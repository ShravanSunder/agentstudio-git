import AgentStudioGitContracts
import CLibGit2Local
import Darwin
import Foundation

/// Where one re-homed Git node now lives.
struct WorktreeForkRehomedNode: Sendable {
    let node: WorktreeForkGitNode
    let destinationWorktree: URL
    let destinationAdministration: URL
}

/// Gives every initialized nested Git node destination-owned administration: submodules beneath the fork's
/// own `$GIT_DIR/modules/...` (as Git lays out a linked worktree's submodules), independent repositories as
/// embedded `.git` directories, and every object alternate a destination-owned CoW mirror. No administrative
/// pointer is copied as final; each is rewritten for the destination. Git directories copied with ordinary
/// content keep their own copy, with every pointer into the source re-aimed at the destination.
struct GitRepositoryStateRehomer: Sendable {
    let plan: WorktreeForkPlan
    let cancellation: WorktreeForkCancellation
    let lockTracker: WorktreeForkLockTracker

    init(
        plan: WorktreeForkPlan,
        cancellation: WorktreeForkCancellation,
        lockTracker: WorktreeForkLockTracker = WorktreeForkLockTracker()
    ) {
        self.plan = plan
        self.cancellation = cancellation
        self.lockTracker = lockTracker
    }

    var rootAdministration: URL {
        plan.commonDirectory.appending(path: "worktrees").appending(path: plan.worktreeName)
    }

    func rehome(journal: inout WorktreeForkRollbackJournal) throws(GitWorktreeForkError) -> [WorktreeForkRehomedNode] {
        let topology = plan.gitTopology
        if let rootSparse = topology.rootSparse {
            try writeSparseState(rootSparse, administration: rootAdministration, reportPath: ".")
        }
        let mirrorByStore = try mirrorObjectStores(topology.mirroredObjectStores, journal: &journal)
        var administrationByNode: [String: URL] = [:]
        var rehomed: [WorktreeForkRehomedNode] = []
        for node in topology.nodes {
            try cancellation.throwIfCancelled()
            let destinationWorktree = plan.destinationRoot.appending(path: node.relativePath)
            let administration = destinationAdministration(for: node, administrationByNode: administrationByNode)
            try requireBeneath(administration, reportPath: "\(node.relativePath)/.git")
            administrationByNode[node.relativePath] = administration
            if case .submodule = node.kind {
                journal.record(
                    .nestedAdministration(
                        path: administration,
                        reportLocation: String(administration.path.dropFirst(plan.commonDirectory.path.count + 1)),
                        identity: nil
                    ))
            }
            try rehome(
                node, worktree: destinationWorktree, administration: administration, mirrorByStore: mirrorByStore
            ) { identity in
                journal.confirmNestedAdministration(at: administration, identity: identity)
            }
            rehomed.append(
                WorktreeForkRehomedNode(
                    node: node, destinationWorktree: destinationWorktree, destinationAdministration: administration))
        }
        for copied in topology.copiedGitDirectories {
            try cancellation.throwIfCancelled()
            try rehomeCopiedPointers(copied, administrationByNode: administrationByNode)
        }
        return rehomed
    }

    /// Rewrites each pointer in a copied Git directory's alternates and linked-worktree registrations that
    /// does not already lead, from the copy, to its destination counterpart. A pointer that already does
    /// (a relative path inside the tree, an absolute path outside it) keeps its bytes, so tracked fixtures
    /// stay clean.
    private func rehomeCopiedPointers(
        _ copied: WorktreeForkCopiedGitDirectory,
        administrationByNode: [String: URL]
    ) throws(GitWorktreeForkError) {
        let gitDirectory = plan.destinationRoot.appending(path: copied.relativePath)
        let alternatesPath = WorktreeForkAdministrationCloner.alternatesRelativePath
        let objects = gitDirectory.appending(path: "objects")
        let alternatesReportPath = "\(copied.relativePath)/\(alternatesPath)"
        var alternateLines: [String] = []
        for pointer in copied.alternates {
            alternateLines.append(
                try destinationLine(
                    for: pointer, resolvingFrom: objects, administrationByNode: administrationByNode,
                    reportPath: alternatesReportPath))
        }
        if alternateLines != copied.alternates.map(\.line) {
            try writeText(
                alternateLines.joined(separator: "\n") + "\n",
                to: gitDirectory.appending(path: alternatesPath),
                reportPath: alternatesReportPath
            )
        }
        for (registrationPath, pointer) in copied.worktreeRegistrations.sorted(by: { $0.key < $1.key }) {
            let registrationDirectory = WorktreeForkDescriptors.splitParent(registrationPath).parent
            let registration = gitDirectory.appending(path: registrationDirectory)
            let reportPath = "\(copied.relativePath)/\(registrationPath)"
            let line = try destinationLine(
                for: pointer, resolvingFrom: registration, administrationByNode: administrationByNode,
                reportPath: reportPath)
            if line != pointer.line {
                try writeText(line + "\n", to: gitDirectory.appending(path: registrationPath), reportPath: reportPath)
            }
        }
    }

