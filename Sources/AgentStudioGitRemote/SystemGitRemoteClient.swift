import AgentStudioGitContracts
import AgentStudioGitLockSupport
import CLibGit2Local
import Foundation

public struct SystemGitRemoteClient: AgentStudioGitRemoteClient, Sendable {
    public struct Configuration: Sendable {
        public let executableURL: URL?
        public let inheritEnvironment: Bool
        public let promptPolicy: GitRemotePromptPolicy
        public let allowedProtocols: [GitRemoteProtocol]
        public let operationTimeoutSeconds: Double
        public let capturedOutputLimitBytes: Int64
        public let additionalEnvironment: [String: String]
        package let inheritedEnvironment: [String: String]?

        public init(
            executableURL: URL? = nil,
            inheritEnvironment: Bool = true,
            promptPolicy: GitRemotePromptPolicy = .noninteractive,
            allowedProtocols: [GitRemoteProtocol] = [.https, .ssh],
            operationTimeoutSeconds: Double = 120,
            capturedOutputLimitBytes: Int64 = 1_048_576,
            additionalEnvironment: [String: String] = [:]
        ) {
            self.init(
                executableURL: executableURL,
                inheritEnvironment: inheritEnvironment,
                promptPolicy: promptPolicy,
                allowedProtocols: allowedProtocols,
                operationTimeoutSeconds: operationTimeoutSeconds,
                capturedOutputLimitBytes: capturedOutputLimitBytes,
                additionalEnvironment: additionalEnvironment,
                inheritedEnvironment: nil
            )
        }

        package init(
            executableURL: URL? = nil,
            inheritEnvironment: Bool = true,
            promptPolicy: GitRemotePromptPolicy = .noninteractive,
            allowedProtocols: [GitRemoteProtocol] = [.https, .ssh],
            operationTimeoutSeconds: Double = 120,
            capturedOutputLimitBytes: Int64 = 1_048_576,
            additionalEnvironment: [String: String] = [:],
            inheritedEnvironment: [String: String]?
        ) {
            self.executableURL = executableURL
            self.inheritEnvironment = inheritEnvironment
            self.promptPolicy = promptPolicy
            self.allowedProtocols = allowedProtocols
            self.operationTimeoutSeconds = max(operationTimeoutSeconds, 0.001)
            self.capturedOutputLimitBytes = max(capturedOutputLimitBytes, 1)
            self.additionalEnvironment = additionalEnvironment
            self.inheritedEnvironment = inheritedEnvironment
        }

        func protocolConfigArguments() -> [String] {
            var arguments = ["-c", "protocol.allow=never"]
            if promptPolicy == .noninteractive {
                arguments.append(contentsOf: ["-c", "core.askPass="])
            }
            for allowedProtocol in allowedProtocols {
                arguments.append(contentsOf: [
                    "-c",
                    "protocol.\(allowedProtocol.rawValue).allow=always",
                ])
            }
            return arguments
        }

        func processEnvironment() -> [String: String] {
            var environment =
                inheritEnvironment
                ? (inheritedEnvironment ?? ProcessInfo.processInfo.environment)
                : [:]
            if inheritEnvironment {
                Self.removeUnsafeInheritedGitEnvironmentOverrides(from: &environment)
            }
            environment.merge(additionalEnvironment) { _, newValue in newValue }
            for key in environment.keys where key.hasPrefix("GIT_TRACE") || key == "GIT_CURL_VERBOSE" {
                environment.removeValue(forKey: key)
            }
            environment["LC_ALL"] = "C"
            switch promptPolicy {
            case .noninteractive:
                environment["GIT_TERMINAL_PROMPT"] = "0"
                environment.removeValue(forKey: "GIT_ASKPASS")
                environment.removeValue(forKey: "SSH_ASKPASS")
                environment.removeValue(forKey: "SSH_ASKPASS_REQUIRE")
                environment["GIT_SSH_COMMAND"] = sshBatchModeCommand(from: environment["GIT_SSH_COMMAND"])
            case .trustedInteractive:
                environment["GIT_TERMINAL_PROMPT"] = "1"
            }
            return environment
        }

