import AgentStudioGitContracts
import CLibGit2Local
import Darwin
import Foundation

struct LibGit2LargeFileStoreFill: Sendable {
    private let store: LibGit2LargeFileStore
    private let faults: LibGit2LargeFileStoreFillFaultInjector

    init(
        store: LibGit2LargeFileStore = LibGit2LargeFileStore(),
        faults: LibGit2LargeFileStoreFillFaultInjector = LibGit2LargeFileStoreFillFaultInjector()
    ) {
        self.store = store
        self.faults = faults
    }

    func fill(worktreePath: URL, excludedPaths: Set<String> = []) -> GitLargeFileFill {
        var repository: OpaquePointer?
        let openResult = worktreePath.path.withCString {
            git_repository_open_ext(&repository, $0, GIT_REPOSITORY_OPEN_NO_SEARCH.rawValue, nil)
        }
        guard openResult >= 0, let repository else {
            return emptyFill(scan: .incomplete(.gitFailure(kind: .repositoryUnavailable)))
        }
        defer { git_repository_free(repository) }

        let canonicalWorktreePath: URL
        switch WorktreeForkDescriptors.realpathURL(worktreePath) {
        case .success(let resolvedPath):
            canonicalWorktreePath = resolvedPath
        case .failure(let failure):
            return emptyFill(scan: .incomplete(.readFailed(errno: failure.code)))
        }
        let worktreeRootDescriptor: Int32
        switch WorktreeForkDescriptors.openRoot(atCanonicalPath: canonicalWorktreePath) {
        case .success(let descriptor):
            worktreeRootDescriptor = descriptor
        case .failure(let failure):
            return emptyFill(scan: .incomplete(.readFailed(errno: failure.code)))
        }
        defer { close(worktreeRootDescriptor) }

        return fill(
            repository: repository,
            worktreeRootDescriptor: worktreeRootDescriptor,
            excludedPaths: excludedPaths
        )
    }

    func fill(
        repository: OpaquePointer,
        worktreeRootDescriptor: Int32,
        excludedPaths: Set<String> = []
    ) -> GitLargeFileFill {
        let commonDirectory: URL
        if let commonDirectoryPointer = git_repository_commondir(repository) {
            commonDirectory = URL(
                fileURLWithPath: String(cString: commonDirectoryPointer),
                isDirectory: true
            )
        } else {
            return emptyFill(scan: .incomplete(.gitFailure(kind: .repositoryUnavailable)))
        }

        if let scanFailure = faults.scanFailureIfRequested() {
            return emptyFill(scan: .incomplete(scanFailure))
        }
        faults.beforeScanning(worktreeRootDescriptor)

        let candidates: [LargeFileFillCandidate]
        switch lfsCandidates(repository: repository, excludedPaths: excludedPaths) {
        case .success(let scannedCandidates):
            candidates = scannedCandidates
        case .failure(.scan(let failure)):
            return emptyFill(scan: .incomplete(failure))
        }
        guard !candidates.isEmpty else {
            faults.beforeReturning()
            return fillResult(materializedCount: 0, missing: [], scan: .complete)
        }

        var missing: [GitLargeFileFillMiss] = []
        var readyCandidates: [ReadyLargeFileFillCandidate] = []
        for candidate in candidates {
            switch pointerIdentity(for: candidate, worktreeRootDescriptor: worktreeRootDescriptor) {
            case .notPointer:
                continue
            case .readFailed(let errorNumber):
                missing.append(GitLargeFileFillMiss(path: candidate.path, reason: .readFailed(errno: errorNumber)))
            case .matches(let identity):
                readyCandidates.append(ReadyLargeFileFillCandidate(candidate: candidate, pointerIdentity: identity))
            }
        }
        guard !readyCandidates.isEmpty else {
            faults.beforeReturning()
            return fillResult(materializedCount: 0, missing: missing, scan: .complete)
        }

        let storageRoot: URL
        switch store.storageRoot(repository: repository, commonDirectory: commonDirectory) {
        case .success(let root):
            storageRoot = root
        case .failure(let failure):
            missing.append(
                contentsOf: readyCandidates.map {
                    GitLargeFileFillMiss(path: $0.candidate.path, reason: failure.reason)
                })
            return fillResult(materializedCount: 0, missing: missing, scan: .complete)
        }
        let storageRootDescriptor: Int32
        switch store.openStorageRoot(at: storageRoot) {
        case .success(let descriptor):
            storageRootDescriptor = descriptor
        case .failure(let failure):
            missing.append(
                contentsOf: readyCandidates.map {
                    GitLargeFileFillMiss(path: $0.candidate.path, reason: failure.reason)
                })
            return fillResult(materializedCount: 0, missing: missing, scan: .complete)
        }
        defer { close(storageRootDescriptor) }

        let priorDatalessPolicy: WorktreeForkDatalessPolicy.PriorPolicy
        switch WorktreeForkDatalessPolicy.denyMaterializationOnCurrentThread() {
        case .success(let prior):
            priorDatalessPolicy = prior
        case .failure(let failure):
            let policyMissing = readyCandidates.map {
                GitLargeFileFillMiss(path: $0.candidate.path, reason: .readFailed(errno: failure.code))
            }
            return fillResult(
                materializedCount: 0,
                missing: missing + policyMissing,
                scan: .complete
            )
        }
        defer { WorktreeForkDatalessPolicy.restore(priorDatalessPolicy) }

        let candidateFill = materializeCandidates(
            candidates: readyCandidates,
            initialMissing: missing,
            storageRootDescriptor: storageRootDescriptor,
            worktreeRootDescriptor: worktreeRootDescriptor
        )
        faults.beforeReturning()
        return candidateFill
    }