    /// The text that leads from the copy to the pointer's destination counterpart, or to its unchanged
    /// target when it has none. The recorded text is kept when it already resolves there from the copy; a
    /// counterpart that does not exist would leave the copy dangling, so it fails the transaction.
    private func destinationLine(
        for pointer: WorktreeForkCopiedPointer,
        resolvingFrom base: URL,
        administrationByNode: [String: URL],
        reportPath: String
    ) throws(GitWorktreeForkError) -> String {
        guard let target = pointer.target else {
            return pointer.line
        }
        let wanted = destinationCounterpart(of: target, administrationByNode: administrationByNode) ?? target
        let recorded =
            pointer.line.hasPrefix("/") ? URL(fileURLWithPath: pointer.line) : base.appending(path: pointer.line)
        if case .success(let resolved) = WorktreeForkDescriptors.realpathURL(recorded), resolved.path == wanted.path {
            return pointer.line
        }
        guard case .success = WorktreeForkDescriptors.realpathURL(wanted) else {
            throw .entryFailed(relativePath: reportPath, reason: .unresolvableGitAdministration, errorNumber: nil)
        }
        return wanted.path
    }

    /// Copied content maps to its destination copy. A path beneath a nested `.git` entry or the source
    /// repository's administration is not copied; it maps to the re-homed node administration that owns it.
    /// Anything outside the source tree and the source administration has no counterpart and keeps its target.
    private func destinationCounterpart(of target: URL, administrationByNode: [String: URL]) -> URL? {
        let inSourceTree = WorktreeForkAdministrativeSymlinks.relativeComponents(of: target, beneath: plan.sourceRoot)
        if let inSourceTree, !inSourceTree.split(separator: "/").dropLast().contains(".git") {
            return inSourceTree.isEmpty ? plan.destinationRoot : plan.destinationRoot.appending(path: inSourceTree)
        }
        let inSourceAdministration =
            WorktreeForkAdministrativeSymlinks.relativeComponents(of: target, beneath: plan.commonDirectory) != nil
        guard inSourceTree != nil || inSourceAdministration else {
            return nil
        }
        let owner = plan.gitTopology.nodes
            .compactMap { node -> (administration: URL, remainder: String, depth: Int)? in
                guard let administration = administrationByNode[node.relativePath],
                    let remainder = WorktreeForkAdministrativeSymlinks.relativeComponents(
                        of: target, beneath: node.sourceCommonDirectory)
                else {
                    return nil
                }
                return (administration, remainder, node.sourceCommonDirectory.pathComponents.count)
            }
            .max { $0.depth < $1.depth }
        guard let owner else {
            return nil
        }
        return owner.remainder.isEmpty ? owner.administration : owner.administration.appending(path: owner.remainder)
    }

    /// Defense in depth behind the planner's name rule: destination administration must sit beneath the
    /// fork's own administration or the destination tree, compared by path components, never by prefix.
    private func requireBeneath(_ administration: URL, reportPath: String) throws(GitWorktreeForkError) {
        let components = administration.pathComponents
        let isBeneath = [rootAdministration, plan.destinationRoot].contains { root in
            let rootComponents = root.pathComponents
            return components.count > rootComponents.count
                && Array(components.prefix(rootComponents.count)) == rootComponents
        }
        guard isBeneath, !components.contains(".."), !components.contains(".") else {
            throw .entryFailed(relativePath: reportPath, reason: .unresolvableGitAdministration, errorNumber: nil)
        }
    }

    private func destinationAdministration(
        for node: WorktreeForkGitNode,
        administrationByNode: [String: URL]
    ) -> URL {
        switch node.kind {
        case .submodule(let name):
            let parentAdministration =
                node.parentRelativePath.flatMap { administrationByNode[$0] } ?? rootAdministration
            return parentAdministration.appending(path: "modules").appending(path: name)
        case .embeddedRepository, .flattenedRepository:
            return plan.destinationRoot.appending(path: node.relativePath).appending(path: ".git")
        }
    }

