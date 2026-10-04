import AgentStudioGitContracts
import Foundation

/// Git-compatible evaluation of `info/sparse-checkout` patterns over tracked paths. It exists because
/// libgit2 1.9 cannot open a sparse-index source, so the patterns — not the source index — are the
/// authority for which captured-tree paths are skip-worktree in the destination.
struct SparseCheckoutMatcher: Sendable {
    private enum Mode: Sendable {
        case cone(recursiveDirectories: Set<String>, parentDirectories: Set<String>)
        case patterns([SparsePattern])
    }

    private let mode: Mode
    /// True when a pattern could not be translated. Such a matcher must not decide skip-worktree state:
    /// dropping a pattern silently would expose or hide paths the source did not.
    let hasUntranslatablePatterns: Bool

    /// `coneMode` follows `core.sparseCheckoutCone`; a pattern file that is not in cone form is evaluated
    /// with ordinary pattern rules, as Git does.
    init(patternFile: String, coneMode: Bool) {
        let lines = patternFile.split(separator: "\n", omittingEmptySubsequences: true)
            .map { String($0).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
        if coneMode, let cone = Self.coneDirectories(lines) {
            mode = .cone(recursiveDirectories: cone.recursive, parentDirectories: cone.parents)
            hasUntranslatablePatterns = false
        } else {
            let patterns = lines.compactMap(SparsePattern.init)
            mode = .patterns(patterns)
            hasUntranslatablePatterns = patterns.count != lines.count
        }
    }

    /// True when the tracked path is inside the sparse checkout (not skip-worktree).
    func includes(_ path: String) -> Bool {
        switch mode {
        case .cone(let recursiveDirectories, let parentDirectories):
            let directory = WorktreeForkDescriptors.splitParent(path).parent
            if directory.isEmpty || parentDirectories.contains(directory) {
                return true
            }
            var ancestor = directory
            while !ancestor.isEmpty {
                if recursiveDirectories.contains(ancestor) {
                    return true
                }
                ancestor = WorktreeForkDescriptors.splitParent(ancestor).parent
            }
            return false
        case .patterns(let patterns):
            return patternDecision(patterns, path: path, isDirectory: false) ?? inheritedDecision(patterns, path)
        }
    }

    /// Non-cone rule: the last matching pattern decides; an undecided path inherits its nearest decided
    /// parent directory; with nothing decided the path is outside the checkout.
    private func inheritedDecision(_ patterns: [SparsePattern], _ path: String) -> Bool {
        var directory = WorktreeForkDescriptors.splitParent(path).parent
        while !directory.isEmpty {
            if let decision = patternDecision(patterns, path: directory, isDirectory: true) {
                return decision
            }
            directory = WorktreeForkDescriptors.splitParent(directory).parent
        }
        return false
    }

    private func patternDecision(_ patterns: [SparsePattern], path: String, isDirectory: Bool) -> Bool? {
        for pattern in patterns.reversed() where pattern.matches(path, isDirectory: isDirectory) {
            return !pattern.isNegated
        }
        return nil
    }

    /// Parses Git's cone form: `/*`, `!/*/`, then `/dir/` entries, where `!/dir/*/` marks `dir` as a
    /// parent whose immediate files are included but whose subdirectories are not.
    private static func coneDirectories(_ lines: [String]) -> (recursive: Set<String>, parents: Set<String>)? {
        var included = Set<String>()
        var parents = Set<String>()
        for line in lines {
            if line == "/*" || line == "!/*/" {
                continue
            }
            if line.hasPrefix("!/"), line.hasSuffix("/*/") {
                parents.insert(unescape(String(line.dropFirst(2).dropLast(3))))
            } else if line.hasPrefix("/"), line.hasSuffix("/"), !line.contains("*") {
                included.insert(unescape(String(line.dropFirst().dropLast())))
            } else {
                return nil
            }
        }
        return (included.subtracting(parents), parents)
    }

    fileprivate static func unescape(_ text: String) -> String {
        var result = ""
        var escaping = false
        for character in text {
            if escaping || character != "\\" {
                result.append(character)
                escaping = false
            } else {
                escaping = true
            }
        }
        return result
    }
}

/// Sparse policy owns negation; the positive pattern grammar is shared with copy rules.
private struct SparsePattern: Sendable {
    let isNegated: Bool
    private let pattern: GitPathPattern

    init?(_ line: String) {
        isNegated = line.hasPrefix("!")
        let positive = isNegated ? String(line.dropFirst()) : line
        guard let pattern = try? GitPathPattern(positive) else { return nil }
        self.pattern = pattern
    }
    func matches(_ path: String, isDirectory: Bool) -> Bool {
        pattern.matches(path, isDirectory: isDirectory)
    }
}
