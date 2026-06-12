import AgentStudioGit
import Foundation
import Testing

@Suite("Git public contracts")
struct GitPublicContractTests {
    @Test("status snapshots round-trip with tri-state origin resolution")
    func statusSnapshotRoundTripsWithOriginResolution() throws {
        let snapshot = GitStatusSnapshot(
            repositoryRoot: URL(fileURLWithPath: "/tmp/repo"),
            worktreePath: URL(fileURLWithPath: "/tmp/repo-linked"),
            generatedAtUnixMilliseconds: 1_781_053_200_000,
            head: GitHeadSnapshot(kind: .branch, oid: "abc123", shortName: "main"),
            originResolution: .resolved(
                GitRemoteSnapshot(
                    name: "origin",
                    url: URL(string: "https://github.com/example/repo.git")!,
                    rawURL: "https://github.com/example/repo.git"
                )
            ),
            summary: GitStatusSummary(
                changedFileCount: 1,
                stagedFileCount: 1,
                unstagedFileCount: 1,
                untrackedFileCount: 0,
                ignoredFileCount: 0,
                linesAdded: 12,
                linesDeleted: 3,
                aheadCount: 2,
                behindCount: 1,
                hasUpstream: true
            ),
            entries: [
                GitStatusEntry(
                    path: "Sources/App.swift",
                    previousPath: nil,
                    indexState: .modified,
                    worktreeState: .modified,
                    ignored: false,
                    untracked: false
                )
            ]
        )

        let data = try JSONEncoder().encode(snapshot)
        let decodedSnapshot = try JSONDecoder().decode(GitStatusSnapshot.self, from: data)

        #expect(decodedSnapshot == snapshot)
        #expect(decodedSnapshot.originResolution == snapshot.originResolution)
    }

    @Test("diff files carry stable file identity and honest content hashes")
    func diffFileCarriesStableIdentityAndContentHashes() throws {
        let diffFile = GitDiffFile(
            fileId: "sha1:old/path.swift->new/path.swift",
            path: "new/path.swift",
            previousPath: "old/path.swift",
            changeKind: .renamed,
            oldContentHash: "old-blob",
            newContentHash: "new-blob",
            contentHashAlgorithm: "git-blob-sha1",
            additions: 7,
            deletions: 2,
            isBinary: false,
            sizeBytes: 128
        )

        let data = try JSONEncoder().encode(diffFile)
        let decodedFile = try JSONDecoder().decode(GitDiffFile.self, from: data)

        #expect(decodedFile == diffFile)
        #expect(decodedFile.fileId == "sha1:old/path.swift->new/path.swift")
        #expect(decodedFile.contentHashAlgorithm == "git-blob-sha1")
    }

    @Test("URL request fields encode as strings")
    func urlRequestFieldsEncodeAsStrings() throws {
        let request = GitCloneRequest(
            remoteURL: URL(string: "ssh://git@example.com/org/repo.git")!,
            destinationPath: URL(fileURLWithPath: "/tmp/checkout"),
            checkoutBranch: "main"
        )

        let jsonObject = try JSONSerialization.jsonObject(with: JSONEncoder().encode(request))
        let dictionary = try #require(jsonObject as? [String: Any])

        #expect(dictionary["remoteURL"] as? String == "ssh://git@example.com/org/repo.git")
        #expect(dictionary["destinationPath"] as? String == "file:///tmp/checkout")
    }
}