    private func rehome(
        _ node: WorktreeForkGitNode,
        worktree: URL,
        administration: URL,
        mirrorByStore: [URL: URL],
        created: (WorktreeForkEntryIdentity) -> Void
    ) throws(GitWorktreeForkError) {
        let reportPath = "\(node.relativePath)/.git"
        var cloner = WorktreeForkAdministrationCloner(reportPath: reportPath)
        cloner.symlinkTargets = try symlinkTargets(node, administration: administration, mirrorByStore: mirrorByStore)
        try cloner.cloneTree(from: node.sourceCommonDirectory, to: administration, created: created)
        if node.sourceGitDirectory != node.sourceCommonDirectory {
            try overlayPrivateAdministration(node, administration: administration, reportPath: reportPath)
        }
        try writeText(headContents(node), to: administration.appending(path: "HEAD"), reportPath: reportPath)
        try writeAlternates(node, administration: administration, mirrorByStore: mirrorByStore, reportPath: reportPath)

        var configurationEdits: [WorktreeForkConfigurationEdit] = [.setBool("core.bare", false)]
        switch node.kind {
        case .submodule:
            configurationEdits.append(
                .setString("core.worktree", WorktreeForkRelativePath.from(administration, to: worktree)))
        case .embeddedRepository, .flattenedRepository:
            configurationEdits.append(.delete("core.worktree"))
        }
        if node.sparse != nil {
            configurationEdits.append(.setBool("index.sparse", false))
        }
        try WorktreeForkConfigurationFile.apply(
            configurationEdits,
            to: administration.appending(path: "config"),
            lockTracker: lockTracker
        )
        if case .submodule = node.kind {
            let pointer = "gitdir: \(WorktreeForkRelativePath.from(worktree, to: administration))\n"
            try writeText(pointer, to: worktree.appending(path: ".git"), reportPath: reportPath)
        }
        if let sparse = node.sparse {
            try writeSparseState(sparse, administration: administration, reportPath: reportPath)
        }
        try sanitizeWorktreeConfiguration(in: administration)
    }

    /// Destination link text for each classified administrative symlink: internal links point at the
    /// destination copy of their target, external stores at their destination-owned mirror.
    private func symlinkTargets(
        _ node: WorktreeForkGitNode,
        administration: URL,
        mirrorByStore: [URL: URL]
    ) throws(GitWorktreeForkError) -> [String: String] {
        var targets: [String: String] = [:]
        for (relativePath, symlink) in node.administrativeSymlinks {
            switch symlink {
            case .internalTarget(let relativeTarget):
                let linkDirectory = administration.appending(path: relativePath).deletingLastPathComponent()
                targets[relativePath] = WorktreeForkRelativePath.from(
                    linkDirectory, to: administration.appending(path: relativeTarget))
            case .externalStore(let store):
                guard let mirror = mirrorByStore[store] else {
                    throw .entryFailed(
                        relativePath: "\(node.relativePath)/.git", reason: .unresolvableGitAdministration,
                        errorNumber: nil)
                }
                targets[relativePath] = mirror.path
            }
        }
        return targets
    }

    /// A gitfile-reached node keeps its worktree-private identity (`HEAD` is rewritten from the plan) and
    /// worktree configuration; its common administration was cloned above.
    private func overlayPrivateAdministration(
        _ node: WorktreeForkGitNode,
        administration: URL,
        reportPath: String
    ) throws(GitWorktreeForkError) {
        // The cloned common directory's config.worktree belongs to that repository's main worktree, not
        // to this one; only the node's own worktree-private configuration may carry over.
        let destinationConfiguration = administration.appending(path: "config.worktree")
        if case .success = WorktreeForkDescriptors.lstatPath(destinationConfiguration),
            (try? FileManager.default.removeItem(at: destinationConfiguration)) == nil
        {
            throw .entryFailed(relativePath: reportPath, reason: .entryCreationFailed, errorNumber: nil)
        }
        let privateConfiguration = node.sourceGitDirectory.appending(path: "config.worktree")
        if let contents = try? Data(contentsOf: privateConfiguration) {
            try writeData(contents, to: destinationConfiguration, reportPath: reportPath)
        }
    }

    /// A worktree-scoped `core.worktree` (Git moves the main worktree's there when worktree config is
    /// enabled) or `core.bare` would point the destination at the source; neither is ever carried over.
    private func sanitizeWorktreeConfiguration(in administration: URL) throws(GitWorktreeForkError) {
        let configuration = administration.appending(path: "config.worktree")
        guard case .success = WorktreeForkDescriptors.lstatPath(configuration) else {
            return
        }
        try WorktreeForkConfigurationFile.apply(
            [.delete("core.worktree"), .delete("core.bare")], to: configuration, lockTracker: lockTracker)
    }

