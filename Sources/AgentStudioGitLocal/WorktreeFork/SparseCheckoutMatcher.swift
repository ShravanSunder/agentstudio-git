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

    /// `coneMode` follows `core.sparseCheckoutCone`; a pattern file that is not in cone form is evaluated
    /// with ordinary pattern rules, as Git does.
    init(patternFile: String, coneMode: Bool) {
        let lines = patternFile.split(separator: "\n", omittingEmptySubsequences: true)
            .map { String($0).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
        if coneMode, let cone = Self.coneDirectories(lines) {
            mode = .cone(recursiveDirectories: cone.recursive, parentDirectories: cone.parents)
        } else {
            mode = .patterns(lines.compactMap(SparsePattern.init))
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

/// One gitignore-syntax sparse pattern.
private struct SparsePattern: Sendable {
    let isNegated: Bool
    let directoryOnly: Bool
    let matchesBasenameOnly: Bool
    let expression: NSRegularExpression

    init?(_ line: String) {
        var body = Substring(line)
        isNegated = body.hasPrefix("!")
        if isNegated {
            body = body.dropFirst()
        }
        directoryOnly = body.hasSuffix("/")
        if directoryOnly {
            body = body.dropLast()
        }
        matchesBasenameOnly = !body.contains("/")
        if body.hasPrefix("/") {
            body = body.dropFirst()
        }
        guard !body.isEmpty,
            let expression = try? NSRegularExpression(pattern: "^\(Self.regex(fromGlob: String(body)))$")
        else {
            return nil
        }
        self.expression = expression
    }

    func matches(_ path: String, isDirectory: Bool) -> Bool {
        if directoryOnly, !isDirectory {
            return false
        }
        let subject = matchesBasenameOnly ? WorktreeForkDescriptors.splitParent(path).name : path
        let range = NSRange(subject.startIndex..<subject.endIndex, in: subject)
        return expression.firstMatch(in: subject, range: range) != nil
    }

    /// Translates wildmatch globs: `**/` spans directories, `*` and `?` stay within one component.
    private static func regex(fromGlob glob: String) -> String {
        var result = ""
        let characters = Array(glob)
        var index = 0
        while index < characters.count {
            let character = characters[index]
            switch character {
            case "*" where index + 1 < characters.count && characters[index + 1] == "*":
                let followedBySlash = index + 2 < characters.count && characters[index + 2] == "/"
                result += followedBySlash ? "(?:.*/)?" : ".*"
                index += followedBySlash ? 3 : 2
                continue
            case "*":
                result += "[^/]*"
            case "?":
                result += "[^/]"
            case "[":
                if let close = characters[(index + 1)...].firstIndex(of: "]") {
                    var set = String(characters[(index + 1)..<close])
                    if set.hasPrefix("!") {
                        set = "^" + set.dropFirst()
                    }
                    result += "[\(set)]"
                    index = close + 1
                    continue
                }
                result += "\\["
            case "\\" where index + 1 < characters.count:
                result += NSRegularExpression.escapedPattern(for: String(characters[index + 1]))
                index += 2
                continue
            default:
                result += NSRegularExpression.escapedPattern(for: String(character))
            }
            index += 1
        }
        return result
    }
}
