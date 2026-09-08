import Foundation

enum GitRefTransactionCommand: Sendable {
    case start
    case verify(refName: String, expectedOID: String)
    case create(refName: String, newOID: String)
    case update(refName: String, newOID: String, expectedOldOID: String)
    case delete(refName: String, expectedOldOID: String)
    case prepare
    case commit
}

enum GitRefTransactionEncoder {
    static func encode(_ commands: [GitRefTransactionCommand]) -> Data {
        var data = Data()
        for command in commands {
            switch command {
            case .start:
                data.appendNullTerminated("start")
            case .verify(let refName, let expectedOID):
                data.appendNullTerminated("verify \(refName)")
                data.appendNullTerminated(expectedOID)
            case .create(let refName, let newOID):
                data.appendNullTerminated("create \(refName)")
                data.appendNullTerminated(newOID)
            case .update(let refName, let newOID, let expectedOldOID):
                data.appendNullTerminated("update \(refName)")
                data.appendNullTerminated(newOID)
                data.appendNullTerminated(expectedOldOID)
            case .delete(let refName, let expectedOldOID):
                data.appendNullTerminated("delete \(refName)")
                data.appendNullTerminated(expectedOldOID)
            case .prepare:
                data.appendNullTerminated("prepare")
            case .commit:
                data.appendNullTerminated("commit")
            }
        }
        return data
    }
}

extension Data {
    fileprivate mutating func appendNullTerminated(_ value: String) {
        append(contentsOf: value.utf8)
        append(0)
    }
}
