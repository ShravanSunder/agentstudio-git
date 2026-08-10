import Foundation
import Testing

@Suite("Bridge review source compatibility")
struct BridgeReviewSourceCompatibilityTests {
    @Test("Bridge review adapter harness typechecks against the checked out AgentStudio seam")
    func bridgeReviewAdapterHarnessTypechecksAgainstCheckedOutAgentStudioSeam() throws {
        try BridgeReviewSourceAdapterCompileHarness().typecheck()
    }

    @Test("Bridge review adapter executes handle-only git-ref content loading")
    func bridgeReviewAdapterExecutesHandleOnlyGitRefContentLoading() throws {
        try BridgeReviewSourceAdapterCompileHarness().runContentLoadingExecutable()
    }
}

private struct BridgeReviewSourceAdapterCompileHarness {
    private let fileManager = FileManager.default

    func typecheck() throws {
        let packageRoot = AgentStudioCompatibilityHarnessSupport.agentStudioGitPackageRoot()
        guard let agentStudioRoot = AgentStudioCompatibilityHarnessSupport.agentStudioRoot() else {
            AgentStudioCompatibilityHarnessSupport.recordMissingAgentStudioSeam(
                "missing checked-out AgentStudio Bridge seam")
            return
        }
        let requiredSources = appSources(agentStudioRoot: agentStudioRoot)
        guard requiredSources.allSatisfy({ fileManager.fileExists(atPath: $0.path) }) else {
            AgentStudioCompatibilityHarnessSupport.recordMissingAgentStudioSeam(
                "missing checked-out AgentStudio Bridge seam at \(agentStudioRoot.path)")
            return
        }

        let scratchRoot = fileManager.temporaryDirectory
            .appending(path: "agentstudio-git-bridge-adapter-\(UUID().uuidString)")
        defer { try? fileManager.removeItem(at: scratchRoot) }
        try fileManager.createDirectory(at: scratchRoot, withIntermediateDirectories: true)
        let harnessFile = scratchRoot.appending(path: "BridgeReviewSourceAdapterHarness.swift")
        try harnessSource(appSources: requiredSources)
            .write(to: harnessFile, atomically: true, encoding: .utf8)

        try runSwiftTypecheck(
            harnessFile: harnessFile,
            moduleSearchPath: moduleSearchPath(packageRoot: packageRoot),
            packageRoot: packageRoot
        )
    }

    private func appSources(agentStudioRoot: URL) -> [URL] {
        let modelRoot = agentStudioRoot.appending(path: "Sources/AgentStudio/Features/Bridge/Models/ReviewFoundation")
        let runtimeRoot = agentStudioRoot.appending(
            path: "Sources/AgentStudio/Features/Bridge/Runtime/ReviewFoundation")
        let constructionRoot = agentStudioRoot.appending(
            path: "Sources/AgentStudio/Features/Bridge/Runtime/Construction")
        return [
            "BridgeReviewGeneration.swift",
            "BridgeFileClass.swift",
            "BridgeViewFilter.swift",
            "BridgeChangeGrouping.swift",
            "BridgeProvenanceFilter.swift",
            "BridgeReviewQuery.swift",
            "BridgeSourceEndpoint.swift",
            "BridgeEndpointResolutionRequest.swift",
            "BridgeEndpointComparisonRequest.swift",
            "BridgeEndpointComparison.swift",
            "BridgeTreeReadRequest.swift",
            "BridgeReviewItemDescriptorRequest.swift",
            "BridgeContentHandle.swift",
            "BridgeContentLoadRequest.swift",
            "BridgeContentLoadResult.swift",
            "BridgeCheckpointEndpointRequest.swift",
            "BridgeReviewItemDescriptor.swift",
            "BridgeProviderFailure.swift",
        ].map { modelRoot.appending(path: $0) } + [
            runtimeRoot.appending(path: "BridgeReviewSourceProvider.swift"),
            runtimeRoot.appending(path: "BridgeGitReviewSourceProvider.swift"),
            runtimeRoot.appending(path: "BridgeContentLoadObservation.swift"),
            constructionRoot.appending(path: "BridgeSharedReviewContentBacking.swift"),
        ]
    }

