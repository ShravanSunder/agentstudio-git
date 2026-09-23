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
        mode: GitForkWorktreeMode = .newBranch(name: "fork")
    ) -> GitForkWorktreeRequest {
        GitForkWorktreeRequest(
            sourceWorktreePath: source,
            destinationPath: destination ?? self.destination(),
            mode: mode
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
