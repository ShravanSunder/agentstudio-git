import AgentStudioGitContracts
import CLibGit2Local
import Foundation

struct LibGit2ReviewRefreshCalculation: Sendable {
    let diff: GitDiffSnapshot
    let successorSeed: GitReviewRefreshSeed
    let disposition: GitReviewCalculationDisposition
    let reason: GitReviewCalculationReason
}

enum LibGit2ProportionalReviewAttempt: Sendable {
    case accepted(GitDiffSnapshot)
    case requiresComplete(GitReviewCalculationReason)
}

struct LibGit2ReviewRefreshCalculator: Sendable {
    static let comparisonOptionsVersion: UInt32 = 1
    static let maximumProportionalChangedPathCount = 256

    private let diffReader = LibGit2DiffReader()

    func completeCalculation(
        key: GitReviewRefreshSeedKey,
        baseTree: OpaquePointer,
        repository: OpaquePointer,
        disposition: GitReviewCalculationDisposition,
        reason: GitReviewCalculationReason
    ) throws -> LibGit2ReviewRefreshCalculation {
        let diff = try diffReader.diff(baseTree: baseTree, repository: repository)
        return LibGit2ReviewRefreshCalculation(
            diff: diff,
            successorSeed: GitReviewRefreshSeed(key: key, files: diff.files),
            disposition: disposition,
            reason: reason
        )
    }

    func proportionalAttempt(
        seed: GitReviewRefreshSeed,
        changedPaths: [String],
        currentKey: GitReviewRefreshSeedKey,
        baseTree: OpaquePointer,
        repository: OpaquePointer,
        resolveCurrentKey: () throws -> GitReviewRefreshSeedKey
    ) -> LibGit2ProportionalReviewAttempt {
        guard !changedPaths.isEmpty else {
            return .requiresComplete(.invalidPath)
        }
        guard changedPaths.count <= Self.maximumProportionalChangedPathCount else {
            return .requiresComplete(.capacityRejected)
        }
        guard seed.storage.key == currentKey else {
            return .requiresComplete(.seedIdentityMismatch)
        }
        guard let seedFileIndexByTouchedPath = seedFileIndexByTouchedPath(seed.storage.files) else {
            return .requiresComplete(.candidatePathCollision)
        }

        let sortedPaths = changedPaths.sorted()
        guard Set(sortedPaths).count == sortedPaths.count else {
            return .requiresComplete(.invalidPath)
        }

        for path in sortedPaths {
            if isStructuralGitControlPath(path) {
                return .requiresComplete(.structuralGitControlPath)
            }
            guard isCurrentRegularWorktreeFile(path, repository: repository) else {
                return .requiresComplete(.invalidPath)
            }
        }

        let scopedDiff: GitDiffSnapshot
        do {
            scopedDiff = try diffReader.diff(
                baseTree: baseTree,
                literalPaths: sortedPaths,
                repository: repository
            )
        } catch {
            return .requiresComplete(.scopedCalculationFailed)
        }

        guard (try? resolveCurrentKey()) == currentKey else {
            return .requiresComplete(.identityMoved)
        }

        return assembleCandidate(
            seedFiles: seed.storage.files,
            validatedSeedFileIndexByTouchedPath: seedFileIndexByTouchedPath,
            changedPaths: sortedPaths,
            scopedFiles: scopedDiff.files
        )
    }

