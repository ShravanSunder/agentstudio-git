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

    @Test("discovery outcomes reject non-selected payload keys")
    func discoveryOutcomesRejectNonSelectedPayloadKeys() throws {
        let evidence = discoveryReadEvidence()
        let failure = GitDiscoveryReadFailure(code: -1, errorClass: 2, message: "ambiguous")
        let encodedEvidence = try encodedJSONObject(evidence)
        let encodedFailure = try encodedJSONObject(failure)
        let contradictoryOutcomes: [(GitDiscoveryReadOutcome, [String: Any])] = [
            (.validated(evidence), ["reason": "invalidRepository", "failure": encodedFailure]),
            (
                .notRepository(.invalidRepository),
                ["evidence": encodedEvidence, "failure": encodedFailure]
            ),
            (.failed(failure), ["evidence": encodedEvidence, "reason": "invalidRepository"]),
        ]

        for (outcome, contradictoryPayload) in contradictoryOutcomes {
            var encodedOutcome = try encodedJSONObject(outcome)
            encodedOutcome.merge(contradictoryPayload) { _, contradictoryValue in contradictoryValue }

            #expect(throws: DecodingError.self) {
                _ = try JSONDecoder().decode(
                    GitDiscoveryReadOutcome.self,
                    from: JSONSerialization.data(withJSONObject: encodedOutcome)
                )
            }
        }
    }

    @Test("discovery outcomes require their selected payload")
    func discoveryOutcomesRequireSelectedPayload() {
        let missingSelectedPayloads = [
            #"{"state":"validated"}"#,
            #"{"state":"notRepository"}"#,
            #"{"state":"failed"}"#,
        ]

        for payload in missingSelectedPayloads {
            #expect(throws: DecodingError.self) {
                _ = try JSONDecoder().decode(
                    GitDiscoveryReadOutcome.self,
                    from: Data(payload.utf8)
                )
            }
        }
    }

    @Test("discovery worktree registrations reject non-selected payload keys")
    func discoveryWorktreeRegistrationsRejectNonSelectedPayloadKeys() {
        let mainWithLinkedPayload = Data(
            #"{"kind":"main","name":"linked-copy","lockState":{"state":"unlocked"}}"#.utf8
        )

        #expect(throws: DecodingError.self) {
            _ = try JSONDecoder().decode(GitDiscoveryWorktreeRegistration.self, from: mainWithLinkedPayload)
        }
    }

    @Test("linked discovery worktree registrations require their selected payload")
    func linkedDiscoveryWorktreeRegistrationsRequireSelectedPayload() {
        let missingSelectedPayloads = [
            #"{"kind":"linked","lockState":{"state":"unlocked"}}"#,
            #"{"kind":"linked","name":"linked-copy"}"#,
        ]

        for payload in missingSelectedPayloads {
            #expect(throws: DecodingError.self) {
                _ = try JSONDecoder().decode(
                    GitDiscoveryWorktreeRegistration.self,
                    from: Data(payload.utf8)
                )
            }
        }
    }

    @Test("discovery lock states reject non-selected reason payloads")
    func discoveryLockStatesRejectNonSelectedReasonPayloads() {
        let contradictoryLockStates = [
            #"{"state":"unlocked","reason":"ambiguous"}"#,
            #"{"state":"lockedWithoutReason","reason":"ambiguous"}"#,
        ]

        for payload in contradictoryLockStates {
            #expect(throws: DecodingError.self) {
                _ = try JSONDecoder().decode(
                    GitDiscoveryLinkedWorktreeLockState.self,
                    from: Data(payload.utf8)
                )
            }
        }
    }

    @Test("locked discovery lock states require their selected reason payload")
    func lockedDiscoveryLockStatesRequireSelectedReasonPayload() {
        let data = Data(#"{"state":"locked"}"#.utf8)

        #expect(throws: DecodingError.self) {
            _ = try JSONDecoder().decode(GitDiscoveryLinkedWorktreeLockState.self, from: data)
        }
    }

    private func discoveryReadEvidence() -> GitDiscoveryReadEvidence {
        GitDiscoveryReadEvidence(
            canonicalCandidatePath: URL(fileURLWithPath: "/tmp/repo"),
            canonicalWorktreePath: URL(fileURLWithPath: "/tmp/repo"),
            canonicalGitDirectory: URL(fileURLWithPath: "/tmp/repo/.git"),
            canonicalCommonDirectory: URL(fileURLWithPath: "/tmp/repo/.git"),
            repositoryIdentity: GitRepositoryIdentity(
                id: GitRepositoryID(rawValue: "common:/tmp/repo/.git"),
                canonicalCommonDirectory: URL(fileURLWithPath: "/tmp/repo/.git"),
                mainWorktreePath: URL(fileURLWithPath: "/tmp/repo")
            ),
            registration: .main
        )
    }

    private func encodedJSONObject<EncodedValue: Encodable>(
        _ value: EncodedValue
    ) throws -> [String: Any] {
        let encodedData = try JSONEncoder().encode(value)
        return try #require(JSONSerialization.jsonObject(with: encodedData) as? [String: Any])
    }
}
