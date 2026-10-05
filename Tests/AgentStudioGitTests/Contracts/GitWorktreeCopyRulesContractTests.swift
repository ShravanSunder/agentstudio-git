import AgentStudioGitContracts
import Foundation
import Testing

@Suite("Git worktree copy rules contracts")
struct GitWorktreeCopyRulesContractTests {
    @Test("copyMatching patterns round-trip through explicit tagged payloads")
    func matchingPolicyRoundTrip() throws {
        let rules = GitWorktreeCopyRules(
            ignoredPaths: .copyMatching([
                try GitPathPattern(".build*/"), try GitPathPattern("*.[oa]"), try GitPathPattern("/vendor/**"),
            ]))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(rules)
        #expect(try JSONDecoder().decode(GitWorktreeCopyRules.self, from: data) == rules)
        #expect(
            String(data: data, encoding: .utf8)
                == #"{"ignoredPaths":{"kind":"copyMatching","patterns":[".build*/","*.[oa]","/vendor/**"]}}"#)
    }

    @Test("copy policy decoding rejects negation and extra or missing keys")
    func invalidPolicies() {
        for payload in [
            #"{"kind":"copyMatching","patterns":["!cache/"]}"#,
            #"{"kind":"copyMatching"}"#,
            #"{"patterns":["cache/"]}"#,
            #"{"kind":"copyMatching","patterns":[],"unexpected":true}"#,
            #"{"kind":"copyAll","patterns":[]}"#,
            #"{"kind":"copyAll","unexpected":true}"#,
        ] {
            #expect(throws: DecodingError.self) {
                _ = try JSONDecoder().decode(GitIgnoredPathPolicy.self, from: Data(payload.utf8))
            }
        }
    }
}
