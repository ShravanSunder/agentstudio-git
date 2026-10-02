import AgentStudioGit
import Foundation
import Testing

@Suite("Git large-file fill contracts")
struct GitLargeFileFillContractTests {
    @Test("creation results round-trip every typed miss and index-update cause")
    func creationResultsRoundTripTypedFillOutcomes() throws {
        // Arrange
        let worktreePath = URL(fileURLWithPath: "/tmp/large-file-worktree", isDirectory: true)
        let lockFact = GitLockFact(
            path: URL(fileURLWithPath: "/tmp/large-file-worktree/.git/index.lock"),
            resource: .index(worktreePath: worktreePath)
        )
        let fillResults = [
            GitLargeFileFill(
                materializedCount: 2,
                missing: [
                    GitLargeFileFillMiss(path: "missing.bin", reason: .objectAbsent),
                    GitLargeFileFillMiss(path: "wrong.bin", reason: .objectMismatch),
                    GitLargeFileFillMiss(path: "unreadable.bin", reason: .readFailed(errno: 13)),
                    GitLargeFileFillMiss(path: "unwritable.bin", reason: .writeFailed(errno: 28)),
                ],
                indexUpdate: .updated
            ),
            GitLargeFileFill(materializedCount: 1, missing: [], indexUpdate: .skipped(.lockHeld(lockFact))),
            GitLargeFileFill(
                materializedCount: 0,
                missing: [],
                indexUpdate: .skipped(.lockUnidentified(.index(worktreePath: worktreePath)))
            ),
            GitLargeFileFill(materializedCount: 0, missing: [], indexUpdate: .skipped(.permissionDenied(path: nil))),
            GitLargeFileFill(
                materializedCount: 0,
                missing: [],
                indexUpdate: .skipped(
                    .gitFailure(.indexWriteFailed)
                )
            ),
        ]
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let result = GitWorktreeCreation(
            worktree: worktreeSnapshot(at: worktreePath),
            largeFiles: fillResults[0]
        )

        // Act
        let encodedResults = try fillResults.map { try encoder.encode($0) }
        let decodedResults = try encodedResults.map { try JSONDecoder().decode(GitLargeFileFill.self, from: $0) }
        let encodedCreation = try encoder.encode(result)
        let decodedCreation = try JSONDecoder().decode(GitWorktreeCreation.self, from: encodedCreation)

        // Assert
        #expect(decodedResults == fillResults)
        #expect(decodedCreation == result)
        #expect(String(data: encodedResults[0], encoding: .utf8)?.contains("\"kind\":\"objectAbsent\"") == true)
        #expect(String(data: encodedResults[1], encoding: .utf8)?.contains("\"lockHeld\"") == true)
        #expect(String(data: encodedCreation, encoding: .utf8)?.contains("\"largeFiles\"") == true)
    }

    @Test("fill result decoding rejects invalid counts, duplicate paths, and incomplete index outcomes")
    func fillResultsRejectInvalidPayloads() throws {
        // Arrange
        let invalidPayloads = [
            #"{"materializedCount":-1,"missing":[],"indexUpdate":{"kind":"updated"}}"#,
            #"{"materializedCount":0,"missing":[{"path":"asset.bin","reason":{"kind":"objectAbsent"}},{"path":"asset.bin","reason":{"kind":"objectMismatch"}}],"indexUpdate":{"kind":"updated"}}"#,
            #"{"materializedCount":0,"missing":[],"indexUpdate":{"kind":"skipped"}}"#,
            #"{"materializedCount":0,"missing":[{"path":"asset.bin","reason":{"kind":"readFailed","errno":0}}],"indexUpdate":{"kind":"updated"}}"#,
        ]

        // Act / Assert
        for payload in invalidPayloads {
            #expect(throws: DecodingError.self) {
                _ = try JSONDecoder().decode(GitLargeFileFill.self, from: Data(payload.utf8))
            }
        }
        #expect(throws: EncodingError.self) {
            try JSONEncoder().encode(GitLargeFileFillMissReason.readFailed(errno: 0))
        }
    }

    private func worktreeSnapshot(at path: URL) -> GitWorktreeSnapshot {
        GitWorktreeSnapshot(
            id: GitWorktreeID(rawValue: "worktree-id"),
            repositoryID: GitRepositoryID(rawValue: "repository-id"),
            displayName: "large-file-worktree",
            path: path,
            canonicalPath: path,
            gitDirectory: path.appending(path: ".git"),
            indexPath: path.appending(path: ".git/index"),
            isMainWorktree: false,
            isLocked: false,
            lockReason: nil,
            head: nil
        )
    }
}
