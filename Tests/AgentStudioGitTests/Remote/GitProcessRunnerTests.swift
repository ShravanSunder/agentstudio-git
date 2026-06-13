import AgentStudioGit
import Darwin
import Foundation
import Testing

@Suite("Git process runner", .serialized)
struct GitProcessRunnerTests {
    @Test("default git executable lookup uses an absolute system path")
    func defaultGitExecutableLookupUsesAbsoluteSystemPath() {
        let invocation = GitExecutableLocator().invocation()

        #expect(invocation.executableURL.path == "/usr/bin/git")
        #expect(invocation.leadingArguments.isEmpty)
        #expect(invocation.displayName == "/usr/bin/git")
    }

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

    @Test("runner preserves ambient SSH command while forcing batch mode")
    func runnerPreservesAmbientSSHCommandWhileForcingBatchMode() async throws {
        setenv("GIT_SSH_COMMAND", "ssh -F /tmp/ambient-agentstudio-ssh-config -oBatchMode=no", 1)
        defer { unsetenv("GIT_SSH_COMMAND") }
        let fakeGit = try FakeGitExecutable()
        let configuration = fakeGit.configuration(inheritEnvironment: true)
        let runner = GitProcessRunner(configuration: configuration)

        _ = try await runner.run(arguments: ["status"])

        let environment = try fakeGit.recordedEnvironment()
        let sshCommand = try #require(environment["GIT_SSH_COMMAND"])
        #expect(sshCommand.contains("/tmp/ambient-agentstudio-ssh-config"))
        #expect(!sshCommand.contains("BatchMode=no"))
        #expect(sshCommand.contains("-oBatchMode=yes"))
    }

    @Test("runner preserves quoted SSH command arguments while forcing batch mode")
    func runnerPreservesQuotedSSHCommandArgumentsWhileForcingBatchMode() async throws {
        let fakeGit = try FakeGitExecutable()
        let configuration = fakeGit.configuration(
            inheritEnvironment: false,
            additionalEnvironment: [
                "GIT_SSH_COMMAND":
                    #"ssh -F "/Users/me/Library/Application Support/ssh/config" -o ProxyCommand="nc bastion 22" -oBatchMode=no"#
            ]
        )
        let runner = GitProcessRunner(configuration: configuration)

        _ = try await runner.run(arguments: ["status"])

        let environment = try fakeGit.recordedEnvironment()
        let sshCommand = try #require(environment["GIT_SSH_COMMAND"])
        #expect(sshCommand.contains(#""/Users/me/Library/Application Support/ssh/config""#))
        #expect(sshCommand.contains(#"ProxyCommand="nc bastion 22""#))
        #expect(!sshCommand.contains("BatchMode=no"))
        #expect(sshCommand.contains("-oBatchMode=yes"))
    }

    @Test("runner drops ambient Git config and transport overrides")
    func runnerDropsAmbientGitConfigAndTransportOverrides() async throws {
        let ambientOverrides = [
            "GIT_CONFIG_COUNT": "1",
            "GIT_CONFIG_KEY_0": "url.https://internal.example/.insteadOf",
            "GIT_CONFIG_VALUE_0": "https://example.com/",
            "GIT_DIR": "/tmp/ambient-agentstudio-git-dir",
            "GIT_EXEC_PATH": "/tmp/ambient-agentstudio-git-exec-path",
            "GIT_INDEX_FILE": "/tmp/ambient-agentstudio-index",
            "GIT_PROXY_COMMAND": "nc 127.0.0.1 22",
            "GIT_SSL_NO_VERIFY": "true",
            "GIT_WORK_TREE": "/tmp/ambient-agentstudio-work-tree",
        ]
        for (key, value) in ambientOverrides {
            setenv(key, value, 1)
        }
        defer {
            for key in ambientOverrides.keys {
                unsetenv(key)
            }
        }
        let fakeGit = try FakeGitExecutable()
        let configuration = fakeGit.configuration(inheritEnvironment: true)
        let runner = GitProcessRunner(configuration: configuration)

        _ = try await runner.run(arguments: ["status"])

        let environment = try fakeGit.recordedEnvironment()
        for key in ambientOverrides.keys {
            #expect(environment[key] == nil)
        }
        #expect(environment["GIT_TERMINAL_PROMPT"] == "0")
        #expect(environment["GIT_SSH_COMMAND"] == "ssh -oBatchMode=yes")
    }

    @Test("runner preserves ambient Git auth and trust establishment environment")
    func runnerPreservesAmbientGitAuthAndTrustEstablishmentEnvironment() async throws {
        let ambientAuthEnvironment = [
            "GIT_HTTP_LOW_SPEED_LIMIT": "1",
            "GIT_SSL_CAINFO": "/tmp/agentstudio-ca.pem",
            "GIT_SSL_CERT": "/tmp/agentstudio-client-cert.pem",
            "GIT_SSL_KEY": "/tmp/agentstudio-client-key.pem",
        ]
        for (key, value) in ambientAuthEnvironment {
            setenv(key, value, 1)
        }
        defer {
            for key in ambientAuthEnvironment.keys {
                unsetenv(key)
            }
        }
        let fakeGit = try FakeGitExecutable()
        let configuration = fakeGit.configuration(inheritEnvironment: true)
        let runner = GitProcessRunner(configuration: configuration)

        _ = try await runner.run(arguments: ["status"])

        let environment = try fakeGit.recordedEnvironment()
        for (key, value) in ambientAuthEnvironment {
            #expect(environment[key] == value)
        }
    }

