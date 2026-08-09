import AgentStudioGit
import Foundation
import Testing

@Suite("Git working tree status compatibility")
struct GitWorkingTreeStatusCompatibilityTests {
    @Test("SDK status snapshot maps into the current AgentStudio working-tree status shape")
    func sdkStatusSnapshotMapsIntoCurrentAgentStudioWorkingTreeStatusShape() async throws {
        let provider = AppStatusCompatibilityProvider(
            client: StubLocalClient(
                snapshot: GitStatusSnapshot(
                    repositoryRoot: URL(fileURLWithPath: "/tmp/repo"),
                    worktreePath: URL(fileURLWithPath: "/tmp/repo"),
                    generatedAtUnixMilliseconds: 1,
                    head: GitHeadSnapshot(kind: .branch, oid: "abc123", shortName: "feature/sdk"),
                    originResolution: .resolved(
                        GitRemoteSnapshot(
                            name: "origin",
                            url: URL(string: "git@example.com:agentstudio/agent-studio.git")!,
                            rawURL: "git@example.com:agentstudio/agent-studio.git"
                        )
                    ),
                    summary: GitStatusSummary(
                        changedFileCount: 5,
                        stagedFileCount: 2,
                        unstagedFileCount: 3,
                        untrackedFileCount: 1,
                        ignoredFileCount: 0,
                        linesAdded: 8,
                        linesDeleted: 4,
                        aheadCount: 1,
                        behindCount: 2,
                        hasUpstream: true
                    ),
                    entries: []
                )
            )
        )

        let status = try #require(await provider.status(for: URL(fileURLWithPath: "/tmp/repo")))

        #expect(status.summary.changed == 3)
        #expect(status.summary.staged == 2)
        #expect(status.summary.untracked == 1)
        #expect(status.summary.linesAdded == 8)
        #expect(status.summary.linesDeleted == 4)
        #expect(status.summary.aheadCount == 1)
        #expect(status.summary.behindCount == 2)
        #expect(status.summary.hasUpstream == true)
        #expect(status.branch == "feature/sdk")
        #expect(status.originResolution == .resolved("git@example.com:agentstudio/agent-studio.git"))
    }

    @Test("SDK status snapshot preserves current AgentStudio origin and sync optional semantics")
    func sdkStatusSnapshotPreservesCurrentAgentStudioOriginAndSyncOptionalSemantics() async throws {
        let provider = AppStatusCompatibilityProvider(
            client: StubLocalClient(
                snapshot: GitStatusSnapshot(
                    repositoryRoot: URL(fileURLWithPath: "/tmp/repo"),
                    worktreePath: URL(fileURLWithPath: "/tmp/repo"),
                    generatedAtUnixMilliseconds: 1,
                    head: GitHeadSnapshot(kind: .branch, oid: "abc123", shortName: "main"),
                    originResolution: .resolved(
                        GitRemoteSnapshot(
                            name: "origin",
                            url: URL(fileURLWithPath: "/tmp/origin.git"),
                            rawURL: "/tmp/origin.git"
                        )
                    ),
                    summary: GitStatusSummary(
                        changedFileCount: 0,
                        stagedFileCount: 0,
                        unstagedFileCount: 0,
                        untrackedFileCount: 0,
                        ignoredFileCount: 0,
                        linesAdded: 0,
                        linesDeleted: 0,
                        aheadCount: 0,
                        behindCount: 0,
                        hasUpstream: false
                    ),
                    entries: []
                )
            )
        )

        let status = try #require(await provider.status(for: URL(fileURLWithPath: "/tmp/repo")))

        #expect(status.summary.aheadCount == nil)
        #expect(status.summary.behindCount == nil)
        #expect(status.summary.hasUpstream == false)
        #expect(status.originResolution == .resolved("/tmp/origin.git"))
    }