    // Generated compile-spike source intentionally lives in one literal so diagnostics match the scratch file.
    // swiftlint:disable:next function_body_length
    private func harnessSource(appSources: [URL], includeRuntimeMain: Bool = false) throws -> String {
        let appDeclarations =
            try appSources
            .map { try sourceWithoutImports($0) }
            .joined(separator: "\n\n")
        return """
            import AgentStudioGitContracts
            import CryptoKit
            import Foundation

            enum AppPolicies {
                enum Bridge {
                    static let contentCacheMaxBytes = 1_048_576
                    static let contentMaxBytesPerItem = 1_048_576
                }
            }

            struct BridgeGitReadFreshnessKey: Hashable, Sendable {
                let token: String

                static let unversioned = Self(token: "unversioned")
            }

            \(appDeclarations)

            actor AgentStudioGitBridgeReviewAdapter<LocalClient: AgentStudioGitLocalClient>:
                BridgeGitReviewDataClient
            {
                struct ContentLocator: Sendable {
                    let target: GitDiffTarget
                    let path: String
                    let reviewGeneration: BridgeReviewGeneration
                }

                let repositoryPath: URL
                let client: LocalClient
                var locatorByHandleId: [String: ContentLocator] = [:]

                init(repositoryPath: URL, client: LocalClient) {
                    self.repositoryPath = repositoryPath
                    self.client = client
                }

                func resolveEndpoint(_ request: BridgeEndpointResolutionRequest) async throws
                    -> BridgeSourceEndpoint
                {
                    request.endpoint
                }

                func compareEndpoints(_ request: BridgeEndpointComparisonRequest) async throws
                    -> BridgeEndpointComparison
                {
                    let diff = try await client.diff(
                        GitDiffRequest(
                            repositoryPath: repositoryPath,
                            base: try gitTarget(for: request.baseEndpoint),
                            compare: try gitTarget(for: request.headEndpoint)
                        )
                    )
                    let changedFiles = try await diff.files.asyncMap { file in
                        try await bridgeChangedFile(
                            file,
                            baseEndpoint: request.baseEndpoint,
                            headEndpoint: request.headEndpoint
                        )
                    }
                    return BridgeEndpointComparison(
                        baseEndpoint: request.baseEndpoint,
                        headEndpoint: request.headEndpoint,
                        changedFiles: changedFiles
                    )
                }

                func readTree(_ request: BridgeTreeReadRequest) async throws -> BridgeTreeReadResult {
                    let tree = try await client.readTree(
                        GitTreeReadRequest(
                            repositoryPath: repositoryPath,
                            revision: GitRevisionTarget.named(request.endpoint.providerIdentity),
                            path: request.pathScope.first
                        )
                    )
                    let descriptors = tree.entries.map { entry in
                        descriptor(
                            path: entry.path,
                            endpoint: request.endpoint,
                            reviewGeneration: request.reviewGeneration,
                            sizeBytes: Int(entry.sizeBytes ?? 0),
                            isBinary: false
                        )
                    }
                    return BridgeTreeReadResult(endpoint: request.endpoint, descriptors: descriptors)
                }

                func readReviewItemDescriptor(_ request: BridgeReviewItemDescriptorRequest) async throws
                    -> BridgeReviewItemDescriptor
                {
                    let target = try gitTarget(for: request.endpoint)
                    let payload = try await client.content(
                        GitContentRequest(
                            repositoryPath: repositoryPath,
                            target: target,
                            path: request.path
                        )
                    )
                    let descriptor = descriptor(
                        path: request.path,
                        endpoint: request.endpoint,
                        reviewGeneration: request.reviewGeneration,
                        sizeBytes: payload.data.count,
                        isBinary: payload.isBinary,
                        contentHash: payload.contentHash,
                        contentHashAlgorithm: payload.contentHashAlgorithm
                    )
                    if let handle = descriptor.contentRoles.file {
                        locatorByHandleId[handle.handleId] = ContentLocator(
                            target: target,
                            path: request.path,
                            reviewGeneration: request.reviewGeneration
                        )
                    }
                    return descriptor
                }

                func resolveCheckpointEndpoint(_ request: BridgeCheckpointEndpointRequest) async throws
                    -> BridgeSourceEndpoint
                {
                    throw BridgeProviderFailure.providerFailed(
                        message: "checkpoint composition remains AgentStudio-owned: \\(request.checkpointId)"
                    )
                }

                func loadContent(_ request: BridgeContentLoadRequest) async throws -> BridgeContentLoadResult {
                    guard let locator = locatorByHandleId[request.handle.handleId] else {
                        throw BridgeProviderFailure.missingContent(handleId: request.handle.handleId)
                    }
                    guard locator.reviewGeneration == request.requestedGeneration,
                        request.handle.reviewGeneration == request.requestedGeneration
                    else {
                        throw BridgeProviderFailure.staleReviewGeneration(
                            storedGeneration: locator.reviewGeneration,
                            requestedGeneration: request.requestedGeneration
                        )
                    }
                    let payload = try await client.content(
                        GitContentRequest(
                            repositoryPath: repositoryPath,
                            target: locator.target,
                            path: locator.path
                        )
                    )
                    return BridgeContentLoadResult(
                        handle: request.handle,
                        data: payload.data,
                        mimeType: request.handle.mimeType,
                        contentHash: payload.contentHash,
                        contentHashAlgorithm: payload.contentHashAlgorithm
                    )
                }

                private func bridgeChangedFile(
                    _ file: GitDiffFile,
                    baseEndpoint: BridgeSourceEndpoint,
                    headEndpoint: BridgeSourceEndpoint
                ) async throws -> BridgeEndpointChangedFile {
                    let preferredEndpoint = file.changeKind == .deleted ? baseEndpoint : headEndpoint
                    let preferredPath = file.changeKind == .deleted ? (file.previousPath ?? file.path) : file.path
                    let payload = try await client.content(
                        GitContentRequest(
                            repositoryPath: repositoryPath,
                            target: try gitTarget(for: preferredEndpoint),
                            path: preferredPath
                        )
                    )
                    return BridgeEndpointChangedFile(
                        fileId: file.fileId,
                        path: file.path,
                        oldPath: file.previousPath,
                        changeKind: bridgeChangeKind(file.changeKind),
                        language: nil,
                        fileExtension: URL(fileURLWithPath: file.path).pathExtension.nonEmpty,
                        sizeBytes: Int(file.sizeBytes ?? Int64(payload.data.count)),
                        oldContentHash: file.changeKind == .added ? nil : file.oldContentHash,
                        newContentHash: file.changeKind == .deleted ? nil : file.newContentHash,
                        contentHashAlgorithm: file.contentHashAlgorithm,
                        additions: file.additions,
                        deletions: file.deletions,
                        isBinary: payload.isBinary,
                        mimeType: payload.isBinary ? "application/octet-stream" : "text/plain"
                    )
                }

                private func descriptor(
                    path: String,
                    endpoint: BridgeSourceEndpoint,
                    reviewGeneration: BridgeReviewGeneration,
                    sizeBytes: Int,
                    isBinary: Bool,
                    contentHash: String = "sha256:unknown",
                    contentHashAlgorithm: String = "sha256"
                ) -> BridgeReviewItemDescriptor {
                    let itemId = "item-\\(path)"
                    let handle = BridgeContentHandle(
                        handleId: "handle-\\(endpoint.endpointId)-\\(itemId)",
                        itemId: itemId,
                        role: .file,
                        endpointId: endpoint.endpointId,
                        reviewGeneration: reviewGeneration,
                        contentHash: contentHash,
                        contentHashAlgorithm: contentHashAlgorithm,
                        cacheKey: "\\(endpoint.endpointId):\\(itemId):\\(contentHash)",
                        mimeType: isBinary ? "application/octet-stream" : "text/plain",
                        language: nil,
                        sizeBytes: sizeBytes,
                        isBinary: isBinary
                    )
                    return BridgeReviewItemDescriptor(
                        itemId: itemId,
                        itemKind: .file,
                        itemVersion: reviewGeneration.rawValue,
                        basePath: nil,
                        headPath: path,
                        changeKind: .modified,
                        fileClass: isBinary ? .binary : .unknown,
                        language: nil,
                        extension: URL(fileURLWithPath: path).pathExtension.nonEmpty,
                        sizeBytes: sizeBytes,
                        baseContentHash: nil,
                        headContentHash: contentHash,
                        contentHashAlgorithm: contentHashAlgorithm,
                        additions: 0,
                        deletions: 0,
                        isHiddenByDefault: isBinary,
                        hiddenReason: isBinary ? BridgeFileClass.binary.rawValue : nil,
                        reviewPriority: .normal,
                        contentRoles: BridgeReviewItemDescriptor.ContentRoles(file: handle),
                        cacheKey: handle.cacheKey,
                        provenance: BridgeProvenanceSummary(),
                        annotationSummary: BridgeAnnotationSummary(
                            threadCount: 0,
                            unresolvedThreadCount: 0,
                            commentCount: 0
                        ),
                        reviewState: .unreviewed,
                        collapsed: isBinary
                    )
                }

                private func gitTarget(for endpoint: BridgeSourceEndpoint) throws -> GitDiffTarget {
                    switch endpoint.kind {
                    case .gitRef:
                        return .commit(endpoint.providerIdentity)
                    case .index:
                        return .index
                    case .workingTree:
                        return .workingTree
                    case .promptCheckpoint, .sessionCheckpoint, .manualCheckpoint, .savedTimeWindowCheckpoint:
                        throw BridgeProviderFailure.providerFailed(
                            message: "checkpoint endpoint resolution remains AgentStudio-owned"
                        )
                    }
                }

                private func bridgeChangeKind(_ kind: GitDiffChangeKind) -> BridgeFileChangeKind {
                    switch kind {
                    case .added:
                        return .added
                    case .copied:
                        return .copied
                    case .deleted:
                        return .deleted
                    case .renamed:
                        return .renamed
                    case .modified, .typeChanged, .unmerged:
                        return .modified
                    }
                }
            }

            \(includeRuntimeMain ? runtimeHarnessSource() : "")

            extension Array {
                fileprivate func asyncMap<Transformed>(
                    _ transform: (Element) async throws -> Transformed
                ) async throws -> [Transformed] {
                    var values: [Transformed] = []
                    values.reserveCapacity(count)
                    for element in self {
                        try await values.append(transform(element))
                    }
                    return values
                }
            }

            extension String {
                fileprivate var nonEmpty: String? {
                    isEmpty ? nil : self
                }
            }
            """
    }

