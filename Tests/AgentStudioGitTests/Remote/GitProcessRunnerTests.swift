import AgentStudioGit
import Darwin
import Foundation
import Testing

@Suite("Git process runner", .serialized)
struct GitProcessRunnerTests {
    @Test("runner applies scrubbed prompt environment and captures output")
    func runnerAppliesScrubbedPromptEnvironmentAndCapturesOutput() async throws {
        let fakeGit = try FakeGitExecutable()
        let configuration = fakeGit.configuration(
            inheritEnvironment: false,
            additionalEnvironment: [
                "GIT_ASKPASS": "/tmp/agentstudio-askpass",
                "GIT_TRACE": "1",
                "GIT_CURL_VERBOSE": "1",
                "GIT_SSH_COMMAND": "ssh -F /tmp/agentstudio-ssh-config",
                "SSH_ASKPASS": "/tmp/agentstudio-ssh-askpass",
                "SSH_ASKPASS_REQUIRE": "force",
                "AGENTSTUDIO_FAKE_GIT_STDOUT": "ok\n",
            ]
        )
        let runner = GitProcessRunner(configuration: configuration)

        let result = try await runner.run(arguments: ["status"])

        #expect(result.stdout == "ok\n")
        let environment = try fakeGit.recordedEnvironment()
        #expect(environment["GIT_TERMINAL_PROMPT"] == "0")
        #expect(environment["LC_ALL"] == "C")
        #expect(environment["GIT_ASKPASS"] == nil)
        #expect(environment["GIT_TRACE"] == nil)
        #expect(environment["GIT_CURL_VERBOSE"] == nil)
        #expect(environment["SSH_ASKPASS"] == nil)
        #expect(environment["SSH_ASKPASS_REQUIRE"] == nil)
        #expect(environment["GIT_SSH_COMMAND"]?.contains("-oBatchMode=yes") == true)
        #expect(environment["GIT_SSH_COMMAND"]?.contains("/tmp/agentstudio-ssh-config") == true)
        let invocation = try #require(fakeGit.recordedInvocations().first)
        #expect(invocation.contains("core.askPass="))
    }

    @Test("runner overrides inherited SSH BatchMode no in noninteractive mode")
    func runnerOverridesInheritedSSHBatchModeNoInNoninteractiveMode() async throws {
        let fakeGit = try FakeGitExecutable()
        let configuration = fakeGit.configuration(
            inheritEnvironment: false,
            additionalEnvironment: [
                "GIT_SSH_COMMAND": "ssh -F /tmp/agentstudio-ssh-config -oBatchMode=no"
            ]
        )
        let runner = GitProcessRunner(configuration: configuration)

        _ = try await runner.run(arguments: ["status"])

        let environment = try fakeGit.recordedEnvironment()
        let sshCommand = try #require(environment["GIT_SSH_COMMAND"])
        #expect(!sshCommand.contains("BatchMode=no"))
        #expect(sshCommand.contains("-oBatchMode=yes"))
        #expect(sshCommand.contains("/tmp/agentstudio-ssh-config"))
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

    @Test("runner terminates processes that exceed the configured timeout")
    func runnerTerminatesProcessesThatExceedTheConfiguredTimeout() async throws {
        let fakeGit = try FakeGitExecutable()
        let configuration = fakeGit.configuration(
            operationTimeoutSeconds: 0.1,
            additionalEnvironment: [
                "AGENTSTUDIO_FAKE_GIT_SLEEP_SECONDS": "5"
            ])
        let runner = GitProcessRunner(configuration: configuration)

        do {
            _ = try await runner.run(arguments: ["fetch", "origin"])
            Issue.record("sleeping fake git unexpectedly succeeded")
        } catch let error {
            guard case .processTimedOut(let failure) = error else {
                Issue.record("expected process timeout, got \(error)")
                return
            }
            #expect(failure.redactedArguments.suffix(2) == ["fetch", "origin"])
            #expect(failure.redactedStderr.contains("timed out after 0.1 seconds"))
        }
    }

    @Test("runner terminates descendant processes after timeout")
    func runnerTerminatesDescendantProcessesAfterTimeout() async throws {
        let fakeGit = try FakeGitExecutable()
        let childPIDURL = fakeGit.root.appending(path: "child.pid")
        let configuration = fakeGit.configuration(
            operationTimeoutSeconds: 1,
            additionalEnvironment: [
                "AGENTSTUDIO_FAKE_GIT_CHILD_PID": childPIDURL.path,
                "AGENTSTUDIO_FAKE_GIT_CHILD_SLEEP_SECONDS": "30",
            ])
        let runner = GitProcessRunner(configuration: configuration)

        do {
            _ = try await runner.run(arguments: ["fetch", "origin"])
            Issue.record("descendant fake git unexpectedly succeeded")
        } catch let error {
            guard case .processTimedOut = error else {
                Issue.record("expected process timeout, got \(error)")
                return
            }
        }

        let pidText = try String(contentsOf: childPIDURL, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let childPID = try #require(pid_t(pidText))
        defer { kill(childPID, SIGKILL) }
        #expect(waitUntilProcessExits(childPID, timeoutSeconds: 2))
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
        if [ -n "${AGENTSTUDIO_FAKE_GIT_CHILD_PID:-}" ]; then
          (trap '' TERM HUP; sleep "${AGENTSTUDIO_FAKE_GIT_CHILD_SLEEP_SECONDS:-30}") &
          child_pid="$!"
          printf '%s\\n' "$child_pid" > "$AGENTSTUDIO_FAKE_GIT_CHILD_PID"
          trap 'exit 143' TERM HUP
          wait "$child_pid"
        fi
        if [ -n "${AGENTSTUDIO_FAKE_GIT_SLEEP_SECONDS:-}" ]; then
          sleep "$AGENTSTUDIO_FAKE_GIT_SLEEP_SECONDS"
        fi
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
        operationTimeoutSeconds: Double = 2,
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
            operationTimeoutSeconds: operationTimeoutSeconds,
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

private func processIsRunning(_ pid: pid_t) -> Bool {
    kill(pid, 0) == 0 || errno == EPERM
}

private func waitUntilProcessExits(_ pid: pid_t, timeoutSeconds: Double) -> Bool {
    let deadline = Date().addingTimeInterval(timeoutSeconds)
    while Date() < deadline {
        if !processIsRunning(pid) {
            return true
        }
        usleep(20_000)
    }
    return !processIsRunning(pid)
}
