import AgentStudioGitContracts
import CLibGit2Local
import CryptoKit
import Foundation

struct GitBranchIntegrationDelta: Equatable, Hashable, Sendable {
    let entries: [GitBranchIntegrationDeltaEntry]

    init(entries: [GitBranchIntegrationDeltaEntry]) {
        self.entries = entries.sorted { $0.path.lexicographicallyPrecedes($1.path) }
    }
}

struct GitBranchIntegrationDeltaEntry: Equatable, Hashable, Sendable {
    let path: [UInt8]
    let oldMode: UInt16
    let oldObjectID: String
    let newMode: UInt16
    let newObjectID: String
}

enum GitBranchIntegrationProofFailure: Error, Equatable, Sendable {
    case missingObjects
    case readFailed
}

struct LibGit2BranchIntegrationDeltaReader: Sendable {
    private let afterDeltaRead: @Sendable () -> Void

    init(afterDeltaRead: @escaping @Sendable () -> Void = {}) {
        self.afterDeltaRead = afterDeltaRead
    }

    func read(
        oldTree: OpaquePointer,
        newTree: OpaquePointer,
        repository: OpaquePointer
    ) throws(GitBranchIntegrationProofFailure) -> GitBranchIntegrationDelta {
        var options = git_diff_options()
        let optionsResult = git_diff_options_init(&options, UInt32(GIT_DIFF_OPTIONS_VERSION))
        guard optionsResult >= 0 else {
            throw Self.failure(for: optionsResult)
        }
        options.flags = GIT_DIFF_SKIP_BINARY_CHECK.rawValue
        options.ignore_submodules = GIT_SUBMODULE_IGNORE_NONE

        var diff: OpaquePointer?
        let diffResult = git_diff_tree_to_tree(&diff, repository, oldTree, newTree, &options)
        guard diffResult >= 0, let diff else {
            throw Self.failure(for: diffResult)
        }
        defer { git_diff_free(diff) }

        var entries: [GitBranchIntegrationDeltaEntry] = []
        entries.reserveCapacity(git_diff_num_deltas(diff))

        for index in 0..<git_diff_num_deltas(diff) {
            guard let delta = git_diff_get_delta(diff, index) else {
                throw .readFailed
            }
            guard
                let path = Self.rawPath(delta.pointee.old_file.path)
                    ?? Self.rawPath(delta.pointee.new_file.path)
            else {
                throw .readFailed
            }
            entries.append(
                GitBranchIntegrationDeltaEntry(
                    path: path,
                    oldMode: delta.pointee.old_file.mode,
                    oldObjectID: LibGit2ReviewSupport.oidString(delta.pointee.old_file.id),
                    newMode: delta.pointee.new_file.mode,
                    newObjectID: LibGit2ReviewSupport.oidString(delta.pointee.new_file.id)
                )
            )
        }

        let delta = GitBranchIntegrationDelta(entries: entries)
        afterDeltaRead()
        return delta
    }

    private static func rawPath(_ path: UnsafePointer<CChar>?) -> [UInt8]? {
        guard let path else {
            return nil
        }
        var byteCount = 0
        while path[byteCount] != 0 {
            byteCount += 1
        }
        let bytePointer = UnsafeRawPointer(path).assumingMemoryBound(to: UInt8.self)
        return Array(UnsafeBufferPointer(start: bytePointer, count: byteCount))
    }

    private static func failure(for code: Int32) -> GitBranchIntegrationProofFailure {
        code == GIT_ENOTFOUND.rawValue ? .missingObjects : .readFailed
    }
}

struct GitBranchIntegrationDeltaIndex: Sendable {
    private struct Candidate: Sendable {
        let commit: String
        let delta: GitBranchIntegrationDelta
    }

    private let digest: @Sendable (GitBranchIntegrationDelta) -> Data
    private var candidatesByDigest: [Data: [Candidate]] = [:]

    init(digest: @escaping @Sendable (GitBranchIntegrationDelta) -> Data = Self.sha256Digest) {
        self.digest = digest
    }

    mutating func insert(_ delta: GitBranchIntegrationDelta, commit: String) {
        candidatesByDigest[digest(delta), default: []].append(Candidate(commit: commit, delta: delta))
    }

    func matchingCommit(for delta: GitBranchIntegrationDelta) -> String? {
        candidatesByDigest[digest(delta)]?.first(where: { $0.delta == delta })?.commit
    }

    private static func sha256Digest(_ delta: GitBranchIntegrationDelta) -> Data {
        var encoded = Data()
        append(UInt64(delta.entries.count), to: &encoded)
        for entry in delta.entries {
            append(entry.path, to: &encoded)
            append(UInt64(entry.oldMode), to: &encoded)
            append(entry.oldObjectID, to: &encoded)
            append(UInt64(entry.newMode), to: &encoded)
            append(entry.newObjectID, to: &encoded)
        }
        return Data(SHA256.hash(data: encoded))
    }

    private static func append(_ bytes: [UInt8], to data: inout Data) {
        append(UInt64(bytes.count), to: &data)
        data.append(contentsOf: bytes)
    }

    private static func append(_ string: String, to data: inout Data) {
        append(Array(string.utf8), to: &data)
    }

    private static func append(_ integer: UInt64, to data: inout Data) {
        var bigEndianInteger = integer.bigEndian
        withUnsafeBytes(of: &bigEndianInteger) { data.append(contentsOf: $0) }
    }
}
