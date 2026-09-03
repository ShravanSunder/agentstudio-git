import AgentStudioGit
import CryptoKit
import Foundation
import Testing

@testable import AgentStudioGitLocal

@Suite("Git review data integration", .serialized)
struct GitReviewDataIntegrationTests {
    @Test("review metadata does not request encoded binary patch payloads")
    func reviewMetadataDoesNotRequestEncodedBinaryPatchPayloads() throws {
        // Arrange
        let encodedBinaryPatchPayloadFlag = UInt32(1 << 30)

        // Act
        let options = try LibGit2DiffReader().diffOptions()

        // Assert
        #expect(options.flags & encodedBinaryPatchPayloadFlag == 0)
    }

    @Test("bounded review capture retains the designated default and reports tip time")
    func boundedReviewCaptureRetainsDefaultAndTipTime() async throws {
        // Arrange
        let fixture = try GitFixtureRepository.makeRepository(prefix: "agentstudio-git-review-capture")
        defer { fixture.remove() }
        let oid = try fixture.git.run("rev-parse", "HEAD").trimmed
        try fixture.git.run("update-ref", "refs/remotes/origin/main", oid)
        try fixture.git.run("symbolic-ref", "refs/remotes/origin/HEAD", "refs/remotes/origin/main")
        let capturedAt = unixMilliseconds(Date().addingTimeInterval(60))

        // Act
        let capture = try await LibGit2AgentStudioGitLocalClient().captureReviewComparisonTargets(
            GitReviewComparisonTargetCaptureRequest(
                repositoryPath: fixture.repositoryPath,
                capturedAt: capturedAt,
                cutoff: 0,
                maximumRows: 10,
                currentBranchReference: nil
            )
        )

        // Assert
        #expect(capture.defaultReferenceName == "refs/remotes/origin/main")
        #expect(capture.rows.contains { $0.canonicalReferenceName == "refs/remotes/origin/main" })
        #expect(capture.rows.allSatisfy { $0.tipCommittedAt <= capturedAt })
    }

    @Test("bounded review capture prioritizes distinct mandatory rows and truncates recent rows")
    func boundedReviewCapturePrioritizesMandatoryRowsAndTruncatesRecentRows() async throws {
        let fixture = try GitFixtureRepository.makeRepository(prefix: "agentstudio-git-review-bounds")
        defer { fixture.remove() }
        let oid = try fixture.git.run("rev-parse", "HEAD").trimmed
        try fixture.git.run("update-ref", "refs/remotes/origin/main", oid)
        try fixture.git.run("symbolic-ref", "refs/remotes/origin/HEAD", "refs/remotes/origin/main")
        try fixture.git.run("branch", "aaa")
        try fixture.git.run("branch", "zzz")
        let now = unixMilliseconds(Date())
        let client = LibGit2AgentStudioGitLocalClient()

        // Act
        let truncated = try await client.captureReviewComparisonTargets(
            GitReviewComparisonTargetCaptureRequest(
                repositoryPath: fixture.repositoryPath,
                capturedAt: now + 60_000,
                cutoff: 0,
                maximumRows: 2,
                currentBranchReference: "refs/heads/main"
            )
        )

        // Assert
        #expect(truncated.isTruncated)
        #expect(
            truncated.rows.map(\.canonicalReferenceName) == [
                "refs/remotes/origin/main",
                "refs/heads/main",
            ])
        #expect(truncated.defaultReferenceName == "refs/remotes/origin/main")
        #expect(truncated.currentReferenceName == "refs/heads/main")

        // Act
        let futureCutoff = try await client.captureReviewComparisonTargets(
            GitReviewComparisonTargetCaptureRequest(
                repositoryPath: fixture.repositoryPath,
                capturedAt: now + 120_000,
                cutoff: now + 60_000,
                maximumRows: 10,
                currentBranchReference: "refs/heads/main"
            )
        )

