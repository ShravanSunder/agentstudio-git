// swift-tools-version: 6.2
import PackageDescription

let libGit2BinaryTarget: Target
let hostedLibGit2BinaryURL =
    "https://raw.githubusercontent.com/ShravanSunder/experiments-gh-cli-repo-public/aa2c8b9/agentstudio-git/libgit2/2026-06-12/CLibGit2Local.xcframework.zip"
let hostedLibGit2BinaryChecksum = "33a995b26dafeaf0b73ef2d65371653c0e35042d55344fef4acea1b059c2740d"
let localLibGit2ArtifactModeEnabled = Context.environment["AGENTSTUDIO_GIT_USE_LOCAL_LIBGIT2_ARTIFACT"] == "1"

func nonEmptyEnvironmentValue(_ name: String) -> String? {
    guard let value = Context.environment[name], !value.isEmpty else {
        return nil
    }
    return value
}

if localLibGit2ArtifactModeEnabled {
    libGit2BinaryTarget = .binaryTarget(
        name: "CLibGit2Local",
        path: "Artifacts/CLibGit2Local.xcframework"
    )
} else {
    let configuredBinaryURL = nonEmptyEnvironmentValue("AGENTSTUDIO_GIT_LIBGIT2_BINARY_URL")
    let configuredBinaryChecksum = nonEmptyEnvironmentValue("AGENTSTUDIO_GIT_LIBGIT2_BINARY_CHECKSUM")
    if (configuredBinaryURL == nil) != (configuredBinaryChecksum == nil) {
        fatalError("AGENTSTUDIO_GIT_LIBGIT2_BINARY_URL and AGENTSTUDIO_GIT_LIBGIT2_BINARY_CHECKSUM must be set together")
    }

    let binaryURL = configuredBinaryURL ?? hostedLibGit2BinaryURL
    let binaryChecksum = configuredBinaryChecksum ?? hostedLibGit2BinaryChecksum
    libGit2BinaryTarget = .binaryTarget(
        name: "CLibGit2Local",
        url: binaryURL,
        checksum: binaryChecksum
    )
}

let package = Package(
    name: "agentstudio-git",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "AgentStudioGit",
            targets: ["AgentStudioGit"]
        ),
        .library(
            name: "AgentStudioGitContracts",
            targets: ["AgentStudioGitContracts"]
        ),
        .library(
            name: "AgentStudioGitLocal",
            targets: ["AgentStudioGitLocal"]
        ),
        .library(
            name: "AgentStudioGitRemote",
            targets: ["AgentStudioGitRemote"]
        ),
    ],
    dependencies: [],
    targets: [
        .target(
            name: "AgentStudioGitContracts",
            dependencies: [],
            path: "Sources/AgentStudioGitContracts"
        ),
        .target(
            name: "AgentStudioGitLocal",
            dependencies: [
                "AgentStudioGitContracts",
                "CLibGit2Local",
            ],
            path: "Sources/AgentStudioGitLocal",
            linkerSettings: [
                .linkedLibrary("z"),
                .linkedLibrary("iconv"),
            ]
        ),
        .target(
            name: "AgentStudioGitRemote",
            dependencies: ["AgentStudioGitContracts"],
            path: "Sources/AgentStudioGitRemote"
        ),
        .target(
            name: "AgentStudioGit",
            dependencies: [
                "AgentStudioGitContracts",
                "AgentStudioGitLocal",
                "AgentStudioGitRemote",
            ],
            path: "Sources/AgentStudioGit"
        ),
        libGit2BinaryTarget,
        .testTarget(
            name: "AgentStudioGitTests",
            dependencies: [
                "AgentStudioGit",
                "AgentStudioGitLocal",
            ],
            path: "Tests/AgentStudioGitTests"
        ),
    ]
)
