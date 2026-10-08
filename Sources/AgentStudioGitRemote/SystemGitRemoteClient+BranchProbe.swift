import AgentStudioGitContracts
import CLibGit2Local
import Foundation

extension SystemGitRemoteClient {
    /// `git ls-remote --exit-code <remote> refs/heads/<branch>`: exit 0 with the exact ref is `present`; exit 2
    /// is `absent`, which Git computes on the client for every transport, so no stderr is read. Any other
    /// outcome (an unreachable remote, a refused protocol, a timeout) is thrown, and nothing is fetched.
    /// `insteadOf`, credential helpers, and the prompt policy apply exactly as they do for `fetch`. With the
    /// repository's `core.precomposeUnicode` on (the macOS default), git rewrites a decomposed branch name to its
    /// precomposed form before asking; the line it returns is then another ref, so the probe answers `absent`.
    public func probeRemoteBranch(_ request: GitRemoteBranchProbeRequest) async throws(GitDataPlaneError)
        -> GitRemoteBranchPresence
    {
        let referenceName = try Self.validatedProbeReferenceName(request)
        let result: GitProcessResult
        do throws(GitDataPlaneError) {
            result = try await runner.run(arguments: [
                "-C",
                request.repositoryPath.path,
                "ls-remote",
                "--exit-code",
                "--",
                request.remoteName,
                referenceName,
            ])
        } catch {
            if case .processFailed(let failure) = error, failure.exitCode == 2 {
                return .absent
            }
            throw error
        }
        // ls-remote matches patterns by path tail, so only the exact ref answers the question. Git refs are bytes:
        // a line ends only at a "\n" byte (`Character` splitting also breaks at U+2028, U+2029 and U+0085), and the
        // ref field must equal the requested name byte for byte (`String` equality also accepts a canonically
        // equivalent name, which is a different ref).
        let referenceBytes = Array(referenceName.utf8)
        for line in result.stdout.utf8.split(separator: UInt8(ascii: "\n")) {
            let fields = line.split(separator: UInt8(ascii: "\t"), maxSplits: 1, omittingEmptySubsequences: false)
            guard fields.count == 2, fields[1].elementsEqual(referenceBytes) else {
                continue
            }
            guard let commit = String(fields[0]), GitObjectIdentifierText.isFullObjectIdentifier(commit) else {
                throw .unsupported(message: "ls-remote returned an invalid object identifier")
            }
            return .present(commit: commit)
        }
        return .absent
    }

    private static func validatedProbeReferenceName(
        _ request: GitRemoteBranchProbeRequest
    ) throws(GitDataPlaneError) -> String {
        let initializationResult = git_libgit2_init()
        guard initializationResult >= 0 else {
            throw .unsupported(message: "could not initialize remote branch validation")
        }
        defer { _ = git_libgit2_shutdown() }

        var isValidRemote: Int32 = 0
        guard !request.remoteName.utf8.contains(0), !request.remoteName.hasPrefix("-"),
            request.remoteName.withCString({ git_remote_name_is_valid(&isValidRemote, $0) }) >= 0,
            isValidRemote == 1
        else {
            throw .unsupported(message: "remote name is invalid")
        }
        var isValidBranch: Int32 = 0
        guard !request.branchName.utf8.contains(0),
            request.branchName.withCString({ git_branch_name_is_valid(&isValidBranch, $0) }) >= 0,
            isValidBranch == 1
        else {
            throw .unsupported(message: "remote branch name is invalid")
        }
        return "refs/heads/\(request.branchName)"
    }
}
