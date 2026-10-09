import AgentStudioGit
import Foundation
import Testing

/// Opt-in real-path timing evidence. No wall-clock assertion is made. Detached sibling forks avoid
/// creating branches, and cleanup proves both destination and registration are gone after each run.
@Suite(
    "Git worktree copy rules real-checkout timings", .serialized,
    .enabled(if: ProcessInfo.processInfo.environment["AGENTSTUDIO_GIT_COPY_RULES_REAL_SOURCE"] != nil))
struct GitWorktreeForkCopyRulesRealCheckoutTests {
    @Test("compare copyAll with copyMatching on the same real checkout and clean both forks")
    func compareRealCheckout() async throws {
        let source = URL(
            fileURLWithPath: try #require(ProcessInfo.processInfo.environment["AGENTSTUDIO_GIT_COPY_RULES_REAL_SOURCE"])
        )
        let prefix = try #require(ProcessInfo.processInfo.environment["AGENTSTUDIO_GIT_COPY_RULES_DESTINATION_PREFIX"])
        let git = GitProcess(repositoryPath: source)
        let sourceHead = try git.run("rev-parse", "HEAD")
        let statusBefore = try git.run("--no-optional-locks", "status", "--porcelain")
        let registryBefore = registeredPaths(try git.run("worktree", "list", "--porcelain"))
        let policies: [(String, GitIgnoredPathPolicy)] = [
            ("copyAll", .copyAll),
            (
                "copyMatching",
                .copyMatching(
                    try [".build*/", "Frameworks/", "node_modules/", "BridgeWeb/node_modules/"].map {
                        try GitPathPattern($0)
                    })
            ),
        ]
        for (label, policy) in policies {
            let destination = URL(fileURLWithPath: prefix + "-" + label)
            try #require(!GitWorktreeForkFileProbe.exists(destination), "proof destination already exists")
            let administrationText = try git.run("rev-parse", "--git-common-dir").trimmingCharacters(
                in: .whitespacesAndNewlines)
            let administration =
                administrationText.hasPrefix("/")
                ? URL(fileURLWithPath: administrationText)
                : source.appending(path: administrationText)
            let registration = administration.appending(path: "worktrees/" + destination.lastPathComponent)
            try #require(!GitWorktreeForkFileProbe.exists(registration), "proof registration already exists")
            defer {
                if GitWorktreeForkFileProbe.exists(destination) {
                    do { try git.run("worktree", "remove", "--force", destination.path) } catch {
                        Issue.record("proof cleanup failed: \(error)")
                    }
                }
                #expect(!GitWorktreeForkFileProbe.exists(destination))
                #expect(!GitWorktreeForkFileProbe.exists(registration))
            }
            let started = ContinuousClock.now
            let result = try await LibGit2AgentStudioGitLocalClient().forkWorktree(
                .init(
                    sourceWorktreePath: source, destinationPath: destination, mode: .detached(start: .sourceHead),
                    materialization: .copyOnWrite, copyRules: .init(ignoredPaths: policy)))
            let elapsed = started.duration(to: .now)
            #expect(try git.run(["rev-parse", "HEAD"], currentDirectory: destination) == sourceHead)
            #expect(try git.run("--no-optional-locks", "status", "--porcelain") == statusBefore)
            guard case .copyOnWrite(let report) = result.materialization else {
                Issue.record("expected copy-on-write report")
                return
            }
            #expect(GitWorktreeForkFileProbe.exists(destination.appending(path: "Frameworks/GhosttyKit.xcframework")))
            if label == "copyMatching" { #expect(report.ignoredIncludedPatterns.contains("Frameworks/")) }
            print(
                "COPY_RULES_REAL \(label) excludedTopLevelRoots=\(try omittedRoots(source: source, destination: destination))"
            )
            print(
                "COPY_RULES_REAL \(label) wall=\(elapsed) clonedFiles=\(report.clonedRegularFileCount) "
                    + "ignoredExcluded=\(report.ignoredExcludedCount) included=\(report.ignoredIncludedPatterns) nestedSkipped=\(report.nestedWorktreesSkipped)"
            )
        }
        // Other live worktrees can commit during this proof. Compare membership, while checking this
        // source's HEAD/status and our exact destination registrations independently.
        #expect(registeredPaths(try git.run("worktree", "list", "--porcelain")) == registryBefore)
        #expect(try git.run("rev-parse", "HEAD") == sourceHead)
        #expect(try git.run("--no-optional-locks", "status", "--porcelain") == statusBefore)
    }

    private func registeredPaths(_ listing: String) -> [String] {
        listing.split(separator: "\n").filter { $0.hasPrefix("worktree ") }.map(String.init).sorted()
    }

    /// Maximal absent paths: report an omitted directory once instead of listing its entire subtree.
    /// This observational scan is outside the measured SDK call and never follows symbolic links.
    private func omittedRoots(source: URL, destination: URL) throws -> [String] {
        let enumerator = try #require(
            FileManager.default.enumerator(
                at: source,
                includingPropertiesForKeys: nil))
        var omitted: [String] = []
        for case let entry as URL in enumerator {
            let relativePath = String(entry.path.dropFirst(source.path.count + 1))
            if relativePath == ".git" {
                enumerator.skipDescendants()
                continue
            }
            if !GitWorktreeForkFileProbe.exists(destination.appending(path: relativePath)) {
                omitted.append(relativePath)
                enumerator.skipDescendants()
            }
        }
        return omitted.sorted()
    }
}
