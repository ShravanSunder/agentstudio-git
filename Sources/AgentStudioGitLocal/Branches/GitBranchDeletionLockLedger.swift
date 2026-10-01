import AgentStudioGitLockSupport
import Darwin
import Foundation

/// Keeps residue evidence tied to lock files this deletion transaction actually acquired.
struct GitBranchDeletionLockLedger {
    private var acquiredLocks: [URL: LockFileIdentity] = [:]

    mutating func recordSuccessfulAcquisition(at path: URL) {
        guard let identity = Self.identity(at: path) else {
            return
        }
        acquiredLocks[path] = identity
    }

    func residue(using observer: GitLockResidueObserver) -> [URL] {
        acquiredLocks.compactMap { path, acquiredIdentity in
            guard observer.status(of: path) == .present,
                Self.identity(at: path) == acquiredIdentity
            else {
                return nil
            }
            return path
        }
        .sorted { $0.path < $1.path }
    }

    private static func identity(at path: URL) -> LockFileIdentity? {
        var fileStatus = Darwin.stat()
        let result = path.path.withCString { lstat($0, &fileStatus) }
        guard result == 0 else {
            return nil
        }
        return LockFileIdentity(device: Int64(fileStatus.st_dev), inode: UInt64(fileStatus.st_ino))
    }
}

private struct LockFileIdentity: Equatable {
    let device: Int64
    let inode: UInt64
}
