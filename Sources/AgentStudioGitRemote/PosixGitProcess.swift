import Darwin
import Foundation

struct PosixGitProcess {
    struct SpawnRequest {
        let executableURL: URL
        let arguments: [String]
        let environment: [String: String]
        let currentDirectory: URL?
        let stdinDescriptor: Int32?
        let stdoutDescriptor: Int32
        let stderrDescriptor: Int32
    }

    let pid: pid_t

    var processGroupID: pid_t {
        pid
    }

    static func spawn(_ request: SpawnRequest) throws -> Self {
        var fileActions: posix_spawn_file_actions_t?
        try checkPOSIX(posix_spawn_file_actions_init(&fileActions), operation: "posix_spawn_file_actions_init")
        defer { posix_spawn_file_actions_destroy(&fileActions) }

        if let stdinDescriptor = request.stdinDescriptor {
            try addDuplicateFileAction(
                &fileActions,
                sourceDescriptor: stdinDescriptor,
                targetDescriptor: STDIN_FILENO
            )
            try addCloseFileAction(&fileActions, descriptor: stdinDescriptor)
        } else {
            try addOpenFileAction(&fileActions, descriptor: STDIN_FILENO, path: "/dev/null", flags: O_RDONLY, mode: 0)
        }
        try addDuplicateFileAction(
            &fileActions,
            sourceDescriptor: request.stdoutDescriptor,
            targetDescriptor: STDOUT_FILENO
        )
        try addDuplicateFileAction(
            &fileActions,
            sourceDescriptor: request.stderrDescriptor,
            targetDescriptor: STDERR_FILENO
        )
        try addCloseFileAction(&fileActions, descriptor: request.stdoutDescriptor)
        try addCloseFileAction(&fileActions, descriptor: request.stderrDescriptor)
        if let currentDirectory = request.currentDirectory {
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

        let argv = [request.executableURL.path] + request.arguments
        let environmentVariables = request.environment.map { "\($0.key)=\($0.value)" }.sorted()
        var pid = pid_t()
        let spawnResult = request.executableURL.path.withCString { executablePath in
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

struct PosixGitProcessError: Error, CustomStringConvertible {
    let operation: String
    let code: Int32

    var description: String {
        "\(operation) failed with errno \(code): \(String(cString: strerror(code)))"
    }
}
