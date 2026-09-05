import Foundation
import Testing

@Suite("AgentStudio real-consumer compatibility gate")
struct AgentStudioCompatibilityGateTests {
    @Test("gate runs the ordinary AgentStudio Swift task with every SDK consumer suite")
    func gateRunsOrdinaryAgentStudioSwiftTaskWithEverySDKConsumerSuite() throws {
        let fixture = try AgentStudioCompatibilityGateFixture.make()
        defer { fixture.remove() }

        let result = try fixture.runGate()

        #expect(result.exitCode == 0)
        let optionalRecordedWorkingDirectory = try fixture.recordedMiseWorkingDirectory()
        let recordedWorkingDirectory = try #require(optionalRecordedWorkingDirectory)
        #expect(
            URL(fileURLWithPath: recordedWorkingDirectory).resolvingSymlinksInPath()
                == fixture.agentStudioRoot.resolvingSymlinksInPath()
        )
        let recordedMiseArguments = try fixture.recordedMiseArguments()
        #expect(
            recordedMiseArguments == [
                "run",
                "test:swift",
                "--",
                "--filter",
                AgentStudioCompatibilityGateFixture.consumerSuiteFilter,
            ])
        #expect(!recordedMiseArguments.contains("--skip-deps"))
    }

    @Test("gate rejects an AgentStudio manifest that does not declare the SDK candidate")
    func gateRejectsMismatchedAgentStudioManifestRevision() throws {
        let fixture = try AgentStudioCompatibilityGateFixture.make(
            configuration: AgentStudioCompatibilityGateFixture.Configuration(
                manifestRevision: AgentStudioCompatibilityGateFixture.otherRevision
            )
        )
        defer { fixture.remove() }

        let result = try fixture.runGate()

        #expect(result.exitCode == 2)
        #expect(result.combinedOutput.contains("Package.swift does not declare the SDK candidate revision"))
        #expect(try fixture.recordedMiseArguments().isEmpty)
    }

    @Test("gate rejects an AgentStudio resolution that does not pin the SDK candidate")
    func gateRejectsMismatchedAgentStudioResolvedRevision() throws {
        let fixture = try AgentStudioCompatibilityGateFixture.make(
            configuration: AgentStudioCompatibilityGateFixture.Configuration(
                resolvedRevision: AgentStudioCompatibilityGateFixture.otherRevision
            )
        )
        defer { fixture.remove() }

        let result = try fixture.runGate()

        #expect(result.exitCode == 2)
        #expect(result.combinedOutput.contains("Package.resolved does not pin the SDK candidate revision"))
        #expect(try fixture.recordedMiseArguments().isEmpty)
    }

    @Test("gate rejects dirty SDK production sources before invoking AgentStudio")
    func gateRejectsDirtySDKProductionSources() throws {
        let fixture = try AgentStudioCompatibilityGateFixture.make(
            configuration: AgentStudioCompatibilityGateFixture.Configuration(
                dirtySDKProductionPath: "Sources/AgentStudioGit/Changed.swift"
            )
        )
        defer { fixture.remove() }

        let result = try fixture.runGate()

        #expect(result.exitCode == 2)
        #expect(result.combinedOutput.contains("SDK candidate has production changes"))
        #expect(try fixture.recordedMiseArguments().isEmpty)
    }

    @Test("gate propagates the AgentStudio task failure")
    func gatePropagatesAgentStudioTaskFailure() throws {
        let fixture = try AgentStudioCompatibilityGateFixture.make(
            configuration: AgentStudioCompatibilityGateFixture.Configuration(miseExitCode: 23)
        )
        defer { fixture.remove() }

        let result = try fixture.runGate()

        #expect(result.exitCode == 23)
        #expect(try fixture.recordedMiseArguments().contains("test:swift"))
    }

    @Test("gate rejects resolution drift caused while the AgentStudio task runs")
    func gateRejectsPostTaskResolutionDrift() throws {
        let fixture = try AgentStudioCompatibilityGateFixture.make(
            configuration: AgentStudioCompatibilityGateFixture.Configuration(
                postTaskResolvedRevision: AgentStudioCompatibilityGateFixture.otherRevision
            )
        )
        defer { fixture.remove() }

        let result = try fixture.runGate()

        #expect(result.exitCode == 2)
        #expect(result.combinedOutput.contains("Package.resolved changed away from the SDK candidate revision"))
        #expect(try fixture.recordedMiseArguments().contains("test:swift"))
    }

    @Test("gate rejects a successful AgentStudio task that executes zero Swift Testing tests")
    func gateRejectsSuccessfulAgentStudioTaskWithZeroSwiftTestingTests() throws {
        let fixture = try AgentStudioCompatibilityGateFixture.make(
            configuration: AgentStudioCompatibilityGateFixture.Configuration(
                swiftTestingTerminalOutput: "Test run with 0 tests in 0 suites passed after 0.001 seconds."
            )
        )
        defer { fixture.remove() }

        let result = try fixture.runGate()

        #expect(result.exitCode == 2)
        #expect(result.combinedOutput.contains("did not report a positive Swift Testing terminal count"))
        #expect(try fixture.recordedMiseArguments().contains("test:swift"))
    }

    @Test("gate rejects a configured path that is not an AgentStudio checkout")
    func gateRejectsInvalidConfiguredCheckout() throws {
        let fixture = try AgentStudioCompatibilityGateFixture.make()
        defer { fixture.remove() }
        let missingCheckout = fixture.root.appending(path: "missing-agent-studio")

        let result = try fixture.runGate(agentStudioPath: missingCheckout)

        #expect(result.exitCode == 2)
        #expect(result.combinedOutput.contains("does not look like an AgentStudio checkout"))
        #expect(try fixture.recordedMiseArguments().isEmpty)
    }
}

