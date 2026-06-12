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

    @Test("consumer verification imports AgentStudioGitLocal without running repo mise tasks")
    func consumerVerificationImportsLocalProductWithoutRunningRepoMiseTasks() throws {
        let contents = try readFile("scripts/verify-package-consumer.sh")

        #expect(contents.contains("import AgentStudioGitLocal"))
        #expect(contents.contains(".package(path:"))
        #expect(contents.contains("swift run --package-path"))
        #expect(contents.contains("AGENTSTUDIO_GIT_LIBGIT2_BINARY_URL"))
        #expect(contents.contains("AGENTSTUDIO_GIT_LIBGIT2_BINARY_CHECKSUM"))
        #expect(contents.contains("swift package dump-package"))
        #expect(contents.contains("CLibGit2Local.xcframework.zip.checksum"))
        #expect(!contents.contains("mise run"))
    }

    @Test("check workflow runs sanitizer and consumer gates")
    func checkWorkflowRunsSanitizerAndConsumerGates() throws {
        let contents = try readFile(".github/workflows/check.yml")

        #expect(contents.contains("mise run check"))
        #expect(contents.contains("mise run test-asan"))
        #expect(contents.contains("mise run test-tsan"))
        #expect(contents.contains("bash scripts/verify-package-consumer.sh"))
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
}
