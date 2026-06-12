import Foundation
import Testing

@Suite("libgit2 packaging scripts")
struct LibGit2PackagingScriptTests {
    @Test("build script creates local-only importable XCFramework")
    func buildScriptCreatesLocalOnlyImportableXCFramework() throws {
        let contents = try readFile("scripts/build-libgit2-xcframework.sh")

        #expect(contents.contains("-DBUILD_SHARED_LIBS=OFF"))
        #expect(contents.contains("-DBUILD_TESTS=OFF"))
        #expect(contents.contains("-DBUILD_CLI=OFF"))
        #expect(contents.contains("-DBUILD_EXAMPLES=OFF"))
        #expect(contents.contains("-DUSE_SSH=OFF"))
        #expect(contents.contains("-DUSE_HTTP=OFF"))
        #expect(contents.contains("-DUSE_HTTPS=OFF"))
        #expect(contents.contains("-DUSE_AUTH_NEGOTIATE=OFF"))
        #expect(contents.contains("for target_arch in arm64 x86_64"))
        #expect(contents.contains("-DCMAKE_OSX_ARCHITECTURES=\"$target_arch\""))
        #expect(contents.contains("lipo -create"))
        #expect(contents.contains("module.modulemap"))
        #expect(contents.contains("umbrella header \"git2.h\""))
        #expect(contents.contains("xcodebuild -create-xcframework"))
        #expect(contents.contains("-headers"))
    }

    @Test("package supports local and distributable libgit2 binary targets")
    func packageSupportsLocalAndDistributableLibGit2BinaryTargets() throws {
        let packageContents = try readFile("Package.swift")
        let canaryContents = try readFile("Sources/AgentStudioGitLocal/LibGit2ImportCanary.swift")

        #expect(packageContents.contains(".binaryTarget("))
        #expect(packageContents.contains("name: \"CLibGit2Local\""))
        #expect(packageContents.contains("path: \"Artifacts/CLibGit2Local.xcframework\""))
        #expect(packageContents.contains("AGENTSTUDIO_GIT_LIBGIT2_BINARY_URL"))
        #expect(packageContents.contains("AGENTSTUDIO_GIT_LIBGIT2_BINARY_CHECKSUM"))
        #expect(packageContents.contains("url: binaryURL"))
        #expect(packageContents.contains("checksum: binaryChecksum"))
        #expect(packageContents.contains(".linkedLibrary(\"z\")"))
        #expect(packageContents.contains(".linkedLibrary(\"iconv\")"))
        #expect(canaryContents.contains("import CLibGit2Local"))
        #expect(canaryContents.contains("git_libgit2_version"))
    }

    @Test("consumer verification imports public SDK products without running repo mise tasks")
    func consumerVerificationImportsPublicSDKProductsWithoutRunningRepoMiseTasks() throws {
        let contents = try readFile("scripts/verify-package-consumer.sh")

        #expect(contents.contains("import AgentStudioGit"))
        #expect(contents.contains("import AgentStudioGitContracts"))
        #expect(contents.contains("import AgentStudioGitLocal"))
        #expect(contents.contains("import AgentStudioGitRemote"))
        #expect(contents.contains(".product(name: \"AgentStudioGit\""))
        #expect(contents.contains(".product(name: \"AgentStudioGitContracts\""))
        #expect(contents.contains(".package(path:"))
        #expect(contents.contains(".product(name: \"AgentStudioGitRemote\""))
        #expect(contents.contains("swift run --package-path"))
        #expect(contents.contains("env -u AGENTSTUDIO_GIT_LIBGIT2_BINARY_URL"))
        #expect(contents.contains("-u AGENTSTUDIO_GIT_LIBGIT2_BINARY_CHECKSUM"))
        #expect(contents.contains("AGENTSTUDIO_GIT_LIBGIT2_BINARY_URL"))
        #expect(contents.contains("AGENTSTUDIO_GIT_LIBGIT2_BINARY_CHECKSUM"))
        #expect(contents.contains("swift package dump-package"))
        #expect(contents.contains("CLibGit2Local.xcframework.zip.checksum"))
        #expect(!contents.contains("mise run"))
    }

    @Test("check workflow runs sanitizer and consumer gates")
    func checkWorkflowRunsSanitizerAndConsumerGates() throws {
        let contents = try readFile(".github/workflows/check.yml")

        #expect(contents.contains("runs-on: macos-26"))
        #expect(contents.contains("mise run check"))
        #expect(contents.contains("mise run test-asan"))
        #expect(contents.contains("mise run test-tsan"))
        #expect(contents.contains("bash scripts/verify-package-consumer.sh"))
        #expect(contents.contains("AgentStudio compatibility requires AGENTSTUDIO_GIT_AGENTSTUDIO_PATH"))
        #expect(contents.contains("bash scripts/verify-agentstudio-compatibility.sh"))
    }

    @Test("artifact workflow runs on Swift 6.2 capable macOS image")
    func artifactWorkflowRunsOnSwift62CapableMacOSImage() throws {
        let contents = try readFile(".github/workflows/libgit2-artifact.yml")

        #expect(contents.contains("runs-on: macos-26"))
    }

