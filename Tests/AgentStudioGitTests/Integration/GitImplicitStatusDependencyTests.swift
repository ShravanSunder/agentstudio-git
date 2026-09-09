import AgentStudioGitLocal
import Darwin
import Foundation
import Testing

// The owning SDK runner executes this global-environment fixture in its own process.
@Suite("Implicit Git status dependencies", .serialized)
struct GitImplicitStatusDependencyTests {
    @Test("default XDG attributes and ignores are observed before clean authority")
    func implicitXDGFilesMustBeObserved() async throws {
        let fixture = try GitFixtureRepository.makeRepository(prefix: "agentstudio-git-implicit-inputs")
        defer { fixture.remove() }
        let xdgRoot = fixture.root.appending(path: "xdg")
        let gitDirectory = xdgRoot.appending(path: "git")
        try FileManager.default.createDirectory(at: gitDirectory, withIntermediateDirectories: true)
        let originalXDGHome = getenv("XDG_CONFIG_HOME").map { String(cString: $0) }
        setenv("XDG_CONFIG_HOME", xdgRoot.path, 1)
        defer {
            if let originalXDGHome {
                setenv("XDG_CONFIG_HOME", originalXDGHome, 1)
            } else {
                unsetenv("XDG_CONFIG_HOME")
            }
        }
        let attributesPath = gitDirectory.appending(path: "attributes")
        let ignoresPath = gitDirectory.appending(path: "ignore")
        try "line-endings.txt -text\n".write(to: attributesPath, atomically: true, encoding: .utf8)
        try "ignored-input.txt\n".write(to: ignoresPath, atomically: true, encoding: .utf8)
        try fixture.git.run("config", "core.autocrlf", "false")
        try fixture.write("line-endings.txt", contents: "first\r\nsecond\r\n")
        try fixture.git.run("add", "line-endings.txt")
        try fixture.git.run("commit", "-m", "track raw line endings")
        try fixture.write("ignored-input.txt", contents: "ignored\n")
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 4_102_444_800)],
            ofItemAtPath: fixture.repositoryPath.appending(path: "line-endings.txt").path
        )
        let client = LibGit2AgentStudioGitLocalClient()
        let plan = try await client.statusObservationPlan(for: fixture.repositoryPath)
        let before = try await client.statusFacts(
            for: fixture.repositoryPath, options: GitStatusOptions(), observationPlan: plan
        )
        #expect(before.facts.entries.isEmpty)

        try "line-endings.txt text eol=lf\n".write(to: attributesPath, atomically: true, encoding: .utf8)
        try "".write(to: ignoresPath, atomically: true, encoding: .utf8)
        let after = try await client.statusFacts(for: fixture.repositoryPath, options: GitStatusOptions())
        #expect(after.facts.entries.contains { $0.path == "line-endings.txt" && $0.worktreeState == .modified })
        #expect(after.facts.entries.contains { $0.path == "ignored-input.txt" && $0.untracked })
        for dependencyPath in [attributesPath, ignoresPath] {
            #expect(
                plan.support == .unsupported
                    || plan.scopes.contains { $0.kind == .item && $0.path == dependencyPath.standardizedFileURL }
            )
        }
        if plan.support == .unsupported { #expect(before.exactCleanBaseline == nil) }
    }
}
