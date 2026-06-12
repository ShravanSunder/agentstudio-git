import AgentStudioGitContracts
import CLibGit2Local
import Foundation

struct LibGit2ContentReader: Sendable {
    func content(_ request: GitContentRequest) throws -> GitContentPayload {
        try LibGit2ReviewSupport.withRepository(at: request.repositoryPath) { repository in
            switch request.target.kind {
            case .head, .commit:
                return try commitContent(request, repository: repository)
            case .index:
                return try indexContent(request, repository: repository)
            case .workingTree:
                return try workingTreeContent(request, repository: repository)
            }
        }
    }

    private func commitContent(_ request: GitContentRequest, repository: OpaquePointer) throws -> GitContentPayload {
        let tree = try LibGit2ReviewSupport.resolveTree(request.target, repository: repository)
        defer { git_tree_free(tree) }

        var entry: OpaquePointer?
        let entryResult = request.path.withCString { pathPointer in
            git_tree_entry_bypath(&entry, tree, pathPointer)
        }
        guard entryResult >= 0, let entry else {
            throw LibGit2ErrorCapture.failure(code: entryResult)
        }
        defer { git_tree_entry_free(entry) }

        var blob: OpaquePointer?
        let lookupResult = git_blob_lookup(&blob, repository, git_tree_entry_id(entry))
        guard lookupResult >= 0, let blob else {
            throw LibGit2ErrorCapture.failure(code: lookupResult)
        }
        defer { git_blob_free(blob) }

        return try payload(blob: blob, path: request.path, maxSizeBytes: request.maxSizeBytes)
    }

    private func indexContent(_ request: GitContentRequest, repository: OpaquePointer) throws -> GitContentPayload {
        var index: OpaquePointer?
        let indexResult = git_repository_index(&index, repository)
        guard indexResult >= 0, let index else {
            throw LibGit2ErrorCapture.failure(code: indexResult)
        }
        defer { git_index_free(index) }

        guard
            let entry = request.path.withCString({ pathPointer in
                git_index_get_bypath(index, pathPointer, 0)
            })
        else {
            throw LibGit2ErrorCapture.fallbackFailure(
                code: GIT_ENOTFOUND.rawValue,
                message: "index entry not found: \(request.path)"
            )
        }

        var blob: OpaquePointer?
        var oid = entry.pointee.id
        let lookupResult = withUnsafePointer(to: &oid) { oidPointer in
            git_blob_lookup(&blob, repository, oidPointer)
        }
        guard lookupResult >= 0, let blob else {
            throw LibGit2ErrorCapture.failure(code: lookupResult)
        }
        defer { git_blob_free(blob) }

        return try payload(blob: blob, path: request.path, maxSizeBytes: request.maxSizeBytes)
    }

    private func workingTreeContent(_ request: GitContentRequest, repository: OpaquePointer) throws -> GitContentPayload
    {
        let file = try LibGit2ReviewSupport.containedWorkingTreeFile(repository: repository, path: request.path)
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        let sizeBytes = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        try enforceSizeLimit(path: request.path, sizeBytes: sizeBytes, maxSizeBytes: request.maxSizeBytes)

        let data = try Data(contentsOf: file)
        return GitContentPayload(
            data: data,
            contentHash: LibGit2ReviewSupport.sha256ContentHash(data),
            contentHashAlgorithm: "sha256",
            isBinary: LibGit2ReviewSupport.isBinaryData(data)
        )
    }

    private func payload(blob: OpaquePointer, path: String, maxSizeBytes: Int64?) throws -> GitContentPayload {
        let sizeBytes = Int64(git_blob_rawsize(blob))
        try enforceSizeLimit(path: path, sizeBytes: sizeBytes, maxSizeBytes: maxSizeBytes)

        let data: Data
        if sizeBytes == 0 {
            data = Data()
        } else {
            guard let rawContent = git_blob_rawcontent(blob) else {
                throw GitDataPlaneError.unsupported(message: "blob has no raw content: \(path)")
            }
            data = Data(bytes: rawContent, count: Int(sizeBytes))
        }

        return GitContentPayload(
            data: data,
            contentHash: LibGit2ReviewSupport.sha256ContentHash(data),
            contentHashAlgorithm: "sha256",
            isBinary: git_blob_is_binary(blob) != 0
        )
    }

    private func enforceSizeLimit(path: String, sizeBytes: Int64, maxSizeBytes: Int64?) throws {
        guard let maxSizeBytes, sizeBytes > maxSizeBytes else {
            return
        }
        throw GitDataPlaneError.contentTooLarge(path: path, sizeBytes: sizeBytes, maxSizeBytes: maxSizeBytes)
    }
}
