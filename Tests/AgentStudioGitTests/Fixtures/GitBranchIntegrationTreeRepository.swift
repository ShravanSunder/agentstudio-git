import Foundation

struct GitBranchIntegrationTreeEntry: Sendable {
    let mode: String
    let objectType: String
    let objectID: String
    let path: [UInt8]

    init(mode: String, objectType: String, objectID: String, path: String) {
        self.init(mode: mode, objectType: objectType, objectID: objectID, path: Array(path.utf8))
    }

    init(mode: String, objectType: String, objectID: String, path: [UInt8]) {
        self.mode = mode
        self.objectType = objectType
        self.objectID = objectID
        self.path = path
    }
}

struct GitBranchIntegrationTreeRepository {
    let fixture: GitFixtureRepository
    let initialCommit: String
    let baseCommit: String
    let readmeBlob: String

    init(prefix: String) throws {
        let fixture = try GitFixtureRepository.makeRepository(prefix: prefix)
        let initialCommit = try fixture.git.run("rev-parse", "HEAD").trimmed
        let readmeBlob = try Self.writeBlob(fixture, contents: Data("hello\n".utf8))
        let baseTree = try Self.writeTree(
            fixture,
            entries: [
                GitBranchIntegrationTreeEntry(
                    mode: "100644",
                    objectType: "blob",
                    objectID: readmeBlob,
                    path: "README.md"
                )
            ]
        )
        let baseCommit = try Self.writeCommit(
            fixture,
            tree: baseTree,
            parent: initialCommit,
            message: "controlled tree base"
        )
        self.fixture = fixture
        self.initialCommit = initialCommit
        self.baseCommit = baseCommit
        self.readmeBlob = readmeBlob
    }

    func writeBlob(_ contents: Data) throws -> String {
        try Self.writeBlob(fixture, contents: contents)
    }

    func writeTree(entries: [GitBranchIntegrationTreeEntry]) throws -> String {
        try Self.writeTree(fixture, entries: entries)
    }

    func writeCommit(tree: String, parent: String, message: String) throws -> String {
        try Self.writeCommit(fixture, tree: tree, parent: parent, message: message)
    }

    func updateBranch(_ branchName: String, to commit: String) throws {
        try fixture.git.run("update-ref", "refs/heads/\(branchName)", commit)
    }

    private static func writeBlob(_ fixture: GitFixtureRepository, contents: Data) throws -> String {
        try fixture.git.run(["hash-object", "-w", "--stdin"], standardInput: contents).trimmed
    }

    private static func writeTree(
        _ fixture: GitFixtureRepository,
        entries: [GitBranchIntegrationTreeEntry]
    ) throws -> String {
        var treeInput = Data()
        for entry in entries.sorted(by: { $0.path.lexicographicallyPrecedes($1.path) }) {
            treeInput.append(Data("\(entry.mode) \(entry.objectType) \(entry.objectID)\t".utf8))
            treeInput.append(contentsOf: entry.path)
            treeInput.append(0)
        }
        return try fixture.git.run(["mktree", "-z"], standardInput: treeInput).trimmed
    }

    private static func writeCommit(
        _ fixture: GitFixtureRepository,
        tree: String,
        parent: String,
        message: String
    ) throws -> String {
        try fixture.git.run(["commit-tree", tree, "-p", parent, "-m", message]).trimmed
    }
}
