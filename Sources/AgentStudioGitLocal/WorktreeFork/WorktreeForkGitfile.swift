import AgentStudioGitContracts
import Foundation

/// Reads a `.git` file the way Git does, without opening the repository it names: a nested repository is
/// classified from this text alone, so a broken one (a stale registration, alternates naming a removed store)
/// still classifies instead of failing the fork.
enum WorktreeForkGitfile {
    /// The path after `gitdir: `, as written (absolute, or relative to the file's directory); nil when `file` is
    /// not a gitfile (a `.git` directory, or any other text).
    static func recordedGitDirectory(_ file: URL, reportPath: String) throws(GitWorktreeForkError) -> String? {
        try WorktreeForkDatalessGuardedRead.run(file, reportPath: reportPath) { () throws(GitWorktreeForkError) in
            guard let text = try? String(contentsOf: file, encoding: .utf8), text.hasPrefix("gitdir: ") else {
                return nil
            }
            let recorded = text.dropFirst("gitdir: ".count).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !recorded.isEmpty, !recorded.contains("\n") else { return nil }
            return recorded
        }
    }
}
