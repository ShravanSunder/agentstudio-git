import AgentStudioGitLockSupport
import Foundation
import Testing

@testable import AgentStudioGitLocal

@Suite("Git lock residue observer")
struct GitLockResidueObserverTests {
    @Test("an own lock remains reported after the named unlink fault denies cleanup")
    func ownLockRemainsReportedAfterNamedUnlinkFaultDeniesCleanup() throws {
        let fixture = try GitFixtureRepository.makeRepository(prefix: "agentstudio-git-lock-residue")
        defer { fixture.remove() }
        let lockPath = fixture.repositoryPath.appending(path: ".git/index.lock")
        try Data().write(to: lockPath)
        let faultControl = GitLockResidueUnlinkFault(deniedPaths: [lockPath])

        #expect(throws: CocoaError.self) {
            try faultControl.unlink(lockPath)
        }

        let lockResidue = GitLockResidueObserver.live.residue(for: [lockPath])

        #expect(lockResidue == [lockPath])
    }

    @Test("an unobservable lock path remains in residue")
    func unobservableLockPathRemainsInResidue() {
        let lockPath = URL(fileURLWithPath: "/tmp/repo/.git/index.lock")
        let observer = GitLockResidueObserver(pathStatus: { _ in .inaccessible })

        #expect(observer.residue(for: [lockPath]) == [lockPath])
    }
}

private struct GitLockResidueUnlinkFault {
    let deniedPaths: Set<URL>

    func unlink(_ path: URL) throws {
        guard deniedPaths.contains(path) else {
            try FileManager.default.removeItem(at: path)
            return
        }
        throw CocoaError(.fileWriteNoPermission, userInfo: [NSFilePathErrorKey: path.path])
    }
}
