import AgentStudioGitContracts
import Foundation

/// One sorted parent/child view of the walked plan. Hard-link secondaries are real paths here. Counts
/// include opaque repository content, while policy lookup never descends into an opaque repository.
struct WorktreeForkCopyTree {
    struct Node {
        let path: String
        let isDirectory: Bool
        let opaque: Bool
        let tracked: Bool
        let skippedWorktree: Bool
        var children: [Int] = []
        var pathCount: Int = 1
        var hasTrackedDescendant: Bool = false
        var matchingPatterns: [Int]?
        var hasIncludedDescendant: Bool?
    }
    var nodes: [Node]

    init(
        filesystem: WorktreeForkFilesystemPlan, tracked: WorktreeForkCopyTrackedPaths,
        nestedRoots: Set<String>, skippedWorktrees: Set<String>
    ) {
        nodes = [Node(path: "", isDirectory: true, opaque: false, tracked: false, skippedWorktree: false, pathCount: 0)]
        var indexByPath: [String: Int] = ["": 0]
        for directory in filesystem.directories where !directory.relativePath.isEmpty {
            append(
                path: directory.relativePath, isDirectory: true, tracked: tracked,
                nestedRoots: nestedRoots, skippedWorktrees: skippedWorktrees, indexByPath: &indexByPath)
        }
        for leaf in filesystem.allPlannedLeaves {
            append(
                path: leaf.relativePath, isDirectory: false, tracked: tracked,
                nestedRoots: nestedRoots, skippedWorktrees: skippedWorktrees, indexByPath: &indexByPath)
        }
        for index in nodes.indices {
            let sorted = nodes[index].children.sorted { nodes[$0].path < nodes[$1].path }
            nodes[index].children = sorted
        }
        for index in nodes.indices.reversed() {
            let childIndices = nodes[index].children
            nodes[index].pathCount += childIndices.reduce(0) { $0 + nodes[$1].pathCount }
            nodes[index].hasTrackedDescendant =
                !nodes[index].skippedWorktree
                && (nodes[index].tracked
                    || childIndices.contains { nodes[$0].hasTrackedDescendant })
        }
    }

    private mutating func append(
        path: String, isDirectory: Bool, tracked: WorktreeForkCopyTrackedPaths,
        nestedRoots: Set<String>, skippedWorktrees: Set<String>, indexByPath: inout [String: Int]
    ) {
        let parent = WorktreeForkDescriptors.splitParent(path).parent
        guard let parentIndex = indexByPath[parent] else { return }
        let index = nodes.count
        let lookupPath = tracked.ignoreCase ? path.lowercased() : path
        nodes.append(
            Node(
                path: path, isDirectory: isDirectory, opaque: nestedRoots.contains(path),
                tracked: tracked.paths.contains(lookupPath), skippedWorktree: skippedWorktrees.contains(path)))
        nodes[parentIndex].children.append(index)
        indexByPath[path] = index
    }

    mutating func matches(at index: Int, patterns: [GitPathPattern], ignoreCase: Bool) -> [Int] {
        if let cached = nodes[index].matchingPatterns { return cached }
        let matched = patterns.indices.filter {
            patterns[$0].matches(nodes[index].path, isDirectory: nodes[index].isDirectory, ignoreCase: ignoreCase)
        }
        nodes[index].matchingPatterns = matched
        return matched
    }

    /// Computed only below an ignored directory that did not itself match. Every node is cached and
    /// opaque roots stop lookup, so a series of ancestors cannot rescan the same candidate population.
    mutating func containsIncludedDescendant(at index: Int, patterns: [GitPathPattern], ignoreCase: Bool) -> Bool {
        if patterns.isEmpty { return false }
        if let cached = nodes[index].hasIncludedDescendant { return cached }
        var pending: [(Int, Bool)] = nodes[index].children.reversed().map { ($0, false) }
        while let (current, visited) = pending.popLast() {
            if nodes[current].hasIncludedDescendant != nil { continue }
            if nodes[current].skippedWorktree {
                nodes[current].hasIncludedDescendant = false
            } else if !matches(at: current, patterns: patterns, ignoreCase: ignoreCase).isEmpty {
                nodes[current].hasIncludedDescendant = true
            } else if nodes[current].opaque || nodes[current].children.isEmpty {
                nodes[current].hasIncludedDescendant = false
            } else if visited {
                nodes[current].hasIncludedDescendant = nodes[current].children.contains {
                    nodes[$0].hasIncludedDescendant == true
                }
            } else {
                pending.append((current, true))
                pending.append(contentsOf: nodes[current].children.reversed().map { ($0, false) })
            }
        }
        let included = nodes[index].children.contains { nodes[$0].hasIncludedDescendant == true }
        nodes[index].hasIncludedDescendant = included
        return included
    }
}
