import AgentStudioGit
import Foundation

enum LocalDefaultBranchDesignationScenario: String, CaseIterable, CustomStringConvertible, Sendable {
    case absent
    case direct
    case malformed
    case missingLocalBranch
    case missingLocalObject
    case nonCommitLocalObject
    case selfReferential

    var description: String { rawValue }

    func makeFixture() throws -> GitFixtureRepository {
        let fixture = try GitFixtureRepository.makeRepository(prefix: "agentstudio-git-designation-\(rawValue)")
        let headOID = try fixture.git.run("rev-parse", "HEAD").trimmed
        switch self {
        case .absent:
            break
        case .direct:
            try fixture.git.run("update-ref", "refs/remotes/origin/HEAD", headOID)
        case .malformed:
            try fixture.git.run("symbolic-ref", "refs/remotes/origin/HEAD", "refs/heads/main")
        case .missingLocalBranch:
            try fixture.git.run("update-ref", "refs/remotes/origin/trunk", headOID)
            try fixture.git.run("symbolic-ref", "refs/remotes/origin/HEAD", "refs/remotes/origin/trunk")
        case .missingLocalObject:
            try fixture.git.run("update-ref", "refs/remotes/origin/main", headOID)
            try fixture.git.run("symbolic-ref", "refs/remotes/origin/HEAD", "refs/remotes/origin/main")
            try fixture.write(".git/refs/heads/main", contents: "1111111111111111111111111111111111111111\n")
        case .nonCommitLocalObject:
            let treeOID = try fixture.git.run("rev-parse", "HEAD^{tree}").trimmed
            try fixture.git.run("update-ref", "refs/remotes/origin/main", headOID)
            try fixture.git.run("symbolic-ref", "refs/remotes/origin/HEAD", "refs/remotes/origin/main")
            try fixture.write(".git/refs/heads/main", contents: "\(treeOID)\n")
        case .selfReferential:
            try fixture.git.run("update-ref", "refs/heads/HEAD", headOID)
            try fixture.git.run("symbolic-ref", "refs/remotes/origin/HEAD", "refs/remotes/origin/HEAD")
        }
        return fixture
    }
}

enum ContributionHistoryShape: String, CaseIterable, Sendable {
    case diverged
    case merged
    case rebased
    case targetContainsHead

    var hasCommittedContribution: Bool {
        self != .targetContainsHead
    }
}

enum ContributionRevisionFailureScenario: String, CaseIterable, CustomStringConvertible, Sendable {
    case missingDWIMTargetObject
    case missingTargetObject
    case missingHeadObject
    case nonCommitTarget

    var description: String { rawValue }

    func makeFixture() throws -> ContributionRevisionFailureFixture {
        let fixture = try GitFixtureRepository.makeRepository(prefix: "agentstudio-git-revision-\(rawValue)")
        let commitOID = try fixture.git.run("rev-parse", "HEAD").trimmed
        var target = GitRevisionTarget.named("refs/heads/target")
        let missingOID = "2222222222222222222222222222222222222222"
        let expectedError: GitDataPlaneError

        switch self {
        case .missingDWIMTargetObject:
            try fixture.write(".git/refs/heads/target", contents: "\(missingOID)\n")
            target = .named("target")
            expectedError = .requiredObjectNotFound(oid: missingOID)
        case .missingTargetObject:
            try fixture.write(".git/refs/heads/target", contents: "\(missingOID)\n")
            expectedError = .requiredObjectNotFound(oid: missingOID)
        case .missingHeadObject:
            try fixture.git.run("update-ref", target.name, commitOID)
            try fixture.write(".git/refs/heads/main", contents: "\(missingOID)\n")
            expectedError = .requiredObjectNotFound(oid: missingOID)
        case .nonCommitTarget:
            let treeOID = try fixture.git.run("rev-parse", "HEAD^{tree}").trimmed
            try fixture.write(".git/refs/heads/target", contents: "\(treeOID)\n")
            expectedError = .revisionUnavailable(target: target)
        }

        return ContributionRevisionFailureFixture(
            fixture: fixture,
            request: GitContributionDiffRequest(repositoryPath: fixture.repositoryPath, target: target),
            expectedError: expectedError
        )
    }
}

