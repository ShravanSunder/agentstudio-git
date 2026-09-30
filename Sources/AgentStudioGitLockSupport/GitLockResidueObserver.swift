import Darwin
import Foundation

package enum GitLockPathStatus: Equatable, Sendable {
    case present
    case absent
    case inaccessible
}

package struct GitLockResidueObserver: Sendable {
    package static let live = Self(pathStatus: Self.inspectPath)

    private let pathStatus: @Sendable (URL) -> GitLockPathStatus

    package init(pathStatus: @escaping @Sendable (URL) -> GitLockPathStatus) {
        self.pathStatus = pathStatus
    }

    package func status(of path: URL) -> GitLockPathStatus {
        pathStatus(path)
    }

    package func residue(for possibleLockPaths: [URL]) -> [URL] {
        var seenPaths: Set<URL> = []
        return possibleLockPaths.filter { path in
            guard seenPaths.insert(path).inserted else {
                return false
            }
            return status(of: path) != .absent
        }
    }

    private static func inspectPath(_ path: URL) -> GitLockPathStatus {
        var fileStatus = stat()
        let result = path.path.withCString { pathPointer in
            lstat(pathPointer, &fileStatus)
        }
        guard result != 0 else {
            return .present
        }

        let errorNumber = errno
        if errorNumber == ENOENT || errorNumber == ENOTDIR {
            return .absent
        }
        return .inaccessible
    }
}