private struct AgentStudioCompatibilityGateFixture {
    static let candidateRevision = String(repeating: "a", count: 40)
    static let otherRevision = String(repeating: "b", count: 40)
    static let consumerSuiteFilter =
        "AgentStudioGitWorkingTreeStatusProviderTests|BridgeGitReviewSourceProviderTests|"
        + "BridgeGitReviewContributionSourceProviderTests|BridgeGitReviewBoundaryTests|"
        + "BridgeReviewGitRefreshScopeTests|BridgeReviewDeltaBuilderTests|"
        + "WorktreeAnnotationGitSourceMaterialProviderTests|" + "WorktreeAnnotationSourceCaptureReviewProportionalTests"

    struct Configuration {
        let manifestRevision: String
        let resolvedRevision: String
        let dirtySDKProductionPath: String?
        let miseExitCode: Int32
        let postTaskResolvedRevision: String?
        let swiftTestingTerminalOutput: String

        init(
            manifestRevision: String = AgentStudioCompatibilityGateFixture.candidateRevision,
            resolvedRevision: String = AgentStudioCompatibilityGateFixture.candidateRevision,
            dirtySDKProductionPath: String? = nil,
            miseExitCode: Int32 = 0,
            postTaskResolvedRevision: String? = nil,
            swiftTestingTerminalOutput: String = "Test run with 1 test in 1 suite passed after 0.001 seconds."
        ) {
            self.manifestRevision = manifestRevision
            self.resolvedRevision = resolvedRevision
            self.dirtySDKProductionPath = dirtySDKProductionPath
            self.miseExitCode = miseExitCode
            self.postTaskResolvedRevision = postTaskResolvedRevision
            self.swiftTestingTerminalOutput = swiftTestingTerminalOutput
        }
    }

    let root: URL
    let sdkRoot: URL
    let agentStudioRoot: URL
    let fakeBinRoot: URL
    let miseArgumentsURL: URL
    let miseWorkingDirectoryURL: URL