    private func headContents(_ node: WorktreeForkGitNode) -> String {
        if let headReferenceName = node.headReferenceName {
            return "ref: \(headReferenceName)\n"
        }
        return "\(node.capturedHead?.commitOID ?? "")\n"
    }

    private func writeAlternates(
        _ node: WorktreeForkGitNode,
        administration: URL,
        mirrorByStore: [URL: URL],
        reportPath: String
    ) throws(GitWorktreeForkError) {
        let direct = try Self.directAlternates(node.sourceCommonDirectory.appending(path: "objects"), reportPath)
        guard !direct.isEmpty else {
            return
        }
        let lines = direct.compactMap { mirrorByStore[$0]?.path }
        guard lines.count == direct.count else {
            throw .entryFailed(relativePath: reportPath, reason: .unresolvableGitAdministration, errorNumber: nil)
        }
        try writeText(
            lines.joined(separator: "\n") + "\n",
            to: administration.appending(path: WorktreeForkAdministrationCloner.alternatesRelativePath),
            reportPath: reportPath
        )
    }

    /// Mirrors each borrowed object store once, beneath the fork's own administration, and points each
    /// mirror's own alternates at the corresponding mirrors so the closure never leaves destination state.
    private func mirrorObjectStores(
        _ stores: [URL],
        journal: inout WorktreeForkRollbackJournal
    ) throws(GitWorktreeForkError) -> [URL: URL] {
        var mirrorByStore: [URL: URL] = [:]
        for (index, store) in stores.enumerated() {
            let mirror = rootAdministration.appending(path: "agentstudio-object-mirrors").appending(path: "\(index)")
            let location = "worktrees/\(plan.worktreeName)/agentstudio-object-mirrors/\(index)"
            journal.record(.nestedAdministration(path: mirror, reportLocation: location, identity: nil))
            var cloner = WorktreeForkAdministrationCloner(reportPath: location)
            cloner.symlinkTargets = plan.gitTopology.mirroredStoreSymlinks[store] ?? [:]
            try cloner.cloneTree(from: store, to: mirror) { identity in
                journal.confirmNestedAdministration(at: mirror, identity: identity)
            }
            mirrorByStore[store] = mirror
        }
        for store in stores {
            guard let mirror = mirrorByStore[store] else {
                continue
            }
            let direct = try Self.directAlternates(store, "")
            if !direct.isEmpty {
                let lines = direct.compactMap { mirrorByStore[$0]?.path }.joined(separator: "\n")
                try writeText(lines + "\n", to: mirror.appending(path: "info/alternates"), reportPath: ".")
            }
        }
        return mirrorByStore
    }

    private func writeSparseState(
        _ sparse: WorktreeForkSparsePlan,
        administration: URL,
        reportPath: String
    ) throws(GitWorktreeForkError) {
        try writeData(
            sparse.patternFile, to: administration.appending(path: "info/sparse-checkout"), reportPath: reportPath)
        guard let worktreeConfiguration = sparse.worktreeConfiguration else {
            return
        }
        let destination = administration.appending(path: "config.worktree")
        try writeData(worktreeConfiguration, to: destination, reportPath: reportPath)
        try WorktreeForkConfigurationFile.apply(
            [.setBool("index.sparse", false), .delete("core.worktree"), .delete("core.bare")],
            to: destination,
            lockTracker: lockTracker
        )
    }

    static func directAlternates(_ objectsDirectory: URL, _ reportPath: String) throws(GitWorktreeForkError) -> [URL] {
        try WorktreeForkGitTopologyPlanner.alternateLines(objectsDirectory).map { line throws(GitWorktreeForkError) in
            let candidate = line.hasPrefix("/") ? URL(fileURLWithPath: line) : objectsDirectory.appending(path: line)
            guard case .success(let canonical) = WorktreeForkDescriptors.realpathURL(candidate) else {
                throw .entryFailed(relativePath: reportPath, reason: .unresolvableGitAdministration, errorNumber: nil)
            }
            return canonical
        }
    }

    private func writeText(_ text: String, to url: URL, reportPath: String) throws(GitWorktreeForkError) {
        try writeData(Data(text.utf8), to: url, reportPath: reportPath)
    }

