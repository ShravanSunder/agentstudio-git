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
        do {
            let stdoutCapture = try CapturedProcessOutputPipe(
                stream: .stdout,
                maxSizeBytes: configuration.capturedOutputLimitBytes
            )
            let stderrCapture = try CapturedProcessOutputPipe(
                stream: .stderr,
                maxSizeBytes: configuration.capturedOutputLimitBytes
            )
            defer {
                stdoutCapture.close()
                stderrCapture.close()
            }
            stdoutCapture.startReading()
            stderrCapture.startReading()

            let spawnedProcess = try PosixGitProcess.spawn(
                executableURL: invocation.executableURL,
                arguments: processArguments,
                environment: configuration.processEnvironment(),
                currentDirectory: currentDirectory,
                stdoutDescriptor: stdoutCapture.writeFileDescriptor,
                stderrDescriptor: stderrCapture.writeFileDescriptor
            )
            stdoutCapture.closeParentWriteDescriptor()
            stderrCapture.closeParentWriteDescriptor()
            let cancellationController = ProcessCancellationController(process: spawnedProcess)
            let waitResult = await withTaskCancellationHandler {
                waitForProcessExit(
                    spawnedProcess,
                    stdoutCapture: stdoutCapture,
                    stderrCapture: stderrCapture,
                    cancellationController: cancellationController
                )
            } onCancel: {
                cancellationController.cancel()
            }

            stdoutCapture.waitForReadCompletion(timeoutSeconds: 1)
            stderrCapture.waitForReadCompletion(timeoutSeconds: 1)

            if let outputLimit = waitResult.outputLimitExceeded
                ?? capturedOutputLimitExceeded(stdoutCapture: stdoutCapture, stderrCapture: stderrCapture)
            {
                throw GitDataPlaneError.processOutputTooLarge(
                    stream: outputLimit.stream,
                    sizeBytes: outputLimit.sizeBytes,
                    maxSizeBytes: outputLimit.maxSizeBytes
                )
            }

            let stdout = stdoutCapture.stringValue()
            let stderr = stderrCapture.stringValue()
            guard !waitResult.cancelled else {
                throw GitDataPlaneError.processCancelled(
                    GitRemoteProcessFailure.redacting(
                        executable: invocation.displayName,
                        arguments: processArguments,
                        exitCode: waitResult.exitCode,
                        stderr: cancellationStderr(stderr)
                    ))
            }
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

    private func waitForProcessExit(
        _ process: PosixGitProcess,
        stdoutCapture: CapturedProcessOutputPipe,
        stderrCapture: CapturedProcessOutputPipe,
        cancellationController: ProcessCancellationController
    ) -> ProcessWaitResult {
        let waitState = ProcessWaitState()
        let waitGroup = DispatchGroup()
        waitGroup.enter()
        DispatchQueue.global(qos: .utility).async {
            var status: Int32 = 0
            let result = waitpid(process.pid, &status, 0)
            waitState.store(result: result, status: status, waitErrno: errno)
            waitGroup.leave()
        }

        let deadline = Date().addingTimeInterval(configuration.operationTimeoutSeconds)
        while true {
            let waitResult = waitGroup.wait(timeout: .now() + 0.02)
            if waitResult != .timedOut {
                return ProcessWaitResult(
                    timedOut: false,
                    cancelled: cancellationController.isCancelled,
                    outputLimitExceeded: nil,
                    exitCode: waitState.exitCode
                )
            }

            if cancellationController.isCancelled {
                terminateProcessGroup(process, waitGroup: waitGroup)
                return ProcessWaitResult(
                    timedOut: false,
                    cancelled: true,
                    outputLimitExceeded: nil,
                    exitCode: waitState.exitCode
                )
            }

            if let outputLimit = capturedOutputLimitExceeded(
                stdoutCapture: stdoutCapture,
                stderrCapture: stderrCapture
            ) {
                terminateProcessGroup(process, waitGroup: waitGroup)
                return ProcessWaitResult(
                    timedOut: false,
                    cancelled: cancellationController.isCancelled,
                    outputLimitExceeded: outputLimit,
                    exitCode: waitState.exitCode
                )
            }

            if Date() >= deadline {
                terminateProcessGroup(process, waitGroup: waitGroup)
                return ProcessWaitResult(
                    timedOut: !cancellationController.isCancelled,
                    cancelled: cancellationController.isCancelled,
                    outputLimitExceeded: nil,
                    exitCode: waitState.exitCode
                )
            }
        }
    }

    private func terminateProcessGroup(_ process: PosixGitProcess, waitGroup: DispatchGroup) {
        killpg(process.processGroupID, SIGTERM)
        let terminatedAfterGrace = waitGroup.wait(timeout: .now() + 1) != .timedOut
        if !terminatedAfterGrace {
            killpg(process.processGroupID, SIGKILL)
            waitGroup.wait()
        }
    }

    private func capturedOutputLimitExceeded(
        stdoutCapture: CapturedProcessOutputPipe,
        stderrCapture: CapturedProcessOutputPipe
    ) -> CapturedOutputLimit? {
        stdoutCapture.outputLimitExceeded ?? stderrCapture.outputLimitExceeded
    }

    private func timeoutStderr(_ stderr: String) -> String {
        let timeoutMessage = "git process timed out after \(configuration.operationTimeoutSeconds) seconds"
        guard !stderr.isEmpty else {
            return timeoutMessage
        }
        return "\(stderr)\n\(timeoutMessage)"
    }

    private func cancellationStderr(_ stderr: String) -> String {
        let cancellationMessage = "git process cancelled"
        guard !stderr.isEmpty else {
            return cancellationMessage
        }
        return "\(stderr)\n\(cancellationMessage)"
    }
}

