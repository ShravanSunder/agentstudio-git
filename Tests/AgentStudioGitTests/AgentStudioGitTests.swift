import Foundation
import Testing

@testable import AgentStudioGit

@Suite("AgentStudioGit contracts")
struct AgentStudioGitTests {
    @Test("Git status snapshots round-trip through JSON with Unix millisecond timestamps")
    func gitStatusSnapshotCodableRoundTrip() throws {
        let snapshot = GitStatusSnapshot(
            repositoryRootPath: "/tmp/example",
            generatedAtUnixMilliseconds: 1_781_053_200_000,
            branchName: "main",
            headCommitSha: "abc123",
            changes: [
                GitFileChange(
                    path: "Sources/App.swift",
                    previousPath: nil,
                    kind: .modified,
                    isStaged: false,
                    isBinary: false,
                    additions: 12,
                    deletions: 3
                )
            ]
        )

        let data = try JSONEncoder().encode(snapshot)
        let decodedSnapshot = try JSONDecoder().decode(GitStatusSnapshot.self, from: data)

        #expect(decodedSnapshot == snapshot)
        #expect(decodedSnapshot.generatedAtUnixMilliseconds == 1_781_053_200_000)
    }

    @Test("Git commands keep explicit discriminators for wire boundaries")
    func gitCommandUsesExplicitKindDiscriminator() throws {
        let command = GitCommand(
            id: "command-1",
            kind: .diff,
            repositoryRootPath: "/tmp/example",
            baseTarget: .head,
            compareTarget: .workingTree
        )

        let jsonObject = try JSONSerialization.jsonObject(with: JSONEncoder().encode(command))
        let dictionary = try #require(jsonObject as? [String: Any])

        #expect(dictionary["kind"] as? String == "diff")
        #expect(dictionary["repositoryRootPath"] as? String == "/tmp/example")
    }
}