    private func emptyFill(scan: GitLargeFileScan) -> GitLargeFileFill {
        GitLargeFileFill(
            materializedCount: 0,
            missing: [],
            residuePaths: [],
            scan: scan
        )
    }

    private func materializeCandidates(
        candidates: [ReadyLargeFileFillCandidate],
        initialMissing: [GitLargeFileFillMiss],
        storageRootDescriptor: Int32,
        worktreeRootDescriptor: Int32
    ) -> GitLargeFileFill {
        var missing = initialMissing
        var residuePaths: [String] = []
        var materializedCount = 0
        for readyCandidate in candidates {
            let candidate = readyCandidate.candidate
            let identity = readyCandidate.pointerIdentity
            let request = LargeFileStoreMaterializationRequest(
                pointer: candidate.pointer,
                pointerData: candidate.pointerData,
                expectedPointerIdentity: identity,
                indexMode: candidate.headMode,
                path: candidate.path
            )
            switch store.materialize(
                request: request,
                storageRootDescriptor: storageRootDescriptor,
                worktreeRootDescriptor: worktreeRootDescriptor
            ) {
            case .success(let materialization):
                if materialization.didMaterialize {
                    materializedCount += 1
                }
                if let residuePath = materialization.residuePath {
                    residuePaths.append(residuePath)
                }
            case .failure(let failure):
                missing.append(GitLargeFileFillMiss(path: candidate.path, reason: failure.reason))
                if let residuePath = failure.residuePath {
                    residuePaths.append(residuePath)
                }
            }
        }
        return fillResult(
            materializedCount: materializedCount,
            missing: missing,
            residuePaths: residuePaths,
            scan: .complete
        )
    }

    private func lfsCandidates(
        repository: OpaquePointer,
        excludedPaths: Set<String>
    ) -> Result<[LargeFileFillCandidate], LargeFileCandidateScanError> {
        var headReference: OpaquePointer?
        let headResult = git_repository_head(&headReference, repository)
        guard headResult >= 0, let headReference else {
            return .failure(.scan(.gitFailure(kind: .headUnavailable)))
        }
        defer { git_reference_free(headReference) }

        var headCommitObject: OpaquePointer?
        let peelResult = git_reference_peel(&headCommitObject, headReference, GIT_OBJECT_COMMIT)
        guard peelResult >= 0, let headCommitObject else {
            return .failure(.scan(.gitFailure(kind: .headUnavailable)))
        }
        defer { git_object_free(headCommitObject) }

        var headTree: OpaquePointer?
        let treeResult = git_commit_tree(&headTree, headCommitObject)
        guard treeResult >= 0, let headTree else {
            return .failure(.scan(.gitFailure(kind: .treeReadFailed)))
        }
        defer { git_tree_free(headTree) }

        var attributeOptions = git_attr_options()
        attributeOptions.version = UInt32(GIT_ATTR_OPTIONS_VERSION)
        attributeOptions.flags = UInt32(GIT_ATTR_CHECK_INCLUDE_HEAD)
        var candidates: [LargeFileFillCandidate] = []
        let scanResult = appendLFSCandidates(
            in: headTree,
            pathPrefix: "",
            repository: repository,
            attributeOptions: &attributeOptions,
            excludedPaths: excludedPaths,
            candidates: &candidates
        )
        guard case .success = scanResult else {
            return scanResult.map { _ in [] }
        }
        return .success(candidates.sorted { $0.path < $1.path })
    }

