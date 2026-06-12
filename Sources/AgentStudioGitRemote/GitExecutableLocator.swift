import Foundation

public struct GitExecutableInvocation: Sendable {
    public let executableURL: URL
    public let leadingArguments: [String]
    public let displayName: String

    public init(executableURL: URL, leadingArguments: [String], displayName: String) {
        self.executableURL = executableURL
        self.leadingArguments = leadingArguments
        self.displayName = displayName
    }
}

public struct GitExecutableLocator: Sendable {
    private let configuredExecutableURL: URL?

    public init(configuredExecutableURL: URL? = nil) {
        self.configuredExecutableURL = configuredExecutableURL
    }

    public func invocation() -> GitExecutableInvocation {
        if let configuredExecutableURL {
            return GitExecutableInvocation(
                executableURL: configuredExecutableURL,
                leadingArguments: [],
                displayName: configuredExecutableURL.path
            )
        }

        return GitExecutableInvocation(
            executableURL: URL(fileURLWithPath: "/usr/bin/env"),
            leadingArguments: ["git"],
            displayName: "git"
        )
    }
}
