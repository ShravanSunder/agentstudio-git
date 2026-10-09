import AgentStudioGit
import Foundation
import Testing

@Suite("Git creation read contracts")
struct GitCreationReadContractTests {
    private let commit = "0123456789abcdef0123456789abcdef01234567"

    @Test("ahead-behind, branch-use, and remote-probe payloads keep explicit stable wire shapes")
    func creationReadPayloadsKeepStableWireShapes() throws {
        // Arrange
        let repositoryPath = URL(fileURLWithPath: "/tmp/repository")
        let worktreePath = URL(fileURLWithPath: "/tmp/repository.feat")
        let cases: [(any Encodable, String)] = [
            (
                GitAheadBehindRequest(repositoryPath: repositoryPath, localCommit: commit, otherCommit: commit),
                #"{"localCommit":"\#(commit)","otherCommit":"\#(commit)","repositoryPath":"file:\/\/\/tmp\/repository"}"#
            ),
            (GitAheadBehind(ahead: 2, behind: 0), #"{"ahead":2,"behind":0}"#),
            (
                GitBranchUseRequest(repositoryPath: repositoryPath, branchName: "feat"),
                #"{"branchName":"feat","repositoryPath":"file:\/\/\/tmp\/repository"}"#
            ),
            (GitBranchUse.free, #"{"kind":"free"}"#),
            (
                GitBranchUse.inUse(worktreePath: worktreePath),
                #"{"kind":"inUse","worktreePath":"file:\/\/\/tmp\/repository.feat"}"#
            ),
            (
                GitRemoteBranchProbeRequest(repositoryPath: repositoryPath, remoteName: "origin", branchName: "feat"),
                #"{"branchName":"feat","remoteName":"origin","repositoryPath":"file:\/\/\/tmp\/repository"}"#
            ),
            (GitRemoteBranchPresence.present(commit: commit), #"{"commit":"\#(commit)","kind":"present"}"#),
            (GitRemoteBranchPresence.absent, #"{"kind":"absent"}"#),
        ]

        for (payload, expected) in cases {
            // Act
            let actual = try sortedWireText(payload)

            // Assert
            #expect(actual == expected)
        }
        #expect(
            try JSONDecoder().decode(
                GitBranchUse.self, from: JSONEncoder().encode(GitBranchUse.inUse(worktreePath: worktreePath)))
                == .inUse(worktreePath: worktreePath))
        #expect(
            try JSONDecoder().decode(
                GitRemoteBranchPresence.self, from: JSONEncoder().encode(GitRemoteBranchPresence.absent))
                == .absent)
    }

    @Test("creation read decoders reject contradictory or invalid payloads")
    func creationReadDecodersRejectInvalidPayloads() {
        // Arrange
        let invalidAheadBehind = [#"{"ahead":-1,"behind":0}"#, #"{"ahead":0,"behind":-3}"#]
        let invalidBranchUse = [
            #"{"kind":"free","worktreePath":"file:///tmp/x"}"#,
            #"{"kind":"inUse"}"#,
            #"{"kind":"borrowed"}"#,
        ]
        let invalidPresence = [
            #"{"kind":"present"}"#,
            #"{"kind":"present","commit":"main"}"#,
            #"{"kind":"present","commit":"0123456"}"#,
            #"{"kind":"absent","commit":"\#(commit)"}"#,
        ]

        // Act / Assert
        for payload in invalidAheadBehind {
            #expect(throws: DecodingError.self) {
                _ = try JSONDecoder().decode(GitAheadBehind.self, from: Data(payload.utf8))
            }
        }
        for payload in invalidBranchUse {
            #expect(throws: DecodingError.self) {
                _ = try JSONDecoder().decode(GitBranchUse.self, from: Data(payload.utf8))
            }
        }
        for payload in invalidPresence {
            #expect(throws: DecodingError.self) {
                _ = try JSONDecoder().decode(GitRemoteBranchPresence.self, from: Data(payload.utf8))
            }
        }
    }

    private func sortedWireText(_ payload: any Encodable) throws -> String {
        let encoded = try JSONEncoder().encode(payload)
        let jsonValue = try JSONSerialization.jsonObject(with: encoded)
        let sorted = try JSONSerialization.data(withJSONObject: jsonValue, options: [.sortedKeys])
        return try #require(String(data: sorted, encoding: .utf8))
    }
}
