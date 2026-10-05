import Foundation

/// Git 2.52 fixed literal-prefix ** context in 1940a02dc1. Older Git cannot be that class's oracle.
struct GitNativePatternOracle: Sendable {
    enum DetectionFailure: Error {
        case unavailable(String)
    }

    // One native version read per test process, shared by all native pattern suites.
    static let installed: Result<Self, DetectionFailure> = {
        do {
            let text = try GitProcess(repositoryPath: FileManager.default.temporaryDirectory).run("--version")
            return .success(try Self(version: text))
        } catch {
            return .failure(.unavailable(String(describing: error)))
        }
    }()

    let supportsModernPrefixContext: Bool

    init(version: String) throws {
        let pieces = version.split(separator: " ")
        guard pieces.count >= 3 else { throw DetectionFailure.unavailable(version) }
        let numbers = pieces[2].split(separator: ".")
        guard numbers.count >= 2, let major = Int(numbers[0]), let minor = Int(numbers[1]) else {
            throw DetectionFailure.unavailable(version)
        }
        supportsModernPrefixContext = major > 2 || (major == 2 && minor >= 52)
    }

    func canCompare(_ pattern: String) -> Bool {
        supportsModernPrefixContext || !Self.hasGluedDoubleStar(pattern)
    }

    func canCompareSparseRules(_ rules: String) -> Bool {
        rules.split(separator: "\n").allSatisfy { canCompare(String($0)) }
    }

    /// Detect the excluded syntax without evaluating a pattern or changing the seeded corpus.
    static func hasGluedDoubleStar(_ pattern: String) -> Bool {
        let bytes = Array(pattern.utf8)
        var cursor = 0
        var literalBefore = false
        while cursor < bytes.count {
            switch bytes[cursor] {
            case 92:
                guard cursor + 1 < bytes.count else { return false }
                literalBefore = bytes[cursor + 1] != 47
                cursor += 2
            case 91:
                // Stars within a class are not wildcard runs. Malformed classes never match.
                cursor += 1
                if cursor < bytes.count, bytes[cursor] == 33 || bytes[cursor] == 94 { cursor += 1 }
                if cursor < bytes.count, bytes[cursor] == 93 { cursor += 1 }
                while cursor < bytes.count, bytes[cursor] != 93 {
                    if bytes[cursor] == 91, cursor + 1 < bytes.count, bytes[cursor + 1] == 58 {
                        cursor += 2
                        while cursor + 1 < bytes.count, !(bytes[cursor] == 58 && bytes[cursor + 1] == 93) {
                            cursor += 1
                        }
                        guard cursor + 1 < bytes.count else { return false }
                        cursor += 2
                    } else {
                        cursor += bytes[cursor] == 92 && cursor + 1 < bytes.count ? 2 : 1
                    }
                }
                guard cursor < bytes.count else { return false }
                cursor += 1
                literalBefore = false
            case 42:
                if literalBefore, cursor + 1 < bytes.count, bytes[cursor + 1] == 42 { return true }
                while cursor < bytes.count, bytes[cursor] == 42 { cursor += 1 }
                literalBefore = false
            case 63:
                literalBefore = false
                cursor += 1
            default:
                literalBefore = bytes[cursor] != 47
                cursor += 1
            }
        }
        return false
    }
}
