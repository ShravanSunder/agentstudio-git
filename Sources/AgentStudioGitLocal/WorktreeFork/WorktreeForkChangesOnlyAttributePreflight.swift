import AgentStudioGitContracts
import CLibGit2Local
import Foundation

extension WorktreeForkChangesOnlyPlanner {
    /// Status omits ignored files, so inspect only attribute files in directories represented by captured HEAD paths.
    func changedWorktreeAttributePath(
        repository: OpaquePointer,
        headEntries: [String: WorktreeForkTreeEntry],
        sourceRootDescriptor: Int32
    ) throws(GitWorktreeForkError) -> String? {
        var attributePaths: Set<String> = [".gitattributes"]
        for headPath in headEntries.keys {
            let components = headPath.split(separator: "/")
            for directoryDepth in 1..<components.count {
                attributePaths.insert("\(components.prefix(directoryDepth).joined(separator: "/"))/.gitattributes")
            }
        }

        for attributePath in attributePaths.sorted() {
            try cancellation.throwIfCancelled()
            let sourceNode = try capture(attributePath, rootDescriptor: sourceRootDescriptor)
            guard let headEntry = headEntries[attributePath] else {
                if sourceNode.kind != .absent {
                    return attributePath
                }
                continue
            }
            guard sourceNode.kind == .regularFile,
                headEntry.mode == UInt32(GIT_FILEMODE_BLOB.rawValue)
                    || headEntry.mode == UInt32(GIT_FILEMODE_BLOB_EXECUTABLE.rawValue),
                let sourceContentSHA256 = sourceNode.contentSHA256
            else {
                return attributePath
            }
            let headContentSHA256 = try WorktreeForkChangesOnlyGitSnapshotReader.blobSHA256(
                headEntry.oid, repository: repository)
            guard sourceContentSHA256 == headContentSHA256 else {
                return attributePath
            }
        }
        return nil
    }
}
