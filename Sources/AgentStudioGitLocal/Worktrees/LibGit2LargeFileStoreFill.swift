import AgentStudioGitContracts
import CLibGit2Local
import Darwin
import Foundation

struct LibGit2LargeFileStoreFill: Sendable {
    private let store: LibGit2LargeFileStore

    init(store: LibGit2LargeFileStore = LibGit2LargeFileStore()) {
        self.store = store
    }

    func fill(worktreePath: URL) -> GitLargeFileFill {
        var repository: OpaquePointer?
        let openResult = worktreePath.path.withCString {
            git_repository_open_ext(&repository, $0, GIT_REPOSITORY_OPEN_NO_SEARCH.rawValue, nil)
        }
        guard openResult >= 0, let repository else {
            return GitLargeFileFill(
                materializedCount: 0,
                missing: [],
                indexUpdate: .skipped(.gitFailure(.repositoryIndexUnavailable))
            )
        }
        defer { git_repository_free(repository) }

        return fill(repository: repository, worktreePath: worktreePath)
    }

    private func fill(repository: OpaquePointer, worktreePath: URL) -> GitLargeFileFill {
        let commonDirectory: URL
        if let commonDirectoryPointer = git_repository_commondir(repository) {
            commonDirectory = URL(
                fileURLWithPath: String(cString: commonDirectoryPointer),
                isDirectory: true
            )
        } else {
            return GitLargeFileFill(
                materializedCount: 0,
                missing: [],
                indexUpdate: .skipped(.gitFailure(.repositoryIndexUnavailable))
            )
        }

        var index: OpaquePointer?
        let indexResult = git_repository_index(&index, repository)
        guard indexResult >= 0, let index else {
            return GitLargeFileFill(
                materializedCount: 0,
                missing: [],
                indexUpdate: .skipped(.gitFailure(.repositoryIndexUnavailable))
            )
        }
        defer { git_index_free(index) }
        let indexReadResult = git_index_read(index, 1)
        guard indexReadResult >= 0 else {
            return GitLargeFileFill(
                materializedCount: 0,
                missing: [],
                indexUpdate: .skipped(.gitFailure(.indexReadFailed))
            )
        }

        var missing: [GitLargeFileFillMiss] = []
        let candidates = lfsCandidates(index: index, repository: repository, missing: &missing)
        guard !candidates.isEmpty else {
            return fillResult(materializedCount: 0, missing: missing)
        }

        let storageRoot: URL
        switch store.storageRoot(repository: repository, commonDirectory: commonDirectory) {
        case .success(let root):
            storageRoot = root
        case .failure(let failure):
            missing.append(
                contentsOf: candidates.map {
                    GitLargeFileFillMiss(path: $0.path, reason: failure.reason)
                })
            return fillResult(materializedCount: 0, missing: missing)
        }
        let storageRootDescriptor: Int32
        switch store.openStorageRoot(at: storageRoot) {
        case .success(let descriptor):
            storageRootDescriptor = descriptor
        case .failure(let failure):
            missing.append(
                contentsOf: candidates.map {
                    GitLargeFileFillMiss(path: $0.path, reason: failure.reason)
                })
            return fillResult(materializedCount: 0, missing: missing)
        }
        defer { close(storageRootDescriptor) }

        let canonicalWorktreePath: URL
        switch WorktreeForkDescriptors.realpathURL(worktreePath) {
        case .success(let resolvedPath):
            canonicalWorktreePath = resolvedPath
        case .failure(let failure):
            missing.append(
                contentsOf: candidates.map {
                    GitLargeFileFillMiss(path: $0.path, reason: .readFailed(errno: failure.code))
                })
            return fillResult(materializedCount: 0, missing: missing)
        }
        let worktreeRootDescriptor: Int32
        switch WorktreeForkDescriptors.openRoot(atCanonicalPath: canonicalWorktreePath) {
        case .success(let descriptor):
            worktreeRootDescriptor = descriptor
        case .failure(let failure):
            missing.append(
                contentsOf: candidates.map {
                    GitLargeFileFillMiss(path: $0.path, reason: .readFailed(errno: failure.code))
                })
            return fillResult(materializedCount: 0, missing: missing)
        }
        defer { close(worktreeRootDescriptor) }

        let priorDatalessPolicy: WorktreeForkDatalessPolicy.PriorPolicy
        switch WorktreeForkDatalessPolicy.denyMaterializationOnCurrentThread() {
        case .success(let prior):
            priorDatalessPolicy = prior
        case .failure(let failure):
            missing.append(
                contentsOf: candidates.map {
                    GitLargeFileFillMiss(path: $0.path, reason: .readFailed(errno: failure.code))
                })
            return fillResult(materializedCount: 0, missing: missing)
        }
        defer { WorktreeForkDatalessPolicy.restore(priorDatalessPolicy) }

        var materializedCount = 0
        for candidate in candidates {
            switch pointerIdentity(
                for: candidate,
                worktreeRootDescriptor: worktreeRootDescriptor
            ) {
            case .notPointer:
                continue
            case .readFailed(let errorNumber):
                missing.append(
                    GitLargeFileFillMiss(path: candidate.path, reason: .readFailed(errno: errorNumber)))
            case .matches(let identity):
                let outcome = store.materialize(
                    pointer: candidate.pointer,
                    pointerData: candidate.pointerData,
                    expectedPointerIdentity: identity,
                    indexMode: candidate.indexMode,
                    path: candidate.path,
                    storageRootDescriptor: storageRootDescriptor,
                    worktreeRootDescriptor: worktreeRootDescriptor
                )
                switch outcome {
                case .success(true):
                    materializedCount += 1
                case .success(false):
                    continue
                case .failure(let failure):
                    missing.append(GitLargeFileFillMiss(path: candidate.path, reason: failure.reason))
                }
            }
        }
        return fillResult(materializedCount: materializedCount, missing: missing)
    }

