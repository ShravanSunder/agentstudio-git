import Foundation

struct GitBranchDeletionFixture {
    let gitFixture: GitFixtureRepository

    var repositoryPath: URL { gitFixture.repositoryPath }
    var root: URL { gitFixture.root }
    var gitDirectory: URL { repositoryPath.appending(path: ".git") }
    var git: GitProcess { gitFixture.git }

    static func make(prefix: String = "agentstudio-git-branch-delete") throws -> Self {
        Self(gitFixture: try GitFixtureRepository.makeRepository(prefix: prefix))
    }

    func makeBranch(_ name: String, at commit: String = "HEAD") throws {
        try git.run("config", "core.logAllRefUpdates", "true")
        try git.run("update-ref", "--create-reflog", "refs/heads/\(name)", commit)
    }

    func addLinkedWorktree(named worktreeName: String, onBranch branchName: String) throws -> URL {
        let worktreePath = root.appending(path: worktreeName)
        try git.run("worktree", "add", worktreePath.path, branchName)
        return worktreePath
    }

    func branchCommit(_ name: String) throws -> String {
        try git.run("rev-parse", "refs/heads/\(name)").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func configValue(_ key: String) throws -> String {
        try git.run("config", "--local", "--get", key).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func localConfiguration() throws -> Data {
        try Data(contentsOf: gitDirectory.appending(path: "config"))
    }

    func reflogPath(for branchName: String) -> URL {
        gitDirectory.appending(path: "logs/refs/heads/\(branchName)")
    }

    func reflogBytes(for branchName: String) throws -> Data? {
        let path = reflogPath(for: branchName)
        guard FileManager.default.fileExists(atPath: path.path) else {
            return nil
        }
        return try Data(contentsOf: path)
    }

    func localReferences() throws -> String {
        try git.run("for-each-ref", "--format=%(refname) %(objectname)", "refs")
    }

    func writeLockFile(_ path: URL) throws {
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("competing lock\n".utf8).write(to: path)
    }

    func remove() {
        gitFixture.remove()
    }
}
