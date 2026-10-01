import Foundation
import Testing

@testable import AgentStudioGitLocal

@Suite("Git branch integration delta index")
struct GitBranchIntegrationDeltaTests {
    @Test("delta digest collisions still require full exact tuple equality")
    func digestCollisionsRequireFullDeltaEquality() {
        // Arrange
        let firstDelta = GitBranchIntegrationDelta(
            entries: [
                GitBranchIntegrationDeltaEntry(
                    path: [0xff, 0x61],
                    oldMode: 0,
                    oldObjectID: String(repeating: "0", count: 40),
                    newMode: 0o100644,
                    newObjectID: String(repeating: "1", count: 40)
                )
            ]
        )
        let collidingDelta = GitBranchIntegrationDelta(
            entries: [
                GitBranchIntegrationDeltaEntry(
                    path: [0xfe, 0x61],
                    oldMode: 0,
                    oldObjectID: String(repeating: "0", count: 40),
                    newMode: 0o100644,
                    newObjectID: String(repeating: "1", count: 40)
                )
            ]
        )
        var deltaIndex = GitBranchIntegrationDeltaIndex(digest: { _ in Data([0]) })
        deltaIndex.insert(firstDelta, commit: "first-candidate")

        // Act / Assert
        #expect(deltaIndex.matchingCommit(for: collidingDelta) == nil)
        #expect(deltaIndex.matchingCommit(for: firstDelta) == "first-candidate")
    }
}
