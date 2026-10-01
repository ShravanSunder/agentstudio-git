import Foundation

struct GitBranchIntegrationRealSquashFixture: Decodable, Sendable {
    struct Manifest: Decodable, Sendable {
        let formatVersion: Int
        let sourceRepository: String
        let sourceHead: String
        let provenance: String
        let objectScope: String
        let packFile: String
        let objectsFile: String
        let cases: [Case]
    }

    struct Case: Decodable, Sendable, Equatable {
        let pullRequest: Int
        let branchCommit: String
        let squashCommit: String
        let mergeBaseCommit: String
        let targetCommit: String
        let candidatePosition: Int
        let matchingDeltaPathCount: Int
    }

    let manifest: Manifest
    let pack: Data
    let objects: Set<String>

    static func load() throws -> Self {
        guard let fixtureDirectory = Bundle.module.resourceURL else {
            throw GitBranchIntegrationRealSquashPackError.resourceBundleUnavailable
        }
        let manifestURL = fixtureDirectory.appending(path: "GitBranchIntegrationRealSquash.manifest.json")
        let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: manifestURL))
        let pack = try Data(contentsOf: fixtureDirectory.appending(path: manifest.packFile))
        let objectManifest = try String(
            contentsOf: fixtureDirectory.appending(path: manifest.objectsFile),
            encoding: .utf8
        )
        let objects = Set(objectManifest.split(whereSeparator: \.isNewline).map(String.init))
        return Self(manifest: manifest, pack: pack, objects: objects)
    }

    func importedIndex(in repository: GitFixtureRepository) throws -> URL {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git", "-C", repository.repositoryPath.path, "index-pack", "--stdin"]
        process.environment = ProcessInfo.processInfo.environment.merging(
            [
                "GIT_CONFIG_NOSYSTEM": "1",
                "GIT_CONFIG_GLOBAL": "/dev/null",
                "GIT_CONFIG_XDG": "/dev/null",
                "GIT_TERMINAL_PROMPT": "0",
                "LC_ALL": "C",
            ]
        ) { _, testValue in testValue }

        let input = Pipe()
        let output = Pipe()
        let error = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = error
        try process.run()
        try input.fileHandleForWriting.write(contentsOf: pack)
        try input.fileHandleForWriting.close()
        process.waitUntilExit()

        let packOutputBytes = output.fileHandleForReading.readDataToEndOfFile()
        guard let packOutput = String(bytes: packOutputBytes, encoding: .utf8) else {
            throw GitBranchIntegrationRealSquashPackError.invalidImportOutput
        }
        let packHash = packOutput.split(whereSeparator: \.isWhitespace).last.map(String.init) ?? ""
        let standardErrorBytes = error.fileHandleForReading.readDataToEndOfFile()
        let standardError =
            String(bytes: standardErrorBytes, encoding: .utf8) ?? "git index-pack returned non-UTF8 stderr"
        guard process.terminationStatus == 0, !packHash.isEmpty else {
            throw GitBranchIntegrationRealSquashPackError.importFailed(
                exitCode: process.terminationStatus,
                standardError: standardError
            )
        }
        return repository.repositoryPath
            .appending(path: ".git/objects/pack/pack-\(packHash).idx")
    }

    func verifiedObjects(in repository: GitFixtureRepository, indexPath: URL) throws -> Set<String> {
        let outputURL = repository.root.appending(path: "verified-pack-\(UUID().uuidString).txt")
        guard FileManager.default.createFile(atPath: outputURL.path, contents: Data()) else {
            throw GitBranchIntegrationRealSquashPackError.outputFileCreationFailed
        }
        let outputHandle = try FileHandle(forWritingTo: outputURL)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git", "-C", repository.repositoryPath.path, "verify-pack", "-v", indexPath.path]
        process.environment = ProcessInfo.processInfo.environment.merging(
            [
                "GIT_CONFIG_NOSYSTEM": "1",
                "GIT_CONFIG_GLOBAL": "/dev/null",
                "GIT_CONFIG_XDG": "/dev/null",
                "GIT_TERMINAL_PROMPT": "0",
                "LC_ALL": "C",
            ]
        ) { _, testValue in testValue }
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = outputHandle
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        try outputHandle.close()

        guard process.terminationStatus == 0 else {
            throw GitBranchIntegrationRealSquashPackError.verificationFailed(exitCode: process.terminationStatus)
        }
        let output = try String(contentsOf: outputURL, encoding: .utf8)
        return Set(
            output.split(whereSeparator: \.isNewline).compactMap { line -> String? in
                let fields = line.split(whereSeparator: \.isWhitespace)
                guard fields.count >= 3, fields[1] == "commit" || fields[1] == "tree" else {
                    return nil
                }
                return "\(fields[0]) \(fields[1])"
            })
    }

}

enum GitBranchIntegrationRealSquashPackError: Error {
    case resourceBundleUnavailable
    case outputFileCreationFailed
    case invalidImportOutput
    case importFailed(exitCode: Int32, standardError: String)
    case verificationFailed(exitCode: Int32)
}
