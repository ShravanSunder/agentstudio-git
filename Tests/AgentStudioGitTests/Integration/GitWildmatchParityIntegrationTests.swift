import AgentStudioGit
import Foundation
import Testing

@testable import AgentStudioGitLocal

/// One extensible table compares the public parser with native Git, including byte-oriented paths.
@Suite("Git path pattern native Git parity", .serialized)
struct GitPathPatternNativeParityTests {
    @Test("native oracle gates only glued double stars before Git 2.52")
    func oracleVersionBoundary() throws {
        for version in ["git version 2.50.1 (Apple Git-155)", "git version 2.51.0"] {
            #expect(!(try GitNativePatternOracle(version: version)).supportsModernPrefixContext)
        }
        for version in ["git version 2.52.0", "git version 2.55.0", "git version 3.0.0"] {
            #expect(try GitNativePatternOracle(version: version).supportsModernPrefixContext)
        }
        #expect(throws: GitNativePatternOracle.DetectionFailure.self) {
            _ = try GitNativePatternOracle(version: "unrecognized")
        }
        let old = try GitNativePatternOracle(version: "git version 2.50.1")
        let modern = try GitNativePatternOracle(version: "git version 2.52.0")
        for pattern in ["foo**/bar", "x/foo**/bar", #"foo**\/bar"#, "!!**/foo", "a?b**/c"] {
            #expect(!old.canCompare(pattern))
            #expect(modern.canCompare(pattern))
        }
        for pattern in ["**/foo", "foo/**/bar", "[**]/foo", "[[:digit:]]**/bar"] {
            #expect(old.canCompare(pattern))
        }
    }

    struct PatternCase: Sendable {
        let pattern: String
        let path: String
        var isDirectory = false
        var ignoreCase = false
        var modernExpected: Bool?
    }

    static let cases: [PatternCase] = [
        .init(pattern: "cache/**/output", path: "cache/a\nb/output"),
        .init(pattern: "cache/**/output", path: "cache/a/output\n"),
        .init(pattern: "cache/*/output", path: "cache/a\nb/output"),
        .init(pattern: "cache/?/output", path: "cache/é/output"),
        .init(pattern: "cache/??/output", path: "cache/é/output"),
        .init(pattern: "cache/?/output", path: "cache/\n/output"),
        .init(pattern: "literal", path: "literal\n"),
        .init(pattern: "*.txt", path: "name.txt\n"),
        .init(pattern: "cache/**/output", path: "cache/output"),
        .init(pattern: "cache/**/output", path: "cache/a/b/output"),
        .init(pattern: #"cache/**\/output"#, path: "cache/a/b/output"),
        .init(pattern: #"cache/**\/output"#, path: "cache/output"),
        .init(pattern: "cache/**/**/output", path: "cache/output"),
        .init(pattern: "cache/**/**/output", path: "cache/a/b/output"),
        .init(pattern: "cache/*/output", path: "cache/a/b/output"),
        .init(pattern: "cache/**", path: "cache/a\nb/file"),
        .init(pattern: "**/x", path: "x"),
        .init(pattern: "**/x", path: "a/b/x"),
        .init(pattern: "foo**bar", path: "foo/a/bar", modernExpected: false),
        .init(pattern: "foo**bar", path: "fooabbar", modernExpected: true),
        .init(pattern: "*.[oa]", path: "build/file.o"),
        .init(pattern: "[!a-c]x", path: "dx"),
        .init(pattern: "[^a-c]x", path: "bx"),
        .init(pattern: "[]]x", path: "]x"),
        .init(pattern: "[a[]x", path: "[x"),
        .init(pattern: "[&&]x", path: "&x"),
        .init(pattern: "[z-a]x", path: "zx"),
        .init(pattern: "[z-a]x", path: "mx"),
        .init(pattern: "[[:digit:]]x", path: "7x"),
        .init(pattern: "[[:alpha:]]x", path: "éx"),
        .init(pattern: "[[:space:]]x", path: "\nx"),
        .init(pattern: "[[:punct:]]x", path: "!x"),
        .init(pattern: "a/b", path: "a/b"),
        .init(pattern: "a/b", path: "other/a/b"),
        .init(pattern: "/root", path: "other/root"),
        .init(pattern: "root", path: "other/root"),
        .init(pattern: "build/", path: "other/build", isDirectory: true),
        .init(pattern: "build/", path: "build", isDirectory: false),
        .init(pattern: "Frameworks/", path: "frameworks", isDirectory: true, ignoreCase: true),
        .init(pattern: "Frameworks/", path: "frameworks", isDirectory: true, ignoreCase: false),
        .init(pattern: "É.txt", path: "é.txt", ignoreCase: true),
        .init(pattern: "[A-Z]x", path: "ax", ignoreCase: true),
        .init(pattern: "[[:upper:]]x", path: "ax", ignoreCase: true),
        .init(pattern: #"literal\*.txt"#, path: "literal*.txt"),
        .init(pattern: #"\!secret.txt"#, path: "!secret.txt"),
        .init(pattern: "name   ", path: "name"),
        .init(pattern: #"name\ "#, path: "name "),
        .init(pattern: " space", path: " space"),
        .init(pattern: "[A]x", path: "Ax", ignoreCase: true),
        .init(pattern: "[A]x", path: "ax", ignoreCase: true),
        .init(pattern: #"[\A]x"#, path: "Ax", ignoreCase: true),
        .init(pattern: #"\A.txt"#, path: "A.txt", ignoreCase: true),
        .init(pattern: #"*\A.txt"#, path: "A.txt", ignoreCase: true),
        .init(pattern: "A.txt", path: "a.txt", ignoreCase: true),
        .init(pattern: "[é]x", path: "éx"),
        .init(pattern: "*a*b*c", path: "aaaa/abc"),
        .init(pattern: "a/**/b*c/d", path: "a/x/babc/d"),
        .init(pattern: "a/**/b*c/d", path: "a/bad/x/babc/d"),
        .init(pattern: "a/**b/d", path: "a/x/b/d"),
        .init(pattern: "a/***/d", path: "a/x/y/d"),
        .init(pattern: #"a/*\/d"#, path: "a/x/d"),
        .init(pattern: #"a/*\/d"#, path: "a/x/y/d"),
        .init(pattern: "[]-]x", path: "-x"),
        .init(pattern: "[a-b-c]x", path: "-x"),
        .init(pattern: "[a-b-c]x", path: "cx"),
        .init(pattern: "/\u{0301}name", path: "\u{0301}name"),
        .init(pattern: "a/\u{0301}name", path: "a/\u{0301}name"),
        .init(pattern: #"\!́name"#, path: "!\u{0301}name"),
        // Recorded Git >=2.52 expectations: 1940a02dc1 retains one byte of prefix context.
        .init(pattern: "foo**/bar", path: "foo/bar", modernExpected: true),
        .init(pattern: "foo**/bar", path: "foox/y/bar", modernExpected: false),
        .init(pattern: "foo**/bar", path: "foobar", modernExpected: false),
        .init(pattern: "x/foo**/bar", path: "x/fooq/r/bar", modernExpected: false),
        .init(pattern: #"foo**\/bar"#, path: "foox/y/bar", modernExpected: false),
        .init(pattern: "a?b**/c", path: "axbq/r/c", modernExpected: false),
        .init(pattern: #"\!**/foo"#, path: "!x/y/foo", modernExpected: false),
        .init(pattern: "x[[:space:]]y", path: "x\u{000B}y"),
        .init(pattern: "x[[:space:]]y", path: "x\u{000C}y"),
        .init(pattern: "x[[:space:]]y", path: "x\ty"),
        .init(pattern: "\\#foo", path: "#foo"),
    ]

    @Test("compiled positive patterns agree with git check-ignore --no-index", arguments: cases)
    func matchesNativeGit(row: PatternCase) throws {
        let oracle = try GitNativePatternOracle.installed.get()
        let pattern = try GitPathPattern(row.pattern)
        if !oracle.canCompare(row.pattern) {
            let recorded = try #require(row.modernExpected, "missing recorded modern Git expectation")
            #expect(pattern.matches(row.path, isDirectory: row.isDirectory, ignoreCase: row.ignoreCase) == recorded)
            return
        }
        let fixture = try GitFixtureRepository.makeRepository(prefix: "wildmatch-parity")
        defer { fixture.remove() }
        try fixture.git.run("config", "core.ignorecase", row.ignoreCase ? "true" : "false")
        let sentinel = "__git_path_oracle__"
        try fixture.write(".gitignore", contents: row.pattern + "\n" + sentinel + "\n")
        let candidate = row.path + (row.isDirectory ? "/" : "")
        // The sentinel guarantees exit 0 for nonmatching candidates; -z preserves embedded newlines.
        let output = try fixture.git.run(
            ["check-ignore", "--no-index", "-z", "--stdin"],
            standardInput: Data((candidate + "\0" + sentinel + "\0").utf8))
        let nativeMatch = output.split(separator: "\0").contains { $0 == candidate }
        #expect(
            pattern.matches(row.path, isDirectory: row.isDirectory, ignoreCase: row.ignoreCase) == nativeMatch,
            "native Git: \(nativeMatch), pattern: \(String(reflecting: row.pattern)), path: \(String(reflecting: row.path))"
        )
    }
}

@Suite("Sparse checkout native Git parity", .serialized)
struct SparseCheckoutMatcherNativeParityTests {
    struct SparseCase: Sendable {
        let rules: String
        let paths: [String]
        var ignoreCase = false
        var modernIncluded: [String]?
    }

    static let cases: [SparseCase] = [
        .init(
            rules: "/cache/**\\/output\n", paths: ["cache/output", "cache/a/output", "cache/a/b/output", "cache/drop"]),
        .init(rules: "/*\n!!secret.txt\n", paths: ["!secret.txt", "visible.txt", "folder/visible.txt"]),
        .init(rules: "/cache/**/output\n", paths: ["cache/output", "cache/a\nb/output", "cache/a/output\n"]),
        .init(rules: "/cache/?/output\n", paths: ["cache/a/output", "cache/é/output", "cache/\n/output"]),
        .init(rules: "/[z-a]x\n", paths: ["zx", "mx", "ax"]),
        .init(rules: "/*\n!/dropped/\n/dropped/keep.txt\n", paths: ["README.md", "dropped/drop", "dropped/keep.txt"]),
        .init(rules: "/Frameworks/**/lib\n", paths: ["Frameworks/a/lib", "frameworks/a/lib"], ignoreCase: true),
        .init(rules: "/Frameworks/**/lib\n", paths: ["Frameworks/a/lib", "frameworks/a/lib"], ignoreCase: false),
        .init(rules: "/ space.txt\n", paths: [" space.txt", "space.txt"]),
        .init(rules: "/name\\ \n", paths: ["name ", "name"]),
        .init(rules: "   \n/visible.txt\n", paths: ["visible.txt", "other.txt"]),
        .init(rules: "/*\r\n!!secret.txt\r\n", paths: ["visible.txt", "!secret.txt"]),
        .init(rules: "/*\n!\u{0301}name\n", paths: ["\u{0301}name", "visible.txt"]),
        .init(rules: "/*\n!!\u{0301}name\n", paths: ["!\u{0301}name", "visible.txt"]),
        .init(rules: "/cache/\n", paths: ["cache/\u{0301}file", "other/file"]),
        // Git >=2.52 / 1940a02dc1: component ** cannot cross a slash or omit /bar.
        .init(rules: "/foo**/bar\n", paths: ["foox/y/bar", "foobar", "foo/bar"], modernIncluded: ["foo/bar"]),
        // 1940a02dc1: the literal ! prefix makes ** component-only; inherit /* for both paths.
        .init(
            rules: "/*\n!!**/foo\n", paths: ["!x/y/foo", "visible.txt"],
            modernIncluded: ["!x/y/foo", "visible.txt"]),
        .init(rules: "b\n?/\\/\n", paths: ["b/c", "b", "other/c"]),
        .init(rules: "b\n[[:unknown:]]\n", paths: ["b/c", "b", "other/c"]),
        .init(rules: "/*\n!#foo\n", paths: ["#foo", "bar"]),
    ]

    @Test("sparse policy agrees with git sparse-checkout check-rules --no-cone", arguments: cases)
    func matchesNativeSparseRules(row: SparseCase) throws {
        let oracle = try GitNativePatternOracle.installed.get()
        let matcher = SparseCheckoutMatcher(patternFile: row.rules, coneMode: false, ignoreCase: row.ignoreCase)
        #expect(!matcher.hasUntranslatablePatterns)
        if !oracle.canCompareSparseRules(row.rules) {
            let included = Set(try #require(row.modernIncluded, "missing recorded modern sparse expectation"))
            for path in row.paths { #expect(matcher.includes(path) == included.contains(path)) }
            return
        }
        let fixture = try GitFixtureRepository.makeRepository(prefix: "sparse-rule-parity")
        defer { fixture.remove() }
        try fixture.git.run("config", "core.ignorecase", row.ignoreCase ? "true" : "false")
        let rulesFile = fixture.root.appending(path: "sparse-rules")
        try row.rules.write(to: rulesFile, atomically: true, encoding: .utf8)
        let output = try fixture.git.run(
            ["sparse-checkout", "check-rules", "--no-cone", "-z", "--rules-file", rulesFile.path],
            standardInput: Data((row.paths.joined(separator: "\0") + "\0").utf8))
        let included = Set(output.split(separator: "\0").map(String.init))
        for path in row.paths {
            #expect(
                matcher.includes(path) == included.contains(path),
                "native Git: \(included.contains(path)), rules: \(String(reflecting: row.rules)), path: \(String(reflecting: path))"
            )
        }
    }
}
