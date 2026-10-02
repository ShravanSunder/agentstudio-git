import AgentStudioGit
import Foundation
import Testing

@Suite("Git worktree fork contracts")
struct GitWorktreeForkContractTests {
    @Test("fork modes use explicit kind discriminators without start points")
    func forkModesUseExplicitKindDiscriminators() throws {
        // Arrange
        let modes: [GitForkWorktreeMode] = [
            .existingBranch(name: "feature"),
            .newBranch(name: "fork-feature"),
            .detached,
        ]

        // Act
        let encodedModes = try modes.map { try sortedEncoder().encode($0) }
        let decodedModes = try encodedModes.map { try JSONDecoder().decode(GitForkWorktreeMode.self, from: $0) }

        // Assert
        #expect(decodedModes == modes)
        #expect(
            encodedModes.map { jsonText($0) } == [
                #"{"kind":"existingBranch","name":"feature"}"#,
                #"{"kind":"newBranch","name":"fork-feature"}"#,
                #"{"kind":"detached"}"#,
            ])
    }

    @Test("fork requests round-trip with stable field names")
    func forkRequestsRoundTripWithStableFieldNames() throws {
        // Arrange
        let request = GitForkWorktreeRequest(
            sourceWorktreePath: URL(fileURLWithPath: "/tmp/source"),
            destinationPath: URL(fileURLWithPath: "/tmp/destination"),
            mode: .newBranch(name: "fork"),
            materialization: .copyOnWrite
        )

        // Act
        let encoded = try sortedEncoder().encode(request)
        let decoded = try JSONDecoder().decode(GitForkWorktreeRequest.self, from: encoded)

        // Assert
        #expect(decoded == request)
        #expect(
            jsonText(encoded)
                == #"{"destinationPath":"file:///tmp/destination","materialization":"copyOnWrite","mode":{"kind":"newBranch","name":"fork"},"#
                + #""sourceWorktreePath":"file:///tmp/source"}"#
        )
    }

    @Test("fork results carry the validated snapshot and ordered materialization report")
    func forkResultsCarrySnapshotAndOrderedReport() throws {
        // Arrange
        let report = GitWorktreeMaterializationReport(
            clonedRegularFileCount: 12,
            createdDirectoryCount: 4,
            recreatedSymbolicLinkCount: 2,
            preservedHardLinkCount: 1,
            preservedGitRepositoryCount: 1,
            recreatedFIFOCount: 1,
            logicalRegularFileBytes: 4096,
            skippedEntries: [
                GitWorktreeMaterializationSkippedEntry(
                    relativePath: "run/agent.sock",
                    kind: .unixSocket,
                    reason: .unixSocketNotReproducible
                )
            ],
            normalizedEntries: [
                GitWorktreeMaterializationNormalizedEntry(
                    relativePath: "bin/tool",
                    attribute: .setUserIDBit,
                    reason: .clearedByCopyOnWriteClone
                ),
                GitWorktreeMaterializationNormalizedEntry(
                    relativePath: "shared/data",
                    attribute: .ownerUser,
                    reason: .ownershipNotAssignable
                ),
            ]
        )
        let result = GitForkWorktreeResult(
            worktree: worktreeSnapshot(), materialization: .copyOnWrite(report))

        // Act
        let decoded = try JSONDecoder().decode(GitForkWorktreeResult.self, from: sortedEncoder().encode(result))

        // Assert
        #expect(decoded == result)
        guard case .copyOnWrite(let decodedReport) = decoded.materialization else {
            Issue.record("expected copy-on-write result")
            return
        }
        #expect(decodedReport.skippedEntries.map(\.relativePath) == ["run/agent.sock"])
        #expect(decodedReport.normalizedEntries.map(\.relativePath) == ["bin/tool", "shared/data"])
    }

    @Test("changes-only reports and refusals use explicit tagged payloads")
    func changesOnlyContractsUseExplicitTags() throws {
        // Arrange
        let largeFiles = GitLargeFileFill(materializedCount: 1, missing: [], indexUpdate: .updated)
        let report = GitChangesOnlyMaterializationReport(
            trackedChanges: 3,
            untrackedFiles: 2,
            largeFiles: largeFiles
        )
        let refusal = GitWorktreeWorkingStateRefusal(reason: .customFilter, relativePath: "assets/icon.png")
        let result = GitWorktreeMaterializationResult.changesOnly(report)
        let error = GitWorktreeForkError.workingStateUnsupported(refusal)

        // Act
        let encodedResult = try sortedEncoder().encode(result)
        let encodedError = try sortedEncoder().encode(error)

        // Assert
        #expect(try JSONDecoder().decode(GitWorktreeMaterializationResult.self, from: encodedResult) == result)
        #expect(try JSONDecoder().decode(GitWorktreeForkError.self, from: encodedError) == error)
        #expect(
            jsonText(encodedResult)
                == #"{"ignoredExcluded":true,"kind":"changesOnly","largeFiles":{"indexUpdate":{"kind":"updated"},"materializedCount":1,"missing":[]},"trackedChanges":3,"untrackedFiles":2}"#
        )
        #expect(
            jsonText(encodedError)
                == #"{"workingStateUnsupported":{"refusal":{"reason":"customFilter","relativePath":"assets/icon.png"}}}"#
        )
        for invalidPayload in [
            #"{"kind":"changesOnly","trackedChanges":-1,"untrackedFiles":0,"ignoredExcluded":true,"largeFiles":{"materializedCount":0,"missing":[],"indexUpdate":{"kind":"updated"}}}"#,
            #"{"kind":"changesOnly","trackedChanges":1,"untrackedFiles":0,"ignoredExcluded":false,"largeFiles":{"materializedCount":0,"missing":[],"indexUpdate":{"kind":"updated"}}}"#,
            #"{"kind":"changesOnly","trackedChanges":1,"untrackedFiles":0,"ignoredExcluded":true,"largeFiles":{"materializedCount":0,"missing":[],"indexUpdate":{"kind":"updated"}},"clonedRegularFileCount":0}"#,
            #"{"kind":"changesOnly","trackedChanges":1,"untrackedFiles":0,"ignoredExcluded":true}"#,
        ] {
            #expect(throws: DecodingError.self) {
                _ = try JSONDecoder().decode(GitWorktreeMaterializationResult.self, from: Data(invalidPayload.utf8))
            }
        }
    }

    @Test("every fork failure variant round-trips through its explicit case key")
    func everyForkFailureVariantRoundTrips() throws {
        // Arrange
        let primary = GitWorktreeForkError.entryFailed(
            relativePath: "cache/blob.bin",
            reason: .strictCloneFailed,
            errorNumber: 45
        )
        let errors: [GitWorktreeForkError] = [
            .rejected(reason: .clientCapabilityUnavailable),
            .rejected(reason: .destinationExists),
            .workingStateUnsupported(
                GitWorktreeWorkingStateRefusal(reason: .nestedRepository, relativePath: "vendor/module")),
            .workingStateUnsupported(
                GitWorktreeWorkingStateRefusal(reason: .attributesChanged, relativePath: ".gitattributes")),
            .gitFailure(.headUnavailable),
            .sourceChanged(relativePath: "src/main.swift", reason: .entryKindChanged),
            primary,
            .cancelled,
            .validationFailed(reason: .indexStatNotRefreshed, relativePath: "README.md"),
            .validationFailed(reason: .headMismatch, relativePath: nil),
            .cleanupIncomplete(
                primary: primary,
                residue: [
                    GitWorktreeForkResidue(kind: .destinationContent, location: "."),
                    GitWorktreeForkResidue(kind: .linkedWorktreeAdministration, location: "worktrees/fork"),
                    GitWorktreeForkResidue(kind: .createdBranch, location: "refs/heads/fork"),
                    GitWorktreeForkResidue(kind: .lockFile, location: "worktrees/fork/index.lock"),
                ]
            ),
        ]

        // Act
        let encoded = try errors.map { try sortedEncoder().encode($0) }
        let decoded = try encoded.map { try JSONDecoder().decode(GitWorktreeForkError.self, from: $0) }

        // Assert
        #expect(decoded == errors)
        #expect(
            jsonText(encoded[0]) == #"{"rejected":{"reason":"clientCapabilityUnavailable"}}"#)
        #expect(
            jsonText(encoded[3])
                == #"{"workingStateUnsupported":{"refusal":{"reason":"attributesChanged","relativePath":".gitattributes"}}}"#
        )
        #expect(jsonText(encoded[7]) == #"{"cancelled":{}}"#)
        #expect(
            jsonText(encoded[4]) == #"{"gitFailure":{"error":{"headUnavailable":{}}}}"#
        )
    }

    @Test("fork failure decoding rejects ambiguous or unknown cases")
    func forkFailureDecodingRejectsAmbiguousOrUnknownCases() {
        // Arrange
        let payloads = [
            #"{"rejected":{"reason":"destinationExists"},"cancelled":{}}"#,
            #"{"teleported":{}}"#,
            #"{"rejected":{"reason":"teleported"}}"#,
            #"{"workingStateUnsupported":{"refusal":{"reason":"customFilter","relativePath":"../escape"}}}"#,
            #"{"kind":"detached","name":"stray"}"#,
        ]

        // Act / Assert
        for payload in payloads.prefix(4) {
            #expect(throws: DecodingError.self) {
                _ = try JSONDecoder().decode(GitWorktreeForkError.self, from: Data(payload.utf8))
            }
        }
        #expect(throws: DecodingError.self) {
            _ = try JSONDecoder().decode(GitForkWorktreeMode.self, from: Data(payloads[4].utf8))
        }
        #expect(throws: DecodingError.self) {
            _ = try JSONDecoder().decode(GitForkWorktreeMode.self, from: Data(#"{"kind":"newBranch"}"#.utf8))
        }
    }

    @Test("fork eligibility uses an explicit state discriminator and rejects contradictory payloads")
    func forkEligibilityUsesExplicitStateDiscriminator() throws {
        // Arrange
        let values: [GitWorktreeForkEligibility] = [.available, .unavailable(.fileProviderManagedLocation)]
        let contradictory = [
            #"{"state":"available","reason":"crossDevice"}"#,
            #"{"state":"unavailable"}"#,
            #"{"state":"teleported"}"#,
        ]

        // Act
        let encoded = try values.map { try sortedEncoder().encode($0) }
        let decoded = try encoded.map { try JSONDecoder().decode(GitWorktreeForkEligibility.self, from: $0) }

        // Assert
        #expect(decoded == values)
        #expect(
            encoded.map(jsonText) == [
                #"{"state":"available"}"#,
                #"{"reason":"fileProviderManagedLocation","state":"unavailable"}"#,
            ])
        for payload in contradictory {
            #expect(throws: DecodingError.self) {
                _ = try JSONDecoder().decode(GitWorktreeForkEligibility.self, from: Data(payload.utf8))
            }
        }
    }

    @Test("existing conformers report fork eligibility as unavailable")
    func existingConformersReportForkEligibilityUnavailable() async {
        // Arrange
        let client: any AgentStudioGitLocalClient = LegacyLocalClientDouble()

        // Act
        let eligibility = await client.forkWorktreeEligibility(
            sourceWorktreePath: URL(fileURLWithPath: "/tmp/source"),
            destinationPath: URL(fileURLWithPath: "/tmp/destination"),
            materialization: .copyOnWrite
        )

        // Assert
        #expect(eligibility == .unavailable(.clientCapabilityUnavailable))
    }

    @Test("normal create requests keep their pre-fork wire shape and legacy payloads decode")
    func normalCreateRequestsKeepPreForkWireShape() throws {
        // Arrange
        let repositoryPath = URL(fileURLWithPath: "/tmp/repo")
        let destinationPath = URL(fileURLWithPath: "/tmp/wt")
        let requests = [
            GitCreateWorktreeRequest(
                repositoryPath: repositoryPath,
                destinationPath: destinationPath,
                mode: .existingBranch(name: "main")
            ),
            GitCreateWorktreeRequest(
                repositoryPath: repositoryPath,
                destinationPath: destinationPath,
                mode: .newBranch(name: "feature", startPoint: .named("HEAD"))
            ),
            GitCreateWorktreeRequest(
                repositoryPath: repositoryPath,
                destinationPath: destinationPath,
                mode: .detached(startPoint: .named("HEAD"))
            ),
        ]
        let legacyPayloads = [
            #"{"destinationPath":"file:///tmp/wt","mode":{"existingBranch":{"name":"main"}},"#
                + #""repositoryPath":"file:///tmp/repo"}"#,
            #"{"destinationPath":"file:///tmp/wt","mode":{"newBranch":{"name":"feature","startPoint":{"name":"HEAD"}}},"#
                + #""repositoryPath":"file:///tmp/repo"}"#,
            #"{"destinationPath":"file:///tmp/wt","mode":{"detached":{"startPoint":{"name":"HEAD"}}},"#
                + #""repositoryPath":"file:///tmp/repo"}"#,
        ]

        // Act
        let encoded = try requests.map { jsonText(try sortedEncoder().encode($0)) }
        let decoded = try legacyPayloads.map {
            try JSONDecoder().decode(GitCreateWorktreeRequest.self, from: Data($0.utf8))
        }

        // Assert
        #expect(encoded == legacyPayloads)
        #expect(decoded == requests)
    }

    @Test("existing conformers without a fork implementation compile and report the capability unavailable")
    func existingConformersReportForkCapabilityUnavailable() async {
        // Arrange
        let client: any AgentStudioGitLocalClient = LegacyLocalClientDouble()
        let request = GitForkWorktreeRequest(
            sourceWorktreePath: URL(fileURLWithPath: "/tmp/source"),
            destinationPath: URL(fileURLWithPath: "/tmp/destination"),
            mode: .detached,
            materialization: .copyOnWrite
        )

        // Act
        let failure: GitWorktreeForkError?
        do {
            _ = try await client.forkWorktree(request)
            failure = nil
        } catch {
            failure = error
        }

        // Assert
        #expect(failure == .rejected(reason: .clientCapabilityUnavailable))
    }

    private func jsonText(_ data: Data) -> String? {
        String(data: data, encoding: .utf8)
    }

    private func sortedEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    private func worktreeSnapshot() -> GitWorktreeSnapshot {
        let repositoryID = GitRepositoryID(rawValue: "common:/tmp/repo/.git")
        return GitWorktreeSnapshot(
            id: GitWorktreeID(rawValue: "worktree:/tmp/destination"),
            repositoryID: repositoryID,
            displayName: "destination",
            path: URL(fileURLWithPath: "/tmp/destination"),
            canonicalPath: URL(fileURLWithPath: "/tmp/destination"),
            gitDirectory: URL(fileURLWithPath: "/tmp/repo/.git/worktrees/destination"),
            indexPath: URL(fileURLWithPath: "/tmp/repo/.git/worktrees/destination/index"),
            isMainWorktree: false,
            isLocked: false,
            lockReason: nil,
            head: nil
        )
    }
}
