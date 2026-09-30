import AgentStudioGitContracts
import AgentStudioGitLockSupport
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

    public func run(
        arguments: [String],
        currentDirectory: URL? = nil,
        standardInput: Data? = nil
    ) async throws(GitDataPlaneError)
        -> GitProcessResult
    {
        try await run(
            arguments: arguments,
            currentDirectory: currentDirectory,
            standardInput: standardInput,
            lockClassificationRepositoryPath: nil
        )
    }

    func run(
        arguments: [String],
        currentDirectory: URL? = nil,
        standardInput: Data? = nil,
        lockClassificationRepositoryPath: URL?
    ) async throws(GitDataPlaneError)
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

            let standardInputFile = try standardInput.map(GitProcessStandardInputFile.init(data:))
            let spawnedProcess = try PosixGitProcess.spawn(
                PosixGitProcess.SpawnRequest(
                    executableURL: invocation.executableURL,
                    arguments: processArguments,
                    environment: configuration.processEnvironment(),
                    currentDirectory: currentDirectory,
                    stdinDescriptor: standardInputFile?.fileDescriptor(),
                    stdoutDescriptor: stdoutCapture.writeFileDescriptor,
                    stderrDescriptor: stderrCapture.writeFileDescriptor
                )
            )
            standardInputFile?.closeParentDescriptor()
            stdoutCapture.closeParentWriteDescriptor()
            stderrCapture.closeParentWriteDescriptor()

            let cancellationController = ProcessCancellationController(process: spawnedProcess)
            let waitCoordinator = GitProcessWaitCoordinator(
                process: spawnedProcess,
                stdoutCapture: stdoutCapture,
                stderrCapture: stderrCapture,
                cancellationController: cancellationController,
                operationTimeoutSeconds: configuration.operationTimeoutSeconds
            )
            let waitResult = await withTaskCancellationHandler {
                await waitCoordinator.waitForExit()
            } onCancel: {
                cancellationController.cancel()
            }

            await stdoutCapture.waitForReadCompletion(timeoutSeconds: 1)
            await stderrCapture.waitForReadCompletion(timeoutSeconds: 1)

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
                throw await processFailure(
                    exitCode: waitResult.exitCode,
                    stderr: stderr,
                    executableName: invocation.displayName,
                    arguments: processArguments,
                    lockClassificationRepositoryPath: lockClassificationRepositoryPath
                )
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

    private func processFailure(
        exitCode: Int32,
        stderr: String,
        executableName: String,
        arguments: [String],
        lockClassificationRepositoryPath: URL?
    ) async -> GitDataPlaneError {
        if let lockClassificationRepositoryPath,
            let lockFailure = await classifyGitLockFailure(
                stderr: stderr,
                repositoryPath: lockClassificationRepositoryPath
            )
        {
            return lockFailure
        }

        return .processFailed(
            GitRemoteProcessFailure.redacting(
                executable: executableName,
                arguments: arguments,
                exitCode: exitCode,
                stderr: stderr
            )
        )
    }

    private func classifyGitLockFailure(stderr: String, repositoryPath: URL) async -> GitDataPlaneError? {
        guard stderr.contains("Unable to create '") && stderr.contains("File exists") else {
            return nil
        }

        let pathsResult = try? await run(arguments: [
            "-C",
            repositoryPath.path,
            "rev-parse",
            "--path-format=absolute",
            "--git-dir",
            "--git-common-dir",
        ])
        guard let pathsResult else {
            return nil
        }

        let paths = pathsResult.stdout.split(whereSeparator: \.isNewline)
        guard paths.count == 2 else {
            return nil
        }

        return GitLockDiagnosticClassifier.failure(
            stderr: stderr,
            repositoryPath: repositoryPath,
            gitDirectory: URL(fileURLWithPath: String(paths[0]), isDirectory: true),
            commonDirectory: URL(fileURLWithPath: String(paths[1]), isDirectory: true)
        )
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
