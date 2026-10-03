import AgentStudioGit
import Darwin
import Foundation
import Testing

@testable import AgentStudioGitLocal

/// A nested linked worktree's configuration can name files in its own private administration. Re-homing
/// re-aims those values at the node's destination administration, so the files they name must exist there:
/// Git silently ignores a missing include or signer file.
@Suite("Git worktree fork private administration integration", .serialized)
struct GitWorktreeForkPrivateAdminIntegrationTests {
    private static let probeAttributeName = "com.example.forklab"

    @Test("files a nested worktree's config names in its private administration are cloned with their metadata")
    func privateAdministrationTargetsAreClonedWithMetadata() async throws {
        // Arrange
        let fixture = try GitWorktreeForkFixture.make(prefix: "agentstudio-git-fork-private-targets")
        let agent = fixture.source.appending(path: ".claude/worktrees/agent")
        let destinationAgent = fixture.destination().appending(path: ".claude/worktrees/agent")
        defer {
            for administration in [fixture.source.appending(path: ".git/worktrees/agent"), destinationAgent] {
                _ = chmod(administration.appending(path: "allowed_signers").path, 0o644)
            }
            fixture.remove()
        }
        try ignore(".claude/", fixture: fixture)
        try fixture.git.run("worktree", "add", "-q", "-b", "agent", agent.path)
        let privateAdministration = try canonical(fixture.source.appending(path: ".git/worktrees/agent"))
        let signers = privateAdministration.appending(path: "allowed_signers")
        let extra = privateAdministration.appending(path: "extra.conf")
        try "agent@example.com ssh-ed25519 AAAAexample\n".write(to: signers, atomically: false, encoding: .utf8)
        try "[agentstudio]\n\tprobe = from-private\n".write(to: extra, atomically: false, encoding: .utf8)
        try #require(setxattr(signers.path, Self.probeAttributeName, "x", 1, 0, XATTR_NOFOLLOW) == 0)
        try #require(chmod(signers.path, 0o444) == 0)
        try fixture.git.run("config", "gpg.ssh.allowedSignersFile", signers.path)
        try fixture.git.run("config", "include.path", extra.path)

        // Act
        _ = try await LibGit2AgentStudioGitLocalClient().forkWorktree(fixture.request())

        // Assert
        let destinationAdministration = try canonical(destinationAgent.appending(path: ".git"))
        let destinationSigners = destinationAdministration.appending(path: "allowed_signers")
        let destinationExtra = destinationAdministration.appending(path: "extra.conf")
        #expect(try Data(contentsOf: destinationSigners) == Data(contentsOf: signers))
        #expect(try Data(contentsOf: destinationExtra) == Data(contentsOf: extra))
        let signersInfo = try #require(GitWorktreeForkFileProbe.info(destinationSigners))
        #expect(signersInfo.st_mode & 0o7777 == 0o444)
        #expect(getxattr(destinationSigners.path, Self.probeAttributeName, nil, 0, 0, XATTR_NOFOLLOW) == 1)
        #expect(try configValue("gpg.ssh.allowedSignersFile", at: destinationAgent, fixture) == destinationSigners.path)
        #expect(try configValue("agentstudio.probe", at: destinationAgent, fixture) == "from-private")

        // Act: the source files change after the fork.
        try #require(chmod(signers.path, 0o644) == 0)
        try "changed@example.com ssh-ed25519 AAAAchanged\n".write(to: signers, atomically: false, encoding: .utf8)
        try "[agentstudio]\n\tprobe = changed-in-source\n".write(to: extra, atomically: false, encoding: .utf8)

        // Assert: the destination owns its own copies.
        #expect(try String(contentsOf: destinationSigners, encoding: .utf8).hasPrefix("agent@example.com"))
        #expect(try configValue("agentstudio.probe", at: destinationAgent, fixture) == "from-private")
    }