    func runContentLoadingExecutable() throws {
        let packageRoot = AgentStudioCompatibilityHarnessSupport.agentStudioGitPackageRoot()
        guard let agentStudioRoot = AgentStudioCompatibilityHarnessSupport.agentStudioRoot() else {
            AgentStudioCompatibilityHarnessSupport.recordMissingAgentStudioSeam(
                "missing checked-out AgentStudio Bridge seam")
            return
        }
        let requiredSources = appSources(agentStudioRoot: agentStudioRoot)
        guard requiredSources.allSatisfy({ fileManager.fileExists(atPath: $0.path) }) else {
            AgentStudioCompatibilityHarnessSupport.recordMissingAgentStudioSeam(
                "missing checked-out AgentStudio Bridge seam at \(agentStudioRoot.path)")
            return
        }

        let scratchRoot = fileManager.temporaryDirectory
            .appending(path: "agentstudio-git-bridge-runtime-\(UUID().uuidString)")
        defer { try? fileManager.removeItem(at: scratchRoot) }
        try fileManager.createDirectory(at: scratchRoot, withIntermediateDirectories: true)
        let harnessFile = scratchRoot.appending(path: "BridgeReviewSourceAdapterRuntime.swift")
        let executableFile = scratchRoot.appending(path: "BridgeReviewSourceAdapterRuntime")
        try harnessSource(appSources: requiredSources, includeRuntimeMain: true)
            .write(to: harnessFile, atomically: true, encoding: .utf8)

        try runSwiftExecutable(
            harnessFile: harnessFile,
            executableFile: executableFile,
            moduleSearchPath: moduleSearchPath(packageRoot: packageRoot)
        )
    }

