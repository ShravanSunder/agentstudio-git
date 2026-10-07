import AgentStudioGitContracts
import CLibGit2Local
import Darwin
import Foundation

/// Classifies every nested `.git` entry the walker found without opening it. A gitlink in the nearest enclosing
/// submodule's (or the root's) captured tree or index is a submodule, named by that tree's `.gitmodules` blob,
/// and only a submodule is opened and captured. Every other entry belongs to an independent repository, copied
/// as content. Git directories the walker found inside ordinary content are confirmed here and their copied
/// pointers captured.
struct WorktreeForkGitTopologyPlanner: Sendable {
    let sourceRoot: URL
    /// The source repository's common directory, which the fork shares rather than mirrors.
    let commonDirectory: URL
    let cancellation: WorktreeForkCancellation

    func plan(
        rootRepository: OpaquePointer,
        rootGitDirectory: URL,
        rootCapturedHead: WorktreeForkCapturedHead,
        nestedGitEntryPaths: [String],
        gitDirectoryCandidatePaths: [String]
    ) throws(GitWorktreeForkError) -> WorktreeForkGitTopology {
        let rootTree = try WorktreeForkGitHandles.treeEntries(rootCapturedHead.treeOID, repository: rootRepository)
        let rootSparse = try WorktreeForkSparseCapture.capture(
            repository: rootRepository, gitDirectory: rootGitDirectory, treeEntries: rootTree)
        let rootSourceIndex = WorktreeForkCleanEntryAdoption.captureSourceIndex(gitDirectory: rootGitDirectory)
        var registrations: [String: WorktreeForkSubmoduleRegistrations] = [
            "": try WorktreeForkSubmoduleRegistrations(
                treeEntries: rootTree, sourceIndex: rootSourceIndex, repository: rootRepository)
        ]
        var nodes: [WorktreeForkGitNode] = []
        var embeddedRepositoryGitEntryPaths: [String] = []
        // A submodule's own registrations must be known before any entry beneath it is classified. A plain sort
        // is not parent-first: `a/+x/.git` precedes `a/.git` because `+` sorts before `.`.
        for gitEntryPath in Self.parentFirst(nestedGitEntryPaths) {
            try cancellation.throwIfCancelled()
            let nodePath = WorktreeForkDescriptors.splitParent(gitEntryPath).parent
            let parentPath = nodes.map(\.relativePath).filter { nodePath.hasPrefix($0 + "/") }.max {
                $0.count < $1.count
            }
            let pathInParent = parentPath.map { String(nodePath.dropFirst($0.count + 1)) } ?? nodePath
            guard let submoduleName = registrations[parentPath ?? ""]?.nameByPath[pathInParent] else {
                embeddedRepositoryGitEntryPaths.append(gitEntryPath)
                continue
            }
            let captured = try captureSubmodule(nodePath, gitEntryPath: gitEntryPath, name: submoduleName)
            registrations[nodePath] = captured.registrations
            nodes.append(
                WorktreeForkGitNode(
                    relativePath: nodePath,
                    parentRelativePath: parentPath,
                    submoduleName: submoduleName,
                    sourceGitDirectory: captured.gitDirectory,
                    sourceCommonDirectory: captured.commonDirectory,
                    capturedHead: captured.head,
                    headReferenceName: captured.headReferenceName,
                    sparse: captured.sparse,
                    sourceIndex: captured.sourceIndex,
                    alternateObjectStores: captured.alternates,
                    administrativeSymlinks: captured.administrativeSymlinks
                ))
        }
        let copiedGitDirectories = try captureCopiedGitDirectories(
            gitDirectoryCandidatePaths,
            capturedAdministration: Set(nodes.map(\.sourceGitDirectory.path)),
            gitfilesNamingSourceAdministration: try gitfilesNamingAbsoluteAdministration(
                embeddedRepositoryGitEntryPaths))
        let mirroredObjectStores = Array(
            Set(
                nodes.flatMap(\.alternateObjectStores)
                    + (try outsideObjectStores(of: copiedGitDirectories))
                    + nodes.flatMap { node in
                        node.administrativeSymlinks.values.compactMap { symlink -> URL? in
                            if case .externalStore(let store) = symlink {
                                return store
                            }
                            return nil
                        }
                    })
        ).sorted { $0.path < $1.path }
        var mirroredStoreSymlinks: [URL: [String: String]] = [:]
        for store in mirroredObjectStores {
            mirroredStoreSymlinks[store] = try WorktreeForkAdministrativeSymlinks.storeSymlinkTargets(
                in: store, reportPath: store.lastPathComponent)
        }
        return WorktreeForkGitTopology(
            rootSparse: rootSparse,
            rootSourceIndex: rootSourceIndex,
            nodes: nodes,
            uninitializedSubmodulePaths: uninitializedSubmodules(registrations, nodes: nodes),
            embeddedRepositoryGitEntryPaths: embeddedRepositoryGitEntryPaths,
            mirroredObjectStores: mirroredObjectStores,
            mirroredStoreSymlinks: mirroredStoreSymlinks,
            copiedGitDirectories: copiedGitDirectories
        )
    }

