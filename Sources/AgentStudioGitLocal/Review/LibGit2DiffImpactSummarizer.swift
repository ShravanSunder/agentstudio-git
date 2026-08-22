import AgentStudioGitContracts
import CLibGit2Local
import Foundation

private final class LibGit2DiffImpactFileAdmissionState {
    let maximumChangedFileCount: Int
    private(set) var observedPaths: [GitDiffImpactPath] = []
    private(set) var didReachLimit = false

    init(maximumChangedFileCount: Int) {
        self.maximumChangedFileCount = maximumChangedFileCount
    }

    func admit(_ delta: git_diff_delta) -> Int32 {
        observedPaths.append(Self.path(from: delta))
        guard observedPaths.count < maximumChangedFileCount else {
            didReachLimit = true
            return GIT_EUSER.rawValue
        }
        return 0
    }

    static func path(from delta: git_diff_delta) -> GitDiffImpactPath {
        let oldPath = LibGit2ReviewSupport.path(delta.old_file.path)
        let newPath = LibGit2ReviewSupport.path(delta.new_file.path)
        switch delta.status {
        case GIT_DELTA_ADDED, GIT_DELTA_UNTRACKED:
            return GitDiffImpactPath(currentPath: newPath, previousPath: nil)
        case GIT_DELTA_DELETED:
            return GitDiffImpactPath(currentPath: nil, previousPath: oldPath)
        case GIT_DELTA_RENAMED, GIT_DELTA_COPIED:
            return GitDiffImpactPath(currentPath: newPath, previousPath: oldPath)
        default:
            return GitDiffImpactPath(currentPath: newPath ?? oldPath, previousPath: nil)
        }
    }
}

private final class LibGit2DiffImpactLineAdmissionState {
    let maximumChangedLineCount: Int
    let maximumDiffableBlobByteCount: UInt64
    private(set) var addedLineCount = 0
    private(set) var deletedLineCount = 0
    private(set) var didReachLimit = false
    private(set) var didEncounterOversizedBlob = false

    init(maximumChangedLineCount: Int, maximumDiffableBlobByteCount: Int64) {
        self.maximumChangedLineCount = maximumChangedLineCount
        self.maximumDiffableBlobByteCount = UInt64(maximumDiffableBlobByteCount)
    }

    func admit(_ delta: git_diff_delta) -> Int32 {
        guard delta.old_file.size <= maximumDiffableBlobByteCount,
            delta.new_file.size <= maximumDiffableBlobByteCount
        else {
            didEncounterOversizedBlob = true
            return GIT_EUSER.rawValue
        }
        return 0
    }

    func admit(_ line: git_diff_line) -> Int32 {
        if line.origin == CChar(GIT_DIFF_LINE_ADDITION.rawValue) {
            addedLineCount += 1
        } else if line.origin == CChar(GIT_DIFF_LINE_DELETION.rawValue) {
            deletedLineCount += 1
        } else {
            return 0
        }
        let changedLineCount = addedLineCount + deletedLineCount
        guard changedLineCount < maximumChangedLineCount else {
            didReachLimit = true
            return GIT_EUSER.rawValue
        }
        return 0
    }
}

private enum LibGit2BoundedDiffCreation {
    case complete(OpaquePointer)
    case fileLimitReached(GitDiffImpactSummary)
}

struct LibGit2DiffImpactSummarizer: Sendable {
    func summarize(_ request: GitDiffImpactSummaryRequest) throws -> GitDiffImpactSummary {
        guard request.maximumChangedFileCount > 0 else {
            throw GitDataPlaneError.unsupported(message: "diff impact maximumChangedFileCount must be positive")
        }
        guard request.maximumChangedLineCount > 0 else {
            throw GitDataPlaneError.unsupported(message: "diff impact maximumChangedLineCount must be positive")
        }
        guard request.maximumDiffableBlobByteCount > 0 else {
            throw GitDataPlaneError.unsupported(
                message: "diff impact maximumDiffableBlobByteCount must be positive"
            )
        }

        return try LibGit2ReviewSupport.withRepository(at: request.repositoryPath) { repository in
            let diffReader = LibGit2DiffReader()
            let creation = try createBoundedDiff(request, repository: repository, diffReader: diffReader)
            guard case .complete(let diff) = creation else {
                guard case .fileLimitReached(let summary) = creation else {
                    throw GitDataPlaneError.unsupported(message: "unrecognized bounded diff creation outcome")
                }
                return summary
            }
            defer { git_diff_free(diff) }

            let deltaCount = git_diff_num_deltas(diff)
            if deltaCount > 0 {
                try diffReader.findRenames(
                    diff,
                    maximumComparisonsPerTarget: deltaCount
                )
            }

            let changedFileCount = git_diff_num_deltas(diff)
            let changedPaths = try changedPaths(diff: diff, changedFileCount: changedFileCount)
            return try summarizeLineImpact(
                diff: diff,
                changedPaths: changedPaths,
                changedFileCount: changedFileCount,
                request: request
            )
        }
    }

