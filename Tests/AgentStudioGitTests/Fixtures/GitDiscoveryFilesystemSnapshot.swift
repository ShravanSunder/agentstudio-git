import Foundation

struct GitDiscoveryFilesystemSnapshot: Equatable {
    let entries: [Entry]

    struct Entry: Equatable {
        let relativePath: String
        let kind: FileAttributeType
        let contents: Data?
        let symbolicLinkDestination: String?
        let posixPermissions: Int
        let ownerAccountID: UInt
        let groupOwnerAccountID: UInt
        let size: UInt64
        let modificationDate: Date?
        let creationDate: Date?
    }

    static func capture(root: URL) throws -> Self {
        let fileManager = FileManager.default
        guard
            let enumerator = fileManager.enumerator(
                at: root,
                includingPropertiesForKeys: nil,
                options: [],
                errorHandler: { _, _ in false }
            )
        else {
            return Self(entries: [])
        }

        let standardizedRoot = root.standardizedFileURL
        let rootPrefix = standardizedRoot.path + "/"
        let urls = ([standardizedRoot] + enumerator.compactMap { $0 as? URL }).sorted { $0.path < $1.path }
        let entries = try urls.map { url in
            let attributes = try fileManager.attributesOfItem(atPath: url.path)
            let kind = attributes[.type] as? FileAttributeType ?? .typeUnknown
            let symbolicLinkDestination =
                kind == .typeSymbolicLink
                ? try fileManager.destinationOfSymbolicLink(atPath: url.path)
                : nil
            let contents = kind == .typeRegular ? try Data(contentsOf: url) : nil
            return Entry(
                relativePath: relativePath(for: url, root: standardizedRoot, rootPrefix: rootPrefix),
                kind: kind,
                contents: contents,
                symbolicLinkDestination: symbolicLinkDestination,
                posixPermissions: attributes[.posixPermissions] as? Int ?? 0,
                ownerAccountID: attributes[.ownerAccountID] as? UInt ?? 0,
                groupOwnerAccountID: attributes[.groupOwnerAccountID] as? UInt ?? 0,
                size: attributes[.size] as? UInt64 ?? 0,
                modificationDate: attributes[.modificationDate] as? Date,
                creationDate: attributes[.creationDate] as? Date
            )
        }
        return Self(entries: entries)
    }

    private static func relativePath(for url: URL, root: URL, rootPrefix: String) -> String {
        let standardizedPath = url.standardizedFileURL.path
        return standardizedPath == root.path ? "." : String(standardizedPath.dropFirst(rootPrefix.count))
    }
}

final class GitDiscoveryWritePermissionGuard: @unchecked Sendable {
    private let originalPermissionsByPath: [String: Int]
    private let lock = NSLock()
    private var isRestored = false

    private init(originalPermissionsByPath: [String: Int]) {
        self.originalPermissionsByPath = originalPermissionsByPath
    }

    static func removeWritePermissions(from root: URL) throws -> GitDiscoveryWritePermissionGuard {
        let fileManager = FileManager.default
        guard let enumerator = fileManager.enumerator(at: root, includingPropertiesForKeys: nil) else {
            return GitDiscoveryWritePermissionGuard(originalPermissionsByPath: [:])
        }
        let paths = [root.path] + enumerator.compactMap { ($0 as? URL)?.path }
        var originalPermissionsByPath: [String: Int] = [:]
        for path in paths.sorted(by: >) {
            let attributes = try fileManager.attributesOfItem(atPath: path)
            let permissions = attributes[.posixPermissions] as? Int ?? 0
            originalPermissionsByPath[path] = permissions
            try fileManager.setAttributes([.posixPermissions: permissions & ~0o222], ofItemAtPath: path)
        }
        return GitDiscoveryWritePermissionGuard(originalPermissionsByPath: originalPermissionsByPath)
    }

    func restore() {
        lock.lock()
        defer { lock.unlock() }
        guard !isRestored else {
            return
        }
        isRestored = true
        let fileManager = FileManager.default
        for (path, permissions) in originalPermissionsByPath.sorted(by: { $0.key.count < $1.key.count }) {
            try? fileManager.setAttributes([.posixPermissions: permissions], ofItemAtPath: path)
        }
    }
}
