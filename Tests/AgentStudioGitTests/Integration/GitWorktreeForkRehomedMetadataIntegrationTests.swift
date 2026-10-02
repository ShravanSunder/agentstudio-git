import AgentStudioGit
import Darwin
import Foundation
import Testing

@testable import AgentStudioGitLocal

/// Re-homing rewrites cloned administrative files (a nested `.git/HEAD`, sparse state, configuration edited
/// through libgit2) on a fresh inode. The specification makes loss of ACL access semantics, extended
/// attributes, or file flags a failure, so each rewrite must carry the metadata of the file it stands for.
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

    @Test(
        "rewritten sparse configuration keeps its source file's mode and extended attribute",
        arguments: SparseNestedLayout.allCases)
    func rewrittenSparseConfigurationKeepsMetadata(layout: SparseNestedLayout) async throws {
        // Arrange: config.worktree is rewritten by re-homing and then edited through libgit2's lock-file
        // rename; a flattened linked worktree's copy is removed and rebuilt from its private source file.
        let fixture = try GitWorktreeForkFixture.make(prefix: "agentstudio-git-fork-sparse-metadata")
        defer { fixture.remove() }
        try fixture.write(".gitignore", ".build/\n")
        try fixture.git.run("add", ".gitignore")
        try fixture.git.run("commit", "-qm", "ignore build")
        let nested = fixture.source.appending(path: ".build/checkouts/dependency")
        let sourceAdministration: URL
        switch layout {
        case .embeddedRepository:
            try makeSparseTree(at: nested, fixture: fixture)
            sourceAdministration = nested.appending(path: ".git")
        case .linkedWorktree:
            let upstream = fixture.repository.root.appending(path: "upstream")
            try makeSparseTree(at: upstream, fixture: fixture)
            try fixture.git.run(["worktree", "add", "-q", nested.path], currentDirectory: upstream)
            sourceAdministration = upstream.appending(path: ".git/worktrees/dependency")
        }
        try fixture.git.run(["sparse-checkout", "set", "--cone", "kept"], currentDirectory: nested)
        let administrativeFiles = ["config.worktree", "info/sparse-checkout"]
        for file in administrativeFiles {
            let url = sourceAdministration.appending(path: file)
            try #require(setxattr(url.path, probeAttributeName, "x", 1, 0, XATTR_NOFOLLOW) == 0)
            try #require(chmod(url.path, 0o444) == 0)
        }

        // Act
        _ = try await LibGit2AgentStudioGitLocalClient().forkWorktree(fixture.request())

        // Assert
        let destinationNested = fixture.destination().appending(path: ".build/checkouts/dependency")
        #expect(try fixture.git.run(["sparse-checkout", "list"], currentDirectory: destinationNested) == "kept\n")
        for file in administrativeFiles {
            let destination = try #require(
                GitWorktreeForkFileProbe.info(destinationNested.appending(path: ".git/\(file)")))
            #expect(destination.st_mode & 0o7777 == 0o444, "\(file) keeps its read-only mode")
            #expect(
                probeAttribute(destinationNested.appending(path: ".git/\(file)")) == Array("x".utf8),
                "\(file) keeps its extended attribute")
        }
    }

    private func makeSparseTree(at path: URL, fixture: GitWorktreeForkFixture) throws {
        try makeRepository(at: path, file: "kept/one.txt", fixture: fixture)
        try fixture.write("dropped/two.txt", "dropped\n", in: path)
        try fixture.git.run(["add", "."], currentDirectory: path)
        try fixture.git.run(["commit", "-qm", "sparse tree"], currentDirectory: path)
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

/// How a sparse nested repository's administration is laid out in the source.
enum SparseNestedLayout: String, CaseIterable, Sendable, CustomStringConvertible {
    /// An embedded `.git` directory; the destination copy is cloned, then rewritten in place.
    case embeddedRepository
    /// A gitfile-reached linked worktree; its destination copy is flattened and rebuilt from the private
    /// source administration.
    case linkedWorktree

    var description: String {
        rawValue
    }
}

/// One piece of metadata a cloned administrative file can carry into the fork.
enum RehomedFileMetadata: String, CaseIterable, Sendable, CustomStringConvertible {
    case extendedAttribute
    case userImmutableFlag
    case appendOnlyFlag
    case denyDeleteAccessControlEntry
    case denyWriteAccessControlEntry
    case everythingOnReadOnlyFile

    var description: String {
        rawValue
    }

    func apply(to url: URL) throws {
        if self == .extendedAttribute || self == .everythingOnReadOnlyFile {
            try #require(setxattr(url.path, probeAttributeName, "x", 1, 0, XATTR_NOFOLLOW) == 0)
        }
        if let accessControlEntry {
            let accessControlList = try #require(acl_from_text(accessControlEntry))
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
        let aclCarried = accessControlEntry.map { accessControlText(url) == $0 } ?? true
        let flagCarried = flag.map { info.st_flags & $0 == $0 } ?? true
        switch self {
        case .extendedAttribute:
            return attributeCarried
        case .userImmutableFlag, .appendOnlyFlag:
            return flagCarried
        case .denyDeleteAccessControlEntry, .denyWriteAccessControlEntry:
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
        case .extendedAttribute, .denyDeleteAccessControlEntry, .denyWriteAccessControlEntry:
            return nil
        }
    }

    /// The entry in `acl_to_text` form, which is also what `accessControlText(_:)` reads back.
    private var accessControlEntry: String? {
        let everyone = "group:ABCDEFAB-CDEF-ABCD-EFAB-CDEF0000000C:everyone:12"
        switch self {
        case .denyDeleteAccessControlEntry, .everythingOnReadOnlyFile:
            return "!#acl 1\n\(everyone):deny:delete\n"
        case .denyWriteAccessControlEntry:
            return "!#acl 1\n\(everyone):deny:write\n"
        case .extendedAttribute, .userImmutableFlag, .appendOnlyFlag:
            return nil
        }
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
