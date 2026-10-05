import AgentStudioGit
import Foundation
import Testing

@testable import AgentStudioGitLocal

@Suite("Seeded Git wildmatch differential", .serialized)
struct GitWildmatchDifferentialTests {
    // Fixed seeds are part of this permanent regression corpus; failures are reproducible locally/CI.
    private static let patternSeed: UInt64 = 0xD1D2_A11C_2026_1004
    private static let sparseSeed: UInt64 = 0x51A2_5EED_2026_1004

    @Test("generated positive patterns agree with native check-ignore in both case policies")
    func seededPatternsAgreeWithNativeGit() throws {
        let fixture = try GitFixtureRepository.makeRepository(prefix: "wildmatch-seeded")
        defer { fixture.remove() }
        var generator = DifferentialGenerator(seed: Self.patternSeed)
        let patterns = generator.patterns(count: 96)
        let paths = generator.paths(count: 32)
        var mismatches: [String] = []
        var decisions = 0
        let sentinel = "__git_differential_oracle__"
        for ignoreCase in [false, true] {
            try fixture.git.run("config", "core.ignorecase", ignoreCase ? "true" : "false")
            for patternText in patterns {
                try fixture.write(".gitignore", contents: patternText + "\n" + sentinel + "\n")
                let candidates = paths.map(\.oraclePath) + [sentinel]
                // Batch paths per pattern: stdout is bounded below pipe capacity, including newlines.
                let output = try fixture.git.run(
                    ["check-ignore", "--no-index", "-z", "--stdin"],
                    standardInput: Data((candidates.joined(separator: "\0") + "\0").utf8))
                let ignored = Set(output.split(separator: "\0").map(String.init))
                let pattern = try? GitPathPattern(patternText)
                for path in paths {
                    decisions += 1
                    let native = ignored.contains(path.oraclePath)
                    let actual =
                        pattern?.matches(path.path, isDirectory: path.isDirectory, ignoreCase: ignoreCase) ?? false
                    if native != actual {
                        mismatches.append(
                            "case=\(ignoreCase) pattern=\(String(reflecting: patternText)) path=\(String(reflecting: path.oraclePath)) native=\(native) actual=\(actual) parsed=\(pattern != nil)"
                        )
                    }
                }
            }
        }
        print(
            "WILDMATCH_DIFFERENTIAL seed=\(String(Self.patternSeed, radix: 16)) pairs=\(decisions) mismatches=\(mismatches.count)"
        )
        if !mismatches.isEmpty {
            Issue.record(
                "Every mismatch, seed \(String(Self.patternSeed, radix: 16)):\n\(mismatches.joined(separator: "\n"))")
        }
    }

    @Test("generated sparse rules agree with native check-rules in both case policies")
    func seededSparseRulesAgreeWithNativeGit() throws {
        let fixture = try GitFixtureRepository.makeRepository(prefix: "sparse-seeded")
        defer { fixture.remove() }
        var generator = DifferentialGenerator(seed: Self.sparseSeed)
        let patterns = generator.patterns(count: 96).filter { $0.utf8.first != 35 }
        let paths = generator.paths(count: 16).map(\.path)
        let rulesFile = fixture.root.appending(path: "sparse-rules")
        var ruleSets = [
            "/foo**/bar.leaf\n", "/*\n!!**/foo.leaf\n", "b\n?/\\/\n", "b\n[[:unknown:]]\n",
            "/*\n!#foo.leaf\n",
        ]
        while ruleSets.count < 80 {
            var lines: [String] = generator.next(3) == 0 ? ["/*"] : []
            for _ in 0..<(generator.next(3) + 1) {
                let positive = patterns[generator.next(patterns.count)]
                let prefix = ["", "!", "!!"][generator.next(3)]
                lines.append(prefix + positive)
            }
            // --rules-file calls add_pattern directly: avoid comments/unescaped trailing spaces.
            // These are file-reader syntax and have separate explicit/reapply-owned coverage.
            ruleSets.append(lines.joined(separator: "\n") + "\n")
        }
        var mismatches: [String] = []
        var decisions = 0
        for ignoreCase in [false, true] {
            try fixture.git.run("config", "core.ignorecase", ignoreCase ? "true" : "false")
            for rules in ruleSets {
                try rules.write(to: rulesFile, atomically: true, encoding: .utf8)
                let output = try fixture.git.run(
                    ["sparse-checkout", "check-rules", "--no-cone", "-z", "--rules-file", rulesFile.path],
                    standardInput: Data((paths.joined(separator: "\0") + "\0").utf8))
                let included = Set(output.split(separator: "\0").map(String.init))
                let matcher = SparseCheckoutMatcher(patternFile: rules, coneMode: false, ignoreCase: ignoreCase)
                if matcher.hasUntranslatablePatterns {
                    mismatches.append(
                        "case=\(ignoreCase) rules=\(String(reflecting: rules)) unexpectedly untranslatable")
                }
                for path in paths {
                    decisions += 1
                    let native = included.contains(path)
                    let actual = matcher.includes(path)
                    if native != actual {
                        mismatches.append(
                            "case=\(ignoreCase) rules=\(String(reflecting: rules)) path=\(String(reflecting: path)) native=\(native) actual=\(actual)"
                        )
                    }
                }
            }
        }
        print(
            "SPARSE_DIFFERENTIAL seed=\(String(Self.sparseSeed, radix: 16)) pairs=\(decisions) mismatches=\(mismatches.count)"
        )
        if !mismatches.isEmpty {
            Issue.record(
                "Every mismatch, seed \(String(Self.sparseSeed, radix: 16)):\n\(mismatches.joined(separator: "\n"))")
        }
    }
}

