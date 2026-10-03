import AgentStudioGitContracts
import Foundation

/// One configuration file the fork owns a copy of, paired with the source file it was copied from, so a
/// relative include in the copy can be resolved the way Git resolved it in the source.
struct WorktreeForkConfigurationCopy: Sendable {
    let source: URL
    let destination: URL
    let reportPath: String

    /// A repository's own configuration files: shared `config` from its common administration and
    /// worktree-scoped `config.worktree` from its private administration.
    static func repositoryFiles(
        sourceCommonDirectory: URL,
        sourceGitDirectory: URL,
        destinationAdministration: URL,
        reportPath: String
    ) -> [Self] {
        [
            Self(
                source: sourceCommonDirectory.appending(path: "config"),
                destination: destinationAdministration.appending(path: "config"),
                reportPath: "\(reportPath)/config"),
            Self(
                source: sourceGitDirectory.appending(path: "config.worktree"),
                destination: destinationAdministration.appending(path: "config.worktree"),
                reportPath: "\(reportPath)/config.worktree"),
        ]
    }
}

/// Git's include rules, shared by the re-homer and the validator.
enum WorktreeForkConfigurationIncludes {
    /// Git refuses configuration nested deeper than this many includes.
    static let maximumDepth = 10

    /// `include.path` and every `includeIf.<condition>.path`, as libgit2 names them.
    static func isInclude(_ name: String) -> Bool {
        name == "include.path" || (name.hasPrefix("includeif.") && name.hasSuffix(".path"))
    }

    /// The canonical file an include value names, resolved as Git does: `~/` against the home directory,
    /// a relative path against the directory of the file that holds it.
    static func target(of value: String, includedFrom file: URL) -> URL {
        let path: String
        if value.hasPrefix("~/") {
            path = FileManager.default.homeDirectoryForCurrentUser.appending(path: String(value.dropFirst(2))).path
        } else if value.hasPrefix("/") {
            path = value
        } else {
            path = file.deletingLastPathComponent().appending(path: value).path
        }
        return WorktreeForkSourcePathRelocation.canonicalized(absolutePath: path)
    }

    static func isRelative(_ value: String) -> Bool {
        !value.hasPrefix("/") && !value.hasPrefix("~/")
    }
}

/// Keys whose values Git reads as regular expressions, not paths, so a value that happens to start with `/`
/// must not be relocated or validated as one: a diff driver's `xfuncname`, `funcname`, and `wordRegex`
/// (Git's `userdiff_config`). The re-homer and the validator both consult this one list.
enum WorktreeForkConfigurationPatternKeys {
    private static let diffDriverPatternVariables: Set<String> = ["xfuncname", "funcname", "wordregex"]

    static func holdsPattern(_ name: String) -> Bool {
        let parts = name.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 3, parts.first?.lowercased() == "diff", let variable = parts.last else {
            return false
        }
        return diffDriverPatternVariables.contains(variable.lowercased())
    }
}

/// Re-aims the absolute paths that a repository's configuration records, across its whole include closure,
/// at their destination counterparts. Every reached file the fork owns a copy of (inside the destination
/// tree or the fork's own administration) is edited. A reached file the fork does not own (outside the
/// source, or in the shared repository) is never edited: it is read, with its own includes, and a value or
/// `gitdir` condition there naming a relocated source location refuses the fork, because the destination
/// would keep reading source state through it.
struct WorktreeForkConfigurationPathRehomer: Sendable {
    let plan: WorktreeForkPlan
    let relocation: WorktreeForkSourcePathRelocation
    let lockTracker: WorktreeForkLockTracker

