import AgentStudioGitLocal
import Foundation
import Testing

@Suite("Exact clean Git baseline integration")
struct GitExactCleanBaselineIntegrationTests {
    @Test("full clean facts mint a baseline tied to the prepared observation plan")
    func fullCleanFactsMintBaseline() async throws {
        let fixture = try GitFixtureRepository.makeRepository(prefix: "agentstudio-git-exact-clean")
        defer { fixture.remove() }
        let client = LibGit2AgentStudioGitLocalClient()

        let plan = try await client.statusObservationPlan(for: fixture.repositoryPath)
        let read = try await client.statusFacts(
            for: fixture.repositoryPath,
            options: GitStatusOptions(),
            observationPlan: plan
        )

        #expect(plan.support == .supported)
        #expect(!plan.scopes.isEmpty)
        #expect(read.facts.entries.isEmpty)
        #expect(read.exactCleanBaseline?.observationIdentity == plan.identity)
    }

    @Test("dirty and recursively untracked worktrees do not mint a baseline")
    func dirtyWorktreesDoNotMintBaseline() async throws {
        let fixture = try GitFixtureRepository.makeRepository(prefix: "agentstudio-git-exact-dirty")
        defer { fixture.remove() }
        let client = LibGit2AgentStudioGitLocalClient()
        let plan = try await client.statusObservationPlan(for: fixture.repositoryPath)
        try fixture.write("nested/untracked.txt", contents: "untracked\n")

        let read = try await client.statusFacts(
            for: fixture.repositoryPath,
            options: GitStatusOptions(),
            observationPlan: plan
        )

        #expect(read.facts.entries.map(\.path) == ["nested/untracked.txt"])
        #expect(read.exactCleanBaseline == nil)
    }

    @Test("scoped and untracked-disabled reads never mint a baseline")
    func incompleteReadsDoNotMintBaseline() async throws {
        let fixture = try GitFixtureRepository.makeRepository(prefix: "agentstudio-git-exact-incomplete")
        defer { fixture.remove() }
        let client = LibGit2AgentStudioGitLocalClient()
        let plan = try await client.statusObservationPlan(for: fixture.repositoryPath)

        let scoped = try await client.statusFacts(
            for: fixture.repositoryPath,
            options: GitStatusOptions(pathspecs: ["README.md"]),
            observationPlan: plan
        )
        let withoutUntracked = try await client.statusFacts(
            for: fixture.repositoryPath,
            options: GitStatusOptions(includeUntracked: false),
            observationPlan: plan
        )
        let emptyPathspec = try await client.statusFacts(
            for: fixture.repositoryPath,
            options: GitStatusOptions(pathspecs: []),
            observationPlan: plan
        )

        #expect(scoped.exactCleanBaseline == nil)
        #expect(withoutUntracked.exactCleanBaseline == nil)
        #expect(emptyPathspec.exactCleanBaseline == nil)
    }

    @Test("observation identity drift rejects baseline while preserving exact facts")
    func observationIdentityDriftRejectsBaseline() async throws {
        let fixture = try GitFixtureRepository.makeRepository(prefix: "agentstudio-git-exact-drift")
        defer { fixture.remove() }
        let client = LibGit2AgentStudioGitLocalClient()
        let plan = try await client.statusObservationPlan(for: fixture.repositoryPath)
        let externalExcludes = fixture.root.appending(path: "changed-excludes")
        try "ignored-after-plan.txt\n".write(to: externalExcludes, atomically: true, encoding: .utf8)
        try fixture.git.run("config", "core.excludesFile", externalExcludes.path)

        let read = try await client.statusFacts(
            for: fixture.repositoryPath,
            options: GitStatusOptions(),
            observationPlan: plan
        )

        #expect(read.facts.entries.isEmpty)
        #expect(read.exactCleanBaseline == nil)
    }

    @Test("linked worktrees expose their exact index and Git dependencies")
    func linkedWorktreePlanIncludesIndex() async throws {
        let fixture = try GitFixtureRepository.makeRepository(prefix: "agentstudio-git-exact-linked")
        defer { fixture.remove() }
        let linkedPath = try fixture.addLinkedWorktree(named: "linked", branch: "linked-branch")
        let client = LibGit2AgentStudioGitLocalClient()

        let plan = try await client.statusObservationPlan(for: linkedPath)
        let snapshot = try await client.worktrees(for: fixture.repositoryPath)
            .first { !$0.isMainWorktree && $0.displayName == "linked" }

        #expect(snapshot != nil)
        #expect(plan.scopes.contains { $0.path == snapshot?.indexPath && $0.kind == .item })
    }

