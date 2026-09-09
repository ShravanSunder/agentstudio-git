import AgentStudioGitLocal
import Foundation
import Testing

@Suite("Exact clean Git baseline integration")
struct GitExactCleanBaselineIntegrationTests {
    @Test("worktree attribute aliases cannot authorize unobserved clean renewal", arguments: ["", "nested/deeper/"])
    func worktreeAttributeAliasMustNotMintBaseline(directory: String) async throws {
        // Arrange: only the external target will change after the clean read.
        let fixture = try GitFixtureRepository.makeRepository(prefix: "agentstudio-git-worktree-attribute-alias")
        defer { fixture.remove() }
        try fixture.git.run("config", "core.autocrlf", "false")
        let externalAttributes = fixture.root.appending(path: "external-attributes")
        try "line-endings.txt -text\n".write(to: externalAttributes, atomically: true, encoding: .utf8)
        let relativeFile = directory + "line-endings.txt"
        try fixture.write(relativeFile, contents: "first\r\nsecond\r\n")
        try fixture.git.run("add", relativeFile)
        try fixture.git.run("commit", "-m", "track literal line endings")
        let attributeAlias = fixture.repositoryPath.appending(path: directory + ".gitattributes")
        try FileManager.default.createSymbolicLink(at: attributeAlias, withDestinationURL: externalAttributes)
        try fixture.git.run("add", directory + ".gitattributes")
        try fixture.git.run("commit", "-m", "track attribute alias")
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 4_102_444_800)],
            ofItemAtPath: fixture.repositoryPath.appending(path: relativeFile).path
        )
        let client = LibGit2AgentStudioGitLocalClient()
        let plan = try await client.statusObservationPlan(for: fixture.repositoryPath)
        let before = try await client.statusFacts(
            for: fixture.repositoryPath, options: GitStatusOptions(), observationPlan: plan)
        #expect(before.facts.entries.isEmpty)

        // Act
        try "line-endings.txt text eol=lf\n".write(to: externalAttributes, atomically: true, encoding: .utf8)
        let after = try await client.statusFacts(for: fixture.repositoryPath, options: GitStatusOptions())

        // Assert: exact reads remain valid, but an unwatched input cannot renew clean authority.
        #expect(after.facts.entries.contains { $0.path == relativeFile && $0.worktreeState == .modified })
        #expect(plan.support == .unsupported)
        #expect(before.exactCleanBaseline == nil)
    }

    enum AttributeLocation: CaseIterable {
        case common, configured, commonSymlink, configuredSymlink

        var usesConfiguration: Bool { self == .configured || self == .configuredSymlink }
        var usesSymlink: Bool { self == .commonSymlink || self == .configuredSymlink }
    }

    @Test(
        "linked clean authority observes attribute inputs outside its worktree", arguments: AttributeLocation.allCases)
    func linkedAttributeChangesMustBeObserved(location: AttributeLocation) async throws {
        // Arrange
        let fixture = try GitFixtureRepository.makeRepository(prefix: "agentstudio-git-attribute-observation")
        defer { fixture.remove() }
        try fixture.git.run("config", "core.autocrlf", "false")
        let attributePath =
            location.usesConfiguration
            ? fixture.root.appending(path: "external-attributes")
            : fixture.repositoryPath.appending(path: ".git/info/attributes")
        let initialAttributeTarget =
            location.usesSymlink
            ? fixture.root.appending(path: "initial-attribute-target") : attributePath
        try "line-endings.txt -text\n".write(to: initialAttributeTarget, atomically: true, encoding: .utf8)
        if location.usesSymlink {
            try FileManager.default.createSymbolicLink(at: attributePath, withDestinationURL: initialAttributeTarget)
        }
        if location.usesConfiguration {
            try fixture.git.run("config", "core.attributesFile", attributePath.path)
        }
        try fixture.write("line-endings.txt", contents: "first\r\nsecond\r\n")
        try fixture.git.run("add", "line-endings.txt")
        try fixture.git.run("commit", "-m", "track exact line endings")
        let linkedPath = try fixture.addLinkedWorktree(named: "linked", branch: "linked-attributes")
        // Keep index stat data stale: NO_REFRESH must hash content without timing-dependent sleeps.
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 4_102_444_800)],
            ofItemAtPath: linkedPath.appending(path: "line-endings.txt").path
        )
        let client = LibGit2AgentStudioGitLocalClient()
        let plan = try await client.statusObservationPlan(for: linkedPath)
        let before = try await client.statusFacts(
            for: linkedPath, options: GitStatusOptions(), observationPlan: plan
        )
        #expect(before.facts.entries.isEmpty)
        let observedAttributePath = attributePath.standardizedFileURL

        // Act: only the attribute dependency changes, not the worktree file or index.
        if location.usesSymlink {
            let replacementTarget = fixture.root.appending(path: "replacement-attribute-target")
            try "line-endings.txt text eol=lf\n".write(to: replacementTarget, atomically: true, encoding: .utf8)
            try FileManager.default.removeItem(at: attributePath)
            try FileManager.default.createSymbolicLink(at: attributePath, withDestinationURL: replacementTarget)
        } else {
            try "line-endings.txt text eol=lf\n".write(to: attributePath, atomically: true, encoding: .utf8)
        }
        let after = try await client.statusFacts(for: linkedPath, options: GitStatusOptions())

        // Assert: exact Git sees the difference; continuity must observe its input or decline authority.
        #expect(after.facts.entries.contains { $0.path == "line-endings.txt" && $0.worktreeState == .modified })
        #expect(
            plan.support == .unsupported
                || plan.scopes.contains { scope in
                    scope.path == observedAttributePath
                        || (scope.kind == .subtree && observedAttributePath.path.hasPrefix(scope.path.path + "/"))
                }
        )
        if plan.support == .unsupported {
            #expect(before.exactCleanBaseline == nil)
        } else {
            #expect(before.exactCleanBaseline?.observationIdentity == plan.identity)
        }
    }

    @Test("empty and missing external includes cannot authorize unobserved clean renewal", arguments: [false, true])
    func externalIncludeDependencyMustBeObservedOrUnsupported(createEmptyFile: Bool) async throws {
        // Arrange
        let fixture = try GitFixtureRepository.makeRepository(prefix: "agentstudio-git-external-include")
        defer { fixture.remove() }
        let includePath = fixture.root.appending(path: "external.gitconfig")
        if createEmptyFile {
            try "".write(to: includePath, atomically: true, encoding: .utf8)
        }
        try fixture.git.run("config", "include.path", includePath.path)
        let client = LibGit2AgentStudioGitLocalClient()

        // Act
        let plan = try await client.statusObservationPlan(for: fixture.repositoryPath)
        let observesInclude = plan.scopes.contains {
            $0.path == includePath.standardizedFileURL.resolvingSymlinksInPath()
        }

        // Assert
        #expect(plan.support == .unsupported || observesInclude)
        let cleanRead = try await client.statusFacts(
            for: fixture.repositoryPath, options: GitStatusOptions(), observationPlan: plan)
        #expect(cleanRead.facts.entries.isEmpty)
        if !observesInclude {
            #expect(cleanRead.exactCleanBaseline == nil)
        }
    }

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