    /// Returns the destination files it edited. Every relocated value that names a captured private
    /// administration gets its counterpart cloned through `counterparts` before an include there is followed.
    func rehome(
        _ roots: [WorktreeForkConfigurationCopy],
        counterparts: inout WorktreeForkPrivateAdministrationCounterparts
    ) throws(GitWorktreeForkError) -> [URL] {
        var edited: [URL] = []
        var visited = Set<String>()
        var pending = roots.map { (file: PendingFile.owned($0), depth: 0) }
        while let (file, depth) = pending.popLast() {
            let copy: WorktreeForkConfigurationCopy
            switch file {
            case .owned(let owned):
                copy = owned
            case .external(let external, let includedBy):
                guard visited.insert(external.path).inserted,
                    case .success = WorktreeForkDescriptors.lstatPath(external)
                else {
                    continue
                }
                guard depth <= WorktreeForkConfigurationIncludes.maximumDepth else {
                    throw .entryFailed(
                        relativePath: includedBy, reason: .unresolvableGitAdministration, errorNumber: nil)
                }
                pending += try externalIncludes(of: external, includedBy: includedBy).map { ($0, depth + 1) }
                continue
            }
            guard visited.insert(copy.destination.path).inserted,
                case .success = WorktreeForkDescriptors.lstatPath(copy.destination)
            else {
                continue
            }
            let unresolvable = GitWorktreeForkError.entryFailed(
                relativePath: copy.reportPath, reason: .unresolvableGitAdministration, errorNumber: nil)
            guard depth <= WorktreeForkConfigurationIncludes.maximumDepth else {
                throw unresolvable
            }
            var edits: [WorktreeForkConfigurationEdit] = []
            for entry in try Self.ownEntries(of: copy) {
                let value = try relocatedValue(for: entry, in: copy, counterparts: &counterparts)
                if let name = try relocatedConditionName(for: entry, in: copy) {
                    edits.append(.moveValue(entry.name, matching: entry.value, to: name, value: value ?? entry.value))
                } else if let value {
                    edits.append(.replaceValue(entry.name, matching: entry.value, with: value))
                }
                guard WorktreeForkConfigurationIncludes.isInclude(entry.name) else {
                    continue
                }
                let sourceTarget = WorktreeForkConfigurationIncludes.target(of: entry.value, includedFrom: copy.source)
                switch relocation.counterpart(of: sourceTarget) {
                case .relocated(let destinationTarget)
                where WorktreeForkDestinationOwnership.isDestinationOwned(destinationTarget, plan: plan):
                    pending.append(
                        (
                            .owned(
                                WorktreeForkConfigurationCopy(
                                    source: sourceTarget, destination: destinationTarget,
                                    reportPath: WorktreeForkDestinationOwnership.reportLocation(
                                        of: destinationTarget, plan: plan))),
                            depth + 1
                        ))
                case .outsideSource, .sharedRepository:
                    pending.append((.external(sourceTarget, includedBy: copy.reportPath), depth + 1))
                case .relocated, .unmapped:
                    continue
                }
            }
            if !edits.isEmpty {
                try WorktreeForkConfigurationFile.apply(
                    edits, to: copy.destination, reportPath: copy.reportPath, lockTracker: lockTracker)
                edited.append(copy.destination)
            }
        }
        return edited
    }

    /// The new value for an entry, or nil to keep it. An absolute value is re-aimed at its relocated
    /// counterpart. A relative include is re-aimed only when, read from the copy, it no longer reaches what it
    /// reached from the source. Values outside the source or in the shared repository keep their target; a
    /// source path with no counterpart fails.
    private func relocatedValue(
        for entry: WorktreeForkConfigurationEntry,
        in copy: WorktreeForkConfigurationCopy,
        counterparts: inout WorktreeForkPrivateAdministrationCounterparts
    ) throws(GitWorktreeForkError) -> String? {
        let isRelativeInclude =
            WorktreeForkConfigurationIncludes.isInclude(entry.name)
            && WorktreeForkConfigurationIncludes.isRelative(entry.value)
        guard entry.value.hasPrefix("/") || isRelativeInclude,
            !WorktreeForkConfigurationPatternKeys.holdsPattern(entry.name)
        else {
            return nil
        }
        let source = WorktreeForkConfigurationIncludes.target(of: entry.value, includedFrom: copy.source)
        let wanted: URL
        switch relocation.counterpart(of: source) {
        case .outsideSource, .sharedRepository:
            wanted = source
        case .relocated(let destination):
            try counterparts.materializeCounterpart(of: source)
            wanted = destination
        case .unmapped:
            let sourcePath =
                WorktreeForkAdministrativeSymlinks.relativeComponents(of: source, beneath: plan.sourceRoot)
                ?? source.lastPathComponent
            throw .entryFailed(
                relativePath: "\(copy.reportPath): \(entry.name) = \(sourcePath)",
                reason: .unresolvableGitAdministration,
                errorNumber: nil
            )
        }
        let reachedFromCopy =
            isRelativeInclude
            ? WorktreeForkConfigurationIncludes.target(of: entry.value, includedFrom: copy.destination).path
            : entry.value
        guard reachedFromCopy != wanted.path, !(entry.value.hasPrefix("/") && wanted == source) else {
            return nil
        }
        return wanted.path
    }

