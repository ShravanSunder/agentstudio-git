import AgentStudioGit
import Darwin
import Foundation
import Testing

@testable import AgentStudioGitLocal

@Suite("Git worktree changes-only tracked-state integration", .serialized)
struct GitWorktreeForkTrackedStateIntegrationTests {
    @Test("a mode-only tracked edit is carried when core.filemode is false")
    func modeOnlyEditIsCarriedWhenFileModeDetectionIsDisabled() async throws {
        // Arrange
        let fixture = try GitWorktreeForkFixture.make(prefix: "agentstudio-git-fork-filemode-disabled")
        defer { fixture.remove() }
        try fixture.write("tool", "run me\n")
        try fixture.git.run("add", "tool")
        try fixture.git.run("commit", "-m", "mode-only baseline")
        try fixture.git.run(["config", "core.filemode", "false"])
        #expect(chmod(fixture.source.appending(path: "tool").path, 0o755) == 0)
        #expect(try fixture.statusLines(at: fixture.source).isEmpty)

        // Act
        let result = try await LibGit2AgentStudioGitLocalClient().forkWorktree(
            fixture.request(materialization: .changesOnly))

        // Assert
        let destinationTool = try #require(GitWorktreeForkFileProbe.info(fixture.destination().appending(path: "tool")))
        #expect(destinationTool.st_mode & S_IXUSR != 0)
        #expect(try fixture.statusLines(at: fixture.source).isEmpty)
        guard case .changesOnly(let report) = result.materialization else {
            Issue.record("expected changes-only materialization")
            return
        }
        #expect(report.trackedChanges == 1)
    }

    @Test("a dirty submodule is refused when diff.ignoreSubmodules is all")
    func dirtySubmoduleIsRefusedDespiteGlobalIgnore() async throws {
        // Arrange
        let fixture = try Self.makeFixtureWithSubmodule(
            prefix: "agentstudio-git-fork-global-submodule-ignore")
        defer { fixture.remove() }
        try fixture.write("README.md", "dirty module\n", in: fixture.source.appending(path: "deps/module"))
        try fixture.git.run(["config", "diff.ignoreSubmodules", "all"])
        #expect(try fixture.statusLines(at: fixture.source).isEmpty)
        let branchesBefore = try fixture.branchNames()
        let destination = fixture.destination()

        // Act
        let failure = await Self.forkFailure(fixture.request(destination: destination, materialization: .changesOnly))

        // Assert
        #expect(
            failure
                == .workingStateUnsupported(
                    GitWorktreeWorkingStateRefusal(reason: .submoduleChanged, relativePath: "deps/module")))
        #expect(!GitWorktreeForkFileProbe.exists(destination))
        #expect(!GitWorktreeForkFileProbe.exists(fixture.linkedWorktreeAdministration()))
        #expect(try fixture.branchNames() == branchesBefore)
    }

    @Test("a moved submodule is refused when its per-submodule ignore is all")
    func movedSubmoduleIsRefusedDespitePerSubmoduleIgnore() async throws {
        // Arrange
        let fixture = try Self.makeFixtureWithSubmodule(prefix: "agentstudio-git-fork-submodule-ignore-all")
        defer { fixture.remove() }
        let submodulePath = fixture.source.appending(path: "deps/module")
        let submoduleGit = GitProcess(repositoryPath: submodulePath)
        try fixture.write("README.md", "advanced module\n", in: submodulePath)
        try submoduleGit.run("add", "README.md")
        try submoduleGit.run("commit", "-m", "advance submodule HEAD")
        try fixture.git.run(["config", "submodule.deps/module.ignore", "all"])
        #expect(try fixture.statusLines(at: fixture.source).isEmpty)
        let branchesBefore = try fixture.branchNames()
        let destination = fixture.destination()

        // Act
        let failure = await Self.forkFailure(fixture.request(destination: destination, materialization: .changesOnly))

        // Assert
        #expect(
            failure
                == .workingStateUnsupported(
                    GitWorktreeWorkingStateRefusal(reason: .submoduleChanged, relativePath: "deps/module")))
        #expect(!GitWorktreeForkFileProbe.exists(destination))
        #expect(!GitWorktreeForkFileProbe.exists(fixture.linkedWorktreeAdministration()))
        #expect(try fixture.branchNames() == branchesBefore)
    }

    private static func makeFixtureWithSubmodule(prefix: String) throws -> GitWorktreeForkFixture {
        let fixture = try GitWorktreeForkFixture.make(prefix: prefix)
        do {
            let moduleRoot = fixture.repository.root.appending(path: "module-source")
            try FileManager.default.createDirectory(at: moduleRoot, withIntermediateDirectories: true)
            let moduleGit = GitProcess(repositoryPath: moduleRoot)
            try moduleGit.run("init")
            try fixture.write("README.md", "module baseline\n", in: moduleRoot)
            try moduleGit.run("add", "README.md")
            try moduleGit.run("commit", "-m", "submodule baseline")
            try fixture.git.run(["submodule", "add", "-q", moduleRoot.path, "deps/module"])
            try fixture.git.run("commit", "-m", "add submodule")
            return fixture
        } catch {
            fixture.remove()
            throw error
        }
    }

    private static func forkFailure(_ request: GitForkWorktreeRequest) async -> GitWorktreeForkError? {
        do {
            _ = try await LibGit2AgentStudioGitLocalClient().forkWorktree(request)
            return nil
        } catch {
            return error
        }
    }
}
