import AgentStudioGit
import Foundation
import Testing

@Suite("Git process runner")
struct GitProcessRunnerTests {
    @Test("runner applies scrubbed prompt environment and captures output")
    func runnerAppliesScrubbedPromptEnvironmentAndCapturesOutput() async throws {
        let fakeGit = try FakeGitExecutable()
        let configuration = fakeGit.configuration(
            inheritEnvironment: false,
            additionalEnvironment: [
                "GIT_TRACE": "1",
                "GIT_CURL_VERBOSE": "1",
                "AGENTSTUDIO_FAKE_GIT_STDOUT": "ok\n",
            ]
        )
        let runner = GitProcessRunner(configuration: configuration)

        let result = try await runner.run(arguments: ["status"])

        #expect(result.stdout == "ok\n")
        let environment = try fakeGit.recordedEnvironment()
        #expect(environment["GIT_TERMINAL_PROMPT"] == "0")
        #expect(environment["LC_ALL"] == "C")
        #expect(environment["GIT_TRACE"] == nil)
        #expect(environment["GIT_CURL_VERBOSE"] == nil)
    }

    @Test("runner allows trusted interactive prompt opt-in")
    func runnerAllowsTrustedInteractivePromptOptIn() async throws {
        let fakeGit = try FakeGitExecutable()
        let configuration = fakeGit.configuration(promptPolicy: .trustedInteractive)
        let runner = GitProcessRunner(configuration: configuration)

        _ = try await runner.run(arguments: ["status"])

        let environment = try fakeGit.recordedEnvironment()
        #expect(environment["GIT_TERMINAL_PROMPT"] == "1")
    }

    @Test("runner redacts process failures")
    func runnerRedactsProcessFailures() async throws {
        let fakeGit = try FakeGitExecutable()
        let configuration = fakeGit.configuration(
            additionalEnvironment: [
                "AGENTSTUDIO_FAKE_GIT_STDERR":
                    "fatal: https://user:secret-token@example.com/org/repo.git failed\n",
                "AGENTSTUDIO_FAKE_GIT_EXIT": "128",
            ])
        let runner = GitProcessRunner(configuration: configuration)

        do {
            _ = try await runner.run(arguments: ["clone", "https://user:secret-token@example.com/org/repo.git"])
            Issue.record("failing fake git unexpectedly succeeded")
        } catch let error {
            guard case .processFailed(let failure) = error else {
                Issue.record("expected process failure, got \(error)")
                return
            }
            #expect(failure.exitCode == 128)
            #expect(failure.redactedArguments.contains("https://<redacted>@example.com/org/repo.git"))
            #expect(failure.redactedStderr.contains("https://<redacted>@example.com/org/repo.git"))
            #expect(!failure.redactedStderr.contains("secret-token"))
        }
    }
}

struct FakeGitExecutable {
    private let fileManager = FileManager.default
    let root: URL
    let executableURL: URL
    let argumentsURL: URL
    let environmentURL: URL

    init() throws {
        root = fileManager.temporaryDirectory.appending(path: "agentstudio-git-fake-git-\(UUID().uuidString)")
        executableURL = root.appending(path: "git")
        argumentsURL = root.appending(path: "arguments.txt")
        environmentURL = root.appending(path: "environment.txt")
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        try """
        #!/bin/sh
        {
          echo BEGIN
          for argument in "$@"; do
            printf '%s\\n' "$argument"
          done
          echo END
        } >> "$AGENTSTUDIO_FAKE_GIT_ARGUMENTS"
        env | sort > "$AGENTSTUDIO_FAKE_GIT_ENVIRONMENT"
        if [ -n "${AGENTSTUDIO_FAKE_GIT_STDOUT:-}" ]; then
          printf '%s' "$AGENTSTUDIO_FAKE_GIT_STDOUT"
        fi
        if [ -n "${AGENTSTUDIO_FAKE_GIT_STDERR:-}" ]; then
          printf '%s' "$AGENTSTUDIO_FAKE_GIT_STDERR" >&2
        fi
        exit "${AGENTSTUDIO_FAKE_GIT_EXIT:-0}"
        """
        .write(to: executableURL, atomically: true, encoding: .utf8)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executableURL.path)
    }

    func configuration(
        promptPolicy: GitRemotePromptPolicy = .noninteractive,
        inheritEnvironment: Bool = false,
        allowedProtocols: [GitRemoteProtocol] = [.https, .ssh],
        additionalEnvironment: [String: String] = [:]
    ) -> SystemGitRemoteClient.Configuration {
        var environment = additionalEnvironment
        environment["AGENTSTUDIO_FAKE_GIT_ARGUMENTS"] = argumentsURL.path
        environment["AGENTSTUDIO_FAKE_GIT_ENVIRONMENT"] = environmentURL.path
        return SystemGitRemoteClient.Configuration(
            executableURL: executableURL,
            inheritEnvironment: inheritEnvironment,
            promptPolicy: promptPolicy,
            allowedProtocols: allowedProtocols,
            additionalEnvironment: environment
        )
    }

    func recordedInvocations() throws -> [[String]] {
        guard fileManager.fileExists(atPath: argumentsURL.path) else {
            return []
        }
        let lines = try String(contentsOf: argumentsURL, encoding: .utf8).split(separator: "\n")
        var invocations: [[String]] = []
        var current: [String] = []
        for line in lines {
            switch line {
            case "BEGIN":
                current = []
            case "END":
                invocations.append(current)
            default:
                current.append(String(line))
            }
        }
        return invocations
    }

    func recordedEnvironment() throws -> [String: String] {
        guard fileManager.fileExists(atPath: environmentURL.path) else {
            return [:]
        }
        let lines = try String(contentsOf: environmentURL, encoding: .utf8).split(separator: "\n")
        return Dictionary(
            uniqueKeysWithValues: lines.compactMap { line in
                let parts = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                guard parts.count == 2 else {
                    return nil
                }
                return (String(parts[0]), String(parts[1]))
            })
    }
}
