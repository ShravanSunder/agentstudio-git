import Foundation

/// The commit a fork's branch target starts at. A start equal to the source's captured `HEAD` keeps the copy
/// exactly as it is; any other start resets the copy to that commit.
public enum GitForkStart: Equatable, Hashable, Sendable {
    /// The source worktree's `HEAD` commit, captured when the fork starts.
    case sourceHead
    /// A full object identifier, validated as a commit in the source repository.
    case commit(String)
}

extension GitForkStart: Codable {
    private enum CodingKeys: String, CodingKey {
        case kind
        case commit
    }

    private enum Kind: String, Codable {
        case sourceHead
        case commit
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let keys = Set(container.allKeys)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .sourceHead:
            guard keys == [.kind] else {
                throw invalidBranchTargetPayload(decoder, "a sourceHead start carries no commit")
            }
            self = .sourceHead
        case .commit:
            let commit = try container.decode(String.self, forKey: .commit)
            guard keys == [.kind, .commit], GitObjectIdentifierText.isFullObjectIdentifier(commit) else {
                throw invalidBranchTargetPayload(decoder, "a commit start carries one full object identifier")
            }
            self = .commit(commit)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .sourceHead:
            try container.encode(Kind.sourceHead, forKey: .kind)
        case .commit(let commit):
            try container.encode(Kind.commit, forKey: .kind)
            try container.encode(commit, forKey: .commit)
        }
    }
}

/// The remote branch a newly created local branch tracks: `branch.<name>.remote` and `branch.<name>.merge`.
public struct GitBranchUpstream: Codable, Equatable, Hashable, Sendable {
    public let remoteName: String
    /// Short branch name on the remote, without `refs/heads/`.
    public let branchName: String

    public init(remoteName: String, branchName: String) {
        self.remoteName = remoteName
        self.branchName = branchName
    }

    private enum CodingKeys: String, CodingKey {
        case remoteName
        case branchName
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let remoteName = try container.decode(String.self, forKey: .remoteName)
        let branchName = try container.decode(String.self, forKey: .branchName)
        guard !remoteName.isEmpty, !branchName.isEmpty else {
            throw invalidBranchTargetPayload(decoder, "an upstream names a remote and a branch")
        }
        self.init(remoteName: remoteName, branchName: branchName)
    }
}

/// Selects the destination's branch target. Every fork registers its linked worktree detached at the captured
/// `HEAD`, copies the source, and then attaches this target under the branch's native ref lock, re-reading
/// branch use there, so another worktree or process cannot take the branch between the check and the attach.
public enum GitForkWorktreeMode: Equatable, Hashable, Sendable {
    /// A new local branch at `start`. `upstream` writes branch.<name>.remote and .merge.
    case newBranch(name: String, start: GitForkStart, upstream: GitBranchUpstream?)
    /// An existing local branch that no worktree has checked out and whose tip, read under its native ref lock,
    /// is `expectedTip` (else `branchMoved`). With `fastForwardTo`, the ref first moves from `expectedTip` to that
    /// commit, which must descend from it; the move is journaled and undone if the fork fails. The start is the
    /// resulting tip.
    case existingBranch(name: String, expectedTip: String, fastForwardTo: String?)
    case detached(start: GitForkStart)
}

extension GitForkWorktreeMode: Codable {
    private enum CodingKeys: String, CodingKey {
        case kind
        case name
        case start
        case upstream
        case expectedTip
        case fastForwardTo
    }

    private enum Kind: String, Codable {
        case newBranch
        case existingBranch
        case detached
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let keys = Set(container.allKeys)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .newBranch:
            guard keys.isSubset(of: [.kind, .name, .start, .upstream]) else {
                throw invalidBranchTargetPayload(decoder, "a newBranch mode carries a name, a start, and an upstream")
            }
            self = .newBranch(
                name: try container.decode(String.self, forKey: .name),
                start: try container.decode(GitForkStart.self, forKey: .start),
                upstream: try container.decodeIfPresent(GitBranchUpstream.self, forKey: .upstream)
            )
        case .existingBranch:
            let expectedTip = try container.decode(String.self, forKey: .expectedTip)
            let fastForwardTo = try container.decodeIfPresent(String.self, forKey: .fastForwardTo)
            guard keys.isSubset(of: [.kind, .name, .expectedTip, .fastForwardTo]),
                GitObjectIdentifierText.isFullObjectIdentifier(expectedTip),
                fastForwardTo.map(GitObjectIdentifierText.isFullObjectIdentifier) ?? true
            else {
                throw invalidBranchTargetPayload(
                    decoder, "an existingBranch mode carries a name and full commit identifiers")
            }
            self = .existingBranch(
                name: try container.decode(String.self, forKey: .name),
                expectedTip: expectedTip,
                fastForwardTo: fastForwardTo
            )
        case .detached:
            guard keys == [.kind, .start] else {
                throw invalidBranchTargetPayload(decoder, "a detached mode carries only a start")
            }
            self = .detached(start: try container.decode(GitForkStart.self, forKey: .start))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .newBranch(let name, let start, let upstream):
            try container.encode(Kind.newBranch, forKey: .kind)
            try container.encode(name, forKey: .name)
            try container.encode(start, forKey: .start)
            try container.encodeIfPresent(upstream, forKey: .upstream)
        case .existingBranch(let name, let expectedTip, let fastForwardTo):
            try container.encode(Kind.existingBranch, forKey: .kind)
            try container.encode(name, forKey: .name)
            try container.encode(expectedTip, forKey: .expectedTip)
            try container.encodeIfPresent(fastForwardTo, forKey: .fastForwardTo)
        case .detached(let start):
            try container.encode(Kind.detached, forKey: .kind)
            try container.encode(start, forKey: .start)
        }
    }
}

private func invalidBranchTargetPayload(_ decoder: Decoder, _ description: String) -> DecodingError {
    .dataCorrupted(DecodingError.Context(codingPath: decoder.codingPath, debugDescription: description))
}