    private func lfsCandidates(
        index: OpaquePointer,
        repository: OpaquePointer,
        missing: inout [GitLargeFileFillMiss]
    ) -> [LargeFileFillCandidate] {
        var attributeOptions = git_attr_options()
        attributeOptions.version = UInt32(GIT_ATTR_OPTIONS_VERSION)
        attributeOptions.flags = UInt32(GIT_ATTR_CHECK_INCLUDE_HEAD)
        var candidates: [LargeFileFillCandidate] = []
        let regularModes: Set<UInt32> = [
            UInt32(GIT_FILEMODE_BLOB.rawValue),
            UInt32(GIT_FILEMODE_BLOB_EXECUTABLE.rawValue),
        ]

        for position in 0..<git_index_entrycount(index) {
            guard var entry = git_index_get_byindex(index, position)?.pointee,
                git_index_entry_stage(&entry) == 0,
                regularModes.contains(entry.mode),
                let pathPointer = entry.path
            else {
                continue
            }
            let path = String(cString: pathPointer)
            var filterValue: UnsafePointer<CChar>?
            errno = 0
            let attributeResult = path.withCString { pathPointer in
                "filter".withCString { attributeName in
                    git_attr_get_ext(&filterValue, repository, &attributeOptions, pathPointer, attributeName)
                }
            }
            guard attributeResult >= 0 else {
                missing.append(
                    GitLargeFileFillMiss(path: path, reason: .readFailed(errno: Self.currentReadErrorNumber()))
                )
                continue
            }
            guard let filterValue, git_attr_value(filterValue) == GIT_ATTR_VALUE_STRING,
                String(cString: filterValue) == "lfs"
            else {
                continue
            }

            var objectID = entry.id
            var blob: OpaquePointer?
            errno = 0
            let blobResult = git_blob_lookup(&blob, repository, &objectID)
            guard blobResult >= 0, let blob else {
                missing.append(
                    GitLargeFileFillMiss(path: path, reason: .readFailed(errno: Self.currentReadErrorNumber()))
                )
                continue
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
                LargeFileFillCandidate(path: path, pointerData: pointerData, pointer: pointer, indexMode: entry.mode)
            )
        }
        return candidates.sorted { $0.path < $1.path }
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
        missing: [GitLargeFileFillMiss]
    ) -> GitLargeFileFill {
        GitLargeFileFill(
            materializedCount: materializedCount,
            missing: missing.sorted { $0.path < $1.path },
            indexUpdate: .updated
        )
    }

    private static func currentReadErrorNumber() -> Int32 {
        errno == 0 ? EIO : errno
    }

}

private struct LargeFileFillCandidate {
    let path: String
    let pointerData: Data
    let pointer: LargeFilePointer
    let indexMode: UInt32
}

private enum WorktreePointerState {
    case notPointer
    case matches(WorktreeForkEntryIdentity)
    case readFailed(Int32)
}