    @Test("a private target wins over a common file of the same name in a flattened node's administration")
    func privateTargetWinsOverSameNamedCommonFile() async throws {
        // Arrange: the flattened node's administration is cloned from the common directory, which holds its own
        // extra.conf and allowed_signers. Git reads the worktree-private files the config names.
        let fixture = try GitWorktreeForkFixture.make(prefix: "agentstudio-git-fork-private-wins")
        let agent = fixture.source.appending(path: ".claude/worktrees/agent")
        let destinationAgent = fixture.destination().appending(path: ".claude/worktrees/agent")
        defer {
            for administration in [fixture.source.appending(path: ".git/worktrees/agent"), destinationAgent] {
                _ = chmod(administration.appending(path: "allowed_signers").path, 0o644)
            }
            fixture.remove()
        }
        try ignore(".claude/", fixture: fixture)
        try fixture.git.run("worktree", "add", "-q", "-b", "agent", agent.path)
        let commonAdministration = try canonical(fixture.source.appending(path: ".git"))
        try "common@example.com ssh-ed25519 AAAAcommon\n".write(
            to: commonAdministration.appending(path: "allowed_signers"), atomically: false, encoding: .utf8)
        try "[agentstudio]\n\tprobe = from-common\n".write(
            to: commonAdministration.appending(path: "extra.conf"), atomically: false, encoding: .utf8)
        let privateAdministration = commonAdministration.appending(path: "worktrees/agent")
        let signers = privateAdministration.appending(path: "allowed_signers")
        let extra = privateAdministration.appending(path: "extra.conf")
        try "agent@example.com ssh-ed25519 AAAAprivate\n".write(to: signers, atomically: false, encoding: .utf8)
        try "[agentstudio]\n\tprobe = from-private\n".write(to: extra, atomically: false, encoding: .utf8)
        try #require(setxattr(signers.path, Self.probeAttributeName, "x", 1, 0, XATTR_NOFOLLOW) == 0)
        try #require(chmod(signers.path, 0o444) == 0)
        try fixture.git.run("config", "gpg.ssh.allowedSignersFile", signers.path)
        try fixture.git.run("config", "include.path", extra.path)

        // Act
        _ = try await LibGit2AgentStudioGitLocalClient().forkWorktree(fixture.request())

        // Assert
        let destinationAdministration = try canonical(destinationAgent.appending(path: ".git"))
        let destinationSigners = destinationAdministration.appending(path: "allowed_signers")
        #expect(try Data(contentsOf: destinationSigners) == Data(contentsOf: signers))
        #expect(
            try Data(contentsOf: destinationAdministration.appending(path: "extra.conf")) == Data(contentsOf: extra))
        let signersInfo = try #require(GitWorktreeForkFileProbe.info(destinationSigners))
        #expect(signersInfo.st_mode & 0o7777 == 0o444)
        #expect(getxattr(destinationSigners.path, Self.probeAttributeName, nil, 0, 0, XATTR_NOFOLLOW) == 1)
        #expect(try configValue("agentstudio.probe", at: destinationAgent, fixture) == "from-private")
    }

    @Test("A58-02: a common file of the same name never stands in for the private include it names")
    func commonFileNeverStandsInForPrivateInclude() async throws {
        // Arrange: the root .git/extra.conf says common-file; the nested worktree's private extra.conf says
        // private-file, and the shared config includes the private one.
        let fixture = try GitWorktreeForkFixture.make(prefix: "agentstudio-git-fork-a58-02")
        defer { fixture.remove() }
        try ignore(".claude/", fixture: fixture)
        let agent = fixture.source.appending(path: ".claude/worktrees/agent")
        try fixture.git.run("worktree", "add", "-q", "-b", "agent", agent.path)
        let commonAdministration = try canonical(fixture.source.appending(path: ".git"))
        try "[agentstudio]\n\tmarker = common-file\n".write(
            to: commonAdministration.appending(path: "extra.conf"), atomically: false, encoding: .utf8)
        let privateExtra = commonAdministration.appending(path: "worktrees/agent/extra.conf")
        try "[agentstudio]\n\tmarker = private-file\n".write(to: privateExtra, atomically: false, encoding: .utf8)
        try fixture.git.run("config", "include.path", privateExtra.path)
        #expect(try configValue("agentstudio.marker", at: agent, fixture) == "private-file")
        let sourceConfiguration = try Data(contentsOf: commonAdministration.appending(path: "config"))

        // Act
        _ = try await LibGit2AgentStudioGitLocalClient().forkWorktree(fixture.request())

        // Assert
        let destinationAgent = fixture.destination().appending(path: ".claude/worktrees/agent")
        #expect(try configValue("agentstudio.marker", at: destinationAgent, fixture) == "private-file")
        #expect(try Data(contentsOf: commonAdministration.appending(path: "config")) == sourceConfiguration)
    }

    @Test(
        "values naming both a flattened node's common and private file of one name need them to agree",
        arguments: CollidingAdministrationContent.allCases)
    func commonAndPrivateReferencesToOneNameMustAgree(content: CollidingAdministrationContent) async throws {
        // Arrange: an external repository's linked worktree nested in the tree is flattened, so its common and
        // private administration both land in one destination .git, and its config includes both extra.conf.
        let fixture = try GitWorktreeForkFixture.make(prefix: "agentstudio-git-fork-private-collision")
        defer { fixture.remove() }
        try ignore(".build/", fixture: fixture)
        let upstream = fixture.repository.root.appending(path: "upstream")
        try FileManager.default.createDirectory(at: upstream, withIntermediateDirectories: true)
        try fixture.git.run(["init", "-q"], currentDirectory: upstream)
        try fixture.write("up.txt", "up\n", in: upstream)
        try fixture.git.run(["add", "."], currentDirectory: upstream)
        try fixture.git.run(["commit", "-qm", "initial"], currentDirectory: upstream)
        let linked = fixture.source.appending(path: ".build/linked")
        try fixture.git.run(["worktree", "add", "-q", "-b", "linked", linked.path], currentDirectory: upstream)
        let commonAdministration = try canonical(upstream.appending(path: ".git"))
        let commonExtra = commonAdministration.appending(path: "extra.conf")
        let privateExtra = commonAdministration.appending(path: "worktrees/linked/extra.conf")
        try "[agentstudio]\n\tmarker = shared\n".write(to: commonExtra, atomically: false, encoding: .utf8)
        let privateText =
            content == .identical ? "[agentstudio]\n\tmarker = shared\n" : "[agentstudio]\n\tmarker = private\n"
        try privateText.write(to: privateExtra, atomically: false, encoding: .utf8)
        for include in [commonExtra, privateExtra] {
            try fixture.git.run(["config", "--add", "include.path", include.path], currentDirectory: upstream)
        }
        let sourceConfiguration = try Data(contentsOf: commonAdministration.appending(path: "config"))
        let branchesBefore = try fixture.branchNames()

        // Act
        let failure: GitWorktreeForkError?
        do {
            _ = try await LibGit2AgentStudioGitLocalClient().forkWorktree(fixture.request())
            failure = nil
        } catch {
            failure = error
        }

        // Assert
        let destinationLinked = fixture.destination().appending(path: ".build/linked")
        switch content {
        case .different:
            #expect(
                failure
                    == .entryFailed(
                        relativePath: ".build/linked/.git/extra.conf", reason: .unresolvableGitAdministration,
                        errorNumber: nil))
            #expect(!GitWorktreeForkFileProbe.exists(fixture.destination()))
            #expect(!GitWorktreeForkFileProbe.exists(fixture.linkedWorktreeAdministration()))
            #expect(try fixture.branchNames() == branchesBefore)
        case .identical:
            #expect(failure == nil)
            #expect(try configValue("agentstudio.marker", at: destinationLinked, fixture) == "shared")
        }
        #expect(try Data(contentsOf: commonAdministration.appending(path: "config")) == sourceConfiguration)
        #expect(try String(contentsOf: privateExtra, encoding: .utf8) == privateText)
    }

    @Test("a private administration target that cannot be cloned fails typed and leaves nothing behind")
    func uncloneablePrivateAdministrationTargetFails() async throws {
        // Arrange: the named signer file is a FIFO, which has no CoW payload to give the destination.
        let fixture = try GitWorktreeForkFixture.make(prefix: "agentstudio-git-fork-private-special")
        defer { fixture.remove() }
        try ignore(".claude/", fixture: fixture)
        let agent = fixture.source.appending(path: ".claude/worktrees/agent")
        try fixture.git.run("worktree", "add", "-q", "-b", "agent", agent.path)
        let signers = try canonical(fixture.source.appending(path: ".git/worktrees/agent"))
            .appending(path: "allowed_signers")
        try #require(mkfifo(signers.path, 0o644) == 0)
        try fixture.git.run("config", "gpg.ssh.allowedSignersFile", signers.path)
        let branchesBefore = try fixture.branchNames()

        // Act
        let failure: GitWorktreeForkError?
        do {
            _ = try await LibGit2AgentStudioGitLocalClient().forkWorktree(fixture.request())
            failure = nil
        } catch {
            failure = error
        }

        // Assert
        #expect(
            failure
                == .entryFailed(
                    relativePath: ".claude/worktrees/agent/.git/allowed_signers", reason: .unsupportedEntryKind,
                    errorNumber: nil))
        #expect(!GitWorktreeForkFileProbe.exists(fixture.destination()))
        #expect(!GitWorktreeForkFileProbe.exists(fixture.linkedWorktreeAdministration()))
        #expect(try fixture.branchNames() == branchesBefore)
    }

    private func ignore(_ pattern: String, fixture: GitWorktreeForkFixture) throws {
        try fixture.write(".gitignore", "\(pattern)\n")
        try fixture.git.run("add", ".gitignore")
        try fixture.git.run("commit", "-qm", "ignore \(pattern)")
    }

    private func configValue(_ key: String, at worktree: URL, _ fixture: GitWorktreeForkFixture) throws -> String {
        try fixture.git.run(["config", "--get", key], currentDirectory: worktree)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func canonical(_ url: URL) throws -> URL {
        let resolved = try #require(realpath(url.path, nil))
        defer { free(resolved) }
        return URL(fileURLWithPath: String(cString: resolved))
    }
}

/// Whether a flattened node's common and private file of one name hold the same thing.
enum CollidingAdministrationContent: String, CaseIterable, Sendable {
    case different
    case identical
}
