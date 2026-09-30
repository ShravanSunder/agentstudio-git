import AgentStudioGitContracts
import CLibGit2Local
import Darwin
import Foundation

struct LibGit2BranchMetadataCleaner: Sendable {
    func clean(
        branchName: String,
        referenceName: String,
        repository: OpaquePointer
    ) -> GitBranchMetadataCleanup {
        GitBranchMetadataCleanup(
            configuration: removeBranchConfiguration(named: branchName, repository: repository),
            reflog: removeBranchReflog(named: referenceName, repository: repository)
        )
    }

    private func removeBranchConfiguration(
        named branchName: String,
        repository: OpaquePointer
    ) -> GitBranchMetadataDisposition {
        var repositoryConfiguration: OpaquePointer?
        let repositoryConfigurationResult = git_repository_config(&repositoryConfiguration, repository)
        guard repositoryConfigurationResult >= 0, let repositoryConfiguration else {
            return .leftInPlace(.removalFailed)
        }
        defer { git_config_free(repositoryConfiguration) }

        var localConfiguration: OpaquePointer?
        let localConfigurationResult = git_config_open_level(
            &localConfiguration,
            repositoryConfiguration,
            GIT_CONFIG_LEVEL_LOCAL
        )
        if localConfigurationResult == GIT_ENOTFOUND.rawValue {
            return .absent
        }
        guard localConfigurationResult >= 0, let localConfiguration else {
            return .leftInPlace(.removalFailed)
        }
        defer { git_config_free(localConfiguration) }

        var configurationTransaction: OpaquePointer?
        errno = 0
        let lockResult = git_config_lock(&configurationTransaction, localConfiguration)
        guard lockResult >= 0, let configurationTransaction else {
            return .leftInPlace(.removalFailed)
        }
        defer { git_transaction_free(configurationTransaction) }

        let entryNames: [String]
        do {
            entryNames = try branchConfigurationEntryNames(
                in: localConfiguration,
                branchName: branchName
            )
        } catch {
            return .leftInPlace(.removalFailed)
        }
        guard !entryNames.isEmpty else {
            return .absent
        }

        for entryName in entryNames {
            let deleteResult = entryName.withCString { git_config_delete_entry(localConfiguration, $0) }
            guard deleteResult >= 0 else {
                return .leftInPlace(.removalFailed)
            }
        }

        let commitResult = git_transaction_commit(configurationTransaction)
        guard commitResult >= 0 else {
            return .leftInPlace(.removalFailed)
        }
        return .removed
    }

    private func branchConfigurationEntryNames(
        in configuration: OpaquePointer,
        branchName: String
    ) throws(GitDataPlaneError) -> [String] {
        var iterator: OpaquePointer?
        let iteratorResult = git_config_iterator_new(&iterator, configuration)
        guard iteratorResult >= 0, let iterator else {
            throw LibGit2ErrorCapture.failure(code: iteratorResult)
        }
        defer { git_config_iterator_free(iterator) }

        var matchingEntryNames = Set<String>()
        while true {
            var entry: UnsafeMutablePointer<git_config_entry>?
            let nextResult = git_config_next(&entry, iterator)
            if nextResult == GIT_ITEROVER.rawValue {
                break
            }
            guard nextResult >= 0, let entry else {
                throw LibGit2ErrorCapture.failure(code: nextResult)
            }
            guard let namePointer = entry.pointee.name else {
                continue
            }
            let name = String(cString: namePointer)
            if belongsToBranchConfigurationSection(name, branchName: branchName) {
                matchingEntryNames.insert(name)
            }
        }
        return matchingEntryNames.sorted()
    }

    private func belongsToBranchConfigurationSection(_ entryName: String, branchName: String) -> Bool {
        let components = entryName.split(separator: ".", omittingEmptySubsequences: false)
        guard components.count >= 3, components.first == "branch" else {
            return false
        }
        let subsection = components.dropFirst().dropLast().joined(separator: ".")
        return subsection == branchName
    }

    private func removeBranchReflog(
        named referenceName: String,
        repository: OpaquePointer
    ) -> GitBranchMetadataDisposition {
        guard let reflogPath = reflogFilePath(referenceName: referenceName, repository: repository) else {
            return .leftInPlace(.removalFailed)
        }
        switch pathStatus(reflogPath) {
        case .absent:
            return .absent
        case .inaccessible:
            return .leftInPlace(.removalFailed)
        case .directory:
            return .absent
        case .file:
            break
        }

        let deleteResult = referenceName.withCString { git_reflog_delete(repository, $0) }
        guard deleteResult >= 0 else {
            return .leftInPlace(.removalFailed)
        }
        return pathStatus(reflogPath) == .absent ? .removed : .leftInPlace(.removalFailed)
    }

    private func reflogFilePath(referenceName: String, repository: OpaquePointer) -> URL? {
        var pathBuffer = git_buf()
        defer { git_buf_dispose(&pathBuffer) }

        let pathResult = git_repository_item_path(&pathBuffer, repository, GIT_REPOSITORY_ITEM_LOGS)
        guard pathResult >= 0, let pathPointer = pathBuffer.ptr else {
            return nil
        }
        return URL(fileURLWithPath: String(cString: pathPointer), isDirectory: true)
            .appending(path: referenceName)
            .standardizedFileURL
    }

    private func pathStatus(_ path: URL) -> ReflogPathStatus {
        var fileStatus = stat()
        let statResult = path.path.withCString { lstat($0, &fileStatus) }
        guard statResult == 0 else {
            return errno == ENOENT || errno == ENOTDIR ? .absent : .inaccessible
        }
        if (fileStatus.st_mode & S_IFMT) == S_IFDIR {
            return .directory
        }
        return .file
    }
}

private enum ReflogPathStatus: Equatable {
    case absent
    case directory
    case file
    case inaccessible
}