    @Test("staged tracked rename and type changes cannot mint clean authority")
    func trackedMutationKindsCannotMintBaseline() async throws {
        let client = LibGit2AgentStudioGitLocalClient()

        let stagedFixture = try GitFixtureRepository.makeRepository(prefix: "agentstudio-git-exact-staged")
        defer { stagedFixture.remove() }
        let stagedPlan = try await client.statusObservationPlan(for: stagedFixture.repositoryPath)
        try stagedFixture.write("README.md", contents: "staged\n")
        try stagedFixture.git.run("add", "README.md")
        let stagedRead = try await client.statusFacts(
            for: stagedFixture.repositoryPath, options: GitStatusOptions(), observationPlan: stagedPlan)
        #expect(stagedRead.exactCleanBaseline == nil)

        let renameFixture = try GitFixtureRepository.makeRepository(prefix: "agentstudio-git-exact-rename")
        defer { renameFixture.remove() }
        let renamePlan = try await client.statusObservationPlan(for: renameFixture.repositoryPath)
        try renameFixture.git.run("mv", "README.md", "RENAMED.md")
        let renameRead = try await client.statusFacts(
            for: renameFixture.repositoryPath, options: GitStatusOptions(), observationPlan: renamePlan)
        #expect(renameRead.facts.entries.contains { $0.indexState == .renamed })
        #expect(renameRead.exactCleanBaseline == nil)

        let typeFixture = try GitFixtureRepository.makeRepository(prefix: "agentstudio-git-exact-type")
        defer { typeFixture.remove() }
        let typePlan = try await client.statusObservationPlan(for: typeFixture.repositoryPath)
        try FileManager.default.removeItem(at: typeFixture.repositoryPath.appending(path: "README.md"))
        try FileManager.default.createSymbolicLink(
            at: typeFixture.repositoryPath.appending(path: "README.md"),
            withDestinationURL: URL(fileURLWithPath: "/tmp")
        )
        let typeRead = try await client.statusFacts(
            for: typeFixture.repositoryPath, options: GitStatusOptions(), observationPlan: typePlan)
        #expect(typeRead.facts.entries.contains { $0.worktreeState == .typeChanged })
        #expect(typeRead.exactCleanBaseline == nil)
    }

    @Test("resolved config include and excludes files are exact observation items")
    func configDependenciesAreObservationItems() async throws {
        let fixture = try GitFixtureRepository.makeRepository(prefix: "agentstudio-git-exact-config")
        defer { fixture.remove() }
        let includedConfig = fixture.root.appending(path: "included.gitconfig")
        let excludesFile = fixture.root.appending(path: "global-excludes")
        try "[core]\n\tfilemode = false\n".write(to: includedConfig, atomically: true, encoding: .utf8)
        try "ignored.txt\n".write(to: excludesFile, atomically: true, encoding: .utf8)
        try fixture.git.run("config", "include.path", includedConfig.path)
        try fixture.git.run("config", "core.excludesFile", excludesFile.path)
        let client = LibGit2AgentStudioGitLocalClient()

        let plan = try await client.statusObservationPlan(for: fixture.repositoryPath)

        #expect(plan.scopes.contains { $0.kind == .item && $0.path == includedConfig.standardizedFileURL })
        #expect(plan.scopes.contains { $0.kind == .item && $0.path == excludesFile.standardizedFileURL })
    }

    @Test("conflicts and initialized submodule mutations cannot mint authority")
    func conflictAndSubmoduleMutationCannotMintBaseline() async throws {
        let client = LibGit2AgentStudioGitLocalClient()
        let conflictFixture = try GitFixtureRepository.makeRepository(prefix: "agentstudio-git-exact-conflict")
        defer { conflictFixture.remove() }
        try conflictFixture.git.run("checkout", "-b", "conflicting")
        try conflictFixture.write("README.md", contents: "branch\n")
        try conflictFixture.git.run("commit", "-am", "branch")
        try conflictFixture.git.run("checkout", "main")
        try conflictFixture.write("README.md", contents: "main\n")
        try conflictFixture.git.run("commit", "-am", "main")
        let conflictPlan = try await client.statusObservationPlan(for: conflictFixture.repositoryPath)
        #expect(try !conflictFixture.git.succeeds("merge", "conflicting"))
        let conflictRead = try await client.statusFacts(
            for: conflictFixture.repositoryPath, options: GitStatusOptions(), observationPlan: conflictPlan)
        #expect(conflictRead.facts.entries.contains { $0.indexState == .unmerged || $0.worktreeState == .unmerged })
        #expect(conflictRead.exactCleanBaseline == nil)

        let parent = try GitFixtureRepository.makeRepository(prefix: "agentstudio-git-exact-submodule")
        defer { parent.remove() }
        let child = try GitFixtureRepository.makeRepository(prefix: "agentstudio-git-exact-submodule-child")
        defer { child.remove() }
        try parent.git.run(
            "-c", "protocol.file.allow=always", "submodule", "add", child.repositoryPath.path, "Vendor/Child")
        try parent.git.run("commit", "-am", "add submodule")
        let submodulePlan = try await client.statusObservationPlan(for: parent.repositoryPath)
        try "changed\n".write(
            to: parent.repositoryPath.appending(path: "Vendor/Child/README.md"), atomically: true, encoding: .utf8)
        let submoduleRead = try await client.statusFacts(
            for: parent.repositoryPath, options: GitStatusOptions(), observationPlan: submodulePlan)
        #expect(submodulePlan.scopes.contains { $0.kind == .subtree && $0.path.path.hasSuffix("/.git/modules") })
        #expect(!submoduleRead.facts.entries.isEmpty)
        #expect(submoduleRead.exactCleanBaseline == nil)
    }

    @Test("unsupported observation plans preserve exact facts without authority")
    func unsupportedPlanPreservesFacts() async throws {
        let fixture = try GitFixtureRepository.makeRepository(prefix: "agentstudio-git-exact-unsupported")
        defer { fixture.remove() }
        let client = LibGit2AgentStudioGitLocalClient()
        let resolvedPlan = try await client.statusObservationPlan(for: fixture.repositoryPath)
        let unsupportedPlan = GitStatusObservationPlan(
            identity: resolvedPlan.identity,
            scopes: resolvedPlan.scopes,
            support: .unsupported
        )

        let read = try await client.statusFacts(
            for: fixture.repositoryPath, options: GitStatusOptions(), observationPlan: unsupportedPlan)

        #expect(read.facts.entries.isEmpty)
        #expect(read.exactCleanBaseline == nil)
    }
}
