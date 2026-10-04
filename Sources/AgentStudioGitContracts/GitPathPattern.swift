import Foundation

public enum GitPathPatternError: Error, Equatable, Hashable, Sendable {
    case empty
    case negationNotSupported
    case malformed
}

/// A positive gitignore pattern, parsed and compiled once. Middle slashes anchor to the repository
/// root; a trailing slash limits the pattern to directories. Matching never evaluates ignore policy.
public struct GitPathPattern: Codable, Hashable, Sendable {
    public let rawValue: String
    private let directoryOnly: Bool
    private let basenameOnly: Bool
    private let expression: NSRegularExpression

    public init(_ rawValue: String) throws(GitPathPatternError) {
        guard !rawValue.isEmpty else { throw .empty }
        guard !rawValue.hasPrefix("!") else { throw .negationNotSupported }
        var body = rawValue
        // Git discards unescaped trailing spaces, preserving an escaped final space.
        while body.hasSuffix(" ") {
            var backslashes = 0
            for character in body.dropLast().reversed() {
                guard character == "\\" else { break }
                backslashes += 1
            }
            if backslashes % 2 == 1 { break }
            body.removeLast()
        }
        directoryOnly = body.hasSuffix("/")
        if directoryOnly { body.removeLast() }
        basenameOnly = !body.contains("/")
        if body.hasPrefix("/") { body.removeFirst() }
        guard !body.isEmpty, !body.contains("\n"), !body.contains("\r"), !body.contains("\0"),
            let translated = Self.regex(fromGlob: body)
        else { throw .malformed }
        do {
            // One compiled expression supports both source case policies. The first branch captures
            // an exact-case match; the second permits folded matching only when the caller asks for it.
            expression = try NSRegularExpression(pattern: "^(?:(\(translated))|(?i:\(translated)))$")
        } catch { throw .malformed }
        self.rawValue = rawValue
    }

    public func matches(_ path: String, isDirectory: Bool, ignoreCase: Bool = false) -> Bool {
        guard !directoryOnly || isDirectory else { return false }
        let subject: Substring
        if basenameOnly, let slash = path.lastIndex(of: "/") {
            subject = path[path.index(after: slash)...]
        } else {
            subject = path[...]
        }
        let text = String(subject)
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = expression.firstMatch(in: text, range: range) else { return false }
        return ignoreCase || match.range(at: 1).location != NSNotFound
    }

    public static func == (lhs: Self, rhs: Self) -> Bool { lhs.rawValue == rhs.rawValue }
    public func hash(into hasher: inout Hasher) { hasher.combine(rawValue) }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let text = try container.decode(String.self)
        do { try self.init(text) } catch {
            throw DecodingError.dataCorruptedError(
                in: container, debugDescription: "invalid Git path pattern: \(error)")
        }
    }
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    private static func regex(fromGlob glob: String) -> String? {
        var result = ""
        let characters = Array(glob)
        var index = 0
        while index < characters.count {
            let character = characters[index]
            switch character {
            case "*":
                var end = index + 1
                while end < characters.count, characters[end] == "*" { end += 1 }
                let recursive =
                    end - index >= 2
                    && (index == 0 || characters[index - 1] == "/")
                    && (end == characters.count || characters[end] == "/")
                if recursive {
                    if end < characters.count {
                        result += "(?:.*/)?"
                        end += 1
                    } else {
                        result += ".*"
                    }
                } else {
                    result += "[^/]*"
                }
                index = end
                continue
            case "?": result += "[^/]"
            case "[":
                switch bracketExpression(characters, from: index) {
                case .translated(let translated, let next):
                    result += translated
                    index = next
                    continue
                case .unterminated: result += "\\["
                case .unsupported: return nil
                }
            case "\\":
                guard index + 1 < characters.count else { return nil }
                result += NSRegularExpression.escapedPattern(for: String(characters[index + 1]))
                index += 2
                continue
            default: result += NSRegularExpression.escapedPattern(for: String(character))
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
                    negated ? "[^/\(members)]" : (members.isEmpty ? "(?!)" : "(?:(?!/)[\(members)])")
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