struct ContributionRevisionFailureFixture {
    let fixture: GitFixtureRepository
    let request: GitContributionDiffRequest
    let expectedError: GitDataPlaneError

    func remove() {
        fixture.remove()
    }
}

enum FortyCharacterTargetScenario: String, CaseIterable, CustomStringConvertible, Sendable {
    case exactObject
    case symbolicReference

    var description: String { rawValue }

    func makeFixture() throws -> FortyCharacterTargetFixture {
        let fixture = try GitFixtureRepository.makeRepository(prefix: "agentstudio-git-40-character-target")
        let initialOID = try fixture.git.run("rev-parse", "HEAD").trimmed
        let target: GitRevisionTarget
        let expectedRevision: GitResolvedRevision

        switch self {
        case .exactObject:
            try fixture.write("object-target.txt", contents: "exact object target\n")
            try fixture.git.run("add", "object-target.txt")
            try fixture.git.run("commit", "-m", "create exact object target")
            let objectOID = try fixture.git.run("rev-parse", "HEAD").trimmed
            try fixture.git.run("update-ref", "refs/heads/\(objectOID)", initialOID)
            target = .named(objectOID)
            expectedRevision = GitResolvedRevision(oid: objectOID, shortName: nil)
        case .symbolicReference:
            let referenceName = String(repeating: "r", count: 40)
            try fixture.git.run("update-ref", "refs/heads/\(referenceName)", initialOID)
            target = .named(referenceName)
            expectedRevision = GitResolvedRevision(oid: initialOID, shortName: referenceName)
        }

        return FortyCharacterTargetFixture(
            fixture: fixture,
            request: GitContributionDiffRequest(repositoryPath: fixture.repositoryPath, target: target),
            expectedRevision: expectedRevision
        )
    }
}

struct FortyCharacterTargetFixture {
    let fixture: GitFixtureRepository
    let request: GitContributionDiffRequest
    let expectedRevision: GitResolvedRevision

    func remove() {
        fixture.remove()
    }
}

struct ContributionHistoryFixture {
    let fixture: GitFixtureRepository
    let request: GitContributionDiffRequest
    let targetOID: String
    let reviewedHeadOID: String
    let expectedBaseOID: String

    static func make(_ historyShape: ContributionHistoryShape) throws -> Self {
        let fixture = try GitFixtureRepository.makeRepository(
            prefix: "agentstudio-git-contribution-\(historyShape.rawValue)")
        let sharedBaseOID = try fixture.git.run("rev-parse", "HEAD").trimmed
        try fixture.git.run("checkout", "-b", "feature")
        try fixture.write("feature.txt", contents: "feature contribution\n")
        try fixture.git.run("add", "feature.txt")
        try fixture.git.run("commit", "-m", "feature contribution")
        let originalFeatureOID = try fixture.git.run("rev-parse", "HEAD").trimmed
        try fixture.git.run(
            "branch", "target", historyShape == .targetContainsHead ? originalFeatureOID : sharedBaseOID)
        try fixture.git.run("checkout", "target")
        try fixture.write("target-only.txt", contents: "target-only work\n")
        try fixture.git.run("add", "target-only.txt")
        try fixture.git.run("commit", "-m", "target-only contribution")
        let targetOID = try fixture.git.run("rev-parse", "HEAD").trimmed
        try fixture.git.run("checkout", "feature")

        let expectedBaseOID: String
        switch historyShape {
        case .diverged:
            expectedBaseOID = sharedBaseOID
        case .merged:
            try fixture.git.run("merge", "--no-ff", "target", "-m", "merge target")
            expectedBaseOID = targetOID
        case .rebased:
            try fixture.git.run("rebase", "target")
            expectedBaseOID = targetOID
        case .targetContainsHead:
            expectedBaseOID = originalFeatureOID
        }
        let reviewedHeadOID = try fixture.git.run("rev-parse", "HEAD").trimmed

        return Self(
            fixture: fixture,
            request: GitContributionDiffRequest(
                repositoryPath: fixture.repositoryPath,
                target: .named("refs/heads/target")
            ),
            targetOID: targetOID,
            reviewedHeadOID: reviewedHeadOID,
            expectedBaseOID: expectedBaseOID
        )
    }

