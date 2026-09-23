import AgentStudioGitContracts
import CLibGit2Local
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
/// pointer is copied as final; each is rewritten for the destination.
struct GitRepositoryStateRehomer: Sendable {
    let plan: WorktreeForkPlan
    let cancellation: WorktreeForkCancellation

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
        return rehomed
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
        let cloner = WorktreeForkAdministrationCloner(reportPath: reportPath)
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
        try WorktreeForkConfigurationFile.apply(configurationEdits, to: administration.appending(path: "config"))
        if case .submodule = node.kind {
            let pointer = "gitdir: \(WorktreeForkRelativePath.from(worktree, to: administration))\n"
            try writeText(pointer, to: worktree.appending(path: ".git"), reportPath: reportPath)
        }
        if let sparse = node.sparse {
            try writeSparseState(sparse, administration: administration, reportPath: reportPath)
        }
    }

    /// A gitfile-reached node keeps its worktree-private identity (`HEAD` is rewritten from the plan) and
    /// worktree configuration; its common administration was cloned above.
    private func overlayPrivateAdministration(
        _ node: WorktreeForkGitNode,
        administration: URL,
        reportPath: String
    ) throws(GitWorktreeForkError) {
        let privateConfiguration = node.sourceGitDirectory.appending(path: "config.worktree")
        if let contents = try? Data(contentsOf: privateConfiguration) {
            try writeData(contents, to: administration.appending(path: "config.worktree"), reportPath: reportPath)
        }
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
            try WorktreeForkAdministrationCloner(reportPath: location).cloneTree(from: store, to: mirror) { identity in
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
        try WorktreeForkConfigurationFile.apply([.setBool("index.sparse", false)], to: destination)
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

    private func writeData(_ data: Data, to url: URL, reportPath: String) throws(GitWorktreeForkError) {
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url)
        } catch {
            throw .entryFailed(relativePath: reportPath, reason: .entryCreationFailed, errorNumber: nil)
        }
    }
}

enum WorktreeForkConfigurationEdit: Sendable {
    case setBool(String, Bool)
    case setString(String, String)
    case delete(String)
}

/// Edits one Git configuration file through libgit2 so its syntax and locking stay Git's.
enum WorktreeForkConfigurationFile {
    static func apply(_ edits: [WorktreeForkConfigurationEdit], to path: URL) throws(GitWorktreeForkError) {
        var configuration: OpaquePointer?
        let openResult = path.path.withCString { git_config_open_ondisk(&configuration, $0) }
        guard openResult >= 0, let configuration else {
            throw .gitFailure(LibGit2ErrorCapture.failure(code: openResult))
        }
        defer { git_config_free(configuration) }
        for edit in edits {
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
            guard result >= 0 else {
                throw .gitFailure(LibGit2ErrorCapture.failure(code: result))
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
