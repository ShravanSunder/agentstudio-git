import AgentStudioGit
import Foundation
import Testing

@testable import AgentStudioGitLocal

extension GitReviewDataIntegrationTests {
    @Test("candidate assembly rejects duplicate out-of-scope and incompatible rows")
    func candidateAssemblyRejectsAmbiguousRows() {
        // Arrange
        let calculator = LibGit2ReviewRefreshCalculator()
        let modified = candidateAssemblerFile(path: "tracked-a.txt", changeKind: .modified)
        let outOfScope = candidateAssemblerFile(path: "other.txt", changeKind: .modified)
        let copiedPredecessor = candidateAssemblerFile(path: "tracked-a.txt", changeKind: .copied)
        let duplicateSeed = [
            modified,
            candidateAssemblerFile(path: "tracked-a.txt", changeKind: .modified),
        ]
        var cases: [(LibGit2ProportionalReviewAttempt, GitReviewCalculationReason)] = [
            (
                calculator.assembleCandidate(
                    seedFiles: [],
                    changedPaths: ["tracked-a.txt"],
                    scopedFiles: [modified, modified]
                ),
                .duplicateScopedRow
            ),
            (
                calculator.assembleCandidate(
                    seedFiles: [],
                    changedPaths: ["tracked-a.txt"],
                    scopedFiles: [outOfScope]
                ),
                .outOfScopeScopedRow
            ),
            (
                calculator.assembleCandidate(
                    seedFiles: [copiedPredecessor],
                    changedPaths: ["tracked-a.txt"],
                    scopedFiles: [modified]
                ),
                .incompatiblePredecessorRow
            ),
            (
                calculator.assembleCandidate(
                    seedFiles: duplicateSeed,
                    changedPaths: ["tracked-a.txt"],
                    scopedFiles: [modified]
                ),
                .candidatePathCollision
            ),
        ]
        for changeKind in [
            GitDiffChangeKind.added,
            .copied,
            .deleted,
            .renamed,
            .typeChanged,
            .unmerged,
        ] {
            cases.append(
                (
                    calculator.assembleCandidate(
                        seedFiles: [],
                        changedPaths: ["tracked-a.txt"],
                        scopedFiles: [candidateAssemblerFile(path: "tracked-a.txt", changeKind: changeKind)]
                    ),
                    .ineligibleScopedRow
                ))
        }

        // Act / Assert
        for (attempt, expectedReason) in cases {
            switch attempt {
            case .accepted:
                Issue.record("ambiguous candidate unexpectedly received proportional acceptance")
            case .requiresComplete(let reason):
                #expect(reason == expectedReason)
            }
        }
    }

    @Test("candidate assembly handles large predecessor and affected-path sets exactly")
    func candidateAssemblyHandlesLargePredecessorAndAffectedPathSets() throws {
        // Arrange
        let seedFiles = (0..<4096).map { index in
            candidateAssemblerFile(path: String(format: "file-%04d.txt", index), newHash: "seed-\(index)")
        }
        let changedPaths = (0..<128).map { String(format: "file-%04d.txt", $0 * 17) }
        let scopedFiles = changedPaths.enumerated().map { offset, path in
            candidateAssemblerFile(path: path, newHash: "replacement-\(offset)")
        }

        // Act
        let attempt = LibGit2ReviewRefreshCalculator().assembleCandidate(
            seedFiles: seedFiles,
            changedPaths: changedPaths,
            scopedFiles: scopedFiles
        )

        // Assert
        switch attempt {
        case .requiresComplete(let reason):
            Issue.record("large safe candidate unexpectedly required complete calculation: \(reason)")
        case .accepted(let snapshot):
            #expect(snapshot.files.count == seedFiles.count)
            #expect(snapshot.files.map(\.path) == snapshot.files.map(\.path).sorted())
            let filesByPath = Dictionary(uniqueKeysWithValues: snapshot.files.map { ($0.path, $0) })
            for (offset, path) in changedPaths.enumerated() {
                #expect(filesByPath[path]?.newContentHash == "replacement-\(offset)")
            }
            #expect(filesByPath["file-4095.txt"]?.newContentHash == "seed-4095")
        }
    }
}

private func candidateAssemblerFile(
    path: String,
    changeKind: GitDiffChangeKind = .modified,
    newHash: String = "new"
) -> GitDiffFile {
    GitDiffFile(
        fileId: "gitdiff:none:\(path):old:new",
        path: path,
        previousPath: nil,
        changeKind: changeKind,
        oldContentHash: "old",
        newContentHash: newHash,
        contentHashAlgorithm: "git-blob-sha1",
        oldMode: 0o100644,
        newMode: 0o100644,
        additions: 1,
        deletions: 1,
        isBinary: false,
        sizeBytes: 8
    )
}
