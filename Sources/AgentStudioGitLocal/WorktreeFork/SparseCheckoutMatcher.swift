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
    private let ignoreCase: Bool
    /// True when a pattern could not be translated. Such a matcher must not decide skip-worktree state:
    /// dropping a pattern silently would expose or hide paths the source did not.
    let hasUntranslatablePatterns: Bool

    /// `coneMode` follows `core.sparseCheckoutCone`; a pattern file that is not in cone form is evaluated
    /// with ordinary pattern rules, as Git does.
    init(patternFile: String, coneMode: Bool, ignoreCase: Bool = false) {
        self.ignoreCase = ignoreCase
        let lines = patternFile.components(separatedBy: "\n")
            .map { $0.hasSuffix("\r") ? String($0.dropLast()) : $0 }
            .filter { !$0.isEmpty && $0.utf8.first != 35 && !$0.utf8.allSatisfy { $0 == 32 } }
        if coneMode, !ignoreCase, let cone = Self.coneDirectories(lines) {
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
            let directory = Self.parentPath(path)
            if directory.isEmpty || parentDirectories.contains(directory) {
                return true
            }
            var ancestor = directory
            while !ancestor.isEmpty {
                if recursiveDirectories.contains(ancestor) {
                    return true
                }
                ancestor = Self.parentPath(ancestor)
            }
            return false
        case .patterns(let patterns):
            return patternDecision(patterns, path: path, isDirectory: false) ?? inheritedDecision(patterns, path)
        }
    }

    /// Non-cone rule: the last matching pattern decides; an undecided path inherits its nearest decided
    /// parent directory; with nothing decided the path is outside the checkout.
    private func inheritedDecision(_ patterns: [SparsePattern], _ path: String) -> Bool {
        var directory = Self.parentPath(path)
        while !directory.isEmpty {
            if let decision = patternDecision(patterns, path: directory, isDirectory: true) {
                return decision
            }
            directory = Self.parentPath(directory)
        }
        return false
    }

    /// Git separators are bytes, even when followed by a combining mark in the next filename.
    private static func parentPath(_ path: String) -> String {
        let bytes = Array(path.utf8)
        guard let slash = bytes.lastIndex(of: 47) else { return "" }
        return String(bytes: bytes[..<slash], encoding: .utf8) ?? ""
    }

    private func patternDecision(_ patterns: [SparsePattern], path: String, isDirectory: Bool) -> Bool? {
        for pattern in patterns.reversed() where pattern.matches(path, isDirectory: isDirectory, ignoreCase: ignoreCase)
        {
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
    private enum Compilation: Sendable {
        case pattern(GitPathPattern)
        case neverMatches
    }
    let isNegated: Bool
    private let compilation: Compilation

    init?(_ line: String) {
        let bytes = Array(line.utf8)
        isNegated = bytes.first == 33
        let positiveBytes = isNegated ? Array(bytes.dropFirst()) : bytes
        guard let positive = String(bytes: positiveBytes, encoding: .utf8) else { return nil }
        // Sparse policy has consumed its one negation byte. Remaining ! or # markers are literal.
        // An existing middle slash already anchors the rule. Spell that anchor explicitly for !,
        // so an injected escape does not incorrectly end match_pathname's glob-free literal prefix.
        let body = positiveBytes.last == 47 ? positiveBytes.dropLast() : positiveBytes[...]
        let literalLeadingMarker =
            positiveBytes.first == 33 || positiveBytes.first == 35
            ? (body.contains(47) ? "/" + positive : "\\" + positive) : positive
        do {
            compilation = .pattern(try GitPathPattern(literalLeadingMarker))
        } catch {
            // A trailing escape or unknown POSIX class aborts Git matching for this line only.
            // Unsupported control bytes retain the existing fail-closed file behavior.
            guard !positiveBytes.contains(0), !positiveBytes.contains(10), !positiveBytes.contains(13) else {
                return nil
            }
            switch error {
            case .empty, .malformed: compilation = .neverMatches
            case .negationNotSupported: return nil
            }
        }
    }
    func matches(_ path: String, isDirectory: Bool, ignoreCase: Bool) -> Bool {
        switch compilation {
        case .pattern(let pattern): pattern.matches(path, isDirectory: isDirectory, ignoreCase: ignoreCase)
        case .neverMatches: false
        }
    }
}
