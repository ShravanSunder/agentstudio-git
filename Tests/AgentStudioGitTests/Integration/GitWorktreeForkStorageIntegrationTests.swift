import AgentStudioGit
import Darwin
import Foundation
import Testing

@testable import AgentStudioGitLocal

@Suite("Git worktree fork storage integration", .serialized)
struct GitWorktreeForkStorageIntegrationTests {
    @Test("regular payloads are APFS clones that diverge independently in both directions")
    func regularPayloadsAreClonesThatDivergeIndependently() async throws {
        // Arrange
        let fixture = try GitWorktreeForkFixture.make(prefix: "agentstudio-git-fork-clone")
        defer { fixture.remove() }
        let payloadSize = 64 * 1024 * 1024
        let sourcePayload = fixture.source.appending(path: "cache/payload.bin")
        try FileManager.default.createDirectory(
            at: sourcePayload.deletingLastPathComponent(), withIntermediateDirectories: true)
        let chunk = Data((0..<(1024 * 1024)).map { UInt8(truncatingIfNeeded: $0 &* 31) })
        #expect(FileManager.default.createFile(atPath: sourcePayload.path, contents: nil))
        let writer = try FileHandle(forWritingTo: sourcePayload)
        for _ in 0..<(payloadSize / chunk.count) {
            try writer.write(contentsOf: chunk)
        }
        try writer.close()
        try fixture.write("notes.txt", "source original\n")
        let destination = fixture.destination()
        let destinationPayload = destination.appending(path: "cache/payload.bin")

        // Act
        let result = try await LibGit2AgentStudioGitLocalClient().forkWorktree(fixture.request())
        let privateBytesAfterClone = try #require(GitWorktreeForkFileProbe.privateSize(destinationPayload))
        let overwrite = try FileHandle(forWritingTo: destinationPayload)
        try overwrite.write(contentsOf: Data(repeating: 0xAB, count: 8 * 1024 * 1024))
        try overwrite.synchronize()
        try overwrite.close()
        let privateBytesAfterOverwrite = try #require(GitWorktreeForkFileProbe.privateSize(destinationPayload))
        try fixture.write("notes.txt", "source edited after fork\n")

        // Assert
        let sourceInfo = try #require(GitWorktreeForkFileProbe.info(sourcePayload))
        let destinationInfo = try #require(GitWorktreeForkFileProbe.info(destinationPayload))
        #expect(sourceInfo.st_ino != destinationInfo.st_ino)
        #expect(destinationInfo.st_size == Int64(payloadSize))
        #expect(privateBytesAfterClone < 1024 * 1024, "a fresh clone must share its blocks")
        #expect(privateBytesAfterOverwrite >= 8 * 1024 * 1024, "only the overwritten range becomes private")
        #expect(try Data(contentsOf: sourcePayload).prefix(4) == Data([0, 31, 62, 93]))
        #expect(
            try String(contentsOf: destination.appending(path: "notes.txt"), encoding: .utf8) == "source original\n")
        #expect(result.materialization.logicalRegularFileBytes >= Int64(payloadSize))
    }

    @Test("special entries follow their kind rules and metadata normalization is reported")
    func specialEntriesFollowKindRules() async throws {
        // Arrange
        let fixture = try GitWorktreeForkFixture(
            repository: GitFixtureRepository.makeRepository(
                prefix: "asgf", rootDirectory: URL(fileURLWithPath: "/private/tmp")))
        defer { fixture.remove() }
        let source = fixture.source
        try FileManager.default.createDirectory(at: source.appending(path: "run"), withIntermediateDirectories: true)
        #expect(mkfifo(source.appending(path: "run/events.fifo").path, 0o640) == 0)
        try bindUnixSocket(at: source.appending(path: "run/agent.sock"))
        try FileManager.default.createSymbolicLink(
            atPath: source.appending(path: "link-in").path, withDestinationPath: "README.md")
        try FileManager.default.createSymbolicLink(
            atPath: source.appending(path: "link-out").path, withDestinationPath: "/etc/hosts")
        try fixture.write("bin/tool", "#!/bin/sh\n")
        #expect(chmod(source.appending(path: "bin/tool").path, 0o4755) == 0)
        try fixture.write("linked/a.txt", "shared inode\n")
        #expect(link(source.appending(path: "linked/a.txt").path, source.appending(path: "b.txt").path) == 0)
        try fixture.write("sealed/inner.txt", "inside read-only directory\n")
        #expect(setxattr(source.appending(path: "sealed").path, "com.agentstudio.probe", "dir", 3, 0, 0) == 0)
        #expect(chmod(source.appending(path: "sealed").path, 0o555) == 0)
        defer { _ = chmod(source.appending(path: "sealed").path, 0o755) }
        let destination = fixture.destination()

        // Act
        let result = try await LibGit2AgentStudioGitLocalClient().forkWorktree(fixture.request())
        defer { _ = chmod(destination.appending(path: "sealed").path, 0o755) }

        // Assert
        let report = result.materialization
        #expect(report.recreatedFIFOCount == 1)
        #expect(
            (GitWorktreeForkFileProbe.info(destination.appending(path: "run/events.fifo"))?.st_mode ?? 0) & S_IFMT
                == S_IFIFO)
        #expect(
            report.skippedEntries == [
                GitWorktreeMaterializationSkippedEntry(
                    relativePath: "run/agent.sock", kind: .unixSocket, reason: .unixSocketNotReproducible)
            ])
        #expect(!GitWorktreeForkFileProbe.exists(destination.appending(path: "run/agent.sock")))
        #expect(report.recreatedSymbolicLinkCount == 2)
        #expect(
            try FileManager.default.destinationOfSymbolicLink(atPath: destination.appending(path: "link-out").path)
                == "/etc/hosts")
        #expect(
            try FileManager.default.destinationOfSymbolicLink(atPath: destination.appending(path: "link-in").path)
                == "README.md")
        #expect(
            report.normalizedEntries.contains(
                GitWorktreeMaterializationNormalizedEntry(
                    relativePath: "bin/tool", attribute: .setUserIDBit, reason: .clearedByCopyOnWriteClone)))
        #expect(report.preservedHardLinkCount == 1)
        let destinationA = try #require(GitWorktreeForkFileProbe.info(destination.appending(path: "linked/a.txt")))
        let destinationB = try #require(GitWorktreeForkFileProbe.info(destination.appending(path: "b.txt")))
        let sourceA = try #require(GitWorktreeForkFileProbe.info(source.appending(path: "linked/a.txt")))
        #expect(destinationA.st_ino == destinationB.st_ino)
        #expect(destinationA.st_ino != sourceA.st_ino)
        let sealed = try #require(GitWorktreeForkFileProbe.info(destination.appending(path: "sealed")))
        #expect(sealed.st_mode & 0o777 == 0o555)
        #expect(getxattr(destination.appending(path: "sealed").path, "com.agentstudio.probe", nil, 0, 0, 0) == 3)
    }

    @Test("a planned directory swapped for an escaping symlink fails and rolls back")
    func swappedEscapingSymlinkFailsAndRollsBack() async throws {
        // Arrange
        let fixture = try GitWorktreeForkFixture.make(prefix: "agentstudio-git-fork-escape")
        defer { fixture.remove() }
        try fixture.write("sub/planned.txt", "planned\n")
        let outside = fixture.repository.root.appending(path: "outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try fixture.write("secret.txt", "outside the root\n", in: outside)
        let source = fixture.source
        let faults = WorktreeForkFaultInjector { point throws(GitWorktreeForkError) in
            guard point == .afterPlanning else {
                return
            }
            try? FileManager.default.removeItem(at: source.appending(path: "sub"))
            try? FileManager.default.createSymbolicLink(at: source.appending(path: "sub"), withDestinationURL: outside)
        }
        let client = LibGit2AgentStudioGitLocalClient(worktreeForkWriter: LibGit2WorktreeForkWriter(faults: faults))

        // Act
        let failure = await forkFailure(client, fixture.request())

        // Assert
        #expect(failure == .sourceChanged(relativePath: "sub", reason: .containmentEscape))
        #expect(!GitWorktreeForkFileProbe.exists(fixture.destination()))
        #expect(!GitWorktreeForkFileProbe.exists(fixture.linkedWorktreeAdministration()))
        #expect(try fixture.branchNames() == ["refs/heads/main"])
    }

    @Test("planned entries that disappear or change kind fail as source races")
    func plannedEntriesThatDisappearOrChangeKindFail() async throws {
        // Arrange
        let fixture = try GitWorktreeForkFixture.make(prefix: "agentstudio-git-fork-race")
        defer { fixture.remove() }
        try fixture.write("vanishing.txt", "gone soon\n")
        try fixture.write("shape.txt", "becomes a directory\n")
        let source = fixture.source
        let scenarios: [(mutation: @Sendable () -> Void, expected: GitWorktreeForkError)] = [
            (
                { try? FileManager.default.removeItem(at: source.appending(path: "vanishing.txt")) },
                .sourceChanged(relativePath: "vanishing.txt", reason: .entryMissing)
            ),
            (
                {
                    try? FileManager.default.removeItem(at: source.appending(path: "shape.txt"))
                    try? FileManager.default.createDirectory(
                        at: source.appending(path: "shape.txt"), withIntermediateDirectories: false)
                },
                .sourceChanged(relativePath: "shape.txt", reason: .entryKindChanged)
            ),
        ]

        for (index, scenario) in scenarios.enumerated() {
            let faults = WorktreeForkFaultInjector { point throws(GitWorktreeForkError) in
                if point == .afterPlanning {
                    scenario.mutation()
                }
            }
            let client = LibGit2AgentStudioGitLocalClient(worktreeForkWriter: LibGit2WorktreeForkWriter(faults: faults))

            // Act
            let failure = await forkFailure(client, fixture.request(destination: fixture.destination("race-\(index)")))

            // Assert
            #expect(failure == scenario.expected)
            #expect(!GitWorktreeForkFileProbe.exists(fixture.destination("race-\(index)")))
            #expect(try fixture.branchNames() == ["refs/heads/main"])
        }
    }

    private func bindUnixSocket(at url: URL) throws {
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        try #require(descriptor >= 0)
        defer { close(descriptor) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(url.path.utf8)
        try #require(pathBytes.count < MemoryLayout.size(ofValue: address.sun_path))
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.copyBytes(from: pathBytes)
        }
        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        try #require(bindResult == 0)
    }

    private func forkFailure(
        _ client: LibGit2AgentStudioGitLocalClient,
        _ request: GitForkWorktreeRequest
    ) async -> GitWorktreeForkError? {
        do {
            _ = try await client.forkWorktree(request)
            return nil
        } catch {
            return error
        }
    }
}