    @Test("runner honors explicit SSH command override in noninteractive mode")
    func runnerHonorsExplicitSSHCommandOverrideInNoninteractiveMode() async throws {
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
            #expect(failure.redactedArguments.contains("<redacted-https-remote>"))
            #expect(failure.redactedStderr.contains("<redacted-https-remote>"))
            #expect(!failure.redactedStderr.contains("secret-token"))
        }
    }

    @Test("runner rejects stdout beyond the configured capture limit")
    func runnerRejectsStdoutBeyondTheConfiguredCaptureLimit() async throws {
        let fakeGit = try FakeGitExecutable()
        let configuration = fakeGit.configuration(
            capturedOutputLimitBytes: 64,
            additionalEnvironment: [
                "AGENTSTUDIO_FAKE_GIT_STDOUT_BYTES": "1048576"
            ])
        let runner = GitProcessRunner(configuration: configuration)

        do {
            _ = try await runner.run(arguments: ["ls-remote", "origin"])
            Issue.record("oversized fake git output unexpectedly succeeded")
        } catch let error {
            guard case .processOutputTooLarge(let stream, let sizeBytes, let maxSizeBytes) = error else {
                Issue.record("expected output limit failure, got \(error)")
                return
            }
            #expect(stream == .stdout)
            #expect(sizeBytes > 64)
            #expect(maxSizeBytes == 64)
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

    @Test("runner terminates process group when task is cancelled")
    func runnerTerminatesProcessGroupWhenTaskIsCancelled() async throws {
        let fakeGit = try FakeGitExecutable()
        let parentPIDURL = fakeGit.root.appending(path: "parent.pid")
        let configuration = fakeGit.configuration(
            operationTimeoutSeconds: 1,
            additionalEnvironment: [
                "AGENTSTUDIO_FAKE_GIT_PARENT_PID": parentPIDURL.path,
                "AGENTSTUDIO_FAKE_GIT_SLEEP_SECONDS": "30",
            ])
        let runner = GitProcessRunner(configuration: configuration)
        let task = Task {
            try await runner.run(arguments: ["fetch", "origin"])
        }
        let parentPID = try await waitForPID(at: parentPIDURL, timeoutSeconds: 5)
        defer { kill(parentPID, SIGKILL) }

        task.cancel()

        do {
            _ = try await task.value
            Issue.record("cancelled fake git unexpectedly succeeded")
        } catch let error as GitDataPlaneError {
            guard case .processCancelled(let failure) = error else {
                Issue.record("expected process cancellation, got \(error)")
                return
            }
            #expect(failure.redactedArguments.suffix(2) == ["fetch", "origin"])
            #expect(failure.redactedStderr.contains("cancelled"))
        }
        #expect(waitUntilProcessExits(parentPID, timeoutSeconds: 2))
    }

    @Test("runner terminates descendant processes when task is cancelled")
    func runnerTerminatesDescendantProcessesWhenTaskIsCancelled() async throws {
        let fakeGit = try FakeGitExecutable()
        let childPIDURL = fakeGit.root.appending(path: "cancel-child.pid")
        let configuration = fakeGit.configuration(
            operationTimeoutSeconds: 30,
            additionalEnvironment: [
                "AGENTSTUDIO_FAKE_GIT_CHILD_PID": childPIDURL.path,
                "AGENTSTUDIO_FAKE_GIT_CHILD_SLEEP_SECONDS": "30",
            ])
        let runner = GitProcessRunner(configuration: configuration)
        let task = Task {
            try await runner.run(arguments: ["fetch", "origin"])
        }
        let childPID = try await waitForPID(at: childPIDURL, timeoutSeconds: 5)
        defer { kill(childPID, SIGKILL) }

        task.cancel()

        do {
            _ = try await task.value
            Issue.record("cancelled fake git descendant unexpectedly succeeded")
        } catch let error as GitDataPlaneError {
            guard case .processCancelled(let failure) = error else {
                Issue.record("expected process cancellation, got \(error)")
                return
            }
            #expect(failure.redactedArguments.suffix(2) == ["fetch", "origin"])
            #expect(failure.redactedStderr.contains("cancelled"))
        }
        #expect(waitUntilProcessExits(childPID, timeoutSeconds: 2))
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

        let childPID = try await waitForPID(at: childPIDURL, timeoutSeconds: 5)
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
        if [ -n "${AGENTSTUDIO_FAKE_GIT_PARENT_PID:-}" ]; then
          printf '%s\\n' "$$" > "$AGENTSTUDIO_FAKE_GIT_PARENT_PID"
        fi
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
        if [ -n "${AGENTSTUDIO_FAKE_GIT_STDOUT_BYTES:-}" ]; then
          count=0
          while [ "$count" -lt "$AGENTSTUDIO_FAKE_GIT_STDOUT_BYTES" ]; do
            printf x
            count=$((count + 1))
          done
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
        operationTimeoutSeconds: Double = 10,
        capturedOutputLimitBytes: Int64 = 1_048_576,
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
            capturedOutputLimitBytes: capturedOutputLimitBytes,
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

private func waitForPID(at url: URL, timeoutSeconds: Double) async throws -> pid_t {
    let deadline = Date().addingTimeInterval(timeoutSeconds)
    while Date() < deadline {
        if let pid = try readPIDIfPresent(at: url) {
            return pid
        }
        try await Task.sleep(nanoseconds: 20_000_000)
    }
    return try #require(try readPIDIfPresent(at: url))
}

private func readPIDIfPresent(at url: URL) throws -> pid_t? {
    guard FileManager.default.fileExists(atPath: url.path) else {
        return nil
    }
    let pidText = try String(contentsOf: url, encoding: .utf8)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    guard !pidText.isEmpty else {
        return nil
    }
    return pid_t(pidText)
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