    @Test("detached SDK heads map to AgentStudio's branchless sync-unknown status")
    func detachedSDKHeadsMapToAgentStudiosBranchlessSyncUnknownStatus() async throws {
        let provider = AppStatusCompatibilityProvider(
            client: StubLocalClient(
                snapshot: GitStatusSnapshot(
                    repositoryRoot: URL(fileURLWithPath: "/tmp/repo"),
                    worktreePath: URL(fileURLWithPath: "/tmp/repo"),
                    generatedAtUnixMilliseconds: 1,
                    head: GitHeadSnapshot(kind: .detached, oid: "abc123", shortName: nil),
                    originResolution: .confirmedAbsent,
                    summary: GitStatusSummary(
                        changedFileCount: 0,
                        stagedFileCount: 0,
                        unstagedFileCount: 0,
                        untrackedFileCount: 0,
                        ignoredFileCount: 0,
                        linesAdded: 0,
                        linesDeleted: 0,
                        aheadCount: 0,
                        behindCount: 0,
                        hasUpstream: false
                    ),
                    entries: []
                )
            )
        )

        let status = try #require(await provider.status(for: URL(fileURLWithPath: "/tmp/repo")))

        #expect(status.branch == nil)
        #expect(status.summary.aheadCount == nil)
        #expect(status.summary.behindCount == nil)
        #expect(status.summary.hasUpstream == nil)
        #expect(status.originResolution == .confirmedAbsent)
    }

    @Test("local client status drives the compatibility provider against a real repository")
    func localClientStatusDrivesCompatibilityProviderAgainstRealRepository() async throws {
        let fixture = try GitFixtureRepository.makeRepository(prefix: "agentstudio-git-status-compatibility")
        defer { fixture.remove() }
        try fixture.write("README.md", contents: "hello\ncompatibility\n")
        let provider = AppStatusCompatibilityProvider(
            client: LibGit2AgentStudioGitLocalClient()
        )

        let status = try #require(await provider.status(for: fixture.repositoryPath))

        #expect(status.branch == "main")
        #expect(status.summary.changed == 1)
        #expect(status.summary.linesAdded == 1)
    }

    @Test("adapter harness typechecks against the checked out AgentStudio seam")
    func adapterHarnessTypechecksAgainstCheckedOutAgentStudioSeam() throws {
        try AgentStudioStatusAdapterCompileHarness().typecheck()
    }

    @Test("compatibility harness resolves hosted libgit2 headers by default")
    func compatibilityHarnessResolvesHostedLibGit2HeadersByDefault() throws {
        let fixture = try LibGit2HeaderSearchPathFixture.make()
        defer { fixture.remove() }

        let resolvedPath = try AgentStudioCompatibilityHarnessSupport.libGit2HeaderSearchPath(
            packageRoot: fixture.packageRoot,
            debugBuildPath: fixture.debugBuildPath,
            environment: [:]
        )

        #expect(resolvedPath.standardizedFileURL == fixture.hostedHeadersPath.standardizedFileURL)
    }

    @Test("compatibility harness uses local libgit2 headers only in local artifact mode")
    func compatibilityHarnessUsesLocalLibGit2HeadersOnlyInLocalArtifactMode() throws {
        let fixture = try LibGit2HeaderSearchPathFixture.make()
        defer { fixture.remove() }

        let resolvedPath = try AgentStudioCompatibilityHarnessSupport.libGit2HeaderSearchPath(
            packageRoot: fixture.packageRoot,
            debugBuildPath: fixture.debugBuildPath,
            environment: ["AGENTSTUDIO_GIT_USE_LOCAL_LIBGIT2_ARTIFACT": "1"]
        )

        #expect(resolvedPath.standardizedFileURL == fixture.localHeadersPath.standardizedFileURL)
    }
}

private struct LibGit2HeaderSearchPathFixture {
    let root: URL
    let packageRoot: URL
    let debugBuildPath: URL
    let hostedHeadersPath: URL
    let localHeadersPath: URL

