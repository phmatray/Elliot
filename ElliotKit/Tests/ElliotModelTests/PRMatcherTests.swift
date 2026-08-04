import Foundation
import Testing

@testable import ElliotModel

private func pr(
    _ number: Int,
    branch: String = "feat/47-add-dark-mode",
    title: String = "feat(ui): add dark mode (#47)",
    body: String? = "Closes #47",
    isDraft: Bool = false,
    state: String = "OPEN",
    createdAt: Date? = nil
) -> GHPullRequest {
    GHPullRequest(
        number: number,
        url: "https://github.com/phmatray/Elliot/pull/\(number)",
        title: title,
        body: body,
        headRefName: branch,
        isDraft: isDraft,
        state: state,
        createdAt: createdAt
    )
}

@Suite("PR matcher")
struct PRMatcherTests {

    // MARK: - The anchoring bug this type exists to prevent

    @Test("Issue 4 does not match branch feat/47-…")
    func shortIssueDoesNotMatchLongerBranch() {
        #expect(!PRMatcher.branchMatches("feat/47-add-dark-mode", issue: 4))
        #expect(PRMatcher.branchMatches("feat/47-add-dark-mode", issue: 47))
    }

    @Test("Issue 47 does not match branch feat/470-…")
    func issueDoesNotMatchLongerNumber() {
        #expect(!PRMatcher.branchMatches("feat/470-something", issue: 47))
    }

    @Test("Any branch prefix works — the convention comes from the repo profile", arguments: [
        "feat/47-add-dark-mode",
        "fix/47-crash-on-launch",
        "chore/47-bump-deps",
        "47-no-prefix",
        "feat/47_underscore",
        "feat/47",
    ])
    func branchPrefixesAreNotPinned(branch: String) {
        #expect(PRMatcher.branchMatches(branch, issue: 47))
    }

    @Test("A branch with no issue number matches nothing")
    func unrelatedBranch() {
        #expect(!PRMatcher.branchMatches("main", issue: 47))
        #expect(!PRMatcher.branchMatches("feat/add-dark-mode", issue: 47))
    }

    // MARK: - Title and body

    @Test("A title ending in (#47) matches")
    func titleMatching() {
        #expect(PRMatcher.titleMatches("feat(ui): add dark mode (#47)", issue: 47))
        #expect(!PRMatcher.titleMatches("feat(ui): add dark mode (#470)", issue: 47))
        #expect(!PRMatcher.titleMatches("feat(ui): add dark mode", issue: 47))
    }

    @Test("Closing keywords are recognised", arguments: [
        "Closes #47", "closes #47", "Fixes #47", "resolved #47", "This PR fixes #47 nicely",
    ])
    func closingKeywords(body: String) {
        #expect(PRMatcher.bodyCloses(body, issue: 47))
    }

    @Test("A close of a different issue is not a match")
    func closingOtherIssue() {
        #expect(!PRMatcher.bodyCloses("Closes #470", issue: 47))
        #expect(!PRMatcher.bodyCloses("Closes #48", issue: 47))
        #expect(!PRMatcher.bodyCloses("Related to #47", issue: 47))
        #expect(!PRMatcher.bodyCloses(nil, issue: 47))
    }

    // MARK: - Selection

    @Test("The PR whose branch carries the issue wins")
    func bestMatchByBranch() {
        let candidates = [
            pr(10, branch: "feat/12-other", title: "other", body: nil),
            pr(11, branch: "feat/47-add-dark-mode", title: "unrelated title", body: nil),
        ]
        #expect(PRMatcher.bestMatch(among: candidates, issue: 47)?.number == 11)
    }

    @Test("A title match carries a PR whose branch was renamed")
    func bestMatchByTitle() {
        let candidates = [pr(11, branch: "renamed-branch", title: "feat: dark mode (#47)", body: nil)]
        #expect(PRMatcher.bestMatch(among: candidates, issue: 47)?.number == 11)
    }

    @Test("Nothing plausible returns nothing")
    func noMatch() {
        let candidates = [pr(10, branch: "feat/12-other", title: "other", body: "Closes #12")]
        #expect(PRMatcher.bestMatch(among: candidates, issue: 47) == nil)
    }

    @Test("A resumed run finds the PR it opened before, even though it is older")
    func resumedRunFindsOlderPR() {
        // The decisive case: implement-issue is resume-safe, so the second run
        // reuses the PR the first one opened. Recency must be a tiebreak only —
        // filtering on it would make every resumed run report "no PR found".
        let runStartedAt = Date(timeIntervalSince1970: 2_000_000)
        let older = pr(11, createdAt: Date(timeIntervalSince1970: 1_000_000))
        #expect(PRMatcher.bestMatch(among: [older], issue: 47, runStartedAt: runStartedAt)?.number == 11)
    }

    @Test("Between two equally-matching PRs, the newer one wins")
    func tiebreakOnRecency() {
        let older = pr(11, createdAt: Date(timeIntervalSince1970: 1_000_000))
        let newer = pr(12, createdAt: Date(timeIntervalSince1970: 3_000_000))
        #expect(PRMatcher.bestMatch(among: [older, newer], issue: 47)?.number == 12)
        #expect(PRMatcher.bestMatch(among: [newer, older], issue: 47)?.number == 12)
    }

    @Test("A stronger signal beats a weaker one")
    func scoringOrder() {
        let branchOnly = pr(11, branch: "feat/47-x", title: "no marker", body: nil)
        let titleOnly = pr(12, branch: "other", title: "feat: x (#47)", body: nil)
        #expect(PRMatcher.bestMatch(among: [titleOnly, branchOnly], issue: 47)?.number == 11)
    }

    @Test("Selection is deterministic when everything else ties")
    func deterministicSelection() {
        let a = pr(11, createdAt: nil)
        let b = pr(12, createdAt: nil)
        #expect(PRMatcher.bestMatch(among: [a, b], issue: 47)?.number == 12)
        #expect(PRMatcher.bestMatch(among: [b, a], issue: 47)?.number == 12)
    }

    // MARK: - PR state helpers

    @Test("A ready-for-review PR is open and not a draft")
    func readyForReview() {
        #expect(pr(11, isDraft: false, state: "OPEN").isReadyForReview)
        #expect(!pr(11, isDraft: true, state: "OPEN").isReadyForReview)
        #expect(!pr(11, isDraft: false, state: "MERGED").isReadyForReview)
    }

    @Test("A merged PR is recognised from either signal")
    func mergedDetection() {
        #expect(pr(11, state: "MERGED").isMerged)
        var byDate = pr(11, state: "CLOSED")
        byDate.mergedAt = Date()
        #expect(byDate.isMerged)
        #expect(!byDate.isClosedUnmerged)
    }

    @Test("A closed unmerged PR needs a human")
    func closedUnmerged() {
        #expect(pr(11, state: "CLOSED").isClosedUnmerged)
    }

    @Test("Failing checks are pulled out of the rollup")
    func failingChecks() {
        let status = GHMergeStatus(
            state: "OPEN",
            statusCheckRollup: [
                .init(name: "build", conclusion: "SUCCESS"),
                .init(name: "test", conclusion: "FAILURE"),
                .init(context: "legacy-lint", state: "ERROR"),
                .init(name: "pending-one", conclusion: nil, state: "PENDING"),
            ]
        )
        #expect(status.failingChecks == ["test", "legacy-lint"])
        #expect(!status.isMerged)
    }
}
