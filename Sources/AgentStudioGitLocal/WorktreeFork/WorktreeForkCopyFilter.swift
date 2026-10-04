import AgentStudioGitContracts
import CLibGit2Local
import Foundation

/// Applies copy-on-write policy after the source walker has captured the filesystem and before Git
/// topology is captured. The walked plan is the candidate universe, so tracked files inside ignored
/// directories remain visible and are never mistaken for ignored roots.
struct WorktreeForkCopyFilter: Sendable {
    private let cancellation: WorktreeForkCancellation
    private let runtime: LibGit2Runtime

    init(cancellation: WorktreeForkCancellation, runtime: LibGit2Runtime = .shared) {
        self.cancellation = cancellation
        self.runtime = runtime
    }

    struct Result: Sendable {
        let filesystem: WorktreeForkFilesystemPlan
        let ignoredIncludedPatterns: [String]
        let ignoredExcludedCount: Int
        let nestedWorktreesSkipped: [String]
    }

    func apply(
        filesystem: WorktreeForkFilesystemPlan,
        sourceRoot: URL,
        sourceCommonDirectory: URL,
        sourceIndex: WorktreeForkSourceIndexSnapshot?,
        capturedHead: WorktreeForkCapturedHead,
        copyRules: GitWorktreeCopyRules
    ) throws(GitWorktreeForkError) -> Result {
        try cancellation.throwIfCancelled()
        let nestedRepositoryRoots = Self.nestedRepositoryRoots(filesystem.nestedGitEntryPaths)
        let sameRepositoryWorktrees = try sameRepositoryWorktreeRoots(
            nestedRepositoryRoots,
            sourceRoot: sourceRoot,
            sourceCommonDirectory: sourceCommonDirectory
        )
        guard case .copyMatching(let patterns) = copyRules.ignoredPaths else {
            return Result(
                filesystem: try filesystem.excludingSubtrees(sameRepositoryWorktrees),
                ignoredIncludedPatterns: [],
                ignoredExcludedCount: 0,
                nestedWorktreesSkipped: sameRepositoryWorktrees.sorted()
            )
        }
        guard let sourceIndex else {
            throw .rejected(reason: .sourceIndexUnreadable)
        }
        let headTrackedPaths = try capturedHeadPaths(sourceRoot: sourceRoot, capturedHead: capturedHead)
        let ignored: [IgnoredEntry]
        do {
            ignored = try ignoredEntries(
                filesystem: filesystem,
                sourceRoot: sourceRoot,
                nestedRepositoryRoots: nestedRepositoryRoots,
                trackedPaths: Set(sourceIndex.entries.keys).union(headTrackedPaths)
            )
        } catch let error as GitWorktreeForkError {
            throw error
        } catch let error as GitDataPlaneError {
            throw .gitFailure(error)
        } catch {
            throw .gitFailure(.unsupported(message: String(describing: error)))
        }
        let decision = ignoredDecision(
            filesystem: filesystem,
            ignored: ignored,
            patterns: patterns,
            nestedRepositoryRoots: nestedRepositoryRoots
        )
        let excludedSubtrees = decision.excludedRoots + sameRepositoryWorktrees
        return Result(
            filesystem: try filesystem.excludingSubtrees(excludedSubtrees),
            ignoredIncludedPatterns: decision.includedPatterns,
            ignoredExcludedCount: decision.excludedCount,
            nestedWorktreesSkipped: sameRepositoryWorktrees.sorted()
        )
    }

    private struct IgnoredEntry: Sendable {
        let path: String
        let isDirectory: Bool
        let tracked: Bool
        let ignored: Bool
    }

    private func ignoredEntries(
        filesystem: WorktreeForkFilesystemPlan,
        sourceRoot: URL,
        nestedRepositoryRoots: [String],
        trackedPaths: Set<String>
    ) throws -> [IgnoredEntry] {
        let candidates = Self.candidateEntries(filesystem: filesystem, nestedRepositoryRoots: nestedRepositoryRoots)
        return try LibGit2IgnoreReader(runtime: runtime).withIgnoreSession(repositoryAt: sourceRoot) { session in
            try candidates.map { candidate in
                try cancellation.throwIfCancelled()
                return IgnoredEntry(
                    path: candidate.path,
                    isDirectory: candidate.isDirectory,
                    tracked: trackedPaths.contains(candidate.path),
                    ignored: try session.isPathIgnored(
                        relativePath: candidate.isDirectory ? candidate.path + "/" : candidate.path
                    )
                )
            }
        }
    }

    private struct CandidateEntry: Sendable {
        let path: String
        let isDirectory: Bool
    }

    private static func candidateEntries(
        filesystem: WorktreeForkFilesystemPlan,
        nestedRepositoryRoots: [String]
    ) -> [CandidateEntry] {
        func isNested(_ path: String) -> Bool {
            nestedRepositoryRoots.contains { WorktreeForkFilesystemPlan.isPath(path, within: $0) }
        }
        let directories = filesystem.directories
            .filter { !$0.relativePath.isEmpty && !isNested($0.relativePath) }
            .map { CandidateEntry(path: $0.relativePath, isDirectory: true) }
        let leaves = filesystem.leafBatches.flatMap(\.leaves)
            .filter { !isNested($0.relativePath) }
            .map { CandidateEntry(path: $0.relativePath, isDirectory: false) }
        let skipped = filesystem.skippedEntries
            .filter { !isNested($0.relativePath) }
            .map { CandidateEntry(path: $0.relativePath, isDirectory: $0.kind == .directory) }
        return (directories + leaves + skipped).sorted { $0.path < $1.path }
    }