    /// The new key for a `gitdir` conditional include whose pattern names a relocated location, or nil to keep
    /// it. Patterns outside the source or in the shared repository keep their target. A glob that could
    /// match beneath a location that relocates differently has no exact counterpart, so it fails.
    private func relocatedConditionName(
        for entry: WorktreeForkConfigurationEntry,
        in copy: WorktreeForkConfigurationCopy
    ) throws(GitWorktreeForkError) -> String? {
        guard let condition = WorktreeForkGitDirectoryCondition.parse(includeName: entry.name),
            let source = condition.location(includedFrom: copy.source)
        else {
            return nil
        }
        let sourceLiteral =
            WorktreeForkAdministrativeSymlinks.relativeComponents(of: source.literal, beneath: plan.sourceRoot)
            ?? source.literal.lastPathComponent
        let displayedPattern = WorktreeForkGitDirectoryCondition.pattern(literal: sourceLiteral, following: source)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let unresolvable = GitWorktreeForkError.entryFailed(
            relativePath: "\(copy.reportPath): includeif.\(condition.prefix)\(displayedPattern).path",
            reason: .unresolvableGitAdministration,
            errorNumber: nil
        )
        switch relocation.counterpart(of: source.literal) {
        case .outsideSource, .sharedRepository:
            return nil
        case .unmapped:
            throw unresolvable
        case .relocated(let destination):
            if source.matchesBeneathLiteral, relocation.hasRelocation(strictlyBeneath: source.literal) {
                throw unresolvable
            }
            // A `./` pattern that still reaches the counterpart from the copy keeps its text.
            if condition.location(includedFrom: copy.destination)?.literal.path == destination.path {
                return nil
            }
            return condition.includeName(
                withPattern: WorktreeForkGitDirectoryCondition.pattern(literal: destination.path, following: source))
        }
    }

    /// A reached configuration file and whether the fork owns a copy of it. An external file is read in
    /// place; `includedBy` is the report path of the owned file whose include chain reached it.
    private enum PendingFile {
        case owned(WorktreeForkConfigurationCopy)
        case external(URL, includedBy: String)
    }

    /// Reads one external file read-only and refuses the fork when any path value or `gitdir` condition in
    /// it names a relocated source location; returns its own includes to read next.
    private func externalIncludes(
        of file: URL,
        includedBy: String
    ) throws(GitWorktreeForkError) -> [PendingFile] {
        let entries: [WorktreeForkConfigurationEntry]
        do {
            entries = try WorktreeForkConfigurationFile.ownEntries(in: file)
        } catch {
            throw .entryFailed(relativePath: includedBy, reason: .unresolvableGitAdministration, errorNumber: nil)
        }
        var includes: [PendingFile] = []
        for entry in entries {
            if let condition = WorktreeForkGitDirectoryCondition.parse(includeName: entry.name),
                let location = condition.location(includedFrom: file),
                relocation.namesRelocatedSource(location.literal)
            {
                let pattern = WorktreeForkGitDirectoryCondition.pattern(
                    literal: sourceRelative(location.literal), following: location)
                throw .entryFailed(
                    relativePath: "\(includedBy): includeif.\(condition.prefix)\(pattern).path",
                    reason: .unresolvableGitAdministration, errorNumber: nil)
            }
            let isInclude = WorktreeForkConfigurationIncludes.isInclude(entry.name)
            guard entry.value.hasPrefix("/") || isInclude,
                !WorktreeForkConfigurationPatternKeys.holdsPattern(entry.name)
            else {
                continue
            }
            let target = WorktreeForkConfigurationIncludes.target(of: entry.value, includedFrom: file)
            if relocation.namesRelocatedSource(target) {
                throw .entryFailed(
                    relativePath: "\(includedBy): \(entry.name) = \(sourceRelative(target))",
                    reason: .unresolvableGitAdministration, errorNumber: nil)
            }
            if isInclude {
                includes.append(.external(target, includedBy: includedBy))
            }
        }
        return includes
    }

