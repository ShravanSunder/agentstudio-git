import AgentStudioGitContracts
import CLibGit2Local
import Foundation

struct LibGit2RemoteNameReader: Sendable {
    private let runtime: LibGit2Runtime

    init(runtime: LibGit2Runtime = .shared) {
        self.runtime = runtime
    }

    /// Every `remote.<name>` section of the repository's configuration, in libgit2's order.
    func remoteNames(for repositoryPath: URL) throws -> [String] {
        try LibGit2ReviewSupport.withRepository(at: repositoryPath, runtime: runtime) { repository in
            var names = git_strarray()
            let listResult = git_remote_list(&names, repository)
            guard listResult >= 0 else {
                throw LibGit2ErrorCapture.failure(code: listResult)
            }
            defer { git_strarray_free(&names) }
            return (0..<names.count).compactMap { position in
                names.strings[position].map { String(cString: $0) }
            }
        }
    }
}