    // swiftlint:disable:next function_body_length
    private func runtimeHarnessSource() -> String {
        """
        actor RecordingLocalClient: AgentStudioGitLocalClient {
            private var contentRequests: [GitContentRequest] = []
            private var diffRequests: [GitDiffRequest] = []
            private var treeRequests: [GitTreeReadRequest] = []

            func recordedContentRequests() -> [GitContentRequest] {
                contentRequests
            }

            func recordedDiffRequests() -> [GitDiffRequest] {
                diffRequests
            }

            func recordedTreeRequests() -> [GitTreeReadRequest] {
                treeRequests
            }

            func content(_ request: GitContentRequest) async throws(GitDataPlaneError) -> GitContentPayload {
                contentRequests.append(request)
                let data = Data("\\(request.target.kind.rawValue):\\(request.target.identifier ?? "nil"):\\(request.path)".utf8)
                return GitContentPayload(
                    data: data,
                    contentHash: sha256ContentHash(data),
                    contentHashAlgorithm: "sha256",
                    isBinary: false
                )
            }

            func repositoryIdentity(for worktreePath: URL) async throws(GitDataPlaneError)
                -> GitRepositoryIdentity
            {
                throw .unsupported(message: "unused")
            }

            func worktrees(for repositoryPath: URL) async throws(GitDataPlaneError) -> [GitWorktreeSnapshot] {
                throw .unsupported(message: "unused")
            }

            func validateWorktree(_ request: GitValidateWorktreeRequest) async throws(GitDataPlaneError)
                -> GitWorktreeValidation
            {
                throw .unsupported(message: "unused")
            }

            func createWorktree(_ request: GitCreateWorktreeRequest) async throws(GitDataPlaneError)
                -> GitWorktreeSnapshot
            {
                throw .unsupported(message: "unused")
            }

            func pruneStaleWorktree(_ request: GitPruneStaleWorktreeRequest) async throws(GitDataPlaneError)
                -> GitWorktreePruneResult
            {
                throw .unsupported(message: "unused")
            }

            func removeWorktree(_ request: GitRemoveWorktreeRequest) async throws(GitDataPlaneError)
                -> GitWorktreeRemovalResult
            {
                throw .unsupported(message: "unused")
            }

            func lockWorktree(_ request: GitLockWorktreeRequest) async throws(GitDataPlaneError)
                -> GitWorktreeSnapshot
            {
                throw .unsupported(message: "unused")
            }

            func unlockWorktree(_ request: GitUnlockWorktreeRequest) async throws(GitDataPlaneError)
                -> GitWorktreeSnapshot
            {
                throw .unsupported(message: "unused")
            }

            func status(for worktreePath: URL, options: GitStatusOptions) async throws(GitDataPlaneError)
                -> GitStatusSnapshot
            {
                throw .unsupported(message: "unused")
            }

            func trackedPaths(for worktreePath: URL, options: GitTrackedPathsOptions) async throws(GitDataPlaneError)
                -> GitTrackedPathsSnapshot
            {
                throw .unsupported(message: "unused")
            }

            func isPathIgnored(repositoryAt worktreePath: URL, relativePath: String) async throws(GitDataPlaneError) -> Bool { throw .unsupported(message: "unused") }
            func ignoredPaths(repositoryAt worktreePath: URL, relativePaths: [String]) async throws(GitDataPlaneError) -> [GitIgnoreCheck] { throw .unsupported(message: "unused") }

            func branches(for repositoryPath: URL) async throws(GitDataPlaneError) -> [GitBranchSnapshot] {
                throw .unsupported(message: "unused")
            }

            func localDefaultBranch(for repositoryPath: URL) async throws(GitDataPlaneError)
                -> GitLocalDefaultBranch?
            {
                throw .unsupported(message: "unused")
            }

            func resolveRevision(_ request: GitRevisionResolutionRequest) async throws(GitDataPlaneError)
                -> GitResolvedRevision
            {
                throw .unsupported(message: "unused")
            }

            func readTree(_ request: GitTreeReadRequest) async throws(GitDataPlaneError) -> GitTreeSnapshot {
                treeRequests.append(request)
                return GitTreeSnapshot(
                    revision: GitResolvedRevision(oid: request.revision.name, shortName: nil),
                    entries: [
                        GitTreeEntry(
                            path: "Sources/App.swift",
                            oid: "tree-entry-oid",
                            mode: 0o100644,
                            isTree: false,
                            sizeBytes: 128
                        )
                    ]
                )
            }

            func diff(_ request: GitDiffRequest) async throws(GitDataPlaneError) -> GitDiffSnapshot {
                diffRequests.append(request)
                return GitDiffSnapshot(
                    files: [
                        GitDiffFile(
                            fileId: "file-Sources/App.swift",
                            path: "Sources/App.swift",
                            previousPath: nil,
                            changeKind: .modified,
                            oldContentHash: "sha256:old",
                            newContentHash: "sha256:new",
                            contentHashAlgorithm: "sha256",
                            oldMode: 0o100644,
                            newMode: 0o100644,
                            additions: 1,
                            deletions: 1,
                            isBinary: false,
                            sizeBytes: 128
                        )
                    ]
                )
            }

            func contributionDiff(_ request: GitContributionDiffRequest) async throws(GitDataPlaneError)
                -> GitContributionDiffSnapshot
            {
                throw .unsupported(message: "unused")
            }

            func directReviewComparison(_ request: GitDirectReviewComparisonRequest) async throws(GitDataPlaneError)
                -> GitDirectReviewComparisonSnapshot
            {
                throw .unsupported(message: "unused")
            }
        }

        enum HarnessFailure: Error {
            case failed(String)
        }

        func sha256ContentHash(_ data: Data) -> String {
            let digest = SHA256.hash(data: data)
            return "sha256:\\(digest.map { String(format: "%02x", $0) }.joined())"
        }

        @main
        enum BridgeReviewAdapterRuntimeHarness {
            static func main() async throws {
                let client = RecordingLocalClient()
                let adapter = AgentStudioGitBridgeReviewAdapter(
                    repositoryPath: URL(fileURLWithPath: "/tmp/repo"),
                    client: client
                )
                let provider = BridgeGitReviewSourceProvider(client: adapter)
                let endpoint = BridgeSourceEndpoint(
                    endpointId: "base",
                    kind: .gitRef,
                    repoId: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
                    worktreeId: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
                    label: "base",
                    createdAtUnixMilliseconds: 0,
                    contentSetHash: nil,
                    providerIdentity: "abc123"
                )
                let headEndpoint = BridgeSourceEndpoint(
                    endpointId: "head",
                    kind: .gitRef,
                    repoId: endpoint.repoId,
                    worktreeId: endpoint.worktreeId,
                    label: "head",
                    createdAtUnixMilliseconds: 0,
                    contentSetHash: nil,
                    providerIdentity: "def456"
                )
                let query = BridgeReviewQuery(
                    queryId: "query-1",
                    queryKind: .compare,
                    repoId: endpoint.repoId,
                    worktreeId: endpoint.worktreeId,
                    baseEndpointId: endpoint.endpointId,
                    headEndpointId: headEndpoint.endpointId,
                    comparisonSemantics: .twoDot,
                    pathScope: ["Sources"],
                    fileTarget: nil,
                    viewFilter: BridgeViewFilter(),
                    grouping: BridgeChangeGrouping(),
                    provenanceFilter: BridgeProvenanceFilter()
                )
                let comparison = try await adapter.compareEndpoints(
                    BridgeEndpointComparisonRequest(
                        query: query,
                        baseEndpoint: endpoint,
                        headEndpoint: headEndpoint,
                        reviewGeneration: 7
                    )
                )
                guard comparison.changedFiles.map(\\.path) == ["Sources/App.swift"] else {
                    throw HarnessFailure.failed("compare did not return synthetic diff file")
                }
                guard comparison.changedFiles.map(\\.oldContentHash) == ["sha256:old"],
                    comparison.changedFiles.map(\\.newContentHash) == ["sha256:new"]
                else {
                    throw HarnessFailure.failed("compare did not preserve old/new diff content hashes")
                }
                let tree = try await adapter.readTree(
                    BridgeTreeReadRequest(
                        endpoint: headEndpoint,
                        pathScope: ["Sources"],
                        reviewGeneration: 7
                    )
                )
                guard tree.descriptors.map(\\.headPath) == ["Sources/App.swift"] else {
                    throw HarnessFailure.failed("tree read did not return synthetic descriptor")
                }
                let descriptor = try await adapter.readReviewItemDescriptor(
                    BridgeReviewItemDescriptorRequest(
                        endpoint: endpoint,
                        path: "Sources/App.swift",
                        reviewGeneration: 7
                    )
                )
                guard let handle = descriptor.contentRoles.file else {
                    throw HarnessFailure.failed("descriptor did not build a file handle")
                }

                let result = try await provider.loadContent(
                    BridgeContentLoadRequest(handle: handle, requestedGeneration: 7)
                )
                let text = String(data: result.data, encoding: .utf8)
                guard text == "commit:abc123:Sources/App.swift" else {
                    throw HarnessFailure.failed("loaded wrong content: \\(text ?? "nil")")
                }
                let requests = await client.recordedContentRequests()
                guard requests.map(\\.target) == [.commit("def456"), .commit("abc123"), .commit("abc123")] else {
                    throw HarnessFailure.failed("content requests did not preserve git-ref identity")
                }
                let diffRequests = await client.recordedDiffRequests()
                guard diffRequests.map(\\.base) == [.commit("abc123")],
                    diffRequests.map(\\.compare) == [.commit("def456")]
                else {
                    throw HarnessFailure.failed("compare did not call client.diff with endpoint identities")
                }
                let treeRequests = await client.recordedTreeRequests()
                guard treeRequests.map(\\.revision) == [.named("def456")],
                    treeRequests.map(\\.path) == ["Sources"]
                else {
                    throw HarnessFailure.failed("readTree did not call client.readTree with endpoint identity")
                }
            }
        }
        """
    }

