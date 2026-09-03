import AgentStudioGitContracts
import CLibGit2Local
import Foundation

struct LibGit2DiffReader: Sendable {
    func diff(_ request: GitDiffRequest) throws -> GitDiffSnapshot {
        try LibGit2ReviewSupport.withRepository(at: request.repositoryPath) { repository in
            var options = try diffOptions()
            let diff = try makeDiff(request, options: &options, repository: repository)
            defer { git_diff_free(diff) }

            try findRenames(diff)
            return GitDiffSnapshot(files: try files(diff: diff, repository: repository))
        }
    }

    func diff(baseTree: OpaquePointer, repository: OpaquePointer) throws -> GitDiffSnapshot {
        var options = try diffOptions()
        let diff = try treeToWorkdirDiff(oldTree: baseTree, options: &options, repository: repository)
        defer { git_diff_free(diff) }

        try findRenames(diff, includingUntracked: true)
        return GitDiffSnapshot(files: try files(diff: diff, repository: repository))
    }

    func diff(
        baseTree: OpaquePointer,
        literalPaths: [String],
        repository: OpaquePointer
    ) throws -> GitDiffSnapshot {
        try withPathspec(literalPaths) { pathspec in
            var options = try diffOptions()
            options.flags |= GIT_DIFF_DISABLE_PATHSPEC_MATCH.rawValue
            options.pathspec = pathspec
            let diff = try treeToWorkdirDiff(oldTree: baseTree, options: &options, repository: repository)
            defer { git_diff_free(diff) }

            try findRenames(diff, includingUntracked: true)
            return GitDiffSnapshot(files: try files(diff: diff, repository: repository))
        }
    }

    func makeDiff(
        _ request: GitDiffRequest,
        options: inout git_diff_options,
        repository: OpaquePointer
    ) throws -> OpaquePointer {
        switch (request.base.kind, request.compare.kind) {
        case (.head, .head), (.commit, .commit), (.head, .commit), (.commit, .head):
            let oldTree = try LibGit2ReviewSupport.resolveTree(request.base, repository: repository)
            defer { git_tree_free(oldTree) }
            let newTree = try LibGit2ReviewSupport.resolveTree(request.compare, repository: repository)
            defer { git_tree_free(newTree) }
            return try treeToTreeDiff(
                oldTree: oldTree,
                newTree: newTree,
                options: &options,
                repository: repository
            )

        case (.head, .index), (.commit, .index):
            let oldTree = try LibGit2ReviewSupport.resolveTree(request.base, repository: repository)
            defer { git_tree_free(oldTree) }
            let index = try repositoryIndex(repository)
            defer { git_index_free(index) }
            return try treeToIndexDiff(
                oldTree: oldTree,
                index: index,
                options: &options,
                repository: repository
            )

        case (.index, .workingTree):
            let index = try repositoryIndex(repository)
            defer { git_index_free(index) }
            return try indexToWorkdirDiff(index: index, options: &options, repository: repository)

        case (.head, .workingTree), (.commit, .workingTree):
            let oldTree = try LibGit2ReviewSupport.resolveTree(request.base, repository: repository)
            defer { git_tree_free(oldTree) }
            return try treeToWorkdirWithIndexDiff(oldTree: oldTree, options: &options, repository: repository)

        default:
            throw GitDataPlaneError.unsupported(
                message:
                    "unsupported diff target pair: \(request.base.kind.rawValue) -> \(request.compare.kind.rawValue)"
            )
        }
    }

    private func treeToTreeDiff(
        oldTree: OpaquePointer,
        newTree: OpaquePointer,
        options: inout git_diff_options,
        repository: OpaquePointer
    ) throws -> OpaquePointer {
        var diff: OpaquePointer?
        let result = git_diff_tree_to_tree(&diff, repository, oldTree, newTree, &options)
        guard result >= 0, let diff else {
            throw LibGit2ErrorCapture.failure(code: result)
        }
        return diff
    }

    private func treeToIndexDiff(
        oldTree: OpaquePointer,
        index: OpaquePointer,
        options: inout git_diff_options,
        repository: OpaquePointer
    ) throws -> OpaquePointer {
        var diff: OpaquePointer?
        let result = git_diff_tree_to_index(&diff, repository, oldTree, index, &options)
        guard result >= 0, let diff else {
            throw LibGit2ErrorCapture.failure(code: result)
        }
        return diff
    }

