import AgentStudioGitContracts
import CLibGit2Local
import Foundation

struct LibGit2BranchReader: Sendable {
    private let runtime: LibGit2Runtime

    init(runtime: LibGit2Runtime = .shared) {
        self.runtime = runtime
    }

    func branches(for repositoryPath: URL) throws -> [GitBranchSnapshot] {
        try withRepository(at: repositoryPath) { repository in
            try branches(repository: repository)
        }
    }

    func branchSummary(repository: OpaquePointer) throws -> GitBranchSummary {
        let head = try headSnapshot(repository: repository)
        guard head.kind == .branch else {
            return GitBranchSummary(head: head, upstreamName: nil, aheadCount: 0, behindCount: 0, hasUpstream: false)
        }

        var headReference: OpaquePointer?
        let headResult = git_repository_head(&headReference, repository)
        guard headResult >= 0, let headReference else {
            throw LibGit2ErrorCapture.failure(code: headResult)
        }
        defer { git_reference_free(headReference) }

        let upstream = try upstreamNameAndCounts(for: headReference, repository: repository)
        return GitBranchSummary(
            head: head,
            upstreamName: upstream.name,
            aheadCount: upstream.aheadCount,
            behindCount: upstream.behindCount,
            hasUpstream: upstream.name != nil
        )
    }

    func originResolution(repository: OpaquePointer) -> GitOriginResolution {
        var remote: OpaquePointer?
        let lookupResult = "origin".withCString { namePointer in
            git_remote_lookup(&remote, repository, namePointer)
        }
        guard lookupResult >= 0, let remote else {
            return lookupResult == GIT_ENOTFOUND.rawValue ? .confirmedAbsent : .awaitingResolution
        }
        defer { git_remote_free(remote) }

        guard let urlPointer = git_remote_url(remote) else {
            return .awaitingResolution
        }
        let rawURL = String(cString: urlPointer).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawURL.isEmpty else {
            return .awaitingResolution
        }

        let remoteName = git_remote_name(remote).map { String(cString: $0) } ?? "origin"
        return .resolved(
            GitRemoteSnapshot(
                name: remoteName,
                url: publicRemoteURL(from: rawURL),
                rawURL: GitRedaction.redact(rawURL)
            ))
    }

    private func branches(repository: OpaquePointer) throws -> [GitBranchSnapshot] {
        var iterator: OpaquePointer?
        let iteratorResult = git_branch_iterator_new(&iterator, repository, GIT_BRANCH_LOCAL)
        guard iteratorResult >= 0, let iterator else {
            throw LibGit2ErrorCapture.failure(code: iteratorResult)
        }
        defer { git_branch_iterator_free(iterator) }

        var snapshots: [GitBranchSnapshot] = []
        while true {
            var reference: OpaquePointer?
            var branchType = git_branch_t(rawValue: 0)
            let nextResult = git_branch_next(&reference, &branchType, iterator)
            if nextResult == GIT_ITEROVER.rawValue {
                break
            }
            guard nextResult >= 0, let reference else {
                throw LibGit2ErrorCapture.failure(code: nextResult)
            }

            do {
                defer { git_reference_free(reference) }
                snapshots.append(
                    GitBranchSnapshot(
                        name: try branchName(reference),
                        isCurrent: try isCurrentBranch(reference),
                        upstreamName: try upstreamName(for: reference, repository: repository)
                    )
                )
            }
        }

        return snapshots.sorted { $0.name < $1.name }
    }

    private func upstreamNameAndCounts(
        for branch: OpaquePointer,
        repository: OpaquePointer
    ) throws -> (name: String?, aheadCount: Int, behindCount: Int) {
        let upstreamName = try upstreamName(for: branch, repository: repository)
        guard upstreamName != nil else {
            return (nil, 0, 0)
        }

        var upstreamReference: OpaquePointer?
        let upstreamResult = git_branch_upstream(&upstreamReference, branch)
        if upstreamResult == GIT_ENOTFOUND.rawValue {
            return (upstreamName, 0, 0)
        }
        guard upstreamResult >= 0, let upstreamReference else {
            throw LibGit2ErrorCapture.failure(code: upstreamResult)
        }
        defer { git_reference_free(upstreamReference) }

        guard let localOID = git_reference_target(branch) ?? git_reference_target_peel(branch),
            let upstreamOID = git_reference_target(upstreamReference) ?? git_reference_target_peel(upstreamReference)
        else {
            return (upstreamName, 0, 0)
        }

        var ahead = 0
        var behind = 0
        let graphResult = git_graph_ahead_behind(&ahead, &behind, repository, localOID, upstreamOID)
        guard graphResult >= 0 else {
            throw LibGit2ErrorCapture.failure(code: graphResult)
        }
        return (upstreamName, ahead, behind)
    }

    private func upstreamName(for branch: OpaquePointer, repository: OpaquePointer) throws -> String? {
        guard let referenceNamePointer = git_reference_name(branch) else {
            return nil
        }

        var buffer = git_buf(ptr: nil, reserved: 0, size: 0)
        let upstreamResult = git_branch_upstream_name(&buffer, repository, referenceNamePointer)
        defer { git_buf_dispose(&buffer) }
        if upstreamResult == GIT_ENOTFOUND.rawValue {
            return nil
        }
        guard upstreamResult >= 0 else {
            throw LibGit2ErrorCapture.failure(code: upstreamResult)
        }
        guard let bufferPointer = buffer.ptr else {
            return nil
        }
        return String(cString: bufferPointer)
    }

    private func branchName(_ reference: OpaquePointer) throws -> String {
        var namePointer: UnsafePointer<CChar>?
        let nameResult = git_branch_name(&namePointer, reference)
        guard nameResult >= 0, let namePointer else {
            throw LibGit2ErrorCapture.failure(code: nameResult)
        }
        return String(cString: namePointer)
    }

    private func isCurrentBranch(_ reference: OpaquePointer) throws -> Bool {
        let isHeadResult = git_branch_is_head(reference)
        guard isHeadResult >= 0 else {
            throw LibGit2ErrorCapture.failure(code: isHeadResult)
        }
        return isHeadResult == 1
    }

    private func remoteURL(from rawURL: String) -> URL {
        if rawURL.hasPrefix("/") {
            return URL(fileURLWithPath: rawURL)
        }
        if let url = URL(string: rawURL) {
            return url
        }
        return URL(fileURLWithPath: rawURL)
    }

    private func publicRemoteURL(from rawURL: String) -> URL {
        guard var components = URLComponents(string: rawURL) else {
            return remoteURL(from: GitRedaction.redact(rawURL))
        }

        components.user = nil
        components.password = nil
        guard let credentialStrippedURL = components.url else {
            return remoteURL(from: GitRedaction.redact(rawURL))
        }
        return remoteURL(from: GitRedaction.redact(credentialStrippedURL.absoluteString))
    }

    private func withRepository<ReturnValue>(
        at path: URL,
        _ body: (OpaquePointer) throws -> ReturnValue
    ) throws -> ReturnValue {
        try runtime.ensureInitialized()

        var repository: OpaquePointer?
        let openResult = path.path.withCString { pathPointer in
            git_repository_open_ext(&repository, pathPointer, 0, nil)
        }
        guard openResult >= 0, let repository else {
            throw repositoryOpenFailure(code: openResult, path: path)
        }
        defer { git_repository_free(repository) }

        return try body(repository)
    }
}

struct GitBranchSummary: Sendable {
    let head: GitHeadSnapshot
    let upstreamName: String?
    let aheadCount: Int
    let behindCount: Int
    let hasUpstream: Bool
}
