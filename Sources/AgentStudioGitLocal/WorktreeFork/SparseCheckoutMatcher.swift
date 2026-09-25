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
        guard !body.isEmpty, let translated = Self.regex(fromGlob: String(body)),
            let expression = try? NSRegularExpression(pattern: "^\(translated)$")
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

    /// Translates wildmatch globs: `**/` spans directories, `*` and `?` stay within one component. Returns
    /// nil for a pattern Git itself rejects (an unknown POSIX class), which the matcher then reports.
    private static func regex(fromGlob glob: String) -> String? {
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
                switch bracketExpression(characters, from: index) {
                case .translated(let expression, let next):
                    result += expression
                    index = next
                    continue
                case .unterminated:
                    result += "\\["
                case .unsupported:
                    return nil
                }
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

    private enum BracketTranslation {
        case translated(String, next: Int)
        case unterminated
        case unsupported
    }

    private static let posixClasses: Set<String> = [
        "alnum", "alpha", "blank", "cntrl", "digit", "graph", "lower", "print", "punct", "space", "upper", "xdigit",
    ]

    /// Translates one Git bracket expression into an ICU class built only from code-point escapes, ranges, and
    /// known POSIX classes, so ICU set syntax (`&&`, nested `[`, `\p`) can never leak in. A leading `]` is a
    /// member, `!`/`^` negates (never matching `/`, as under Git's pathname rule), and a reversed range
    /// matches nothing.
    private static func bracketExpression(_ characters: [Character], from start: Int) -> BracketTranslation {
        var index = start + 1
        var negated = false
        if index < characters.count, characters[index] == "!" || characters[index] == "^" {
            negated = true
            index += 1
        }
        var members = ""
        var isFirst = true
        while index < characters.count {
            let character = characters[index]
            if character == "]", !isFirst {
                let expression =
                    negated ? "[^/\(members)]" : (members.isEmpty ? "(?!)" : "[\(members)]")
                return .translated(expression, next: index + 1)
            }
            isFirst = false
            if character == "[", index + 1 < characters.count, characters[index + 1] == ":" {
                guard let end = posixClassEnd(characters, from: index + 2) else {
                    return .unsupported
                }
                let name = String(characters[(index + 2)..<end])
                guard posixClasses.contains(name) else {
                    return .unsupported
                }
                members += "[:\(name):]"
                index = end + 2
                continue
            }
            var lower = character
            if character == "\\", index + 1 < characters.count {
                index += 1
                lower = characters[index]
            }
            if index + 2 < characters.count, characters[index + 1] == "-", characters[index + 2] != "]" {
                var upper = characters[index + 2]
                var consumed = 3
                if upper == "\\", index + 3 < characters.count {
                    upper = characters[index + 3]
                    consumed = 4
                }
                if let low = lower.unicodeScalars.first?.value, let high = upper.unicodeScalars.first?.value,
                    low <= high
                {
                    members += "\\x{\(String(low, radix: 16))}-\\x{\(String(high, radix: 16))}"
                }
                index += consumed
                continue
            }
            for scalar in lower.unicodeScalars {
                members += "\\x{\(String(scalar.value, radix: 16))}"
            }
            index += 1
        }
        return .unterminated
    }

    private static func posixClassEnd(_ characters: [Character], from start: Int) -> Int? {
        var index = start
        while index + 1 < characters.count {
            if characters[index] == ":", characters[index + 1] == "]" {
                return index
            }
            index += 1
        }
        return nil
    }
}
