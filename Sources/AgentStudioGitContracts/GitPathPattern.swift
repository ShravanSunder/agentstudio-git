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
    private let compiledPattern: GitWildmatchPattern

    public init(_ rawValue: String) throws(GitPathPatternError) {
        var body = Array(rawValue.utf8)
        guard !body.isEmpty else { throw .empty }
        guard body.first != 33 else { throw .negationNotSupported }
        guard body.first != 35 else { throw .malformed }
        // Syntax markers are bytes too: a following combining mark must not be consumed with them.
        // Git discards unescaped trailing spaces, preserving an escaped final space.
        while body.last == 32 {
            var backslashes = 0
            for byte in body.dropLast().reversed() {
                guard byte == 92 else { break }
                backslashes += 1
            }
            if backslashes % 2 == 1 { break }
            body.removeLast()
        }
        directoryOnly = body.last == 47
        if directoryOnly { body.removeLast() }
        basenameOnly = !body.contains(47)
        if body.first == 47 { body.removeFirst() }
        guard !body.isEmpty, !body.contains(10), !body.contains(13), !body.contains(0) else { throw .malformed }
        compiledPattern = try GitWildmatchPattern(bytes: body)
        self.rawValue = rawValue
    }

    public func matches(_ path: String, isDirectory: Bool, ignoreCase: Bool = false) -> Bool {
        guard !directoryOnly || isDirectory else { return false }
        let bytes = Array(path.utf8)
        guard !bytes.contains(0) else { return false }
        let start = basenameOnly ? bytes.lastIndex(of: 47).map { $0 + 1 } ?? 0 : 0
        return compiledPattern.matches(bytes[start...], ignoreCase: ignoreCase)
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

}
