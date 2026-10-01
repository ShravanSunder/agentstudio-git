import AgentStudioGitContracts
import Foundation
import Testing

@Suite("Git worktree removal contracts")
struct GitWorktreeRemovalContractTests {
    @Test("removal results round-trip observed effects and typed failures")
    func removalResultsRoundTripObservedEffects() throws {
        let worktreeID = GitWorktreeID(rawValue: "common:/tmp/repository/.git|worktree:/tmp/repository/linked")
        let results = [
            GitWorktreeRemovalResult(
                removedWorktreeID: worktreeID,
                effects: GitWorktreeRemovalEffects(
                    administration: .removed,
                    workingDirectory: .removed,
                    failure: nil,
                    lockResidue: []
                )
            ),
            GitWorktreeRemovalResult(
                removedWorktreeID: worktreeID,
                effects: GitWorktreeRemovalEffects(
                    administration: .partial,
                    workingDirectory: .retained,
                    failure: .pruneFailed(code: -1, klass: 7),
                    lockResidue: [URL(fileURLWithPath: "/tmp/repository/.git/config.lock")]
                )
            ),
            GitWorktreeRemovalResult(
                removedWorktreeID: worktreeID,
                effects: GitWorktreeRemovalEffects(
                    administration: .unknown,
                    workingDirectory: .unknown,
                    failure: .observationFailed,
                    lockResidue: []
                )
            ),
            GitWorktreeRemovalResult(
                removedWorktreeID: worktreeID,
                effects: GitWorktreeRemovalEffects(
                    administration: .removed,
                    workingDirectory: .retained,
                    failure: .removalIncomplete,
                    lockResidue: []
                )
            ),
            GitWorktreeRemovalResult(
                removedWorktreeID: worktreeID,
                effects: GitWorktreeRemovalEffects(
                    administration: .removed,
                    workingDirectory: .notRequested,
                    failure: nil,
                    lockResidue: []
                )
            ),
        ]

        #expect(try results.map(roundTrip) == results)
        #expect(
            try [
                GitRemovalEffect.removed,
                .retained,
                .partial,
                .unknown,
                .notRequested,
            ].map(roundTrip) == [
                .removed,
                .retained,
                .partial,
                .unknown,
                .notRequested,
            ]
        )
    }

    @Test("removal effects reject notRequested administration")
    func removalEffectsRejectInvalidAdministration() {
        let malformedPayload = Data(
            #"{"administration":"notRequested","workingDirectory":"removed","failure":null,"lockResidue":[]}"#.utf8
        )

        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(GitWorktreeRemovalEffects.self, from: malformedPayload)
        }
    }

    private func roundTrip<TPayload: Codable & Equatable>(_ payload: TPayload) throws -> TPayload {
        let encoded = try JSONEncoder().encode(payload)
        return try JSONDecoder().decode(TPayload.self, from: encoded)
    }
}
