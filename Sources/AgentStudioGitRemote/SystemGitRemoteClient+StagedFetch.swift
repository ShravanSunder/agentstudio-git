import AgentStudioGitContracts
import Foundation

extension SystemGitRemoteClient {
    public func captureRemoteTrackingSnapshot(
        _ request: GitRemoteTrackingSnapshotRequest
    ) async throws(GitDataPlaneError) -> GitRemoteTrackingSnapshot {
        try validateRemoteName(request.remoteName)
        let configuredRemoteURLResult = try await runner.run(arguments: [
            "-C",
            request.repositoryPath.path,
            "config",
            "--get",
            "remote.\(request.remoteName).url",
        ])
        let configuredRemoteURL = configuredRemoteURLResult.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !configuredRemoteURL.isEmpty, !configuredRemoteURL.contains("\n") else {
            throw GitDataPlaneError.unsupported(message: "configured remote URL lookup returned an invalid value")
        }
        let effectiveRemoteURLResult = try await runner.run(arguments: [
            "-C",
            request.repositoryPath.path,
            "remote",
            "get-url",
            "--",
            request.remoteName,
        ])
        let effectiveFetchURL = effectiveRemoteURLResult.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !effectiveFetchURL.isEmpty, !effectiveFetchURL.contains("\n") else {
            throw GitDataPlaneError.unsupported(message: "effective remote URL lookup returned an invalid value")
        }
        try validateRemoteProtocol(effectiveFetchURL)
        let repositoryCommonDirectory = try await resolvedCommonDirectory(
            repositoryPath: request.repositoryPath
        )
        let canonicalNamespace = canonicalRemoteNamespace(request.remoteName)

        return GitRemoteTrackingSnapshot(
            repositoryPath: request.repositoryPath,
            repositoryCommonDirectory: repositoryCommonDirectory,
            remoteName: request.remoteName,
            configuredRemoteURL: configuredRemoteURL,
            effectiveFetchURL: effectiveFetchURL,
            references: try await references(
                repositoryCommonDirectory: repositoryCommonDirectory,
                namespace: canonicalNamespace
            ).map {
                GitRemoteTrackingReference(canonicalRefName: $0.refName, oid: $0.oid)
            }
        )
    }

    public func stageFetch(_ request: GitStagedFetchRequest) async throws(GitDataPlaneError)
        -> GitStagedFetchResult
    {
        try validateSnapshot(request.snapshot)
        let currentCommonDirectory = try await resolvedCommonDirectory(
            repositoryPath: request.snapshot.repositoryPath
        )
        guard currentCommonDirectory == request.snapshot.repositoryCommonDirectory else {
            throw GitDataPlaneError.unsupported(message: "repository common directory changed after capture")
        }
        let handle = GitStagedFetchHandle(
            repositoryCommonDirectory: request.snapshot.repositoryCommonDirectory,
            stagingID: request.stagingID
        )
        let stagingNamespace = handle.stagingNamespace
        let existingStagingReferences = try await references(
            repositoryCommonDirectory: request.snapshot.repositoryCommonDirectory,
            namespace: stagingNamespace
        )
        guard existingStagingReferences.isEmpty else {
            throw GitDataPlaneError.unsupported(message: "staged fetch namespace is already occupied")
        }

        let stagedRemoteNamespace = "\(stagingNamespace)heads/"
        _ = try await runner.run(arguments: [
            "--git-dir",
            request.snapshot.repositoryCommonDirectory.path,
            "fetch",
            "--porcelain",
            "--atomic",
            "--no-write-fetch-head",
            "--no-tags",
            "--no-prune",
            "--no-prune-tags",
            "--no-recurse-submodules",
            "--no-auto-maintenance",
            "--no-write-commit-graph",
            "--refmap=",
            "--",
            request.snapshot.effectiveFetchURL,
            "+refs/heads/*:\(stagedRemoteNamespace)*",
        ])

        let stagedReferences = try await references(
            repositoryCommonDirectory: request.snapshot.repositoryCommonDirectory,
            namespace: stagedRemoteNamespace
        )
        return try makeStagedFetchResult(
            snapshot: request.snapshot,
            handle: handle,
            stagedReferences: stagedReferences
        )
    }

