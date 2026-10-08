import AgentStudioGitContracts
import Foundation

public struct GitRemoteOutputParser: Sendable {
    public init() {}

    /// Git refs are bytes: a line ends only at a "\n" byte, and references are told apart by their names' bytes, since
    /// `String` keys would merge two canonically equivalent names into one reference.
    public func parse(_ output: String) throws(GitDataPlaneError) -> [GitRemoteReference] {
        var builders: [[UInt8]: RemoteReferenceBuilder] = [:]
        var orderedNames: [String] = []

        for rawLine in output.utf8.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: false) {
            guard let line = String(rawLine) else {
                throw .unsupported(message: "malformed ls-remote output")
            }
            if line.isEmpty {
                continue
            }

            if line.hasPrefix("ref: ") {
                let parts = line.dropFirst("ref: ".count)
                    .split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
                guard parts.count == 2 else {
                    throw .unsupported(message: "malformed ls-remote output")
                }
                let target = String(parts[0])
                let name = String(parts[1])
                if builders[Array(name.utf8)] == nil {
                    orderedNames.append(name)
                }
                builders[Array(name.utf8), default: RemoteReferenceBuilder()].symrefTarget = target
                continue
            }

            let parts = line.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else {
                throw .unsupported(message: "malformed ls-remote output")
            }
            let oid = String(parts[0])
            let refName = String(parts[1])
            if refName.hasSuffix("^{}") {
                let baseName = String(refName.dropLast(3))
                if builders[Array(baseName.utf8)] == nil {
                    orderedNames.append(baseName)
                }
                builders[Array(baseName.utf8), default: RemoteReferenceBuilder()].peeledOID = oid
            } else {
                if builders[Array(refName.utf8)] == nil {
                    orderedNames.append(refName)
                }
                builders[Array(refName.utf8), default: RemoteReferenceBuilder()].oid = oid
            }
        }

        var references: [GitRemoteReference] = []
        references.reserveCapacity(orderedNames.count)
        for name in orderedNames {
            guard let builder = builders[Array(name.utf8)], let oid = builder.oid else {
                throw .unsupported(message: "malformed ls-remote output")
            }
            references.append(
                GitRemoteReference(
                    oid: oid,
                    name: name,
                    peeledOID: builder.peeledOID,
                    symrefTarget: builder.symrefTarget
                ))
        }
        return references
    }

    private struct RemoteReferenceBuilder {
        var oid: String?
        var peeledOID: String?
        var symrefTarget: String?
    }
}