    static func make() throws -> Self {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "agentstudio-git-header-search-\(UUID().uuidString)")
        let packageRoot = root.appending(path: "agentstudio-git")
        let debugBuildPath = packageRoot.appending(path: ".build/arm64-apple-macosx/debug")
        let hostedHeadersPath = packageRoot.appending(
            path: ".build/artifacts/agentstudio-git/CLibGit2Local/CLibGit2Local.xcframework/macos-arm64_x86_64/Headers")
        let localHeadersPath = packageRoot.appending(
            path: "Artifacts/CLibGit2Local.xcframework/macos-arm64_x86_64/Headers")
        let unrelatedHeadersPath = packageRoot.appending(
            path: ".build/artifacts/other/Other.xcframework/macos-arm64_x86_64/Headers")

        try writeLibGit2Headers(at: hostedHeadersPath)
        try writeLibGit2Headers(at: localHeadersPath)
        try writeUnrelatedHeaders(at: unrelatedHeadersPath)
        try FileManager.default.createDirectory(
            at: debugBuildPath,
            withIntermediateDirectories: true
        )

        return Self(
            root: root,
            packageRoot: packageRoot,
            debugBuildPath: debugBuildPath,
            hostedHeadersPath: hostedHeadersPath,
            localHeadersPath: localHeadersPath
        )
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }

    private static func writeLibGit2Headers(at headersPath: URL) throws {
        try FileManager.default.createDirectory(at: headersPath, withIntermediateDirectories: true)
        try "module CLibGit2Local { header \"git2.h\" }\n"
            .write(to: headersPath.appending(path: "module.modulemap"), atomically: true, encoding: .utf8)
        try "int git_libgit2_version(int *major, int *minor, int *rev);\n"
            .write(to: headersPath.appending(path: "git2.h"), atomically: true, encoding: .utf8)
    }

    private static func writeUnrelatedHeaders(at headersPath: URL) throws {
        try FileManager.default.createDirectory(at: headersPath, withIntermediateDirectories: true)
        try "module Other { header \"git2.h\" }\n"
            .write(to: headersPath.appending(path: "module.modulemap"), atomically: true, encoding: .utf8)
        try "int git_libgit2_version(int *major, int *minor, int *rev);\n"
            .write(to: headersPath.appending(path: "git2.h"), atomically: true, encoding: .utf8)
    }
}

private struct AgentStudioStatusAdapterCompileHarness {
    private let fileManager = FileManager.default

    func typecheck() throws {
        let packageRoot = AgentStudioCompatibilityHarnessSupport.agentStudioGitPackageRoot()
        guard let agentStudioRoot = AgentStudioCompatibilityHarnessSupport.agentStudioRoot() else {
            AgentStudioCompatibilityHarnessSupport.recordMissingAgentStudioSeam(
                "missing checked-out AgentStudio seam")
            return
        }
        let providerSource = agentStudioRoot.appending(
            path: "Sources/AgentStudio/Core/RuntimeEventSystem/Git/GitWorkingTreeStatusProvider.swift")
        let eventSource = agentStudioRoot.appending(
            path: "Sources/AgentStudio/Core/RuntimeEventSystem/Contracts/PaneRuntimeEvent.swift")
        guard fileManager.fileExists(atPath: providerSource.path),
            fileManager.fileExists(atPath: eventSource.path)
        else {
            AgentStudioCompatibilityHarnessSupport.recordMissingAgentStudioSeam(
                "missing checked-out AgentStudio seam at \(agentStudioRoot.path)")
            return
        }

        let scratchRoot = fileManager.temporaryDirectory
            .appending(path: "agentstudio-git-app-status-adapter-\(UUID().uuidString)")
        defer { try? fileManager.removeItem(at: scratchRoot) }
        try fileManager.createDirectory(at: scratchRoot, withIntermediateDirectories: true)
        let harnessFile = scratchRoot.appending(path: "AgentStudioStatusAdapterHarness.swift")
        try harnessSource(providerSource: providerSource, eventSource: eventSource)
            .write(to: harnessFile, atomically: true, encoding: .utf8)

        try runSwiftTypecheck(
            harnessFile: harnessFile,
            moduleSearchPath: moduleSearchPath(packageRoot: packageRoot),
            packageRoot: packageRoot
        )
    }

