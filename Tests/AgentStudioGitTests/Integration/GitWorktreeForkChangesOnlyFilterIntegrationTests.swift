import AgentStudioGit
import CryptoKit
import Foundation
import Testing

@testable import AgentStudioGitLocal

@Suite("Git worktree changes-only fork filter integration", .serialized)
struct GitWorktreeForkChangesOnlyFilterIntegrationTests {
    @Test("a smudged LFS path that is otherwise unchanged is restored from verified source bytes")
    func smudgedLargeFileIsVerifiedAndCopied() async throws {
        // Arrange
        let fixture = try GitWorktreeForkFixture.make(prefix: "agentstudio-git-fork-lfs-smudged")
        defer { fixture.remove() }
        let payload = Data("verified large file payload\n".utf8)
        let hash = SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
        let pointer = "version https://git-lfs.github.com/spec/v1\noid sha256:\(hash)\nsize \(payload.count)\n"
        try fixture.write(".gitattributes", "asset.bin filter=lfs\n")
        try fixture.write("asset.bin", pointer)
        try fixture.git.run("add", ".")
        try fixture.git.run("commit", "-m", "large file pointer")
        try payload.write(to: fixture.source.appending(path: "asset.bin"))
        let destination = fixture.destination()
        let request = GitForkWorktreeRequest(
            sourceWorktreePath: fixture.source,
            destinationPath: destination,
            mode: .newBranch(name: "fork-lfs-smudged"),
            materialization: .changesOnly
        )

        // Act
        _ = try await LibGit2AgentStudioGitLocalClient().forkWorktree(request)

        // Assert
        #expect(try Data(contentsOf: destination.appending(path: "asset.bin")) == payload)
        #expect(try Data(contentsOf: fixture.source.appending(path: "asset.bin")) == payload)
    }

    @Test("a source that only has LFS pointer text keeps the checked-out pointer")
    func pointerOnlyLargeFileStaysPointer() async throws {
        // Arrange
        let fixture = try GitWorktreeForkFixture.make(prefix: "agentstudio-git-fork-lfs-pointer")
        defer { fixture.remove() }
        let pointer =
            "version https://git-lfs.github.com/spec/v1\noid sha256:\(String(repeating: "a", count: 64))\nsize 81\n"
        try fixture.write(".gitattributes", "asset.bin filter=lfs\n")
        try fixture.write("asset.bin", pointer)
        try fixture.git.run("add", ".")
        try fixture.git.run("commit", "-m", "large file pointer only")
        let destination = fixture.destination()
        let request = GitForkWorktreeRequest(
            sourceWorktreePath: fixture.source,
            destinationPath: destination,
            mode: .newBranch(name: "fork-lfs-pointer"),
            materialization: .changesOnly
        )

        // Act
        _ = try await LibGit2AgentStudioGitLocalClient().forkWorktree(request)

        // Assert
        #expect(try String(contentsOf: destination.appending(path: "asset.bin"), encoding: .utf8) == pointer)
    }

