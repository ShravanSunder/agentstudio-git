import Foundation
import Testing

enum AgentStudioCompatibilityHarnessSupport {
    static func agentStudioGitPackageRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    static func agentStudioRoot() -> URL? {
        let environment = ProcessInfo.processInfo.environment
        if let configuredPath = environment["AGENTSTUDIO_GIT_AGENTSTUDIO_PATH"],
            !configuredPath.isEmpty
        {
            return URL(fileURLWithPath: configuredPath)
        }

        let packageSiblingRoot = agentStudioGitPackageRoot().deletingLastPathComponent()
        let candidateNames = [
            "agent-studio.bridge-start",
            "agent-studio",
            "agent-studio.main",
        ]
        return
            candidateNames
            .map { packageSiblingRoot.appending(path: $0) }
            .first { FileManager.default.fileExists(atPath: $0.path) }
    }

    static func shouldRequireAgentStudioCompatibility() -> Bool {
        ProcessInfo.processInfo.environment["AGENTSTUDIO_GIT_REQUIRE_AGENTSTUDIO_COMPATIBILITY"] == "1"
    }

    static func recordMissingAgentStudioSeam(_ message: String) {
        guard
            shouldRequireAgentStudioCompatibility()
                || ProcessInfo.processInfo.environment["AGENTSTUDIO_GIT_AGENTSTUDIO_PATH"] != nil
        else {
            return
        }
        Issue.record("\(message)")
    }

    static func moduleSearchPath(packageRoot: URL, requiredModules: [String]) throws -> URL {
        let result = try runCapturedProcess(arguments: [
            "swift",
            "build",
            "--show-bin-path",
            "--package-path",
            packageRoot.path,
        ])
        guard result.terminationStatus == 0 else {
            Issue.record(
                """
                Swift build path discovery failed with exit \(result.terminationStatus)
                stdout:
                \(result.stdout)
                stderr:
                \(result.stderr)
                """
            )
            throw AgentStudioCompatibilityHarnessSupportError.buildPathDiscoveryFailed(
                result.terminationStatus)
        }

        let debugBuildPath = URL(
            fileURLWithPath: result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        let moduleSearchPath = debugBuildPath.appending(path: "Modules")
        for requiredModule in requiredModules {
            guard
                FileManager.default.fileExists(
                    atPath: moduleSearchPath.appending(path: "\(requiredModule).swiftmodule").path
                )
            else {
                throw AgentStudioCompatibilityHarnessSupportError.missingBuiltModule(
                    moduleSearchPath.path)
            }
        }
        return moduleSearchPath
    }

    static func libGit2HeaderSearchPath(
        packageRoot: URL,
        debugBuildPath: URL,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> URL {
        let localArtifactHeaders = packageRoot.appending(
            path: "Artifacts/CLibGit2Local.xcframework/macos-arm64_x86_64/Headers")
        if environment["AGENTSTUDIO_GIT_USE_LOCAL_LIBGIT2_ARTIFACT"] == "1",
            isLibGit2HeaderSearchPath(localArtifactHeaders)
        {
            return localArtifactHeaders
        }

        let artifactsRoot =
            debugBuildPath
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "artifacts")
        let enumerator = FileManager.default.enumerator(
            at: artifactsRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        while let candidate = enumerator?.nextObject() as? URL {
            if candidate.pathExtension == "xcframework",
                candidate.lastPathComponent != "CLibGit2Local.xcframework"
            {
                enumerator?.skipDescendants()
                continue
            }
            guard candidate.pathComponents.contains("CLibGit2Local.xcframework"),
                candidate.lastPathComponent == "Headers",
                isLibGit2HeaderSearchPath(candidate)
            else {
                continue
            }
            return candidate
        }

        throw AgentStudioCompatibilityHarnessSupportError.missingLibGit2Headers(artifactsRoot.path)
    }

    private static func isLibGit2HeaderSearchPath(_ headersPath: URL) -> Bool {
        let moduleMap = headersPath.appending(path: "module.modulemap")
        let gitHeader = headersPath.appending(path: "git2.h")
        guard FileManager.default.fileExists(atPath: gitHeader.path),
            let moduleMapContents = try? String(contentsOf: moduleMap, encoding: .utf8)
        else {
            return false
        }
        return moduleMapContents.contains("module CLibGit2Local")
    }

    private static func runCapturedProcess(arguments: [String]) throws -> CapturedProcessResult {
        let outputRoot = FileManager.default.temporaryDirectory
            .appending(path: "agentstudio-git-process-output-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: outputRoot) }
        try FileManager.default.createDirectory(at: outputRoot, withIntermediateDirectories: true)

        let stdoutURL = outputRoot.appending(path: "stdout.txt")
        let stderrURL = outputRoot.appending(path: "stderr.txt")
        FileManager.default.createFile(atPath: stdoutURL.path, contents: nil)
        FileManager.default.createFile(atPath: stderrURL.path, contents: nil)

        let stdoutWriter = try FileHandle(forWritingTo: stdoutURL)
        let stderrWriter = try FileHandle(forWritingTo: stderrURL)
        defer {
            stdoutWriter.closeFile()
            stderrWriter.closeFile()
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = arguments
        process.environment = ProcessInfo.processInfo.environment.merging(
            ["LC_ALL": "C"]
        ) { _, testValue in testValue }
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = stdoutWriter
        process.standardError = stderrWriter
        try process.run()
        process.waitUntilExit()

        stdoutWriter.closeFile()
        stderrWriter.closeFile()

        return CapturedProcessResult(
            terminationStatus: process.terminationStatus,
            stdout: try String(contentsOf: stdoutURL, encoding: .utf8),
            stderr: try String(contentsOf: stderrURL, encoding: .utf8)
        )
    }

    private struct CapturedProcessResult {
        let terminationStatus: Int32
        let stdout: String
        let stderr: String
    }
}

enum AgentStudioCompatibilityHarnessSupportError: Error {
    case buildPathDiscoveryFailed(Int32)
    case missingBuiltModule(String)
    case missingLibGit2Headers(String)
}