    private func indexToWorkdirDiff(
        index: OpaquePointer,
        options: inout git_diff_options,
        repository: OpaquePointer
    ) throws -> OpaquePointer {
        var diff: OpaquePointer?
        let result = git_diff_index_to_workdir(&diff, repository, index, &options)
        guard result >= 0, let diff else {
            throw LibGit2ErrorCapture.failure(code: result)
        }
        return diff
    }

    private func treeToWorkdirDiff(
        oldTree: OpaquePointer,
        options: inout git_diff_options,
        repository: OpaquePointer
    ) throws -> OpaquePointer {
        var diff: OpaquePointer?
        let result = git_diff_tree_to_workdir(&diff, repository, oldTree, &options)
        guard result >= 0, let diff else {
            throw LibGit2ErrorCapture.failure(code: result)
        }
        return diff
    }

    private func withPathspec<ReturnValue>(
        _ paths: [String],
        _ body: (git_strarray) throws -> ReturnValue
    ) rethrows -> ReturnValue {
        var cStrings: [UnsafeMutablePointer<CChar>?] = paths.map { strdup($0) }
        defer {
            for cString in cStrings {
                free(cString)
            }
        }
        return try cStrings.withUnsafeMutableBufferPointer { buffer in
            try body(git_strarray(strings: buffer.baseAddress, count: paths.count))
        }
    }

    private func treeToWorkdirWithIndexDiff(
        oldTree: OpaquePointer,
        options: inout git_diff_options,
        repository: OpaquePointer
    ) throws
        -> OpaquePointer
    {
        var diff: OpaquePointer?
        let result = git_diff_tree_to_workdir_with_index(&diff, repository, oldTree, &options)
        guard result >= 0, let diff else {
            throw LibGit2ErrorCapture.failure(code: result)
        }
        return diff
    }

    private func repositoryIndex(_ repository: OpaquePointer) throws -> OpaquePointer {
        var index: OpaquePointer?
        let indexResult = git_repository_index(&index, repository)
        guard indexResult >= 0, let index else {
            throw LibGit2ErrorCapture.failure(code: indexResult)
        }
        return index
    }

    func diffOptions() throws -> git_diff_options {
        var options = git_diff_options()
        let initResult = git_diff_options_init(&options, UInt32(GIT_DIFF_OPTIONS_VERSION))
        guard initResult >= 0 else {
            throw LibGit2ErrorCapture.failure(code: initResult)
        }
        options.flags =
            GIT_DIFF_INCLUDE_UNTRACKED.rawValue
            | GIT_DIFF_RECURSE_UNTRACKED_DIRS.rawValue
            | GIT_DIFF_INCLUDE_TYPECHANGE.rawValue
        return options
    }

    func findRenames(
        _ diff: OpaquePointer,
        includingUntracked: Bool = false,
        maximumComparisonsPerTarget: Int? = nil
    ) throws {
        var options = git_diff_find_options()
        let initResult = git_diff_find_options_init(&options, UInt32(GIT_DIFF_FIND_OPTIONS_VERSION))
        guard initResult >= 0 else {
            throw LibGit2ErrorCapture.failure(code: initResult)
        }
        options.flags = GIT_DIFF_FIND_RENAMES.rawValue
        if let maximumComparisonsPerTarget {
            options.rename_limit = maximumComparisonsPerTarget
        }
        if includingUntracked {
            options.flags |= GIT_DIFF_FIND_FOR_UNTRACKED.rawValue
        }
        let result = git_diff_find_similar(diff, &options)
        guard result >= 0 else {
            throw LibGit2ErrorCapture.failure(code: result)
        }
    }

    private func files(diff: OpaquePointer, repository: OpaquePointer) throws -> [GitDiffFile] {
        try (0..<git_diff_num_deltas(diff)).map { index in
            guard let deltaPointer = git_diff_get_delta(diff, index) else {
                throw GitDataPlaneError.unsupported(message: "libgit2 returned no diff delta at index \(index)")
            }
            let lineStats = try lineStats(diff: diff, index: index)
            return try file(delta: deltaPointer.pointee, lineStats: lineStats, repository: repository)
        }
        .sorted { $0.path < $1.path }
    }

    private func lineStats(diff: OpaquePointer, index: Int) throws -> (additions: Int, deletions: Int) {
        var patch: OpaquePointer?
        let patchResult = git_patch_from_diff(&patch, diff, index)
        guard patchResult >= 0 else {
            throw LibGit2ErrorCapture.failure(code: patchResult)
        }
        guard let patch else {
            return (0, 0)
        }
        defer { git_patch_free(patch) }

        var additions = 0
        var deletions = 0
        let statsResult = git_patch_line_stats(nil, &additions, &deletions, patch)
        guard statsResult >= 0 else {
            throw LibGit2ErrorCapture.failure(code: statsResult)
        }
        return (additions, deletions)
    }