private struct DifferentialPath {
    let path: String
    let isDirectory: Bool
    var oraclePath: String { path + (isDirectory ? "/" : "") }
}

private struct DifferentialGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }

    mutating func next(_ upperBound: Int) -> Int {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return Int(state % UInt64(upperBound))
    }

    mutating func patterns(count: Int) -> [String] {
        var patterns = [
            "foo**/bar.leaf", "x/foo**/bar.leaf", #"foo**\/bar.leaf"#, "a?b**/c.leaf",
            "*.leaf", "**/foo.leaf", "a/***/bar.leaf", "x[[:space:]]y.leaf", "[a-z].leaf",
            "[z-a].leaf", "[!ab].leaf", "[^ab].leaf", "[]].leaf", "[[:digit:]].leaf",
            "[[:upper:]].leaf", "[[:unknown:]].leaf", "[abc.leaf", "tail.leaf\\",
            #"\!**/foo.leaf"#, "/foo.leaf", "a/b.leaf", "foo.leaf/", "é**/bar.leaf",
            "/#**/bar.leaf", "/\u{0301}name.leaf", #"literal\*.leaf"#,
            "#*.leaf", "#foo.leaf", "\\#foo.leaf",
        ]
        let tokens = [
            "foo", "a", "b", "x", "é", "\u{0301}", "*", "**", "***", "?", "[ab]", "[a-z]",
            "[z-a]", "[!ab]", "[^x]", "[]]", "[[:digit:]]", "[[:upper:]]", "[[:space:]]",
            "[[:unknown:]]", "[", "[[:broken]", #"\*"#, #"\?"#, #"\/"#, #"\a"#,
        ]
        let prefixes = ["", "/", "a/", "x/", "é/", "/#"]
        let joins = ["", "/", #"\/"#]
        while patterns.count < count {
            var pattern = prefixes[next(prefixes.count)]
            for index in 0..<(next(3) + 1) {
                if index > 0 { pattern += joins[next(joins.count)] }
                pattern += tokens[next(tokens.count)]
            }
            pattern += ".leaf"
            if next(5) == 0 { pattern += "/" } else if next(13) == 0 { pattern += "\\" }
            patterns.append(pattern)
        }
        return patterns
    }

    mutating func paths(count: Int) -> [DifferentialPath] {
        // All generated patterns end in .leaf (or an intentionally malformed fragment). Ancestors
        // never do, so check-ignore's inherited directory decisions cannot mask entry-level parity.
        var names = [
            "foox/y/bar.leaf", "foo/bar.leaf", "foobar.leaf", "x/fooq/r/bar.leaf", "axbq/r/c.leaf",
            "!x/y/foo.leaf", "#foo.leaf", "foo.leaf", "a/b.leaf", "a/b/c.leaf", "b/c.leaf", "é.leaf",
            "a/\u{0301}name.leaf", "\u{0301}name.leaf", "foo/\n/bar.leaf", "\n.leaf", "\t.leaf",
            "\u{000B}.leaf", "\u{000C}.leaf", "foo.leaf\n", "UPPER.leaf", "upper.leaf", "bar.leaf",
            "literal*.leaf", "!foo.leaf",
        ]
        let directories = ["foo", "a", "x", "é", "\u{0301}dir", "!x", "dir"]
        let leaves = ["foo", "bar", "ab", "x", "é", "\u{0301}name", "7", "]", "\n"]
        while names.count < count {
            var name = ""
            for _ in 0..<next(3) { name += directories[next(directories.count)] + "/" }
            names.append(name + leaves[next(leaves.count)] + ".leaf")
        }
        return names.prefix(count).enumerated().map { offset, path in
            DifferentialPath(path: path, isDirectory: offset.isMultiple(of: 5))
        }
    }
}
