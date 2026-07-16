import AgentStudioGit
import Foundation
import Testing

@Suite("Git public contracts")
struct GitPublicContractTests {
    @Test("discovery reads round-trip strict request and outcome variants")
    func discoveryReadsRoundTripStrictRequestAndOutcomeVariants() throws {
        let request = GitDiscoveryReadRequest(candidatePath: URL(fileURLWithPath: "/tmp/repo"))
        let identity = GitRepositoryIdentity(
            id: GitRepositoryID(rawValue: "common:/tmp/repo/.git"),
            canonicalCommonDirectory: URL(fileURLWithPath: "/tmp/repo/.git"),
            mainWorktreePath: URL(fileURLWithPath: "/tmp/repo")
        )
        let evidence = GitDiscoveryReadEvidence(
            canonicalCandidatePath: URL(fileURLWithPath: "/tmp/repo"),
            canonicalWorktreePath: URL(fileURLWithPath: "/tmp/repo"),
            canonicalGitDirectory: URL(fileURLWithPath: "/tmp/repo/.git"),
            canonicalCommonDirectory: URL(fileURLWithPath: "/tmp/repo/.git"),
            repositoryIdentity: identity,
            registration: .main
        )
        let outcomes: [GitDiscoveryReadOutcome] = [
            .validated(evidence),
            .notRepository(.exactCandidateIsNotRepository),
            .notRepository(.invalidRepository),
            .notRepository(.invalidWorktreeRegistration),
            .failed(GitDiscoveryReadFailure(code: -1, errorClass: 2, message: "permission denied")),
        ]

        let decodedRequest = try JSONDecoder().decode(
            GitDiscoveryReadRequest.self,
            from: JSONEncoder().encode(request)
        )
        let decodedOutcomes = try outcomes.map { outcome in
            try JSONDecoder().decode(GitDiscoveryReadOutcome.self, from: JSONEncoder().encode(outcome))
        }

        #expect(decodedRequest == request)
        #expect(decodedOutcomes == outcomes)
    }

    @Test("status snapshots round-trip with tri-state origin resolution")
    func statusSnapshotRoundTripsWithOriginResolution() throws {
        let snapshot = GitStatusSnapshot(
            repositoryRoot: URL(fileURLWithPath: "/tmp/repo"),
            worktreePath: URL(fileURLWithPath: "/tmp/repo-linked"),
            generatedAtUnixMilliseconds: 1_781_053_200_000,
            head: GitHeadSnapshot(kind: .branch, oid: "abc123", shortName: "main"),
            originResolution: .resolved(
                GitRemoteSnapshot(
                    name: "origin",
                    url: URL(string: "https://github.com/example/repo.git")!,
                    rawURL: "https://github.com/example/repo.git"
                )
            ),
            summary: GitStatusSummary(
                changedFileCount: 1,
                stagedFileCount: 1,
                unstagedFileCount: 1,
                untrackedFileCount: 0,
                ignoredFileCount: 0,
                linesAdded: 12,
                linesDeleted: 3,
                aheadCount: 2,
                behindCount: 1,
                hasUpstream: true
            ),
            entries: [
                GitStatusEntry(
                    path: "Sources/App.swift",
                    previousPath: nil,
                    indexState: .modified,
                    worktreeState: .modified,
                    ignored: false,
                    untracked: false
                )
            ]
        )

        let data = try JSONEncoder().encode(snapshot)
        let decodedSnapshot = try JSONDecoder().decode(GitStatusSnapshot.self, from: data)

        #expect(decodedSnapshot == snapshot)
        #expect(decodedSnapshot.originResolution == snapshot.originResolution)
    }

