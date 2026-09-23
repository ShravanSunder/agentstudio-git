import AgentStudioGitContracts
import CLibGit2Local
import Darwin
import Foundation

/// A side effect the fork transaction created (or attempted), recorded before the call that creates it.
enum WorktreeForkJournalEntry: Equatable, Sendable {
    /// `identity` is filled once `git_worktree_add` succeeded, which proves the transaction created the
    /// destination; nil means creation was attempted, and a present path may belong to someone else.
    case destinationRoot(path: URL, identity: WorktreeForkEntryIdentity?)
    /// Same ownership rule as the destination: confirmed only after `git_worktree_add` succeeded.
    case linkedWorktreeAdministration(name: String, path: URL, identity: WorktreeForkEntryIdentity?)
    case createdBranch(referenceName: String, targetOID: String)
    /// `identity` is filled once the transaction's own `mkdir` succeeded; nil means creation was attempted
    /// but not confirmed, so a present path may belong to someone else and is never deleted.
    case nestedAdministration(path: URL, reportLocation: String, identity: WorktreeForkEntryIdentity?)
}

/// Owns transaction-created artifact identity, compensation, and residue proof. It lives on the lane's
/// serial queue for one call; there is deliberately no persistence or crash recovery.
struct WorktreeForkRollbackJournal {
    private(set) var entries: [WorktreeForkJournalEntry] = []
    let commonDirectory: URL
    let destinationRoot: URL
    let runtime: LibGit2Runtime

    init(commonDirectory: URL, destinationRoot: URL, runtime: LibGit2Runtime) {
        self.commonDirectory = commonDirectory
        self.destinationRoot = destinationRoot
        self.runtime = runtime
    }

    mutating func record(_ entry: WorktreeForkJournalEntry) {
        entries.append(entry)
    }

    mutating func confirmDestinationIdentity(_ identity: WorktreeForkEntryIdentity) {
        entries = entries.map { entry in
            if case .destinationRoot(let path, nil) = entry {
                return .destinationRoot(path: path, identity: identity)
            }
            return entry
        }
    }

    mutating func confirmLinkedWorktreeAdministration(_ identity: WorktreeForkEntryIdentity) {
        entries = entries.map { entry in
            if case .linkedWorktreeAdministration(let name, let path, nil) = entry {
                return .linkedWorktreeAdministration(name: name, path: path, identity: identity)
            }
            return entry
        }
    }

    mutating func confirmNestedAdministration(at path: URL, identity: WorktreeForkEntryIdentity) {
        entries = entries.map { entry in
            if case .nestedAdministration(path, let location, nil) = entry {
                return .nestedAdministration(path: path, reportLocation: location, identity: identity)
            }
            return entry
        }
    }

    /// A branch the transaction deleted itself (the detached-mode carrier branch) needs no compensation.
    mutating func forgetBranch(referenceName: String) {
        entries.removeAll { entry in
            if case .createdBranch(let name, _) = entry {
                return name == referenceName
            }
            return false
        }
    }

    /// Compensates every entry in dependency order, then re-probes each one. Returns ordered residue;
    /// an empty result means every journaled artifact is verified absent. No cleanup error is discarded.
    func rollback(faults: WorktreeForkFaultInjector) -> [GitWorktreeForkResidue] {
        var residue: [GitWorktreeForkResidue] = []
        for entry in entries.reversed() {
            if case .nestedAdministration(let path, let location, let identity) = entry,
                !removeOwned(path, identity: identity)
            {
                residue.append(GitWorktreeForkResidue(kind: .nestedAdministration, location: location))
            }
        }
        for entry in entries {
            if case .destinationRoot(let path, let identity) = entry,
                !removeDestination(path, identity: identity, faults: faults)
            {
                residue.append(GitWorktreeForkResidue(kind: .destinationContent, location: "."))
            }
        }
        for entry in entries {
            if case .linkedWorktreeAdministration(let name, let path, let identity) = entry,
                !removeOwned(path, identity: identity)
            {
                residue.append(
                    GitWorktreeForkResidue(kind: .linkedWorktreeAdministration, location: "worktrees/\(name)"))
            }
        }
        for entry in entries {
            if case .createdBranch(let referenceName, let targetOID) = entry,
                !deleteBranch(referenceName, targetOID: targetOID)
            {
                residue.append(GitWorktreeForkResidue(kind: .createdBranch, location: referenceName))
            }
        }
        return residue
    }