    /// `.git` entries ordered by the depth of the directory holding them, then by that directory's path.
    private static func parentFirst(_ gitEntryPaths: [String]) -> [String] {
        gitEntryPaths.map { (nodePath: WorktreeForkDescriptors.splitParent($0).parent, gitEntryPath: $0) }
            .sorted {
                let firstDepth = $0.nodePath.split(separator: "/").count
                let secondDepth = $1.nodePath.split(separator: "/").count
                return (firstDepth, $0.nodePath) < (secondDepth, $1.nodePath)
            }
            .map(\.gitEntryPath)
    }

    /// Object stores outside the source tree that copied Git directories borrow from, with every store those
    /// borrow from in turn. Each gets a destination-owned mirror, exactly as a submodule's alternates do.
    /// The source repository's own common directory is shared by the fork, so it is never mirrored here.
    private func outsideObjectStores(
        of copiedGitDirectories: [WorktreeForkCopiedGitDirectory]
    ) throws(GitWorktreeForkError) -> [URL] {
        var stores: [URL] = []
        for copied in copiedGitDirectories {
            let reportPath = "\(copied.relativePath)/\(WorktreeForkAdministrationCloner.alternatesRelativePath)"
            for pointer in copied.alternates {
                guard let target = pointer.target,
                    WorktreeForkAdministrativeSymlinks.relativeComponents(of: target, beneath: sourceRoot) == nil,
                    WorktreeForkAdministrativeSymlinks.relativeComponents(of: target, beneath: commonDirectory) == nil
                else {
                    continue
                }
                stores.append(target)
                stores += try Self.alternateClosure(of: target, reportPath)
            }
        }
        return stores
    }

    /// Keeps each candidate libgit2 opens as a Git directory and records the pointers its copy will hold. A
    /// candidate Git would not open is not a repository, so its copy stays ordinary content. A registration no
    /// destination gitfile will lead back to is retired rather than recorded: its directory is a captured
    /// submodule's own administration (`capturedAdministration`), or its `gitdir` names a gitfile copied as
    /// content that still names the source administration (`gitfilesNamingSourceAdministration`). Both sets hold
    /// canonical paths. No candidate inside a retired registration is kept.
    private func captureCopiedGitDirectories(
        _ candidatePaths: [String],
        capturedAdministration: Set<String>,
        gitfilesNamingSourceAdministration: Set<String>
    ) throws(GitWorktreeForkError) -> [WorktreeForkCopiedGitDirectory] {
        var copied: [WorktreeForkCopiedGitDirectory] = []
        for relativePath in candidatePaths {
            try cancellation.throwIfCancelled()
            let gitDirectory = sourceRoot.appending(path: relativePath)
            var repository: OpaquePointer?
            let openFlags = GIT_REPOSITORY_OPEN_NO_SEARCH.rawValue | GIT_REPOSITORY_OPEN_BARE.rawValue
            let openResult = gitDirectory.path.withCString {
                git_repository_open_ext(&repository, $0, openFlags, nil)
            }
            guard openResult >= 0, let repository else {
                continue
            }
            git_repository_free(repository)
            let objects = gitDirectory.appending(path: "objects")
            var registrations = Self.worktreeRegistrations(in: gitDirectory)
            var retired: [String] = []
            for registrationPath in registrations.keys.sorted() {
                let registrationDirectory = WorktreeForkDescriptors.splitParent(registrationPath).parent
                let capturedAsSubmodule =
                    if case .success(let canonical) = WorktreeForkDescriptors.realpathURL(
                        gitDirectory.appending(path: registrationDirectory))
                    {
                        capturedAdministration.contains(canonical.path)
                    } else {
                        false
                    }
                let copiedAsContent =
                    registrations[registrationPath]?.target.map {
                        gitfilesNamingSourceAdministration.contains($0.path)
                    } ?? false
                if capturedAsSubmodule || copiedAsContent {
                    registrations[registrationPath] = nil
                    retired.append(registrationDirectory)
                }
            }
            copied.append(
                WorktreeForkCopiedGitDirectory(
                    relativePath: relativePath,
                    alternates: Self.alternateLines(objects).map { Self.copiedPointer($0, resolvingFrom: objects) },
                    worktreeRegistrations: registrations,
                    retiredRegistrations: retired
                ))
        }
        let retiredSubtrees = copied.flatMap(\.retiredRegistrationSubtrees)
        return copied.filter { candidate in
            !retiredSubtrees.contains { WorktreeForkFilesystemPlan.isPath(candidate.relativePath, within: $0) }
        }
    }

