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
                "https://<redacted>@example.com/org/repo.git",
            ])
        #expect(failure.redactedStderr.contains("https://<redacted>@example.com/org/repo.git"))
        #expect(!failure.redactedStderr.contains("secret-token"))
        #expect(!failure.redactedArguments.joined(separator: " ").contains("secret-token"))
    }
}