    public func promoteStagedFetch(
        _ request: GitPromoteStagedFetchRequest
    ) async throws(GitDataPlaneError) -> GitPromoteStagedFetchResult {
        try validateStagedFetch(request.stagedFetch)
        let actualStagedReferences = try await references(
            repositoryCommonDirectory: request.stagedFetch.snapshot.repositoryCommonDirectory,
            namespace: request.stagedFetch.stagingNamespace
        )
        let expectedStagedReferences =
            (request.stagedFetch.updates.map {
                GitRefRecord(refName: $0.stagingRefName, oid: $0.newOID)
            }
            + request.stagedFetch.verifications.map {
                GitRefRecord(refName: $0.stagingRefName, oid: $0.expectedOID)
            }).sorted { $0.refName < $1.refName }
        guard actualStagedReferences == expectedStagedReferences else {
            throw GitDataPlaneError.unsupported(message: "staged fetch namespace changed before promotion")
        }
        let reconstructedPlan = try makeStagedFetchResult(
            snapshot: request.stagedFetch.snapshot,
            handle: request.stagedFetch.handle,
            stagedReferences: actualStagedReferences
        )
        guard reconstructedPlan == request.stagedFetch else {
            throw GitDataPlaneError.unsupported(message: "staged fetch plan is incomplete or inconsistent")
        }

        var commands: [GitRefTransactionCommand] = [.start]
        for update in request.stagedFetch.updates {
            if let expectedOldOID = update.expectedOldOID {
                commands.append(
                    .update(
                        refName: update.canonicalRefName,
                        newOID: update.newOID,
                        expectedOldOID: expectedOldOID
                    )
                )
            } else {
                commands.append(.create(refName: update.canonicalRefName, newOID: update.newOID))
            }
            commands.append(.delete(refName: update.stagingRefName, expectedOldOID: update.newOID))
        }
        for verification in request.stagedFetch.verifications {
            commands.append(
                .verify(
                    refName: verification.canonicalRefName,
                    expectedOID: verification.expectedOID
                )
            )
            commands.append(
                .delete(
                    refName: verification.stagingRefName,
                    expectedOldOID: verification.expectedOID
                )
            )
        }
        for deletion in request.stagedFetch.deletions {
            commands.append(
                .delete(
                    refName: deletion.canonicalRefName,
                    expectedOldOID: deletion.expectedOldOID
                )
            )
        }
        commands.append(.prepare)
        commands.append(.commit)
        do {
            try await runRefTransaction(
                repositoryCommonDirectory: request.stagedFetch.snapshot.repositoryCommonDirectory,
                commands: commands
            )
        } catch let transactionError {
            switch try await promotionOutcome(after: transactionError, stagedFetch: request.stagedFetch) {
            case .promoted:
                break
            case .notPromoted:
                throw transactionError
            case .indeterminate:
                throw GitDataPlaneError.remoteRefTransactionIndeterminate(
                    message: "staged remote-ref promotion outcome is indeterminate"
                )
            }
        }
        return GitPromoteStagedFetchResult(
            updatedRefNames: request.stagedFetch.updates.map(\.canonicalRefName),
            deletedRefNames: request.stagedFetch.deletions.map(\.canonicalRefName)
        )
    }

