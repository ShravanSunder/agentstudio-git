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

    @Test("malformed public includes still reject trailing escapes and unknown POSIX classes")
    func malformedIncludesRemainTypedErrors() {
        #expect(throws: GitPathPatternError.malformed) { _ = try GitPathPattern("trailing\\") }
        #expect(throws: GitPathPatternError.malformed) { _ = try GitPathPattern("[[:unknown:]]") }
    }

    @Test("public includes reject unescaped comment markers and accept a literal escaped hash")
    func commentMarkersAreTypedErrors() throws {
        #expect(throws: GitPathPatternError.malformed) { _ = try GitPathPattern("#*") }
        #expect(throws: GitPathPatternError.malformed) { _ = try GitPathPattern("#foo") }
        #expect(try GitPathPattern("\\#foo").matches("#foo", isDirectory: false))
    }
}

@Suite("Git path pattern review grammar")
struct GitPathPatternReviewTests {
    @Test("brackets, escapes, middle slash, and wildcard component boundaries match Git")
    func extendedGrammar() throws {
        #expect(try GitPathPattern("*.[oa]").matches("build/file.o", isDirectory: false))
        #expect(try GitPathPattern("Build[0-9]/").matches("Build7", isDirectory: true))
        #expect(try GitPathPattern("[!x].txt").matches("a.txt", isDirectory: false))
        #expect(!(try GitPathPattern("[!x].txt").matches("x.txt", isDirectory: false)))
        #expect(try GitPathPattern("a/b").matches("a/b", isDirectory: true))
        #expect(!(try GitPathPattern("a/b").matches("other/a/b", isDirectory: true)))
        #expect(try GitPathPattern("a/**").matches("a/b/c", isDirectory: false))
        #expect(try GitPathPattern("**/x").matches("x", isDirectory: false))
        #expect(try GitPathPattern("**/x").matches("a/b/x", isDirectory: false))
        #expect(!(try GitPathPattern("foo**bar").matches("foo/a/bar", isDirectory: false)))
        #expect(try GitPathPattern(#"literal\*.txt"#).matches("literal*.txt", isDirectory: false))
        #expect(try GitPathPattern("name   ").matches("name", isDirectory: false))
        #expect(throws: GitPathPatternError.malformed) { _ = try GitPathPattern("/") }
        let mixedCase = try GitPathPattern("Frameworks/")
        #expect(!mixedCase.matches("frameworks", isDirectory: true))
        #expect(mixedCase.matches("frameworks", isDirectory: true, ignoreCase: true))
    }
}
