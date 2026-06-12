import AgentStudioGitContracts
import CLibGit2Local
import Foundation

struct LibGit2TreeReader: Sendable {
    func readTree(_ request: GitTreeReadRequest) throws -> GitTreeSnapshot {
        try LibGit2ReviewSupport.withRepository(at: request.repositoryPath) { repository in
            let commit = try LibGit2ReviewSupport.resolveCommit(request.revision, repository: repository)
            defer { git_commit_free(commit) }

            let rootTree = try tree(for: commit)
            defer { git_tree_free(rootTree) }

            let tree = try scopedTree(rootTree: rootTree, path: request.path, repository: repository)
            defer {
                if tree != rootTree {
                    git_tree_free(tree)
                }
            }

            return GitTreeSnapshot(
                revision: GitResolvedRevision(
                    oid: LibGit2ReviewSupport.oidString(git_commit_id(commit)),
                    shortName: request.revision.name.count == 40 ? nil : request.revision.name
                ),
                entries: try entries(tree: tree, prefix: request.path, repository: repository)
            )
        }
    }

    private func tree(for commit: OpaquePointer) throws -> OpaquePointer {
        var tree: OpaquePointer?
        let treeResult = git_commit_tree(&tree, commit)
        guard treeResult >= 0, let tree else {
            throw LibGit2ErrorCapture.failure(code: treeResult)
        }
        return tree
    }

    private func scopedTree(rootTree: OpaquePointer, path: String?, repository: OpaquePointer) throws -> OpaquePointer {
        guard let path, !path.isEmpty else {
            return rootTree
        }

        var entry: OpaquePointer?
        let entryResult = path.withCString { pathPointer in
            git_tree_entry_bypath(&entry, rootTree, pathPointer)
        }
        guard entryResult >= 0, let entry else {
            throw LibGit2ErrorCapture.failure(code: entryResult)
        }
        defer { git_tree_entry_free(entry) }

        guard git_tree_entry_type(entry) == GIT_OBJECT_TREE else {
            throw GitDataPlaneError.unsupported(message: "tree path is not a directory: \(path)")
        }

        var tree: OpaquePointer?
        let lookupResult = git_tree_lookup(&tree, repository, git_tree_entry_id(entry))
        guard lookupResult >= 0, let tree else {
            throw LibGit2ErrorCapture.failure(code: lookupResult)
        }
        return tree
    }

    private func entries(tree: OpaquePointer, prefix: String?, repository: OpaquePointer) throws -> [GitTreeEntry] {
        let normalizedPrefix = prefix.map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "/")) }
            .flatMap { $0.isEmpty ? nil : $0 }
        let entryPrefix = normalizedPrefix.map { "\($0)/" } ?? ""

        return try (0..<git_tree_entrycount(tree)).map { index in
            guard let entry = git_tree_entry_byindex(tree, index),
                let namePointer = git_tree_entry_name(entry)
            else {
                throw GitDataPlaneError.unsupported(message: "libgit2 returned an invalid tree entry")
            }

            let path = entryPrefix + String(cString: namePointer)
            let isTree = git_tree_entry_type(entry) == GIT_OBJECT_TREE
            return GitTreeEntry(
                path: path,
                oid: LibGit2ReviewSupport.oidString(git_tree_entry_id(entry)),
                mode: Int32(git_tree_entry_filemode(entry).rawValue),
                isTree: isTree,
                sizeBytes: try isTree ? nil : blobSize(entry: entry, repository: repository)
            )
        }
        .sorted { $0.path < $1.path }
    }

    private func blobSize(entry: OpaquePointer, repository: OpaquePointer) throws -> Int64 {
        var blob: OpaquePointer?
        let lookupResult = git_blob_lookup(&blob, repository, git_tree_entry_id(entry))
        guard lookupResult >= 0, let blob else {
            throw LibGit2ErrorCapture.failure(code: lookupResult)
        }
        defer { git_blob_free(blob) }

        return Int64(git_blob_rawsize(blob))
    }
}
