import AgentStudioGit
import Foundation
import Testing

@testable import AgentStudioGitLocal

@Suite("Git worktree fork eligibility integration", .serialized)
struct GitWorktreeForkEligibilityIntegrationTests {
    private static let iCloudDrive = FileManager.default.homeDirectoryForCurrentUser
        .appending(path: "Library/Mobile Documents/com~apple~CloudDocs")

    @Test("the query reports a repository on the data volume as available without mutating anything")
    func queryReportsDataVolumeRepositoryAvailable() async throws {
        // Arrange
        let fixture = try GitWorktreeForkFixture.make(prefix: "agentstudio-git-fork-query")
        defer { fixture.remove() }
        let statusBefore = try fixture.statusLines(at: fixture.source)

        // Act
        let eligibility = await LibGit2AgentStudioGitLocalClient().forkWorktreeEligibility(
            sourceWorktreePath: fixture.source,
            destinationPath: fixture.destination()
        )

        // Assert
        #expect(eligibility == .available)
        #expect(!GitWorktreeForkFileProbe.exists(fixture.destination()))
        #expect(try fixture.statusLines(at: fixture.source) == statusBefore)
        #expect(try fixture.branchNames() == ["refs/heads/main"])
    }

    @Test("the query and the fork reject the same ineligible host and volume facts before mutation")
    func queryAndForkRejectTheSameFacts() async throws {
        // Arrange
        let fixture = try GitWorktreeForkFixture.make(prefix: "agentstudio-git-fork-query-facts")
        defer { fixture.remove() }
        let sourceDevice = try #require(GitWorktreeForkFileProbe.info(fixture.source)).st_dev
        let sourcePath = try #require(realpath(fixture.source.path, nil))
        let canonicalSource = String(cString: sourcePath)
        free(sourcePath)
        func provider(
            operatingSystem: Int = 26,
            sourceFacts: WorktreeForkVolumeFacts? = nil,
            destinationFacts: WorktreeForkVolumeFacts? = nil
        ) -> WorktreeForkHostFactsProvider {
            let ordinary = WorktreeForkVolumeFacts(
                fileSystemTypeName: "apfs", deviceID: sourceDevice, supportsFileCloning: true,
                isFileProviderManaged: false)
            return WorktreeForkHostFactsProvider(
                operatingSystemMajorVersion: { operatingSystem },
                volumeFacts: { path in
                    path.path == canonicalSource ? sourceFacts ?? ordinary : destinationFacts ?? ordinary
                }
            )
        }
        let managed = WorktreeForkVolumeFacts(
            fileSystemTypeName: "apfs", deviceID: sourceDevice, supportsFileCloning: true,
            isFileProviderManaged: true)
        let otherDevice = WorktreeForkVolumeFacts(
            fileSystemTypeName: "apfs", deviceID: sourceDevice + 1, supportsFileCloning: true,
            isFileProviderManaged: false)
        let cases: [(WorktreeForkHostFactsProvider, GitWorktreeForkRejectionReason)] = [
            (provider(operatingSystem: 15), .unsupportedOperatingSystem),
            (provider(sourceFacts: managed), .fileProviderManagedLocation),
            (provider(destinationFacts: managed), .fileProviderManagedLocation),
            (provider(destinationFacts: otherDevice), .crossDevice),
        ]

        for (hostFacts, expected) in cases {
            let client = LibGit2AgentStudioGitLocalClient(
                worktreeForkWriter: LibGit2WorktreeForkWriter(hostFacts: hostFacts))

            // Act
            let eligibility = await client.forkWorktreeEligibility(
                sourceWorktreePath: fixture.source, destinationPath: fixture.destination())
            let forkFailure: GitWorktreeForkError?
            do {
                _ = try await client.forkWorktree(fixture.request())
                forkFailure = nil
            } catch {
                forkFailure = error
            }

            // Assert
            #expect(eligibility == .unavailable(expected))
            #expect(forkFailure == .rejected(reason: expected))
            #expect(!GitWorktreeForkFileProbe.exists(fixture.destination()))
            #expect(!GitWorktreeForkFileProbe.exists(fixture.linkedWorktreeAdministration()))
            #expect(try fixture.branchNames() == ["refs/heads/main"])
        }
    }

    @Test("the query reports missing destination parents and non-directory sources")
    func queryReportsMissingParentsAndInvalidSources() async throws {
        // Arrange
        let fixture = try GitWorktreeForkFixture.make(prefix: "agentstudio-git-fork-query-paths")
        defer { fixture.remove() }
        let client = LibGit2AgentStudioGitLocalClient()

        // Act
        let missingParent = await client.forkWorktreeEligibility(
            sourceWorktreePath: fixture.source, destinationPath: fixture.destination("missing/child"))
        let fileSource = await client.forkWorktreeEligibility(
            sourceWorktreePath: fixture.source.appending(path: "README.md"), destinationPath: fixture.destination())

        // Assert
        #expect(missingParent == .unavailable(.destinationParentMissing))
        #expect(fileSource == .unavailable(.sourceNotWorktreeRoot))
    }

    @Test(
        "an iCloud Drive location is reported as File Provider managed without writing there",
        .enabled(if: FileManager.default.fileExists(atPath: iCloudDrive.path))
    )
    func iCloudDriveLocationIsReportedAsFileProviderManaged() async {
        // Act
        let eligibility = await LibGit2AgentStudioGitLocalClient().forkWorktreeEligibility(
            sourceWorktreePath: Self.iCloudDrive,
            destinationPath: Self.iCloudDrive.appending(path: "agentstudio-fork-never-created-\(UUID().uuidString)")
        )

        // Assert
        #expect(eligibility == .unavailable(.fileProviderManagedLocation))
    }
}
