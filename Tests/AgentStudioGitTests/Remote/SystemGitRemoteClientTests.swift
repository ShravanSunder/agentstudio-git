import AgentStudioGit
import Foundation
import Testing

@Suite("System Git remote client")
struct SystemGitRemoteClientTests {
    @Test("clone fetch push and ls-remote use trusted system git arguments")
    func cloneFetchPushAndLsRemoteUseTrustedSystemGitArguments() async throws {
        let fakeGit = try FakeGitExecutable()
        let repositoryPath = fakeGit.root.appending(path: "repo")
        let destinationPath = fakeGit.root.appending(path: "checkout")
        let client = SystemGitRemoteClient(configuration: fakeGit.configuration())

        _ = try await client.clone(
            GitCloneRequest(
                remoteURL: "https://example.com/org/repo.git",
                destinationPath: destinationPath,
                checkoutBranch: "main"
            ))
        _ = try await client.fetch(GitFetchRequest(repositoryPath: repositoryPath, remoteName: "origin"))
        _ = try await client.push(
            GitPushRequest(repositoryPath: repositoryPath, remoteName: "origin", refspec: "HEAD:refs/heads/main"))
        _ = try await client.remoteReferences(
            GitRemoteReferencesRequest(remoteURL: "git@github.com:org/repo.git"))

        let invocations = try fakeGit.recordedInvocations()
        #expect(invocations.count == 4)
        #expect(
            invocations[0].suffix(6) == [
                "clone", "--branch", "main", "--", "https://example.com/org/repo.git", destinationPath.path,
            ])
        #expect(invocations[1].suffix(4) == ["fetch", "--porcelain", "--", "origin"])
        #expect(invocations[1].contains(repositoryPath.path))
        #expect(invocations[2].suffix(5) == ["push", "--porcelain", "--", "origin", "HEAD:refs/heads/main"])
        #expect(invocations[2].contains(repositoryPath.path))
        #expect(invocations[3].suffix(3) == ["ls-remote", "--symref", "git@github.com:org/repo.git"])
        for invocation in invocations {
            #expect(invocation.contains("protocol.allow=never"))
            #expect(invocation.contains("protocol.https.allow=always"))
            #expect(invocation.contains("protocol.ssh.allow=always"))
        }
    }

    @Test("remote references parse fake git output")
    func remoteReferencesParseFakeGitOutput() async throws {
        let fakeGit = try FakeGitExecutable()
        let client = SystemGitRemoteClient(
            configuration: fakeGit.configuration(
                additionalEnvironment: [
                    "AGENTSTUDIO_FAKE_GIT_STDOUT":
                        """
                    ref: refs/heads/main\tHEAD
                    aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\tHEAD
                    bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\trefs/heads/main
                    cccccccccccccccccccccccccccccccccccccccc\trefs/tags/v1
                    dddddddddddddddddddddddddddddddddddddddd\trefs/tags/v1^{}

                    """
                ]))

        let references = try await client.remoteReferences(
            GitRemoteReferencesRequest(remoteURL: "https://example.com/org/repo.git"))

        #expect(references.first { $0.name == "HEAD" }?.symrefTarget == "refs/heads/main")
        #expect(references.first { $0.name == "refs/tags/v1" }?.peeledOID == "dddddddddddddddddddddddddddddddddddddddd")
    }

    @Test("remote URL protocol allowlist rejects untrusted protocols before process launch")
    func remoteURLProtocolAllowlistRejectsUntrustedProtocolsBeforeProcessLaunch() async throws {
        let fakeGit = try FakeGitExecutable()
        let client = SystemGitRemoteClient(
            configuration: fakeGit.configuration(allowedProtocols: [.ssh]))

        do {
            _ = try await client.remoteReferences(
                GitRemoteReferencesRequest(remoteURL: "https://example.com/org/repo.git"))
            Issue.record("disallowed protocol unexpectedly launched")
        } catch let error {
            guard case .unsupported(let message) = error else {
                Issue.record("expected unsupported protocol error, got \(error)")
                return
            }
            #expect(message.contains("protocol https is not allowed"))
        }

        #expect(try fakeGit.recordedInvocations().isEmpty)
    }

    @Test("option-shaped remote strings are rejected before process launch")
    func optionShapedRemoteStringsAreRejectedBeforeProcessLaunch() async throws {
        let fakeGit = try FakeGitExecutable()
        let client = SystemGitRemoteClient(configuration: fakeGit.configuration())

        do {
            _ = try await client.remoteReferences(
                GitRemoteReferencesRequest(remoteURL: "-oProxyCommand=bad:repo.git"))
            Issue.record("option-shaped remote unexpectedly launched")
        } catch let error {
            guard case .unsupported(let message) = error else {
                Issue.record("expected unsupported protocol error, got \(error)")
                return
            }
            #expect(message.contains("remote must not start with '-'"))
        }

        #expect(try fakeGit.recordedInvocations().isEmpty)
    }

    @Test("live remote smoke is explicitly opt in")
    func liveRemoteSmokeIsExplicitlyOptIn() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["AGENTSTUDIO_GIT_LIVE_REMOTE_SMOKE"] == "1" else {
            return
        }
        guard let remoteURL = environment["AGENTSTUDIO_GIT_LIVE_REMOTE_URL"], !remoteURL.isEmpty else {
            Issue.record("AGENTSTUDIO_GIT_LIVE_REMOTE_URL is required when live remote smoke is enabled")
            return
        }

        let client = SystemGitRemoteClient()
        let references = try await client.remoteReferences(GitRemoteReferencesRequest(remoteURL: remoteURL))

        #expect(!references.isEmpty)
    }

    @Test("live authenticated remote smoke covers clone fetch push and remote refs")
    func liveAuthenticatedRemoteSmokeCoversCloneFetchPushAndRemoteRefs() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["AGENTSTUDIO_GIT_LIVE_REMOTE_AUTH_SMOKE"] == "1" else {
            return
        }
        guard let remoteURL = environment["AGENTSTUDIO_GIT_LIVE_REMOTE_AUTH_URL"], !remoteURL.isEmpty else {
            Issue.record("AGENTSTUDIO_GIT_LIVE_REMOTE_AUTH_URL is required when live remote auth smoke is enabled")
            return
        }

        let label = environment["AGENTSTUDIO_GIT_LIVE_REMOTE_AUTH_LABEL"] ?? "remote"
        let client = SystemGitRemoteClient(configuration: .init(operationTimeoutSeconds: 180))
        let smokeID = UUID().uuidString.lowercased()
        let refName = "refs/heads/agentstudio-git-live-smoke/\(label)-\(smokeID)"
        let tempRoot = FileManager.default.temporaryDirectory
            .appending(path: "agentstudio-git-live-remote-auth-\(smokeID)")
        let checkoutPath = tempRoot.appending(path: "checkout")
        var pushedRef = false
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        do {
            _ = try await client.clone(
                GitCloneRequest(remoteURL: remoteURL, destinationPath: checkoutPath, checkoutBranch: nil))
            let git = GitProcess(repositoryPath: checkoutPath)
            try git.run("config", "user.name", "AgentStudio Git Live Smoke")
            try git.run("config", "user.email", "agentstudio-git-live-smoke@example.invalid")
            let markerPath = "agentstudio-git-live-smoke-\(smokeID).txt"
            try "live auth smoke \(label) \(smokeID)\n".write(
                to: checkoutPath.appending(path: markerPath),
                atomically: true,
                encoding: .utf8
            )
            try git.run("add", markerPath)
            try git.run("commit", "-m", "agentstudio-git live auth smoke \(label)")

            _ = try await client.push(
                GitPushRequest(repositoryPath: checkoutPath, remoteName: "origin", refspec: "HEAD:\(refName)"))
            pushedRef = true
            _ = try await client.fetch(GitFetchRequest(repositoryPath: checkoutPath, remoteName: "origin"))
            let references = try await client.remoteReferences(GitRemoteReferencesRequest(remoteURL: remoteURL))

            #expect(references.contains { $0.name == refName })
        } catch {
            if pushedRef {
                _ = try? await client.push(
                    GitPushRequest(repositoryPath: checkoutPath, remoteName: "origin", refspec: ":\(refName)"))
            }
            throw error
        }

        _ = try await client.push(
            GitPushRequest(repositoryPath: checkoutPath, remoteName: "origin", refspec: ":\(refName)"))
    }
}