    @Test("origin resolution encodes an explicit stable wire shape")
    func originResolutionEncodesExplicitStableWireShape() throws {
        let resolved = GitOriginResolution.resolved(
            GitRemoteSnapshot(
                name: "origin",
                url: URL(string: "https://github.com/example/repo.git")!,
                rawURL: "https://github.com/example/repo.git"
            ))

        let awaitingObject = try jsonDictionary(for: GitOriginResolution.awaitingResolution)
        let absentObject = try jsonDictionary(for: GitOriginResolution.confirmedAbsent)
        let resolvedObject = try jsonDictionary(for: resolved)
        let remoteObject = try #require(resolvedObject["remote"] as? [String: Any])

        #expect(awaitingObject["state"] as? String == "awaitingResolution")
        #expect(awaitingObject.keys.contains("remote") == false)
        #expect(absentObject["state"] as? String == "confirmedAbsent")
        #expect(absentObject.keys.contains("remote") == false)
        #expect(resolvedObject["state"] as? String == "resolved")
        #expect(remoteObject["name"] as? String == "origin")
        #expect(remoteObject["url"] as? String == "https://github.com/example/repo.git")
        #expect(remoteObject["rawURL"] as? String == "https://github.com/example/repo.git")
    }

    @Test("diff files carry stable file identity and honest content hashes")
    func diffFileCarriesStableIdentityAndContentHashes() throws {
        let diffFile = GitDiffFile(
            fileId: "sha1:old/path.swift->new/path.swift",
            path: "new/path.swift",
            previousPath: "old/path.swift",
            changeKind: .renamed,
            oldContentHash: "old-blob",
            newContentHash: "new-blob",
            contentHashAlgorithm: "git-blob-sha1",
            oldMode: 0o100644,
            newMode: 0o100755,
            additions: 7,
            deletions: 2,
            isBinary: false,
            sizeBytes: 128
        )

        let data = try JSONEncoder().encode(diffFile)
        let decodedFile = try JSONDecoder().decode(GitDiffFile.self, from: data)

        #expect(decodedFile == diffFile)
        #expect(decodedFile.fileId == "sha1:old/path.swift->new/path.swift")
        #expect(decodedFile.contentHashAlgorithm == "git-blob-sha1")
        #expect(decodedFile.oldMode == 0o100644)
        #expect(decodedFile.newMode == 0o100755)
    }

    @Test("remote and path request fields encode as strings")
    func remoteAndPathRequestFieldsEncodeAsStrings() throws {
        let request = GitCloneRequest(
            remoteURL: "git@example.com:org/repo.git",
            destinationPath: URL(fileURLWithPath: "/tmp/checkout"),
            checkoutBranch: "main"
        )

        let jsonObject = try JSONSerialization.jsonObject(with: JSONEncoder().encode(request))
        let dictionary = try #require(jsonObject as? [String: Any])

        #expect(dictionary["remoteURL"] as? String == "git@example.com:org/repo.git")
        #expect(dictionary["destinationPath"] as? String == "file:///tmp/checkout")
    }

    @Test("content requests target review endpoints and carry optional size limits")
    func contentRequestsTargetReviewEndpointsAndCarryOptionalSizeLimits() throws {
        let request = GitContentRequest(
            repositoryPath: URL(fileURLWithPath: "/tmp/repo"),
            target: .workingTree,
            path: "Sources/App.swift",
            maxSizeBytes: 1024
        )

        let data = try JSONEncoder().encode(request)
        let decodedRequest = try JSONDecoder().decode(GitContentRequest.self, from: data)
        let jsonObject = try JSONSerialization.jsonObject(with: data)
        let dictionary = try #require(jsonObject as? [String: Any])
        let target = try #require(dictionary["target"] as? [String: Any])

        #expect(decodedRequest == request)
        #expect(target["kind"] as? String == "workingTree")
        #expect(target.keys.contains("identifier") == false)
        #expect(dictionary["maxSizeBytes"] as? Int == 1024)
        #expect(decodedRequest.target == .workingTree)
        #expect(decodedRequest.maxSizeBytes == 1024)
    }