    private func sourceWithoutImports(_ source: URL) throws -> String {
        try String(contentsOf: source, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("import ") }
            .joined(separator: "\n")
    }

    private func moduleSearchPath(packageRoot: URL) throws -> URL {
        try AgentStudioCompatibilityHarnessSupport.moduleSearchPath(
            packageRoot: packageRoot,
            requiredModules: ["AgentStudioGit", "AgentStudioGitContracts"]
        )
    }

    private func runSwiftTypecheck(harnessFile: URL, moduleSearchPath: URL, packageRoot: URL) throws {
        let debugBuildPath = moduleSearchPath.deletingLastPathComponent()
        let moduleCachePath = debugBuildPath.appending(path: "ModuleCache")
        let result = try runCapturedProcess(arguments: [
            "swiftc",
            "-typecheck",
            "-parse-as-library",
            "-package-name",
            "AgentStudio",
            "-I",
            moduleSearchPath.path,
            "-module-cache-path",
            moduleCachePath.path,
            harnessFile.path,
        ])

        guard result.terminationStatus == 0 else {
            Issue.record(
                """
                Bridge review adapter typecheck failed with exit \(result.terminationStatus)
                stdout:
                \(result.stdout)
                stderr:
                \(result.stderr)
                """
            )
            throw BridgeReviewCompatibilityHarnessError.typecheckFailed(result.terminationStatus)
        }
    }

