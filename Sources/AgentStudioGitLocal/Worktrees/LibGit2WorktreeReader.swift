import AgentStudioGitContracts
import CLibGit2Local
import Foundation

struct LibGit2WorktreeReader: Sendable {
    private let runtime: LibGit2Runtime

    init(runtime: LibGit2Runtime = .shared) {
        self.runtime = runtime
    }

    func worktrees(for repositoryPath: URL) throws -> [GitWorktreeSnapshot] {
        try withRepository(at: repositoryPath) { repository in
            let mainWorktreePath = try mainWorktreePath(repository: repository)
            return try worktreesFromMainRepository(at: mainWorktreePath)
        }
    }

    private func worktreesFromMainRepository(at mainWorktreePath: URL) throws -> [GitWorktreeSnapshot] {
        try withRepository(at: mainWorktreePath) { repository in
            var snapshots = [try snapshotForMainWorktree(repository: repository, requestedPath: mainWorktreePath)]
            var worktreeNames = git_strarray()
            let listResult = git_worktree_list(&worktreeNames, repository)
            guard listResult >= 0 else {
                throw LibGit2ErrorCapture.failure(code: listResult)
            }
            defer { git_strarray_free(&worktreeNames) }

            let nameCount = Int(worktreeNames.count)
            for index in 0..<nameCount {
                guard let namePointer = worktreeNames.strings[index] else {
                    continue
                }
                do {
                    var worktree: OpaquePointer?
                    let lookupResult = git_worktree_lookup(&worktree, repository, namePointer)
                    guard lookupResult >= 0, let worktree else {
                        throw LibGit2ErrorCapture.failure(code: lookupResult)
                    }
                    defer { git_worktree_free(worktree) }
                    snapshots.append(try snapshot(for: worktree, parentRepository: repository))
                }
            }

            return snapshots.sorted { first, second in
                if first.isMainWorktree != second.isMainWorktree {
                    return first.isMainWorktree
                }
                return first.canonicalPath.path < second.canonicalPath.path
            }
        }
    }

    func validateWorktree(_ request: GitValidateWorktreeRequest) throws
        -> GitWorktreeValidation
    {
        do {
            return try withRepository(at: request.worktreePath) { repository in
                if git_repository_is_worktree(repository) == 0 {
                    return GitWorktreeValidation(
                        snapshot: try snapshotForMainWorktree(
                            repository: repository, requestedPath: request.worktreePath),
                        isValid: true
                    )
                }

                var worktree: OpaquePointer?
                let openResult = git_worktree_open_from_repository(&worktree, repository)
                guard openResult >= 0, let worktree else {
                    throw LibGit2ErrorCapture.failure(code: openResult)
                }
                defer { git_worktree_free(worktree) }

                let validationResult = git_worktree_validate(worktree)
                guard validationResult >= 0 else {
                    return GitWorktreeValidation(snapshot: nil, isValid: false)
                }

                return GitWorktreeValidation(
                    snapshot: try snapshot(for: worktree, parentRepository: repository),
                    isValid: true
                )
            }
        } catch GitDataPlaneError.repositoryNotFound {
            return GitWorktreeValidation(snapshot: nil, isValid: false)
        } catch {
            throw error
        }
    }

    func snapshotForWorktreeID(_ worktreeID: GitWorktreeID) throws -> GitWorktreeSnapshot {
        guard let parsedID = LibGit2WorktreeIDParser.parse(worktreeID) else {
            throw GitDataPlaneError.worktreeNotFound(id: worktreeID)
        }
        let snapshots = try worktrees(for: parsedID.mainWorktreePath)
        guard let snapshot = snapshots.first(where: { $0.id == worktreeID }) else {
            throw GitDataPlaneError.worktreeNotFound(id: worktreeID)
        }
        return snapshot
    }

    private func withRepository<ReturnValue>(
        at path: URL,
        _ body: (OpaquePointer) throws -> ReturnValue
    ) throws -> ReturnValue {
        try runtime.ensureInitialized()

        var repository: OpaquePointer?
        let openResult = path.path.withCString { pathPointer in
            git_repository_open_ext(&repository, pathPointer, 0, nil)
        }
        guard openResult >= 0, let repository else {
            throw repositoryOpenFailure(code: openResult, path: path)
        }
        defer { git_repository_free(repository) }

        return try body(repository)
    }
}

