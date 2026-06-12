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
            dependencies: ["AgentStudioGitContracts"],
            path: "Sources/AgentStudioGitLocal"
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
        .testTarget(
            name: "AgentStudioGitTests",
            dependencies: ["AgentStudioGit"],
            path: "Tests/AgentStudioGitTests"
        ),
    ]
)
