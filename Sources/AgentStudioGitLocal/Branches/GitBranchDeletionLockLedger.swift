import AgentStudioGitLockSupport
import Darwin
import Foundation

/// Keeps residue evidence tied to lock files this deletion transaction actually acquired.
struct GitBranchDeletionLockLedger {
    private struct RecordedAcquisition {
        let identity: LockFileIdentity?
    }

    private enum IdentityObservation {
        case present(LockFileIdentity)
        case absent
        case inaccessible
    }

    private var acquiredLocks: [URL: RecordedAcquisition] = [:]

    mutating func recordSuccessfulAcquisition(at path: URL) {
        acquiredLocks[path] = RecordedAcquisition(identity: Self.identity(at: path))
    }

    func residue(using observer: GitLockResidueObserver) -> [URL] {
        acquiredLocks.compactMap { path, acquisition in
            switch observer.status(of: path) {
            case .absent:
                return nil
            case .inaccessible:
                return path
            case .present:
                switch Self.observeIdentity(at: path) {
                case .absent:
                    return nil
                case .inaccessible:
                    return path
                case .present(let observedIdentity):
                    guard let acquiredIdentity = acquisition.identity else {
                        return path
                    }
                    return observedIdentity == acquiredIdentity ? path : nil
                }
            }
        }
        .sorted { $0.path < $1.path }
    }

    private static func identity(at path: URL) -> LockFileIdentity? {
        guard case .present(let identity) = observeIdentity(at: path) else {
            return nil
        }
        return identity
    }

    private static func observeIdentity(at path: URL) -> IdentityObservation {
        var fileStatus = Darwin.stat()
        let result = path.path.withCString { lstat($0, &fileStatus) }
        guard result == 0 else {
            return errno == ENOENT || errno == ENOTDIR ? .absent : .inaccessible
        }
        return .present(LockFileIdentity(device: Int64(fileStatus.st_dev), inode: UInt64(fileStatus.st_ino)))
    }
}

private struct LockFileIdentity: Equatable {
    let device: Int64
    let inode: UInt64
}