    private func file(
        delta: git_diff_delta,
        lineStats: (additions: Int, deletions: Int),
        repository: OpaquePointer
    ) throws -> GitDiffFile {
        let newPath = LibGit2ReviewSupport.path(delta.new_file.path)
        let oldPath = LibGit2ReviewSupport.path(delta.old_file.path)
        let path = try requiredPath(newPath ?? oldPath)
        let previousPath = delta.status == GIT_DELTA_RENAMED ? oldPath : nil
        let oldHash = contentHash(delta.old_file, repository: repository, workdirPath: oldPath)
        let newHash = contentHash(delta.new_file, repository: repository, workdirPath: newPath)

        return GitDiffFile(
            fileId: fileID(path: path, previousPath: previousPath, oldHash: oldHash, newHash: newHash),
            path: path,
            previousPath: previousPath,
            changeKind: changeKind(delta.status),
            oldContentHash: oldHash,
            newContentHash: newHash,
            contentHashAlgorithm: "git-blob-sha1",
            oldMode: mode(delta.old_file),
            newMode: mode(delta.new_file),
            additions: lineStats.additions,
            deletions: lineStats.deletions,
            isBinary: isBinary(delta),
            sizeBytes: size(delta.new_file) ?? size(delta.old_file)
        )
    }

    private func contentHash(
        _ file: git_diff_file,
        repository: OpaquePointer,
        workdirPath: String?
    ) -> String? {
        if !LibGit2ReviewSupport.isZeroOID(file.id), hasFlag(file.flags, GIT_DIFF_FLAG_VALID_ID) {
            return LibGit2ReviewSupport.oidString(file.id)
        }
        guard let workdirPath, hasFlag(file.flags, GIT_DIFF_FLAG_EXISTS) else {
            return nil
        }

        var oid = git_oid()
        let result = workdirPath.withCString { pathPointer in
            git_repository_hashfile(&oid, repository, pathPointer, GIT_OBJECT_BLOB, pathPointer)
        }
        guard result >= 0 else {
            return nil
        }
        return LibGit2ReviewSupport.oidString(oid)
    }

    private func mode(_ file: git_diff_file) -> Int32? {
        let rawMode = Int32(file.mode)
        return rawMode == 0 ? nil : rawMode
    }

    private func size(_ file: git_diff_file) -> Int64? {
        guard hasFlag(file.flags, GIT_DIFF_FLAG_VALID_SIZE) || hasFlag(file.flags, GIT_DIFF_FLAG_EXISTS) else {
            return nil
        }
        return Int64(file.size)
    }

    private func isBinary(_ delta: git_diff_delta) -> Bool {
        hasFlag(delta.flags, GIT_DIFF_FLAG_BINARY)
            || hasFlag(delta.old_file.flags, GIT_DIFF_FLAG_BINARY)
            || hasFlag(delta.new_file.flags, GIT_DIFF_FLAG_BINARY)
    }

    private func hasFlag(_ flags: UInt32, _ flag: git_diff_flag_t) -> Bool {
        (flags & flag.rawValue) != 0
    }

    private func changeKind(_ status: git_delta_t) -> GitDiffChangeKind {
        switch status {
        case GIT_DELTA_ADDED, GIT_DELTA_UNTRACKED:
            return .added
        case GIT_DELTA_COPIED:
            return .copied
        case GIT_DELTA_DELETED:
            return .deleted
        case GIT_DELTA_RENAMED:
            return .renamed
        case GIT_DELTA_TYPECHANGE:
            return .typeChanged
        case GIT_DELTA_CONFLICTED:
            return .unmerged
        case GIT_DELTA_MODIFIED, GIT_DELTA_UNMODIFIED, GIT_DELTA_IGNORED, GIT_DELTA_UNREADABLE:
            return .modified
        default:
            return .modified
        }
    }

    private func fileID(path: String, previousPath: String?, oldHash: String?, newHash: String?) -> String {
        [
            "gitdiff",
            previousPath ?? "none",
            path,
            oldHash ?? "none",
            newHash ?? "none",
        ].joined(separator: ":")
    }

    private func requiredPath(_ path: String?) throws -> String {
        guard let path, !path.isEmpty else {
            throw GitDataPlaneError.unsupported(message: "libgit2 diff delta did not include a path")
        }
        return path
    }
}