    @Test("oversized content errors carry path and limit facts")
    func oversizedContentErrorsCarryPathAndLimitFacts() throws {
        let error = GitDataPlaneError.contentTooLarge(
            path: "large.bin",
            sizeBytes: 2048,
            maxSizeBytes: 1024
        )

        let data = try JSONEncoder().encode(error)
        let decodedError = try JSONDecoder().decode(GitDataPlaneError.self, from: data)
        let jsonObject = try JSONSerialization.jsonObject(with: data)
        let dictionary = try #require(jsonObject as? [String: Any])
        let payload = try #require(dictionary["contentTooLarge"] as? [String: Any])

        #expect(decodedError == error)
        #expect(payload["path"] as? String == "large.bin")
        #expect(payload["sizeBytes"] as? Int == 2048)
        #expect(payload["maxSizeBytes"] as? Int == 1024)
    }

    @Test("process timeout errors carry redacted process failure facts")
    func processTimeoutErrorsCarryRedactedProcessFailureFacts() throws {
        let error = GitDataPlaneError.processTimedOut(
            GitRemoteProcessFailure(
                executable: "git",
                redactedArguments: ["fetch", "origin"],
                exitCode: -1,
                redactedStderr: "git process timed out after 0.1 seconds"
            ))

        let data = try JSONEncoder().encode(error)
        let decodedError = try JSONDecoder().decode(GitDataPlaneError.self, from: data)
        let jsonObject = try JSONSerialization.jsonObject(with: data)
        let dictionary = try #require(jsonObject as? [String: Any])
        let payload = try #require(dictionary["processTimedOut"] as? [String: Any])

        #expect(decodedError == error)
        #expect(payload["executable"] as? String == "git")
        #expect(payload["redactedArguments"] as? [String] == ["fetch", "origin"])
        #expect(payload["exitCode"] as? Int == -1)
        #expect(payload["redactedStderr"] as? String == "git process timed out after 0.1 seconds")
    }

    @Test("process cancellation errors carry redacted process failure facts")
    func processCancellationErrorsCarryRedactedProcessFailureFacts() throws {
        let error = GitDataPlaneError.processCancelled(
            GitRemoteProcessFailure(
                executable: "git",
                redactedArguments: ["fetch", "origin"],
                exitCode: -15,
                redactedStderr: "git process cancelled"
            ))

        let data = try JSONEncoder().encode(error)
        let decodedError = try JSONDecoder().decode(GitDataPlaneError.self, from: data)
        let jsonObject = try JSONSerialization.jsonObject(with: data)
        let dictionary = try #require(jsonObject as? [String: Any])
        let payload = try #require(dictionary["processCancelled"] as? [String: Any])

        #expect(decodedError == error)
        #expect(payload["executable"] as? String == "git")
        #expect(payload["redactedArguments"] as? [String] == ["fetch", "origin"])
        #expect(payload["exitCode"] as? Int == -15)
        #expect(payload["redactedStderr"] as? String == "git process cancelled")
    }

    @Test("process output limit errors carry stream and size facts")
    func processOutputLimitErrorsCarryStreamAndSizeFacts() throws {
        let error = GitDataPlaneError.processOutputTooLarge(
            stream: .stdout,
            sizeBytes: 256,
            maxSizeBytes: 64
        )

        let data = try JSONEncoder().encode(error)
        let decodedError = try JSONDecoder().decode(GitDataPlaneError.self, from: data)
        let jsonObject = try JSONSerialization.jsonObject(with: data)
        let dictionary = try #require(jsonObject as? [String: Any])
        let payload = try #require(dictionary["processOutputTooLarge"] as? [String: Any])

        #expect(decodedError == error)
        #expect(payload["stream"] as? String == "stdout")
        #expect(payload["sizeBytes"] as? Int == 256)
        #expect(payload["maxSizeBytes"] as? Int == 64)
    }

    private func jsonDictionary<T: Encodable>(for value: T) throws -> [String: Any] {
        let data = try JSONEncoder().encode(value)
        let jsonObject = try JSONSerialization.jsonObject(with: data)
        return try #require(jsonObject as? [String: Any])
    }
}