    private func appendLFSCandidates(
        in tree: OpaquePointer,
        pathPrefix: String,
        repository: OpaquePointer,
        attributeOptions: inout git_attr_options,
        excludedPaths: Set<String>,
        candidates: inout [LargeFileFillCandidate]
    ) -> Result<Void, LargeFileCandidateScanError> {
        let regularModes: Set<UInt32> = [
            UInt32(GIT_FILEMODE_BLOB.rawValue),
            UInt32(GIT_FILEMODE_BLOB_EXECUTABLE.rawValue),
        ]

        for position in 0..<git_tree_entrycount(tree) {
            guard let entry = git_tree_entry_byindex(tree, position),
                let namePointer = git_tree_entry_name(entry)
            else {
                return .failure(.scan(.gitFailure(kind: .treeReadFailed)))
            }
            let name = String(cString: namePointer)
            let path = pathPrefix.isEmpty ? name : "\(pathPrefix)/\(name)"

            if git_tree_entry_type(entry) == GIT_OBJECT_TREE {
                var childTree: OpaquePointer?
                let childTreeResult = git_tree_lookup(&childTree, repository, git_tree_entry_id(entry))
                guard childTreeResult >= 0, let childTree else {
                    return .failure(.scan(.gitFailure(kind: .treeReadFailed)))
                }
                let childResult = appendLFSCandidates(
                    in: childTree,
                    pathPrefix: path,
                    repository: repository,
                    attributeOptions: &attributeOptions,
                    excludedPaths: excludedPaths,
                    candidates: &candidates
                )
                git_tree_free(childTree)
                guard case .success = childResult else {
                    return childResult
                }
                continue
            }

            guard regularModes.contains(UInt32(git_tree_entry_filemode(entry).rawValue)),
                !excludedPaths.contains(where: { Self.pathsOverlap(path, $0) })
            else {
                continue
            }

            var filterValue: UnsafePointer<CChar>?
            let attributeResult = path.withCString { pathPointer in
                "filter".withCString { attributeName in
                    git_attr_get_ext(&filterValue, repository, &attributeOptions, pathPointer, attributeName)
                }
            }
            guard attributeResult >= 0 else {
                return .failure(.scan(.gitFailure(kind: .attributeReadFailed)))
            }
            guard let filterValue, git_attr_value(filterValue) == GIT_ATTR_VALUE_STRING,
                String(cString: filterValue) == "lfs"
            else {
                continue
            }

            var blob: OpaquePointer?
            let blobResult = git_blob_lookup(&blob, repository, git_tree_entry_id(entry))
            guard blobResult >= 0, let blob else {
                return .failure(.scan(.gitFailure(kind: .treeReadFailed)))
            }
            defer { git_blob_free(blob) }

            let pointerSize = git_blob_rawsize(blob)
            guard pointerSize > 0, pointerSize < Int64(LibGit2LargeFilePointerCleanliness.maximumPointerByteCount),
                let pointerContent = git_blob_rawcontent(blob)
            else {
                continue
            }
            let pointerData = Data(bytes: pointerContent, count: Int(pointerSize))
            guard let pointer = LargeFilePointer(data: pointerData) else {
                continue
            }
            candidates.append(
                LargeFileFillCandidate(
                    path: path,
                    pointerData: pointerData,
                    pointer: pointer,
                    headMode: UInt32(git_tree_entry_filemode(entry).rawValue)
                )
            )
        }
        return .success(())
    }

