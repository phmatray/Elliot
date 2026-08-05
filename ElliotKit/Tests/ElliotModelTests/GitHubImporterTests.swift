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

private func card(
    repoID: UUID, title: String = "Some work", column: Column = .todo,
    issueNumber: Int? = nil, prNumber: Int? = nil
) -> Card {
    let t = Date(timeIntervalSince1970: 0)
    return Card(
        repoID: repoID, title: title, column: column,
        issueNumber: issueNumber, prNumber: prNumber,
        columnEnteredAt: t, createdAt: t, updatedAt: t)
}

@Suite("GitHub importer — the plan")
struct GitHubImporterPlanTests {
    let repoID = UUID()
    let now = Date(timeIntervalSince1970: 1_700_000_000)

    @Test("An empty board plans one creation per unit")
    func createsEverythingOnAnEmptyBoard() {
        let plan = GitHubImporter.plan(
            repoID: repoID, issues: [issue(11), issue(12)],
            pullRequests: [pullRequest(20, branch: "feat/11-x")],
            existingCards: [], dismissed: [], now: now)
        #expect(plan.actions.count == 2)
        #expect(plan.actions.allSatisfy { if case .create = $0 { true } else { false } })
    }

    @Test("Planning twice is the whole feature: the second pass changes nothing")
    func isIdempotent() {
        let issues = [issue(11), issue(12)]
        let prs = [pullRequest(20, branch: "feat/11-x")]
        let first = GitHubImporter.plan(
            repoID: repoID, issues: issues, pullRequests: prs,
            existingCards: [], dismissed: [], now: now)
        // Materialise the seeds the way the store would.
        let cards: [Card] = first.actions.compactMap {
            guard case .create(let s) = $0 else { return nil }
            return Card(
                repoID: s.repoID, title: s.title, body: s.body, column: s.column,
                issueNumber: s.issueNumber, issueURL: s.issueURL,
                prNumber: s.prNumber, prURL: s.prURL, branch: s.branch,
                columnEnteredAt: now, createdAt: s.createdAt, updatedAt: now)
        }
        let second = GitHubImporter.plan(
            repoID: repoID, issues: issues, pullRequests: prs,
            existingCards: cards, dismissed: [], now: now)
        #expect(second.actions.allSatisfy { if case .unchanged = $0 { true } else { false } })
    }

    @Test("A card already carrying the issue is adopted, never duplicated")
    func adoptsRatherThanDuplicates() {
        let existing = card(repoID: repoID, title: "stale label", issueNumber: 11)
        let plan = GitHubImporter.plan(
            repoID: repoID, issues: [issue(11, title: "Tree layout")], pullRequests: [],
            existingCards: [existing], dismissed: [], now: now)
        guard case .adopt(let id, let fields, _) = plan.actions.first else {
            Issue.record("expected an adopt")
            return
        }
        #expect(id == existing.id)
        #expect(fields.title == "Tree layout")
    }

    @Test("Ownership is permanent: a PR stays on the card that already holds it")
    func ownershipIsFirstComeAndPermanent() {
        // The standalone card owns PR 20. The PR now also closes issue 11,
        // which has its own card. PR 20 must not be claimed twice.
        let prCard = card(repoID: repoID, column: .inReview, prNumber: 20)
        let issueCard = card(repoID: repoID, column: .todo, issueNumber: 11)
        let plan = GitHubImporter.plan(
            repoID: repoID, issues: [issue(11)],
            pullRequests: [pullRequest(20, branch: "feat/11-x")],
            existingCards: [prCard, issueCard], dismissed: [], now: now)
        let assigned = plan.actions.compactMap { action -> UUID? in
            guard case .adopt(let id, let f, _) = action, f.prNumber == 20 else { return nil }
            return id
        }
        #expect(assigned == [prCard.id])
    }

    @Test("Split ownership stays split: neither number is claimed twice")
    func splitOwnershipClaimsNothingTwice() {
        // The mirror of the case above, and the reason preferring one ref over
        // the other is not a fix: whichever card is looked up first, the *other*
        // number must not follow it. Each card keeps exactly what it held.
        let prCard = card(repoID: repoID, column: .inReview, prNumber: 20)
        let issueCard = card(repoID: repoID, column: .todo, issueNumber: 11)
        let plan = GitHubImporter.plan(
            repoID: repoID, issues: [issue(11)],
            pullRequests: [pullRequest(20, branch: "feat/11-x")],
            existingCards: [prCard, issueCard], dismissed: [], now: now)

        var claimed: [ExternalRef: [UUID]] = [:]
        for case .adopt(let id, let f, _) in plan.actions {
            if let n = f.issueNumber { claimed[ExternalRef(kind: .issue, number: n), default: []].append(id) }
            if let n = f.prNumber { claimed[ExternalRef(kind: .pullRequest, number: n), default: []].append(id) }
        }
        #expect(claimed[ExternalRef(kind: .issue, number: 11)] == [issueCard.id])
        #expect(claimed[ExternalRef(kind: .pullRequest, number: 20)] == [prCard.id])
    }

    @Test("Import advances a card and never rewinds it")
    func neverRewinds() {
        // In Progress with a run in flight; this pass sees no pull request yet.
        let existing = card(repoID: repoID, column: .inProgress, issueNumber: 11)
        let plan = GitHubImporter.plan(
            repoID: repoID, issues: [issue(11)], pullRequests: [],
            existingCards: [existing], dismissed: [], now: now)
        for action in plan.actions {
            if case .adopt(_, _, let moveTo) = action { #expect(moveTo == nil) }
        }
    }

    @Test("Import does move a card forward")
    func advancesForward() {
        let existing = card(repoID: repoID, column: .todo, issueNumber: 11)
        let plan = GitHubImporter.plan(
            repoID: repoID, issues: [issue(11)],
            pullRequests: [pullRequest(20, branch: "feat/11-x")],
            existingCards: [existing], dismissed: [], now: now)
        guard case .adopt(_, _, let moveTo) = plan.actions.first else {
            Issue.record("expected an adopt")
            return
        }
        #expect(moveTo == .inReview)
    }

    @Test("A dismissed issue is skipped and counted")
    func skipsDismissed() {
        let plan = GitHubImporter.plan(
            repoID: repoID, issues: [issue(4, title: "Dependency Dashboard"), issue(11)],
            pullRequests: [], existingCards: [],
            dismissed: [ExternalRef(kind: .issue, number: 4)], now: now)
        #expect(plan.actions.count == 1)
        #expect(plan.skippedDismissed == 1)
    }

    @Test("A seed carries the issue's age but enters its column now")
    func timestamps() {
        let created = Date(timeIntervalSince1970: 1_600_000_000)
        let plan = GitHubImporter.plan(
            repoID: repoID, issues: [issue(11, createdAt: created)], pullRequests: [],
            existingCards: [], dismissed: [], now: now)
        guard case .create(let seed) = plan.actions.first else {
            Issue.record("expected a create")
            return
        }
        #expect(seed.createdAt == created)
    }
}