    private func removeDestination(
        _ path: URL,
        identity: WorktreeForkEntryIdentity?,
        faults: WorktreeForkFaultInjector
    ) -> Bool {
        if case .failure(let failure) = WorktreeForkDescriptors.lstatPath(path) {
            return failure.code == ENOENT
        }
        do throws(GitWorktreeForkError) {
            try faults.reach(.rollbackRemovingDestination)
        } catch {
            return false
        }
        return removeOwned(path, identity: identity)
    }

    /// Removes `path` only when the transaction confirmed creating it and it still has that identity. A
    /// present, unconfirmed path is never touched — emptiness does not establish ownership — and is reported
    /// as residue.
    private func removeOwned(_ path: URL, identity: WorktreeForkEntryIdentity?) -> Bool {
        let current: Darwin.stat
        switch WorktreeForkDescriptors.lstatPath(path) {
        case .success(let info):
            current = info
        case .failure(let failure):
            return failure.code == ENOENT
        }
        guard let identity, WorktreeForkEntryIdentity(current) == identity else {
            return false
        }
        return removeTree(path)
    }

    /// Removes a transaction-owned tree, first making every directory writable so restrictive modes
    /// reproduced from the source cannot block compensation. Symlinks are never followed.
    private func removeTree(_ path: URL) -> Bool {
        if case .failure(let failure) = WorktreeForkDescriptors.lstatPath(path) {
            return failure.code == ENOENT
        }
        let fileManager = FileManager.default
        if let enumerator = fileManager.enumerator(at: path, includingPropertiesForKeys: [.isDirectoryKey]) {
            for case let child as URL in enumerator
            where (try? child.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                _ = child.path.withCString { lchflags($0, 0) }
                _ = child.path.withCString { chmod($0, 0o700) }
            }
        }
        _ = path.path.withCString { lchflags($0, 0) }
        _ = path.path.withCString { chmod($0, 0o700) }
        do {
            try fileManager.removeItem(at: path)
        } catch {
            return false
        }
        if case .failure(let failure) = WorktreeForkDescriptors.lstatPath(path) {
            return failure.code == ENOENT
        }
        return false
    }

    private func deleteBranch(_ referenceName: String, targetOID: String) -> Bool {
        guard (try? runtime.ensureInitialized()) != nil else {
            return false
        }
        var repository: OpaquePointer?
        let openResult = commonDirectory.path.withCString { git_repository_open_bare(&repository, $0) }
        guard openResult >= 0, let repository else {
            return false
        }
        defer { git_repository_free(repository) }

        var reference: OpaquePointer?
        let lookupResult = referenceName.withCString { git_reference_lookup(&reference, repository, $0) }
        if lookupResult == GIT_ENOTFOUND.rawValue {
            return true
        }
        guard lookupResult >= 0, let reference else {
            return false
        }
        defer { git_reference_free(reference) }
        guard let target = git_reference_target(reference), oidString(target) == targetOID else {
            return false
        }
        guard git_branch_delete(reference) >= 0 else {
            return false
        }
        var probe: OpaquePointer?
        let probeResult = referenceName.withCString { git_reference_lookup(&probe, repository, $0) }
        if let probe {
            git_reference_free(probe)
        }
        return probeResult == GIT_ENOTFOUND.rawValue
    }
}

enum WorktreeForkObjectID {
    static func parse(_ hex: String) -> git_oid? {
        var oid = git_oid()
        let result = hex.withCString { git_oid_fromstr(&oid, $0) }
        return result == 0 ? oid : nil
    }
}