    func assembleCandidate(
        seedFiles: [GitDiffFile],
        validatedSeedFileIndexByTouchedPath: [String: Int]? = nil,
        changedPaths: [String],
        scopedFiles: [GitDiffFile]
    ) -> LibGit2ProportionalReviewAttempt {
        guard
            let predecessorIndex = validatedSeedFileIndexByTouchedPath ?? seedFileIndexByTouchedPath(seedFiles)
        else {
            return .requiresComplete(.candidatePathCollision)
        }
        let changedPathSet = Set(changedPaths)
        guard scopedFiles.allSatisfy({ changedPathSet.contains($0.path) }) else {
            return .requiresComplete(.outOfScopeScopedRow)
        }

        let scopedFilesByPath = Dictionary(grouping: scopedFiles, by: \.path)
        guard scopedFilesByPath.values.allSatisfy({ $0.count == 1 }) else {
            return .requiresComplete(.duplicateScopedRow)
        }

        var replacementByPath: [String: GitDiffFile] = [:]
        for path in changedPaths {
            guard let pathRows = scopedFilesByPath[path], let scopedFile = pathRows.first else {
                return .requiresComplete(.missingScopedRow)
            }
            guard scopedFile.changeKind == .modified,
                scopedFile.path == path,
                scopedFile.previousPath == nil
            else {
                return .requiresComplete(.ineligibleScopedRow)
            }

            if let predecessorIndex = predecessorIndex[path] {
                let predecessor = seedFiles[predecessorIndex]
                guard predecessor.path == path,
                    predecessor.previousPath == nil,
                    predecessor.changeKind == .modified
                else {
                    return .requiresComplete(.incompatiblePredecessorRow)
                }
            }
            replacementByPath[path] = scopedFile
        }

        var candidateFiles = seedFiles.filter { !changedPathSet.contains($0.path) }
        candidateFiles.append(contentsOf: replacementByPath.values)
        candidateFiles.sort { $0.path < $1.path }
        guard candidatePathsAreUnique(candidateFiles) else {
            return .requiresComplete(.candidatePathCollision)
        }
        return .accepted(GitDiffSnapshot(files: candidateFiles))
    }

    private func seedFileIndexByTouchedPath(_ files: [GitDiffFile]) -> [String: Int]? {
        var fileIndexByTouchedPath: [String: Int] = [:]
        fileIndexByTouchedPath.reserveCapacity(files.count * 2)
        for (index, file) in files.enumerated() {
            guard fileIndexByTouchedPath.updateValue(index, forKey: file.path) == nil else {
                return nil
            }
            if let previousPath = file.previousPath,
                fileIndexByTouchedPath.updateValue(index, forKey: previousPath) != nil
            {
                return nil
            }
        }
        return fileIndexByTouchedPath
    }

    private func candidatePathsAreUnique(_ files: [GitDiffFile]) -> Bool {
        var seenPaths: Set<String> = []
        for file in files {
            guard seenPaths.insert(file.path).inserted else {
                return false
            }
            if let previousPath = file.previousPath,
                !seenPaths.insert(previousPath).inserted
            {
                return false
            }
        }
        return true
    }

    private func isStructuralGitControlPath(_ path: String) -> Bool {
        guard let finalComponent = path.split(separator: "/", omittingEmptySubsequences: false).last else {
            return false
        }
        return finalComponent == ".gitattributes" || finalComponent == ".gitignore"
    }

    private func isCurrentRegularWorktreeFile(_ path: String, repository: OpaquePointer) -> Bool {
        guard isValidRepositoryRelativePath(path),
            let workdirPointer = git_repository_workdir(repository)
        else {
            return false
        }

        let worktreeRoot = URL(fileURLWithPath: String(cString: workdirPointer), isDirectory: true)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        let candidate = worktreeRoot.appending(path: path).standardizedFileURL
        guard candidate.path != worktreeRoot.path,
            (try? FileManager.default.destinationOfSymbolicLink(atPath: candidate.path)) == nil
        else {
            return false
        }
        let resolvedCandidate = candidate.resolvingSymlinksInPath()
        let rootPrefix = worktreeRoot.path.hasSuffix("/") ? worktreeRoot.path : "\(worktreeRoot.path)/"
        guard resolvedCandidate.path.hasPrefix(rootPrefix),
            let values = try? resolvedCandidate.resourceValues(forKeys: [.isRegularFileKey]),
            values.isRegularFile == true
        else {
            return false
        }
        return true
    }

    private func isValidRepositoryRelativePath(_ path: String) -> Bool {
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        return !path.isEmpty
            && !path.hasPrefix("/")
            && !components.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." })
    }
}