    private func harnessSource(providerSource: URL, eventSource: URL) throws -> String {
        let providerContents = try String(contentsOf: providerSource, encoding: .utf8)
        let eventContents = try String(contentsOf: eventSource, encoding: .utf8)
        let summaryDeclaration = try extractDeclaration(
            from: eventContents,
            start: "package struct GitWorkingTreeSummary",
            end: "package struct GitWorkingTreeSnapshot"
        )
        let statusProviderDeclarations = try extractDeclaration(
            from: providerContents,
            start: "package enum GitOriginResolution",
            end: nil
        )

        return """
            import AgentStudioGit
            import AgentStudioGitContracts
            import Foundation

            \(summaryDeclaration)

            \(statusProviderDeclarations)

            typealias AppGitOrigin = GitOriginResolution

            struct AgentStudioGitStatusAdapter<LocalClient: AgentStudioGitLocalClient>:
                GitWorkingTreeStatusProvider
            {
                let client: LocalClient

                func statusResult(for rootPath: URL, pathspecs: [String]?) async -> GitWorkingTreeStatusResult {
                    do {
                        let snapshot = try await client.status(
                            for: rootPath,
                            options: GitStatusOptions(pathspecs: pathspecs)
                        )
                        return .available(
                            GitWorkingTreeStatus(
                                summary: GitWorkingTreeSummary(
                                    changed: snapshot.summary.unstagedFileCount,
                                    staged: snapshot.summary.stagedFileCount,
                                    untracked: snapshot.summary.untrackedFileCount,
                                    linesAdded: snapshot.summary.linesAdded,
                                    linesDeleted: snapshot.summary.linesDeleted,
                                    aheadCount: appAheadCount(snapshot),
                                    behindCount: appBehindCount(snapshot),
                                    hasUpstream: appHasUpstream(snapshot)
                                ),
                                branch: snapshot.head.kind == .branch ? snapshot.head.shortName : nil,
                                originResolution: appOriginResolution(snapshot.originResolution),
                                entries: snapshot.entries.map(appEntry)
                            ),
                        )
                    } catch {
                        return .unavailable(GitWorkingTreeStatusUnavailable(reason: .sdkError))
                    }
                }

                private func appEntry(_ entry: GitStatusEntry) -> GitWorkingTreeStatusEntry {
                    GitWorkingTreeStatusEntry(
                        path: entry.path,
                        previousPath: entry.previousPath,
                        hasStagedChange: entry.indexState != nil,
                        hasUnstagedChange: entry.worktreeState != nil,
                        isUntracked: entry.untracked,
                        isRename: entry.indexState == .renamed || entry.worktreeState == .renamed
                    )
                }

                private func appAheadCount(_ snapshot: GitStatusSnapshot) -> Int? {
                    snapshot.summary.hasUpstream ? snapshot.summary.aheadCount : nil
                }

                private func appBehindCount(_ snapshot: GitStatusSnapshot) -> Int? {
                    snapshot.summary.hasUpstream ? snapshot.summary.behindCount : nil
                }

                private func appHasUpstream(_ snapshot: GitStatusSnapshot) -> Bool? {
                    snapshot.head.kind == .branch ? snapshot.summary.hasUpstream : nil
                }

                private func appOriginResolution(
                    _ resolution: AgentStudioGitContracts.GitOriginResolution
                ) -> AppGitOrigin {
                    switch resolution {
                    case .awaitingResolution:
                        return .awaitingResolution
                    case .confirmedAbsent:
                        return .confirmedAbsent
                    case .resolved(let remote):
                        return .resolved(remote.rawURL)
                    }
                }
            }
            """
    }

    private func extractDeclaration(from source: String, start: String, end: String?) throws -> String {
        guard let startRange = source.range(of: start) else {
            throw AgentStudioCompatibilityHarnessError.missingMarker(start)
        }
        let endIndex: String.Index
        if let end {
            guard let endRange = source[startRange.lowerBound...].range(of: end) else {
                throw AgentStudioCompatibilityHarnessError.missingMarker(end)
            }
            endIndex = endRange.lowerBound
        } else {
            endIndex = source.endIndex
        }
        return String(source[startRange.lowerBound..<endIndex]).trimmingCharacters(
            in: .whitespacesAndNewlines)
    }