    @Test("a custom filter is refused before branch, administration, or destination mutation")
    func customFilterRefusesBeforeMutation() async throws {
        // Arrange
        let fixture = try GitWorktreeForkFixture.make(prefix: "agentstudio-git-fork-custom-filter")
        defer { fixture.remove() }
        try fixture.write(".gitattributes", "asset.bin filter=custom\n")
        try fixture.write("asset.bin", "custom content\n")
        try fixture.git.run("add", ".")
        try fixture.git.run("commit", "-m", "custom filter path")
        let destination = fixture.destination()
        let beforeBranches = try fixture.branchNames()
        let request = GitForkWorktreeRequest(
            sourceWorktreePath: fixture.source,
            destinationPath: destination,
            mode: .newBranch(name: "fork-custom-filter"),
            materialization: .changesOnly
        )

        // Act
        let failure = await forkFailure(request)

        // Assert
        #expect(
            failure
                == .workingStateUnsupported(
                    GitWorktreeWorkingStateRefusal(reason: .customFilter, relativePath: "asset.bin")))
        #expect(!GitWorktreeForkFileProbe.exists(destination))
        #expect(!GitWorktreeForkFileProbe.exists(fixture.linkedWorktreeAdministration()))
        #expect(try fixture.branchNames() == beforeBranches)
    }

    @Test("edited attributes refuse before custom filter evaluation")
    func editedAttributesRefuseBeforeFilterEvaluation() async throws {
        // Arrange
        let fixture = try GitWorktreeForkFixture.make(prefix: "agentstudio-git-fork-edited-attributes")
        defer { fixture.remove() }
        let headAttributes = "asset.bin -filter\n"
        try fixture.write(".gitattributes", headAttributes)
        try fixture.write("asset.bin", "tracked payload\n")
        try fixture.git.run("add", ".")
        try fixture.git.run("commit", "-m", "attribute baseline")
        try fixture.write(".gitattributes", "asset.bin filter=custom\n")
        let destination = fixture.destination()
        let beforeBranches = try fixture.branchNames()
        let request = fixture.request(
            destination: destination,
            mode: .newBranch(name: "fork-edited-attributes"),
            materialization: .changesOnly
        )

        // Act
        let failure = await forkFailure(request)

        // Assert
        guard case .workingStateUnsupported(let refusal) = failure else {
            Issue.record("expected an attributes preflight refusal, got \(String(describing: failure))")
            return
        }
        #expect(refusal.reason.rawValue == "attributesChanged")
        #expect(refusal.relativePath == ".gitattributes")
        #expect(!GitWorktreeForkFileProbe.exists(destination))
        #expect(!GitWorktreeForkFileProbe.exists(fixture.linkedWorktreeAdministration("fork-edited-attributes")))
        #expect(try fixture.branchNames() == beforeBranches)
    }

    @Test("staged-only attribute changes refuse before filter evaluation")
    func stagedOnlyAttributesRefuseBeforeFilterEvaluation() async throws {
        // Arrange
        let fixture = try GitWorktreeForkFixture.make(prefix: "agentstudio-git-fork-staged-attributes")
        defer { fixture.remove() }
        let headAttributes = "asset.bin -filter\n"
        try fixture.write(".gitattributes", headAttributes)
        try fixture.write("asset.bin", "tracked payload\n")
        try fixture.git.run("add", ".")
        try fixture.git.run("commit", "-m", "attribute baseline")
        try fixture.write(".gitattributes", "asset.bin filter=custom\n")
        try fixture.git.run("add", ".gitattributes")
        try fixture.write(".gitattributes", headAttributes)
        let destination = fixture.destination()
        let beforeBranches = try fixture.branchNames()
        let request = fixture.request(
            destination: destination,
            mode: .newBranch(name: "fork-staged-attributes"),
            materialization: .changesOnly
        )

        // Act
        let failure = await forkFailure(request)

        // Assert
        guard case .workingStateUnsupported(let refusal) = failure else {
            Issue.record("expected an attributes preflight refusal, got \(String(describing: failure))")
            return
        }
        #expect(refusal.reason.rawValue == "attributesChanged")
        #expect(refusal.relativePath == ".gitattributes")
        #expect(try Data(contentsOf: fixture.source.appending(path: ".gitattributes")) == Data(headAttributes.utf8))
        #expect(!(try fixture.git.succeeds("diff", "--cached", "--quiet", "--", ".gitattributes")))
        #expect(!GitWorktreeForkFileProbe.exists(destination))
        #expect(!GitWorktreeForkFileProbe.exists(fixture.linkedWorktreeAdministration("fork-staged-attributes")))
        #expect(try fixture.branchNames() == beforeBranches)
    }

    private func forkFailure(_ request: GitForkWorktreeRequest) async -> GitWorktreeForkError? {
        do {
            _ = try await LibGit2AgentStudioGitLocalClient().forkWorktree(request)
            return nil
        } catch {
            return error
        }
    }
}
