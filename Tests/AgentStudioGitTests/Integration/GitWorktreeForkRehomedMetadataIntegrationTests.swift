import AgentStudioGit
import Darwin
import Foundation
import Testing

@testable import AgentStudioGitLocal

/// Re-homing rewrites cloned administrative files such as a nested `.git/HEAD` on a fresh inode. The specification makes loss of ACL access semantics, extended attributes, or file flags a failure,
/// so each rewrite must carry the replaced file's metadata.
@Suite("Git worktree fork re-homed file metadata integration", .serialized)
struct GitWorktreeForkRehomedMetadataIntegrationTests {
    private static let nestedHead = ".build/checkouts/dependency/.git/HEAD"

    @Test("a rewritten nested HEAD keeps the replaced file's metadata", arguments: RehomedFileMetadata.allCases)
    func rewrittenNestedHeadKeepsMetadata(metadata: RehomedFileMetadata) async throws {
        // Arrange
        let fixture = try GitWorktreeForkFixture.make(prefix: "agentstudio-git-fork-head-metadata")
        let sourceHead = fixture.source.appending(path: Self.nestedHead)
        let destinationHead = fixture.destination().appending(path: Self.nestedHead)
        defer {
            clearProtection(sourceHead)
            clearProtection(destinationHead)
            fixture.remove()
        }
        try fixture.write(".gitignore", ".build/\n")
        try fixture.git.run("add", ".gitignore")
        try fixture.git.run("commit", "-qm", "ignore build")
        let checkout = fixture.source.appending(path: ".build/checkouts/dependency")
        try makeRepository(at: checkout, file: "Package.swift", fixture: fixture)
        try metadata.apply(to: sourceHead)

        // Act
        _ = try await LibGit2AgentStudioGitLocalClient().forkWorktree(fixture.request())

        // Assert
        let destinationCheckout = fixture.destination().appending(path: ".build/checkouts/dependency")
        #expect(try fixture.blobID("HEAD", at: destinationCheckout) == fixture.blobID("HEAD", at: checkout))
        #expect(metadata.isCarried(by: destinationHead), "\(metadata) on the rewritten HEAD")
        let sourceInfo = try #require(GitWorktreeForkFileProbe.info(sourceHead))
        let destinationInfo = try #require(GitWorktreeForkFileProbe.info(destinationHead))
        #expect(destinationInfo.st_mode & 0o7777 == sourceInfo.st_mode & 0o7777)
        #expect(
            destinationInfo.st_flags & WorktreeForkEntryMetadata.reproducibleFlagMask
                == sourceInfo.st_flags & WorktreeForkEntryMetadata.reproducibleFlagMask)
        #expect(probeAttribute(destinationHead) == probeAttribute(sourceHead))
        #expect(accessControlText(destinationHead) == accessControlText(sourceHead))
    }

    @discardableResult
    private func makeRepository(at path: URL, file: String, fixture: GitWorktreeForkFixture) throws -> URL {
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        try fixture.git.run(["init", "-q"], currentDirectory: path)
        try fixture.write(file, "\(file)\n", in: path)
        try fixture.git.run(["add", "."], currentDirectory: path)
        try fixture.git.run(["commit", "-qm", "initial"], currentDirectory: path)
        return path
    }

    /// Lifts flags, the extended ACL, and the read-only mode so fixture cleanup can delete the file.
    private func clearProtection(_ url: URL) {
        _ = lchflags(url.path, 0)
        if let empty = acl_init(0) {
            _ = acl_set_link_np(url.path, ACL_TYPE_EXTENDED, empty)
            acl_free(UnsafeMutableRawPointer(empty))
        }
        _ = chmod(url.path, 0o644)
    }
}

private let probeAttributeName = "com.example.forklab"

/// One piece of metadata a cloned administrative file can carry into the fork.
enum RehomedFileMetadata: String, CaseIterable, Sendable, CustomStringConvertible {
    case extendedAttribute
    case userImmutableFlag
    case appendOnlyFlag
    case denyDeleteAccessControlEntry
    case everythingOnReadOnlyFile

    var description: String {
        rawValue
    }

    func apply(to url: URL) throws {
        if self == .extendedAttribute || self == .everythingOnReadOnlyFile {
            try #require(setxattr(url.path, probeAttributeName, "x", 1, 0, XATTR_NOFOLLOW) == 0)
        }
        if self == .denyDeleteAccessControlEntry || self == .everythingOnReadOnlyFile {
            let accessControlList = try #require(acl_from_text(denyDeleteText))
            defer { acl_free(UnsafeMutableRawPointer(accessControlList)) }
            try #require(acl_set_link_np(url.path, ACL_TYPE_EXTENDED, accessControlList) == 0)
        }
        if self == .everythingOnReadOnlyFile {
            try #require(chmod(url.path, 0o444) == 0)
        }
        if let flag {
            try #require(lchflags(url.path, flag) == 0)
        }
    }

    func isCarried(by url: URL) -> Bool {
        guard let info = GitWorktreeForkFileProbe.info(url) else {
            return false
        }
        let attributeCarried = probeAttribute(url) == Array("x".utf8)
        let aclCarried = accessControlText(url)?.contains("everyone:12:deny:delete") == true
        let flagCarried = flag.map { info.st_flags & $0 == $0 } ?? true
        switch self {
        case .extendedAttribute:
            return attributeCarried
        case .userImmutableFlag, .appendOnlyFlag:
            return flagCarried
        case .denyDeleteAccessControlEntry:
            return aclCarried
        case .everythingOnReadOnlyFile:
            return attributeCarried && aclCarried && flagCarried && info.st_mode & 0o7777 == 0o444
        }
    }

    private var flag: UInt32? {
        switch self {
        case .userImmutableFlag, .everythingOnReadOnlyFile:
            return UInt32(UF_IMMUTABLE)
        case .appendOnlyFlag:
            return UInt32(UF_APPEND)
        case .extendedAttribute, .denyDeleteAccessControlEntry:
            return nil
        }
    }

    private var denyDeleteText: String {
        "!#acl 1\ngroup:ABCDEFAB-CDEF-ABCD-EFAB-CDEF0000000C:everyone:12:deny:delete\n"
    }
}

private func probeAttribute(_ url: URL) -> [UInt8]? {
    let size = getxattr(url.path, probeAttributeName, nil, 0, 0, XATTR_NOFOLLOW)
    guard size >= 0 else {
        return nil
    }
    var value = [UInt8](repeating: 0, count: size)
    guard getxattr(url.path, probeAttributeName, &value, value.count, 0, XATTR_NOFOLLOW) == size else {
        return nil
    }
    return value
}

private func accessControlText(_ url: URL) -> String? {
    guard let accessControlList = acl_get_link_np(url.path, ACL_TYPE_EXTENDED) else {
        return nil
    }
    defer { acl_free(UnsafeMutableRawPointer(accessControlList)) }
    guard let text = acl_to_text(accessControlList, nil) else {
        return nil
    }
    defer { acl_free(UnsafeMutableRawPointer(text)) }
    return String(cString: text)
}