func mainWorktreePath(repository: OpaquePointer) throws -> URL {
    let commonDirectory = try requiredGitURL(git_repository_commondir(repository), label: "common directory")
    if commonDirectory.lastPathComponent == ".git" {
        return commonDirectory.deletingLastPathComponent()
    }
    return try requiredGitURL(git_repository_workdir(repository), label: "work directory")
}

func repositoryOpenFailure(code: Int32, path: URL) -> GitDataPlaneError {
    if code == GIT_ENOTFOUND.rawValue {
        return .repositoryNotFound(path: path)
    }
    return LibGit2ErrorCapture.failure(code: code)
}

func snapshotForMainWorktree(
    repository: OpaquePointer,
    requestedPath: URL
) throws -> GitWorktreeSnapshot {
    let gitDirectory = try requiredGitURL(git_repository_path(repository), label: "git directory")
    let commonDirectory = try requiredGitURL(git_repository_commondir(repository), label: "common directory")
    let workDirectory = try requiredGitURL(git_repository_workdir(repository), label: "work directory")
    let canonicalPath = canonicalWorktreeURL(for: workDirectory)
    let repositoryID = GitRepositoryID(rawValue: "common:\(commonDirectory.path)")
    return GitWorktreeSnapshot(
        id: LibGit2WorktreeIDParser.worktreeID(repositoryID: repositoryID, canonicalPath: canonicalPath),
        repositoryID: repositoryID,
        displayName: "main",
        path: requestedPath.standardizedFileURL,
        canonicalPath: canonicalPath,
        gitDirectory: gitDirectory,
        indexPath: gitDirectory.appending(path: "index"),
        isMainWorktree: true,
        isLocked: false,
        lockReason: nil,
        head: try headSnapshot(repository: repository)
    )
}

func snapshot(
    for worktree: OpaquePointer,
    parentRepository: OpaquePointer
) throws -> GitWorktreeSnapshot {
    var repository: OpaquePointer?
    let openResult = git_repository_open_from_worktree(&repository, worktree)
    guard openResult >= 0, let repository else {
        throw LibGit2ErrorCapture.failure(code: openResult)
    }
    defer { git_repository_free(repository) }

    let commonDirectory = try requiredGitURL(git_repository_commondir(repository), label: "common directory")
    let gitDirectory = try requiredGitURL(git_repository_path(repository), label: "git directory")
    let path = try requiredGitURL(git_worktree_path(worktree), label: "worktree path")
    let canonicalPath = canonicalWorktreeURL(for: path)
    let repositoryID = GitRepositoryID(rawValue: "common:\(commonDirectory.path)")
    let lockState = try worktreeLockState(worktree)
    return GitWorktreeSnapshot(
        id: LibGit2WorktreeIDParser.worktreeID(repositoryID: repositoryID, canonicalPath: canonicalPath),
        repositoryID: repositoryID,
        displayName: try requiredGitString(git_worktree_name(worktree), label: "worktree name"),
        path: path,
        canonicalPath: canonicalPath,
        gitDirectory: gitDirectory,
        indexPath: gitDirectory.appending(path: "index"),
        isMainWorktree: false,
        isLocked: lockState.isLocked,
        lockReason: lockState.reason,
        head: try headSnapshot(repository: repository)
    )
}

func requiredGitURL(_ pointer: UnsafePointer<CChar>?, label: String) throws -> URL {
    guard let pointer else {
        throw LibGit2ErrorCapture.fallbackFailure(
            code: -1,
            message: "libgit2 returned no \(label)"
        )
    }
    return URL(fileURLWithPath: normalizedGitPath(String(cString: pointer)), isDirectory: false).standardizedFileURL
}

private func normalizedGitPath(_ path: String) -> String {
    var normalizedPath = path
    while normalizedPath.count > 1, normalizedPath.hasSuffix("/") {
        normalizedPath.removeLast()
    }
    if normalizedPath == "/private/tmp" || normalizedPath.hasPrefix("/private/tmp/") {
        normalizedPath.removeFirst("/private".count)
    } else if normalizedPath == "/private/var" || normalizedPath.hasPrefix("/private/var/") {
        normalizedPath.removeFirst("/private".count)
    }
    return normalizedPath
}