        private static func removeUnsafeInheritedGitEnvironmentOverrides(from environment: inout [String: String]) {
            for key in environment.keys where isUnsafeInheritedGitEnvironmentOverride(key) {
                environment.removeValue(forKey: key)
            }
        }

        private static func isUnsafeInheritedGitEnvironmentOverride(_ key: String) -> Bool {
            if key.hasPrefix("GIT_CONFIG") {
                return true
            }
            switch key {
            case "GIT_ALTERNATE_OBJECT_DIRECTORIES",
                "GIT_COMMON_DIR",
                "GIT_DIR",
                "GIT_EXEC_PATH",
                "GIT_INDEX_FILE",
                "GIT_OBJECT_DIRECTORY",
                "GIT_PROXY_COMMAND",
                "GIT_SSL_NO_VERIFY",
                "GIT_WORK_TREE":
                return true
            default:
                return false
            }
        }

        private func sshBatchModeCommand(from command: String?) -> String {
            guard let command, !command.isEmpty else {
                return "ssh -oBatchMode=yes"
            }
            let sanitizedCommand = removingBatchModeOptions(from: command)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !sanitizedCommand.isEmpty else {
                return "ssh -oBatchMode=yes"
            }
            return "\(sanitizedCommand) -oBatchMode=yes"
        }

        private func removingBatchModeOptions(from command: String) -> String {
            let patterns = [
                #"(?i)(^|\s)-o\s*BatchMode\s*=\s*(?:yes|no|ask)(?=\s|$)"#,
                #"(?i)(^|\s)-oBatchMode\s*=\s*(?:yes|no|ask)(?=\s|$)"#,
                #"(?i)(^|\s)-o\s+BatchMode\s+(?:yes|no|ask)(?=\s|$)"#,
            ]
            return patterns.reduce(command) { currentCommand, pattern in
                replacingMatches(in: currentCommand, pattern: pattern, template: "$1")
            }
        }

        private func replacingMatches(in value: String, pattern: String, template: String) -> String {
            guard let expression = try? NSRegularExpression(pattern: pattern) else {
                return value
            }
            let range = NSRange(value.startIndex..<value.endIndex, in: value)
            return expression.stringByReplacingMatches(
                in: value,
                options: [],
                range: range,
                withTemplate: template
            )
        }
    }

    let configuration: Configuration
    let runner: GitProcessRunner
    private let outputParser: GitRemoteOutputParser
    private let lockResidueObserver: GitLockResidueObserver

    public init(configuration: Configuration = .init()) {
        self.configuration = configuration
        runner = GitProcessRunner(configuration: configuration)
        outputParser = GitRemoteOutputParser()
        lockResidueObserver = .live
    }

    public func clone(_ request: GitCloneRequest) async throws(GitDataPlaneError) -> GitCloneResult {
        try validateRemoteProtocol(request.remoteURL)
        var arguments = ["clone"]
        if let checkoutBranch = request.checkoutBranch {
            arguments.append(contentsOf: ["--branch", checkoutBranch])
        }
        arguments.append(contentsOf: ["--", request.remoteURL, request.destinationPath.path])
        _ = try await runner.run(arguments: arguments)
        return GitCloneResult(repositoryPath: request.destinationPath)
    }

