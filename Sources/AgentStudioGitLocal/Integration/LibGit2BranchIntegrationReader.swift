import AgentStudioGitContracts
import CLibGit2Local
import Foundation

struct LibGit2BranchIntegrationReader: Sendable {
    private let identityResolver: GitRepositoryIdentityResolver
    private let afterRepositoryOpen: @Sendable () -> Void
    let deltaReader: LibGit2BranchIntegrationDeltaReader

    init(
        identityResolver: GitRepositoryIdentityResolver = GitRepositoryIdentityResolver(),
        afterRepositoryOpen: @escaping @Sendable () -> Void = {},
        deltaReader: LibGit2BranchIntegrationDeltaReader = LibGit2BranchIntegrationDeltaReader()
    ) {
        self.identityResolver = identityResolver
        self.afterRepositoryOpen = afterRepositoryOpen
        self.deltaReader = deltaReader
    }

    func assess(_ request: GitBranchIntegrationRequest) throws -> GitBranchIntegrationReport {
        guard (0...10_000).contains(request.squashSearchCommitLimit) else {
            throw GitDataPlaneError.unsupported(
                message: "branch integration squash search limit must be from 0 through 10000"
            )
        }
        guard !request.targetCommit.isEmpty else {
            throw GitDataPlaneError.revisionUnavailable(target: .named(request.targetCommit))
        }
        guard !request.branchNames.isEmpty else {
            return GitBranchIntegrationReport(targetCommit: request.targetCommit, assessments: [])
        }

        let historyPaths = try resolveHistoryPaths(for: request.repositoryPath)
        let initialHistoryGuard = try? GitBranchIntegrationHistoryGuard.capture(paths: historyPaths)

        return try LibGit2ReviewSupport.withRepository(at: request.repositoryPath) { repository in
            afterRepositoryOpen()

            let target = try resolveTargetCommit(request.targetCommit, repository: repository)
            defer { git_commit_free(target.commit) }

            let historyAvailability = historyAvailability(
                initialGuard: initialHistoryGuard,
                paths: historyPaths,
                repository: repository
            )
            var computedAssessments = [LibGit2ComputedBranchIntegration?](
                repeating: nil,
                count: request.branchNames.count
            )
            var pendingBranches: [LibGit2PendingBranchIntegration] = []

            for (assessmentIndex, branchName) in request.branchNames.enumerated() {
                let result = assessBranch(
                    branchName,
                    targetOID: target.oid,
                    targetTreeOID: target.treeOID,
                    historyAvailability: historyAvailability,
                    repository: repository
                )
                computedAssessments[assessmentIndex] = result.computed
                if let pending = result.pending {
                    pendingBranches.append(
                        LibGit2PendingBranchIntegration(
                            assessmentIndex: assessmentIndex,
                            branchName: branchName,
                            branchCommit: pending.branchCommit,
                            delta: pending.delta
                        )
                    )
                }
            }

            if !pendingBranches.isEmpty, historyAvailability == .complete {
                resolveSquashAssessments(
                    pendingBranches,
                    targetCommit: target.commit,
                    repository: repository,
                    limit: request.squashSearchCommitLimit,
                    computedAssessments: &computedAssessments
                )
            }

            let finalHistoryGuard = try? GitBranchIntegrationHistoryGuard.capture(paths: historyPaths)
            let historyGuardChanged =
                !historyPaths.matches(repository: repository)
                || initialHistoryGuard == nil
                || finalHistoryGuard != initialHistoryGuard

            if historyGuardChanged {
                for assessmentIndex in computedAssessments.indices {
                    guard let computed = computedAssessments[assessmentIndex], computed.dependsOnHistory else {
                        continue
                    }
                    computedAssessments[assessmentIndex] = computed.withGrade(.unknown(.readFailed))
                }
            }

            let assessments = computedAssessments.compactMap { $0?.assessment }
            guard assessments.count == request.branchNames.count else {
                throw LibGit2ErrorCapture.fallbackFailure(
                    code: GIT_ERROR.rawValue,
                    message: "branch integration did not produce every requested assessment"
                )
            }
            return GitBranchIntegrationReport(targetCommit: target.oidString, assessments: assessments)
        }
    }

    private func resolveHistoryPaths(for repositoryPath: URL) throws -> GitBranchIntegrationHistoryPaths {
        do {
            return try GitBranchIntegrationHistoryPaths.resolve(
                repositoryPath: repositoryPath,
                identityResolver: identityResolver
            )
        } catch GitRepositoryIdentityResolverError.missingGitDirectory(let worktreePath) {
            throw GitDataPlaneError.repositoryNotFound(path: worktreePath)
        } catch GitRepositoryIdentityResolverError.invalidGitFile(let gitFilePath) {
            throw LibGit2ErrorCapture.fallbackFailure(
                code: GIT_EINVALID.rawValue,
                message: "invalid .git file: \(gitFilePath.path)"
            )
        } catch {
            throw GitDataPlaneError.unsupported(message: "repository metadata paths could not be resolved")
        }
    }

