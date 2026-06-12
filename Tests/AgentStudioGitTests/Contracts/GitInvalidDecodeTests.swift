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
}