    /// The canonical paths of the gitfiles among `gitEntryPaths` whose `gitdir:` is absolute. Copied byte for
    /// byte, such a gitfile still names the source's administration, so the destination copy of the
    /// registration it names would have nothing leading back to it. A relative one leads to the copy instead.
    private func gitfilesNamingAbsoluteAdministration(
        _ gitEntryPaths: [String]
    ) throws(GitWorktreeForkError) -> Set<String> {
        var gitfiles = Set<String>()
        for gitEntryPath in gitEntryPaths {
            let file = sourceRoot.appending(path: gitEntryPath)
            if try WorktreeForkGitfile.recordedGitDirectory(file, reportPath: gitEntryPath)?.hasPrefix("/") == true {
                gitfiles.insert(file.path)
            }
        }
        return gitfiles
    }

    /// Each `worktrees/<name>/gitdir` file, which Git writes as the linked worktree's `.git` path, absolute
    /// or relative to the registration directory.
    private static func worktreeRegistrations(in gitDirectory: URL) -> [String: WorktreeForkCopiedPointer] {
        let worktrees = gitDirectory.appending(path: "worktrees")
        var registrations: [String: WorktreeForkCopiedPointer] = [:]
        for name in (try? FileManager.default.contentsOfDirectory(atPath: worktrees.path)) ?? [] {
            let registration = worktrees.appending(path: name)
            guard let text = try? String(contentsOf: registration.appending(path: "gitdir"), encoding: .utf8) else {
                continue
            }
            let line = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !line.isEmpty {
                registrations["worktrees/\(name)/gitdir"] = copiedPointer(line, resolvingFrom: registration)
            }
        }
        return registrations
    }

    /// A recorded path that does not resolve (a stale registration or a broken cache) is kept as written:
    /// the copy is no more broken than its source.
    private static func copiedPointer(_ line: String, resolvingFrom base: URL) -> WorktreeForkCopiedPointer {
        let recorded = line.hasPrefix("/") ? URL(fileURLWithPath: line) : base.appending(path: line)
        guard case .success(let canonical) = WorktreeForkDescriptors.realpathURL(recorded) else {
            return WorktreeForkCopiedPointer(line: line, target: nil)
        }
        return WorktreeForkCopiedPointer(line: line, target: canonical)
    }