func canonicalWorktreeURL(for url: URL) -> URL {
    URL(
        fileURLWithPath: normalizedGitPath(GitPathCanonicalizer.canonicalURL(for: url).path),
        isDirectory: false
    ).standardizedFileURL
}

func normalizedGitPath(for url: URL) -> String {
    normalizedGitPath(GitPathCanonicalizer.canonicalURL(for: url).path)
}

func requiredGitString(_ pointer: UnsafePointer<CChar>?, label: String) throws -> String {
    guard let pointer else {
        throw LibGit2ErrorCapture.fallbackFailure(
            code: -1,
            message: "libgit2 returned no \(label)"
        )
    }
    return String(cString: pointer)
}

func headSnapshot(repository: OpaquePointer) throws -> GitHeadSnapshot {
    var headReference: OpaquePointer?
    let headResult = git_repository_head(&headReference, repository)
    if headResult == GIT_EUNBORNBRANCH.rawValue {
        return GitHeadSnapshot(kind: .unborn, oid: nil, shortName: nil)
    }
    guard headResult >= 0, let headReference else {
        throw LibGit2ErrorCapture.failure(code: headResult)
    }
    defer { git_reference_free(headReference) }

    let target = git_reference_target(headReference) ?? git_reference_target_peel(headReference)
    let oid = target.map(oidString)
    if git_reference_is_branch(headReference) == 1 {
        return GitHeadSnapshot(
            kind: .branch,
            oid: oid,
            shortName: git_reference_shorthand(headReference).map { String(cString: $0) }
        )
    }

    return GitHeadSnapshot(kind: .detached, oid: oid, shortName: nil)
}

func oidString(_ oid: UnsafePointer<git_oid>) -> String {
    var buffer = [CChar](repeating: 0, count: 41)
    buffer.withUnsafeMutableBufferPointer { bufferPointer in
        _ = git_oid_tostr(bufferPointer.baseAddress, bufferPointer.count, oid)
    }
    let endIndex = buffer.firstIndex(of: 0) ?? buffer.count
    let bytes = buffer[..<endIndex].map { UInt8(bitPattern: $0) }
    return String(bytes: bytes, encoding: .utf8) ?? ""
}

func worktreeLockState(_ worktree: OpaquePointer) throws -> (isLocked: Bool, reason: String?) {
    var reasonBuffer = git_buf(ptr: nil, reserved: 0, size: 0)
    let lockResult = git_worktree_is_locked(&reasonBuffer, worktree)
    defer { git_buf_dispose(&reasonBuffer) }
    guard lockResult >= 0 else {
        throw LibGit2ErrorCapture.failure(code: lockResult)
    }
    guard lockResult > 0 else {
        return (false, nil)
    }
    return (true, reasonBuffer.ptr.map { String(cString: $0).trimmingCharacters(in: .newlines) })
}

struct LibGit2ParsedWorktreeID: Sendable {
    let commonDirectory: URL
    let canonicalPath: URL

    var mainWorktreePath: URL {
        commonDirectory.lastPathComponent == ".git"
            ? commonDirectory.deletingLastPathComponent()
            : commonDirectory
    }
}

enum LibGit2WorktreeIDParser {
    static func worktreeID(repositoryID: GitRepositoryID, canonicalPath: URL) -> GitWorktreeID {
        GitWorktreeID(rawValue: "\(repositoryID.rawValue)|worktree:\(canonicalPath.path)")
    }

    static func parse(_ worktreeID: GitWorktreeID) -> LibGit2ParsedWorktreeID? {
        let marker = "|worktree:"
        guard let markerRange = worktreeID.rawValue.range(of: marker) else {
            return nil
        }
        let repositoryPart = String(worktreeID.rawValue[..<markerRange.lowerBound])
        let pathPart = String(worktreeID.rawValue[markerRange.upperBound...])
        let commonPrefix = "common:"
        guard repositoryPart.hasPrefix(commonPrefix), !pathPart.isEmpty else {
            return nil
        }
        let commonPath = String(repositoryPart.dropFirst(commonPrefix.count))
        return LibGit2ParsedWorktreeID(
            commonDirectory: URL(fileURLWithPath: commonPath, isDirectory: true).standardizedFileURL,
            canonicalPath: URL(fileURLWithPath: pathPart, isDirectory: true).standardizedFileURL
        )
    }
}
