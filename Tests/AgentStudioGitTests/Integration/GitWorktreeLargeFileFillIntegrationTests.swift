import AgentStudioGit
import CryptoKit
import Darwin
import Foundation
import Testing

@testable import AgentStudioGitLocal

@Suite("Git worktree large-file fill integration", .serialized)
struct GitWorktreeLargeFileFillIntegrationTests {
    @Test("create fills a normal LFS pointer from the default local object store")
    func createFillsNormalLargeFileFromDefaultStore() async throws {
        // Arrange
        let fixture = try Self.makeFixture(prefix: "agentstudio-git-lfs-normal")
        defer { fixture.repository.remove() }
        try fixture.writeObject(fixture.payload)
        try assertFixtureObjectIsValid(fixture)
        let destination = fixture.repository.linkedWorktreePath("lfs-normal")

        // Act
        let creation = try await createWorktree(fixture, destination: destination, branch: "lfs-normal")

        // Assert
        #expect(try Data(contentsOf: destination.appending(path: "asset.bin")) == fixture.payload)
        #expect(creation.largeFiles.materializedCount == 1)
        #expect(creation.largeFiles.missing.isEmpty)
        #expect(creation.largeFiles.indexUpdate == .updated)
        let indexEntry = try indexEntry(for: "asset.bin", worktree: destination)
        #expect(indexEntry.contains("100644"))
        #expect(indexEntry.contains(fixture.pointerBlobOID))
        #expect(try fileMode(destination.appending(path: "asset.bin")) & 0o111 == 0)
    }

    @Test("create preserves the executable index mode when filling an LFS pointer")
    func createFillsExecutableLargeFileWithIndexMode() async throws {
        // Arrange
        let fixture = try Self.makeFixture(prefix: "agentstudio-git-lfs-executable", executable: true)
        defer { fixture.repository.remove() }
        try fixture.writeObject(fixture.payload)
        try assertFixtureObjectIsValid(fixture)
        let destination = fixture.repository.linkedWorktreePath("lfs-executable")

        // Act
        let creation = try await createWorktree(fixture, destination: destination, branch: "lfs-executable")

        // Assert
        #expect(try Data(contentsOf: destination.appending(path: "asset.bin")) == fixture.payload)
        #expect(creation.largeFiles.materializedCount == 1)
        let indexEntry = try indexEntry(for: "asset.bin", worktree: destination)
        #expect(indexEntry.contains("100755"))
        #expect(indexEntry.contains(fixture.pointerBlobOID))
        #expect(try fileMode(destination.appending(path: "asset.bin")) & 0o111 != 0)
    }

