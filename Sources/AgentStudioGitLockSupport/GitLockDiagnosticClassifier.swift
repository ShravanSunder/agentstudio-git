import AgentStudioGitContracts
import Foundation

package enum GitLockDiagnosticClassifier {
    private static let diagnosticPrefix = "Unable to create '"
    private static let diagnosticSuffix = "': File exists"

    package static func failure(
        stderr: String,
        repositoryPath: URL,
        gitDirectory: URL,
        commonDirectory: URL,
        residueObserver: GitLockResidueObserver = .live
    ) -> GitDataPlaneError? {
        guard let lockPath = diagnosticPath(in: stderr),
            let resource = resource(
                for: lockPath,
                repositoryPath: repositoryPath,
                gitDirectory: gitDirectory,
                commonDirectory: commonDirectory
            )
        else {
            return nil
        }

        let lockFact = GitLockFact(path: lockPath, resource: resource)
        switch residueObserver.status(of: lockPath) {
        case .present:
            return .lockHeld(lockFact)
        case .absent, .inaccessible:
            return .lockUnidentified(resource)
        }
    }

    private static func diagnosticPath(in stderr: String) -> URL? {
        for line in stderr.split(separator: "\n", omittingEmptySubsequences: false) {
            let diagnosticLine = String(line).trimmingCharacters(in: .newlines)
            guard !diagnosticLine.hasPrefix("remote:"),
                diagnosticLine.hasPrefix("fatal:") || diagnosticLine.hasPrefix("error:")
            else {
                continue
            }

            guard let prefixRange = diagnosticLine.range(of: diagnosticPrefix),
                let suffixRange = diagnosticLine.range(of: diagnosticSuffix, options: .backwards)
            else {
                continue
            }

            let pathText = String(diagnosticLine[prefixRange.upperBound..<suffixRange.lowerBound])
            guard pathText.hasPrefix("/"), !pathText.isEmpty else {
                continue
            }
            return URL(fileURLWithPath: pathText).standardizedFileURL
        }
        return nil
    }

    private static func resource(
        for lockPath: URL,
        repositoryPath: URL,
        gitDirectory: URL,
        commonDirectory: URL
    ) -> GitLockResource? {
        let canonicalLockPath = canonicalURL(lockPath)
        let canonicalGitDirectory = canonicalURL(gitDirectory)
        let canonicalCommonDirectory = canonicalURL(commonDirectory)
        let canonicalRepositoryPath = canonicalURL(repositoryPath)

        guard
            isDescendant(canonicalLockPath.path, of: canonicalGitDirectory.path)
                || isDescendant(canonicalLockPath.path, of: canonicalCommonDirectory.path)
        else {
            return nil
        }

        if canonicalLockPath == canonicalGitDirectory.appending(path: "index.lock") {
            return .index(worktreePath: canonicalRepositoryPath)
        }
        if canonicalLockPath == canonicalCommonDirectory.appending(path: "packed-refs.lock") {
            return .packedRefs
        }
        if canonicalLockPath == canonicalCommonDirectory.appending(path: "config.lock")
            || canonicalLockPath == canonicalGitDirectory.appending(path: "config.worktree.lock")
        {
            return .config
        }

        for referenceDirectory in [canonicalGitDirectory, canonicalCommonDirectory] {
            guard
                let relativeLockPath = relativePath(
                    canonicalLockPath.path,
                    beneath: referenceDirectory.path
                ), relativeLockPath.hasPrefix("refs/"), relativeLockPath.hasSuffix(".lock")
            else {
                continue
            }
            let referenceName = String(relativeLockPath.dropLast(".lock".count))
            return .reference(name: referenceName)
        }
        return nil
    }

    private static func relativePath(_ path: String, beneath directory: String) -> String? {
        guard isDescendant(path, of: directory) else {
            return nil
        }
        return String(path.dropFirst(directory.count + 1))
    }

    private static func isDescendant(_ path: String, of directory: String) -> Bool {
        path.hasPrefix(directory.hasSuffix("/") ? directory : "\(directory)/")
    }

    private static func canonicalURL(_ url: URL) -> URL {
        var path = url.standardizedFileURL.resolvingSymlinksInPath().path
        while path.count > 1, path.hasSuffix("/") {
            path.removeLast()
        }
        return URL(fileURLWithPath: path, isDirectory: false)
    }
}
