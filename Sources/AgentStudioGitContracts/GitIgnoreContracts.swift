import Foundation

public struct GitIgnoreCheck: Codable, Equatable, Hashable, Sendable {
    public let relativePath: String
    public let isIgnored: Bool

    public init(relativePath: String, isIgnored: Bool) {
        self.relativePath = relativePath
        self.isIgnored = isIgnored
    }
}