    private func moduleSearchPath(packageRoot: URL) throws -> URL {
        try AgentStudioCompatibilityHarnessSupport.moduleSearchPath(
            packageRoot: packageRoot,
            requiredModules: ["AgentStudioGit", "AgentStudioGitContracts"]
        )
    }

    private func runSwiftTypecheck(harnessFile: URL, moduleSearchPath: URL, packageRoot: URL) throws {
        let debugBuildPath = moduleSearchPath.deletingLastPathComponent()
        let cHeaderSearchPath = try AgentStudioCompatibilityHarnessSupport.libGit2HeaderSearchPath(
            packageRoot: packageRoot,
            debugBuildPath: debugBuildPath
        )
        let moduleCachePath = debugBuildPath.appending(path: "ModuleCache")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [
            "swiftc",
            "-typecheck",
            "-parse-as-library",
            "-package-name",
            "AgentStudio",
            "-I",
            moduleSearchPath.path,
            "-I",
            cHeaderSearchPath.path,
            "-Xcc",
            "-I",
            "-Xcc",
            cHeaderSearchPath.path,
            "-F",
            debugBuildPath.path,
            "-module-cache-path",
            moduleCachePath.path,
            harnessFile.path,
        ]
        process.environment = ProcessInfo.processInfo.environment.merging(
            ["LC_ALL": "C"]
        ) { _, testValue in testValue }
        let output = Pipe()
        let error = Pipe()
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = error
        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let stdout = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            let stderr = String(data: error.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            Issue.record(
                """
                AgentStudio status adapter typecheck failed with exit \(process.terminationStatus)
                stdout:
                \(stdout)
                stderr:
                \(stderr)
                """
            )
            throw AgentStudioCompatibilityHarnessError.typecheckFailed(process.terminationStatus)
        }
    }
}

private struct AppStatusCompatibilityProvider<LocalClient: AgentStudioGitLocalClient>: Sendable {
    let client: LocalClient

    func status(for rootPath: URL) async -> AppGitWorkingTreeStatus? {
        do {
            let snapshot = try await client.status(for: rootPath, options: GitStatusOptions())
            return AppGitWorkingTreeStatus(snapshot: snapshot)
        } catch {
            return nil
        }
    }
}

private struct AppGitWorkingTreeStatus: Sendable, Equatable {
    let summary: AppGitWorkingTreeSummary
    let branch: String?
    let originResolution: AppGitOriginResolution

    init(snapshot: GitStatusSnapshot) {
        self.summary = AppGitWorkingTreeSummary(summary: snapshot.summary, headKind: snapshot.head.kind)
        self.branch = snapshot.head.kind == .branch ? snapshot.head.shortName : nil
        self.originResolution = AppGitOriginResolution(snapshot: snapshot.originResolution)
    }
}

private struct AppGitWorkingTreeSummary: Sendable, Equatable {
    let changed: Int
    let staged: Int
    let untracked: Int
    let linesAdded: Int
    let linesDeleted: Int
    let aheadCount: Int?
    let behindCount: Int?
    let hasUpstream: Bool?

    init(summary: GitStatusSummary, headKind: GitHeadKind) {
        self.changed = summary.unstagedFileCount
        self.staged = summary.stagedFileCount
        self.untracked = summary.untrackedFileCount
        self.linesAdded = summary.linesAdded
        self.linesDeleted = summary.linesDeleted
        self.aheadCount = summary.hasUpstream ? summary.aheadCount : nil
        self.behindCount = summary.hasUpstream ? summary.behindCount : nil
        self.hasUpstream = headKind == .branch ? summary.hasUpstream : nil
    }
}

private enum AppGitOriginResolution: Sendable, Equatable {
    case awaitingResolution
    case confirmedAbsent
    case resolved(String)

