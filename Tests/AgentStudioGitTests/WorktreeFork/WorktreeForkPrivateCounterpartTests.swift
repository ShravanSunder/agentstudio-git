import AgentStudioGit
import Darwin
import Foundation
import Testing

@testable import AgentStudioGitLocal

/// Containment of private-administration counterpart cloning. A configuration value is canonicalized before
/// re-homing, so a symlink can only reach the clone if it is swapped in afterwards; these tests hand the clone
/// such a path directly.
@Suite("Worktree fork private counterparts")
struct WorktreeForkPrivateCounterpartTests {
    @Test(
        "a symlinked intermediate directory on either side fails typed and writes nothing outside",
        arguments: [CounterpartSymlinkSide.source, .destination])
    func symlinkedIntermediateDirectoryFailsTyped(side: CounterpartSymlinkSide) throws {
        // Arrange
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceAdministration = root.appending(path: "source-admin")
        let destinationAdministration = root.appending(path: "destination-admin")
        let outside = root.appending(path: "outside")
        for directory in [sourceAdministration, destinationAdministration, outside] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        try Data("outside\n".utf8).write(to: outside.appending(path: "allowed_signers"))
        switch side {
        case .source:
            try FileManager.default.createSymbolicLink(
                at: sourceAdministration.appending(path: "keys"), withDestinationURL: outside)
        case .destination:
            try FileManager.default.createDirectory(
                at: sourceAdministration.appending(path: "keys"), withIntermediateDirectories: true)
            try Data("private\n".utf8).write(to: sourceAdministration.appending(path: "keys/allowed_signers"))
            try FileManager.default.createSymbolicLink(
                at: destinationAdministration.appending(path: "keys"), withDestinationURL: outside)
        }
        let match = WorktreeForkSourcePathRelocation.AdministrationMatch(
            sourceAdministration: sourceAdministration, destinationAdministration: destinationAdministration,
            remainder: "keys/allowed_signers")

        // Act
        let failure: GitWorktreeForkError?
        do {
            _ = try WorktreeForkPrivateAdministrationCounterparts.realize(match) { $0 }
            failure = nil
        } catch {
            failure = error
        }

        // Assert
        switch side {
        case .source:
            #expect(failure == .sourceChanged(relativePath: "keys", reason: .containmentEscape))
            #expect(try FileManager.default.contentsOfDirectory(atPath: destinationAdministration.path).isEmpty)
        case .destination:
            #expect(
                failure == .entryFailed(relativePath: "keys", reason: .unresolvableGitAdministration, errorNumber: nil))
            #expect(try FileManager.default.contentsOfDirectory(atPath: destinationAdministration.path) == ["keys"])
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: outside.path) == ["allowed_signers"])
        #expect(try String(contentsOf: outside.appending(path: "allowed_signers"), encoding: .utf8) == "outside\n")
    }

    /// A canonical temporary directory: the clone opens its roots with no symlink anywhere in the path.
    private func temporaryRoot() throws -> URL {
        let resolved = try #require(realpath(NSTemporaryDirectory(), nil))
        defer { free(resolved) }
        let root = URL(fileURLWithPath: String(cString: resolved))
            .appending(path: "agentstudio-git-counterpart-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
}

enum CounterpartSymlinkSide: String, CaseIterable, Sendable {
    case source
    case destination
}
