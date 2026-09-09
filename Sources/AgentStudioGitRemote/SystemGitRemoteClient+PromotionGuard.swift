import AgentStudioGitContracts
import Foundation

extension SystemGitRemoteClient {
    func createPromotionGuard(
        for stagedFetch: GitStagedFetchResult
    ) async throws(GitDataPlaneError) -> GitStagedFetchPromotionGuard {
        guard
            let guardOID = stagedFetch.updates.first?.newOID
                ?? stagedFetch.verifications.first?.expectedOID
                ?? stagedFetch.deletions.first?.expectedOldOID
        else {
            throw GitDataPlaneError.unsupported(
                message: "mutation-bearing staged fetch has no object for its promotion guard"
            )
        }
        let promotionGuard = GitStagedFetchPromotionGuard(
            refName: "\(stagedFetch.stagingNamespace)promotion-guard",
            expectedOID: guardOID
        )
        try await runRefTransaction(
            repositoryCommonDirectory: stagedFetch.snapshot.repositoryCommonDirectory,
            commands: [
                .start,
                .create(refName: promotionGuard.refName, newOID: promotionGuard.expectedOID),
                .prepare,
                .commit,
            ]
        )
        return promotionGuard
    }

    func runRefTransaction(
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
}

extension GitStagedFetchResult {
    var requiresPromotionGuard: Bool {
        !updates.isEmpty || !verifications.isEmpty || !deletions.isEmpty
    }
}
