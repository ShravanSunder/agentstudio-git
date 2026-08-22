import AgentStudioGitContracts
import CLibGit2Local
import Foundation

private struct LibGit2CommitTraversalBudget {
    let maximumVisitCount: Int
    private(set) var visitedCommitCount = 0

    var remainingVisitCount: Int {
        maximumVisitCount - visitedCommitCount
    }

    mutating func admitVisit() -> Bool {
        guard visitedCommitCount < maximumVisitCount else { return false }
        visitedCommitCount += 1
        return true
    }
}

private struct LibGit2CommitGraphDiscovery {
    let commitOIDs: [git_oid]
    let encounteredStopOID: Bool
    let includesMerge: Bool
}

private enum LibGit2CommitGraphDiscoveryOutcome {
    case complete(LibGit2CommitGraphDiscovery)
    case traversalLimitReached
}

struct LibGit2CommitRangeCounter: Sendable {
    func count(_ request: GitCommitRangeCountRequest) throws -> GitCommitRangeCount {
        guard request.maximumCount > 0 else {
            throw GitDataPlaneError.unsupported(message: "commit range maximumCount must be positive")
        }
        guard request.maximumTraversalCount > 0 else {
            throw GitDataPlaneError.unsupported(message: "commit range maximumTraversalCount must be positive")
        }
        return try LibGit2ReviewSupport.withRepository(at: request.repositoryPath) { repository in
            let baseCommit = try LibGit2ReviewSupport.resolveCommit(request.base, repository: repository)
            defer { git_commit_free(baseCommit) }
            let candidateCommit = try LibGit2ReviewSupport.resolveCommit(request.candidate, repository: repository)
            defer { git_commit_free(candidateCommit) }

            guard let baseOIDPointer = git_commit_id(baseCommit),
                let candidateOIDPointer = git_commit_id(candidateCommit)
            else {
                throw GitDataPlaneError.unsupported(message: "libgit2 resolved a commit without an object ID")
            }
            let baseOID = baseOIDPointer.pointee
            let candidateOID = candidateOIDPointer.pointee
            if Self.oidsAreEqual(baseOID, candidateOID) {
                return .exact(0)
            }

            var traversalBudget = LibGit2CommitTraversalBudget(
                maximumVisitCount: request.maximumTraversalCount
            )
            let candidateOutcome = try discoverCommitGraph(
                startingAt: candidateOID,
                stoppingBefore: baseOID,
                repository: repository,
                traversalBudget: &traversalBudget
            )
            guard case .complete(let candidateDiscovery) = candidateOutcome else {
                return .traversalLimitReached(request.maximumTraversalCount)
            }

            if candidateDiscovery.encounteredStopOID, !candidateDiscovery.includesMerge {
                return Self.boundedResult(
                    exactCount: candidateDiscovery.commitOIDs.count,
                    maximumCount: request.maximumCount
                )
            }

            let baseOutcome = try discoverCommitGraph(
                startingAt: baseOID,
                stoppingBefore: nil,
                repository: repository,
                traversalBudget: &traversalBudget
            )
            guard case .complete(let baseDiscovery) = baseOutcome else {
                return .traversalLimitReached(request.maximumTraversalCount)
            }

            let candidateOnlyCount = candidateDiscovery.commitOIDs.count { candidateOID in
                !Self.contains(candidateOID, in: baseDiscovery.commitOIDs)
            }
            if candidateOnlyCount >= request.maximumCount {
                return .atLeastLimit(request.maximumCount)
            }
            guard candidateDiscovery.encounteredStopOID else {
                return .unrelated
            }
            return .exact(candidateOnlyCount)
        }
    }

    private func discoverCommitGraph(
        startingAt startOID: git_oid,
        stoppingBefore stopOID: git_oid?,
        repository: OpaquePointer,
        traversalBudget: inout LibGit2CommitTraversalBudget
    ) throws -> LibGit2CommitGraphDiscoveryOutcome {
        var pendingOIDs = [startOID]
        var visitedOIDs: [git_oid] = []
        var encounteredStopOID = false
        var includesMerge = false

        while let currentOID = pendingOIDs.popLast() {
            if let stopOID, Self.oidsAreEqual(currentOID, stopOID) {
                encounteredStopOID = true
                continue
            }
            guard !Self.contains(currentOID, in: visitedOIDs) else { continue }
            guard traversalBudget.admitVisit() else { return .traversalLimitReached }

            var lookupOID = currentOID
            var commit: OpaquePointer?
            let lookupResult = git_commit_lookup(&commit, repository, &lookupOID)
            guard lookupResult >= 0, let commit else {
                throw LibGit2ErrorCapture.failure(code: lookupResult)
            }
            defer { git_commit_free(commit) }

            visitedOIDs.append(currentOID)
            let parentCount = Int(git_commit_parentcount(commit))
            includesMerge = includesMerge || parentCount > 1
            guard parentCount <= traversalBudget.remainingVisitCount + 1 else {
                return .traversalLimitReached
            }

            for parentIndex in 0..<parentCount {
                guard let parentOIDPointer = git_commit_parent_id(commit, UInt32(parentIndex)) else {
                    throw GitDataPlaneError.unsupported(
                        message: "libgit2 returned a commit without a parent object ID"
                    )
                }
                let parentOID = parentOIDPointer.pointee
                if let stopOID, Self.oidsAreEqual(parentOID, stopOID) {
                    encounteredStopOID = true
                    continue
                }
                guard !Self.contains(parentOID, in: visitedOIDs),
                    !Self.contains(parentOID, in: pendingOIDs)
                else { continue }
                guard pendingOIDs.count < traversalBudget.remainingVisitCount else {
                    return .traversalLimitReached
                }
                pendingOIDs.append(parentOID)
            }
        }

        return .complete(
            LibGit2CommitGraphDiscovery(
                commitOIDs: visitedOIDs,
                encounteredStopOID: encounteredStopOID,
                includesMerge: includesMerge
            )
        )
    }

    private static func boundedResult(exactCount: Int, maximumCount: Int) -> GitCommitRangeCount {
        exactCount >= maximumCount ? .atLeastLimit(maximumCount) : .exact(exactCount)
    }

    private static func contains(_ targetOID: git_oid, in candidateOIDs: [git_oid]) -> Bool {
        candidateOIDs.contains { oidsAreEqual(targetOID, $0) }
    }

    private static func oidsAreEqual(_ lhs: git_oid, _ rhs: git_oid) -> Bool {
        var lhs = lhs
        var rhs = rhs
        return git_oid_equal(&lhs, &rhs) != 0
    }
}
