import AgentStudioGit
import Foundation
import Testing

@Suite("Git branch integration contracts")
struct GitBranchIntegrationContractTests {
    @Test("branch integration reports and every grade round-trip with explicit tags")
    func branchIntegrationReportsAndGradesRoundTrip() throws {
        // Arrange
        let grades: [GitBranchIntegrationGrade] = [
            .integrated(.sameCommit),
            .integrated(.ancestor),
            .integrated(.sameContent),
            .integrated(.emptyDelta),
            .integrated(.squash(commit: "0123456789abcdef0123456789abcdef01234567")),
            .hasRemainingContribution,
            .unknown(.branchNotFound),
            .unknown(.noMergeBase),
            .unknown(.multipleMergeBases),
            .unknown(.historyLimitReached),
            .unknown(.incompleteHistory),
            .unknown(.missingObjects),
            .unknown(.readFailed),
        ]
        let report = GitBranchIntegrationReport(
            targetCommit: "0123456789abcdef0123456789abcdef01234567",
            assessments: grades.enumerated().map { index, grade in
                GitBranchIntegrationAssessment(
                    branchName: "branch-\(index)",
                    branchCommit: index == 0 ? nil : "89abcdef0123456789abcdef0123456789abcdef",
                    grade: grade
                )
            }
        )

        // Act
        let encodedReport = try JSONEncoder().encode(report)
        let decodedReport = try JSONDecoder().decode(GitBranchIntegrationReport.self, from: encodedReport)

        // Assert
        #expect(decodedReport == report)
        #expect(
            try JSONDecoder().decode(
                GitBranchIntegrationGrade.self,
                from: Data(#"{"kind":"integrated","proof":{"kind":"squash","commit":"deadbeef"}}"#.utf8)
            ) == .integrated(.squash(commit: "deadbeef"))
        )
    }

    @Test("branch integration decoders reject invalid limits and contradictory tagged payloads")
    func branchIntegrationDecodersRejectInvalidShapes() {
        // Arrange
        let invalidRequests = [
            #"{"repositoryPath":"file:///tmp/repo","branchNames":[],"targetCommit":"abc","squashSearchCommitLimit":-1}"#,
            #"{"repositoryPath":"file:///tmp/repo","branchNames":[],"targetCommit":"","squashSearchCommitLimit":0}"#,
            #"{"repositoryPath":"file:///tmp/repo","branchNames":[],"targetCommit":"abc","squashSearchCommitLimit":10001}"#,
        ]
        let invalidGrades = [
            #"{"kind":"hasRemainingContribution","proof":{"kind":"ancestor"}}"#,
            #"{"kind":"integrated","proof":{"kind":"sameCommit"},"reason":"readFailed"}"#,
            #"{"kind":"unknown","reason":"readFailed","proof":{"kind":"ancestor"}}"#,
        ]
        let invalidProofs = [
            #"{"kind":"sameCommit","commit":"deadbeef"}"#,
            #"{"kind":"squash","commit":""}"#,
        ]

        // Act / Assert
        for json in invalidRequests {
            #expect(throws: DecodingError.self) {
                _ = try JSONDecoder().decode(GitBranchIntegrationRequest.self, from: Data(json.utf8))
            }
        }
        for json in invalidGrades {
            #expect(throws: DecodingError.self) {
                _ = try JSONDecoder().decode(GitBranchIntegrationGrade.self, from: Data(json.utf8))
            }
        }
        for json in invalidProofs {
            #expect(throws: DecodingError.self) {
                _ = try JSONDecoder().decode(GitIntegrationProof.self, from: Data(json.utf8))
            }
        }
        #expect(throws: DecodingError.self) {
            _ = try JSONDecoder().decode(
                GitIntegrationUnknownReason.self,
                from: Data(#""futureReason""#.utf8)
            )
        }
    }
}
