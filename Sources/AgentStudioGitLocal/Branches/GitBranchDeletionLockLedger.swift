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
        switch Self.observeIdentity(at: path) {
        case .present(let identity):
            acquiredLocks[path] = RecordedAcquisition(identity: identity)
        case .inaccessible:
            acquiredLocks[path] = RecordedAcquisition(identity: nil)
        case .absent:
            acquiredLocks.removeValue(forKey: path)
        }
    }

    mutating func residue(using observer: GitLockResidueObserver) -> [URL] {
        var residue: [URL] = []
        for path in Array(acquiredLocks.keys) {
            guard let acquisition = acquiredLocks[path] else {
                continue
            }
            switch observer.status(of: path) {
            case .absent:
                acquiredLocks.removeValue(forKey: path)
            case .inaccessible:
                residue.append(path)
            case .present:
                switch Self.observeIdentity(at: path) {
                case .absent:
                    acquiredLocks.removeValue(forKey: path)
                case .inaccessible:
                    residue.append(path)
                case .present(let observedIdentity):
                    guard let acquiredIdentity = acquisition.identity else {
                        residue.append(path)
                        continue
                    }
                    if observedIdentity == acquiredIdentity {
                        residue.append(path)
                    }
                }
            }
        }
        return residue.sorted { $0.path < $1.path }
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
