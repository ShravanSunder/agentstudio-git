import AgentStudioGit
import Foundation
import Testing

@testable import AgentStudioGitLocal

/// Reapply reads the actual sparse file, including trimming that check-rules --rules-file bypasses.
@Suite("Sparse checkout native reapply parity", .serialized)
struct SparseCheckoutReapplyNativeParityTests {
    struct ReapplyCase: Sendable {
        let rules: String
        let skippedPaths: [String]
        let includedPaths: [String]
    }

    static let cases: [ReapplyCase] = [
        // Recorded Git >=2.52 / 1940a02dc1: ** after a literal prefix is a component star.
        .init(rules: "/foo**/bar\n", skippedPaths: ["foox/y/bar", "foobar"], includedPaths: ["foo/bar"]),
        .init(
            rules: "/*\n!!build/ \n", skippedPaths: ["!build/f", "x/!build/f"],
            includedPaths: ["!build /f", "keep"]),
        .init(
            rules: "/*\n!#build/ \n", skippedPaths: ["x/#build/f"],
            includedPaths: ["!build/f", "keep"]),
        .init(
            rules: "/*\n!!build\\ \n", skippedPaths: ["!build /f", "x/!build /f"],
            includedPaths: ["!build/f", "x/!build/f", "keep"]),
    ]

    @Test("trailing-space marker rules agree with real reapply flags", arguments: cases)
    func trailingSpaceRulesMatchNativeGit(row: ReapplyCase) throws {
        let oracle = try GitNativePatternOracle.installed.get()
        let matcher = SparseCheckoutMatcher(patternFile: row.rules, coneMode: false)
        if !oracle.canCompareSparseRules(row.rules) {
            #expect(!matcher.hasUntranslatablePatterns)
            for path in row.skippedPaths { #expect(!matcher.includes(path)) }
            for path in row.includedPaths { #expect(matcher.includes(path)) }
            return
        }
        // Arrange
        let paths = row.skippedPaths + row.includedPaths
        let fixture = try makeSparseFixture(paths: paths)
        defer { fixture.remove() }

        // Act: write the file directly so Git's file reader, rather than set/check-rules, is the oracle.
        let flags = try reapplyFlags(fixture: fixture, rules: row.rules)

        // Assert both the recorded native outcome and the adapter's decision.
        #expect(!matcher.hasUntranslatablePatterns)
        for path in row.skippedPaths {
            #expect(flags[path] == false)
            #expect(!matcher.includes(path), "rules=\(String(reflecting: row.rules)) path=\(path)")
        }
        for path in row.includedPaths {
            #expect(flags[path] == true)
            #expect(matcher.includes(path), "rules=\(String(reflecting: row.rules)) path=\(path)")
        }
    }

    @Test("seeded marker and trailing-form rules agree with real reapply skip-worktree flags")
    func seededTrailingFormsMatchNativeGit() throws {
        let oracle = try GitNativePatternOracle.installed.get()
        // Arrange: cover the full prefix/body/tail product, then add fixed-seed generated cases.
        let seed: UInt64 = 0xE1_5A2E_2026_1004
        var generator = ReapplyDifferentialGenerator(seed: seed)
        let prefixes = ["!!", "!#", "!"]
        let bodies = [
            "build", "cache", "a", "a**/b", "**/f", "foo**/bar", "a?b", "[ab]", "[!a]",
            "[[:digit:]]", "dir/sub", "é",
        ]
        let tails = ["", "/", " ", "/ ", "/  ", #"\ "#, #"/\ "#, "  "]
        var rules = prefixes.flatMap { prefix in
            bodies.flatMap { body in tails.map { "/*\n" + prefix + body + $0 + "\n" } }
        }
        while rules.count < 300 {
            rules.append(
                "/*\n" + prefixes[generator.next(prefixes.count)] + bodies[generator.next(bodies.count)]
                    + tails[generator.next(tails.count)] + "\n")
        }
        for index in stride(from: rules.count - 1, through: 1, by: -1) {
            rules.swapAt(index, generator.next(index + 1))
        }
        let descendants = [
            "build/f", "build /f", "cache/f", "a/f", "a7/b/f", "axb/f", "b/f", "7/f",
            "dir/sub/f", "é/f", "foox/y/bar/f",
        ]
        let paths =
            ["keep"]
            + ["!", "#", ""].flatMap { marker in
                descendants.flatMap { [marker + $0, "x/" + marker + $0] }
            }
        let fixture = try makeSparseFixture(paths: paths)
        defer { fixture.remove() }
        var mismatches: [String] = []
        var decisions = 0
        var excluded = 0

        // Act: each rule set crosses Git's actual file reader and index update path.
        for ruleSet in rules {
            // 1940a02dc1: generate the same corpus, gate only native comparison on old Git.
            guard oracle.canCompareSparseRules(ruleSet) else {
                excluded += paths.count
                continue
            }
            let flags = try reapplyFlags(fixture: fixture, rules: ruleSet)
            let matcher = SparseCheckoutMatcher(patternFile: ruleSet, coneMode: false)
            if matcher.hasUntranslatablePatterns {
                mismatches.append("untranslatable rules=\(String(reflecting: ruleSet))")
            }
            for path in paths {
                let nativeIncluded = try #require(flags[path], "missing index entry \(path)")
                let actualIncluded = matcher.includes(path)
                decisions += 1
                if nativeIncluded != actualIncluded {
                    mismatches.append(
                        "rules=\(String(reflecting: ruleSet)) path=\(String(reflecting: path)) native=\(nativeIncluded ? "H" : "S") actual=\(actualIncluded ? "H" : "S")"
                    )
                }
            }
        }

        // Assert: list every divergence with the fixed seed and complete native/adapter inputs.
        print(
            "SPARSE_REAPPLY_DIFFERENTIAL seed=\(String(seed, radix: 16)) rules=\(rules.count) paths=\(paths.count) generated=\(rules.count * paths.count) excluded=\(excluded) decisions=\(decisions) mismatches=\(mismatches.count)"
        )
        if !mismatches.isEmpty {
            Issue.record("Every mismatch, seed \(String(seed, radix: 16)):\n\(mismatches.joined(separator: "\n"))")
        }
    }

    private func makeSparseFixture(paths: [String]) throws -> GitFixtureRepository {
        let fixture = try GitFixtureRepository.makeRepository(prefix: "sparse-reapply-parity")
        do {
            for path in paths { try fixture.write(path, contents: "tracked\n") }
            try fixture.git.run("add", ".")
            try fixture.git.run("commit", "-qm", "sparse parity paths")
            try fixture.git.run("config", "core.ignorecase", "false")
            try fixture.git.run("config", "core.sparseCheckout", "true")
            try fixture.git.run("config", "core.sparseCheckoutCone", "false")
            return fixture
        } catch {
            fixture.remove()
            throw error
        }
    }

    private func reapplyFlags(fixture: GitFixtureRepository, rules: String) throws -> [String: Bool] {
        try fixture.write(".git/info/sparse-checkout", contents: rules)
        try fixture.git.run("sparse-checkout", "reapply")
        let listing = try fixture.git.run("ls-files", "-t", "-z")
        var flags: [String: Bool] = [:]
        for entry in listing.split(separator: "\0") {
            let tag = try #require(entry.first)
            try #require(tag == "H" || tag == "S", "unexpected clean-index tag: \(tag)")
            flags[String(entry.dropFirst(2))] = tag == "H"
        }
        return flags
    }
}

private struct ReapplyDifferentialGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }

    mutating func next(_ upperBound: Int) -> Int {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return Int(state % UInt64(upperBound))
    }
}
