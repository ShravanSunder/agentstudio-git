import Darwin
import Foundation

final class GitProcessStandardInputFile {
    private var descriptor: Int32

    init(data: Data) throws {
        var template = Array("/tmp/agentstudio-git-input.XXXXXX".utf8CString)
        let openedDescriptor = mkstemp(&template)
        guard openedDescriptor >= 0 else {
            throw GitProcessStandardInputError(operation: "mkstemp", code: errno)
        }
        descriptor = openedDescriptor
        unlink(template)

        do {
            try writeAll(data)
            guard lseek(descriptor, 0, SEEK_SET) >= 0 else {
                throw GitProcessStandardInputError(operation: "lseek", code: errno)
            }
        } catch {
            closeDescriptor()
            throw error
        }
    }

    deinit {
        closeDescriptor()
    }

    func fileDescriptor() -> Int32 {
        descriptor
    }

    func closeParentDescriptor() {
        closeDescriptor()
    }

    private func writeAll(_ data: Data) throws {
        try data.withUnsafeBytes { rawBuffer in
            guard var baseAddress = rawBuffer.baseAddress else { return }
            var remainingByteCount = rawBuffer.count
            while remainingByteCount > 0 {
                let writtenByteCount = Darwin.write(descriptor, baseAddress, remainingByteCount)
                guard writtenByteCount >= 0 else {
                    if errno == EINTR { continue }
                    throw GitProcessStandardInputError(operation: "write", code: errno)
                }
                remainingByteCount -= writtenByteCount
                baseAddress = baseAddress.advanced(by: writtenByteCount)
            }
        }
    }

    private func closeDescriptor() {
        guard descriptor >= 0 else { return }
        close(descriptor)
        descriptor = -1
    }
}

private struct GitProcessStandardInputError: Error, CustomStringConvertible {
    let operation: String
    let code: Int32

    var description: String {
        "\(operation) failed with errno \(code): \(String(cString: strerror(code)))"
    }
}
