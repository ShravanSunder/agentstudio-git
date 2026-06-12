import Foundation

public enum GitPathCanonicalizer {
    public static func canonicalURL(for url: URL) -> URL {
        url.standardizedFileURL.resolvingSymlinksInPath()
    }
}