    private func sourceRelative(_ path: URL) -> String {
        WorktreeForkAdministrativeSymlinks.relativeComponents(of: path, beneath: plan.sourceRoot)
            ?? path.lastPathComponent
    }

    private static func ownEntries(
        of copy: WorktreeForkConfigurationCopy
    ) throws(GitWorktreeForkError) -> [WorktreeForkConfigurationEntry] {
        do {
            return try WorktreeForkConfigurationFile.ownEntries(in: copy.destination)
        } catch {
            // libgit2 refuses a file whose own includes cycle or nest too deeply; Git refuses it too.
            throw .entryFailed(relativePath: copy.reportPath, reason: .unresolvableGitAdministration, errorNumber: nil)
        }
    }
}

/// Walks the destination include closure the re-homer edited, external files included, and rejects any value
/// that still names a source location the fork relocates elsewhere, or one with no counterpart, and any value
/// naming a missing destination file whose private-administration source exists (Git would silently read
/// nothing).
struct WorktreeForkConfigurationPathValidation: Sendable {
    let plan: WorktreeForkPlan
    let relocation: WorktreeForkSourcePathRelocation

    /// `roots` are destination configuration files with their report paths.
    func validate(_ roots: [(file: URL, reportPath: String)]) throws(GitWorktreeForkError) {
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
                    let location = condition.location(includedFrom: file),
                    !WorktreeForkDestinationOwnership.isDestinationOwned(location.literal, plan: plan),
                    relocation.namesRelocatedSource(location.literal)
                {
                    throw leftover
                }
                let isInclude = WorktreeForkConfigurationIncludes.isInclude(entry.name)
                guard entry.value.hasPrefix("/") || isInclude,
                    !WorktreeForkConfigurationPatternKeys.holdsPattern(entry.name)
                else {
                    continue
                }
                let target = WorktreeForkConfigurationIncludes.target(of: entry.value, includedFrom: file)
                let destinationOwned = WorktreeForkDestinationOwnership.isDestinationOwned(target, plan: plan)
                if !destinationOwned, relocation.namesRelocatedSource(target) {
                    throw leftover
                }
                if destinationOwned, case .failure = WorktreeForkDescriptors.lstatPath(target),
                    relocation.privateAdministrationSources(ofDestination: target).contains(where: {
                        if case .success = WorktreeForkDescriptors.lstatPath($0) { true } else { false }
                    })
                {
                    throw .validationFailed(reason: .nestedRepositoryUnusable, relativePath: reportPath)
                }
                // External includes are walked too: they are never edited, so a leftover there is a leak.
                if isInclude {
                    pending.append(
                        (
                            target, WorktreeForkDestinationOwnership.reportLocation(of: target, plan: plan),
                            depth + 1
                        ))
                }
            }
        }
    }

}

extension WorktreeForkSourcePathRelocation {
    /// True when `path` is a source location the fork relocates to somewhere else, or one with no counterpart.
    func namesRelocatedSource(_ path: URL) -> Bool {
        switch counterpart(of: path) {
        case .outsideSource, .sharedRepository:
            false
        case .relocated(let destination):
            destination.path != path.path
        case .unmapped:
            true
        }
    }
}

/// The places the fork owns: its destination tree and its own linked-worktree administration.
enum WorktreeForkDestinationOwnership {
    static func isDestinationOwned(_ path: URL, plan: WorktreeForkPlan) -> Bool {
        [plan.destinationRoot, forkAdministration(plan)].contains {
            WorktreeForkAdministrativeSymlinks.relativeComponents(of: path, beneath: $0) != nil
        }
    }

    /// Destination-root-relative, or common-directory-relative for the fork's administration.
    static func reportLocation(of path: URL, plan: WorktreeForkPlan) -> String {
        WorktreeForkAdministrativeSymlinks.relativeComponents(of: path, beneath: plan.destinationRoot)
            ?? WorktreeForkAdministrativeSymlinks.relativeComponents(of: path, beneath: plan.commonDirectory)
            ?? path.lastPathComponent
    }

    private static func forkAdministration(_ plan: WorktreeForkPlan) -> URL {
        plan.commonDirectory.appending(path: "worktrees").appending(path: plan.worktreeName)
    }
}