    private func resolveTargetCommit(
        _ targetCommitString: String,
        repository: OpaquePointer
    ) throws -> LibGit2ResolvedTargetCommit {
        var targetOID = git_oid()
        let parseResult = targetCommitString.withCString { targetCommitPointer in
            git_oid_fromstr(&targetOID, targetCommitPointer)
        }
        guard parseResult >= 0 else {
            throw GitDataPlaneError.revisionUnavailable(target: .named(targetCommitString))
        }

        var commit: OpaquePointer?
        let commitResult = git_commit_lookup(&commit, repository, &targetOID)
        guard commitResult >= 0, let commit else {
            if commitResult == GIT_ENOTFOUND.rawValue {
                throw GitDataPlaneError.requiredObjectNotFound(oid: targetCommitString)
            }
            throw LibGit2ErrorCapture.failure(code: commitResult)
        }

        guard let treeOIDPointer = git_commit_tree_id(commit) else {
            git_commit_free(commit)
            throw LibGit2ErrorCapture.fallbackFailure(
                code: GIT_ERROR.rawValue,
                message: "libgit2 returned a target commit without a tree object ID"
            )
        }
        let treeOID = treeOIDPointer.pointee
        var tree: OpaquePointer?
        let treeResult = git_commit_tree(&tree, commit)
        guard treeResult >= 0, let tree else {
            git_commit_free(commit)
            if treeResult == GIT_ENOTFOUND.rawValue {
                throw GitDataPlaneError.requiredObjectNotFound(oid: Self.oidString(treeOID))
            }
            throw LibGit2ErrorCapture.failure(code: treeResult)
        }
        git_tree_free(tree)

        return LibGit2ResolvedTargetCommit(
            commit: commit,
            oid: targetOID,
            oidString: Self.oidString(targetOID),
            treeOID: treeOID
        )
    }

    private func historyAvailability(
        initialGuard: GitBranchIntegrationHistoryGuard?,
        paths: GitBranchIntegrationHistoryPaths,
        repository: OpaquePointer
    ) -> LibGit2BranchIntegrationHistoryAvailability {
        guard
            let initialGuard,
            paths.matches(repository: repository),
            let guardAfterOpen = try? GitBranchIntegrationHistoryGuard.capture(paths: paths),
            guardAfterOpen == initialGuard
        else {
            return .readFailed
        }

        let shallowResult = git_repository_is_shallow(repository)
        guard shallowResult >= 0 else {
            return .readFailed
        }
        if shallowResult > 0 || initialGuard.containsGraphOverlay {
            return .incomplete
        }
        return .complete
    }

    static func computed(
        branchName: String,
        branchCommit: String?,
        grade: GitBranchIntegrationGrade,
        dependsOnHistory: Bool = false
    ) -> LibGit2ComputedBranchIntegration {
        LibGit2ComputedBranchIntegration(
            assessment: GitBranchIntegrationAssessment(
                branchName: branchName,
                branchCommit: branchCommit,
                grade: grade
            ),
            dependsOnHistory: dependsOnHistory
        )
    }

    static func proofFailure(for code: Int32) -> GitIntegrationUnknownReason {
        code == GIT_ENOTFOUND.rawValue ? .missingObjects : .readFailed
    }

    static func failureKind(for code: Int32) -> GitBranchIntegrationProofFailure {
        code == GIT_ENOTFOUND.rawValue ? .missingObjects : .readFailed
    }

    static func failureKind(
        for result: Result<OpaquePointer, GitBranchIntegrationProofFailure>
    ) -> GitBranchIntegrationProofFailure {
        guard case .failure(let failure) = result else {
            return .readFailed
        }
        return failure
    }

    static func reason(for failure: GitBranchIntegrationProofFailure) -> GitIntegrationUnknownReason {
        switch failure {
        case .missingObjects:
            .missingObjects
        case .readFailed:
            .readFailed
        }
    }

    static func reason<TProofValue>(
        for result: Result<TProofValue, GitBranchIntegrationProofFailure>
    ) -> GitIntegrationUnknownReason {
        guard case .failure(let failure) = result else {
            return .readFailed
        }
        return reason(for: failure)
    }

    static func oidString(_ oid: git_oid) -> String {
        var mutableOID = oid
        var buffer = [CChar](repeating: 0, count: 65)
        buffer.withUnsafeMutableBufferPointer { bufferPointer in
            _ = git_oid_tostr(bufferPointer.baseAddress, bufferPointer.count, &mutableOID)
        }
        let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return String(bytes: bytes, encoding: .utf8) ?? ""
    }
}

enum LibGit2BranchIntegrationHistoryAvailability: Equatable {
    case complete
    case incomplete
    case readFailed
}

struct LibGit2ResolvedTargetCommit {
    let commit: OpaquePointer
    let oid: git_oid
    let oidString: String
    let treeOID: git_oid
}

struct LibGit2ComputedBranchIntegration {
    let assessment: GitBranchIntegrationAssessment
    let dependsOnHistory: Bool

    func withGrade(_ grade: GitBranchIntegrationGrade) -> Self {
        Self(
            assessment: GitBranchIntegrationAssessment(
                branchName: assessment.branchName,
                branchCommit: assessment.branchCommit,
                grade: grade
            ),
            dependsOnHistory: dependsOnHistory
        )
    }
}

struct LibGit2PendingBranchDelta {
    let branchCommit: String
    let delta: GitBranchIntegrationDelta
}

struct LibGit2PendingBranchIntegration {
    let assessmentIndex: Int
    let branchName: String
    let branchCommit: String
    let delta: GitBranchIntegrationDelta
}