    @Test("live remote auth verifier requires HTTPS and SSH smoke remotes")
    func liveRemoteAuthVerifierRequiresHTTPSAndSSHSmokeRemotes() throws {
        let scriptContents = try readFile("scripts/verify-live-remote-auth.sh")
        let miseContents = try readFile(".mise.toml")
        let remoteTestContents = try readFile("Tests/AgentStudioGitTests/Remote/SystemGitRemoteClientTests.swift")

        #expect(scriptContents.contains("AGENTSTUDIO_GIT_LIVE_HTTPS_REMOTE_URL"))
        #expect(scriptContents.contains("AGENTSTUDIO_GIT_LIVE_SSH_REMOTE_URL"))
        #expect(scriptContents.contains("AGENTSTUDIO_GIT_LIVE_REMOTE_AUTH_SMOKE=1"))
        #expect(scriptContents.contains("AGENTSTUDIO_GIT_LIVE_REMOTE_AUTH_LABEL"))
        #expect(scriptContents.contains("AGENTSTUDIO_GIT_LIVE_REMOTE_AUTH_PROTOCOL"))
        #expect(scriptContents.contains("env -u AGENTSTUDIO_GIT_LIVE_REMOTE_SMOKE"))
        #expect(scriptContents.contains("-u AGENTSTUDIO_GIT_LIVE_REMOTE_URL"))
        #expect(scriptContents.contains("require_remote_protocol"))
        #expect(scriptContents.contains("expected https remote URL"))
        #expect(scriptContents.contains("expected ssh remote URL"))
        #expect(scriptContents.contains("SystemGitRemoteClientTests"))
        #expect(scriptContents.contains("agentstudio-git-live-smoke"))
        #expect(scriptContents.contains("value not printed"))
        #expect(!scriptContents.contains("remote: $remote_url"))
        #expect(remoteTestContents.contains(".enabled("))
        #expect(remoteTestContents.contains("AGENTSTUDIO_GIT_LIVE_REMOTE_AUTH_PROTOCOL"))
        #expect(remoteTestContents.contains("git.run(\"add\", \"-f\", markerPath)"))
        #expect(miseContents.contains("[tasks.verify-live-remote-auth]"))
        #expect(miseContents.contains("bash scripts/verify-live-remote-auth.sh"))
    }

    @Test("hosted artifact verifier proves release binary target download")
    func hostedArtifactVerifierProvesReleaseBinaryTargetDownload() throws {
        let scriptContents = try readFile("scripts/verify-hosted-libgit2-artifact.sh")
        let miseContents = try readFile(".mise.toml")
        let guideContents = try readFile("docs/guides/agentstudio-consumption.md")

        #expect(scriptContents.contains("AGENTSTUDIO_GIT_LIBGIT2_BINARY_URL"))
        #expect(scriptContents.contains("AGENTSTUDIO_GIT_LIBGIT2_BINARY_CHECKSUM"))
        #expect(scriptContents.contains("must be an https URL"))
        #expect(scriptContents.contains(".package(path:"))
        #expect(scriptContents.contains("import AgentStudioGitLocal"))
        #expect(scriptContents.contains("LibGit2ImportCanary.version()"))
        #expect(scriptContents.contains("expectedLibGit2MajorVersion = 1"))
        #expect(scriptContents.contains("expectedLibGit2MinorVersion = 9"))
        #expect(scriptContents.contains("expectedLibGit2RevisionVersion = 4"))
        #expect(scriptContents.contains("swift run"))
        #expect(scriptContents.contains("--package-path"))
        #expect(scriptContents.contains("--cache-path"))
        #expect(!scriptContents.contains("mise run"))
        #expect(miseContents.contains("[tasks.verify-hosted-libgit2-artifact]"))
        #expect(miseContents.contains("bash scripts/verify-hosted-libgit2-artifact.sh"))
        #expect(guideContents.contains("verify-hosted-libgit2-artifact.sh"))
        #expect(guideContents.contains("AGENTSTUDIO_GIT_LIBGIT2_BINARY_URL"))
    }

    @Test("hosted artifact verifier validates public inputs before SwiftPM")
    func hostedArtifactVerifierValidatesPublicInputsBeforeSwiftPM() throws {
        let fakeSwift = try FakeSwiftExecutable()
        let checksum = String(repeating: "a", count: 64)

        let queryResult = try runHostedArtifactVerifier(
            environment: [
                "AGENTSTUDIO_GIT_LIBGIT2_BINARY_URL":
                    "https://example.com/CLibGit2Local.xcframework.zip?token=secret",
                "AGENTSTUDIO_GIT_LIBGIT2_BINARY_CHECKSUM": checksum,
            ],
            fakeSwift: fakeSwift
        )

        #expect(queryResult.exitCode == 2)
        #expect(!queryResult.combinedOutput.contains("token=secret"))
        #expect(try fakeSwift.recordedArguments().isEmpty)

        let loopbackResult = try runHostedArtifactVerifier(
            environment: [
                "AGENTSTUDIO_GIT_LIBGIT2_BINARY_URL": "https://127.0.0.1/CLibGit2Local.xcframework.zip",
                "AGENTSTUDIO_GIT_LIBGIT2_BINARY_CHECKSUM": checksum,
            ],
            fakeSwift: fakeSwift
        )

        #expect(loopbackResult.exitCode == 2)
        #expect(try fakeSwift.recordedArguments().isEmpty)

        let checksumResult = try runHostedArtifactVerifier(
            environment: [
                "AGENTSTUDIO_GIT_LIBGIT2_BINARY_URL": "https://example.com/CLibGit2Local.xcframework.zip",
                "AGENTSTUDIO_GIT_LIBGIT2_BINARY_CHECKSUM": "not-a-checksum",
            ],
            fakeSwift: fakeSwift
        )

        #expect(checksumResult.exitCode == 2)
        #expect(try fakeSwift.recordedArguments().isEmpty)
    }

