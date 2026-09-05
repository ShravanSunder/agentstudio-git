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
    let commitOIDKeys: Set<LibGit2CommitOIDKey>
    let encounteredStopOID: Bool
    let includesMerge: Bool
}

private struct LibGit2CommitOIDKey: Hashable {
    let bytes0Through7: UInt64
    let bytes8Through15: UInt64
    let bytes16Through23: UInt64
    let bytes24Through31: UInt64
    let bytes32Through39: UInt64

    init(_ oid: git_oid) {
        var oid = oid
        precondition(MemoryLayout<git_oid>.size <= 40)
        var fixedBytes = (UInt64(0), UInt64(0), UInt64(0), UInt64(0), UInt64(0))
        withUnsafeMutableBytes(of: &fixedBytes) { destination in
            withUnsafeBytes(of: &oid) { source in
                destination.copyBytes(from: source)
            }
        }
        bytes0Through7 = fixedBytes.0
        bytes8Through15 = fixedBytes.1
        bytes16Through23 = fixedBytes.2
        bytes24Through31 = fixedBytes.3
        bytes32Through39 = fixedBytes.4
    }
}

private struct LibGit2PendingCommitOID {
    let oid: git_oid
    let key: LibGit2CommitOIDKey
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
            let baseOIDKey = LibGit2CommitOIDKey(baseOID)
            let candidateOIDKey = LibGit2CommitOIDKey(candidateOID)
            if baseOIDKey == candidateOIDKey {
                return .exact(0)
            }

            var traversalBudget = LibGit2CommitTraversalBudget(
                maximumVisitCount: request.maximumTraversalCount
            )
            let candidateOutcome = try discoverCommitGraph(
                startingAt: candidateOID,
                stoppingBefore: baseOIDKey,
                repository: repository,
                traversalBudget: &traversalBudget
            )
            guard case .complete(let candidateDiscovery) = candidateOutcome else {
                return .traversalLimitReached(request.maximumTraversalCount)
            }

            if candidateDiscovery.encounteredStopOID, !candidateDiscovery.includesMerge {
                return Self.boundedResult(
                    exactCount: candidateDiscovery.commitOIDKeys.count,
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

            let candidateOnlyCount = candidateDiscovery.commitOIDKeys.count { candidateOIDKey in
                !baseDiscovery.commitOIDKeys.contains(candidateOIDKey)
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
        stoppingBefore stopOIDKey: LibGit2CommitOIDKey?,
        repository: OpaquePointer,
        traversalBudget: inout LibGit2CommitTraversalBudget
    ) throws -> LibGit2CommitGraphDiscoveryOutcome {
        let startOIDKey = LibGit2CommitOIDKey(startOID)
        var pendingOIDs = [LibGit2PendingCommitOID(oid: startOID, key: startOIDKey)]
        var pendingOIDKeys: Set<LibGit2CommitOIDKey> = [startOIDKey]
        var visitedOIDKeys: Set<LibGit2CommitOIDKey> = []
        var encounteredStopOID = false
        var includesMerge = false

        while let current = pendingOIDs.popLast() {
            pendingOIDKeys.remove(current.key)
            if current.key == stopOIDKey {
                encounteredStopOID = true
                continue
            }
            guard visitedOIDKeys.insert(current.key).inserted else { continue }
            guard traversalBudget.admitVisit() else { return .traversalLimitReached }

            var lookupOID = current.oid
            var commit: OpaquePointer?
            let lookupResult = git_commit_lookup(&commit, repository, &lookupOID)
            guard lookupResult >= 0, let commit else {
                throw LibGit2ErrorCapture.failure(code: lookupResult)
            }
            defer { git_commit_free(commit) }

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
                let parentOIDKey = LibGit2CommitOIDKey(parentOID)
                if parentOIDKey == stopOIDKey {
                    encounteredStopOID = true
                    continue
                }
                guard !visitedOIDKeys.contains(parentOIDKey), !pendingOIDKeys.contains(parentOIDKey) else { continue }
                guard pendingOIDs.count < traversalBudget.remainingVisitCount else {
                    return .traversalLimitReached
                }
                pendingOIDs.append(LibGit2PendingCommitOID(oid: parentOID, key: parentOIDKey))
                pendingOIDKeys.insert(parentOIDKey)
            }
        }

        return .complete(
            LibGit2CommitGraphDiscovery(
                commitOIDKeys: visitedOIDKeys,
                encounteredStopOID: encounteredStopOID,
                includesMerge: includesMerge
            )
        )
    }

    private static func boundedResult(exactCount: Int, maximumCount: Int) -> GitCommitRangeCount {
        exactCount >= maximumCount ? .atLeastLimit(maximumCount) : .exact(exactCount)
    }
}