    func addDirtyWorktreeChanges() throws {
        try fixture.write("staged.txt", contents: "staged work\n")
        try fixture.git.run("add", "staged.txt")
        try fixture.write("README.md", contents: "unstaged work\n")
        try fixture.write("untracked.txt", contents: "untracked work\n")
    }

    func advanceTargetOnly() throws -> String {
        try fixture.git.run("checkout", "target")
        try fixture.write("target-second.txt", contents: "later target work\n")
        try fixture.git.run("add", "target-second.txt")
        try fixture.git.run("commit", "-m", "advance target only")
        let targetOID = try fixture.git.run("rev-parse", "HEAD").trimmed
        try fixture.git.run("checkout", "feature")
        return targetOID
    }

    func remove() {
        fixture.remove()
    }
}

struct RenameDeleteBinaryFixture {
    let fixture: GitFixtureRepository
    let request: GitContributionDiffRequest

    static func make() throws -> Self {
        let fixture = try GitFixtureRepository.makeRepository(prefix: "agentstudio-git-contribution-file-kinds")
        try fixture.write("rename-source.txt", contents: "rename me\n")
        try fixture.write("delete-source.txt", contents: "delete me\n")
        try Data([0, 1, 2, 3, 255]).write(to: fixture.repositoryPath.appending(path: "binary.bin"))
        try fixture.git.run("add", ".")
        try fixture.git.run("commit", "-m", "seed file kinds")
        try fixture.git.run("branch", "target", "HEAD")
        try fixture.git.run("checkout", "-b", "feature")
        try fixture.git.run("mv", "rename-source.txt", "renamed.txt")
        try fixture.git.run("rm", "delete-source.txt")
        try Data([255, 3, 2, 1, 0]).write(to: fixture.repositoryPath.appending(path: "binary.bin"))
        try fixture.git.run("add", "binary.bin")

        return Self(
            fixture: fixture,
            request: GitContributionDiffRequest(
                repositoryPath: fixture.repositoryPath,
                target: .named("refs/heads/target")
            )
        )
    }

    func remove() {
        fixture.remove()
    }
}

struct SamePathOverlapFixture {
    let fixture: GitFixtureRepository
    let request: GitContributionDiffRequest
    let originalContentHash: String
    let recreatedContentHash: String

    static func make() throws -> Self {
        let fixture = try GitFixtureRepository.makeRepository(prefix: "agentstudio-git-same-path-overlap")
        try fixture.write("overlap.txt", contents: "original tracked content\n")
        try fixture.git.run("add", "overlap.txt")
        try fixture.git.run("commit", "-m", "seed overlap path")
        try fixture.git.run("branch", "target", "HEAD")
        let originalContentHash = try fixture.git.run("rev-parse", "HEAD:overlap.txt").trimmed
        try fixture.git.run("rm", "overlap.txt")
        try fixture.write("overlap.txt", contents: "recreated worktree content\n")
        let recreatedContentHash = try fixture.git.run(
            "hash-object", "--path=overlap.txt", "overlap.txt"
        ).trimmed

        return Self(
            fixture: fixture,
            request: GitContributionDiffRequest(
                repositoryPath: fixture.repositoryPath,
                target: .named("refs/heads/target")
            ),
            originalContentHash: originalContentHash,
            recreatedContentHash: recreatedContentHash
        )
    }

    func remove() {
        fixture.remove()
    }
}

struct UnrelatedHistoryFixture {
    let fixture: GitFixtureRepository
    let request: GitContributionDiffRequest
    let targetOID: String
    let reviewedHeadOID: String