    private func runSwiftExecutable(
        harnessFile: URL,
        executableFile: URL,
        moduleSearchPath: URL
    ) throws {
        let debugBuildPath = moduleSearchPath.deletingLastPathComponent()
        let moduleCachePath = debugBuildPath.appending(path: "ModuleCache")
        let contractObjects = try contractObjectPaths(debugBuildPath: debugBuildPath)
        let sanitizerFlags = try childLinkSanitizerFlags(for: contractObjects)
        let result = try runCapturedProcess(
            arguments: [
                "swiftc"
            ] + sanitizerFlags + [
                "-parse-as-library",
                "-package-name",
                "AgentStudio",
                "-I",
                moduleSearchPath.path,
                "-module-cache-path",
                moduleCachePath.path,
                "-o",
                executableFile.path,
                harnessFile.path,
            ] + contractObjects.map(\.path)
        )

        guard result.terminationStatus == 0 else {
            Issue.record(
                """
                Bridge review adapter executable compile failed with exit \(result.terminationStatus)
                stdout:
                \(result.stdout)
                stderr:
                \(result.stderr)
                """
            )
            throw BridgeReviewCompatibilityHarnessError.executableCompileFailed(result.terminationStatus)
        }

        try runCompiledExecutable(executableFile)
    }
}

