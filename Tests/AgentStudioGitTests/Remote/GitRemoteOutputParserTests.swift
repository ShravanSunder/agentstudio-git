import AgentStudioGit
import Testing

@Suite("Git remote output parser")
struct GitRemoteOutputParserTests {
    @Test("ls-remote parser preserves symrefs normal refs and peeled tags")
    func lsRemoteParserPreservesSymrefsNormalRefsAndPeeledTags() throws {
        let output = """
            ref: refs/heads/main\tHEAD
            1111111111111111111111111111111111111111\tHEAD
            2222222222222222222222222222222222222222\trefs/heads/main
            3333333333333333333333333333333333333333\trefs/tags/v1.0.0
            4444444444444444444444444444444444444444\trefs/tags/v1.0.0^{}

            """

        let references = try GitRemoteOutputParser().parse(output)

        #expect(
            references.contains(
                GitRemoteReference(
                    oid: "1111111111111111111111111111111111111111",
                    name: "HEAD",
                    peeledOID: nil,
                    symrefTarget: "refs/heads/main"
                )))
        #expect(
            references.contains(
                GitRemoteReference(
                    oid: "2222222222222222222222222222222222222222",
                    name: "refs/heads/main",
                    peeledOID: nil,
                    symrefTarget: nil
                )))
        #expect(
            references.contains(
                GitRemoteReference(
                    oid: "3333333333333333333333333333333333333333",
                    name: "refs/tags/v1.0.0",
                    peeledOID: "4444444444444444444444444444444444444444",
                    symrefTarget: nil
                )))
    }

    @Test("ls-remote parser keeps a name holding U+2028 as one reference with its own object")
    func lsRemoteParserKeepsLineSeparatorNameWhole() throws {
        let separatorInside = "refs/heads/a\u{2028}b"
        let output = """
            1111111111111111111111111111111111111111\trefs/heads/main
            2222222222222222222222222222222222222222\t\(separatorInside)

            """

        let references = try GitRemoteOutputParser().parse(output)

        #expect(references.map { Array($0.name.utf8) } == [Array("refs/heads/main".utf8), Array(separatorInside.utf8)])
        #expect(
            references.map(\.oid) == [
                "1111111111111111111111111111111111111111", "2222222222222222222222222222222222222222",
            ])
    }

    @Test("ls-remote parser rejects malformed lines")
    func lsRemoteParserRejectsMalformedLines() throws {
        do {
            _ = try GitRemoteOutputParser().parse("not a valid ls-remote line\n")
            Issue.record("malformed ls-remote output unexpectedly parsed")
        } catch let error {
            guard case .unsupported(let message) = error else {
                Issue.record("expected unsupported parser error, got \(error)")
                return
            }
            #expect(message.contains("malformed ls-remote output"))
        }
    }
}