    static func make() throws -> Self {
        let fixture = try GitFixtureRepository.makeRepository(prefix: "agentstudio-git-unrelated-history")
        let reviewedHeadOID = try fixture.git.run("rev-parse", "HEAD").trimmed
        let treeOID = try fixture.git.run("rev-parse", "HEAD^{tree}").trimmed
        let targetOID = try fixture.git.run("commit-tree", treeOID, "-m", "unrelated root").trimmed
        try fixture.git.run("update-ref", "refs/heads/target", targetOID)
        return Self(
            fixture: fixture,
            request: GitContributionDiffRequest(
                repositoryPath: fixture.repositoryPath,
                target: .named("refs/heads/target")
            ),
            targetOID: targetOID,
            reviewedHeadOID: reviewedHeadOID
        )
    }

    func remove() {
        fixture.remove()
    }
}

struct MissingAncestryFixture {
    let fixture: GitFixtureRepository
    let request: GitContributionDiffRequest
    let missingCommitOID: String

    static func make() throws -> Self {
        let fixture = try GitFixtureRepository.makeRepository(prefix: "agentstudio-git-missing-ancestry")
        try fixture.git.run("branch", "target", "HEAD")
        try fixture.git.run("checkout", "-b", "feature")
        try fixture.write("intermediate.txt", contents: "intermediate contribution\n")
        try fixture.git.run("add", "intermediate.txt")
        try fixture.git.run("commit", "-m", "intermediate contribution")
        let missingCommitOID = try fixture.git.run("rev-parse", "HEAD").trimmed
        try fixture.write("tip.txt", contents: "tip contribution\n")
        try fixture.git.run("add", "tip.txt")
        try fixture.git.run("commit", "-m", "tip contribution")
        try FileManager.default.removeItem(at: fixture.looseObjectPath(oid: missingCommitOID))

        return Self(
            fixture: fixture,
            request: GitContributionDiffRequest(
                repositoryPath: fixture.repositoryPath,
                target: .named("refs/heads/target")
            ),
            missingCommitOID: missingCommitOID
        )
    }

    func remove() {
        fixture.remove()
    }
}

struct MultipleBestMergeBasesFixture {
    let fixture: GitFixtureRepository
    let request: GitContributionDiffRequest
    let targetOID: String
    let reviewedHeadOID: String

    static func make() throws -> Self {
        let fixture = try GitFixtureRepository.makeRepository(prefix: "agentstudio-git-multiple-bases")
        let rootOID = try fixture.git.run("rev-parse", "HEAD").trimmed
        let treeOID = try fixture.git.run("rev-parse", "HEAD^{tree}").trimmed
        let sideAOID = try fixture.git.run("commit-tree", treeOID, "-p", rootOID, "-m", "side a").trimmed
        let sideBOID = try fixture.git.run("commit-tree", treeOID, "-p", rootOID, "-m", "side b").trimmed
        let targetOID = try fixture.git.run(
            "commit-tree", treeOID, "-p", sideAOID, "-p", sideBOID, "-m", "target merge"
        ).trimmed
        let reviewedHeadOID = try fixture.git.run(
            "commit-tree", treeOID, "-p", sideBOID, "-p", sideAOID, "-m", "reviewed merge"
        ).trimmed
        try fixture.git.run("update-ref", "refs/heads/target", targetOID)
        try fixture.git.run("update-ref", "refs/heads/feature", reviewedHeadOID)
        try fixture.git.run("checkout", "feature")
        return Self(
            fixture: fixture,
            request: GitContributionDiffRequest(
                repositoryPath: fixture.repositoryPath,
                target: .named("refs/heads/target")
            ),
            targetOID: targetOID,
            reviewedHeadOID: reviewedHeadOID
        )
    }

    func remove() {
        fixture.remove()
    }
}

extension String {
    var trimmed: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

extension GitFixtureRepository {
    func looseObjectPath(oid: String) -> URL {
        repositoryPath
            .appending(path: ".git/objects")
            .appending(path: String(oid.prefix(2)))
            .appending(path: String(oid.dropFirst(2)))
    }
}