    public func fetch(_ request: GitFetchRequest)
        async throws(GitLockedOperationFailure<GitDataPlaneError>) -> GitFetchResult
    {
        let fetchTarget: GitFetchTarget?
        do throws(GitDataPlaneError) {
            fetchTarget = try validatedFetchTarget(for: request)
        } catch {
            throw GitLockedOperationFailure(reason: error, lockResidue: [])
        }

        let lockContext: GitFetchLockContext
        if let fetchTarget {
            do throws(GitDataPlaneError) {
                lockContext = try await fetchLockContext(for: request, target: fetchTarget)
            } catch {
                throw GitLockedOperationFailure(reason: error, lockResidue: [])
            }
        } else {
            lockContext = .unobserved
        }

        var arguments = ["-C", request.repositoryPath.path, "fetch", "--porcelain"]
        if let fetchTarget {
            arguments.append(contentsOf: [
                "--no-tags",
                "--no-prune",
                "--no-prune-tags",
                "--no-recurse-submodules",
                "--refmap=",
                "--",
                request.remoteName,
                fetchTarget.refspec,
            ])
        } else {
            arguments.append(contentsOf: ["--", request.remoteName])
        }

        do throws(GitDataPlaneError) {
            _ = try await runner.run(
                arguments: arguments,
                lockClassificationRepositoryPath: request.repositoryPath
            )
            let fetchedCommit: String?
            if let fetchTarget {
                fetchedCommit = try await resolvedFetchedCommit(
                    for: fetchTarget,
                    repositoryPath: request.repositoryPath
                )
            } else {
                fetchedCommit = nil
            }

            return GitFetchResult(
                fetchedRemoteName: request.remoteName,
                fetchedCommit: fetchedCommit,
                lockResidue: lockContext.residue(using: lockResidueObserver)
            )
        } catch {
            throw GitLockedOperationFailure(
                reason: error,
                lockResidue: lockContext.residue(using: lockResidueObserver)
            )
        }
    }

    public func push(_ request: GitPushRequest) async throws(GitDataPlaneError) -> GitPushResult {
        _ = try await runner.run(arguments: [
            "-C",
            request.repositoryPath.path,
            "push",
            "--porcelain",
            "--",
            request.remoteName,
            request.refspec,
        ])
        return GitPushResult(pushedRefspec: request.refspec)
    }

    public func remoteReferences(_ request: GitRemoteReferencesRequest) async throws(GitDataPlaneError)
        -> [GitRemoteReference]
    {
        try validateRemoteProtocol(request.remoteURL)
        let result = try await runner.run(arguments: ["ls-remote", "--symref", request.remoteURL])
        return try outputParser.parse(result.stdout)
    }

    private func validatedFetchTarget(for request: GitFetchRequest) throws(GitDataPlaneError) -> GitFetchTarget? {
        guard let branchName = request.branchName else {
            return nil
        }

        let initializationResult = git_libgit2_init()
        guard initializationResult >= 0 else {
            throw .unsupported(message: "could not initialize fetch reference validation")
        }
        defer { _ = git_libgit2_shutdown() }

        let sourceReferenceName = "refs/heads/\(branchName)"
        guard try isValidReferenceName(sourceReferenceName) else {
            throw .unsupported(message: "fetch branch name is invalid")
        }

        let trackingReferenceName = "refs/remotes/\(request.remoteName)/\(branchName)"
        guard try isValidReferenceName(trackingReferenceName) else {
            throw .unsupported(message: "fetch remote-tracking reference name is invalid")
        }

        return GitFetchTarget(
            sourceReferenceName: sourceReferenceName,
            trackingReferenceName: trackingReferenceName
        )
    }