    private func captureSubmodule(
        _ nodePath: String,
        gitEntryPath: String,
        name: String
    ) throws(GitWorktreeForkError) -> WorktreeForkCapturedNode {
        let unresolvable = GitWorktreeForkError.entryFailed(
            relativePath: gitEntryPath, reason: .unresolvableGitAdministration, errorNumber: nil)
        guard WorktreeForkSubmoduleRegistrations.isSafeName(name) else {
            throw unresolvable
        }
        let nodeRoot = sourceRoot.appending(path: nodePath)
        guard case .success(let gitEntryInfo) = WorktreeForkDescriptors.lstatPath(nodeRoot.appending(path: ".git"))
        else {
            throw unresolvable
        }
        let gitEntryKind = WorktreeForkEntryKind(mode: gitEntryInfo.st_mode)
        guard gitEntryKind == .directory || gitEntryKind == .regularFile else {
            throw unresolvable
        }
        var repository: OpaquePointer?
        let openResult = nodeRoot.path.withCString {
            git_repository_open_ext(&repository, $0, GIT_REPOSITORY_OPEN_NO_SEARCH.rawValue, nil)
        }
        guard openResult >= 0, let repository else {
            throw unresolvable
        }
        defer { git_repository_free(repository) }
        guard let workdir = git_repository_workdir(repository),
            case .success(let canonicalWorkdir) = WorktreeForkDescriptors.realpathURL(
                URL(fileURLWithPath: String(cString: workdir))),
            case .success(let canonicalNode) = WorktreeForkDescriptors.realpathURL(nodeRoot),
            canonicalWorkdir.path == canonicalNode.path,
            let gitDirectoryPointer = git_repository_path(repository),
            let commonDirectoryPointer = git_repository_commondir(repository),
            case .success(let gitDirectory) = WorktreeForkDescriptors.realpathURL(
                URL(fileURLWithPath: String(cString: gitDirectoryPointer))),
            case .success(let commonDirectory) = WorktreeForkDescriptors.realpathURL(
                URL(fileURLWithPath: String(cString: commonDirectoryPointer)))
        else {
            throw unresolvable
        }

        let head = try Self.captureOptionalHead(repository)
        let treeEntries =
            try head.map { head throws(GitWorktreeForkError) in
                try WorktreeForkGitHandles.treeEntries(head.treeOID, repository: repository)
            } ?? [:]
        let sourceIndex = WorktreeForkCleanEntryAdoption.captureSourceIndex(gitDirectory: gitDirectory)
        return WorktreeForkCapturedNode(
            gitDirectory: gitDirectory,
            commonDirectory: commonDirectory,
            head: head,
            headReferenceName: Self.symbolicHeadTarget(repository),
            sparse: try WorktreeForkSparseCapture.capture(
                repository: repository, gitDirectory: gitDirectory, treeEntries: treeEntries),
            sourceIndex: sourceIndex,
            alternates: try Self.alternateClosure(of: commonDirectory.appending(path: "objects"), gitEntryPath),
            administrativeSymlinks: try WorktreeForkAdministrativeSymlinks.classify(
                administrationRoot: commonDirectory, reportPath: gitEntryPath),
            registrations: try WorktreeForkSubmoduleRegistrations(
                treeEntries: treeEntries, sourceIndex: sourceIndex, repository: repository)
        )
    }

    private func uninitializedSubmodules(
        _ registrations: [String: WorktreeForkSubmoduleRegistrations],
        nodes: [WorktreeForkGitNode]
    ) -> [String] {
        let initialized = Set(nodes.map(\.relativePath))
        return registrations.flatMap { parentPath, parentRegistrations in
            parentRegistrations.nameByPath.keys.map { WorktreeForkDescriptors.joined(parentPath, $0) }
        }
        .filter { !initialized.contains($0) }
        .sorted()
    }

    private static func captureOptionalHead(
        _ repository: OpaquePointer
    ) throws(GitWorktreeForkError) -> WorktreeForkCapturedHead? {
        var headOID = git_oid()
        let resolveResult = git_reference_name_to_id(&headOID, repository, "HEAD")
        if resolveResult == GIT_ENOTFOUND.rawValue || resolveResult == GIT_EUNBORNBRANCH.rawValue {
            return nil
        }
        guard resolveResult >= 0 else {
            throw .gitFailure(LibGit2ErrorCapture.failure(code: resolveResult))
        }
        let commit = try WorktreeForkGitHandles.lookupCommit(oidString(&headOID), repository: repository)
        defer { git_commit_free(commit) }
        guard let treeOID = git_commit_tree_id(commit) else {
            throw .gitFailure(.headUnavailable)
        }
        return WorktreeForkCapturedHead(commitOID: oidString(&headOID), treeOID: oidString(treeOID))
    }

    private static func symbolicHeadTarget(_ repository: OpaquePointer) -> String? {
        var head: OpaquePointer?
        guard git_reference_lookup(&head, repository, "HEAD") >= 0, let head else {
            return nil
        }
        defer { git_reference_free(head) }
        guard git_reference_type(head) == GIT_REFERENCE_SYMBOLIC, let target = git_reference_symbolic_target(head)
        else {
            return nil
        }
        return String(cString: target)
    }

    /// Follows `objects/info/alternates` transitively. Relative entries resolve against the objects dir.
    static func alternateClosure(
        of objectsDirectory: URL,
        _ reportPath: String
    ) throws(GitWorktreeForkError) -> [URL] {
        var discovered: [URL] = []
        var pending = [objectsDirectory]
        while let current = pending.popLast() {
            for line in alternateLines(current) {
                let candidate =
                    line.hasPrefix("/") ? URL(fileURLWithPath: line) : current.appending(path: line)
                guard case .success(let canonical) = WorktreeForkDescriptors.realpathURL(candidate) else {
                    throw .entryFailed(
                        relativePath: reportPath, reason: .unresolvableGitAdministration, errorNumber: nil)
                }
                if !discovered.contains(canonical) {
                    discovered.append(canonical)
                    pending.append(canonical)
                }
            }
        }
        return discovered
    }

