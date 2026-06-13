import AgentStudioGit
import Foundation
import Testing

@Suite("Git invalid decode behavior")
struct GitInvalidDecodeTests {
    @Test("unknown wire enum values throw")
    func unknownWireEnumValuesThrow() {
        let data = Data(#""teleported""#.utf8)

        #expect(throws: DecodingError.self) {
            _ = try JSONDecoder().decode(GitStatusState.self, from: data)
        }
    }

    @Test("diff files require stable file ids")
    func diffFilesRequireStableFileIds() {
        let data = Data(
            """
            {
              "path": "Sources/App.swift",
              "changeKind": "modified",
              "contentHashAlgorithm": "git-blob-sha1",
              "additions": 1,
              "deletions": 0,
              "isBinary": false,
              "sizeBytes": 42
            }
            """.utf8
        )

        #expect(throws: DecodingError.self) {
            _ = try JSONDecoder().decode(GitDiffFile.self, from: data)
        }
    }

    @Test("diff targets require identifiers only for commit targets")
    func diffTargetsRequireIdentifiersOnlyForCommitTargets() {
        let missingCommitIdentifier = Data(
            """
            {
              "kind": "commit"
            }
            """.utf8
        )
        let nonCommitIdentifier = Data(
            """
            {
              "kind": "workingTree",
              "identifier": "abc123"
            }
            """.utf8
        )

        #expect(throws: DecodingError.self) {
            _ = try JSONDecoder().decode(GitDiffTarget.self, from: missingCommitIdentifier)
        }
        #expect(throws: DecodingError.self) {
            _ = try JSONDecoder().decode(GitDiffTarget.self, from: nonCommitIdentifier)
        }
    }

    @Test("data plane errors reject ambiguous multi-case payloads")
    func dataPlaneErrorsRejectAmbiguousMultiCasePayloads() {
        let data = Data(
            """
            {
              "repositoryNotFound": {
                "path": "file:///tmp/agentstudio-git-missing"
              },
              "unsupported": {
                "message": "ambiguous"
              }
            }
            """.utf8
        )

        #expect(throws: DecodingError.self) {
            _ = try JSONDecoder().decode(GitDataPlaneError.self, from: data)
        }
    }
}