extension BridgeReviewSourceAdapterCompileHarness {
    private func childLinkSanitizerFlags(for objectFiles: [URL]) throws -> [String] {
        if try objectFilesContainMarker("__asan_init", in: objectFiles) {
            return ["-sanitize=address"]
        }
        if try objectFilesContainMarker("__tsan_init", in: objectFiles) {
            return ["-sanitize=thread"]
        }
        return []
    }

    private func objectFilesContainMarker(_ marker: String, in objectFiles: [URL]) throws -> Bool {
        for objectFile in objectFiles {
            let objectData = try Data(contentsOf: objectFile, options: .mappedIfSafe)
            if String(bytes: objectData, encoding: .isoLatin1)?.contains(marker) == true {
                return true
            }
        }
        return false
    }

    private func contractObjectPaths(debugBuildPath: URL) throws -> [URL] {
        let buildPath = debugBuildPath.appending(path: "AgentStudioGitContracts.build")
        return try fileManager.contentsOfDirectory(at: buildPath, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasSuffix(".swift.o") }
            .sorted { $0.path < $1.path }
    }

    private func runCompiledExecutable(_ executableFile: URL) throws {
        let result = try runCapturedProcess(executableURL: executableFile, arguments: [])

        guard result.terminationStatus == 0 else {
            Issue.record(
                """
                Bridge review adapter executable failed with exit \(result.terminationStatus)
                stdout:
                \(result.stdout)
                stderr:
                \(result.stderr)
                """
            )
            throw BridgeReviewCompatibilityHarnessError.executableRunFailed(result.terminationStatus)
        }
    }

