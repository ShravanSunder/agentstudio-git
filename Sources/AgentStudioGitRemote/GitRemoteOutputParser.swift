import AgentStudioGitContracts
import Foundation

public struct GitRemoteOutputParser: Sendable {
    public init() {}

    public func parse(_ output: String) throws(GitDataPlaneError) -> [GitRemoteReference] {
        var builders: [String: RemoteReferenceBuilder] = [:]
        var orderedNames: [String] = []

        for rawLine in output.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
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
                if builders[name] == nil {
                    orderedNames.append(name)
                }
                builders[name, default: RemoteReferenceBuilder()].symrefTarget = target
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
                if builders[baseName] == nil {
                    orderedNames.append(baseName)
                }
                builders[baseName, default: RemoteReferenceBuilder()].peeledOID = oid
            } else {
                if builders[refName] == nil {
                    orderedNames.append(refName)
                }
                builders[refName, default: RemoteReferenceBuilder()].oid = oid
            }
        }

        var references: [GitRemoteReference] = []
        references.reserveCapacity(orderedNames.count)
        for name in orderedNames {
            guard let builder = builders[name], let oid = builder.oid else {
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