    @Test("hosted artifact verifier isolates cache and redacts SwiftPM output")
    func hostedArtifactVerifierIsolatesCacheAndRedactsSwiftPMOutput() throws {
        let fakeSwift = try FakeSwiftExecutable()
        let artifactURL = "https://example.com/signed/path-token-123/CLibGit2Local.xcframework.zip"

        let result = try runHostedArtifactVerifier(
            environment: [
                "AGENTSTUDIO_GIT_LIBGIT2_BINARY_URL": artifactURL,
                "AGENTSTUDIO_GIT_LIBGIT2_BINARY_CHECKSUM": String(repeating: "b", count: 64),
            ],
            fakeSwift: fakeSwift
        )

        #expect(result.exitCode == 1)
        #expect(!result.combinedOutput.contains(artifactURL))
        #expect(!result.combinedOutput.contains("path-token-123"))
        let arguments = try fakeSwift.recordedArguments()
        #expect(arguments.contains("--cache-path"))
    }

    @Test("third-party notice records pinned libgit2 tag and license")
    func thirdPartyNoticeRecordsPinnedLibGit2TagAndLicense() throws {
        let contents = try readFile("ThirdPartyNotices/libgit2.md")

        #expect(contents.contains("v1.9.4"))
        #expect(contents.contains("GPL-2.0-only WITH GCC-exception-2.0"))
        #expect(contents.contains("f7164261c9bc0a7e0ebf767c584e5192810a8b24"))
    }

    private func readFile(_ path: String) throws -> String {
        try String(contentsOf: URL(fileURLWithPath: path), encoding: .utf8)
    }

    private func runHostedArtifactVerifier(
        environment: [String: String],
        fakeSwift: FakeSwiftExecutable
    ) throws -> CapturedScriptResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["bash", "scripts/verify-hosted-libgit2-artifact.sh"]
        process.currentDirectoryURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)

        var processEnvironment = ProcessInfo.processInfo.environment
        processEnvironment.merge(environment) { _, testValue in testValue }
        processEnvironment["PATH"] =
            "\(fakeSwift.binDirectory.path):\(ProcessInfo.processInfo.environment["PATH"] ?? "")"
        processEnvironment["AGENTSTUDIO_FAKE_SWIFT_ARGUMENTS"] = fakeSwift.argumentsURL.path
        process.environment = processEnvironment

        let output = Pipe()
        let error = Pipe()
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = error
        try process.run()
        process.waitUntilExit()

        return CapturedScriptResult(
            exitCode: process.terminationStatus,
            stdout: String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "",
            stderr: String(data: error.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        )
    }
}

private struct FakeSwiftExecutable {
    private let fileManager = FileManager.default
    let root: URL
    let binDirectory: URL
    let argumentsURL: URL

    init() throws {
        root = fileManager.temporaryDirectory.appending(path: "agentstudio-git-fake-swift-\(UUID().uuidString)")
        binDirectory = root.appending(path: "bin")
        argumentsURL = root.appending(path: "arguments.txt")
        try fileManager.createDirectory(at: binDirectory, withIntermediateDirectories: true)
        let executableURL = binDirectory.appending(path: "swift")
        try """
        #!/bin/sh
        {
          for argument in "$@"; do
            printf '%s\\n' "$argument"
          done
        } >> "$AGENTSTUDIO_FAKE_SWIFT_ARGUMENTS"
        printf 'Downloading binary artifact %s\\n' "$AGENTSTUDIO_GIT_LIBGIT2_BINARY_URL" >&2
        printf "failed downloading '%s'\\n" "$AGENTSTUDIO_GIT_LIBGIT2_BINARY_URL" >&2
        exit 1
        """
        .write(to: executableURL, atomically: true, encoding: .utf8)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executableURL.path)
    }

    func recordedArguments() throws -> [String] {
        guard fileManager.fileExists(atPath: argumentsURL.path) else {
            return []
        }
        return try String(contentsOf: argumentsURL, encoding: .utf8)
            .split(separator: "\n")
            .map(String.init)
    }
}

private struct CapturedScriptResult {
    let exitCode: Int32
    let stdout: String
    let stderr: String

    var combinedOutput: String {
        "\(stdout)\n\(stderr)"
    }
}
