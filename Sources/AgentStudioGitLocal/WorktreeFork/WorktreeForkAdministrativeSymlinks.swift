import AgentStudioGitContracts
import Darwin
import Foundation

/// How one symlink inside a nested Git administration is reproduced. Copying link text verbatim would
/// leave the destination attached to source or external storage, so each link is classified at planning.
enum WorktreeForkAdministrativeSymlink: Equatable, Sendable {
    /// Resolves inside the node's own administration: recreated relative to the destination copy.
    case internalTarget(relativeToAdministration: String)
    /// Resolves to a directory outside it: mirrored as a destination-owned CoW store and linked there.
    case externalStore(URL)
}

enum WorktreeForkAdministrativeSymlinks {
    /// Classifies every symlink the administration cloner would reproduce beneath `administrationRoot`.
    static func classify(
        administrationRoot: URL,
        reportPath: String
    ) throws(GitWorktreeForkError) -> [String: WorktreeForkAdministrativeSymlink] {
        var classified: [String: WorktreeForkAdministrativeSymlink] = [:]
        for (relativePath, link) in symlinks(
            beneath: administrationRoot, skipping: WorktreeForkAdministrationCloner.isExcluded)
        {
            guard case .success(let target) = WorktreeForkDescriptors.realpathURL(link) else {
                throw unresolvable(reportPath)
            }
            if let inside = relativeComponents(of: target, beneath: administrationRoot) {
                classified[relativePath] = .internalTarget(relativeToAdministration: inside)
                continue
            }
            guard case .success(let info) = WorktreeForkDescriptors.lstatPath(target),
                WorktreeForkEntryKind(mode: info.st_mode) == .directory
            else {
                throw unresolvable(reportPath)
            }
            classified[relativePath] = .externalStore(target)
        }
        return classified
    }

    /// Link text for the mirror of `store`: a link resolving inside the same store is reproduced relative
    /// to its own directory, so it resolves inside the destination-owned mirror. An escaping or dangling
    /// link is rejected before mutation.
    static func storeSymlinkTargets(in store: URL, reportPath: String) throws(GitWorktreeForkError) -> [String: String]
    {
        var targets: [String: String] = [:]
        for (relativePath, link) in symlinks(beneath: store, skipping: { _ in false }) {
            guard case .success(let target) = WorktreeForkDescriptors.realpathURL(link),
                relativeComponents(of: target, beneath: store) != nil
            else {
                throw unresolvable(reportPath)
            }
            targets[relativePath] = WorktreeForkRelativePath.from(link.deletingLastPathComponent(), to: target)
        }
        return targets
    }

    /// Every symlink beneath `root`, keyed by root-relative path, without following any link.
    static func symlinks(beneath root: URL, skipping isSkipped: (String) -> Bool) -> [(String, URL)] {
        var found: [(String, URL)] = []
        var pending = [""]
        while let directory = pending.popLast() {
            let directoryURL = directory.isEmpty ? root : root.appending(path: directory)
            let names = (try? FileManager.default.contentsOfDirectory(atPath: directoryURL.path)) ?? []
            for name in names.sorted() {
                let relativePath = WorktreeForkDescriptors.joined(directory, name)
                guard !isSkipped(relativePath),
                    case .success(let info) = WorktreeForkDescriptors.lstatPath(root.appending(path: relativePath))
                else {
                    continue
                }
                switch WorktreeForkEntryKind(mode: info.st_mode) {
                case .symbolicLink:
                    found.append((relativePath, root.appending(path: relativePath)))
                case .directory:
                    pending.append(relativePath)
                default:
                    continue
                }
            }
        }
        return found
    }

    /// Component-wise containment (never string prefix) for canonical paths.
    static func relativeComponents(of path: URL, beneath root: URL) -> String? {
        let components = path.pathComponents
        let rootComponents = root.pathComponents
        guard components.count > rootComponents.count, Array(components.prefix(rootComponents.count)) == rootComponents
        else {
            return nil
        }
        return components.dropFirst(rootComponents.count).joined(separator: "/")
    }

    private static func unresolvable(_ reportPath: String) -> GitWorktreeForkError {
        .entryFailed(relativePath: reportPath, reason: .unresolvableGitAdministration, errorNumber: nil)
    }
}
