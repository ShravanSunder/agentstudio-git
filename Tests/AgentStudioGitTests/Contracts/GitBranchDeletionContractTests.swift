import AgentStudioGitContracts
import Foundation
import Testing

@Suite("Git branch deletion contracts")
struct GitBranchDeletionContractTests {
    @Test("branch deletion requests, results, and reasons round-trip with explicit tags")
    func branchDeletionPayloadsRoundTripWithExplicitTags() throws {
        // Arrange
        let repositoryPath = URL(fileURLWithPath: "/tmp/repository")
        let referenceLock = URL(fileURLWithPath: "/tmp/repository/.git/refs/heads/topic.lock")
        let request = GitDeleteLocalBranchRequest(
            repositoryPath: repositoryPath,
            branchName: "topic",
            expectedCommit: "0123456789abcdef0123456789abcdef01234567"
        )
        let cleanup = GitBranchMetadataCleanup(
            configuration: .removed,
            reflog: .leftInPlace(.reservationUnavailable)
        )
        let results: [GitDeleteLocalBranchResult] = [
            .deleted(cleanup: cleanup, lockResidue: []),
            .retained(reason: .notFound, lockResidue: [referenceLock]),
            .retained(
                reason: .moved(currentCommit: "89abcdef0123456789abcdef0123456789abcdef"),
                lockResidue: []
            ),
            .retained(reason: .checkedOut(worktreePaths: [repositoryPath]), lockResidue: []),
            .uncertain(error: .lockUnidentified(.packedRefs), lockResidue: [referenceLock]),
        ]
        let errorReasons: [GitDeleteLocalBranchErrorReason] = [
            .invalidBranchName,
            .refLockContended,
            .checkoutUnreadable(worktreePath: repositoryPath),
            .checkoutUnreadable(worktreePath: nil),
            .notADirectCommitReference,
            .gitFailure(
                .lockHeld(
                    GitLockFact(path: referenceLock, resource: .reference(name: "refs/heads/topic"))
                )),
        ]

        // Act / Assert
        #expect(try roundTrip(request) == request)
        #expect(try roundTrip(cleanup) == cleanup)
        #expect(try results.map(roundTrip) == results)
        #expect(try errorReasons.map(roundTrip) == errorReasons)
    }

    @Test("branch deletion decoders reject contradictory tagged payloads")
    func branchDeletionDecodersRejectContradictoryPayloads() {
        // Arrange
        let invalidResults = [
            #"{"kind":"deleted","cleanup":{"configuration":"removed","reflog":"absent"},"reason":"notFound","lockResidue":[]}"#,
            #"{"kind":"retained","lockResidue":[]}"#,
            #"{"kind":"uncertain","error":{"unsupported":{"message":"failure"}},"lockResidue":[],"reason":"notFound"}"#,
            #"{"kind":"future","lockResidue":[]}"#,
        ]
        let invalidReasons = [
            #"{"kind":"invalidBranchName","worktreePath":"file:///tmp/repository"}"#,
            #"{"kind":"checkoutUnreadable","error":{"unsupported":{"message":"failure"}}}"#,
            #"{"kind":"futureReason"}"#,
        ]

        // Act / Assert
        for json in invalidResults {
            #expect(throws: DecodingError.self) {
                _ = try JSONDecoder().decode(GitDeleteLocalBranchResult.self, from: Data(json.utf8))
            }
        }
        for json in invalidReasons {
            #expect(throws: DecodingError.self) {
                _ = try JSONDecoder().decode(GitDeleteLocalBranchErrorReason.self, from: Data(json.utf8))
            }
        }
    }

    private func roundTrip<TPayload: Codable & Equatable>(_ payload: TPayload) throws -> TPayload {
        let encoded = try JSONEncoder().encode(payload)
        return try JSONDecoder().decode(TPayload.self, from: encoded)
    }
}
