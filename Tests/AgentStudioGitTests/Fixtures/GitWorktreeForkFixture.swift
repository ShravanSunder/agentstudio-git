import AgentStudioGit
import Darwin
import Foundation
import Testing

/// Real-Git oracle helpers for Worktree Fork tests. Assertions read destination state through the `git`
/// CLI and Darwin metadata, never through the SDK's own status reader.
struct GitWorktreeForkFixture {
    let repository: GitFixtureRepository

    var source: URL {
        repository.repositoryPath
    }

    var git: GitProcess {
        repository.git
    }

    static func make(prefix: String) throws -> Self {
        Self(repository: try GitFixtureRepository.makeRepository(prefix: prefix))
    }

    func destination(_ name: String = "fork") -> URL {
        repository.root.appending(path: name)
    }

    func request(
        destination: URL? = nil,
        mode: GitForkWorktreeMode = .newBranch(name: "fork", start: .sourceHead, upstream: nil),
        materialization: GitWorktreeForkMaterialization = .copyOnWrite,
        copyRules: GitWorktreeCopyRules = GitWorktreeCopyRules(ignoredPaths: .copyAll)
    ) -> GitForkWorktreeRequest {
        GitForkWorktreeRequest(
            sourceWorktreePath: source,
            destinationPath: destination ?? self.destination(),
            mode: mode,
            materialization: materialization,
            copyRules: copyRules
        )
    }

    /// `git status --porcelain=v1 --ignored`, sorted, with index writes disabled so the oracle itself does
    /// not refresh the index it is observing.
    func statusLines(at worktree: URL) throws -> [String] {
        let output = try git.run(
            ["-c", "core.untrackedCache=false", "--no-optional-locks", "status", "--porcelain=v1", "--ignored"],
            currentDirectory: worktree
        )
        return output.split(separator: "\n").map(String.init).sorted()
    }

    /// Parses `git ls-files --debug` into per-path cached stat data.
    func indexStat(at worktree: URL) throws -> [String: GitIndexStatOracle] {
        let output = try git.run(["ls-files", "--debug"], currentDirectory: worktree)
        var result: [String: GitIndexStatOracle] = [:]
        var currentPath: String?
        var mtimeSeconds: Int64 = 0
        var inode: UInt64 = 0
        for rawLine in output.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            if !line.hasPrefix(" "), !line.isEmpty {
                currentPath = line
                continue
            }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("mtime:") {
                let seconds = trimmed.dropFirst("mtime:".count).split(separator: ":").first ?? ""
                mtimeSeconds = Int64(seconds.trimmingCharacters(in: .whitespaces)) ?? 0
            } else if trimmed.hasPrefix("dev:") {
                inode =
                    UInt64(trimmed.components(separatedBy: "ino:").last?.trimmingCharacters(in: .whitespaces) ?? "")
                    ?? 0
            } else if trimmed.hasPrefix("size:"), let currentPath {
                let size =
                    Int64(
                        trimmed.dropFirst("size:".count).split(separator: "\t").first?
                            .trimmingCharacters(in: .whitespaces) ?? "") ?? 0
                result[currentPath] = GitIndexStatOracle(mtimeSeconds: mtimeSeconds, inode: inode, size: size)
            }
        }
        return result
    }

    func blobID(_ spec: String, at worktree: URL) throws -> String {
        try git.run(["rev-parse", spec], currentDirectory: worktree).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func stagedBlobID(_ path: String, at worktree: URL) throws -> String {
        let line = try git.run(["ls-files", "-s", "--", path], currentDirectory: worktree)
        return line.split(separator: " ").dropFirst().first.map(String.init) ?? ""
    }

    func branchNames() throws -> [String] {
        try git.run("for-each-ref", "--format=%(refname)", "refs/heads").split(separator: "\n").map(String.init)
            .sorted()
    }

    func linkedWorktreeAdministration(_ name: String = "fork") -> URL {
        source.appending(path: ".git/worktrees/\(name)")
    }

    func write(_ relativePath: String, _ contents: String, in directory: URL? = nil) throws {
        try repository.write(relativePath, contents: contents, in: directory)
    }

    func remove() {
        repository.remove()
    }

    /// Adds and commits a submodule at `relativePath`, cloned from a new repository outside the source; its
    /// administration lives in the source's `.git/modules`. Returns the source working tree.
    @discardableResult
    func addSubmodule(at relativePath: String, file: String = "tool.txt") throws -> URL {
        let origin = repository.root.appending(path: "origins").appending(path: relativePath)
        try FileManager.default.createDirectory(at: origin, withIntermediateDirectories: true)
        try git.run(["init", "-q"], currentDirectory: origin)
        try write(file, "\(file)\n", in: origin)
        try git.run(["add", "."], currentDirectory: origin)
        try git.run(["commit", "-qm", "initial"], currentDirectory: origin)
        try git.run("submodule", "add", "-q", "-f", origin.path, relativePath)
        try git.run("commit", "-qm", "submodule \(relativePath)")
        return source.appending(path: relativePath)
    }

    /// Commits the nested working tree at `relativePath` as a gitlink, so the fork re-homes it as a registered
    /// submodule however its `.git` was made. A linked worktree of an outside repository registered this way is
    /// a submodule whose worktree-private administration differs from its common administration.
    func registerSubmodule(at relativePath: String) throws {
        try git.run("-c", "advice.addEmbeddedRepo=false", "add", "-f", relativePath)
        try git.run("commit", "-qm", "register \(relativePath)")
    }

    /// The canonical administration Git opens for `worktree`.
    func gitDirectory(of worktree: URL) throws -> URL {
        let path = try git.run(["rev-parse", "--absolute-git-dir"], currentDirectory: worktree)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let resolved = try #require(realpath(path, nil))
        defer { free(resolved) }
        return URL(fileURLWithPath: String(cString: resolved))
    }

    /// An outside repository whose linked worktrees nested in the source become submodules once registered.
    /// It is outside the copied tree, so only its nested linked working trees enter the filesystem plan.
    func makeIndependentWorktreeRepository() throws -> URL {
        let origin = repository.root.appending(path: "nested-origin")
        try FileManager.default.createDirectory(at: origin, withIntermediateDirectories: true)
        try git.run(["init", "-q"], currentDirectory: origin)
        try write("nested.txt", "independent repository\n", in: origin)
        try git.run(["add", "."], currentDirectory: origin)
        try git.run(["commit", "-qm", "independent initial"], currentDirectory: origin)
        return origin
    }
}

