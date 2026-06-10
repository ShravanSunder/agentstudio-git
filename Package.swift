// swift-tools-version: 6.2
import PackageDescription

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
    ],
    dependencies: [],
    targets: [
        .target(
            name: "AgentStudioGit",
            dependencies: [],
            path: "Sources/AgentStudioGit"
        ),
        .testTarget(
            name: "AgentStudioGitTests",
            dependencies: ["AgentStudioGit"],
            path: "Tests/AgentStudioGitTests"
        ),
    ]
)
