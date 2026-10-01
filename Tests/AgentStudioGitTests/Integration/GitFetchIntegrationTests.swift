import AgentStudioGit
import Foundation
import Testing

@Suite("Git fetch integration", .serialized)
struct GitFetchIntegrationTests {
    @Test("one-branch fetch updates only the requested remote-tracking ref")
    func oneBranchFetchIsolatedFromOtherRefsAndHostileConfig() async throws {
        let fixture = try GitFixtureRepository.makeRepository(prefix: "agentstudio-git-single-branch-fetch")
        defer { fixture.remove() }
        let bareRemotePath = fixture.root.appending(path: "origin.git")
        try fixture.git.run("init", "--bare", bareRemotePath.path, currentDirectory: fixture.root)
        try fixture.git.run("remote", "add", "origin", bareRemotePath.path)
        try fixture.git.run("push", "-u", "origin", "main")
        try fixture.git.run("branch", "topic")
        try fixture.git.run("push", "origin", "topic")
        let fetchTargetRepositoryPath = fixture.root.appending(path: "fetch-target")
        try fixture.git.run("clone", bareRemotePath.path, fetchTargetRepositoryPath.path)
        let fetchTargetGit = GitProcess(repositoryPath: fetchTargetRepositoryPath)

        let initialMainCommit = try revision("refs/remotes/origin/main", in: fixture)
        let initialTopicCommit = try revision("refs/remotes/origin/topic", in: fixture)
        try fetchTargetGit.run("update-ref", "refs/remotes/origin/stale", initialMainCommit)
        try fetchTargetGit.run("tag", "local-only-stale", initialMainCommit)

        try fixture.write("default-update.txt", contents: "new default tip\n")
        try fixture.git.run("add", "default-update.txt")
        try fixture.git.run("commit", "-m", "advance default branch")
        let updatedMainCommit = try revision("refs/heads/main", in: fixture)
        try fixture.git.run("push", "origin", "main")

        try fixture.git.run("switch", "topic")
        try fixture.write("topic-update.txt", contents: "new topic tip\n")
        try fixture.git.run("add", "topic-update.txt")
        try fixture.git.run("commit", "-m", "advance topic branch")
        let updatedTopicCommit = try revision("refs/heads/topic", in: fixture)
        try fixture.git.run("push", "origin", "topic")
        try fixture.git.run("tag", "remote-only-tag", updatedMainCommit)
        try fixture.git.run("push", "origin", "refs/tags/remote-only-tag")

        try fetchTargetGit.run("update-ref", "refs/remotes/origin/hostile/stale", initialTopicCommit)
        try fetchTargetGit.run("config", "--unset-all", "remote.origin.fetch")
        try fetchTargetGit.run("config", "--add", "remote.origin.fetch", "+refs/heads/*:refs/remotes/origin/hostile/*")
        try fetchTargetGit.run("config", "fetch.prune", "true")
        try fetchTargetGit.run("config", "fetch.pruneTags", "true")
        try fetchTargetGit.run("config", "remote.origin.tagOpt", "--tags")

        let beforeReferences = try referenceMap(in: fetchTargetRepositoryPath)
        let beforeRemoteHead = try fetchTargetGit.run("symbolic-ref", "refs/remotes/origin/HEAD")
        let client = SystemGitRemoteClient(configuration: .init(allowedProtocols: [.file]))

        let result = try await client.fetch(
            GitFetchRequest(repositoryPath: fetchTargetRepositoryPath, remoteName: "origin", branchName: "main")
        )

        let afterReferences = try referenceMap(in: fetchTargetRepositoryPath)
        let afterRemoteHead = try fetchTargetGit.run("symbolic-ref", "refs/remotes/origin/HEAD")
        let requestedRef = "refs/remotes/origin/main"
        let changedReferences = Set(
            Set(beforeReferences.keys).union(afterReferences.keys).filter { refName in
                beforeReferences[refName] != afterReferences[refName]
            })

        #expect(result.fetchedRemoteName == "origin")
        #expect(result.fetchedCommit == updatedMainCommit)
        #expect(result.lockResidue?.isEmpty == true)
        #expect(changedReferences == Set([requestedRef]))
        #expect(afterRemoteHead == beforeRemoteHead)
        #expect(afterReferences[requestedRef] == updatedMainCommit)
        #expect(updatedTopicCommit != initialTopicCommit)
        #expect(afterReferences["refs/remotes/origin/topic"] == initialTopicCommit)
        #expect(afterReferences["refs/remotes/origin/stale"] == initialMainCommit)
        #expect(afterReferences["refs/remotes/origin/hostile/stale"] == initialTopicCommit)
        #expect(afterReferences["refs/tags/local-only-stale"] == initialMainCommit)
        #expect(afterReferences["refs/tags/remote-only-tag"] == nil)
        #expect(afterReferences["refs/remotes/origin/hostile/main"] == nil)

        let upToDateResult = try await client.fetch(
            GitFetchRequest(repositoryPath: fetchTargetRepositoryPath, remoteName: "origin", branchName: "main")
        )
        #expect(upToDateResult.fetchedCommit == updatedMainCommit)
        #expect(upToDateResult.lockResidue?.isEmpty == true)
    }

    private func revision(_ referenceName: String, in fixture: GitFixtureRepository) throws -> String {
        try fixture.git.run("rev-parse", "--verify", referenceName).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func referenceMap(in repositoryPath: URL) throws -> [String: String] {
        let git = GitProcess(repositoryPath: repositoryPath)
        let output = try git.run("for-each-ref", "--format=%(refname)%00%(objectname)%00%(symref)")
        return Dictionary(
            uniqueKeysWithValues: output.split(whereSeparator: \.isNewline).compactMap { line in
                let fields = line.split(separator: "\0", omittingEmptySubsequences: false)
                guard fields.count == 3 else {
                    return nil
                }
                guard fields[2].isEmpty else {
                    return nil
                }
                return (String(fields[0]), String(fields[1]))
            }
        )
    }
}
