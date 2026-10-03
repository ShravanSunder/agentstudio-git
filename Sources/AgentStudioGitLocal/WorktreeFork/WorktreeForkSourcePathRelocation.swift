import Foundation

/// Where a source path lives after the fork. Every nested node's administration (common and worktree
/// private) moves to its re-homed administration, and the source tree moves to the destination tree; the
/// longest matching source location wins, so a path inside relocated administration never takes the plain
/// tree substitution (the fork's own `.git` is a gitfile, not the source's administration directory). The
/// source repository's common directory is the fork's own repository, so it is never a relocation source,
/// even when a nested linked worktree of that repository shares it.
struct WorktreeForkSourcePathRelocation: Sendable {
    enum Counterpart: Equatable, Sendable {
        /// Outside every relocated location: the path keeps its target.
        case outsideSource
        case relocated(URL)
        /// Beneath a source `.git` entry that no re-homed administration owns. Nothing was copied there, so
        /// there is no destination counterpart to name.
        case unmapped
    }

    private struct Relocation: Sendable {
        let source: URL
        let destination: URL
        let isSourceTree: Bool
    }

    private let relocations: [Relocation]

    init(plan: WorktreeForkPlan, administrationByNode: [String: URL]) {
        var relocations = [Relocation(source: plan.sourceRoot, destination: plan.destinationRoot, isSourceTree: true)]
        for node in plan.gitTopology.nodes {
            guard let administration = administrationByNode[node.relativePath] else {
                continue
            }
            for sourceAdministration in Set([node.sourceCommonDirectory, node.sourceGitDirectory])
            where sourceAdministration != plan.commonDirectory {
                relocations.append(
                    Relocation(source: sourceAdministration, destination: administration, isSourceTree: false))
            }
        }
        self.relocations = relocations
    }

    /// `path` must be canonical (see `canonicalized(absolutePath:)`).
    func counterpart(of path: URL) -> Counterpart {
        let match =
            relocations
            .compactMap { relocation -> (relocation: Relocation, remainder: String)? in
                WorktreeForkAdministrativeSymlinks.relativeComponents(of: path, beneath: relocation.source)
                    .map { (relocation, $0) }
            }
            .max { $0.relocation.source.pathComponents.count < $1.relocation.source.pathComponents.count }
        guard let match else {
            return .outsideSource
        }
        if match.relocation.isSourceTree, match.remainder.split(separator: "/").dropLast().contains(".git") {
            return .unmapped
        }
        let destination = match.relocation.destination
        return .relocated(match.remainder.isEmpty ? destination : destination.appending(path: match.remainder))
    }

    /// Canonical form of an absolute path whose tail may not exist (a missing include, a store created on
    /// demand): the deepest existing ancestor is resolved and the rest appended, so `/var/...` and
    /// `/private/var/...` compare equal.
    static func canonicalized(absolutePath: String) -> URL {
        var existing = URL(fileURLWithPath: absolutePath).standardizedFileURL
        var missing: [String] = []
        while case .failure = WorktreeForkDescriptors.realpathURL(existing), existing.pathComponents.count > 1 {
            missing.insert(existing.lastPathComponent, at: 0)
            existing.deleteLastPathComponent()
        }
        guard case .success(let canonical) = WorktreeForkDescriptors.realpathURL(existing) else {
            return URL(fileURLWithPath: absolutePath).standardizedFileURL
        }
        return missing.reduce(canonical) { $0.appending(path: $1) }
    }
}
