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

/// Re-homed nodes plus every administration tree cloned for them. The trees' directory metadata is
/// reproduced only after the last administration write (re-homing and index builds) has landed.
struct WorktreeForkRehomeOutcome: Sendable {
    var nodes: [WorktreeForkRehomedNode] = []
    var administrationTrees: [WorktreeForkClonedAdministrationTree] = []

    /// Child trees (nested submodule administration, created later) are finalized before their parents.
    func finalizeAdministrationDirectories() throws(GitWorktreeForkError) -> [GitWorktreeMaterializationNormalizedEntry]
    {
        var normalized: [GitWorktreeMaterializationNormalizedEntry] = []
        for tree in administrationTrees.reversed() {
            normalized += try tree.finalizeDirectories()
        }
        return normalized
    }
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

    func rehome(journal: inout WorktreeForkRollbackJournal) throws(GitWorktreeForkError) -> WorktreeForkRehomeOutcome {
        let topology = plan.gitTopology
        if let rootSparse = topology.rootSparse {
            try writeSparseState(rootSparse, administration: rootAdministration, reportPath: ".")
        }
        var outcome = WorktreeForkRehomeOutcome()
        let mirrorByStore = try mirrorObjectStores(
            topology.mirroredObjectStores, journal: &journal, trees: &outcome.administrationTrees)
        var administrationByNode: [String: URL] = [:]
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
            let tree = try rehome(
                node, worktree: destinationWorktree, administration: administration, mirrorByStore: mirrorByStore
            ) { identity in
                journal.confirmNestedAdministration(at: administration, identity: identity)
            }
            outcome.administrationTrees.append(tree)
            outcome.nodes.append(
                WorktreeForkRehomedNode(
                    node: node, destinationWorktree: destinationWorktree, destinationAdministration: administration))
        }
        let relocation = WorktreeForkSourcePathRelocation(plan: plan, administrationByNode: administrationByNode)
        for node in outcome.nodes {
            try cancellation.throwIfCancelled()
            try rehomeConfigurationPaths(
                in: node.destinationAdministration, reportPath: "\(node.node.relativePath)/.git",
                relocation: relocation)
        }
        for copied in topology.copiedGitDirectories {
            try cancellation.throwIfCancelled()
            try rehomeCopiedPointers(copied, relocation: relocation)
            try rehomeConfigurationPaths(
                in: plan.destinationRoot.appending(path: copied.relativePath), reportPath: copied.relativePath,
                relocation: relocation)
        }
        return outcome
    }

    /// Re-aims every absolute path a repository's own configuration records (`include.path`, `lfs.storage`,
    /// `core.hooksPath`, a local remote URL, any key) at its destination counterpart. Paths outside the
    /// relocated locations keep their target; a path with no counterpart fails rather than being guessed.
    private func rehomeConfigurationPaths(
        in administration: URL,
        reportPath: String,
        relocation: WorktreeForkSourcePathRelocation
    ) throws(GitWorktreeForkError) {
        for fileName in WorktreeForkConfigurationFile.repositoryFileNames {
            let file = administration.appending(path: fileName)
            guard case .success = WorktreeForkDescriptors.lstatPath(file) else {
                continue
            }
            var edits: [WorktreeForkConfigurationEdit] = []
            for entry in try WorktreeForkConfigurationFile.absolutePathEntries(in: file) {
                let source = WorktreeForkSourcePathRelocation.canonicalized(absolutePath: entry.value)
                switch relocation.counterpart(of: source) {
                case .outsideSource:
                    continue
                case .relocated(let destination) where destination.path != entry.value:
                    edits.append(.replaceValue(entry.name, matching: entry.value, with: destination.path))
                case .relocated:
                    continue
                case .unmapped:
                    let sourcePath =
                        WorktreeForkAdministrativeSymlinks.relativeComponents(of: source, beneath: plan.sourceRoot)
                        ?? source.lastPathComponent
                    throw .entryFailed(
                        relativePath: "\(reportPath)/\(fileName): \(entry.name) = \(sourcePath)",
                        reason: .unresolvableGitAdministration,
                        errorNumber: nil
                    )
                }
            }
            if !edits.isEmpty {
                try WorktreeForkConfigurationFile.apply(
                    edits, to: file, reportPath: "\(reportPath)/\(fileName)", lockTracker: lockTracker)
            }
        }
    }

    /// Rewrites each pointer in a copied Git directory's alternates and linked-worktree registrations that
    /// does not already lead, from the copy, to its destination counterpart. A pointer that already does
    /// (a relative path inside the tree, an absolute path outside it) keeps its bytes, so tracked fixtures
    /// stay clean.
    private func rehomeCopiedPointers(
        _ copied: WorktreeForkCopiedGitDirectory,
        relocation: WorktreeForkSourcePathRelocation
    ) throws(GitWorktreeForkError) {
        let gitDirectory = plan.destinationRoot.appending(path: copied.relativePath)
        let alternatesPath = WorktreeForkAdministrationCloner.alternatesRelativePath
        let objects = gitDirectory.appending(path: "objects")
        let alternatesReportPath = "\(copied.relativePath)/\(alternatesPath)"
        var alternateLines: [String] = []
        for pointer in copied.alternates {
            alternateLines.append(
                try destinationLine(
                    for: pointer, resolvingFrom: objects, relocation: relocation, reportPath: alternatesReportPath))
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
                for: pointer, resolvingFrom: registration, relocation: relocation, reportPath: reportPath)
            if line != pointer.line {
                try writeText(line + "\n", to: gitDirectory.appending(path: registrationPath), reportPath: reportPath)
            }
        }
    }

    /// The text that leads from the copy to the pointer's destination counterpart, or to its unchanged
    /// target when it has none. The recorded text is kept when it already resolves there from the copy; a
    /// counterpart that is unmapped or does not exist would leave the copy dangling, so it fails.
    private func destinationLine(
        for pointer: WorktreeForkCopiedPointer,
        resolvingFrom base: URL,
        relocation: WorktreeForkSourcePathRelocation,
        reportPath: String
    ) throws(GitWorktreeForkError) -> String {
        guard let target = pointer.target else {
            return pointer.line
        }
        let unresolvable = GitWorktreeForkError.entryFailed(
            relativePath: reportPath, reason: .unresolvableGitAdministration, errorNumber: nil)
        let wanted: URL
        switch relocation.counterpart(of: target) {
        case .outsideSource:
            wanted = target
        case .relocated(let destination):
            wanted = destination
        case .unmapped:
            throw unresolvable
        }
        let recorded =
            pointer.line.hasPrefix("/") ? URL(fileURLWithPath: pointer.line) : base.appending(path: pointer.line)
        if case .success(let resolved) = WorktreeForkDescriptors.realpathURL(recorded), resolved.path == wanted.path {
            return pointer.line
        }
        guard case .success = WorktreeForkDescriptors.realpathURL(wanted) else {
            throw unresolvable
        }
        return wanted.path
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
    ) throws(GitWorktreeForkError) -> WorktreeForkClonedAdministrationTree {
        let reportPath = "\(node.relativePath)/.git"
        var cloner = WorktreeForkAdministrationCloner(reportPath: reportPath)
        cloner.symlinkTargets = try symlinkTargets(node, administration: administration, mirrorByStore: mirrorByStore)
        let tree = try cloner.cloneTree(from: node.sourceCommonDirectory, to: administration, created: created)
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
            reportPath: reportPath,
            lockTracker: lockTracker
        )
        if case .submodule = node.kind {
            // The materializer never copies a nested gitfile, so the source gitfile is the metadata template.
            let pointer = "gitdir: \(WorktreeForkRelativePath.from(worktree, to: administration))\n"
            try writeData(
                Data(pointer.utf8),
                to: worktree.appending(path: ".git"),
                metadataFrom: plan.sourceRoot.appending(path: node.relativePath).appending(path: ".git"),
                reportPath: reportPath
            )
        }
        if let sparse = node.sparse {
            try writeSparseState(sparse, administration: administration, reportPath: reportPath)
        }
        try sanitizeWorktreeConfiguration(in: administration, reportPath: reportPath)
        return tree
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
            try writeData(
                contents, to: destinationConfiguration, metadataFrom: privateConfiguration, reportPath: reportPath)
        }
    }

    /// A worktree-scoped `core.worktree` (Git moves the main worktree's there when worktree config is
    /// enabled) or `core.bare` would point the destination at the source; neither is ever carried over.
    private func sanitizeWorktreeConfiguration(
        in administration: URL,
        reportPath: String
    ) throws(GitWorktreeForkError) {
        let configuration = administration.appending(path: "config.worktree")
        guard case .success = WorktreeForkDescriptors.lstatPath(configuration) else {
            return
        }
        try WorktreeForkConfigurationFile.apply(
            [.delete("core.worktree"), .delete("core.bare")], to: configuration, reportPath: reportPath,
            lockTracker: lockTracker)
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
        // The cloner never copies this file, so the source alternates file is the metadata template.
        let alternatesPath = WorktreeForkAdministrationCloner.alternatesRelativePath
        try writeData(
            Data((lines.joined(separator: "\n") + "\n").utf8),
            to: administration.appending(path: alternatesPath),
            metadataFrom: node.sourceCommonDirectory.appending(path: alternatesPath),
            reportPath: reportPath
        )
    }

    /// Mirrors each borrowed object store once, beneath the fork's own administration, and points each
    /// mirror's own alternates at the corresponding mirrors so the closure never leaves destination state.
    private func mirrorObjectStores(
        _ stores: [URL],
        journal: inout WorktreeForkRollbackJournal,
        trees: inout [WorktreeForkClonedAdministrationTree]
    ) throws(GitWorktreeForkError) -> [URL: URL] {
        var mirrorByStore: [URL: URL] = [:]
        for (index, store) in stores.enumerated() {
            let mirror = rootAdministration.appending(path: "agentstudio-object-mirrors").appending(path: "\(index)")
            let location = "worktrees/\(plan.worktreeName)/agentstudio-object-mirrors/\(index)"
            journal.record(.nestedAdministration(path: mirror, reportLocation: location, identity: nil))
            var cloner = WorktreeForkAdministrationCloner(reportPath: location)
            cloner.symlinkTargets = plan.gitTopology.mirroredStoreSymlinks[store] ?? [:]
            let tree = try cloner.cloneTree(from: store, to: mirror) { identity in
                journal.confirmNestedAdministration(at: mirror, identity: identity)
            }
            trees.append(tree)
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
        // The destination copy may be absent (fresh fork administration) or removed (a flattened node's
        // overlay), so the source files are the metadata templates.
        try writeData(
            sparse.patternFile,
            to: administration.appending(path: "info/sparse-checkout"),
            metadataFrom: sparse.sourceGitDirectory.appending(path: "info/sparse-checkout"),
            reportPath: reportPath
        )
        guard let worktreeConfiguration = sparse.worktreeConfiguration else {
            return
        }
        let destination = administration.appending(path: "config.worktree")
        try writeData(
            worktreeConfiguration,
            to: destination,
            metadataFrom: sparse.sourceGitDirectory.appending(path: "config.worktree"),
            reportPath: reportPath
        )
        try WorktreeForkConfigurationFile.apply(
            [.setBool("index.sparse", false), .delete("core.worktree"), .delete("core.bare")],
            to: destination,
            reportPath: reportPath,
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

    /// Replaces `url` with `data` on a fresh same-directory inode renamed into place, carrying the metadata of
    /// `template` or of the replaced file (see `WorktreeForkMetadataPreservingRewrite`).
    private func writeData(
        _ data: Data,
        to url: URL,
        metadataFrom template: URL? = nil,
        reportPath: String
    ) throws(GitWorktreeForkError) {
        let directory = url.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            throw .entryFailed(
                relativePath: reportPath, reason: .entryCreationFailed, errorNumber: Self.errorNumber(of: error))
        }
        try WorktreeForkMetadataPreservingRewrite.rewrite(url, metadataFrom: template, reportPath: reportPath) {
            () throws(GitWorktreeForkError) in
            let temporary = directory.appending(path: ".\(url.lastPathComponent).agentstudio-\(UUID().uuidString).tmp")
            try Self.writeNewFile(data, at: temporary, reportPath: reportPath)
            guard rename(temporary.path, url.path) == 0 else {
                let failure = errno
                _ = unlink(temporary.path)
                throw .entryFailed(relativePath: reportPath, reason: .entryCreationFailed, errorNumber: failure)
            }
        }
    }

    /// Creates `temporary` with mode 0644 holding `data`; removes it again on failure.
    private static func writeNewFile(_ data: Data, at temporary: URL, reportPath: String) throws(GitWorktreeForkError) {
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
        if failure == nil, fchmod(descriptor, 0o644) != 0 { failure = errno }
        if close(descriptor) != 0, failure == nil { failure = errno }
        if let failure {
            _ = unlink(temporary.path)
            throw .entryFailed(relativePath: reportPath, reason: .entryCreationFailed, errorNumber: failure)
        }
    }

    private static func errorNumber(of error: Error) -> Int32? {
        ((error as NSError).userInfo[NSUnderlyingErrorKey] as? NSError).map { Int32($0.code) }
    }
}

enum WorktreeForkConfigurationEdit: Sendable {
    case setBool(String, Bool)
    case setString(String, String)
    case delete(String)
    /// Replaces every value of a (possibly multi-valued) key that equals `matching` exactly.
    case replaceValue(String, matching: String, with: String)
}

struct WorktreeForkConfigurationEntry: Equatable, Sendable {
    let name: String
    let value: String
}

/// Edits one Git configuration file through libgit2 so its syntax and locking stay Git's.
enum WorktreeForkConfigurationFile {
    /// The configuration files a repository's administration owns: shared, then worktree-scoped.
    static let repositoryFileNames = ["config", "config.worktree"]

    /// Entries written in this file itself, not reached through an include, whose value is an absolute path;
    /// each distinct name and value once.
    static func absolutePathEntries(in path: URL) throws(GitWorktreeForkError) -> [WorktreeForkConfigurationEntry] {
        var configuration: OpaquePointer?
        let openResult = path.path.withCString { git_config_open_ondisk(&configuration, $0) }
        guard openResult >= 0, let configuration else {
            throw .gitFailure(LibGit2ErrorCapture.failure(code: openResult))
        }
        defer { git_config_free(configuration) }
        var iterator: OpaquePointer?
        let iteratorResult = git_config_iterator_new(&iterator, configuration)
        guard iteratorResult >= 0, let iterator else {
            throw .gitFailure(LibGit2ErrorCapture.failure(code: iteratorResult))
        }
        defer { git_config_iterator_free(iterator) }
        var entries: [WorktreeForkConfigurationEntry] = []
        var entry: UnsafeMutablePointer<git_config_entry>?
        while true {
            let nextResult = git_config_next(&entry, iterator)
            if nextResult == GIT_ITEROVER.rawValue {
                return entries
            }
            guard nextResult >= 0, let current = entry?.pointee else {
                throw .gitFailure(LibGit2ErrorCapture.failure(code: nextResult))
            }
            guard current.include_depth == 0, let name = current.name, let value = current.value else {
                continue
            }
            let candidate = WorktreeForkConfigurationEntry(name: String(cString: name), value: String(cString: value))
            if candidate.value.hasPrefix("/"), !entries.contains(candidate) {
                entries.append(candidate)
            }
        }
    }

    /// libgit2 commits each edit by renaming a fresh lock file over `path`, so the edit runs as a
    /// metadata-preserving rewrite of the configuration file.
    static func apply(
        _ edits: [WorktreeForkConfigurationEdit],
        to path: URL,
        reportPath: String,
        lockTracker: WorktreeForkLockTracker? = nil
    ) throws(GitWorktreeForkError) {
        try WorktreeForkMetadataPreservingRewrite.rewrite(path, reportPath: reportPath) {
            () throws(GitWorktreeForkError) in
            try applyThroughLibGit2(edits, to: path, lockTracker: lockTracker)
        }
    }

    private static func applyThroughLibGit2(
        _ edits: [WorktreeForkConfigurationEdit],
        to path: URL,
        lockTracker: WorktreeForkLockTracker?
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
            case .replaceValue(let name, let matching, let value):
                result = git_config_set_multivar(configuration, name, "^\(Self.escapedPattern(matching))$", value)
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

    /// `literal` as a regular expression that matches only itself.
    private static func escapedPattern(_ literal: String) -> String {
        let special = Set("\\^$.|?*+()[]{}")
        return literal.reduce(into: "") { pattern, character in
            if special.contains(character) {
                pattern.append("\\")
            }
            pattern.append(character)
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