    private static func pathsOverlap(_ left: String, _ right: String) -> Bool {
        left == right || left.hasPrefix(right + "/") || right.hasPrefix(left + "/")
    }

    private func pointerIdentity(
        for candidate: LargeFileFillCandidate,
        worktreeRootDescriptor: Int32
    ) -> WorktreePointerState {
        let (parentPath, name) = WorktreeForkDescriptors.splitParent(candidate.path)
        let parentDescriptor: Int32
        switch WorktreeForkDescriptors.openDirectory(beneath: worktreeRootDescriptor, relativePath: parentPath) {
        case .success(let descriptor):
            parentDescriptor = descriptor
        case .failure(let failure) where failure.code == ENOENT || failure.code == ENOTDIR:
            return .notPointer
        case .failure(let failure):
            return .readFailed(failure.code)
        }
        defer { close(parentDescriptor) }

        let descriptor = name.withCString {
            openat(parentDescriptor, $0, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        }
        guard descriptor >= 0 else {
            if errno == ENOENT || errno == ENOTDIR || errno == ELOOP {
                return .notPointer
            }
            return .readFailed(errno)
        }
        defer { close(descriptor) }
        guard case .success(let info) = WorktreeForkDescriptors.statDescriptor(descriptor) else {
            return .readFailed(Self.currentReadErrorNumber())
        }
        guard WorktreeForkEntryKind(mode: info.st_mode) == .regularFile,
            info.st_size == off_t(candidate.pointerData.count)
        else {
            return .notPointer
        }
        guard info.st_flags & UInt32(SF_DATALESS) == 0 else {
            return .readFailed(EIO)
        }
        switch LibGit2LargeFileStore.readExactly(candidate.pointerData.count, from: descriptor) {
        case .success(let contents) where contents == candidate.pointerData:
            return .matches(WorktreeForkEntryIdentity(info))
        case .success:
            return .notPointer
        case .failure(let failure):
            if case .readFailed(let errorNumber) = failure.reason {
                return .readFailed(errorNumber)
            }
            return .readFailed(EIO)
        }
    }

    private func fillResult(
        materializedCount: Int,
        missing: [GitLargeFileFillMiss],
        residuePaths: [String] = [],
        scan: GitLargeFileScan
    ) -> GitLargeFileFill {
        GitLargeFileFill(
            materializedCount: materializedCount,
            missing: missing.sorted { $0.path < $1.path },
            residuePaths: Array(Set(residuePaths)).sorted(),
            scan: scan
        )
    }

    private static func currentReadErrorNumber() -> Int32 {
        errno == 0 ? EIO : errno
    }

}

struct LibGit2LargeFileStoreFillFaultInjector: Sendable {
    private let scanFailure: GitLargeFileScanFailure?
    private let beforeScanningHandler: @Sendable (Int32) -> Void
    private let beforeReturningHandler: @Sendable () -> Void

    init(
        scanFailure: GitLargeFileScanFailure? = nil,
        beforeScanning: @escaping @Sendable (Int32) -> Void = { _ in },
        beforeReturning: @escaping @Sendable () -> Void = {}
    ) {
        self.scanFailure = scanFailure
        beforeScanningHandler = beforeScanning
        beforeReturningHandler = beforeReturning
    }

    func scanFailureIfRequested() -> GitLargeFileScanFailure? {
        scanFailure
    }

    func beforeScanning(_ worktreeRootDescriptor: Int32) {
        beforeScanningHandler(worktreeRootDescriptor)
    }

    func beforeReturning() {
        beforeReturningHandler()
    }
}

private enum LargeFileCandidateScanError: Error {
    case scan(GitLargeFileScanFailure)
}

private struct LargeFileFillCandidate {
    let path: String
    let pointerData: Data
    let pointer: LargeFilePointer
    let headMode: UInt32
}

private struct ReadyLargeFileFillCandidate {
    let candidate: LargeFileFillCandidate
    let pointerIdentity: WorktreeForkEntryIdentity
}

private enum WorktreePointerState {
    case notPointer
    case matches(WorktreeForkEntryIdentity)
    case readFailed(Int32)
}