    public func cleanupStagedFetch(
        _ request: GitCleanupStagedFetchRequest
    ) async throws(GitDataPlaneError) -> GitCleanupStagedFetchResult {
        let stagingNamespace = request.handle.stagingNamespace
        try validateStagingNamespace(stagingNamespace)
        let stagedReferences = try await references(
            repositoryCommonDirectory: request.handle.repositoryCommonDirectory,
            namespace: stagingNamespace
        )
        guard !stagedReferences.isEmpty else {
            return GitCleanupStagedFetchResult(deletedRefNames: [], retainedRefNames: [])
        }

        var commands: [GitRefTransactionCommand] = [.start]
        commands.append(
            contentsOf: stagedReferences.map {
                .delete(refName: $0.refName, expectedOldOID: $0.oid)
            }
        )
        commands.append(.prepare)
        commands.append(.commit)
        try await runRefTransaction(
            repositoryCommonDirectory: request.handle.repositoryCommonDirectory,
            commands: commands
        )
        let retainedReferences = try await references(
            repositoryCommonDirectory: request.handle.repositoryCommonDirectory,
            namespace: stagingNamespace
        )
        return GitCleanupStagedFetchResult(
            deletedRefNames: stagedReferences.map(\.refName),
            retainedRefNames: retainedReferences.map(\.refName)
        )
    }

    public func cleanupAbandonedStagedFetches(
        _ request: GitCleanupAbandonedStagedFetchesRequest
    ) async throws(GitDataPlaneError) -> GitCleanupStagedFetchResult {
        let allStagedReferences = try await references(
            repositoryCommonDirectory: request.repositoryCommonDirectory,
            namespace: "refs/agentstudio/staged/"
        )
        let abandonedReferences = allStagedReferences.filter { reference in
            guard let stagingID = stagingID(from: reference.refName) else { return false }
            return !request.retainedStagingIDs.contains(stagingID)
        }
        guard !abandonedReferences.isEmpty else {
            return GitCleanupStagedFetchResult(
                deletedRefNames: [],
                retainedRefNames: allStagedReferences.map(\.refName)
            )
        }
        var commands: [GitRefTransactionCommand] = [.start]
        commands.append(
            contentsOf: abandonedReferences.map {
                .delete(refName: $0.refName, expectedOldOID: $0.oid)
            }
        )
        commands.append(.prepare)
        commands.append(.commit)
        try await runRefTransaction(
            repositoryCommonDirectory: request.repositoryCommonDirectory,
            commands: commands
        )
        let retainedReferences = try await references(
            repositoryCommonDirectory: request.repositoryCommonDirectory,
            namespace: "refs/agentstudio/staged/"
        )
        return GitCleanupStagedFetchResult(
            deletedRefNames: abandonedReferences.map(\.refName),
            retainedRefNames: retainedReferences.map(\.refName)
        )
    }

    private func references(
        repositoryCommonDirectory: URL,
        namespace: String
    ) async throws(GitDataPlaneError) -> [GitRefRecord] {
        let result = try await runner.run(arguments: [
            "--git-dir",
            repositoryCommonDirectory.path,
            "for-each-ref",
            "--format=%(refname)%09%(objectname)%09%(symref)",
            namespace,
        ])
        var references: [GitRefRecord] = []
        for rawLine in result.stdout.split(separator: "\n") {
            let fields = rawLine.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
            guard fields.count == 3 else {
                throw GitDataPlaneError.unsupported(message: "malformed local ref output")
            }
            let refName = String(fields[0])
            guard fields[2].isEmpty else { continue }
            let oid = String(fields[1])
            try validateRefName(refName, namespace: namespace)
            try validateOID(oid)
            references.append(GitRefRecord(refName: refName, oid: oid))
        }
        return references.sorted { $0.refName < $1.refName }
    }