    private func fetchLockContext(
        for request: GitFetchRequest,
        target: GitFetchTarget
    ) async throws(GitDataPlaneError) -> GitFetchLockContext {
        let pathsResult = try await runner.run(arguments: [
            "-C",
            request.repositoryPath.path,
            "rev-parse",
            "--path-format=absolute",
            "--git-dir",
            "--git-common-dir",
        ])
        let paths = pathsResult.stdout.split(whereSeparator: \.isNewline)
        guard paths.count == 2 else {
            throw .unsupported(message: "fetch lock paths could not be resolved")
        }

        let gitDirectory = URL(fileURLWithPath: String(paths[0]), isDirectory: true)
        let commonDirectory = URL(fileURLWithPath: String(paths[1]), isDirectory: true)
        let possibleLockPaths = [
            commonDirectory.appending(path: "\(target.trackingReferenceName).lock"),
            commonDirectory.appending(path: "packed-refs.lock"),
            gitDirectory.appending(path: "FETCH_HEAD.lock"),
        ]
        let preexistingLockPaths = Set(
            possibleLockPaths.filter { lockResidueObserver.status(of: $0) != .absent }
        )
        return .observed(
            possibleLockPaths: possibleLockPaths,
            preexistingLockPaths: preexistingLockPaths
        )
    }

    private func resolvedFetchedCommit(for target: GitFetchTarget, repositoryPath: URL) async throws(GitDataPlaneError)
        -> String
    {
        let result = try await runner.run(arguments: [
            "-C",
            repositoryPath.path,
            "rev-parse",
            "--verify",
            "--end-of-options",
            "\(target.trackingReferenceName)^{commit}",
        ])
        let objectID = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isValidObjectID(objectID) else {
            throw .unsupported(message: "fetch resolved an invalid object identifier")
        }
        return objectID
    }

    func validateRemoteProtocol(_ remote: String) throws(GitDataPlaneError) {
        guard !remote.hasPrefix("-") else {
            throw .unsupported(message: "remote must not start with '-'")
        }
        guard let remoteProtocol = GitRemoteProtocol(remote: remote) else {
            throw .unsupported(message: "could not determine remote protocol")
        }
        guard configuration.allowedProtocols.contains(remoteProtocol) else {
            throw .unsupported(message: "protocol \(remoteProtocol.rawValue) is not allowed")
        }
    }

}

private struct GitFetchTarget: Sendable {
    let sourceReferenceName: String
    let trackingReferenceName: String

    var refspec: String {
        "+\(sourceReferenceName):\(trackingReferenceName)"
    }
}

private enum GitFetchLockContext: Sendable {
    case unobserved
    case observed(possibleLockPaths: [URL], preexistingLockPaths: Set<URL>)

    func residue(using observer: GitLockResidueObserver) -> [URL]? {
        switch self {
        case .unobserved:
            return nil
        case .observed(let possibleLockPaths, let preexistingLockPaths):
            return possibleLockPaths.filter { path in
                !preexistingLockPaths.contains(path) && observer.status(of: path) != .absent
            }
        }
    }
}

private func isValidReferenceName(_ referenceName: String) throws(GitDataPlaneError) -> Bool {
    guard !referenceName.utf8.contains(0) else {
        return false
    }
    var isValid: Int32 = 0
    let result = referenceName.withCString { git_reference_name_is_valid(&isValid, $0) }
    guard result >= 0 else {
        throw .unsupported(message: "fetch reference name validation failed")
    }
    return isValid != 0
}

private func isValidObjectID(_ objectID: String) -> Bool {
    !objectID.isEmpty
        && objectID.utf8.allSatisfy { byte in
            (byte >= 48 && byte <= 57) || (byte >= 65 && byte <= 70) || (byte >= 97 && byte <= 102)
        }
}

extension GitRemoteProtocol {
    init?(remote: String) {
        let lowercasedRemote = remote.lowercased()
        if let schemeSeparator = lowercasedRemote.range(of: "://") {
            let scheme = String(lowercasedRemote[..<schemeSeparator.lowerBound])
            self.init(rawValue: scheme)
            return
        }

        if remote.hasPrefix("/") || remote.hasPrefix("./") || remote.hasPrefix("../") || remote.hasPrefix("~") {
            self = .file
            return
        }

        if let colonIndex = remote.firstIndex(of: ":") {
            let prefix = remote[..<colonIndex]
            if !prefix.contains("/") {
                self = .ssh
                return
            }
        }

        return nil
    }
}
