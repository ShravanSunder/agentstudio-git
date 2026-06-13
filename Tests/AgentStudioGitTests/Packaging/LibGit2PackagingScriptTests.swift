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
        #expect(packageContents.contains("AGENTSTUDIO_GIT_USE_LOCAL_LIBGIT2_ARTIFACT"))
        #expect(packageContents.contains("AGENTSTUDIO_GIT_LIBGIT2_BINARY_URL"))
        #expect(packageContents.contains("AGENTSTUDIO_GIT_LIBGIT2_BINARY_CHECKSUM"))
        #expect(
            packageContents.contains(
                "https://github.com/ShravanSunder/agentstudio-git/releases/download/libgit2-1.9.4-agentstudio.1/CLibGit2Local.xcframework.zip"
            ))
        #expect(packageContents.contains("a14247dbdd4e228c2c07436c908f10e293993e0c7b8d30a22d9a2f8f6daeac84"))
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
        #expect(contents.contains(".package(name: \"agentstudio-git\", path:"))
        #expect(contents.contains(".product(name: \"AgentStudioGitRemote\""))
        #expect(contents.contains("swift run --package-path"))
        #expect(contents.contains("without hosted artifact overrides"))
        #expect(contents.contains("env -u AGENTSTUDIO_GIT_LIBGIT2_BINARY_URL"))
        #expect(contents.contains("-u AGENTSTUDIO_GIT_LIBGIT2_BINARY_CHECKSUM"))
        #expect(contents.contains("-u AGENTSTUDIO_GIT_ALLOW_LIBGIT2_BINARY_URL"))
        #expect(contents.contains("-u AGENTSTUDIO_GIT_USE_LOCAL_LIBGIT2_ARTIFACT"))
        #expect(contents.contains("swift package dump-package"))
        #expect(
            contents.contains(
                "https://github.com/ShravanSunder/agentstudio-git/releases/download/libgit2-1.9.4-agentstudio.1/CLibGit2Local.xcframework.zip"
            ))
        #expect(contents.contains("a14247dbdd4e228c2c07436c908f10e293993e0c7b8d30a22d9a2f8f6daeac84"))
        #expect(!contents.contains("CLibGit2Local.xcframework.zip.checksum"))
        #expect(!contents.contains("mise run"))
    }

    @Test("package defaults to hosted libgit2 binary URL without environment")
    func packageDefaultsToHostedLibGit2BinaryURLWithoutEnvironment() throws {
        let packageContents = try readFile("Package.swift")

        #expect(packageContents.contains("let hostedLibGit2BinaryURL ="))
        #expect(packageContents.contains("let hostedLibGit2BinaryChecksum ="))
        #expect(packageContents.contains("AGENTSTUDIO_GIT_USE_LOCAL_LIBGIT2_ARTIFACT"))
        #expect(!packageContents.contains("hostedBinaryURLModeEnabled"))
        #expect(packageContents.contains("nonEmptyEnvironmentValue(\"AGENTSTUDIO_GIT_LIBGIT2_BINARY_URL\")"))
    }

    @Test("check workflow runs sanitizer and consumer gates")
    func checkWorkflowRunsSanitizerAndConsumerGates() throws {
        let contents = try readFile(".github/workflows/check.yml")

        #expect(contents.contains("runs-on: macos-26"))
        #expect(contents.contains("brew install mise cmake swift-format swiftlint"))
        #expect(contents.contains("timeout-minutes: 12"))
        #expect(contents.contains("mise run check"))
        #expect(
            contents.contains(
                "      - name: Run AddressSanitizer tests\n        timeout-minutes: 12\n        run: mise run test-asan"
            ))
        #expect(
            contents.contains(
                "      - name: Run ThreadSanitizer tests\n        timeout-minutes: 12\n        run: mise run test-tsan"
            ))
        #expect(contents.contains("mise run test-asan"))
        #expect(contents.contains("mise run test-tsan"))
        #expect(contents.contains("bash scripts/verify-package-consumer.sh"))
        #expect(contents.contains("AgentStudio compatibility requires AGENTSTUDIO_GIT_AGENTSTUDIO_PATH"))
        #expect(contents.contains("bash scripts/verify-agentstudio-compatibility.sh"))
    }

    @Test("test task runs named Swift Testing suites through no-zero filter")
    func testTaskRunsNamedSwiftTestingSuitesThroughNoZeroFilter() throws {
        let miseContents = try readFile(".mise.toml")
        let scriptContents = try readFile("scripts/run-swift-test-suites.sh")
        let runnerSuites = suiteNamesListedByRunner(scriptContents)
        let sourceSuites = try swiftTestingSuiteTypeNames()

        #expect(miseContents.contains("bash scripts/run-swift-test-suites.sh"))
        #expect(miseContents.contains("bash scripts/run-swift-test-suites.sh --sanitize address --disable-xctest"))
        #expect(miseContents.contains("bash scripts/run-swift-test-suites.sh --sanitize thread --disable-xctest"))
        #expect(scriptContents.contains("scripts/run-swift-test-filter.sh"))
        #expect(scriptContents.contains("\"${swift_test_arguments[@]}\""))
        #expect(scriptContents.contains("if [ \"${#swift_test_arguments[@]}\" -gt 0 ]; then"))
        #expect(scriptContents.contains("GitProcessRunnerTests"))
        #expect(scriptContents.contains("SystemGitRemoteClientTests"))
        #expect(scriptContents.contains("BridgeReviewSourceCompatibilityTests"))
        #expect(runnerSuites == sourceSuites)
    }

    @Test("filter script falls back when ripgrep is unavailable")
    func filterScriptFallsBackWhenRipgrepIsUnavailable() throws {
        let fakeSwift = try FakeSwiftTestExecutable(
            stdout: "Test run with 0 tests in 0 suites passed after 0.001 seconds.\n",
            exitCode: 0
        )

        let result = try runSwiftTestFilter(
            filter: "MissingTests",
            fakeSwift: fakeSwift,
            path: "\(fakeSwift.binDirectory.path):/usr/bin:/bin"
        )

        #expect(result.exitCode == 1)
        #expect(result.combinedOutput.contains("filtered Swift test gate executed zero tests: MissingTests"))
    }

    @Test("filter script preserves Swift test options")
    func filterScriptPreservesSwiftTestOptions() throws {
        let fakeSwift = try FakeSwiftTestExecutable(
            stdout: "Test run with 1 test in 1 suite passed after 0.001 seconds.\n",
            exitCode: 0
        )

        let result = try runSwiftTestFilter(
            arguments: ["--sanitize", "address", "--disable-xctest", "GitProcessRunnerTests"],
            fakeSwift: fakeSwift,
            path: "\(fakeSwift.binDirectory.path):/usr/bin:/bin"
        )

        #expect(result.exitCode == 0)
        #expect(
            try fakeSwift.recordedArguments() == [
                "test",
                "--sanitize",
                "address",
                "--disable-xctest",
                "--filter",
                "GitProcessRunnerTests",
            ])
    }

    @Test("Git process runner suite is serialized and bounded")
    func gitProcessRunnerSuiteIsSerializedAndBounded() throws {
        let contents = try readFile("Tests/AgentStudioGitTests/Remote/GitProcessRunnerTests.swift")

        #expect(contents.contains("@Suite(\"Git process runner\", .serialized)"))
        #expect(contents.contains("operationTimeoutSeconds: Double = 10"))
    }

    @Test("artifact workflow runs on Swift 6.2 capable macOS image")
    func artifactWorkflowRunsOnSwift62CapableMacOSImage() throws {
        let contents = try readFile(".github/workflows/libgit2-artifact.yml")

        #expect(contents.contains("runs-on: macos-26"))
    }

    @Test("artifact workflow publishes immutable GitHub release asset")
    func artifactWorkflowPublishesImmutableGitHubReleaseAsset() throws {
        let contents = try readFile(".github/workflows/libgit2-artifact.yml")

        #expect(contents.contains("name: libgit2 Artifact Release"))
        #expect(contents.contains("permissions:\n  contents: write"))
        #expect(contents.contains("artifact_tag:"))
        #expect(contents.contains("type: string"))
        #expect(contents.contains("prerelease:"))
        #expect(contents.contains("type: boolean"))
        #expect(contents.contains("GH_TOKEN: ${{ github.token }}"))
        #expect(contents.contains("gh release view \"$ARTIFACT_TAG\""))
        #expect(contents.contains("git ls-remote --exit-code --tags origin \"refs/tags/$ARTIFACT_TAG\""))
        #expect(contents.contains("release already exists"))
        #expect(contents.contains("release_created=1"))
        #expect(contents.contains("gh release delete \"$ARTIFACT_TAG\" --yes --cleanup-tag"))
        #expect(!contents.contains("--clobber"))
        #expect(contents.contains("gh release create \"$ARTIFACT_TAG\""))
        #expect(contents.contains("--target \"$GITHUB_SHA\""))
        #expect(contents.contains("Artifacts/CLibGit2Local.xcframework.zip"))
        #expect(contents.contains("Artifacts/CLibGit2Local.xcframework.zip.checksum"))
        #expect(contents.contains("actions/upload-artifact@v4"))
    }

    @Test("artifact workflow verifies public SwiftPM release URL")
    func artifactWorkflowVerifiesPublicSwiftPMReleaseURL() throws {
        let contents = try readFile(".github/workflows/libgit2-artifact.yml")

        #expect(
            contents.contains(
                "artifact_url=https://github.com/${{ github.repository }}/releases/download/$artifact_tag/CLibGit2Local.xcframework.zip"
            ))
        #expect(
            contents.contains("checksum=\"$(tr -d '[:space:]' < Artifacts/CLibGit2Local.xcframework.zip.checksum)\""))
        #expect(contents.contains("[[ ! \"$checksum\" =~ ^[0-9a-f]{64}$ ]]"))
        #expect(contents.contains("AGENTSTUDIO_GIT_LIBGIT2_BINARY_URL: ${{ steps.artifact.outputs.artifact_url }}"))
        #expect(contents.contains("AGENTSTUDIO_GIT_LIBGIT2_BINARY_CHECKSUM: ${{ steps.artifact.outputs.checksum }}"))
        #expect(contents.contains("bash scripts/verify-hosted-libgit2-artifact.sh"))
        #expect(contents.contains("for attempt in 1 2 3 4 5"))
        #expect(contents.contains("sleep \"$((attempt * 5))\""))
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
        #expect(!scriptContents.contains("AGENTSTUDIO_GIT_ALLOW_LIBGIT2_BINARY_URL=1"))
        #expect(scriptContents.contains("must be an https URL"))
        #expect(scriptContents.contains(".package(name: \"agentstudio-git\", path:"))
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
        #expect(guideContents.contains("AGENTSTUDIO_GIT_USE_LOCAL_LIBGIT2_ARTIFACT=1 swift build"))
        #expect(guideContents.contains("AGENTSTUDIO_GIT_LIBGIT2_BINARY_URL"))
        #expect(!guideContents.contains("AGENTSTUDIO_GIT_ALLOW_LIBGIT2_BINARY_URL=1"))
        #expect(guideContents.contains("mise run test-asan"))
        #expect(guideContents.contains("mise run test-tsan"))
        #expect(!guideContents.contains("swift test --sanitize address"))
        #expect(!guideContents.contains("swift test --sanitize thread"))
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

        let privateIPv6Result = try runHostedArtifactVerifier(
            environment: [
                "AGENTSTUDIO_GIT_LIBGIT2_BINARY_URL": "https://[fd00::1]/CLibGit2Local.xcframework.zip",
                "AGENTSTUDIO_GIT_LIBGIT2_BINARY_CHECKSUM": checksum,
            ],
            fakeSwift: fakeSwift
        )

        #expect(privateIPv6Result.exitCode == 2)
        #expect(try fakeSwift.recordedArguments().isEmpty)

        let mappedLoopbackIPv6Result = try runHostedArtifactVerifier(
            environment: [
                "AGENTSTUDIO_GIT_LIBGIT2_BINARY_URL":
                    "https://[::ffff:127.0.0.1]/CLibGit2Local.xcframework.zip",
                "AGENTSTUDIO_GIT_LIBGIT2_BINARY_CHECKSUM": checksum,
            ],
            fakeSwift: fakeSwift
        )

        #expect(mappedLoopbackIPv6Result.exitCode == 2)
        #expect(try fakeSwift.recordedArguments().isEmpty)

        let hexMappedLoopbackIPv6Result = try runHostedArtifactVerifier(
            environment: [
                "AGENTSTUDIO_GIT_LIBGIT2_BINARY_URL":
                    "https://[::ffff:7f00:1]/CLibGit2Local.xcframework.zip",
                "AGENTSTUDIO_GIT_LIBGIT2_BINARY_CHECKSUM": checksum,
            ],
            fakeSwift: fakeSwift
        )

        #expect(hexMappedLoopbackIPv6Result.exitCode == 2)
        #expect(try fakeSwift.recordedArguments().isEmpty)

        let hexMappedPrivateIPv6Result = try runHostedArtifactVerifier(
            environment: [
                "AGENTSTUDIO_GIT_LIBGIT2_BINARY_URL":
                    "https://[::ffff:c0a8:1]/CLibGit2Local.xcframework.zip",
                "AGENTSTUDIO_GIT_LIBGIT2_BINARY_CHECKSUM": checksum,
            ],
            fakeSwift: fakeSwift
        )

        #expect(hexMappedPrivateIPv6Result.exitCode == 2)
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

    @Test("hosted artifact verifier resolves non-allowlisted hostnames")
    func hostedArtifactVerifierResolvesNonAllowlistedHostnames() throws {
        let checksum = String(repeating: "a", count: 64)
        let publicHostFakeSwift = try FakeSwiftExecutable()
        let publicHostResult = try runHostedArtifactVerifier(
            environment: [
                "AGENTSTUDIO_GIT_LIBGIT2_BINARY_URL":
                    "https://fcdelivery.example.com/CLibGit2Local.xcframework.zip",
                "AGENTSTUDIO_GIT_LIBGIT2_BINARY_CHECKSUM": checksum,
            ],
            fakeSwift: publicHostFakeSwift
        )

        #expect(publicHostResult.exitCode == 1)
        #expect(try !publicHostFakeSwift.recordedArguments().isEmpty)

        let knownPublicHostFakeSwift = try FakeSwiftExecutable()
        let knownPublicHostResult = try runHostedArtifactVerifier(
            environment: [
                "AGENTSTUDIO_GIT_LIBGIT2_BINARY_URL":
                    "https://raw.githubusercontent.com/example/agentstudio-git-artifacts/CLibGit2Local.xcframework.zip",
                "AGENTSTUDIO_GIT_LIBGIT2_BINARY_CHECKSUM": checksum,
                "AGENTSTUDIO_GIT_TEST_RESOLVED_ARTIFACT_ADDRESSES": "127.0.0.1",
            ],
            fakeSwift: knownPublicHostFakeSwift
        )

        #expect(knownPublicHostResult.exitCode == 1)
        #expect(try !knownPublicHostFakeSwift.recordedArguments().isEmpty)

        let privateHostFakeSwift = try FakeSwiftExecutable()
        let privateResolvedHostnameResult = try runHostedArtifactVerifier(
            environment: [
                "AGENTSTUDIO_GIT_LIBGIT2_BINARY_URL":
                    "https://public-looking.example.com/CLibGit2Local.xcframework.zip",
                "AGENTSTUDIO_GIT_LIBGIT2_BINARY_CHECKSUM": checksum,
                "AGENTSTUDIO_GIT_TEST_RESOLVED_ARTIFACT_ADDRESSES": "127.0.0.1",
            ],
            fakeSwift: privateHostFakeSwift
        )

        #expect(privateResolvedHostnameResult.exitCode == 2)
        #expect(try privateHostFakeSwift.recordedArguments().isEmpty)
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

    private func suiteNamesListedByRunner(_ scriptContents: String) -> Set<String> {
        guard let startRange = scriptContents.range(of: "suites=("),
            let endRange = scriptContents[startRange.upperBound...].range(of: ")")
        else {
            return []
        }
        return Set(
            scriptContents[startRange.upperBound..<endRange.lowerBound]
                .split(separator: "\n")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty && !$0.hasPrefix("#") }
        )
    }

    private func swiftTestingSuiteTypeNames() throws -> Set<String> {
        let testRoot = URL(fileURLWithPath: "Tests/AgentStudioGitTests")
        let fileManager = FileManager.default
        guard
            let enumerator = fileManager.enumerator(
                at: testRoot,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            )
        else {
            return []
        }

        var suiteNames: Set<String> = []
        let expression = try NSRegularExpression(
            pattern: #"@Suite[^\n]*\n\s*struct\s+([A-Za-z_][A-Za-z0-9_]*)"#,
            options: []
        )
        for case let fileURL as URL in enumerator where fileURL.pathExtension == "swift" {
            let contents = try String(contentsOf: fileURL, encoding: .utf8)
            let range = NSRange(contents.startIndex..<contents.endIndex, in: contents)
            for match in expression.matches(in: contents, range: range) {
                guard let nameRange = Range(match.range(at: 1), in: contents) else {
                    continue
                }
                suiteNames.insert(String(contents[nameRange]))
            }
        }
        return suiteNames
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
        processEnvironment["AGENTSTUDIO_GIT_TESTING"] = "1"
        if processEnvironment["AGENTSTUDIO_GIT_TEST_RESOLVED_ARTIFACT_ADDRESSES"] == nil {
            processEnvironment["AGENTSTUDIO_GIT_TEST_RESOLVED_ARTIFACT_ADDRESSES"] = "93.184.216.34"
        }
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

    private func runSwiftTestFilter(
        filter: String,
        fakeSwift: FakeSwiftTestExecutable,
        path: String
    ) throws -> CapturedScriptResult {
        try runSwiftTestFilter(arguments: [filter], fakeSwift: fakeSwift, path: path)
    }

    private func runSwiftTestFilter(
        arguments: [String],
        fakeSwift: FakeSwiftTestExecutable,
        path: String
    ) throws -> CapturedScriptResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["bash", "scripts/run-swift-test-filter.sh"] + arguments
        process.currentDirectoryURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)

        var processEnvironment = ProcessInfo.processInfo.environment
        processEnvironment["PATH"] = path
        processEnvironment["AGENTSTUDIO_FAKE_SWIFT_OUTPUT"] = fakeSwift.output
        processEnvironment["AGENTSTUDIO_FAKE_SWIFT_EXIT"] = "\(fakeSwift.exitCode)"
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

private struct FakeSwiftTestExecutable {
    private let fileManager = FileManager.default
    let root: URL
    let binDirectory: URL
    let argumentsURL: URL
    let output: String
    let exitCode: Int32

    init(stdout: String, exitCode: Int32) throws {
        root = fileManager.temporaryDirectory.appending(path: "agentstudio-git-fake-swift-test-\(UUID().uuidString)")
        binDirectory = root.appending(path: "bin")
        argumentsURL = root.appending(path: "arguments.txt")
        output = stdout
        self.exitCode = exitCode
        try fileManager.createDirectory(at: binDirectory, withIntermediateDirectories: true)
        let executableURL = binDirectory.appending(path: "swift")
        try """
        #!/bin/sh
        {
          for argument in "$@"; do
            printf '%s\\n' "$argument"
          done
        } > "$AGENTSTUDIO_FAKE_SWIFT_ARGUMENTS"
        printf '%s' "$AGENTSTUDIO_FAKE_SWIFT_OUTPUT"
        exit "$AGENTSTUDIO_FAKE_SWIFT_EXIT"
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