        // Assert
        #expect(
            futureCutoff.rows.map(\.canonicalReferenceName) == [
                "refs/remotes/origin/main",
                "refs/heads/main",
            ])
        #expect(!futureCutoff.isTruncated)
    }

    @Test("bounded review capture collapses duplicate default and current roles")
    func boundedReviewCaptureCollapsesDuplicateRoles() async throws {
        // Arrange
        let fixture = try GitFixtureRepository.makeRepository(prefix: "agentstudio-git-review-dedup")
        defer { fixture.remove() }
        let oid = try fixture.git.run("rev-parse", "HEAD").trimmed
        try fixture.git.run("update-ref", "refs/remotes/origin/main", oid)
        try fixture.git.run("symbolic-ref", "refs/remotes/origin/HEAD", "refs/remotes/origin/main")

        // Act
        let capture = try await LibGit2AgentStudioGitLocalClient().captureReviewComparisonTargets(
            GitReviewComparisonTargetCaptureRequest(
                repositoryPath: fixture.repositoryPath,
                capturedAt: unixMilliseconds(Date().addingTimeInterval(60)),
                cutoff: 0,
                maximumRows: 10,
                currentBranchReference: "refs/remotes/origin/main"
            )
        )

        // Assert
        #expect(capture.defaultReferenceName == "refs/remotes/origin/main")
        #expect(capture.currentReferenceName == "refs/remotes/origin/main")
        #expect(capture.rows.filter { $0.canonicalReferenceName == "refs/remotes/origin/main" }.count == 1)
    }

    @Test("bounded review capture canonicalizes branch shorthands before mandatory retention")
    func boundedReviewCaptureCanonicalizesBranchShorthandsBeforeMandatoryRetention() async throws {
        // Arrange
        let fixture = try GitFixtureRepository.makeRepository(prefix: "agentstudio-git-review-current-dwim")
        defer { fixture.remove() }
        let oid = try fixture.git.run("rev-parse", "HEAD").trimmed
        try fixture.git.run("branch", "feature/foo")
        try fixture.git.run("update-ref", "refs/remotes/origin/archive", oid)
        let now = unixMilliseconds(Date())
        let client = LibGit2AgentStudioGitLocalClient()
        let scenarios: [(input: String, canonical: String, target: GitReviewComparisonBranchTarget)] = [
            (
                input: "origin/archive",
                canonical: "refs/remotes/origin/archive",
                target: .remoteTracking(remoteName: "origin", branchName: "archive", oid: oid)
            ),
            (
                input: "feature/foo",
                canonical: "refs/heads/feature/foo",
                target: .local(branchName: "feature/foo", oid: oid)
            ),
            (
                input: "refs/heads/feature/foo",
                canonical: "refs/heads/feature/foo",
                target: .local(branchName: "feature/foo", oid: oid)
            ),
        ]

        // Act / Assert
        for scenario in scenarios {
            let capture = try await client.captureReviewComparisonTargets(
                GitReviewComparisonTargetCaptureRequest(
                    repositoryPath: fixture.repositoryPath,
                    capturedAt: now + 120_000,
                    cutoff: now + 60_000,
                    maximumRows: 10,
                    currentBranchReference: scenario.input
                )
            )

            #expect(capture.currentReferenceName == scenario.canonical)
            #expect(capture.rows.map(\.canonicalReferenceName) == [scenario.canonical])
            #expect(capture.rows.first?.target == scenario.target)
        }
    }

    @Test("bounded review capture does not retain tags or revision expressions as current branches")
    func boundedReviewCaptureDoesNotRetainNonBranchCurrentTargets() async throws {
        // Arrange
        let fixture = try GitFixtureRepository.makeRepository(prefix: "agentstudio-git-review-current-non-branch")
        defer { fixture.remove() }
        try fixture.git.run("tag", "archive-tag")
        let now = unixMilliseconds(Date())
        let client = LibGit2AgentStudioGitLocalClient()

        // Act / Assert
        for currentTarget in ["archive-tag", "main^{commit}"] {
            let capture = try await client.captureReviewComparisonTargets(
                GitReviewComparisonTargetCaptureRequest(
                    repositoryPath: fixture.repositoryPath,
                    capturedAt: now + 120_000,
                    cutoff: now + 60_000,
                    maximumRows: 10,
                    currentBranchReference: currentTarget
                )
            )

            #expect(capture.currentReferenceName == nil)
            #expect(capture.rows.isEmpty)
        }
    }

    @Test("bounded review capture follows DWIM precedence when local and remote branch shorthands collide")
    func boundedReviewCaptureFollowsDWIMPrecedenceForBranchCollision() async throws {
        // Arrange
        let fixture = try GitFixtureRepository.makeRepository(prefix: "agentstudio-git-review-current-collision")
        defer { fixture.remove() }
        let oid = try fixture.git.run("rev-parse", "HEAD").trimmed
        try fixture.git.run("branch", "origin/archive")
        try fixture.git.run("update-ref", "refs/remotes/origin/archive", oid)
        let now = unixMilliseconds(Date())

        // Act
        let capture = try await LibGit2AgentStudioGitLocalClient().captureReviewComparisonTargets(
            GitReviewComparisonTargetCaptureRequest(
                repositoryPath: fixture.repositoryPath,
                capturedAt: now + 120_000,
                cutoff: now + 60_000,
                maximumRows: 10,
                currentBranchReference: "origin/archive"
            )
        )

        // Assert
        #expect(capture.currentReferenceName == "refs/heads/origin/archive")
        #expect(capture.rows.map(\.canonicalReferenceName) == ["refs/heads/origin/archive"])
        #expect(capture.rows.first?.target == .local(branchName: "origin/archive", oid: oid))
    }

    @Test("default resolver designates origin HEAD without substituting divergent local main")
    func defaultResolverDesignatesOriginHeadWithoutSubstitutingDivergentLocalMain() async throws {
        // Arrange
        let fixture = try GitFixtureRepository.makeRepository(prefix: "agentstudio-git-review-targets")
        defer { fixture.remove() }
        let remoteMainOID = try fixture.git.run("rev-parse", "HEAD").trimmed
        try fixture.git.run("update-ref", "refs/remotes/origin/main", remoteMainOID)
        try fixture.git.run("symbolic-ref", "refs/remotes/origin/HEAD", "refs/remotes/origin/main")
        try fixture.git.run("update-ref", "refs/remotes/origin/release", remoteMainOID)
        try fixture.git.run("branch", "stack/base")
        try fixture.write("local-only.txt", contents: "local integration work\n")
        try fixture.git.run("add", "local-only.txt")
        try fixture.git.run("commit", "-m", "local integration commit")
        let localMainOID = try fixture.git.run("rev-parse", "refs/heads/main").trimmed
        let client = LibGit2AgentStudioGitLocalClient()
        let defaultTarget = try await client.resolveReviewDefaultTarget(for: fixture.repositoryPath)
        let capture = try await client.captureReviewComparisonTargets(
            GitReviewComparisonTargetCaptureRequest(
                repositoryPath: fixture.repositoryPath,
                capturedAt: unixMilliseconds(Date().addingTimeInterval(60)),
                cutoff: 0,
                maximumRows: 10,
                currentBranchReference: nil
            )
        )

        // Assert
        #expect(
            defaultTarget
                == .remoteTracking(remoteName: "origin", branchName: "main", oid: remoteMainOID)
        )
        #expect(remoteMainOID != localMainOID)
        #expect(capture.rows.contains { $0.target == .local(branchName: "main", oid: localMainOID) })
        #expect(capture.rows.contains { $0.target == .local(branchName: "stack/base", oid: remoteMainOID) })
        #expect(
            capture.rows.contains {
                $0.target == .remoteTracking(remoteName: "origin", branchName: "main", oid: remoteMainOID)
            }
        )
        #expect(
            capture.rows.contains {
                $0.target == .remoteTracking(remoteName: "origin", branchName: "release", oid: remoteMainOID)
            }
        )
        #expect(!capture.rows.contains { $0.canonicalReferenceName == "refs/remotes/origin/HEAD" })
    }

    @Test("default resolver leaves the target absent for unusable origin HEAD references")
    func defaultResolverRejectsUnusableOriginHeadReferences() async throws {
        // Arrange
        let absentFixture = try GitFixtureRepository.makeRepository(prefix: "agentstudio-git-targets-absent")
        defer { absentFixture.remove() }

        let directFixture = try GitFixtureRepository.makeRepository(prefix: "agentstudio-git-targets-direct")
        defer { directFixture.remove() }
        let directOID = try directFixture.git.run("rev-parse", "HEAD").trimmed
        try directFixture.git.run("update-ref", "refs/remotes/origin/HEAD", directOID)

        let malformedFixture = try GitFixtureRepository.makeRepository(prefix: "agentstudio-git-targets-malformed")
        defer { malformedFixture.remove() }
        try malformedFixture.git.run("symbolic-ref", "refs/remotes/origin/HEAD", "refs/heads/main")

        let danglingFixture = try GitFixtureRepository.makeRepository(prefix: "agentstudio-git-targets-dangling")
        defer { danglingFixture.remove() }
        try danglingFixture.git.run(
            "symbolic-ref",
            "refs/remotes/origin/HEAD",
            "refs/remotes/origin/missing"
        )
        let client = LibGit2AgentStudioGitLocalClient()

        // Act
        var targets: [GitReviewComparisonBranchTarget?] = []
        for fixture in [absentFixture, directFixture, malformedFixture, danglingFixture] {
            targets.append(try await client.resolveReviewDefaultTarget(for: fixture.repositoryPath))
        }

        // Assert
        #expect(targets.allSatisfy { $0 == nil })
    }

    @Test(
        "contribution capture retains committed and dirty work across history shapes",
        arguments: ContributionHistoryShape.allCases
    )
    func contributionCaptureRetainsCommittedAndDirtyWork(historyShape: ContributionHistoryShape) async throws {
        // Arrange
        let fixture = try ContributionHistoryFixture.make(historyShape)
        defer { fixture.remove() }
        try fixture.addDirtyWorktreeChanges()
        let client = LibGit2AgentStudioGitLocalClient()

        // Act
        let snapshot = try await client.contributionDiff(fixture.request)
        let files = filesByPath(snapshot.diff.files)

        // Assert
        #expect(snapshot.resolvedTarget.oid == fixture.targetOID)
        #expect(snapshot.reviewedHead.oid == fixture.reviewedHeadOID)
        #expect(snapshot.contributionBase.oid == fixture.expectedBaseOID)
        #expect(files["target-only.txt"] == nil)
        #expect(files["staged.txt"]?.changeKind == .added)
        #expect(files["README.md"]?.changeKind == .modified)
        #expect(files["untracked.txt"]?.changeKind == .added)
        #expect((files["feature.txt"] != nil) == historyShape.hasCommittedContribution)
    }

    @Test("target-only advancement changes target identity without changing contribution")
    func targetOnlyAdvancementChangesTargetIdentityWithoutChangingContribution() async throws {
        // Arrange
        let fixture = try ContributionHistoryFixture.make(.diverged)
        defer { fixture.remove() }
        let client = LibGit2AgentStudioGitLocalClient()
        let expressionRequest = GitContributionDiffRequest(
            repositoryPath: fixture.request.repositoryPath,
            target: .named("\(fixture.request.target.name)^{commit}")
        )
        let predecessor = try await client.contributionDiff(expressionRequest)

        // Act
        let advancedTargetOID = try fixture.advanceTargetOnly()
        let successor = try await client.contributionDiff(expressionRequest)

        // Assert
        #expect(predecessor.resolvedTarget.oid != successor.resolvedTarget.oid)
        #expect(successor.resolvedTarget.oid == advancedTargetOID)
        #expect(predecessor.contributionBase == successor.contributionBase)
        #expect(predecessor.diff == successor.diff)
        #expect(filesByPath(successor.diff.files)["target-second.txt"] == nil)
    }

    @Test(arguments: FortyCharacterTargetScenario.allCases)
    func fortyCharacterTargetResolution(scenario: FortyCharacterTargetScenario) async throws {
        // Arrange
        let fixture = try scenario.makeFixture()
        defer { fixture.remove() }
        // Act
        let snapshot = try await LibGit2AgentStudioGitLocalClient().contributionDiff(fixture.request)
        // Assert
        #expect(snapshot.resolvedTarget == fixture.expectedRevision)
    }

    @Test("contribution capture preserves rename delete and binary facts")
    func contributionCapturePreservesRenameDeleteAndBinaryFacts() async throws {
        // Arrange
        let fixture = try RenameDeleteBinaryFixture.make()
        defer { fixture.remove() }
        let client = LibGit2AgentStudioGitLocalClient()

        // Act
        let snapshot = try await client.contributionDiff(fixture.request)
        let files = filesByPath(snapshot.diff.files)

        // Assert
        #expect(files["renamed.txt"]?.changeKind == .renamed)
        #expect(files["renamed.txt"]?.previousPath == "rename-source.txt")
        #expect(files["delete-source.txt"]?.changeKind == .deleted)
        #expect(files["binary.bin"]?.isBinary == true)
    }

    @Test("contribution capture preserves recreated content after a staged same-path deletion")
    func contributionCapturePreservesRecreatedContentAfterStagedSamePathDeletion() async throws {
        // Arrange
        let fixture = try SamePathOverlapFixture.make()
        defer { fixture.remove() }
        let client = LibGit2AgentStudioGitLocalClient()

        // Act
        let snapshot = try await client.contributionDiff(fixture.request)
        let overlap = try #require(filesByPath(snapshot.diff.files)["overlap.txt"])

        // Assert
        #expect(overlap.changeKind == .modified)
        #expect(overlap.oldContentHash == fixture.originalContentHash)
        #expect(overlap.newContentHash == fixture.recreatedContentHash)
    }

    @Test("contribution capture rejects unresolved targets without a snapshot")
    func contributionCaptureRejectsUnresolvedTargetsWithoutASnapshot() async throws {
        // Arrange
        let fixture = try GitFixtureRepository.makeRepository(prefix: "agentstudio-git-unresolved-target")
        defer { fixture.remove() }
        let request = GitContributionDiffRequest(
            repositoryPath: fixture.repositoryPath,
            target: .named("refs/heads/missing")
        )
        let client = LibGit2AgentStudioGitLocalClient()

        // Act / Assert
        await #expect(throws: GitDataPlaneError.revisionUnavailable(target: request.target)) {
            _ = try await client.contributionDiff(request)
        }
    }

    @Test(
        "contribution capture preserves target and HEAD failure identity without a snapshot",
        arguments: ContributionRevisionFailureScenario.allCases
    )
    func contributionCapturePreservesRevisionFailureIdentity(
        scenario: ContributionRevisionFailureScenario
    ) async throws {
        // Arrange
        let fixture = try scenario.makeFixture()
        defer { fixture.remove() }
        let client = LibGit2AgentStudioGitLocalClient()

        // Act / Assert
        await #expect(throws: fixture.expectedError) {
            _ = try await client.contributionDiff(fixture.request)
        }
    }

    @Test("contribution capture rejects unrelated histories without a snapshot")
    func contributionCaptureRejectsUnrelatedHistoriesWithoutASnapshot() async throws {
        // Arrange
        let fixture = try UnrelatedHistoryFixture.make()
        defer { fixture.remove() }
        let client = LibGit2AgentStudioGitLocalClient()

        // Act / Assert
        await #expect(
            throws: GitDataPlaneError.noSharedHistory(
                targetOID: fixture.targetOID,
                headOID: fixture.reviewedHeadOID
            )
        ) {
            _ = try await client.contributionDiff(fixture.request)
        }
    }

    @Test("contribution capture rejects missing ancestry without a partial snapshot")
    func contributionCaptureRejectsMissingAncestryWithoutAPartialSnapshot() async throws {
        // Arrange
        let fixture = try MissingAncestryFixture.make()
        defer { fixture.remove() }
        let client = LibGit2AgentStudioGitLocalClient()

        // Act / Assert
        do {
            _ = try await client.contributionDiff(fixture.request)
            Issue.record("missing ancestry unexpectedly produced a contribution snapshot")
        } catch GitDataPlaneError.libgit2Failure(_, _, let message) {
            #expect(message.contains(fixture.missingCommitOID))
        } catch {
            Issue.record("expected libgit2 failure, got \(error)")
        }
    }

    @Test("contribution capture rejects multiple best merge bases without a snapshot")
    func contributionCaptureRejectsMultipleBestMergeBasesWithoutASnapshot() async throws {
        // Arrange
        let fixture = try MultipleBestMergeBasesFixture.make()
        defer { fixture.remove() }
        let client = LibGit2AgentStudioGitLocalClient()

        // Act / Assert
        await #expect(
            throws: GitDataPlaneError.multipleBestMergeBases(
                targetOID: fixture.targetOID,
                headOID: fixture.reviewedHeadOID,
                count: 2
            )
        ) {
            _ = try await client.contributionDiff(fixture.request)
        }
    }

    @Test("contribution capture rejects unborn and missing HEAD without a snapshot")
    func contributionCaptureRejectsUnbornAndMissingHeadWithoutASnapshot() async throws {
        // Arrange
        let unbornFixture = try GitFixtureRepository.makeRepository(prefix: "agentstudio-git-unborn-head")
        let missingFixture = try GitFixtureRepository.makeRepository(prefix: "agentstudio-git-missing-head")
        defer {
            unbornFixture.remove()
            missingFixture.remove()
        }
        try unbornFixture.git.run("symbolic-ref", "HEAD", "refs/heads/unborn")
        try missingFixture.git.run("symbolic-ref", "HEAD", "refs/missing/HEAD")
        let client = LibGit2AgentStudioGitLocalClient()

        // Act / Assert
        for fixture in [unbornFixture, missingFixture] {
            await #expect(throws: GitDataPlaneError.headUnavailable) {
                _ = try await client.contributionDiff(
                    GitContributionDiffRequest(
                        repositoryPath: fixture.repositoryPath,
                        target: .named("refs/heads/main")
                    )
                )
            }
        }
    }

    @Test("contribution capture rejects a missing required tree without a snapshot")
    func contributionCaptureRejectsMissingRequiredTreeWithoutASnapshot() async throws {
        // Arrange
        let fixture = try GitFixtureRepository.makeRepository(prefix: "agentstudio-git-missing-base-tree")
        defer { fixture.remove() }
        let treeOID = try fixture.git.run("rev-parse", "HEAD^{tree}").trimmed
        try FileManager.default.removeItem(at: fixture.looseObjectPath(oid: treeOID))
        let client = LibGit2AgentStudioGitLocalClient()

        // Act / Assert
        await #expect(throws: GitDataPlaneError.requiredObjectNotFound(oid: treeOID)) {
            _ = try await client.contributionDiff(
                GitContributionDiffRequest(
                    repositoryPath: fixture.repositoryPath,
                    target: .named("refs/heads/main")
                )
            )
        }
    }

    @Test("revision resolution and tree reads expose commit backed review data")
    func revisionResolutionAndTreeReadsExposeCommitBackedReviewData() async throws {
        let fixture = try ReviewDataFixture.make()
        defer { fixture.remove() }
        let client = LibGit2AgentStudioGitLocalClient()

        let resolvedHead = try await client.resolveRevision(
            GitRevisionResolutionRequest(repositoryPath: fixture.repositoryPath, target: .named("HEAD"))
        )
        let resolvedBase = try await client.resolveRevision(
            GitRevisionResolutionRequest(repositoryPath: fixture.repositoryPath, target: .named(fixture.baseOID))
        )
        let rootTree = try await client.readTree(
            GitTreeReadRequest(repositoryPath: fixture.repositoryPath, revision: .named("HEAD"), path: nil)
        )
        let sourcesTree = try await client.readTree(
            GitTreeReadRequest(repositoryPath: fixture.repositoryPath, revision: .named("HEAD"), path: "Sources")
        )

        #expect(resolvedHead.oid == fixture.headOID)
        #expect(resolvedBase.oid == fixture.baseOID)
        #expect(rootTree.revision.oid == fixture.headOID)
        #expect(rootTree.entries.contains { $0.path == "Sources" && $0.isTree })
        #expect(rootTree.entries.contains { $0.path == "binary.bin" && !$0.isTree && $0.sizeBytes == 5 })
        #expect(sourcesTree.entries.contains { $0.path == "Sources/App.swift" && !$0.isTree })
    }

    @Test("tree reads preserve entries when blob size lookup cannot read an object")
    func treeReadsPreserveEntriesWhenBlobSizeLookupCannotReadAnObject() async throws {
        let fixture = try GitFixtureRepository.makeRepository(prefix: "agentstudio-git-tree-missing-blob")
        defer { fixture.remove() }
        try fixture.write("MissingBlob.txt", contents: "content\n")
        try fixture.git.run("add", "MissingBlob.txt")
        try fixture.git.run("commit", "-m", "seed missing blob")
        let blobOID = try fixture.git.run("rev-parse", "HEAD:MissingBlob.txt")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let objectPath = fixture.repositoryPath
            .appending(path: ".git/objects")
            .appending(path: String(blobOID.prefix(2)))
            .appending(path: String(blobOID.dropFirst(2)))
        try FileManager.default.removeItem(at: objectPath)
        let client = LibGit2AgentStudioGitLocalClient()

        let tree = try await client.readTree(
            GitTreeReadRequest(repositoryPath: fixture.repositoryPath, revision: .named("HEAD"), path: nil)
        )
        let entry = try #require(tree.entries.first { $0.path == "MissingBlob.txt" })

        #expect(entry.oid == blobOID)
        #expect(entry.sizeBytes == nil)
    }

    @Test("diffs cover commit index and working-tree endpoints")
    func diffsCoverCommitIndexAndWorkingTreeEndpoints() async throws {
        let fixture = try ReviewDataFixture.make()
        defer { fixture.remove() }
        let client = LibGit2AgentStudioGitLocalClient()

        let commitDiff = try await client.diff(
            GitDiffRequest(
                repositoryPath: fixture.repositoryPath,
                base: .commit(fixture.baseOID),
                compare: .commit(fixture.headOID)
            )
        )
        try fixture.stageReviewChanges()

        let headToIndex = try await client.diff(
            GitDiffRequest(repositoryPath: fixture.repositoryPath, base: .head, compare: .index)
        )
        try fixture.addWorkingTreeOnlyChanges()
        let objectCountBeforeWorktreeDiff = try fixture.looseObjectCount()
        let indexToWorktree = try await client.diff(
            GitDiffRequest(repositoryPath: fixture.repositoryPath, base: .index, compare: .workingTree)
        )
        let objectCountAfterWorktreeDiff = try fixture.looseObjectCount()
        let headToWorktree = try await client.diff(
            GitDiffRequest(repositoryPath: fixture.repositoryPath, base: .head, compare: .workingTree)
        )

        let commitFiles = filesByPath(commitDiff.files)
        #expect(commitFiles["Sources/App.swift"]?.changeKind == .modified)
        #expect(commitFiles["Sources/New.swift"]?.changeKind == .added)
        #expect(commitFiles["Sources/App.swift"]?.oldContentHash != nil)
        #expect(commitFiles["Sources/App.swift"]?.newContentHash != nil)
        #expect(commitFiles["Sources/App.swift"]?.contentHashAlgorithm == "git-blob-sha1")

        let stagedFiles = filesByPath(headToIndex.files)
        #expect(stagedFiles["Docs/RenamedGuide.md"]?.changeKind == .renamed)
        #expect(stagedFiles["Docs/RenamedGuide.md"]?.previousPath == "Docs/Guide.md")
        #expect(stagedFiles["delete-me.txt"]?.changeKind == .deleted)
        #expect(stagedFiles["script.sh"]?.oldMode == 0o100644)
        #expect(stagedFiles["script.sh"]?.newMode == 0o100755)

        let worktreeFiles = filesByPath(indexToWorktree.files)
        let filteredCRLFHash = try fixture.filteredHash("crlf.crlf")
        #expect(objectCountAfterWorktreeDiff == objectCountBeforeWorktreeDiff)
        #expect(worktreeFiles["Sources/App.swift"]?.changeKind == .modified)
        #expect(worktreeFiles["worktree-only.txt"]?.changeKind == .added)
        #expect(worktreeFiles["large.txt"]?.sizeBytes == 2048)
        #expect(worktreeFiles["crlf.crlf"]?.newContentHash == filteredCRLFHash)
        #expect(worktreeFiles["crlf.crlf"]?.contentHashAlgorithm == "git-blob-sha1")

        let fullFiles = filesByPath(headToWorktree.files)
        #expect(fullFiles["binary.bin"]?.isBinary == true)
        #expect(fullFiles["binary.bin"]?.newContentHash != nil)
        #expect(fullFiles["Docs/RenamedGuide.md"]?.fileId != nil)
    }

    @Test("direct review comparison correlates a selected target with the working tree")
    func directReviewComparisonCorrelatesSelectedTargetWithWorkingTree() async throws {
        // Arrange
        let fixture = try ReviewDataFixture.make()
        defer { fixture.remove() }
        try fixture.stageReviewChanges()
        try fixture.addWorkingTreeOnlyChanges()
        let client = LibGit2AgentStudioGitLocalClient()

        // Act
        let snapshot = try await client.directReviewComparison(
            GitDirectReviewComparisonRequest(
                repositoryPath: fixture.repositoryPath,
                target: .named(fixture.baseOID)
            )
        )
        let files = filesByPath(snapshot.diff.files)

        // Assert
        #expect(snapshot.resolvedTarget.oid == fixture.baseOID)
        #expect(snapshot.reviewedHead.oid == fixture.headOID)
        #expect(files["Sources/App.swift"]?.changeKind == .modified)
        #expect(files["Sources/New.swift"]?.changeKind == .added)
        #expect(files["worktree-only.txt"]?.changeKind == .added)
        #expect(files["Docs/RenamedGuide.md"]?.changeKind == .renamed)
    }

    @Test("content reads load commit index and working-tree bytes and enforce size limits")
    func contentReadsLoadCommitIndexAndWorkingTreeBytesAndEnforceSizeLimits() async throws {
        let fixture = try ReviewDataFixture.make()
        defer { fixture.remove() }
        let client = LibGit2AgentStudioGitLocalClient()

        let headContent = try await client.content(
            GitContentRequest(repositoryPath: fixture.repositoryPath, target: .head, path: "Sources/App.swift")
        )
        let binaryContent = try await client.content(
            GitContentRequest(repositoryPath: fixture.repositoryPath, target: .head, path: "binary.bin")
        )

        try fixture.stageReviewChanges()
        try fixture.write("Sources/App.swift", contents: "func value() -> Int {\n    30\n}\n")
        let indexContent = try await client.content(
            GitContentRequest(repositoryPath: fixture.repositoryPath, target: .index, path: "Sources/App.swift")
        )
        let worktreeContent = try await client.content(
            GitContentRequest(
                repositoryPath: fixture.repositoryPath,
                target: .workingTree,
                path: "Sources/App.swift"
            )
        )

        #expect(String(data: headContent.data, encoding: .utf8)?.contains("20") == true)
        #expect(headContent.contentHashAlgorithm == "sha256")
        #expect(headContent.contentHash == sha256ContentHash(headContent.data))
        #expect(!headContent.isBinary)
        #expect(binaryContent.isBinary)
        #expect(String(data: indexContent.data, encoding: .utf8)?.contains("10") == true)
        #expect(String(data: worktreeContent.data, encoding: .utf8)?.contains("30") == true)

        await #expect(
            throws: GitDataPlaneError.contentTooLarge(
                path: "large.txt",
                sizeBytes: 2048,
                maxSizeBytes: 16
            )
        ) {
            try await client.content(
                GitContentRequest(
                    repositoryPath: fixture.repositoryPath,
                    target: .workingTree,
                    path: "large.txt",
                    maxSizeBytes: 16
                )
            )
        }
    }

    @Test("working-tree content refuses paths that escape the repository")
    func workingTreeContentRefusesPathsThatEscapeTheRepository() async throws {
        let fixture = try ReviewDataFixture.make()
        defer { fixture.remove() }
        let client = LibGit2AgentStudioGitLocalClient()
        try fixture.writeOutsideRepository("outside.txt", contents: "outside\n")
        try fixture.createSymlinkToOutsideFile(named: "outside-link.txt", outsideName: "outside.txt")

        await #expect(throws: GitDataPlaneError.pathEscapesRepository(path: "../outside.txt")) {
            try await client.content(
                GitContentRequest(repositoryPath: fixture.repositoryPath, target: .workingTree, path: "../outside.txt")
            )
        }
        await #expect(throws: GitDataPlaneError.pathEscapesRepository(path: "outside-link.txt")) {
            try await client.content(
                GitContentRequest(
                    repositoryPath: fixture.repositoryPath,
                    target: .workingTree,
                    path: "outside-link.txt"
                )
            )
        }
    }

    @Test("review APIs report missing repositories consistently")
    func reviewAPIsReportMissingRepositoriesConsistently() async {
        let missingRepositoryPath = FileManager.default.temporaryDirectory
            .appending(path: "agentstudio-git-missing-review-\(UUID().uuidString)")
        let client = LibGit2AgentStudioGitLocalClient()

        await #expect(throws: GitDataPlaneError.repositoryNotFound(path: missingRepositoryPath)) {
            _ = try await client.resolveRevision(
                GitRevisionResolutionRequest(repositoryPath: missingRepositoryPath, target: .named("HEAD"))
            )
        }
        await #expect(throws: GitDataPlaneError.repositoryNotFound(path: missingRepositoryPath)) {
            _ = try await client.readTree(
                GitTreeReadRequest(repositoryPath: missingRepositoryPath, revision: .named("HEAD"), path: nil)
            )
        }
        await #expect(throws: GitDataPlaneError.repositoryNotFound(path: missingRepositoryPath)) {
            _ = try await client.diff(
                GitDiffRequest(repositoryPath: missingRepositoryPath, base: .head, compare: .workingTree)
            )
        }
        await #expect(throws: GitDataPlaneError.repositoryNotFound(path: missingRepositoryPath)) {
            _ = try await client.content(
                GitContentRequest(repositoryPath: missingRepositoryPath, target: .head, path: "README.md")
            )
        }
    }
}

