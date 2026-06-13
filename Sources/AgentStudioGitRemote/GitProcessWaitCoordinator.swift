import Darwin
import Foundation

struct ProcessWaitResult {
    let timedOut: Bool
    let cancelled: Bool
    let outputLimitExceeded: CapturedOutputLimit?
    let exitCode: Int32
}

struct GitProcessWaitCoordinator {
    let process: PosixGitProcess
    let stdoutCapture: CapturedProcessOutputPipe
    let stderrCapture: CapturedProcessOutputPipe
    let cancellationController: ProcessCancellationController
    let operationTimeoutSeconds: Double

    func waitForExit() async -> ProcessWaitResult {
        let waitState = ProcessWaitState()
        startWaitingForProcessExit(waitState: waitState)

        let deadline = Date().addingTimeInterval(operationTimeoutSeconds)
        while true {
            if waitState.didExit {
                return ProcessWaitResult(
                    timedOut: false,
                    cancelled: cancellationController.isCancelled,
                    outputLimitExceeded: nil,
                    exitCode: waitState.exitCode
                )
            }

            if cancellationController.isCancelled {
                await terminateProcessGroup(waitState: waitState)
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
                await terminateProcessGroup(waitState: waitState)
                return ProcessWaitResult(
                    timedOut: false,
                    cancelled: cancellationController.isCancelled,
                    outputLimitExceeded: outputLimit,
                    exitCode: waitState.exitCode
                )
            }

            if Date() >= deadline {
                await terminateProcessGroup(waitState: waitState)
                return ProcessWaitResult(
                    timedOut: !cancellationController.isCancelled,
                    cancelled: cancellationController.isCancelled,
                    outputLimitExceeded: nil,
                    exitCode: waitState.exitCode
                )
            }

            await sleepForPollInterval()
        }
    }

    private func startWaitingForProcessExit(waitState: ProcessWaitState) {
        DispatchQueue.global(qos: .utility).async {
            var status: Int32 = 0
            let result = waitpid(process.pid, &status, 0)
            waitState.store(result: result, status: status, waitErrno: errno)
        }
    }

    private func terminateProcessGroup(waitState: ProcessWaitState) async {
        killpg(process.processGroupID, SIGTERM)
        let graceDeadline = Date().addingTimeInterval(1)
        while Date() < graceDeadline {
            if waitState.didExit {
                return
            }
            await sleepForPollInterval()
        }

        killpg(process.processGroupID, SIGKILL)
        while !waitState.didExit {
            await sleepForPollInterval()
        }
    }
}

final class ProcessCancellationController: @unchecked Sendable {
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
    private var result: pid_t?
    private var status: Int32 = 0
    private var waitErrno: Int32 = 0

    var didExit: Bool {
        lock.lock()
        defer { lock.unlock() }
        return result != nil
    }

    var exitCode: Int32 {
        lock.lock()
        defer { lock.unlock() }
        guard let result, result > 0 else {
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
