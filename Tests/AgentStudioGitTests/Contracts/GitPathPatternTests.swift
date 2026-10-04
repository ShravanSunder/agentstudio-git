import AgentStudioGitContracts
import Testing

@Suite("Git path patterns")
struct GitPathPatternTests {
    @Test("wildcards, recursive wildcards, anchors, and directory-only patterns match")
    func grammarMatchesExpectedPaths() throws {
        let star = try GitPathPattern("*.log")
        #expect(star.matches("logs/build.log", isDirectory: false))
        #expect(!star.matches("logs/build.txt", isDirectory: false))

        let recursive = try GitPathPattern("/cache/**/output?")
        #expect(recursive.matches("cache/output1", isDirectory: false))
        #expect(recursive.matches("cache/a/b/output2", isDirectory: false))

        let directory = try GitPathPattern("vendor/")
        #expect(directory.matches("vendor", isDirectory: true))
        #expect(!directory.matches("vendor", isDirectory: false))

        let anchored = try GitPathPattern("/build")
        #expect(anchored.matches("build", isDirectory: true))
        #expect(!anchored.matches("src/build", isDirectory: true))
    }

    @Test("negation and malformed patterns are rejected with typed errors")
    func invalidPatternsFailClosed() {
        #expect(throws: GitPathPatternError.negationNotSupported) {
            _ = try GitPathPattern("!cache/")
        }
        #expect(throws: GitPathPatternError.empty) {
            _ = try GitPathPattern("")
        }
    }
}
