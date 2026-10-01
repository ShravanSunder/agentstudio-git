import AgentStudioGitContracts
import AgentStudioGitLockSupport
import Foundation
import Testing

@Suite("Local Git lock diagnostic classification")
struct GitLockDiagnosticTests {
    @Test("local reference lock diagnostics preserve quoted Unicode paths")
    func localReferenceLockDiagnosticPreservesQuotedUnicodePath() throws {
        let fixture = try GitLockDiagnosticFixture.make()
        defer { fixture.remove() }
        let lockPath = fixture.commonDirectory.appending(path: "refs/remotes/origin/feature's café.lock")
        try FileManager.default.createDirectory(
            at: lockPath.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data().write(to: lockPath)
        let stderr =
            "error: cannot lock ref 'refs/remotes/origin/feature': Unable to create '\(lockPath.path)': File exists.\n"

        let error = GitLockDiagnosticClassifier.failure(
            stderr: stderr,
            repositoryPath: fixture.repositoryPath,
            gitDirectory: fixture.gitDirectory,
            commonDirectory: fixture.commonDirectory
        )

        #expect(
            error
                == .lockHeld(
                    GitLockFact(
                        path: lockPath,
                        resource: .reference(name: "refs/remotes/origin/feature's café")
                    )
                )
        )
    }

    @Test("local index lock diagnostics identify the requested worktree")
    func localIndexLockDiagnosticIdentifiesRequestedWorktree() throws {
        let fixture = try GitLockDiagnosticFixture.make()
        defer { fixture.remove() }
        let lockPath = fixture.gitDirectory.appending(path: "index.lock")
        try Data().write(to: lockPath)
        let stderr = "fatal: Unable to create '\(lockPath.path)': File exists.\n"

        let error = GitLockDiagnosticClassifier.failure(
            stderr: stderr,
            repositoryPath: fixture.repositoryPath,
            gitDirectory: fixture.gitDirectory,
            commonDirectory: fixture.commonDirectory
        )

        #expect(
            error
                == .lockHeld(
                    GitLockFact(path: lockPath, resource: .index(worktreePath: fixture.repositoryPath))
                )
        )
    }

    @Test("remote-looking lock diagnostics never identify a local lock")
    func remoteLookingLockDiagnosticNeverIdentifiesLocalLock() throws {
        let fixture = try GitLockDiagnosticFixture.make()
        defer { fixture.remove() }
        let lockPath = fixture.commonDirectory.appending(path: "refs/remotes/origin/main.lock")
        try FileManager.default.createDirectory(
            at: lockPath.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data().write(to: lockPath)
        let stderr = "remote: Unable to create '\(lockPath.path)': File exists.\n"

        let error = GitLockDiagnosticClassifier.failure(
            stderr: stderr,
            repositoryPath: fixture.repositoryPath,
            gitDirectory: fixture.gitDirectory,
            commonDirectory: fixture.commonDirectory
        )

        #expect(error == nil)
    }

    @Test("a lock path outside repository Git directories is rejected")
    func lockPathOutsideRepositoryGitDirectoriesIsRejected() throws {
        let fixture = try GitLockDiagnosticFixture.make()
        defer { fixture.remove() }
        let outsideLockPath = fixture.root.appending(path: "unrelated.lock")
        try Data().write(to: outsideLockPath)
        let stderr = "fatal: Unable to create '\(outsideLockPath.path)': File exists.\n"

        let error = GitLockDiagnosticClassifier.failure(
            stderr: stderr,
            repositoryPath: fixture.repositoryPath,
            gitDirectory: fixture.gitDirectory,
            commonDirectory: fixture.commonDirectory
        )

        #expect(error == nil)
    }

    @Test("a recognized lock diagnostic with an unavailable file is unidentified")
    func recognizedLockDiagnosticWithMissingFileIsUnidentified() throws {
        let fixture = try GitLockDiagnosticFixture.make()
        defer { fixture.remove() }
        let lockPath = fixture.commonDirectory.appending(path: "refs/heads/moved.lock")
        let stderr = "fatal: Unable to create '\(lockPath.path)': File exists.\n"

        let error = GitLockDiagnosticClassifier.failure(
            stderr: stderr,
            repositoryPath: fixture.repositoryPath,
            gitDirectory: fixture.gitDirectory,
            commonDirectory: fixture.commonDirectory
        )

        #expect(error == .lockUnidentified(.reference(name: "refs/heads/moved")))
    }
}

private struct GitLockDiagnosticFixture {
    let root: URL
    let repositoryPath: URL
    let gitDirectory: URL
    let commonDirectory: URL

    static func make() throws -> Self {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "agentstudio-git-lock space ' café-\(UUID().uuidString)")
        let repositoryPath = root.appending(path: "working tree")
        let gitDirectory = root.appending(path: "administration/worktree 'id")
        let commonDirectory = root.appending(path: "administration/common")
        try FileManager.default.createDirectory(at: repositoryPath, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: gitDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: commonDirectory, withIntermediateDirectories: true)
        return Self(
            root: root,
            repositoryPath: repositoryPath,
            gitDirectory: gitDirectory,
            commonDirectory: commonDirectory
        )
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}
