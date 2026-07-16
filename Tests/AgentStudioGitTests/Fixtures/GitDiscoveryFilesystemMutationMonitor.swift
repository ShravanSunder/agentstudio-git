import Darwin
import Foundation

private typealias GitDiscoveryKQueueEvent = Darwin.kevent
private let gitDiscoveryKQueueEventSystemCall:
    @Sendable (
        Int32,
        UnsafePointer<GitDiscoveryKQueueEvent>?,
        Int32,
        UnsafeMutablePointer<GitDiscoveryKQueueEvent>?,
        Int32,
        UnsafePointer<timespec>?
    ) -> Int32 = kevent

final class GitDiscoveryFilesystemMutationMonitor {
    struct Mutation: CustomStringConvertible, Equatable {
        let path: String
        let kinds: Set<Kind>

        enum Kind: String, CaseIterable, Comparable {
            case attribute
            case delete
            case extend
            case link
            case rename
            case revoke
            case write

            static func < (lhs: Self, rhs: Self) -> Bool {
                lhs.rawValue < rhs.rawValue
            }
        }

        var description: String {
            let kindDescription = kinds.sorted().map(\.rawValue).joined(separator: ",")
            return "\(path) [\(kindDescription)]"
        }
    }

    private let queueDescriptor: Int32
    private var pathByFileDescriptor: [Int32: String]
    private var isStopped = false

    private init(queueDescriptor: Int32, pathByFileDescriptor: [Int32: String]) {
        self.queueDescriptor = queueDescriptor
        self.pathByFileDescriptor = pathByFileDescriptor
    }

    deinit {
        stop()
    }

    static func startAndWaitUntilReady(scopeRoot: URL, watchedRoots: [URL]) throws -> Self {
        let standardizedScopeRoot = scopeRoot.standardizedFileURL
        let scopePrefix = standardizedScopeRoot.path + "/"
        var watchedPaths: Set<String> = []
        for watchedRoot in watchedRoots {
            let standardizedWatchedRoot = watchedRoot.standardizedFileURL
            guard
                standardizedWatchedRoot.path == standardizedScopeRoot.path
                    || standardizedWatchedRoot.path.hasPrefix(scopePrefix)
            else {
                throw GitDiscoveryFilesystemMutationMonitorError.pathOutsideScope(
                    path: standardizedWatchedRoot.path,
                    scopeRoot: standardizedScopeRoot.path
                )
            }
            try collectPathsRecursively(from: standardizedWatchedRoot, into: &watchedPaths)
        }

        let queueDescriptor = kqueue()
        guard queueDescriptor >= 0 else {
            throw GitDiscoveryFilesystemMutationMonitorError.systemCallFailed(
                operation: "kqueue",
                path: nil,
                errorNumber: errno
            )
        }

        var pathByFileDescriptor: [Int32: String] = [:]
        do {
            for path in watchedPaths.sorted() {
                let fileDescriptor = try openEventDescriptor(path: path)
                do {
                    try register(fileDescriptor: fileDescriptor, path: path, queueDescriptor: queueDescriptor)
                    pathByFileDescriptor[fileDescriptor] = path
                } catch {
                    Darwin.close(fileDescriptor)
                    throw error
                }
            }
        } catch {
            for fileDescriptor in pathByFileDescriptor.keys {
                Darwin.close(fileDescriptor)
            }
            Darwin.close(queueDescriptor)
            throw error
        }

        // Successful synchronous kevent registration is the readiness barrier; callers cannot write before every
        // descriptor is armed.
        return Self(queueDescriptor: queueDescriptor, pathByFileDescriptor: pathByFileDescriptor)
    }

    func flushAndDrain() throws -> [Mutation] {
        guard !isStopped else {
            throw GitDiscoveryFilesystemMutationMonitorError.monitorAlreadyStopped
        }

        var mutationFlagsByPath: [String: UInt32] = [:]
        var eventBuffer = [GitDiscoveryKQueueEvent](
            repeating: GitDiscoveryKQueueEvent(),
            count: max(pathByFileDescriptor.count, 1)
        )
        // Discovery and the control write complete their filesystem calls before this drain. Reading until an empty
        // zero-timeout result flushes every event already queued by those calls without a wall-clock wait.
        while true {
            var timeout = timespec(tv_sec: 0, tv_nsec: 0)
            let eventCount = eventBuffer.withUnsafeMutableBufferPointer { buffer in
                gitDiscoveryKQueueEventSystemCall(
                    queueDescriptor,
                    nil,
                    0,
                    buffer.baseAddress,
                    Int32(buffer.count),
                    &timeout
                )
            }
            if eventCount < 0 {
                if errno == EINTR {
                    continue
                }
                throw GitDiscoveryFilesystemMutationMonitorError.systemCallFailed(
                    operation: "kevent drain",
                    path: nil,
                    errorNumber: errno
                )
            }
            guard eventCount > 0 else {
                break
            }

            for event in eventBuffer.prefix(Int(eventCount)) {
                let fileDescriptor = Int32(event.ident)
                guard let path = pathByFileDescriptor[fileDescriptor] else {
                    throw GitDiscoveryFilesystemMutationMonitorError.unknownDescriptor(fileDescriptor)
                }
                mutationFlagsByPath[path, default: 0] |= event.fflags
            }
        }

        return mutationFlagsByPath.keys.sorted().map { path in
            Mutation(path: path, kinds: mutationKinds(for: mutationFlagsByPath[path] ?? 0))
        }
    }

