import AgentStudioGitContracts
import Foundation

public struct GitRepositoryIdentityResolver: Sendable {
    public init() {}

    public func identity(for worktreePath: URL) throws -> GitRepositoryIdentity {
        let resolution = try resolveGitDirectories(for: worktreePath)
        return GitRepositoryIdentity(
            id: repositoryID(for: resolution.commonDirectory),
            canonicalCommonDirectory: resolution.commonDirectory,
            mainWorktreePath: resolution.mainWorktreePath
        )
    }

    public func worktreeSnapshot(for worktreePath: URL) throws -> GitWorktreeSnapshot {
        let resolution = try resolveGitDirectories(for: worktreePath)
        let repositoryID = repositoryID(for: resolution.commonDirectory)
        let worktreeID = GitWorktreeID(
            rawValue: "\(repositoryID.rawValue)|worktree:\(resolution.canonicalWorktreePath.path)"
        )
        return GitWorktreeSnapshot(
            id: worktreeID,
            repositoryID: repositoryID,
            displayName: resolution.isMainWorktree ? "main" : resolution.canonicalWorktreePath.lastPathComponent,
            path: worktreePath.standardizedFileURL,
            canonicalPath: resolution.canonicalWorktreePath,
            gitDirectory: resolution.gitDirectory,
            indexPath: resolution.gitDirectory.appending(path: "index"),
            isMainWorktree: resolution.isMainWorktree,
            isLocked: false,
            lockReason: nil,
            head: nil
        )
    }

    private func repositoryID(for commonDirectory: URL) -> GitRepositoryID {
        GitRepositoryID(rawValue: "common:\(commonDirectory.path)")
    }

    private func resolveGitDirectories(for worktreePath: URL) throws -> GitDirectoryResolution {
        let canonicalWorktreePath = GitPathCanonicalizer.canonicalURL(for: worktreePath)
        let dotGitPath = canonicalWorktreePath.appending(path: ".git")
        let gitDirectory = try resolveGitDirectory(dotGitPath: dotGitPath, worktreePath: canonicalWorktreePath)
        let commonDirectory = try resolveCommonDirectory(gitDirectory: gitDirectory)
        let isMainWorktree = gitDirectory == commonDirectory
        let mainWorktreePath =
            commonDirectory.lastPathComponent == ".git"
            ? commonDirectory.deletingLastPathComponent()
            : nil

        return GitDirectoryResolution(
            canonicalWorktreePath: canonicalWorktreePath,
            gitDirectory: gitDirectory,
            commonDirectory: commonDirectory,
            isMainWorktree: isMainWorktree,
            mainWorktreePath: mainWorktreePath
        )
    }

    private func resolveGitDirectory(dotGitPath: URL, worktreePath: URL) throws -> URL {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dotGitPath.path, isDirectory: &isDirectory) else {
            throw GitRepositoryIdentityResolverError.missingGitDirectory(worktreePath)
        }

        if isDirectory.boolValue {
            return GitPathCanonicalizer.canonicalURL(for: dotGitPath)
        }

        let contents = try String(contentsOf: dotGitPath, encoding: .utf8)
        let prefix = "gitdir:"
        guard contents.lowercased().hasPrefix(prefix) else {
            throw GitRepositoryIdentityResolverError.invalidGitFile(dotGitPath)
        }

        let rawPath = contents.dropFirst(prefix.count).trimmingCharacters(in: .whitespacesAndNewlines)
        let gitDirectory =
            rawPath.hasPrefix("/")
            ? URL(fileURLWithPath: rawPath)
            : worktreePath.appending(path: rawPath)
        return GitPathCanonicalizer.canonicalURL(for: gitDirectory)
    }

    private func resolveCommonDirectory(gitDirectory: URL) throws -> URL {
        let commonDirectoryFile = gitDirectory.appending(path: "commondir")
        guard FileManager.default.fileExists(atPath: commonDirectoryFile.path) else {
            return gitDirectory
        }

        let contents = try String(contentsOf: commonDirectoryFile, encoding: .utf8)
        let rawPath = contents.trimmingCharacters(in: .whitespacesAndNewlines)
        let commonDirectory =
            rawPath.hasPrefix("/")
            ? URL(fileURLWithPath: rawPath)
            : gitDirectory.appending(path: rawPath)
        return GitPathCanonicalizer.canonicalURL(for: commonDirectory)
    }
}

private struct GitDirectoryResolution {
    let canonicalWorktreePath: URL
    let gitDirectory: URL
    let commonDirectory: URL
    let isMainWorktree: Bool
    let mainWorktreePath: URL?
}

public enum GitRepositoryIdentityResolverError: Error, Equatable, Sendable {
    case missingGitDirectory(URL)
    case invalidGitFile(URL)
}
