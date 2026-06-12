// swift-tools-version: 6.2
import PackageDescription

let libGit2BinaryTarget: Target
if let binaryURL = Context.environment["AGENTSTUDIO_GIT_LIBGIT2_BINARY_URL"],
    !binaryURL.isEmpty
{
    guard let binaryChecksum = Context.environment["AGENTSTUDIO_GIT_LIBGIT2_BINARY_CHECKSUM"],
        !binaryChecksum.isEmpty
    else {
        fatalError(
            "AGENTSTUDIO_GIT_LIBGIT2_BINARY_CHECKSUM is required when AGENTSTUDIO_GIT_LIBGIT2_BINARY_URL is set")
    }
    libGit2BinaryTarget = .binaryTarget(
        name: "CLibGit2Local",
        url: binaryURL,
        checksum: binaryChecksum
    )
} else {
    libGit2BinaryTarget = .binaryTarget(
        name: "CLibGit2Local",
        path: "Artifacts/CLibGit2Local.xcframework"
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
