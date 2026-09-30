import AgentStudioGitContracts
import CLibGit2Local
import Darwin
import Foundation

struct GitBranchIntegrationHistoryPaths: Equatable, Sendable {
    let gitDirectory: URL
    let commonDirectory: URL

    var graftsFile: URL {
        commonDirectory.appending(path: "info/grafts")
    }

    var shallowFile: URL {
        gitDirectory.appending(path: "shallow")
    }

    static func resolve(
        repositoryPath: URL,
        identityResolver: GitRepositoryIdentityResolver
    ) throws -> Self {
        let identity = try identityResolver.identity(for: repositoryPath)
        let worktree = try identityResolver.worktreeSnapshot(for: repositoryPath)
        guard identity.id == worktree.repositoryID else {
            throw GitBranchIntegrationHistoryGuardError.repositoryPathChanged
        }
        return Self(
            gitDirectory: Self.canonicalURL(worktree.gitDirectory),
            commonDirectory: Self.canonicalURL(identity.canonicalCommonDirectory)
        )
    }

    func matches(repository: OpaquePointer) -> Bool {
        guard
            let actualGitDirectory = Self.canonicalPath(git_repository_path(repository)),
            let actualCommonDirectory = try? LibGit2ReviewSupport.repositoryCommonDirectory(repository),
            let actualInfoDirectory = Self.repositoryInfoDirectory(repository)
        else {
            return false
        }

        return Self.canonicalURL(actualGitDirectory) == Self.canonicalURL(gitDirectory)
            && Self.canonicalURL(actualCommonDirectory) == Self.canonicalURL(commonDirectory)
            && Self.canonicalURL(actualInfoDirectory) == Self.canonicalURL(commonDirectory.appending(path: "info"))
    }

    static func canonicalURL(_ url: URL) -> URL {
        var canonicalPath = url.standardizedFileURL.resolvingSymlinksInPath().path
        while canonicalPath.count > 1, canonicalPath.hasSuffix("/") {
            canonicalPath.removeLast()
        }
        return URL(fileURLWithPath: canonicalPath)
    }

    private static func canonicalPath(_ path: UnsafePointer<CChar>?) -> URL? {
        guard let path else {
            return nil
        }
        return URL(fileURLWithPath: String(cString: path), isDirectory: true)
    }

    private static func repositoryInfoDirectory(_ repository: OpaquePointer) -> URL? {
        var buffer = git_buf()
        defer { git_buf_dispose(&buffer) }

        let result = git_repository_item_path(&buffer, repository, GIT_REPOSITORY_ITEM_INFO)
        guard result >= 0, let path = buffer.ptr else {
            return nil
        }
        return URL(fileURLWithPath: String(cString: path), isDirectory: true)
    }
}

struct GitBranchIntegrationHistoryGuard: Equatable, Sendable {
    let grafts: GitBranchIntegrationMetadataFile
    let shallow: GitBranchIntegrationMetadataFile

    var containsGraphOverlay: Bool {
        grafts.containsRecords || shallow.containsRecords
    }

    static func capture(paths: GitBranchIntegrationHistoryPaths) throws -> Self {
        Self(
            grafts: try GitBranchIntegrationMetadataFile.capture(at: paths.graftsFile),
            shallow: try GitBranchIntegrationMetadataFile.capture(at: paths.shallowFile)
        )
    }
}

struct GitBranchIntegrationMetadataFile: Equatable, Sendable {
    let path: URL
    let fileSystemIdentity: FileSystemIdentity?
    let contents: Data?

    var containsRecords: Bool {
        guard let contents else {
            return false
        }
        return !contents.isEmpty
    }

    static func capture(at path: URL) throws -> Self {
        var firstStatus = stat()
        let firstResult = path.path.withCString { pathPointer in
            stat(pathPointer, &firstStatus)
        }
        guard firstResult == 0 else {
            let errorNumber = errno
            if errorNumber == ENOENT {
                return Self(path: path, fileSystemIdentity: nil, contents: nil)
            }
            throw GitBranchIntegrationHistoryGuardError.statFailed(path: path, errorNumber: errorNumber)
        }

        guard firstStatus.st_mode & S_IFMT == S_IFREG else {
            throw GitBranchIntegrationHistoryGuardError.unexpectedFileKind(path: path)
        }

        let contents: Data
        do {
            contents = try Data(contentsOf: path)
        } catch {
            throw GitBranchIntegrationHistoryGuardError.readFailed(path: path)
        }

        var secondStatus = stat()
        let secondResult = path.path.withCString { pathPointer in
            stat(pathPointer, &secondStatus)
        }
        guard secondResult == 0 else {
            throw GitBranchIntegrationHistoryGuardError.changedDuringRead(path: path)
        }

        let firstIdentity = FileSystemIdentity(firstStatus)
        let secondIdentity = FileSystemIdentity(secondStatus)
        guard firstIdentity == secondIdentity, Int64(contents.count) == secondIdentity.size else {
            throw GitBranchIntegrationHistoryGuardError.changedDuringRead(path: path)
        }

        return Self(path: path, fileSystemIdentity: secondIdentity, contents: contents)
    }

    struct FileSystemIdentity: Equatable, Sendable {
        let device: UInt64
        let inode: UInt64
        let size: Int64
        let modificationSeconds: Int64
        let modificationNanoseconds: Int64
        let changeSeconds: Int64
        let changeNanoseconds: Int64

        init(_ status: stat) {
            device = UInt64(status.st_dev)
            inode = UInt64(status.st_ino)
            size = Int64(status.st_size)
            modificationSeconds = Int64(status.st_mtimespec.tv_sec)
            modificationNanoseconds = Int64(status.st_mtimespec.tv_nsec)
            changeSeconds = Int64(status.st_ctimespec.tv_sec)
            changeNanoseconds = Int64(status.st_ctimespec.tv_nsec)
        }
    }
}

private enum GitBranchIntegrationHistoryGuardError: Error {
    case repositoryPathChanged
    case statFailed(path: URL, errorNumber: Int32)
    case readFailed(path: URL)
    case unexpectedFileKind(path: URL)
    case changedDuringRead(path: URL)
}
