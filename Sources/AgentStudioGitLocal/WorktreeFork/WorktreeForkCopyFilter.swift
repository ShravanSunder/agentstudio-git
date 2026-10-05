import AgentStudioGitContracts
import CLibGit2Local
import Foundation

/// Applies policy in one top-down pass over the sorted walked plan. Classification stops at excluded,
/// include-matched, and opaque roots. A matched non-ignored directory only probes for report evidence.
struct WorktreeForkCopyFilter: Sendable {
    let cancellation: WorktreeForkCancellation

    struct Input {
        let filesystem: WorktreeForkFilesystemPlan
        let sourceRoot: URL
        let sourceCommonDirectory: URL
        let sourceGitDirectory: URL
        let capturedHead: WorktreeForkCapturedHead
        let copyRules: GitWorktreeCopyRules
    }
    struct Result: Sendable {
        let filesystem: WorktreeForkFilesystemPlan
        let ignoredIncludedPatterns: [String]
        let ignoredExcludedCount: Int
        let nestedWorktreesSkipped: [String]
        /// Internal operation-count proof, independent of clocks and host scheduling.
        let classifiedPathCount: Int
        let ignoreQueryCount: Int
    }

    func apply(_ input: Input) throws(GitWorktreeForkError) -> Result {
        try cancellation.throwIfCancelled()
        let nestedRepositories = WorktreeForkCopyNestedRepositories(
            sourceRoot: input.sourceRoot,
            commonDirectory: input.sourceCommonDirectory, cancellation: cancellation
        )
        let skipped = try nestedRepositories.sameRepositoryWorktreeRoots(input.filesystem.nestedGitEntryPaths)
        guard case .copyMatching(let patterns) = input.copyRules.ignoredPaths else {
            return Result(
                filesystem: try input.filesystem.excludingSubtrees(skipped),
                ignoredIncludedPatterns: [], ignoredExcludedCount: 0, nestedWorktreesSkipped: skipped,
                classifiedPathCount: 0, ignoreQueryCount: 0)
        }
        let tracked = try WorktreeForkCopyTrackedPaths.capture(
            sourceRoot: input.sourceRoot,
            gitDirectory: input.sourceGitDirectory, capturedHead: input.capturedHead)
        let nestedRoots = Set(
            input.filesystem.nestedGitEntryPaths.map { WorktreeForkDescriptors.splitParent($0).parent }
        )
        .union(try nestedRepositories.confirmedGitDirectoryRoots(input.filesystem.gitDirectoryCandidatePaths))
        var tree = WorktreeForkCopyTree(
            filesystem: input.filesystem, tracked: tracked,
            nestedRoots: nestedRoots, skippedWorktrees: Set(skipped))
        do {
            return try LibGit2IgnoreReader().withIgnoreSession(repositoryAt: input.sourceRoot) { session in
                try classify(
                    tree: &tree, patterns: patterns, tracked: tracked, session: session,
                    filesystem: input.filesystem, skipped: skipped)
            }
        } catch let error as GitWorktreeForkError { throw error } catch let error as GitDataPlaneError {
            throw .gitFailure(error)
        } catch { throw .gitFailure(.unsupported(message: String(describing: error))) }
    }

    private func classify(
        tree: inout WorktreeForkCopyTree, patterns: [GitPathPattern],
        tracked: WorktreeForkCopyTrackedPaths, session: LibGit2IgnoreSession,
        filesystem: WorktreeForkFilesystemPlan, skipped: [String]
    ) throws -> Result {
        var excluded = skipped
        var excludedCount = 0
        var includedPatterns = Set<Int>()
        var classifiedCount = 0
        var ignoreQueries = 0
        var pending = tree.nodes[0].children.reversed().map { ($0, false) }
        while let (index, parentIgnored) = pending.popLast() {
            try cancellation.throwIfCancelled()
            let node = tree.nodes[index]
            if node.skippedWorktree { continue }
            classifiedCount += 1
            let ignored: Bool
            if parentIgnored {
                ignored = true
            } else if node.tracked && !node.isDirectory {
                ignored = false
            } else {
                ignoreQueries += 1
                ignored = try session.isPathIgnored(relativePath: node.isDirectory ? node.path + "/" : node.path)
            }
            let matched =
                node.isDirectory || ignored
                ? tree.matches(at: index, patterns: patterns, ignoreCase: tracked.ignoreCase) : []
            if node.isDirectory && !matched.isEmpty {
                if ignored {
                    includedPatterns.formUnion(matched)
                } else if !node.opaque {
                    let evidence = try ignoredDescendantEvidence(in: tree, below: index, session: session)
                    ignoreQueries += evidence.queryCount
                    if evidence.found { includedPatterns.formUnion(matched) }
                }
                // Every matched directory carries its whole subtree, even when only a child is ignored.
                continue
            }
            if ignored && !matched.isEmpty {
                includedPatterns.formUnion(matched)
            }
            if ignored && !node.hasTrackedDescendant && matched.isEmpty {
                let includesBelow =
                    node.isDirectory && !node.opaque
                    && tree.containsIncludedDescendant(at: index, patterns: patterns, ignoreCase: tracked.ignoreCase)
                if !includesBelow {
                    excluded.append(node.path)
                    excludedCount += node.pathCount
                    continue
                }
            }
            if node.isDirectory && !node.opaque {
                pending.append(contentsOf: node.children.reversed().map { ($0, ignored) })
            }
        }
        return Result(
            filesystem: try filesystem.excludingSubtrees(excluded),
            ignoredIncludedPatterns: patterns.indices.filter { includedPatterns.contains($0) }.map {
                patterns[$0].rawValue
            },
            ignoredExcludedCount: excludedCount, nestedWorktreesSkipped: skipped,
            classifiedPathCount: classifiedCount, ignoreQueryCount: ignoreQueries)
    }

    /// Reporting only: keep the already-decided subtree without classifying it. Stop at the first
    /// ignored path, opaque repository, or same-repository skip. Matched roots are disjoint, so this
    /// lazy evidence search never rescans the population for a series of ancestors.
    private func ignoredDescendantEvidence(
        in tree: WorktreeForkCopyTree, below index: Int,
        session: LibGit2IgnoreSession
    ) throws -> (found: Bool, queryCount: Int) {
        var pending = tree.nodes[index].children.reversed().map { $0 }
        var queryCount = 0
        while let current = pending.popLast() {
            try cancellation.throwIfCancelled()
            let node = tree.nodes[current]
            if node.skippedWorktree { continue }
            if !node.tracked {
                queryCount += 1
                if try session.isPathIgnored(relativePath: node.isDirectory ? node.path + "/" : node.path) {
                    return (true, queryCount)
                }
            }
            if node.isDirectory && !node.opaque {
                pending.append(contentsOf: node.children.reversed())
            }
        }
        return (false, queryCount)
    }
}
