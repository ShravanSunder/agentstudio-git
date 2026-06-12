import Foundation

struct GitFixtureRepository {
    let root: URL
    let repositoryPath: URL
    let git: GitProcess

    static func makeRepository(prefix: String = "agentstudio-git-worktree") throws -> Self {
        let root = FileManager.default.temporaryDirectory
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