    init(snapshot: GitOriginResolution) {
        switch snapshot {
        case .awaitingResolution:
            self = .awaitingResolution
        case .confirmedAbsent:
            self = .confirmedAbsent
        case .resolved(let remote):
            self = .resolved(remote.rawURL)
        }
    }
}

private struct StubLocalClient: AgentStudioGitLocalClient {
    let snapshot: GitStatusSnapshot

    func repositoryIdentity(for _: URL) async throws(GitDataPlaneError) -> GitRepositoryIdentity {
        throw .unsupported(message: "not needed")
    }

    func worktrees(for _: URL) async throws(GitDataPlaneError) -> [GitWorktreeSnapshot] {
        throw .unsupported(message: "not needed")
    }

    func validateWorktree(_: GitValidateWorktreeRequest) async throws(GitDataPlaneError) -> GitWorktreeValidation {
        throw .unsupported(message: "not needed")
    }

    func createWorktree(_: GitCreateWorktreeRequest) async throws(GitDataPlaneError) -> GitWorktreeSnapshot {
        throw .unsupported(message: "not needed")
    }

    func pruneStaleWorktree(_: GitPruneStaleWorktreeRequest) async throws(GitDataPlaneError)
        -> GitWorktreePruneResult
    {
        throw .unsupported(message: "not needed")
    }

    func removeWorktree(_: GitRemoveWorktreeRequest) async throws(GitDataPlaneError) -> GitWorktreeRemovalResult {
        throw .unsupported(message: "not needed")
    }

    func lockWorktree(_: GitLockWorktreeRequest) async throws(GitDataPlaneError) -> GitWorktreeSnapshot {
        throw .unsupported(message: "not needed")
    }

    func unlockWorktree(_: GitUnlockWorktreeRequest) async throws(GitDataPlaneError) -> GitWorktreeSnapshot {
        throw .unsupported(message: "not needed")
    }

    func status(for _: URL, options _: GitStatusOptions) async throws(GitDataPlaneError) -> GitStatusSnapshot {
        snapshot
    }

    func trackedPaths(for _: URL, options _: GitTrackedPathsOptions) async throws(GitDataPlaneError)
        -> GitTrackedPathsSnapshot
    {
        throw .unsupported(message: "not needed")
    }

    func isPathIgnored(repositoryAt _: URL, relativePath _: String) async throws(GitDataPlaneError) -> Bool {
        throw .unsupported(message: "not needed")
    }

    func ignoredPaths(repositoryAt _: URL, relativePaths _: [String]) async throws(GitDataPlaneError)
        -> [GitIgnoreCheck]
    {
        throw .unsupported(message: "not needed")
    }

    func branches(for _: URL) async throws(GitDataPlaneError) -> [GitBranchSnapshot] {
        throw .unsupported(message: "not needed")
    }

    func localDefaultBranch(for _: URL) async throws(GitDataPlaneError) -> GitLocalDefaultBranch? {
        throw .unsupported(message: "not needed")
    }

    func resolveRevision(_: GitRevisionResolutionRequest) async throws(GitDataPlaneError) -> GitResolvedRevision {
        throw .unsupported(message: "not needed")
    }

    func readTree(_: GitTreeReadRequest) async throws(GitDataPlaneError) -> GitTreeSnapshot {
        throw .unsupported(message: "not needed")
    }

    func diff(_: GitDiffRequest) async throws(GitDataPlaneError) -> GitDiffSnapshot {
        throw .unsupported(message: "not needed")
    }

    func contributionDiff(_: GitContributionDiffRequest) async throws(GitDataPlaneError)
        -> GitContributionDiffSnapshot
    {
        throw .unsupported(message: "not needed")
    }

    func content(_: GitContentRequest) async throws(GitDataPlaneError) -> GitContentPayload {
        throw .unsupported(message: "not needed")
    }
}

private enum AgentStudioCompatibilityHarnessError: Error {
    case missingMarker(String)
    case typecheckFailed(Int32)
}