private struct ProcessWaitResult {
    let timedOut: Bool
    let cancelled: Bool
    let outputLimitExceeded: CapturedOutputLimit?
    let exitCode: Int32
}

private struct CapturedOutputLimit {
    let stream: GitProcessOutputStream
    let sizeBytes: Int64
    let maxSizeBytes: Int64
}

private final class CapturedProcessOutputPipe: @unchecked Sendable {
    private let lock = NSLock()
    private let stream: GitProcessOutputStream
    private let maxSizeBytes: Int64
    private let readDescriptor: Int32
    private var writeDescriptor: Int32?
    private var bufferedData = Data()
    private var observedSizeBytes: Int64 = 0
    private var outputLimit: CapturedOutputLimit?
    private var readDescriptorClosed = false
    private let readGroup = DispatchGroup()
    private var readerStarted = false

    init(stream: GitProcessOutputStream, maxSizeBytes: Int64) throws {
        var descriptors: [Int32] = [0, 0]
        guard pipe(&descriptors) == 0 else {
            throw PosixGitProcessError(operation: "pipe", code: errno)
        }
        self.stream = stream
        self.maxSizeBytes = maxSizeBytes
        readDescriptor = descriptors[0]
        writeDescriptor = descriptors[1]
    }

    var writeFileDescriptor: Int32 {
        lock.lock()
        defer { lock.unlock() }
        return writeDescriptor ?? -1
    }

    var outputLimitExceeded: CapturedOutputLimit? {
        lock.lock()
        defer { lock.unlock() }
        return outputLimit
    }

    func startReading() {
        lock.lock()
        guard !readerStarted else {
            lock.unlock()
            return
        }
        readerStarted = true
        readGroup.enter()
        lock.unlock()

        DispatchQueue.global(qos: .utility).async {
            self.readUntilEOF()
            self.readGroup.leave()
        }
    }

    func closeParentWriteDescriptor() {
        let descriptor = takeWriteDescriptor()
        if descriptor >= 0 {
            Darwin.close(descriptor)
        }
    }

    func waitForReadCompletion(timeoutSeconds: Double) {
        guard readGroup.wait(timeout: .now() + timeoutSeconds) == .timedOut else {
            return
        }
        closeReadDescriptor()
        readGroup.wait()
    }

    func stringValue() -> String {
        lock.lock()
        let data = bufferedData
        lock.unlock()
        let bytes = [UInt8](data)
        if let string = String(bytes: bytes, encoding: .utf8) {
            return string
        }
        return "<non-utf8 git process output>"
    }

