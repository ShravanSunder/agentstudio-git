import AgentStudioGitContracts
import Foundation

/// Proves the re-homed configuration closure, independently of the re-homer, in two walks:
///
/// - the destination closure, external files included, must hold no value that still names a source location
///   the fork relocates elsewhere, or one with no counterpart;
/// - the unchanged source closure decides what each reference requires. Every source value naming relocated
///   administration gives an exact source target and the destination that must stand for it: present when the
///   source is present and absent when it is absent, one source per destination name, an included
///   configuration file holding exactly the source's entries with the authorized relocations applied, and any
///   other file equivalent to its source. Unreferenced files that merely share a name are irrelevant.
struct WorktreeForkConfigurationPathValidation: Sendable {
    let plan: WorktreeForkPlan
    let relocation: WorktreeForkSourcePathRelocation

    func validate(_ roots: [WorktreeForkConfigurationCopy]) throws(GitWorktreeForkError) {
        try validateNoSourceReferences(roots.map { ($0.destination, $0.reportPath) })
        try validateRequiredCounterparts(roots)
    }

    private func validateNoSourceReferences(_ roots: [(file: URL, reportPath: String)]) throws(GitWorktreeForkError) {
        var visited = Set<String>()
        var pending = roots.map { (file: $0.file, reportPath: $0.reportPath, depth: 0) }
        while let (file, reportPath, depth) = pending.popLast() {
            guard visited.insert(file.path).inserted, case .success = WorktreeForkDescriptors.lstatPath(file) else {
                continue
            }
            let leftover = GitWorktreeForkError.validationFailed(
                reason: .sourceAdministrationReference, relativePath: reportPath)
            guard depth <= WorktreeForkConfigurationIncludes.maximumDepth,
                let entries = try? WorktreeForkConfigurationFile.ownEntries(in: file)
            else {
                throw leftover
            }
            for entry in entries {
                if let condition = WorktreeForkGitDirectoryCondition.parse(includeName: entry.name),
                    let location = condition.location(includedFrom: file, homeDirectory: plan.homeDirectory),
                    !WorktreeForkDestinationOwnership.isDestinationOwned(location.literal, plan: plan),
                    relocation.namesRelocatedSource(location.literal)
                {
                    throw leftover
                }
                guard WorktreeForkConfigurationIncludes.pathForm(name: entry.name, value: entry.value) != nil else {
                    continue
                }
                let target = WorktreeForkConfigurationIncludes.target(
                    of: entry.value, includedFrom: file, homeDirectory: plan.homeDirectory)
                if !WorktreeForkDestinationOwnership.isDestinationOwned(target, plan: plan),
                    relocation.namesRelocatedSource(target)
                {
                    throw leftover
                }
                // External includes are walked too: they are never edited, so a leftover there is a leak.
                if WorktreeForkConfigurationIncludes.isInclude(entry.name) {
                    pending.append(
                        (
                            target, WorktreeForkDestinationOwnership.reportLocation(of: target, plan: plan),
                            depth + 1
                        ))
                }
            }
        }
    }

    /// A configuration file reached in the source closure, with the report path of the file whose reference
    /// reached it (nil for a repository's own configuration, which no reference requires).
    private struct ReachedFile {
        let copy: WorktreeForkConfigurationCopy
        let referencedBy: String?
        let depth: Int
    }

    private func validateRequiredCounterparts(_ roots: [WorktreeForkConfigurationCopy]) throws(GitWorktreeForkError) {
        let mapping = WorktreeForkConfigurationRelocationMapping(plan: plan, relocation: relocation)
        var requiredSources: [String: URL] = [:]
        var visited = Set<String>()
        var pending = roots.map { ReachedFile(copy: $0, referencedBy: nil, depth: 0) }
        while let reached = pending.popLast() {
            let copy = reached.copy
            guard visited.insert(copy.source.path).inserted,
                let sourceEntries = try? WorktreeForkConfigurationFile.ownEntries(in: copy.source)
            else {
                continue
            }
            if let referencedBy = reached.referencedBy {
                // An included file the fork owns: the source's entries with exactly the authorized relocations.
                guard reached.depth <= WorktreeForkConfigurationIncludes.maximumDepth,
                    let destinationEntries = try? WorktreeForkConfigurationFile.ownEntries(in: copy.destination),
                    let expected = try? mapping.expectedEntries(of: sourceEntries, in: copy),
                    destinationEntries == expected
                else {
                    throw .validationFailed(reason: .nestedRepositoryUnusable, relativePath: referencedBy)
                }
            }
            for entry in sourceEntries {
                guard WorktreeForkConfigurationIncludes.pathForm(name: entry.name, value: entry.value) != nil else {
                    continue
                }
                let source = WorktreeForkConfigurationIncludes.target(
                    of: entry.value, includedFrom: copy.source, homeDirectory: plan.homeDirectory)
                guard case .relocated(let destination) = relocation.counterpart(of: source),
                    WorktreeForkDestinationOwnership.isDestinationOwned(destination, plan: plan)
                else {
                    continue
                }
                let isInclude = WorktreeForkConfigurationIncludes.isInclude(entry.name)
                if let match = relocation.administrationMatch(of: source) {
                    try requireCounterpart(
                        of: source, at: destination, match: match, comparesBytes: !isInclude,
                        requiredSources: &requiredSources, reportPath: copy.reportPath)
                }
                if isInclude, case .success = WorktreeForkDescriptors.lstatPath(source) {
                    pending.append(
                        ReachedFile(
                            copy: WorktreeForkConfigurationCopy(
                                source: source, destination: destination,
                                reportPath: WorktreeForkDestinationOwnership.reportLocation(
                                    of: destination, plan: plan)),
                            referencedBy: copy.reportPath, depth: reached.depth + 1))
                }
            }
        }
    }

    /// One reference into relocated administration: `destination` must stand for `source` and nothing else.
    private func requireCounterpart(
        of source: URL,
        at destination: URL,
        match: WorktreeForkSourcePathRelocation.AdministrationMatch,
        comparesBytes: Bool,
        requiredSources: inout [String: URL],
        reportPath: String
    ) throws(GitWorktreeForkError) {
        let unusable = GitWorktreeForkError.validationFailed(
            reason: .nestedRepositoryUnusable, relativePath: reportPath)
        if let required = requiredSources[destination.path] {
            guard required == source || WorktreeForkPrivateAdministrationCounterparts.sourcesAgree(required, source)
            else {
                throw unusable
            }
        } else {
            requiredSources[destination.path] = source
        }
        // Files re-homing writes itself (HEAD, worktree configuration) legitimately differ from their source.
        let writtenByRehoming = WorktreeForkPrivateAdministrationCounterparts.filesWrittenByRehoming.contains(
            match.remainder)
        switch (WorktreeForkDescriptors.lstatPath(source), WorktreeForkDescriptors.lstatPath(destination)) {
        case (.success, .failure):
            throw unusable
        case (.failure, .success) where !writtenByRehoming:
            // Git finds nothing in the source but would read a stand-in in the destination.
            throw unusable
        case (.success(let sourceInfo), .success)
        where comparesBytes && !writtenByRehoming && sourceInfo.st_mode & S_IFMT == S_IFREG:
            guard WorktreeForkFileEquivalence.isEquivalent(source, destination) else {
                throw unusable
            }
        default:
            return
        }
    }
}
