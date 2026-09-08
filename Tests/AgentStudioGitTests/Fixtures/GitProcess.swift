import Foundation
import Testing

struct GitProcess {
    let repositoryPath: URL

    @discardableResult
    func run(_ arguments: String..., currentDirectory: URL? = nil) throws -> String {
        try run(arguments, currentDirectory: currentDirectory)
    }

    @discardableResult
    func run(
        _ arguments: [String],
        currentDirectory: URL? = nil,
        standardInput: Data? = nil
    ) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments =
            [
                "git",
                "-c",
                "user.name=AgentStudio Test",
                "-c",
                "user.email=agentstudio@example.invalid",
                "-c",
                "commit.gpgsign=false",
                "-c",
                "init.defaultBranch=main",
            ] + arguments
        process.currentDirectoryURL = currentDirectory ?? repositoryPath
        process.environment = ProcessInfo.processInfo.environment.merging(
            [
                "GIT_CONFIG_NOSYSTEM": "1",
                "GIT_CONFIG_GLOBAL": "/dev/null",
                "GIT_CONFIG_XDG": "/dev/null",
                "GIT_TERMINAL_PROMPT": "0",
                "LC_ALL": "C",
            ]
        ) { _, testValue in testValue }

        let output = Pipe()
        let error = Pipe()
        let input = standardInput.map { _ in Pipe() }
        process.standardInput = input ?? FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = error
        try process.run()
        if let standardInput, let input {
            input.fileHandleForWriting.write(standardInput)
            try input.fileHandleForWriting.close()
        }
        process.waitUntilExit()

        let stdout = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let stderr = String(data: error.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        guard process.terminationStatus == 0 else {
            Issue.record(
                """
                git \(arguments.joined(separator: " ")) failed with exit \(process.terminationStatus)
                stdout:
                \(stdout)
                stderr:
                \(stderr)
                """
            )
            throw GitProcessError(
                arguments: arguments, exitCode: process.terminationStatus, stdout: stdout, stderr: stderr)
        }

        return stdout
    }

    func succeeds(_ arguments: String..., currentDirectory: URL? = nil) throws -> Bool {
        try result(arguments, currentDirectory: currentDirectory).exitCode == 0
    }

    private func result(_ arguments: [String], currentDirectory: URL? = nil) throws -> GitProcessResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments =
            [
                "git",
                "-c",
                "user.name=AgentStudio Test",
                "-c",
                "user.email=agentstudio@example.invalid",
                "-c",
                "commit.gpgsign=false",
                "-c",
                "init.defaultBranch=main",
            ] + arguments
        process.currentDirectoryURL = currentDirectory ?? repositoryPath
        process.environment = ProcessInfo.processInfo.environment.merging(
            [
                "GIT_CONFIG_NOSYSTEM": "1",
                "GIT_CONFIG_GLOBAL": "/dev/null",
                "GIT_CONFIG_XDG": "/dev/null",
                "GIT_TERMINAL_PROMPT": "0",
                "LC_ALL": "C",
            ]
        ) { _, testValue in testValue }

        let output = Pipe()
        let error = Pipe()
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = error
        try process.run()
        process.waitUntilExit()

        return GitProcessResult(
            exitCode: process.terminationStatus,
            stdout: String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "",
            stderr: String(data: error.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        )
    }
}

private struct GitProcessResult {
    let exitCode: Int32
    let stdout: String
    let stderr: String
}

struct GitProcessError: Error {
    let arguments: [String]
    let exitCode: Int32
    let stdout: String
    let stderr: String
}
