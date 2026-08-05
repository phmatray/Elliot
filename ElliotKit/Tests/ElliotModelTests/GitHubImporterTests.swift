import Foundation
import Testing

@testable import ElliotModel

func issue(
    _ n: Int, title: String = "Some work", body: String? = "",
    state: String = "OPEN", createdAt: Date? = nil
) -> GHIssue {
    GHIssue(
        number: n, title: title,
        url: "https://github.com/phmatray/Elliot/issues/\(n)",
        state: state, createdAt: createdAt, body: body)
}

func pullRequest(
    _ n: Int, branch: String, title: String = "feat(app): something",
    body: String? = nil, isDraft: Bool = false,
    state: String = "OPEN", mergedAt: Date? = nil
) -> GHPullRequest {
    GHPullRequest(
        number: n, url: "https://github.com/phmatray/Elliot/pull/\(n)",
        title: title, body: body, headRefName: branch,
        isDraft: isDraft, state: state, mergedAt: mergedAt)
}

@Suite("GitHub importer — pairing and columns")
struct GitHubImporterPairingTests {

    @Test("An issue and the PR on its branch are one unit")
    func pairsIssueWithItsPullRequest() {
        let units = GitHubImporter.group(
            issues: [issue(11)], pullRequests: [pullRequest(20, branch: "feat/11-tree-layout")])
        #expect(units.count == 1)
        #expect(units[0].issue?.number == 11)
        #expect(units[0].pullRequest?.number == 20)
    }

    @Test("A PR no issue claims stands alone")
    func unclaimedPullRequestBecomesItsOwnUnit() {
        let units = GitHubImporter.group(
            issues: [issue(11)], pullRequests: [pullRequest(14, branch: "renovate/grdb-7.x")])
        #expect(units.count == 2)
        #expect(units.contains { $0.issue == nil && $0.pullRequest?.number == 14 })
    }

    @Test("A pull request is claimed by at most one issue")
    func pullRequestIsClaimedOnce() {
        let units = GitHubImporter.group(
            issues: [issue(4), issue(47)],
            pullRequests: [pullRequest(20, branch: "feat/47-dark-mode")])
        let claimants = units.filter { $0.pullRequest?.number == 20 }
        #expect(claimants.count == 1)
        #expect(claimants.first?.issue?.number == 47)
    }

    /// The whole mapping matrix in one place: (issue state, PR state) → column.
    @Test(
        "The column comes from what GitHub says",
        arguments: [
            ("OPEN", nil as (String, Bool)?, Column.todo),  // no pull request
            ("OPEN", ("OPEN", true), Column.inProgress),  // draft
            ("OPEN", ("OPEN", false), Column.inReview),  // ready
            ("OPEN", ("MERGED", false), Column.done),
            ("CLOSED", ("MERGED", false), Column.done),
            ("CLOSED", nil, Column.done),
            ("OPEN", ("CLOSED", false), Column.todo),  // branch abandoned, work is not
            ("CLOSED", ("CLOSED", false), Column.done),
        ])
    func columnMatrix(issueState: String, pr: (String, Bool)?, expected: Column) {
        let unit = ImportUnit(
            issue: issue(11, state: issueState),
            pullRequest: pr.map {
                pullRequest(
                    20, branch: "feat/11-x", isDraft: $0.1, state: $0.0,
                    mergedAt: $0.0 == "MERGED" ? Date(timeIntervalSince1970: 1) : nil)
            })
        #expect(GitHubImporter.column(for: unit) == expected)
    }

    @Test("A pull request with no issue at all still lands somewhere sensible")
    func standalonePullRequest() {
        #expect(
            GitHubImporter.column(
                for: ImportUnit(pullRequest: pullRequest(14, branch: "renovate/grdb-7.x")))
                == .inReview)
    }

    @Test("No unit ever maps to Backlog")
    func backlogIsUnreachable() {
        let units = GitHubImporter.group(
            issues: [issue(1), issue(2, state: "CLOSED")],
            pullRequests: [pullRequest(3, branch: "feat/1-x"), pullRequest(9, branch: "renovate/x")])
        #expect(units.allSatisfy { GitHubImporter.column(for: $0) != .backlog })
    }
}
