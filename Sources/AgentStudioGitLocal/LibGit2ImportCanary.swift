import CLibGit2Local

public enum LibGit2ImportCanary {
    public static func version() -> LibGit2Version {
        var major: Int32 = 0
        var minor: Int32 = 0
        var revision: Int32 = 0
        _ = git_libgit2_version(&major, &minor, &revision)
        return LibGit2Version(major: major, minor: minor, revision: revision)
    }
}

public struct LibGit2Version: Equatable, Sendable {
    public let major: Int32
    public let minor: Int32
    public let revision: Int32

    public init(major: Int32, minor: Int32, revision: Int32) {
        self.major = major
        self.minor = minor
        self.revision = revision
    }
}