    @Test("a missing object keeps the pointer and reports objectAbsent")
    func missingObjectKeepsPointerAndReportsTypedMiss() async throws {
        // Arrange
        let fixture = try Self.makeFixture(prefix: "agentstudio-git-lfs-absent")
        defer { fixture.repository.remove() }
        let destination = fixture.repository.linkedWorktreePath("lfs-absent")

        // Act
        let creation = try await createWorktree(fixture, destination: destination, branch: "lfs-absent")

        // Assert
        #expect(try Data(contentsOf: destination.appending(path: "asset.bin")) == Data(fixture.pointer.utf8))
        #expect(
            creation.largeFiles.missing == [
                GitLargeFileFillMiss(path: "asset.bin", reason: .objectAbsent)
            ]
        )
        #expect(creation.largeFiles.materializedCount == 0)
    }

    @Test("a mismatched object leaves the pointer and removes its temporary file")
    func mismatchedObjectLeavesNoPartialFile() async throws {
        // Arrange
        let fixture = try Self.makeFixture(prefix: "agentstudio-git-lfs-mismatch")
        defer { fixture.repository.remove() }
        let wrongPayload = Data(repeating: 0x78, count: fixture.payload.count)
        try fixture.writeObject(wrongPayload)
        let destination = fixture.repository.linkedWorktreePath("lfs-mismatch")

        // Act
        let creation = try await createWorktree(fixture, destination: destination, branch: "lfs-mismatch")

        // Assert
        #expect(try Data(contentsOf: destination.appending(path: "asset.bin")) == Data(fixture.pointer.utf8))
        #expect(
            creation.largeFiles.missing == [
                GitLargeFileFillMiss(path: "asset.bin", reason: .objectMismatch)
            ]
        )
        let destinationNames = try FileManager.default.contentsOfDirectory(
            atPath: destination.path
        )
        #expect(!destinationNames.contains(where: { $0.hasPrefix(".agentstudio-lfs-fill-") }))
    }

    @Test("create honors relative lfs.storage from the common Git directory")
    func createUsesConfiguredLocalStore() async throws {
        // Arrange
        let fixture = try Self.makeFixture(
            prefix: "agentstudio-git-lfs-configured-store",
            configuredStorage: "custom-lfs"
        )
        defer { fixture.repository.remove() }
        try fixture.writeObject(fixture.payload)
        try assertFixtureObjectIsValid(fixture)
        let destination = fixture.repository.linkedWorktreePath("lfs-configured")

        // Act
        let creation = try await createWorktree(fixture, destination: destination, branch: "lfs-configured")

        // Assert
        #expect(try Data(contentsOf: destination.appending(path: "asset.bin")) == fixture.payload)
        #expect(creation.largeFiles.materializedCount == 1)
        #expect(creation.largeFiles.missing.isEmpty)
    }

    private func createWorktree(
        _ fixture: LargeFileFixture,
        destination: URL,
        branch: String
    ) async throws -> GitWorktreeCreation {
        try await LibGit2AgentStudioGitLocalClient().createWorktree(
            GitCreateWorktreeRequest(
                repositoryPath: fixture.repository.repositoryPath,
                destinationPath: destination,
                mode: .newBranch(name: branch, startPoint: .named("HEAD"))
            )
        )
    }

    private func indexEntry(for path: String, worktree: URL) throws -> String {
        try GitProcess(repositoryPath: worktree).run("ls-files", "--stage", "--", path)
    }

    private func assertFixtureObjectIsValid(_ fixture: LargeFileFixture) throws {
        let storedContents = try Data(contentsOf: fixture.objectPath)
        let pointer = try #require(LargeFilePointer(data: Data(fixture.pointer.utf8)))
        let payloadSHA256 = SHA256.hash(data: fixture.payload).map { String(format: "%02x", $0) }.joined()

        #expect(storedContents == fixture.payload)
        #expect(pointer.payloadByteCount == fixture.payload.count)
        #expect(pointer.payloadSHA256 == fixture.objectID)
        #expect(payloadSHA256 == fixture.objectID)
    }

    private func fileMode(_ path: URL) throws -> mode_t {
        var info = Darwin.stat()
        let result = path.path.withCString { lstat($0, &info) }
        guard result == 0 else {
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }
        return info.st_mode
    }

    private static func makeFixture(
        prefix: String,
        executable: Bool = false,
        configuredStorage: String? = nil
    ) throws -> LargeFileFixture {
        let repository = try GitFixtureRepository.makeRepository(prefix: prefix)
        let payload = Data("real large file payload for \(prefix)\n".utf8)
        let objectID = SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
        let pointer = "version https://git-lfs.github.com/spec/v1\noid sha256:\(objectID)\nsize \(payload.count)\n"
        try repository.write(".gitattributes", contents: "*.bin filter=lfs diff=lfs merge=lfs -text\n")
        try repository.write("asset.bin", contents: pointer)
        if executable {
            let chmodResult = repository.repositoryPath.appending(path: "asset.bin").path.withCString {
                chmod($0, 0o755)
            }
            guard chmodResult == 0 else {
                throw POSIXError(.init(rawValue: errno) ?? .EIO)
            }
        }
        if let configuredStorage {
            try repository.git.run("config", "lfs.storage", configuredStorage)
        }
        try repository.git.run("add", ".gitattributes", "asset.bin")
        try repository.git.run("commit", "-m", "commit LFS pointer")
        let pointerBlobOID = try repository.git.run("hash-object", "asset.bin")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return LargeFileFixture(
            repository: repository,
            payload: payload,
            pointer: pointer,
            objectID: objectID,
            pointerBlobOID: pointerBlobOID,
            objectStorageRoot: repository.repositoryPath.appending(
                path: configuredStorage.map { ".git/\($0)/objects" } ?? ".git/lfs/objects"
            )
        )
    }
}

private struct LargeFileFixture {
    let repository: GitFixtureRepository
    let payload: Data
    let pointer: String
    let objectID: String
    let pointerBlobOID: String
    let objectStorageRoot: URL

    var objectPath: URL {
        objectStorageRoot
            .appending(path: String(objectID.prefix(2)))
            .appending(path: String(objectID.dropFirst(2).prefix(2)))
            .appending(path: objectID)
    }

    func writeObject(_ contents: Data) throws {
        let objectDirectory = objectPath.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: objectDirectory, withIntermediateDirectories: true)
        try contents.write(to: objectPath)
    }
}