    private func runCapturedProcess(
        executableURL: URL = URL(fileURLWithPath: "/usr/bin/env"),
        arguments: [String]
    ) throws -> CapturedProcessResult {
        let outputRoot = fileManager.temporaryDirectory
            .appending(path: "agentstudio-git-process-output-\(UUID().uuidString)")
        defer { try? fileManager.removeItem(at: outputRoot) }
        try fileManager.createDirectory(at: outputRoot, withIntermediateDirectories: true)

        let stdoutURL = outputRoot.appending(path: "stdout.txt")
        let stderrURL = outputRoot.appending(path: "stderr.txt")
        fileManager.createFile(atPath: stdoutURL.path, contents: nil)
        fileManager.createFile(atPath: stderrURL.path, contents: nil)

        let stdoutWriter = try FileHandle(forWritingTo: stdoutURL)
        let stderrWriter = try FileHandle(forWritingTo: stderrURL)
        defer {
            stdoutWriter.closeFile()
            stderrWriter.closeFile()
        }

        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        process.environment = ProcessInfo.processInfo.environment.merging(
            ["LC_ALL": "C"]
        ) { _, testValue in testValue }
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = stdoutWriter
        process.standardError = stderrWriter
        try process.run()
        process.waitUntilExit()

        stdoutWriter.closeFile()
        stderrWriter.closeFile()

        return CapturedProcessResult(
            terminationStatus: process.terminationStatus,
            stdout: try String(contentsOf: stdoutURL, encoding: .utf8),
            stderr: try String(contentsOf: stderrURL, encoding: .utf8)
        )
    }

    private struct CapturedProcessResult {
        let terminationStatus: Int32
        let stdout: String
        let stderr: String
    }
}

private enum BridgeReviewCompatibilityHarnessError: Error {
    case typecheckFailed(Int32)
    case executableCompileFailed(Int32)
    case executableRunFailed(Int32)
}
