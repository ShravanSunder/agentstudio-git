import AgentStudioGitContracts
import CLibGit2Local
import Foundation

extension WorktreeForkChangesOnlyPlanner {
    func planLargeFileRestorations(
        context: WorktreeForkChangesOnlyCaptureContext,
        candidates: inout Set<String>
    ) throws(GitWorktreeForkError) -> (
        restorations: [WorktreeForkLargeFileRestoration],
        smudgedPaths: Set<String>,
        trackedChangeCount: Int
    ) {
        var restorations: [WorktreeForkLargeFileRestoration] = []
        var smudgedPaths = Set<String>()
        var trackedChangeCount = 0
        for (path, pointer) in context.filters.largeFilePointers {
            try cancellation.throwIfCancelled()
            let node = try capture(path, rootDescriptor: context.sourceRootDescriptor)
            guard node.kind == .regularFile,
                node.size == Int64(pointer.payloadByteCount),
                node.contentSHA256 == pointer.payloadSHA256,
                let identity = node.identity
            else {
                continue
            }
            smudgedPaths.insert(path)
            candidates.remove(path)
            if Self.lfsModeDiffersFromHead(
                sourceMode: node.mode, path: path, headEntries: context.headEntries)
            {
                trackedChangeCount += 1
            }
            restorations.append(
                WorktreeForkLargeFileRestoration(
                    relativePath: path,
                    identity: identity,
                    mode: node.mode,
                    size: node.size,
                    contentSHA256: pointer.payloadSHA256
                ))
        }
        return (restorations, smudgedPaths, trackedChangeCount)
    }

    private static func lfsModeDiffersFromHead(
        sourceMode: UInt32,
        path: String,
        headEntries: [String: WorktreeForkTreeEntry]
    ) -> Bool {
        guard let headEntry = headEntries[path] else {
            return false
        }
        let sourceIsExecutable = sourceMode & 0o111 != 0
        let headIsExecutable = headEntry.mode == UInt32(GIT_FILEMODE_BLOB_EXECUTABLE.rawValue)
        return sourceIsExecutable != headIsExecutable
    }
}
