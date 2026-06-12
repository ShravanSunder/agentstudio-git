import AgentStudioGitContracts
import Darwin
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

            let spawnedProcess = try PosixGitProcess.spawn(
                executableURL: invocation.executableURL,
                arguments: processArguments,
                environment: configuration.processEnvironment(),
                currentDirectory: currentDirectory,
                stdoutURL: stdoutURL,
                stderrURL: stderrURL
            )
            let waitResult = waitForProcessExit(spawnedProcess)

            stdoutWriter.closeFile()
            stderrWriter.closeFile()

            let stdout = try String(contentsOf: stdoutURL, encoding: .utf8)
            let stderr = try String(contentsOf: stderrURL, encoding: .utf8)
            guard !waitResult.timedOut else {
                throw GitDataPlaneError.processTimedOut(
                    GitRemoteProcessFailure.redacting(
                        executable: invocation.displayName,
                        arguments: processArguments,
                        exitCode: waitResult.exitCode,
                        stderr: timeoutStderr(stderr)
                    ))
            }
            guard waitResult.exitCode == 0 else {
                throw GitDataPlaneError.processFailed(
                    GitRemoteProcessFailure.redacting(
                        executable: invocation.displayName,
                        arguments: processArguments,
                        exitCode: waitResult.exitCode,
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

    private func waitForProcessExit(_ process: PosixGitProcess) -> ProcessWaitResult {
        let waitState = ProcessWaitState()
        let waitGroup = DispatchGroup()
        waitGroup.enter()
        DispatchQueue.global(qos: .utility).async {
            var status: Int32 = 0
            let result = waitpid(process.pid, &status, 0)
            waitState.store(result: result, status: status, waitErrno: errno)
            waitGroup.leave()
        }

        let waitResult = waitGroup.wait(
            timeout: .now() + configuration.operationTimeoutSeconds
        )
        guard waitResult == .timedOut else {
            return ProcessWaitResult(timedOut: false, exitCode: waitState.exitCode)
        }

        killpg(process.processGroupID, SIGTERM)
        let terminatedAfterGrace = waitGroup.wait(timeout: .now() + 1) != .timedOut
        killpg(process.processGroupID, SIGKILL)
        if !terminatedAfterGrace {
            waitGroup.wait()
        }
        return ProcessWaitResult(timedOut: true, exitCode: waitState.exitCode)
    }

    private func timeoutStderr(_ stderr: String) -> String {
        let timeoutMessage = "git process timed out after \(configuration.operationTimeoutSeconds) seconds"
        guard !stderr.isEmpty else {
            return timeoutMessage
        }
        return "\(stderr)\n\(timeoutMessage)"
    }
}

private struct ProcessWaitResult {
    let timedOut: Bool
    let exitCode: Int32
}

private final class ProcessWaitState: @unchecked Sendable {
    private let lock = NSLock()
    private var result: pid_t = 0
    private var status: Int32 = 0
    private var waitErrno: Int32 = 0

    var exitCode: Int32 {
        lock.lock()
        defer { lock.unlock() }
        guard result > 0 else {
            return -waitErrno
        }
        return Self.exitCode(from: status)
    }

    func store(result: pid_t, status: Int32, waitErrno: Int32) {
        lock.lock()
        self.result = result
        self.status = status
        self.waitErrno = waitErrno
        lock.unlock()
    }

    private static func exitCode(from status: Int32) -> Int32 {
        let signalStatus = status & 0x7f
        if signalStatus == 0 {
            return (status >> 8) & 0xff
        }
        if signalStatus != 0x7f {
            return -signalStatus
        }
        return status
    }
}

private struct PosixGitProcess {
    let pid: pid_t

    var processGroupID: pid_t {
        pid
    }

    static func spawn(
        executableURL: URL,
        arguments: [String],
        environment: [String: String],
        currentDirectory: URL?,
        stdoutURL: URL,
        stderrURL: URL
    ) throws -> Self {
        var fileActions: posix_spawn_file_actions_t?
        try checkPOSIX(posix_spawn_file_actions_init(&fileActions), operation: "posix_spawn_file_actions_init")
        defer { posix_spawn_file_actions_destroy(&fileActions) }

        try addOpenFileAction(&fileActions, descriptor: STDIN_FILENO, path: "/dev/null", flags: O_RDONLY, mode: 0)
        try addOpenFileAction(
            &fileActions,
            descriptor: STDOUT_FILENO,
            path: stdoutURL.path,
            flags: O_WRONLY | O_CREAT | O_TRUNC,
            mode: 0o600
        )
        try addOpenFileAction(
            &fileActions,
            descriptor: STDERR_FILENO,
            path: stderrURL.path,
            flags: O_WRONLY | O_CREAT | O_TRUNC,
            mode: 0o600
        )
        if let currentDirectory {
            try currentDirectory.path.withCString { directoryPath in
                try checkPOSIX(
                    posix_spawn_file_actions_addchdir_np(&fileActions, directoryPath),
                    operation: "posix_spawn_file_actions_addchdir_np"
                )
            }
        }

        var attributes: posix_spawnattr_t?
        try checkPOSIX(posix_spawnattr_init(&attributes), operation: "posix_spawnattr_init")
        defer { posix_spawnattr_destroy(&attributes) }
        try checkPOSIX(
            posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP)),
            operation: "posix_spawnattr_setflags"
        )
        try checkPOSIX(posix_spawnattr_setpgroup(&attributes, 0), operation: "posix_spawnattr_setpgroup")

        let argv = [executableURL.path] + arguments
        let environmentVariables = environment.map { "\($0.key)=\($0.value)" }.sorted()
        var pid = pid_t()
        let spawnResult = executableURL.path.withCString { executablePath in
            withCStringArray(argv) { argvPointer in
                withCStringArray(environmentVariables) { environmentPointer in
                    posix_spawn(&pid, executablePath, &fileActions, &attributes, argvPointer, environmentPointer)
                }
            }
        }
        try checkPOSIX(spawnResult, operation: "posix_spawn")
        return Self(pid: pid)
    }

    private static func addOpenFileAction(
        _ fileActions: inout posix_spawn_file_actions_t?,
        descriptor: Int32,
        path: String,
        flags: Int32,
        mode: mode_t
    ) throws {
        try path.withCString { pathPointer in
            try checkPOSIX(
                posix_spawn_file_actions_addopen(&fileActions, descriptor, pathPointer, flags, mode),
                operation: "posix_spawn_file_actions_addopen"
            )
        }
    }

    private static func withCStringArray<ReturnValue>(
        _ values: [String],
        _ body: (UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) throws -> ReturnValue
    ) rethrows -> ReturnValue {
        let cStrings: [UnsafeMutablePointer<CChar>] = values.map { strdup($0) }
        defer {
            for cString in cStrings {
                free(cString)
            }
        }
        var pointers: [UnsafeMutablePointer<CChar>?] = cStrings.map { $0 }
        pointers.append(nil)
        return try pointers.withUnsafeMutableBufferPointer { buffer in
            try body(buffer.baseAddress!)
        }
    }

    private static func checkPOSIX(_ result: Int32, operation: String) throws {
        guard result == 0 else {
            throw PosixGitProcessError(operation: operation, code: result)
        }
    }
}

private struct PosixGitProcessError: Error, CustomStringConvertible {
    let operation: String
    let code: Int32

    var description: String {
        "\(operation) failed with errno \(code): \(String(cString: strerror(code)))"
    }
}