private struct ReviewDataFixture {
    let fixture: GitFixtureRepository
    let baseOID: String
    let headOID: String

    var repositoryPath: URL { fixture.repositoryPath }

    static func make() throws -> Self {
        let fixture = try GitFixtureRepository.makeRepository(prefix: "agentstudio-git-review-data")
        try fixture.write(".gitattributes", contents: "*.crlf text eol=crlf\n")
        try fixture.write("Sources/App.swift", contents: "func value() -> Int {\n    10\n}\n")
        try fixture.write("Docs/Guide.md", contents: "guide\n")
        try fixture.write("delete-me.txt", contents: "remove me\n")
        try fixture.write("script.sh", contents: "#!/bin/sh\necho hello\n")
        try fixture.write("crlf.crlf", contents: "one\ntwo\n")
        try writeData(Data([0, 1, 2, 3, 255]), to: "binary.bin", in: fixture.repositoryPath)
        try fixture.git.run("add", ".")
        try fixture.git.run("commit", "-m", "seed review data")
        let baseOID = try fixture.git.run("rev-parse", "HEAD").trimmingCharacters(in: .whitespacesAndNewlines)

        try fixture.write("Sources/App.swift", contents: "func value() -> Int {\n    20\n}\n")
        try fixture.write("Sources/New.swift", contents: "let created = true\n")
        try fixture.git.run("add", ".")
        try fixture.git.run("commit", "-m", "update review data")
        let headOID = try fixture.git.run("rev-parse", "HEAD").trimmingCharacters(in: .whitespacesAndNewlines)

        try fixture.write("large.txt", contents: String(repeating: "x", count: 2048))
        return Self(fixture: fixture, baseOID: baseOID, headOID: headOID)
    }