    func stop() {
        guard !isStopped else {
            return
        }
        isStopped = true
        for fileDescriptor in pathByFileDescriptor.keys {
            Darwin.close(fileDescriptor)
        }
        pathByFileDescriptor.removeAll()
        Darwin.close(queueDescriptor)
    }

    private static func collectPathsRecursively(from root: URL, into paths: inout Set<String>) throws {
        let rootPath = root.path
        var status = stat()
        guard lstat(rootPath, &status) == 0 else {
            throw GitDiscoveryFilesystemMutationMonitorError.systemCallFailed(
                operation: "lstat",
                path: rootPath,
                errorNumber: errno
            )
        }
        guard paths.insert(rootPath).inserted else {
            return
        }
        guard status.st_mode & S_IFMT == S_IFDIR else {
            return
        }

        let children = try FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: nil,
            options: []
        )
        for child in children.sorted(by: { $0.path < $1.path }) {
            try collectPathsRecursively(from: child.standardizedFileURL, into: &paths)
        }
    }

    private static func openEventDescriptor(path: String) throws -> Int32 {
        var status = stat()
        guard lstat(path, &status) == 0 else {
            throw GitDiscoveryFilesystemMutationMonitorError.systemCallFailed(
                operation: "lstat",
                path: path,
                errorNumber: errno
            )
        }
        let symbolicLinkFlag = status.st_mode & S_IFMT == S_IFLNK ? O_SYMLINK : 0
        let fileDescriptor = open(path, O_EVTONLY | O_CLOEXEC | symbolicLinkFlag)
        guard fileDescriptor >= 0 else {
            throw GitDiscoveryFilesystemMutationMonitorError.systemCallFailed(
                operation: "open",
                path: path,
                errorNumber: errno
            )
        }
        return fileDescriptor
    }

    private static func register(fileDescriptor: Int32, path: String, queueDescriptor: Int32) throws {
        var registration = GitDiscoveryKQueueEvent(
            ident: UInt(fileDescriptor),
            filter: Int16(EVFILT_VNODE),
            flags: UInt16(EV_ADD | EV_ENABLE | EV_CLEAR),
            fflags: relevantMutationFlags,
            data: 0,
            udata: nil
        )
        let registrationResult = withUnsafePointer(to: &registration) { registrationPointer in
            gitDiscoveryKQueueEventSystemCall(queueDescriptor, registrationPointer, 1, nil, 0, nil)
        }
        guard registrationResult == 0 else {
            throw GitDiscoveryFilesystemMutationMonitorError.systemCallFailed(
                operation: "kevent register",
                path: path,
                errorNumber: errno
            )
        }
    }

    private static var relevantMutationFlags: UInt32 {
        // EVFILT_VNODE exposes no read/access-time flag. Registering mutation flags only therefore permits the
        // accepted read/access noise while rejecting content, namespace, and metadata mutations.
        UInt32(NOTE_DELETE | NOTE_WRITE | NOTE_EXTEND | NOTE_ATTRIB | NOTE_LINK | NOTE_RENAME | NOTE_REVOKE)
    }

    private func mutationKinds(for flags: UInt32) -> Set<Mutation.Kind> {
        var kinds: Set<Mutation.Kind> = []
        if flags & UInt32(NOTE_DELETE) != 0 {
            kinds.insert(.delete)
        }
        if flags & UInt32(NOTE_WRITE) != 0 {
            kinds.insert(.write)
        }
        if flags & UInt32(NOTE_EXTEND) != 0 {
            kinds.insert(.extend)
        }
        if flags & UInt32(NOTE_ATTRIB) != 0 {
            kinds.insert(.attribute)
        }
        if flags & UInt32(NOTE_LINK) != 0 {
            kinds.insert(.link)
        }
        if flags & UInt32(NOTE_RENAME) != 0 {
            kinds.insert(.rename)
        }
        if flags & UInt32(NOTE_REVOKE) != 0 {
            kinds.insert(.revoke)
        }
        return kinds
    }
}

private enum GitDiscoveryFilesystemMutationMonitorError: Error, CustomStringConvertible {
    case monitorAlreadyStopped
    case pathOutsideScope(path: String, scopeRoot: String)
    case systemCallFailed(operation: String, path: String?, errorNumber: Int32)
    case unknownDescriptor(Int32)

    var description: String {
        switch self {
        case .monitorAlreadyStopped:
            "filesystem mutation monitor was already stopped"
        case .pathOutsideScope(let path, let scopeRoot):
            "refusing to watch path outside disposable scope: \(path) (scope: \(scopeRoot))"
        case .systemCallFailed(let operation, let path, let errorNumber):
            "\(operation) failed\(path.map { " for \($0)" } ?? ""): \(String(cString: strerror(errorNumber)))"
        case .unknownDescriptor(let fileDescriptor):
            "filesystem mutation event used unknown descriptor \(fileDescriptor)"
        }
    }
}
