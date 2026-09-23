import AgentStudioGitContracts
import CLibGit2Local
import Foundation

/// Proves every re-homed Git node is independently usable and that no administrative pointer resolves
/// outside destination-owned state: the destination tree or the fork's own linked-worktree administration.
struct WorktreeForkTopologyValidator: Sendable {
    let plan: WorktreeForkPlan

    private var allowedPrefixes: [String] {
        [
            plan.destinationRoot.path + "/",
            plan.commonDirectory.appending(path: "worktrees").appending(path: plan.worktreeName).path + "/",
        ]
    }

    func validate(
        _ rehomed: [WorktreeForkRehomedNode],
        evidenceByNode: [String: WorktreeForkIndexRefreshEvidence]
    ) throws(GitWorktreeForkError) {
        for path in plan.gitTopology.uninitializedSubmodulePaths {
            if case .success = WorktreeForkDescriptors.lstatPath(plan.destinationRoot.appending(path: "\(path)/.git")) {
                throw .validationFailed(reason: .submoduleStateMismatch, relativePath: path)
            }
        }
        for node in rehomed {
            try validateNode(node, evidence: evidenceByNode[node.node.relativePath])
        }
    }

    private func validateNode(
        _ rehomed: WorktreeForkRehomedNode,
        evidence: WorktreeForkIndexRefreshEvidence?
    ) throws(GitWorktreeForkError) {
        let reportPath = rehomed.node.relativePath
        let unusable = GitWorktreeForkError.validationFailed(
            reason: .nestedRepositoryUnusable, relativePath: reportPath)
        let repository: OpaquePointer
        do throws(GitWorktreeForkError) {
            repository = try WorktreeForkGitHandles.openWorktree(rehomed.destinationWorktree)
        } catch {
            throw unusable
        }
        defer { git_repository_free(repository) }
        guard let workdir = git_repository_workdir(repository), let gitDirectory = git_repository_path(repository),
            let commonDirectory = git_repository_commondir(repository),
            canonicalPath(String(cString: workdir)) == canonicalPath(rehomed.destinationWorktree.path),
            canonicalPath(String(cString: gitDirectory)) == canonicalPath(rehomed.destinationAdministration.path)
        else {
            throw unusable
        }
        try validateHead(rehomed.node, repository: repository)
        var pointers = [String(cString: gitDirectory), String(cString: commonDirectory)]
        pointers += configuredWorktree(repository, administration: rehomed.destinationAdministration)
        pointers +=
            (try? GitRepositoryStateRehomer.directAlternates(
                rehomed.destinationAdministration.appending(path: "objects"), reportPath
            ).map(\.path)) ?? []
        for pointer in pointers {
            let resolved = (canonicalPath(pointer) ?? pointer) + "/"
            guard allowedPrefixes.contains(where: { resolved.hasPrefix($0) }) else {
                throw .validationFailed(reason: .sourceAdministrationReference, relativePath: reportPath)
            }
        }
        try WorktreeForkIndexValidation.validate(
            worktreePath: rehomed.destinationWorktree,
            treeOID: rehomed.node.capturedHead?.treeOID,
            expectedSkipWorktree: rehomed.node.sparse?.skipWorktreePaths ?? [],
            evidence: evidence ?? WorktreeForkIndexRefreshEvidence(unrefreshedPaths: []),
            reportPrefix: reportPath
        )
    }

    private func validateHead(
        _ node: WorktreeForkGitNode,
        repository: OpaquePointer
    ) throws(GitWorktreeForkError) {
        let mismatch = GitWorktreeForkError.validationFailed(reason: .headMismatch, relativePath: node.relativePath)
        var headOID = git_oid()
        let resolved = git_reference_name_to_id(&headOID, repository, "HEAD") >= 0
        guard resolved == (node.capturedHead != nil) else {
            throw mismatch
        }
        if let capturedHead = node.capturedHead, oidString(&headOID) != capturedHead.commitOID {
            throw mismatch
        }
        guard let headReferenceName = node.headReferenceName else {
            return
        }
        var head: OpaquePointer?
        guard git_reference_lookup(&head, repository, "HEAD") >= 0, let head else {
            throw mismatch
        }
        defer { git_reference_free(head) }
        guard let target = git_reference_symbolic_target(head), String(cString: target) == headReferenceName else {
            throw mismatch
        }
    }

    private func configuredWorktree(_ repository: OpaquePointer, administration: URL) -> [String] {
        var configuration: OpaquePointer?
        guard git_repository_config_snapshot(&configuration, repository) >= 0, let configuration else {
            return []
        }
        defer { git_config_free(configuration) }
        var value: UnsafePointer<CChar>?
        guard git_config_get_string(&value, configuration, "core.worktree") >= 0, let value else {
            return []
        }
        let configured = String(cString: value)
        return [configured.hasPrefix("/") ? configured : administration.appending(path: configured).path]
    }

    private func canonicalPath(_ path: String) -> String? {
        guard case .success(let canonical) = WorktreeForkDescriptors.realpathURL(URL(fileURLWithPath: path)) else {
            return nil
        }
        return canonical.path
    }
}
