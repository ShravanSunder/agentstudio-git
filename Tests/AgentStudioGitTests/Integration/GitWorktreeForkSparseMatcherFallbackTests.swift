import AgentStudioGit
import Foundation
import Testing

@Suite("Git worktree sparse matcher fallback integration", .serialized)
struct GitWorktreeForkSparseMatcherFallbackTests {
    enum SparseRuleScenario: CaseIterable {
        case escapedRecursiveSeparator
        case literalBangNegation

        var rules: String {
            switch self {
            case .escapedRecursiveSeparator: "/cache/**\\/output\n"
            case .literalBangNegation: "/*\n!!secret.txt\n"
            }
        }
        var includedPath: String {
            switch self {
            case .escapedRecursiveSeparator: "cache/a/b/output"
            case .literalBangNegation: "visible.txt"
            }
        }
        var excludedPath: String {
            switch self {
            case .escapedRecursiveSeparator: "cache/a/b/drop.txt"
            case .literalBangNegation: "!secret.txt"
            }
        }
    }

    @Test(
        "copyAll uses native sparse rules when no persisted index flags are available",
        arguments: SparseRuleScenario.allCases)
    func missingIndexMakesMatcherAuthoritative(scenario: SparseRuleScenario) async throws {
        let fixture = try GitWorktreeForkFixture.make(prefix: "sparse-fallback")
        defer { fixture.remove() }
        try fixture.write(scenario.includedPath, "clean\n")
        try fixture.write(scenario.excludedPath, "excluded\n")
        try fixture.git.run("add", ".")
        try fixture.git.run("commit", "-qm", "sparse tree")
        try fixture.git.run("sparse-checkout", "init", "--no-cone")
        try fixture.git.run(
            ["sparse-checkout", "set", "--no-cone", "--stdin"], standardInput: Data(scenario.rules.utf8))
        try #require(GitWorktreeForkFileProbe.exists(fixture.source.appending(path: scenario.includedPath)))
        try #require(!GitWorktreeForkFileProbe.exists(fixture.source.appending(path: scenario.excludedPath)))
        try fixture.write(scenario.includedPath, "dirty included content\n")
        try FileManager.default.removeItem(at: fixture.source.appending(path: ".git/index"))
        try #require(!GitWorktreeForkFileProbe.exists(fixture.source.appending(path: ".git/index")))

        _ = try await LibGit2AgentStudioGitLocalClient().forkWorktree(fixture.request())

        let includedFlags = try fixture.git.run(
            ["ls-files", "-t", "--", scenario.includedPath], currentDirectory: fixture.destination())
        let excludedFlags = try fixture.git.run(
            ["ls-files", "-t", "--", scenario.excludedPath], currentDirectory: fixture.destination())
        #expect(includedFlags.hasPrefix("H "))
        #expect(excludedFlags.hasPrefix("S "))
        #expect(try fixture.statusLines(at: fixture.destination()) == [" M \(scenario.includedPath)"])
        #expect(
            try String(contentsOf: fixture.destination().appending(path: scenario.includedPath), encoding: .utf8)
                == "dirty included content\n")
    }
}
