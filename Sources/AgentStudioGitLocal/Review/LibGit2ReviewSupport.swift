import AgentStudioGitContracts
import CLibGit2Local
import CryptoKit
import Foundation

enum LibGit2ReviewSupport {
    static func withRepository<ReturnValue>(
        at path: URL,
        runtime: LibGit2Runtime = .shared,
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

    static func resolveCommit(_ target: GitRevisionTarget, repository: OpaquePointer) throws -> OpaquePointer {
        var object: OpaquePointer?
        let revparseResult = target.name.withCString { targetPointer in
            git_revparse_single(&object, repository, targetPointer)
        }
        guard revparseResult >= 0, let object else {
            throw LibGit2ErrorCapture.failure(code: revparseResult)
        }
        defer { git_object_free(object) }

        var commit: OpaquePointer?
        let peelResult = git_object_peel(&commit, object, GIT_OBJECT_COMMIT)
        guard peelResult >= 0, let commit else {
            throw LibGit2ErrorCapture.failure(code: peelResult)
        }
        return commit
    }

    static func resolveTree(_ target: GitRevisionTarget, repository: OpaquePointer) throws -> OpaquePointer {
        let commit = try resolveCommit(target, repository: repository)
        defer { git_commit_free(commit) }

        var tree: OpaquePointer?
        let treeResult = git_commit_tree(&tree, commit)
        guard treeResult >= 0, let tree else {
            throw LibGit2ErrorCapture.failure(code: treeResult)
        }
        return tree
    }

    static func resolveTree(_ target: GitDiffTarget, repository: OpaquePointer) throws -> OpaquePointer {
        switch target.kind {
        case .head:
            return try resolveTree(.named("HEAD"), repository: repository)
        case .commit:
            guard let identifier = target.identifier else {
                throw GitDataPlaneError.unsupported(message: "commit diff target requires an identifier")
            }
            return try resolveTree(.named(identifier), repository: repository)
        case .index, .workingTree:
            throw GitDataPlaneError.unsupported(message: "\(target.kind.rawValue) cannot be resolved as a tree")
        }
    }

    static func resolveCommit(_ target: GitDiffTarget, repository: OpaquePointer) throws -> OpaquePointer {
        switch target.kind {
        case .head:
            return try resolveCommit(.named("HEAD"), repository: repository)
        case .commit:
            guard let identifier = target.identifier else {
                throw GitDataPlaneError.unsupported(message: "commit diff target requires an identifier")
            }
            return try resolveCommit(.named(identifier), repository: repository)
        case .index, .workingTree:
            throw GitDataPlaneError.unsupported(message: "\(target.kind.rawValue) cannot be resolved as a commit")
        }
    }

    static func oidString(_ oid: UnsafePointer<git_oid>) -> String {
        var buffer = [CChar](repeating: 0, count: 41)
        git_oid_tostr(&buffer, buffer.count, oid)
        let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return String(bytes: bytes, encoding: .utf8) ?? ""
    }

    static func oidString(_ oid: git_oid) -> String {
        var mutableOID = oid
        return withUnsafePointer(to: &mutableOID) { oidString($0) }
    }

    static func isZeroOID(_ oid: git_oid) -> Bool {
        var mutableOID = oid
        return withUnsafePointer(to: &mutableOID) { git_oid_is_zero($0) != 0 }
    }

    static func path(_ pointer: UnsafePointer<CChar>?) -> String? {
        pointer.map { String(cString: $0) }
    }

    static func sha256ContentHash(_ data: Data) -> String {
        let digest = SHA256.hash(data: data)
        return "sha256:\(digest.map { String(format: "%02x", $0) }.joined())"
    }

    static func isBinaryData(_ data: Data) -> Bool {
        if data.isEmpty {
            return false
        }
        return data.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.bindMemory(to: CChar.self).baseAddress else {
                return false
            }
            return git_blob_data_is_binary(baseAddress, data.count) != 0
        }
    }

    static func repositoryWorkDirectory(_ repository: OpaquePointer) throws -> URL {
        guard let workdirPointer = git_repository_workdir(repository) else {
            throw GitDataPlaneError.unsupported(message: "repository has no working directory")
        }
        return URL(fileURLWithPath: String(cString: workdirPointer), isDirectory: true)
    }

    static func repositoryCommonDirectory(_ repository: OpaquePointer) throws -> URL {
        guard let commonDirectoryPointer = git_repository_commondir(repository) else {
            throw GitDataPlaneError.unsupported(message: "repository has no common Git directory")
        }
        return URL(fileURLWithPath: String(cString: commonDirectoryPointer), isDirectory: true)
    }

    static func containedWorkingTreeFile(repository: OpaquePointer, path: String) throws -> URL {
        try validateRepositoryRelativePath(path)

        let workDirectory = try repositoryWorkDirectory(repository)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        let candidate =
            workDirectory
            .appending(path: path)
            .standardizedFileURL

        if (try? FileManager.default.destinationOfSymbolicLink(atPath: candidate.path)) != nil {
            throw GitDataPlaneError.pathEscapesRepository(path: path)
        }

        let resolvedCandidate = candidate.resolvingSymlinksInPath()
        guard isContained(resolvedCandidate, in: workDirectory) else {
            throw GitDataPlaneError.pathEscapesRepository(path: path)
        }

        let values = try resolvedCandidate.resourceValues(forKeys: [.isRegularFileKey])
        guard values.isRegularFile == true else {
            throw GitDataPlaneError.unsupported(message: "content path is not a regular file: \(path)")
        }

        return resolvedCandidate
    }

    private static func validateRepositoryRelativePath(_ path: String) throws {
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !path.isEmpty, !path.hasPrefix("/"), !components.contains("..") else {
            throw GitDataPlaneError.pathEscapesRepository(path: path)
        }
    }

    private static func isContained(_ candidate: URL, in directory: URL) -> Bool {
        let directoryPath = directory.path.hasSuffix("/") ? directory.path : "\(directory.path)/"
        return candidate.path == directory.path || candidate.path.hasPrefix(directoryPath)
    }
}
