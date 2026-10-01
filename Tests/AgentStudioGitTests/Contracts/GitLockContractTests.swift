import AgentStudioGitContracts
import Foundation
import Testing

@Suite("Git lock contracts")
struct GitLockContractTests {
    @Test("lock facts round-trip with explicit resource cases")
    func lockFactsRoundTripWithExplicitResourceCases() throws {
        let worktreePath = URL(fileURLWithPath: "/tmp/repo/worktree")
        let facts = [
            GitLockFact(
                path: URL(fileURLWithPath: "/tmp/repo/worktree/.git/index.lock"),
                resource: .index(worktreePath: worktreePath)
            ),
            GitLockFact(
                path: URL(fileURLWithPath: "/tmp/repo/.git/refs/heads/topic.lock"),
                resource: .reference(name: "refs/heads/topic")
            ),
            GitLockFact(
                path: URL(fileURLWithPath: "/tmp/repo/.git/packed-refs.lock"),
                resource: .packedRefs
            ),
            GitLockFact(
                path: URL(fileURLWithPath: "/tmp/repo/.git/config.lock"),
                resource: .config
            ),
        ]

        let decodedFacts = try facts.map { fact in
            try JSONDecoder().decode(GitLockFact.self, from: JSONEncoder().encode(fact))
        }

        #expect(decodedFacts == facts)
    }

    @Test("lock errors round-trip without native diagnostic text")
    func lockErrorsRoundTripWithoutNativeDiagnosticText() throws {
        let lockFact = GitLockFact(
            path: URL(fileURLWithPath: "/tmp/repo/.git/refs/heads/topic.lock"),
            resource: .reference(name: "refs/heads/topic")
        )
        let errors: [GitDataPlaneError] = [
            .lockHeld(lockFact),
            .lockUnidentified(.reference(name: "refs/heads/topic")),
            .permissionDenied(path: URL(fileURLWithPath: "/tmp/repo/.git")),
            .permissionDenied(path: nil),
        ]

        for error in errors {
            let encoded = try JSONEncoder().encode(error)
            let decoded = try JSONDecoder().decode(GitDataPlaneError.self, from: encoded)
            let payload = try #require(String(data: encoded, encoding: .utf8))

            #expect(decoded == error)
            #expect(!payload.contains("failed to lock file"))
            #expect(!payload.contains("EACCES"))
        }
    }

    @Test("locked operation failure round-trips its reason and residue")
    func lockedOperationFailureRoundTripsItsReasonAndResidue() throws {
        let failure = GitLockedOperationFailure(
            reason: TestLockedOperationReason.refLockContended,
            lockResidue: [URL(fileURLWithPath: "/tmp/repo/.git/refs/heads/topic.lock")]
        )

        let encodedFailure = try JSONEncoder().encode(failure)
        let decodedFailure = try JSONDecoder().decode(
            GitLockedOperationFailure<TestLockedOperationReason>.self,
            from: encodedFailure
        )

        #expect(decodedFailure == failure)

        let unobservedFailure = GitLockedOperationFailure(
            reason: TestLockedOperationReason.refLockContended,
            lockResidue: nil
        )
        let unobservedPayload = try #require(
            String(data: JSONEncoder().encode(unobservedFailure), encoding: .utf8)
        )
        let decodedUnobservedFailure = try JSONDecoder().decode(
            GitLockedOperationFailure<TestLockedOperationReason>.self,
            from: Data(unobservedPayload.utf8)
        )
        #expect(decodedUnobservedFailure == unobservedFailure)
        #expect(!unobservedPayload.contains("lockResidue"))

        let observedEmptyFailure = GitLockedOperationFailure(
            reason: TestLockedOperationReason.refLockContended,
            lockResidue: []
        )
        let decodedObservedEmptyFailure = try JSONDecoder().decode(
            GitLockedOperationFailure<TestLockedOperationReason>.self,
            from: JSONEncoder().encode(observedEmptyFailure)
        )
        #expect(decodedObservedEmptyFailure == observedEmptyFailure)
    }

    @Test("lock resource decoding rejects multiple active cases")
    func lockResourceDecodingRejectsMultipleActiveCases() {
        let malformedPayload = Data(#"{"config":{},"packedRefs":{}}"#.utf8)

        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(GitLockResource.self, from: malformedPayload)
        }
    }
}

private enum TestLockedOperationReason: String, Codable, Equatable, Sendable {
    case refLockContended
}