    private func createBoundedDiff(
        _ request: GitDiffImpactSummaryRequest,
        repository: OpaquePointer,
        diffReader: LibGit2DiffReader
    ) throws -> LibGit2BoundedDiffCreation {
        let admissionState = LibGit2DiffImpactFileAdmissionState(
            maximumChangedFileCount: request.maximumChangedFileCount
        )
        var options = try diffReader.diffOptions()
        options.max_size = request.maximumDiffableBlobByteCount
        options.flags &= ~GIT_DIFF_SHOW_BINARY.rawValue
        options.payload = Unmanaged.passUnretained(admissionState).toOpaque()
        options.notify_cb = { _, deltaPointer, _, payload in
            guard let deltaPointer, let payload else {
                return GIT_EUSER.rawValue
            }
            let state = Unmanaged<LibGit2DiffImpactFileAdmissionState>
                .fromOpaque(payload)
                .takeUnretainedValue()
            return state.admit(deltaPointer.pointee)
        }

        do {
            let diff = try diffReader.makeDiff(
                GitDiffRequest(
                    repositoryPath: request.repositoryPath,
                    base: request.base,
                    compare: request.compare
                ),
                options: &options,
                repository: repository
            )
            return .complete(diff)
        } catch GitDataPlaneError.libgit2Failure(let code, _, _)
            where code == GIT_EUSER.rawValue && admissionState.didReachLimit
        {
            return .fileLimitReached(
                GitDiffImpactSummary(
                    changedPaths: admissionState.observedPaths,
                    pathsAreComplete: false,
                    changedFileCount: .atLeastLimit(request.maximumChangedFileCount),
                    changedLineCount: .indeterminate,
                    addedLineCount: nil,
                    deletedLineCount: nil
                )
            )
        }
    }

    private func changedPaths(diff: OpaquePointer, changedFileCount: Int) throws -> [GitDiffImpactPath] {
        try (0..<changedFileCount)
            .map { index -> GitDiffImpactPath in
                guard let deltaPointer = git_diff_get_delta(diff, index) else {
                    throw GitDataPlaneError.unsupported(
                        message: "libgit2 returned no diff delta at index \(index)"
                    )
                }
                return LibGit2DiffImpactFileAdmissionState.path(from: deltaPointer.pointee)
            }
            .sorted(by: Self.pathsPrecede)
    }

    private func summarizeLineImpact(
        diff: OpaquePointer,
        changedPaths: [GitDiffImpactPath],
        changedFileCount: Int,
        request: GitDiffImpactSummaryRequest
    ) throws -> GitDiffImpactSummary {
        let state = LibGit2DiffImpactLineAdmissionState(
            maximumChangedLineCount: request.maximumChangedLineCount,
            maximumDiffableBlobByteCount: request.maximumDiffableBlobByteCount
        )
        let result = git_diff_foreach(
            diff,
            { deltaPointer, _, payload in
                guard let deltaPointer, let payload else { return GIT_EUSER.rawValue }
                return Unmanaged<LibGit2DiffImpactLineAdmissionState>
                    .fromOpaque(payload).takeUnretainedValue().admit(deltaPointer.pointee)
            },
            nil,
            nil,
            { _, _, linePointer, payload in
                guard let linePointer, let payload else { return GIT_EUSER.rawValue }
                return Unmanaged<LibGit2DiffImpactLineAdmissionState>
                    .fromOpaque(payload).takeUnretainedValue().admit(linePointer.pointee)
            },
            Unmanaged.passUnretained(state).toOpaque()
        )
        if result == GIT_EUSER.rawValue, state.didEncounterOversizedBlob {
            return GitDiffImpactSummary(
                changedPaths: changedPaths,
                pathsAreComplete: true,
                changedFileCount: .exact(changedFileCount),
                changedLineCount: .indeterminate,
                addedLineCount: nil,
                deletedLineCount: nil
            )
        }
        if result == GIT_EUSER.rawValue, state.didReachLimit {
            return GitDiffImpactSummary(
                changedPaths: changedPaths,
                pathsAreComplete: true,
                changedFileCount: .exact(changedFileCount),
                changedLineCount: .atLeastLimit(request.maximumChangedLineCount),
                addedLineCount: state.addedLineCount,
                deletedLineCount: state.deletedLineCount
            )
        }
        guard result >= 0 else {
            throw LibGit2ErrorCapture.failure(code: result)
        }
        return GitDiffImpactSummary(
            changedPaths: changedPaths,
            pathsAreComplete: true,
            changedFileCount: .exact(changedFileCount),
            changedLineCount: .exact(state.addedLineCount + state.deletedLineCount),
            addedLineCount: state.addedLineCount,
            deletedLineCount: state.deletedLineCount
        )
    }

    private static func pathsPrecede(_ lhs: GitDiffImpactPath, _ rhs: GitDiffImpactPath) -> Bool {
        let lhsSortPath = lhs.currentPath ?? lhs.previousPath ?? ""
        let rhsSortPath = rhs.currentPath ?? rhs.previousPath ?? ""
        if lhsSortPath != rhsSortPath {
            return lhsSortPath < rhsSortPath
        }
        return (lhs.previousPath ?? "") < (rhs.previousPath ?? "")
    }
}
