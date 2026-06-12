import AgentStudioGit
import Testing

@Suite("Git redaction")
struct GitRedactionTests {
    @Test("remote process failures redact credential-bearing URLs")
    func remoteProcessFailuresRedactCredentialBearingURLs() {
        let failure = GitRemoteProcessFailure.redacting(
            executable: "git",
            arguments: [
                "clone",
                "https://user:secret-token@example.com/org/repo.git",
            ],
            exitCode: 128,
            stderr: "fatal: could not read from https://user:secret-token@example.com/org/repo.git"
        )

        #expect(
            failure.redactedArguments == [
                "clone",
                "<redacted-https-remote>",
            ])
        #expect(failure.redactedStderr.contains("<redacted-https-remote>"))
        #expect(!failure.redactedStderr.contains("secret-token"))
        #expect(!failure.redactedArguments.joined(separator: " ").contains("secret-token"))
    }

    @Test("remote process failures redact plain HTTPS remote values")
    func remoteProcessFailuresRedactPlainHTTPSRemoteValues() {
        let failure = GitRemoteProcessFailure.redacting(
            executable: "git",
            arguments: [
                "clone",
                "https://example.com/team/private-repo.git",
            ],
            exitCode: 128,
            stderr: "fatal: could not read from https://example.com/team/private-repo.git"
        )

        let redactedOutput = ([failure.redactedStderr] + failure.redactedArguments).joined(separator: " ")
        #expect(!redactedOutput.contains("example.com"))
        #expect(!redactedOutput.contains("team/private-repo.git"))
        #expect(redactedOutput.contains("<redacted-https-remote>"))
    }

    @Test("redaction removes SSH private key paths from process output")
    func redactionRemovesSSHPrivateKeyPathsFromProcessOutput() {
        let stderr = """
            Warning: Identity file /Users/alice/.ssh/company_deploy_key not accessible.
            no such identity: /Users/alice/.ssh/id_work: No such file or directory
            ssh -i /Users/alice/.ssh/id_rsa git@example.com
            """

        let redacted = GitRedaction.redact(stderr)

        #expect(!redacted.contains("/Users/alice/.ssh"))
        #expect(!redacted.contains("company_deploy_key"))
        #expect(!redacted.contains("id_work"))
        #expect(!redacted.contains("id_rsa"))
        #expect(redacted.contains("<redacted-private-key-path>"))
    }

    @Test("remote process failures redact SSH remote values")
    func remoteProcessFailuresRedactSSHRemoteValues() {
        let failure = GitRemoteProcessFailure.redacting(
            executable: "git",
            arguments: [
                "clone",
                "git@internal.example.com:team/smoke.git",
                "ssh://git@internal.example.com/team/smoke.git",
            ],
            exitCode: 128,
            stderr:
                "fatal: could not read from git@internal.example.com:team/smoke.git or ssh://git@internal.example.com/team/smoke.git"
        )

        let redactedOutput = ([failure.redactedStderr] + failure.redactedArguments).joined(separator: " ")
        #expect(!redactedOutput.contains("internal.example.com"))
        #expect(!redactedOutput.contains("team/smoke.git"))
        #expect(!redactedOutput.contains("git@"))
        #expect(redactedOutput.contains("<redacted-ssh-remote>"))
    }

    @Test("redaction removes HTTPS signed URL query values")
    func redactionRemovesHTTPSSignedURLQueryValues() {
        let failure = GitRemoteProcessFailure.redacting(
            executable: "git",
            arguments: [
                "fetch",
                "https://example.com/artifact.zip?X-Amz-Signature=abcdef123456&sig=shhhh&expires=999",
            ],
            exitCode: 128,
            stderr:
                "failed https://example.com/artifact.zip?X-Amz-Signature=abcdef123456&sig=shhhh&expires=999"
        )

        let redactedOutput = ([failure.redactedStderr] + failure.redactedArguments).joined(separator: " ")
        #expect(!redactedOutput.contains("abcdef123456"))
        #expect(!redactedOutput.contains("shhhh"))
        #expect(!redactedOutput.contains("999"))
        #expect(redactedOutput.contains("<redacted-https-remote>"))
    }
}