    private func resolvedCommonDirectory(repositoryPath: URL) async throws(GitDataPlaneError) -> URL {
        let result = try await runner.run(arguments: [
            "-C",
            repositoryPath.path,
            "rev-parse",
            "--path-format=absolute",
            "--git-common-dir",
        ])
        let path = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard path.hasPrefix("/") else {
            throw GitDataPlaneError.unsupported(message: "git common directory was not absolute")
        }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    private func makeStagedFetchResult(
        snapshot: GitRemoteTrackingSnapshot,
        handle: GitStagedFetchHandle,
        stagedReferences: [GitRefRecord]
    ) throws(GitDataPlaneError) -> GitStagedFetchResult {
        let stagedRemoteNamespace = "\(handle.stagingNamespace)heads/"
        let capturedReferencesByName = Dictionary(
            uniqueKeysWithValues: snapshot.references.map { ($0.canonicalRefName, $0) }
        )
        var stagedCanonicalRefNames = Set<String>()
        var updates: [GitStagedFetchUpdate] = []
        var verifications: [GitStagedFetchVerification] = []
        for stagedReference in stagedReferences {
            guard stagedReference.refName.hasPrefix(stagedRemoteNamespace) else {
                throw GitDataPlaneError.unsupported(message: "staged fetch produced an unexpected ref")
            }
            let branchSuffix = String(stagedReference.refName.dropFirst(stagedRemoteNamespace.count))
            let canonicalRefName = "\(canonicalRemoteNamespace(snapshot.remoteName))\(branchSuffix)"
            guard stagedCanonicalRefNames.insert(canonicalRefName).inserted else {
                throw GitDataPlaneError.unsupported(message: "staged fetch produced a duplicate canonical ref")
            }
            let expectedOldOID = capturedReferencesByName[canonicalRefName]?.oid
            if expectedOldOID == stagedReference.oid {
                verifications.append(
                    GitStagedFetchVerification(
                        stagingRefName: stagedReference.refName,
                        canonicalRefName: canonicalRefName,
                        expectedOID: stagedReference.oid
                    )
                )
            } else {
                updates.append(
                    GitStagedFetchUpdate(
                        stagingRefName: stagedReference.refName,
                        canonicalRefName: canonicalRefName,
                        newOID: stagedReference.oid,
                        expectedOldOID: expectedOldOID
                    )
                )
            }
        }
        updates.sort { $0.canonicalRefName < $1.canonicalRefName }
        verifications.sort { $0.canonicalRefName < $1.canonicalRefName }
        let deletions: [GitStagedFetchDeletion] = snapshot.references.compactMap { capturedReference in
            guard !stagedCanonicalRefNames.contains(capturedReference.canonicalRefName) else {
                return nil
            }
            return GitStagedFetchDeletion(
                canonicalRefName: capturedReference.canonicalRefName,
                expectedOldOID: capturedReference.oid
            )
        }
        .sorted { $0.canonicalRefName < $1.canonicalRefName }
        return GitStagedFetchResult(
            snapshot: snapshot,
            handle: handle,
            updates: updates,
            verifications: verifications,
            deletions: deletions
        )
    }

    private func promotionOutcome(
        after _: GitDataPlaneError,
        stagedFetch: GitStagedFetchResult
    ) async throws(GitDataPlaneError) -> GitStagedFetchPromotionOutcome {
        let actualStagedReferences = try await references(
            repositoryCommonDirectory: stagedFetch.snapshot.repositoryCommonDirectory,
            namespace: stagedFetch.stagingNamespace
        )
        let expectedStagedReferences =
            (stagedFetch.updates.map { GitRefRecord(refName: $0.stagingRefName, oid: $0.newOID) }
            + stagedFetch.verifications.map {
                GitRefRecord(refName: $0.stagingRefName, oid: $0.expectedOID)
            }).sorted { $0.refName < $1.refName }
        if actualStagedReferences == expectedStagedReferences {
            return .notPromoted
        }
        guard actualStagedReferences.isEmpty else { return .indeterminate }

        let canonicalReferences = try await references(
            repositoryCommonDirectory: stagedFetch.snapshot.repositoryCommonDirectory,
            namespace: canonicalRemoteNamespace(stagedFetch.snapshot.remoteName)
        )
        let canonicalOIDsByRefName = Dictionary(
            uniqueKeysWithValues: canonicalReferences.map { ($0.refName, $0.oid) }
        )
        guard stagedFetch.updates.allSatisfy({ canonicalOIDsByRefName[$0.canonicalRefName] == $0.newOID }),
            stagedFetch.verifications.allSatisfy({
                canonicalOIDsByRefName[$0.canonicalRefName] == $0.expectedOID
            }),
            stagedFetch.deletions.allSatisfy({ canonicalOIDsByRefName[$0.canonicalRefName] == nil })
        else {
            return .indeterminate
        }
        return .promoted
    }

    private func runRefTransaction(
        repositoryCommonDirectory: URL,
        commands: [GitRefTransactionCommand]
    ) async throws(GitDataPlaneError) {
        _ = try await runner.run(
            arguments: [
                "--git-dir",
                repositoryCommonDirectory.path,
                "update-ref",
                "--no-deref",
                "--stdin",
                "-z",
            ],
            standardInput: GitRefTransactionEncoder.encode(commands)
        )
    }

    private func validateSnapshot(_ snapshot: GitRemoteTrackingSnapshot) throws(GitDataPlaneError) {
        try validateRemoteName(snapshot.remoteName)
        guard !snapshot.configuredRemoteURL.isEmpty,
            !snapshot.configuredRemoteURL.contains("\n"),
            snapshot.repositoryCommonDirectory.path.hasPrefix("/")
        else {
            throw GitDataPlaneError.unsupported(message: "remote tracking snapshot provenance is malformed")
        }
        try validateRemoteProtocol(snapshot.effectiveFetchURL)
        let canonicalNamespace = canonicalRemoteNamespace(snapshot.remoteName)
        var refNames = Set<String>()
        for reference in snapshot.references {
            try validateRefName(reference.canonicalRefName, namespace: canonicalNamespace)
            guard reference.canonicalRefName != "\(canonicalNamespace)HEAD" else {
                throw GitDataPlaneError.unsupported(message: "remote HEAD is not a promotable tracking ref")
            }
            try validateOID(reference.oid)
            guard refNames.insert(reference.canonicalRefName).inserted else {
                throw GitDataPlaneError.unsupported(message: "remote tracking snapshot contains duplicate refs")
            }
        }
    }

    private func validateStagedFetch(_ stagedFetch: GitStagedFetchResult) throws(GitDataPlaneError) {
        try validateSnapshot(stagedFetch.snapshot)
        try validateStagingNamespace(stagedFetch.stagingNamespace)
        guard stagedFetch.handle.repositoryCommonDirectory == stagedFetch.snapshot.repositoryCommonDirectory else {
            throw GitDataPlaneError.unsupported(message: "staged fetch handle does not match its repository")
        }
        let canonicalNamespace = canonicalRemoteNamespace(stagedFetch.snapshot.remoteName)
        let capturedReferencesByName = Dictionary(
            uniqueKeysWithValues: stagedFetch.snapshot.references.map { ($0.canonicalRefName, $0.oid) }
        )
        var canonicalRefNames = Set<String>()
        for update in stagedFetch.updates {
            try validateRefName(update.stagingRefName, namespace: stagedFetch.stagingNamespace)
            try validateRefName(update.canonicalRefName, namespace: canonicalNamespace)
            let branchSuffix = String(update.canonicalRefName.dropFirst(canonicalNamespace.count))
            guard update.stagingRefName == "\(stagedFetch.stagingNamespace)heads/\(branchSuffix)" else {
                throw GitDataPlaneError.unsupported(message: "staged ref does not map to its canonical ref")
            }
            try validateOID(update.newOID)
            if let expectedOldOID = update.expectedOldOID {
                try validateOID(expectedOldOID)
            }
            guard update.expectedOldOID == capturedReferencesByName[update.canonicalRefName] else {
                throw GitDataPlaneError.unsupported(message: "staged update does not match captured provenance")
            }
            guard canonicalRefNames.insert(update.canonicalRefName).inserted else {
                throw GitDataPlaneError.unsupported(message: "staged fetch contains duplicate canonical refs")
            }
        }
        for verification in stagedFetch.verifications {
            try validateRefName(verification.stagingRefName, namespace: stagedFetch.stagingNamespace)
            try validateRefName(verification.canonicalRefName, namespace: canonicalNamespace)
            let branchSuffix = String(verification.canonicalRefName.dropFirst(canonicalNamespace.count))
            guard verification.stagingRefName == "\(stagedFetch.stagingNamespace)heads/\(branchSuffix)" else {
                throw GitDataPlaneError.unsupported(message: "staged verification does not map to its canonical ref")
            }
            try validateOID(verification.expectedOID)
            guard capturedReferencesByName[verification.canonicalRefName] == verification.expectedOID else {
                throw GitDataPlaneError.unsupported(message: "staged verification does not match captured provenance")
            }
            guard canonicalRefNames.insert(verification.canonicalRefName).inserted else {
                throw GitDataPlaneError.unsupported(message: "staged fetch contains duplicate canonical refs")
            }
        }
        for deletion in stagedFetch.deletions {
            try validateRefName(deletion.canonicalRefName, namespace: canonicalNamespace)
            try validateOID(deletion.expectedOldOID)
            guard capturedReferencesByName[deletion.canonicalRefName] == deletion.expectedOldOID else {
                throw GitDataPlaneError.unsupported(message: "staged deletion does not match captured provenance")
            }
            guard canonicalRefNames.insert(deletion.canonicalRefName).inserted else {
                throw GitDataPlaneError.unsupported(message: "staged fetch contains duplicate canonical refs")
            }
        }
    }

    private func validateRemoteName(_ remoteName: String) throws(GitDataPlaneError) {
        let allowedScalars = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._/"))
        guard !remoteName.isEmpty,
            !remoteName.hasPrefix("-"),
            !remoteName.hasPrefix("/"),
            !remoteName.hasSuffix("/"),
            !remoteName.hasSuffix("."),
            !remoteName.hasSuffix(".lock"),
            !remoteName.contains(".."),
            !remoteName.contains("//"),
            !remoteName.contains("@{"),
            remoteName.unicodeScalars.allSatisfy(allowedScalars.contains)
        else {
            throw GitDataPlaneError.unsupported(message: "remote name is not safe for ref construction")
        }
    }

    private func validateStagingNamespace(_ namespace: String) throws(GitDataPlaneError) {
        let prefix = "refs/agentstudio/staged/"
        guard namespace.hasPrefix(prefix), namespace.hasSuffix("/") else {
            throw GitDataPlaneError.unsupported(message: "staged fetch namespace is outside the reserved prefix")
        }
        let identifier = String(namespace.dropFirst(prefix.count).dropLast())
        guard UUID(uuidString: identifier) != nil else {
            throw GitDataPlaneError.unsupported(message: "staged fetch namespace has an invalid identifier")
        }
    }

    private func stagingID(from refName: String) -> UUID? {
        let prefix = "refs/agentstudio/staged/"
        guard refName.hasPrefix(prefix) else { return nil }
        let suffix = refName.dropFirst(prefix.count)
        guard let identifier = suffix.split(separator: "/", maxSplits: 1).first else { return nil }
        return UUID(uuidString: String(identifier))
    }

    private func validateRefName(_ refName: String, namespace: String) throws(GitDataPlaneError) {
        guard refName.hasPrefix(namespace),
            refName.count > namespace.count,
            !refName.contains("\t"),
            !refName.contains("\n"),
            !refName.contains(".."),
            !refName.contains("@{"),
            !refName.hasSuffix("."),
            !refName.hasSuffix(".lock")
        else {
            throw GitDataPlaneError.unsupported(message: "ref name is outside the expected namespace")
        }
    }

    private func validateOID(_ oid: String) throws(GitDataPlaneError) {
        let hexadecimalScalars = CharacterSet(charactersIn: "0123456789abcdefABCDEF")
        guard [40, 64].contains(oid.count), oid.unicodeScalars.allSatisfy(hexadecimalScalars.contains) else {
            throw GitDataPlaneError.unsupported(message: "ref object ID is malformed")
        }
    }

    private func canonicalRemoteNamespace(_ remoteName: String) -> String {
        "refs/remotes/\(remoteName)/"
    }
}

private struct GitRefRecord: Equatable, Sendable {
    let refName: String
    let oid: String
}

private enum GitStagedFetchPromotionOutcome: Sendable {
    case promoted
    case notPromoted
    case indeterminate
}
