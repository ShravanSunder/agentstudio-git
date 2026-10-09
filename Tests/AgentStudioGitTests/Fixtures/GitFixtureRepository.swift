import Foundation

struct GitFixtureRepository {
    let root: URL
    let repositoryPath: URL
    let git: GitProcess

    static func makeRepository(
        prefix: String = "agentstudio-git-worktree",
        rootDirectory: URL = FileManager.default.temporaryDirectory
    ) throws -> Self {
        let root =
            rootDirectory
            .appending(path: "\(prefix)-\(UUID().uuidString)")
        let repositoryPath = root.appending(path: "repo")
        try FileManager.default.createDirectory(at: repositoryPath, withIntermediateDirectories: true)
        let fixture = Self(root: root, repositoryPath: repositoryPath, git: GitProcess(repositoryPath: repositoryPath))
        try fixture.git.run("init")
        try fixture.write("README.md", contents: "hello\n")
        try fixture.git.run("add", "README.md")
        try fixture.git.run("commit", "-m", "initial")
        return fixture
    }

    func linkedWorktreePath(_ name: String) -> URL {
        root.appending(path: name)
    }

    func addLinkedWorktree(named name: String, branch: String? = nil) throws -> URL {
        let path = linkedWorktreePath(name)
        if let branch {
            try git.run("worktree", "add", "-b", branch, path.path)
        } else {
            try git.run("worktree", "add", path.path)
        }
        return path
    }

    func write(_ relativePath: String, contents: String, in directory: URL? = nil) throws {
        let file = (directory ?? repositoryPath).appending(path: relativePath)
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try contents.write(to: file, atomically: true, encoding: .utf8)
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}

extension GitFixtureRepository {
    /// `url` with every symbolic link resolved (`/var` becomes `/private/var`), the way libgit2 reports paths.
    static func resolvedPath(_ url: URL) -> String {
        guard let resolved = realpath(url.path, nil) else {
            return url.path
        }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    /// A linked worktree on `branch` (created here at `HEAD`) stopped by an add/add conflict while rebasing with
    /// `--merge` onto a commit this adds to the current branch: its `HEAD` is detached and `rebase-merge/head-name`
    /// names `branch`. Returns the worktree and that `rebase-merge` directory.
    func addWorktreeStoppedInRebase(branch: String) throws -> (worktree: URL, rebaseState: URL) {
        let worktree = linkedWorktreePath("\(branch)-rebasing")
        try git.run("worktree", "add", "-q", "-b", branch, worktree.path)
        try write("\(branch)-conflict.txt", contents: "\(branch) side\n", in: worktree)
        try git.run(["add", "."], currentDirectory: worktree)
        try git.run(["commit", "-qm", "\(branch) side"], currentDirectory: worktree)
        try write("\(branch)-conflict.txt", contents: "other side\n")
        try git.run("add", "\(branch)-conflict.txt")
        try git.run("commit", "-qm", "other side of \(branch)")
        let onto = try git.run("rev-parse", "HEAD").trimmingCharacters(in: .whitespacesAndNewlines)
        guard try !git.succeeds("rebase", "--merge", onto, currentDirectory: worktree) else {
            throw CocoaError(.featureUnsupported, userInfo: [NSDebugDescriptionErrorKey: "the rebase did not stop"])
        }
        let gitDirectory = try git.run(["rev-parse", "--absolute-git-dir"], currentDirectory: worktree)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (worktree, URL(fileURLWithPath: gitDirectory).appending(path: "rebase-merge"))
    }
}