/// One entry of `GitWorktreeForkFileProbe.contentTree(at:)`.
struct GitWorktreeForkCopiedEntry: Equatable {
    enum Kind: Equatable {
        case directory
        case symbolicLink
        case file
    }

    let kind: Kind
    let permissions: mode_t
    let bytes: Data
}

struct GitIndexStatOracle: Equatable {
    let mtimeSeconds: Int64
    let inode: UInt64
    let size: Int64
}

enum GitWorktreeForkFileProbe {
    static func info(_ url: URL) -> Darwin.stat? {
        var info = Darwin.stat()
        return url.path.withCString { lstat($0, &info) } == 0 ? info : nil
    }

    /// Every entry beneath `root`, `.git` included, by relative path: its kind, permission bits, and bytes
    /// (link text for a symlink). Two equal snapshots are byte-for-byte copies of one another.
    static func contentTree(at root: URL) throws -> [String: GitWorktreeForkCopiedEntry] {
        var entries: [String: GitWorktreeForkCopiedEntry] = [:]
        var pending = [""]
        while let relativePath = pending.popLast() {
            let directory = relativePath.isEmpty ? root : root.appending(path: relativePath)
            for name in try FileManager.default.contentsOfDirectory(atPath: directory.path) {
                let childPath = relativePath.isEmpty ? name : "\(relativePath)/\(name)"
                let child = root.appending(path: childPath)
                let info = try #require(Self.info(child))
                let permissions = info.st_mode & 0o7777
                switch info.st_mode & S_IFMT {
                case S_IFDIR:
                    entries[childPath] = GitWorktreeForkCopiedEntry(
                        kind: .directory, permissions: permissions, bytes: Data())
                    pending.append(childPath)
                case S_IFLNK:
                    let target = try FileManager.default.destinationOfSymbolicLink(atPath: child.path)
                    entries[childPath] = GitWorktreeForkCopiedEntry(
                        kind: .symbolicLink, permissions: 0, bytes: Data(target.utf8))
                default:
                    entries[childPath] = GitWorktreeForkCopiedEntry(
                        kind: .file, permissions: permissions, bytes: try Data(contentsOf: child))
                }
            }
        }
        return entries
    }

    static func exists(_ url: URL) -> Bool {
        info(url) != nil
    }

    /// APFS bytes not shared with any clone (`ATTR_CMNEXT_PRIVATESIZE`). A fresh clone reports ~0.
    static func privateSize(_ url: URL) -> Int64? {
        var attributes = attrlist()
        attributes.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        attributes.forkattr = attrgroup_t(ATTR_CMNEXT_PRIVATESIZE)
        var buffer = [UInt8](repeating: 0, count: 64)
        let result = url.path.withCString { path in
            buffer.withUnsafeMutableBytes { bytes in
                getattrlist(
                    path, &attributes, bytes.baseAddress, bytes.count, UInt32(FSOPT_ATTR_CMN_EXTENDED | FSOPT_NOFOLLOW))
            }
        }
        guard result == 0 else {
            return nil
        }
        return buffer.withUnsafeBytes { bytes in
            bytes.loadUnaligned(fromByteOffset: MemoryLayout<UInt32>.size, as: Int64.self)
        }
    }
}