    /// Replaces `url` atomically. Cloned administration keeps the source's file modes, and tools such as
    /// SwiftPM make files like `.git/HEAD` read-only, so writing in place fails with EACCES. A same-directory
    /// temporary file renamed over the target needs only directory write permission, and it keeps the
    /// replaced file's mode.
    private func writeData(_ data: Data, to url: URL, reportPath: String) throws(GitWorktreeForkError) {
        let directory = url.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            throw .entryFailed(
                relativePath: reportPath, reason: .entryCreationFailed, errorNumber: Self.errorNumber(of: error))
        }
        let mode = Self.replacementMode(for: url)
        let temporary = directory.appending(path: ".\(url.lastPathComponent).agentstudio-\(UUID().uuidString).tmp")
        let descriptor = temporary.path.withCString { open($0, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600) }
        guard descriptor >= 0 else {
            throw .entryFailed(relativePath: reportPath, reason: .entryCreationFailed, errorNumber: errno)
        }
        var failure: Int32?
        data.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else { return }
            var offset = 0
            while offset < buffer.count, failure == nil {
                let written = write(descriptor, base + offset, buffer.count - offset)
                if written < 0 {
                    if errno != EINTR { failure = errno }
                } else {
                    offset += written
                }
            }
        }
        if failure == nil, fchmod(descriptor, mode) != 0 { failure = errno }
        if close(descriptor) != 0, failure == nil { failure = errno }
        if failure == nil, rename(temporary.path, url.path) != 0 { failure = errno }
        if let failure {
            _ = unlink(temporary.path)
            throw .entryFailed(relativePath: reportPath, reason: .entryCreationFailed, errorNumber: failure)
        }
    }

    /// The replaced file's permission bits when it exists as a regular file, otherwise 0644.
    private static func replacementMode(for url: URL) -> mode_t {
        var status = stat()
        guard url.path.withCString({ lstat($0, &status) }) == 0, status.st_mode & S_IFMT == S_IFREG else {
            return 0o644
        }
        return status.st_mode & 0o7777
    }

    private static func errorNumber(of error: Error) -> Int32? {
        ((error as NSError).userInfo[NSUnderlyingErrorKey] as? NSError).map { Int32($0.code) }
    }
}

enum WorktreeForkConfigurationEdit: Sendable {
    case setBool(String, Bool)
    case setString(String, String)
    case delete(String)
}

/// Edits one Git configuration file through libgit2 so its syntax and locking stay Git's.
enum WorktreeForkConfigurationFile {
    static func apply(
        _ edits: [WorktreeForkConfigurationEdit],
        to path: URL,
        lockTracker: WorktreeForkLockTracker? = nil
    ) throws(GitWorktreeForkError) {
        var configuration: OpaquePointer?
        let openResult = path.path.withCString { git_config_open_ondisk(&configuration, $0) }
        guard openResult >= 0, let configuration else {
            throw .gitFailure(LibGit2ErrorCapture.failure(code: openResult))
        }
        defer { git_config_free(configuration) }
        let lockFact = GitLockFact(
            path: URL(fileURLWithPath: "\(path.path).lock").standardizedFileURL,
            resource: .config
        )
        for edit in edits {
            lockTracker?.beginAttempt(for: [lockFact])
            errno = 0
            let result: Int32
            switch edit {
            case .setBool(let name, let value):
                result = git_config_set_bool(configuration, name, value ? 1 : 0)
            case .setString(let name, let value):
                result = git_config_set_string(configuration, name, value)
            case .delete(let name):
                let deleteResult = git_config_delete_entry(configuration, name)
                result = deleteResult == GIT_ENOTFOUND.rawValue ? 0 : deleteResult
            }
            let systemErrorCode = errno
            guard result >= 0 else {
                lockTracker?.recordFailure(for: [lockFact])
                throw .gitFailure(
                    LibGit2ErrorCapture.failure(
                        code: result,
                        lockFacts: [lockFact],
                        systemErrorCode: systemErrorCode
                    ))
            }
        }
    }
}

enum WorktreeForkRelativePath {
    /// Relative path from directory `origin` to `target`; both are canonical absolute paths.
    static func from(_ origin: URL, to target: URL) -> String {
        let originComponents = origin.pathComponents
        let targetComponents = target.pathComponents
        var shared = 0
        while shared < min(originComponents.count, targetComponents.count),
            originComponents[shared] == targetComponents[shared]
        {
            shared += 1
        }
        let ascent = Array(repeating: "..", count: originComponents.count - shared)
        let descent = targetComponents[shared...]
        let components = ascent + descent
        return components.isEmpty ? "." : components.joined(separator: "/")
    }
}
