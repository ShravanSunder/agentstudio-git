import AgentStudioGitContracts
import Foundation

extension SystemGitRemoteClient {
    public func cleanupStagedFetch(
        _ request: GitCleanupStagedFetchRequest
    ) async throws(GitDataPlaneError) -> GitCleanupStagedFetchResult {
        let stagingNamespace = request.handle.stagingNamespace
        try validateStagingNamespace(stagingNamespace)
        var deletedRefNames: [String] = []

        while true {
            let stagedReferences = try await boundedStagedReferences(
                repositoryCommonDirectory: request.handle.repositoryCommonDirectory,
                namespace: stagingNamespace
            )
            guard !stagedReferences.isEmpty else { break }
            try await deleteStagedReferences(
                stagedReferences,
                repositoryCommonDirectory: request.handle.repositoryCommonDirectory
            )
            deletedRefNames.append(contentsOf: stagedReferences.map(\.refName))
        }

        return GitCleanupStagedFetchResult(
            deletedRefNames: deletedRefNames,
            retainedRefNames: []
        )
    }

    public func cleanupAbandonedStagedFetches(
        _ request: GitCleanupAbandonedStagedFetchesRequest
    ) async throws(GitDataPlaneError) -> GitCleanupStagedFetchResult {
        let stagedNamespace = "refs/agentstudio/staged/"
        let retainedNamespaces = request.retainedStagingIDs
            .map { "\(stagedNamespace)\($0.uuidString.lowercased())/" }
            .sorted()
        var excludedPatterns = retainedNamespaces
        var deletedRefNames: [String] = []
        var retainedReferencesOutsideActiveNamespaces: [GitRefRecord] = []

        while true {
            let candidateReferences = try await boundedStagedReferences(
                repositoryCommonDirectory: request.repositoryCommonDirectory,
                namespace: stagedNamespace,
                excludedPatterns: excludedPatterns
            )
            guard !candidateReferences.isEmpty else { break }

            let abandonedReferences = candidateReferences.filter {
                stagingID(from: $0.refName) != nil
            }
            let unrecognizedReferences = candidateReferences.filter {
                stagingID(from: $0.refName) == nil
            }
            retainedReferencesOutsideActiveNamespaces.append(contentsOf: unrecognizedReferences)
            excludedPatterns.append(contentsOf: unrecognizedReferences.map(\.refName))

            guard !abandonedReferences.isEmpty else { continue }
            // Cleanup debt is retryable. Committing each bounded page makes forward progress without
            // weakening expected-OID protection inside that page.
            try await deleteStagedReferences(
                abandonedReferences,
                repositoryCommonDirectory: request.repositoryCommonDirectory
            )
            deletedRefNames.append(contentsOf: abandonedReferences.map(\.refName))
        }

        var retainedRefNames = retainedReferencesOutsideActiveNamespaces.map(\.refName)
        for retainedNamespace in retainedNamespaces {
            // A completed active stage has already enumerated this namespace through the same output
            // bound. An oversized failed stage stops being retained and becomes cleanup debt.
            let retainedReferences = try await references(
                repositoryCommonDirectory: request.repositoryCommonDirectory,
                namespace: retainedNamespace
            )
            retainedRefNames.append(contentsOf: retainedReferences.map(\.refName))
        }

        return GitCleanupStagedFetchResult(
            deletedRefNames: deletedRefNames.sorted(),
            retainedRefNames: retainedRefNames.sorted()
        )
    }

    private var stagedCleanupReferencePageCount: Int {
        let conservativeBytesPerReference = 512
        let outputBoundedCount = Int(configuration.capturedOutputLimitBytes) / conservativeBytesPerReference
        return max(1, min(outputBoundedCount, 512))
    }

    private func boundedStagedReferences(
        repositoryCommonDirectory: URL,
        namespace: String,
        excludedPatterns: [String] = []
    ) async throws(GitDataPlaneError) -> [GitRefRecord] {
        var pageCount = stagedCleanupReferencePageCount
        while true {
            do {
                return try await references(
                    repositoryCommonDirectory: repositoryCommonDirectory,
                    namespace: namespace,
                    count: pageCount,
                    excludedPatterns: excludedPatterns
                )
            } catch let error {
                guard case .processOutputTooLarge = error, pageCount > 1 else {
                    throw error
                }
                pageCount = max(1, pageCount / 2)
            }
        }
    }

    private func deleteStagedReferences(
        _ references: [GitRefRecord],
        repositoryCommonDirectory: URL
    ) async throws(GitDataPlaneError) {
        var commands: [GitRefTransactionCommand] = [.start]
        commands.append(
            contentsOf: references.map {
                .delete(refName: $0.refName, expectedOldOID: $0.oid)
            }
        )
        commands.append(.prepare)
        commands.append(.commit)
        try await runRefTransaction(
            repositoryCommonDirectory: repositoryCommonDirectory,
            commands: commands
        )
    }
}
