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

struct LibGit2DiffImpactSummarizer: Sendable {
    func summarize(_ request: GitDiffImpactSummaryRequest) throws -> GitDiffImpactSummary {
        guard request.maximumChangedFileCount > 0 else {
            throw GitDataPlaneError.unsupported(message: "diff impact maximumChangedFileCount must be positive")
        }
        guard request.maximumChangedLineCount > 0 else {
            throw GitDataPlaneError.unsupported(message: "diff impact maximumChangedLineCount must be positive")
        }

        return try LibGit2ReviewSupport.withRepository(at: request.repositoryPath) { repository in
            let diffReader = LibGit2DiffReader()
            let admissionState = LibGit2DiffImpactFileAdmissionState(
                maximumChangedFileCount: request.maximumChangedFileCount
            )
            var options = try diffReader.diffOptions()
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

            let diff: OpaquePointer
            do {
                diff = try diffReader.makeDiff(
                    GitDiffRequest(
                        repositoryPath: request.repositoryPath,
                        base: request.base,
                        compare: request.compare
                    ),
                    options: &options,
                    repository: repository
                )
            } catch GitDataPlaneError.libgit2Failure(let code, _, _)
                where code == GIT_EUSER.rawValue && admissionState.didReachLimit
            {
                return GitDiffImpactSummary(
                    changedPaths: admissionState.observedPaths,
                    pathsAreComplete: false,
                    changedFileCount: .indeterminate,
                    changedLineCount: .indeterminate
                )
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
            let changedPaths = try (0..<changedFileCount)
                .map { index -> GitDiffImpactPath in
                    guard let deltaPointer = git_diff_get_delta(diff, index) else {
                        throw GitDataPlaneError.unsupported(
                            message: "libgit2 returned no diff delta at index \(index)"
                        )
                    }
                    return LibGit2DiffImpactFileAdmissionState.path(from: deltaPointer.pointee)
                }
                .sorted(by: Self.pathsPrecede)

            var changedLineCount = 0
            for index in 0..<changedFileCount {
                let lineStats = try diffReader.lineStats(diff: diff, index: index)
                let fileLineCount = lineStats.additions.addingReportingOverflow(lineStats.deletions)
                let cumulativeLineCount = changedLineCount.addingReportingOverflow(fileLineCount.partialValue)
                if fileLineCount.overflow || cumulativeLineCount.overflow
                    || cumulativeLineCount.partialValue >= request.maximumChangedLineCount
                {
                    return GitDiffImpactSummary(
                        changedPaths: changedPaths,
                        pathsAreComplete: true,
                        changedFileCount: .exact(changedFileCount),
                        changedLineCount: .atLeastLimit(request.maximumChangedLineCount)
                    )
                }
                changedLineCount = cumulativeLineCount.partialValue
            }

            return GitDiffImpactSummary(
                changedPaths: changedPaths,
                pathsAreComplete: true,
                changedFileCount: .exact(changedFileCount),
                changedLineCount: .exact(changedLineCount)
            )
        }
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