    func remove() {
        fixture.remove()
    }

    func write(_ relativePath: String, contents: String) throws {
        try fixture.write(relativePath, contents: contents)
    }

    func stageReviewChanges() throws {
        try fixture.write("Sources/App.swift", contents: "func value() -> Int {\n    10\n}\n")
        try fixture.git.run("add", "Sources/App.swift")
        try fixture.git.run("mv", "Docs/Guide.md", "Docs/RenamedGuide.md")
        try fixture.git.run("rm", "delete-me.txt")
        try fixture.git.run("update-index", "--chmod=+x", "script.sh")
        try writeData(Data([255, 3, 2, 1, 0]), to: "binary.bin", in: fixture.repositoryPath)
        try fixture.git.run("add", "binary.bin")
    }

    func addWorkingTreeOnlyChanges() throws {
        try fixture.write("Sources/App.swift", contents: "func value() -> Int {\n    30\n}\n")
        try fixture.write("crlf.crlf", contents: "one\ntwo\nthree\n")
        try fixture.write("worktree-only.txt", contents: "loose\n")
    }

    func filteredHash(_ relativePath: String) throws -> String {
        try fixture.git.run("hash-object", "--path=\(relativePath)", relativePath)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func looseObjectCount() throws -> Int {
        let output = try fixture.git.run("count-objects", "-v")
        let countLine = try #require(output.split(separator: "\n").first { $0.hasPrefix("count:") })
        let countValue = try #require(countLine.split(separator: " ").last)
        return try #require(Int(countValue))
    }

    func writeOutsideRepository(_ name: String, contents: String) throws {
        try contents.write(to: fixture.root.appending(path: name), atomically: true, encoding: .utf8)
    }

    func createSymlinkToOutsideFile(named name: String, outsideName: String) throws {
        try FileManager.default.createSymbolicLink(
            at: fixture.repositoryPath.appending(path: name),
            withDestinationURL: fixture.root.appending(path: outsideName)
        )
    }
}

private func filesByPath(_ files: [GitDiffFile]) -> [String: GitDiffFile] {
    Dictionary(uniqueKeysWithValues: files.map { ($0.path, $0) })
}

private func unixMilliseconds(_ date: Date) -> Int64 {
    Int64(date.timeIntervalSince1970 * 1000)
}

private func writeData(_ data: Data, to relativePath: String, in directory: URL) throws {
    let file = directory.appending(path: relativePath)
    try FileManager.default.createDirectory(
        at: file.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    try data.write(to: file)
}

private func sha256ContentHash(_ data: Data) -> String {
    let digest = SHA256.hash(data: data)
    return "sha256:\(digest.map { String(format: "%02x", $0) }.joined())"
}