    private struct IgnoredDecision {
        let excludedRoots: [String]
        let includedPatterns: [String]
        let excludedCount: Int
    }

    private func ignoredDecision(
        filesystem: WorktreeForkFilesystemPlan,
        ignored: [IgnoredEntry],
        patterns: [GitPathPattern],
        nestedRepositoryRoots: [String]
    ) -> IgnoredDecision {
        let ignoredByPath = Dictionary(uniqueKeysWithValues: ignored.map { ($0.path, $0) })
        let directories = filesystem.directories.map(\.relativePath)
            .filter { path in
                !path.isEmpty
                    && !nestedRepositoryRoots.contains { root in
                        WorktreeForkFilesystemPlan.isPath(path, within: root)
                    }
            }
            .sorted { ($0.count, $0) < ($1.count, $1) }
        var excludedRoots: [String] = []
        var includedPatternSet = Set<String>()

        func matchingPatterns(for path: String, isDirectory: Bool) -> [GitPathPattern] {
            patterns.filter { pattern in
                if pattern.matches(path, isDirectory: isDirectory) { return true }
                var ancestor = path
                while let slash = ancestor.lastIndex(of: "/") {
                    ancestor = String(ancestor[..<slash])
                    if pattern.matches(ancestor, isDirectory: true) { return true }
                }
                return false
            }
        }

        func isAlreadyExcluded(_ path: String) -> Bool {
            excludedRoots.contains { WorktreeForkFilesystemPlan.isPath(path, within: $0) }
        }

        for directory in directories {
            guard let entry = ignoredByPath[directory], entry.ignored, !entry.tracked else {
                continue
            }
            let descendants = ignored.filter {
                WorktreeForkFilesystemPlan.isPath($0.path, within: directory)
            }
            guard !descendants.isEmpty else { continue }
            let matchedHere = matchingPatterns(for: directory, isDirectory: true)
            let matchedDescendants = descendants.flatMap {
                matchingPatterns(for: $0.path, isDirectory: $0.isDirectory)
            }
            if !matchedHere.isEmpty {
                includedPatternSet.formUnion(matchedHere.map(\.rawValue))
            } else if descendants.allSatisfy({ $0.ignored && !$0.tracked }) && matchedDescendants.isEmpty {
                if !isAlreadyExcluded(directory) {
                    excludedRoots.append(directory)
                }
            } else {
                includedPatternSet.formUnion(matchedDescendants.map(\.rawValue))
            }
        }

        for entry in ignored
        where !entry.isDirectory && entry.ignored && !entry.tracked && !isAlreadyExcluded(entry.path) {
            let matched = matchingPatterns(for: entry.path, isDirectory: entry.isDirectory)
            if matched.isEmpty {
                excludedRoots.append(entry.path)
            } else {
                includedPatternSet.formUnion(matched.map(\.rawValue))
            }
        }
        return IgnoredDecision(
            excludedRoots: excludedRoots.sorted(),
            includedPatterns: patterns.filter { includedPatternSet.contains($0.rawValue) }.map(\.rawValue),
            excludedCount: excludedRoots.count
        )
    }

    private static func nestedRepositoryRoots(_ gitEntryPaths: [String]) -> [String] {
        var roots = Set<String>()
        for path in gitEntryPaths {
            roots.insert(WorktreeForkDescriptors.splitParent(path).parent)
        }
        return roots.filter { !$0.isEmpty }.sorted()
    }

    private func capturedHeadPaths(
        sourceRoot: URL,
        capturedHead: WorktreeForkCapturedHead
    ) throws(GitWorktreeForkError) -> Set<String> {
        let repository = try WorktreeForkGitHandles.openWorktree(sourceRoot)
        defer { git_repository_free(repository) }
        return Set(try WorktreeForkGitHandles.treeEntries(capturedHead.treeOID, repository: repository).keys)
    }

    private func sameRepositoryWorktreeRoots(
        _ nestedRepositoryRoots: [String],
        sourceRoot: URL,
        sourceCommonDirectory: URL
    ) throws(GitWorktreeForkError) -> [String] {
        do {
            try runtime.ensureInitialized()
        } catch let error as GitDataPlaneError {
            throw .gitFailure(error)
        } catch {
            throw .gitFailure(.unsupported(message: String(describing: error)))
        }
        var matches: [String] = []
        for relativePath in nestedRepositoryRoots {
            try cancellation.throwIfCancelled()
            let nodeRoot = sourceRoot.appending(path: relativePath)
            var repository: OpaquePointer?
            let openResult = nodeRoot.path.withCString {
                git_repository_open_ext(&repository, $0, GIT_REPOSITORY_OPEN_NO_SEARCH.rawValue, nil)
            }
            guard openResult >= 0, let repository else {
                continue
            }
            let matchesSource: Bool
            if let commonPointer = git_repository_commondir(repository),
                case .success(let commonDirectory) = WorktreeForkDescriptors.realpathURL(
                    URL(fileURLWithPath: String(cString: commonPointer))),
                commonDirectory.path == sourceCommonDirectory.path
            {
                matchesSource = true
            } else {
                matchesSource = false
            }
            git_repository_free(repository)
            if matchesSource {
                matches.append(relativePath)
            }
        }
        return matches
    }
}
