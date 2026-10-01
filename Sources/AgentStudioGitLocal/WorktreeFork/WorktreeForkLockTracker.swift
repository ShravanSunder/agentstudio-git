import AgentStudioGitContracts
import Darwin
import Foundation
import os

/// Tracks lock paths touched by one fork so rollback can distinguish its own survivors from foreign files.
final class WorktreeForkLockTracker: Sendable {
    enum ObservedPath: Sendable {
        case absent
        case present(WorktreeForkEntryIdentity)
        case inaccessible

        var isAbsent: Bool {
            if case .absent = self { true } else { false }
        }
    }

    private struct TrackedLock {
        let fact: GitLockFact
        var acquiredIdentity: WorktreeForkEntryIdentity?
        var wasAcquired = false
        var foreign = false
    }

    private struct State {
        var locks: [URL: TrackedLock] = [:]
    }

    private let state = OSAllocatedUnfairLock(initialState: State())
    private let pathObserver: @Sendable (URL) -> ObservedPath

    init() {
        pathObserver = Self.observe
    }

    init(pathObserver: @escaping @Sendable (URL) -> ObservedPath) {
        self.pathObserver = pathObserver
    }

    /// Records the pre-call state before libgit2 gets a chance to inspect or create a lock.
    func beginAttempt(for facts: [GitLockFact]) {
        state.withLock { state in
            for fact in facts {
                let observed = pathObserver(fact.path)
                guard var tracked = state.locks[fact.path] else {
                    var newLock = TrackedLock(fact: fact)
                    if case .present = observed {
                        newLock.foreign = true
                    } else if case .inaccessible = observed {
                        newLock.foreign = true
                    }
                    state.locks[fact.path] = newLock
                    continue
                }

                if Self.matchesOwnedLock(observed, tracked: tracked) {
                    continue
                }
                if case .present = observed {
                    tracked.foreign = true
                } else if case .inaccessible = observed, !tracked.wasAcquired {
                    tracked.foreign = true
                } else if case .absent = observed {
                    Self.retireAcquisition(in: &tracked)
                }
                state.locks[fact.path] = tracked
            }
        }
    }

    /// A successful explicit transaction lock proves ownership while it is still held.
    func recordAcquisition(of fact: GitLockFact) {
        let observed = pathObserver(fact.path)
        state.withLock { state in
            var tracked = state.locks[fact.path] ?? TrackedLock(fact: fact)
            switch observed {
            case .present(let identity):
                tracked.acquiredIdentity = identity
                tracked.wasAcquired = true
                tracked.foreign = false
            case .inaccessible:
                tracked.acquiredIdentity = nil
                tracked.wasAcquired = true
                tracked.foreign = false
            case .absent:
                tracked.acquiredIdentity = nil
                tracked.wasAcquired = false
                tracked.foreign = false
            }
            state.locks[fact.path] = tracked
        }
    }

    func recordForeignLock(_ fact: GitLockFact) {
        let observed = pathObserver(fact.path)
        state.withLock { state in
            var tracked = state.locks[fact.path] ?? TrackedLock(fact: fact)
            if case .absent = observed {
                Self.retireAcquisition(in: &tracked)
            }
            if !Self.matchesOwnedLock(observed, tracked: tracked) {
                tracked.foreign = true
            }
            state.locks[fact.path] = tracked
        }
    }

    /// A failed call cannot prove it acquired a newly present candidate lock.
    func recordFailure(for facts: [GitLockFact]) {
        state.withLock { state in
            for fact in facts {
                let observed = pathObserver(fact.path)
                var tracked = state.locks[fact.path] ?? TrackedLock(fact: fact)
                if Self.matchesOwnedLock(observed, tracked: tracked) {
                    state.locks[fact.path] = tracked
                    continue
                }

                switch observed {
                case .absent:
                    Self.retireAcquisition(in: &tracked)
                case .present, .inaccessible:
                    tracked.foreign = true
                }
                state.locks[fact.path] = tracked
            }
        }
    }

    /// Returns active candidates in stable path order, including foreign locks for final validation.
    func activeLocks() -> [GitLockFact] {
        state.withLock { state in
            var activeFacts: [GitLockFact] = []
            for var tracked in Array(state.locks.values) {
                switch pathObserver(tracked.fact.path) {
                case .absent:
                    Self.retireAcquisition(in: &tracked)
                    state.locks[tracked.fact.path] = tracked
                case .present, .inaccessible:
                    activeFacts.append(tracked.fact)
                }
            }
            return activeFacts.sorted { $0.path.path < $1.path.path }
        }
    }

    /// Returns only survivors whose current inode is the one this operation acquired.
    func ownedResidue() -> [GitLockFact] {
        state.withLock { state in
            var residues: [GitLockFact] = []
            for var tracked in Array(state.locks.values) {
                let observed = pathObserver(tracked.fact.path)
                if case .absent = observed {
                    Self.retireAcquisition(in: &tracked)
                    state.locks[tracked.fact.path] = tracked
                    continue
                }
                if !tracked.foreign, Self.matchesOwnedLock(observed, tracked: tracked) {
                    residues.append(tracked.fact)
                }
            }
            return residues.sorted { $0.path.path < $1.path.path }
        }
    }

    /// Every active lock is protected from recursive deletion, even when it belongs to another process.
    func protectedPaths() -> [URL] {
        activeLocks().map(\.path)
    }

    private static func matchesOwnedLock(_ observed: ObservedPath, tracked: TrackedLock) -> Bool {
        switch observed {
        case .present(let identity):
            guard tracked.wasAcquired else {
                return false
            }
            guard let acquiredIdentity = tracked.acquiredIdentity else {
                return true
            }
            return acquiredIdentity == identity
        case .inaccessible:
            return tracked.wasAcquired
        case .absent:
            return false
        }
    }

    private static func retireAcquisition(in tracked: inout TrackedLock) {
        tracked.acquiredIdentity = nil
        tracked.wasAcquired = false
    }

    private static func observe(_ path: URL) -> ObservedPath {
        var info = Darwin.stat()
        let result = path.path.withCString { lstat($0, &info) }
        guard result != 0 else {
            return .present(WorktreeForkEntryIdentity(info))
        }
        return errno == ENOENT || errno == ENOTDIR ? .absent : .inaccessible
    }
}
