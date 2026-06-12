import AgentStudioGitContracts
import Foundation

public struct SystemGitRemoteClient: AgentStudioGitRemoteClient, Sendable {
    public struct Configuration: Sendable {
        public let executableURL: URL?
        public let inheritEnvironment: Bool
        public let promptPolicy: GitRemotePromptPolicy
        public let allowedProtocols: [GitRemoteProtocol]
        public let operationTimeoutSeconds: Double
        public let additionalEnvironment: [String: String]

        public init(
            executableURL: URL? = nil,
            inheritEnvironment: Bool = true,
            promptPolicy: GitRemotePromptPolicy = .noninteractive,
            allowedProtocols: [GitRemoteProtocol] = [.https, .ssh],
            operationTimeoutSeconds: Double = 120,
            additionalEnvironment: [String: String] = [:]
        ) {
            self.executableURL = executableURL
            self.inheritEnvironment = inheritEnvironment
            self.promptPolicy = promptPolicy
            self.allowedProtocols = allowedProtocols
            self.operationTimeoutSeconds = max(operationTimeoutSeconds, 0.001)
            self.additionalEnvironment = additionalEnvironment
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
            var environment = inheritEnvironment ? ProcessInfo.processInfo.environment : [:]
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

        private func sshBatchModeCommand(from command: String?) -> String {
            guard let command, !command.isEmpty else {
                return "ssh -oBatchMode=yes"
            }
            guard !command.contains("BatchMode") else {
                return command
            }
            return "\(command) -oBatchMode=yes"
        }
    }

    private let configuration: Configuration
    private let runner: GitProcessRunner
    private let outputParser: GitRemoteOutputParser

    public init(configuration: Configuration = .init()) {
        self.configuration = configuration
        runner = GitProcessRunner(configuration: configuration)
        outputParser = GitRemoteOutputParser()
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

    public func fetch(_ request: GitFetchRequest) async throws(GitDataPlaneError) -> GitFetchResult {
        _ = try await runner.run(arguments: [
            "-C",
            request.repositoryPath.path,
            "fetch",
            "--porcelain",
            "--",
            request.remoteName,
        ])
        return GitFetchResult(fetchedRemoteName: request.remoteName)
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

    private func validateRemoteProtocol(_ remote: String) throws(GitDataPlaneError) {
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
