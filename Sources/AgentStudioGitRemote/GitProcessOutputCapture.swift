import AgentStudioGitContracts
import Darwin
import Foundation

struct CapturedOutputLimit {
    let stream: GitProcessOutputStream
    let sizeBytes: Int64
    let maxSizeBytes: Int64
}

final class CapturedProcessOutputPipe: @unchecked Sendable {
    private let lock = NSLock()
    private let stream: GitProcessOutputStream
    private let maxSizeBytes: Int64
    private let readDescriptor: Int32
    private var writeDescriptor: Int32?
    private var bufferedData = Data()
    private var observedSizeBytes: Int64 = 0
    private var outputLimit: CapturedOutputLimit?
    private var readDescriptorClosed = false
    private var readCompleted = false
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
        lock.unlock()

        DispatchQueue.global(qos: .utility).async {
            self.readUntilEOF()
            self.markReadCompleted()
        }
    }

    func closeParentWriteDescriptor() {
        let descriptor = takeWriteDescriptor()
        if descriptor >= 0 {
            Darwin.close(descriptor)
        }
    }

    func waitForReadCompletion(timeoutSeconds: Double) async {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            if isReadCompleted {
                return
            }
            await sleepForPollInterval()
        }
        closeReadDescriptor()
        while !isReadCompleted {
            await sleepForPollInterval()
        }
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

    private var isReadCompleted: Bool {
        lock.lock()
        defer { lock.unlock() }
        return readCompleted
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

    private func markReadCompleted() {
        lock.lock()
        readCompleted = true
        lock.unlock()
    }
}

func capturedOutputLimitExceeded(
    stdoutCapture: CapturedProcessOutputPipe,
    stderrCapture: CapturedProcessOutputPipe
) -> CapturedOutputLimit? {
    stdoutCapture.outputLimitExceeded ?? stderrCapture.outputLimitExceeded
}

func sleepForPollInterval() async {
    await withCheckedContinuation { continuation in
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + .milliseconds(20)) {
            continuation.resume()
        }
    }
}