    func close() {
        closeParentWriteDescriptor()
        closeReadDescriptor()
    }

    private func readUntilEOF() {
        var buffer = [UInt8](repeating: 0, count: 8192)
        while true {
            let bytesRead = buffer.withUnsafeMutableBufferPointer { pointer in
                Darwin.read(readDescriptor, pointer.baseAddress, pointer.count)
            }
            if bytesRead > 0 {
                buffer.withUnsafeBufferPointer { pointer in
                    if let baseAddress = pointer.baseAddress {
                        record(baseAddress, count: Int(bytesRead))
                    }
                }
                continue
            }
            if bytesRead == 0 {
                break
            }
            if errno == EINTR {
                continue
            }
            break
        }
        closeReadDescriptor()
    }

    private func record(_ bytes: UnsafePointer<UInt8>, count: Int) {
        lock.lock()
        observedSizeBytes += Int64(count)
        if observedSizeBytes > maxSizeBytes {
            outputLimit = CapturedOutputLimit(
                stream: stream,
                sizeBytes: observedSizeBytes,
                maxSizeBytes: maxSizeBytes
            )
        }
        let bufferedByteCount = Int64(bufferedData.count)
        if bufferedByteCount < maxSizeBytes {
            let remainingBytes = Int(maxSizeBytes - bufferedByteCount)
            bufferedData.append(bytes, count: min(count, remainingBytes))
        }
        lock.unlock()
    }

    private func takeWriteDescriptor() -> Int32 {
        lock.lock()
        defer { lock.unlock() }
        guard let descriptor = writeDescriptor else {
            return -1
        }
        writeDescriptor = nil
        return descriptor
    }

    private func closeReadDescriptor() {
        lock.lock()
        guard !readDescriptorClosed else {
            lock.unlock()
            return
        }
        readDescriptorClosed = true
        lock.unlock()
        Darwin.close(readDescriptor)
    }
}

private final class ProcessCancellationController: @unchecked Sendable {
    private let lock = NSLock()
    private let process: PosixGitProcess
    private var cancelled = false

    init(process: PosixGitProcess) {
        self.process = process
    }

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        lock.lock()
        let shouldSignal = !cancelled
        cancelled = true
        lock.unlock()

        guard shouldSignal else {
            return
        }
        killpg(process.processGroupID, SIGTERM)
    }
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
        stdoutDescriptor: Int32,
        stderrDescriptor: Int32
    ) throws -> Self {
        var fileActions: posix_spawn_file_actions_t?
        try checkPOSIX(posix_spawn_file_actions_init(&fileActions), operation: "posix_spawn_file_actions_init")
        defer { posix_spawn_file_actions_destroy(&fileActions) }

        try addOpenFileAction(&fileActions, descriptor: STDIN_FILENO, path: "/dev/null", flags: O_RDONLY, mode: 0)
        try addDuplicateFileAction(
            &fileActions,
            sourceDescriptor: stdoutDescriptor,
            targetDescriptor: STDOUT_FILENO
        )
        try addDuplicateFileAction(
            &fileActions,
            sourceDescriptor: stderrDescriptor,
            targetDescriptor: STDERR_FILENO
        )
        try addCloseFileAction(&fileActions, descriptor: stdoutDescriptor)
        try addCloseFileAction(&fileActions, descriptor: stderrDescriptor)
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

    private static func addDuplicateFileAction(
        _ fileActions: inout posix_spawn_file_actions_t?,
        sourceDescriptor: Int32,
        targetDescriptor: Int32
    ) throws {
        try checkPOSIX(
            posix_spawn_file_actions_adddup2(&fileActions, sourceDescriptor, targetDescriptor),
            operation: "posix_spawn_file_actions_adddup2"
        )
    }

    private static func addCloseFileAction(
        _ fileActions: inout posix_spawn_file_actions_t?,
        descriptor: Int32
    ) throws {
        try checkPOSIX(
            posix_spawn_file_actions_addclose(&fileActions, descriptor),
            operation: "posix_spawn_file_actions_addclose"
        )
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