    static func alternateLines(_ objectsDirectory: URL) -> [String] {
        guard
            let text = try? String(
                contentsOf: objectsDirectory.appending(path: "info/alternates"), encoding: .utf8)
        else {
            return []
        }
        return text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
    }
}

private struct WorktreeForkCapturedNode {
    let gitDirectory: URL
    let commonDirectory: URL
    let head: WorktreeForkCapturedHead?
    let headReferenceName: String?
    let sparse: WorktreeForkSparsePlan?
    let sourceIndex: WorktreeForkSourceIndexSnapshot?
    let alternates: [URL]
    let administrativeSymlinks: [String: WorktreeForkAdministrativeSymlink]
    let registrations: WorktreeForkSubmoduleRegistrations
}

/// Registered submodules of one node: gitlink paths from its captured tree and its source index (a submodule
/// added but not yet committed), named by the `.gitmodules` blob in that tree (Git's default name is the path).
struct WorktreeForkSubmoduleRegistrations: Sendable {
    let nameByPath: [String: String]

    init(
        treeEntries: [String: WorktreeForkTreeEntry],
        sourceIndex: WorktreeForkSourceIndexSnapshot?,
        repository: OpaquePointer
    ) throws(GitWorktreeForkError) {
        let gitlinkMode = UInt32(GIT_FILEMODE_COMMIT.rawValue)
        let gitlinkPaths = Set(treeEntries.filter { $0.value.mode == gitlinkMode }.keys)
            .union((sourceIndex?.entries ?? [:]).filter { $0.value.mode == gitlinkMode }.keys)
        guard !gitlinkPaths.isEmpty else {
            nameByPath = [:]
            return
        }
        let declaredNames =
            try treeEntries[".gitmodules"].map { entry throws(GitWorktreeForkError) in
                Self.namesByPath(try Self.blobText(entry.oid, repository: repository))
            } ?? [:]
        nameByPath = Dictionary(uniqueKeysWithValues: gitlinkPaths.map { ($0, declaredNames[$0] ?? $0) })
    }

    /// Git refuses submodule names that could leave `$GIT_DIR/modules`; the fork applies the same rule so a
    /// name can never place destination administration outside the fork's own administration.
    static func isSafeName(_ name: String) -> Bool {
        guard !name.isEmpty, !name.hasPrefix("/"), !name.hasPrefix("\\") else {
            return false
        }
        let components = name.split(separator: "/", omittingEmptySubsequences: false)
            .flatMap { $0.split(separator: "\\", omittingEmptySubsequences: false) }
        return !components.contains { $0.isEmpty || $0 == "." || $0 == ".." }
    }

    /// Reads `[submodule "name"]` sections and their `path` keys.
    static func namesByPath(_ text: String) -> [String: String] {
        var result: [String: String] = [:]
        var currentName: String?
        for rawLine in text.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") {
                currentName =
                    line.hasPrefix("[submodule \"") && line.hasSuffix("\"]")
                    ? String(line.dropFirst("[submodule \"".count).dropLast(2)) : nil
                continue
            }
            let parts = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if let currentName, parts.count == 2, parts[0] == "path" {
                result[parts[1].trimmingCharacters(in: CharacterSet(charactersIn: "\""))] = currentName
            }
        }
        return result
    }

    private static func blobText(_ oidString: String, repository: OpaquePointer) throws(GitWorktreeForkError) -> String
    {
        guard var oid = WorktreeForkObjectID.parse(oidString) else {
            throw .gitFailure(.requiredObjectNotFound(oid: oidString))
        }
        var blob: OpaquePointer?
        let lookupResult = git_blob_lookup(&blob, repository, &oid)
        guard lookupResult >= 0, let blob, let content = git_blob_rawcontent(blob) else {
            throw .gitFailure(LibGit2ErrorCapture.failure(code: lookupResult))
        }
        defer { git_blob_free(blob) }
        let bytes = UnsafeRawBufferPointer(start: content, count: Int(git_blob_rawsize(blob)))
        return String(bytes: bytes, encoding: .utf8) ?? ""
    }
}