    static func make(configuration: Configuration = Configuration()) throws -> Self {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appending(
            path: "agentstudio-real-consumer-gate-\(UUID().uuidString)"
        )
        let sdkRoot = root.appending(path: "agentstudio-git")
        let agentStudioRoot = root.appending(path: "agent-studio")
        let fakeBinRoot = root.appending(path: "bin")
        let miseArgumentsURL = root.appending(path: "mise-arguments.txt")
        let miseWorkingDirectoryURL = root.appending(path: "mise-working-directory.txt")
        try fileManager.createDirectory(
            at: sdkRoot.appending(path: "scripts"),
            withIntermediateDirectories: true
        )
        try fileManager.createDirectory(
            at: sdkRoot.appending(path: "Sources"),
            withIntermediateDirectories: true
        )
        try fileManager.createDirectory(
            at: agentStudioRoot.appending(path: "Sources/AgentStudio"),
            withIntermediateDirectories: true
        )
        try fileManager.createDirectory(at: fakeBinRoot, withIntermediateDirectories: true)

        try fileManager.copyItem(
            at: URL(fileURLWithPath: "scripts/verify-agentstudio-compatibility.sh"),
            to: sdkRoot.appending(path: "scripts/verify-agentstudio-compatibility.sh")
        )
        try manifestSource(revision: configuration.manifestRevision).write(
            to: agentStudioRoot.appending(path: "Package.swift"),
            atomically: true,
            encoding: .utf8
        )
        try resolvedSource(revision: configuration.resolvedRevision).write(
            to: agentStudioRoot.appending(path: "Package.resolved"),
            atomically: true,
            encoding: .utf8
        )
        try fakeGitSource(dirtySDKProductionPath: configuration.dirtySDKProductionPath).write(
            to: fakeBinRoot.appending(path: "git"),
            atomically: true,
            encoding: .utf8
        )
        try fakeMiseSource().write(
            to: fakeBinRoot.appending(path: "mise"),
            atomically: true,
            encoding: .utf8
        )
        try fileManager.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: fakeBinRoot.appending(path: "git").path
        )
        try fileManager.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: fakeBinRoot.appending(path: "mise").path
        )

        let fixture = Self(
            root: root,
            sdkRoot: sdkRoot,
            agentStudioRoot: agentStudioRoot,
            fakeBinRoot: fakeBinRoot,
            miseArgumentsURL: miseArgumentsURL,
            miseWorkingDirectoryURL: miseWorkingDirectoryURL
        )
        try fixture.writeConfiguration(configuration)
        return fixture
    }

    func runGate(agentStudioPath: URL? = nil) throws -> CapturedCompatibilityGateResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["bash", sdkRoot.appending(path: "scripts/verify-agentstudio-compatibility.sh").path]
        process.currentDirectoryURL = sdkRoot
        var environment = ProcessInfo.processInfo.environment
        environment["AGENTSTUDIO_GIT_AGENTSTUDIO_PATH"] = (agentStudioPath ?? agentStudioRoot).path
        environment["PATH"] = "\(fakeBinRoot.path):\(environment["PATH"] ?? "")"
        environment["AGENTSTUDIO_GATE_CANDIDATE_REVISION"] = Self.candidateRevision
        environment["AGENTSTUDIO_GATE_MISE_ARGUMENTS"] = miseArgumentsURL.path
        environment["AGENTSTUDIO_GATE_MISE_WORKING_DIRECTORY"] = miseWorkingDirectoryURL.path
        environment["AGENTSTUDIO_GATE_PACKAGE_RESOLVED"] = agentStudioRoot.appending(path: "Package.resolved").path
        process.environment = environment

        let standardOutput = Pipe()
        let standardError = Pipe()
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = standardOutput
        process.standardError = standardError
        try process.run()
        process.waitUntilExit()

        return CapturedCompatibilityGateResult(
            exitCode: process.terminationStatus,
            stdout: String(data: standardOutput.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "",
            stderr: String(data: standardError.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        )
    }

    func recordedMiseArguments() throws -> [String] {
        guard FileManager.default.fileExists(atPath: miseArgumentsURL.path) else {
            return []
        }
        return try String(contentsOf: miseArgumentsURL, encoding: .utf8)
            .split(separator: "\n")
            .map(String.init)
    }

    func recordedMiseWorkingDirectory() throws -> String? {
        guard FileManager.default.fileExists(atPath: miseWorkingDirectoryURL.path) else {
            return nil
        }
        return try String(contentsOf: miseWorkingDirectoryURL, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }

    private func writeConfiguration(_ configuration: Configuration) throws {
        try "\(configuration.miseExitCode)\n".write(
            to: root.appending(path: "mise-exit-code.txt"),
            atomically: true,
            encoding: .utf8
        )
        try (configuration.postTaskResolvedRevision ?? "").write(
            to: root.appending(path: "post-task-revision.txt"),
            atomically: true,
            encoding: .utf8
        )
        try configuration.swiftTestingTerminalOutput.write(
            to: root.appending(path: "swift-testing-output.txt"),
            atomically: true,
            encoding: .utf8
        )
    }

    private static func manifestSource(revision: String) -> String {
        """
        // swift-tools-version:6.2
        import PackageDescription
        let package = Package(
            name: "AgentStudio",
            dependencies: [
                .package(
                    url: "https://github.com/ShravanSunder/agentstudio-git.git",
                    revision: "\(revision)"
                ),
            ]
        )
        """
    }

    private static func resolvedSource(revision: String) -> String {
        """
        {
          "pins" : [
            {
              "identity" : "agentstudio-git",
              "kind" : "remoteSourceControl",
              "location" : "https://github.com/ShravanSunder/agentstudio-git.git",
              "state" : {
                "revision" : "\(revision)"
              }
            }
          ],
          "version" : 3
        }
        """
    }

    private static func fakeGitSource(dirtySDKProductionPath: String?) -> String {
        """
        #!/bin/sh
        if [ "$3" = "rev-parse" ] && [ "$4" = "HEAD" ]; then
          printf '%s\n' "$AGENTSTUDIO_GATE_CANDIDATE_REVISION"
          exit 0
        fi
        if [ "$3" = "status" ]; then
          printf '%s\n' "\(dirtySDKProductionPath ?? "")"
          exit 0
        fi
        exit 64
        """
    }

    private static func fakeMiseSource() -> String {
        """
        #!/bin/sh
        printf '%s\n' "$@" > "$AGENTSTUDIO_GATE_MISE_ARGUMENTS"
        pwd -P > "$AGENTSTUDIO_GATE_MISE_WORKING_DIRECTORY"
        fixture_root="$(dirname "$AGENTSTUDIO_GATE_MISE_ARGUMENTS")"
        post_task_revision="$(cat "$fixture_root/post-task-revision.txt")"
        if [ -n "$post_task_revision" ]; then
          sed "s/[a-f0-9]\\{40\\}/$post_task_revision/g" \
            "$AGENTSTUDIO_GATE_PACKAGE_RESOLVED" > "$AGENTSTUDIO_GATE_PACKAGE_RESOLVED.tmp"
          mv "$AGENTSTUDIO_GATE_PACKAGE_RESOLVED.tmp" "$AGENTSTUDIO_GATE_PACKAGE_RESOLVED"
        fi
        cat "$fixture_root/swift-testing-output.txt"
        exit "$(cat "$fixture_root/mise-exit-code.txt")"
        """
    }
}

private struct CapturedCompatibilityGateResult {
    let exitCode: Int32
    let stdout: String
    let stderr: String

    var combinedOutput: String {
        "\(stdout)\n\(stderr)"
    }
}
