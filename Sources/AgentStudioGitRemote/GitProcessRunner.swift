import AgentStudioGitContracts
import Foundation

public struct GitProcessResult: Equatable, Sendable {
    public let stdout: String
    public let stderr: String

    public init(stdout: String, stderr: String) {
        self.stdout = stdout
        self.stderr = stderr
    }
}

public struct GitProcessRunner: Sendable {
    public let configuration: SystemGitRemoteClient.Configuration

    public init(configuration: SystemGitRemoteClient.Configuration = .init()) {
        self.configuration = configuration
    }

    public func run(arguments: [String], currentDirectory: URL? = nil) async throws(GitDataPlaneError)
        -> GitProcessResult
    {
        let invocation = GitExecutableLocator(configuredExecutableURL: configuration.executableURL).invocation()
        let processArguments = invocation.leadingArguments + configuration.protocolConfigArguments() + arguments
        let fileManager = FileManager.default
        let outputRoot = fileManager.temporaryDirectory
            .appending(path: "agentstudio-git-process-\(UUID().uuidString)")
        let stdoutURL = outputRoot.appending(path: "stdout.txt")
        let stderrURL = outputRoot.appending(path: "stderr.txt")

        do {
            try fileManager.createDirectory(at: outputRoot, withIntermediateDirectories: true)
            fileManager.createFile(atPath: stdoutURL.path, contents: nil)
            fileManager.createFile(atPath: stderrURL.path, contents: nil)

            let stdoutWriter = try FileHandle(forWritingTo: stdoutURL)
            let stderrWriter = try FileHandle(forWritingTo: stderrURL)
            defer {
                stdoutWriter.closeFile()
                stderrWriter.closeFile()
                try? fileManager.removeItem(at: outputRoot)
            }

            let process = Process()
            process.executableURL = invocation.executableURL
            process.arguments = processArguments
            process.currentDirectoryURL = currentDirectory
            process.environment = configuration.processEnvironment()
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = stdoutWriter
            process.standardError = stderrWriter
            try process.run()
            process.waitUntilExit()

            stdoutWriter.closeFile()
            stderrWriter.closeFile()

            let stdout = try String(contentsOf: stdoutURL, encoding: .utf8)
            let stderr = try String(contentsOf: stderrURL, encoding: .utf8)
            guard process.terminationStatus == 0 else {
                throw GitDataPlaneError.processFailed(
                    GitRemoteProcessFailure.redacting(
                        executable: invocation.displayName,
                        arguments: processArguments,
                        exitCode: process.terminationStatus,
                        stderr: stderr
                    ))
            }

            return GitProcessResult(stdout: stdout, stderr: stderr)
        } catch let error as GitDataPlaneError {
            throw error
        } catch {
            throw GitDataPlaneError.processFailed(
                GitRemoteProcessFailure.redacting(
                    executable: invocation.displayName,
                    arguments: processArguments,
                    exitCode: -1,
                    stderr: String(describing: error)
                ))
        }
    }
}
