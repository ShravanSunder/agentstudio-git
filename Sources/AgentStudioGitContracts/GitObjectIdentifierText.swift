import Foundation

/// The textual form a contract accepts for a pinned commit: a full SHA-1 or SHA-256 object identifier.
/// Abbreviations and revision expressions are rejected, because a pinned commit must not re-resolve.
package enum GitObjectIdentifierText {
    package static func isFullObjectIdentifier(_ text: String) -> Bool {
        (text.utf8.count == 40 || text.utf8.count == 64)
            && text.utf8.allSatisfy { byte in
                (byte >= 48 && byte <= 57) || (byte >= 65 && byte <= 70) || (byte >= 97 && byte <= 102)
            }
    }
}
