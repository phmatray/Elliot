import Foundation
import Testing

@testable import ElliotModel

private let now = Date(timeIntervalSince1970: 1_700_000_000)

private func card(
    in column: Column = .inProgress,
    issueNumber: Int? = nil,
    issueURL: String? = nil,
    prNumber: Int? = nil,
    prURL: String? = nil,
    branch: String? = nil,
    lastError: String? = nil
) -> Card {
    Card(
        repoID: UUID(),
        title: "A card",
        column: column,
        issueNumber: issueNumber,
        issueURL: issueURL,
        prNumber: prNumber,
        prURL: prURL,
        branch: branch,
        columnEnteredAt: now,
        lastError: lastError,
        createdAt: now,
        updatedAt: now
    )
}

private let prOpenReady = VerifiedOutcome.prOpen(
    number: 7, url: "https://github.com/o/r/pull/7", isDraft: false, branch: "feat/4-thing"
)
private let prOpenDraft = VerifiedOutcome.prOpen(
    number: 7, url: "https://github.com/o/r/pull/7", isDraft: true, branch: "feat/4-thing"
)

/// What a verified outcome does to a card, decided once. The three engine
/// components that used to answer this separately have no switch of their own
/// left, so this suite is the whole specification of that answer.
@Suite("Card outcome")
struct CardOutcomeTests {

    // MARK: - The decision, once — one test per case

    @Test("An issue that was created writes its number and URL, and moves nothing")
    func issueCreated() {
        let subject = card(in: .todo)
        let result = VerifiedOutcome
            .issueCreated(number: 42, url: "https://github.com/o/r/issues/42")
            .applied(to: subject)

        #expect(result.card.issueNumber == 42)
        #expect(result.card.issueURL == "https://github.com/o/r/issues/42")
        #expect(result.card.lastError == nil)
        #expect(result.move == nil)
        #expect(result.changed)
    }

    @Test("An issue that was deliberately not created is a reason on the card, not a move")
    func noIssueCreated() {
        let result = VerifiedOutcome
            .noIssueCreated(reason: "Already covered by #12")
            .applied(to: card(in: .todo))

        #expect(result.card.lastError == "Already covered by #12")
        #expect(result.card.issueNumber == nil)
        #expect(result.move == nil)
        #expect(result.changed)
    }

    @Test("A ready pull request writes its three fields and sends an In Progress card to In Review")
    func prOpenReadyFromInProgress() {
        let result = prOpenReady.applied(to: card(in: .inProgress))

        #expect(result.card.prNumber == 7)
        #expect(result.card.prURL == "https://github.com/o/r/pull/7")
        #expect(result.card.branch == "feat/4-thing")
        #expect(result.card.lastError == nil)
        #expect(result.move == .init(column: .inReview, reason: .prBecameReady))
        #expect(result.changed)
    }

    @Test("A draft pull request writes its fields but implies no move")
    func prOpenDraftDoesNotMove() {
        let result = prOpenDraft.applied(to: card(in: .inProgress))

        #expect(result.card.prNumber == 7)
        #expect(result.card.branch == "feat/4-thing")
        #expect(result.move == nil)
        #expect(result.changed)
    }

    @Test("A ready pull request on a card already in In Review writes its fields and implies no move")
    func prOpenOnACardAlreadyInReview() {
        let result = prOpenReady.applied(to: card(in: .inReview))

        #expect(result.card.prNumber == 7)
        #expect(result.card.branch == "feat/4-thing")
        #expect(result.move == nil)
        #expect(result.changed)
    }

    @Test("A merged pull request sends the card to Done and writes no field it was not given")
    func mergedMovesToDone() {
        let subject = card(in: .inReview, prNumber: 7)
        let result = VerifiedOutcome
            .merged(commitSHA: "abc1234", number: nil, url: nil, branch: nil)
            .applied(to: subject)

        #expect(result.move == .init(column: .done, reason: .prMergedExternally))
        #expect(result.card.prNumber == 7)
        #expect(result.card.lastError == nil)
        #expect(result.changed)
    }

    @Test("A merged pull request first seen already merged records which one it was")
    func mergedNamesItsPullRequest() {
        let subject = card(in: .inProgress, issueNumber: 7)
        let result = VerifiedOutcome
            .merged(commitSHA: nil, number: 42, url: "https://github.com/o/r/pull/42", branch: "feat/7-x")
            .applied(to: subject)

        #expect(result.card.prNumber == 42)
        #expect(result.card.prURL == "https://github.com/o/r/pull/42")
        #expect(result.card.branch == "feat/7-x")
        #expect(result.move == .init(column: .done, reason: .prMergedExternally))
        #expect(result.changed)
    }

    @Test("A pull request that is not merged is a reason on the card, not a move")
    func notMerged() {
        let result = VerifiedOutcome
            .notMerged(reason: "CI is red")
            .applied(to: card(in: .inReview))

        #expect(result.card.lastError == "CI is red")
        #expect(result.move == nil)
        #expect(result.changed)
    }

    @Test("An outcome gh could not establish is a reason on the card, not a move")
    func unverified() {
        let result = VerifiedOutcome
            .unverified(reason: "gh is unavailable")
            .applied(to: card(in: .inProgress))

        #expect(result.card.lastError == "gh is unavailable")
        #expect(result.move == nil)
        #expect(result.changed)
    }

    @Test("A pull request closed without merging says so, in the one wording there is")
    func closedUnmerged() {
        let result = VerifiedOutcome
            .closedUnmerged(number: nil, url: nil, branch: nil)
            .applied(to: card(in: .inReview))

        #expect(result.card.lastError == "The pull request was closed without being merged.")
        #expect(result.move == nil)
        #expect(result.changed)
    }

    @Test("A closed-unmerged pull request records which one it was, and still says so")
    func closedUnmergedNamesItsPullRequest() {
        let subject = card(in: .inProgress, issueNumber: 7)
        let result = VerifiedOutcome
            .closedUnmerged(number: 42, url: "https://github.com/o/r/pull/42", branch: "feat/7-x")
            .applied(to: subject)

        #expect(result.card.prNumber == 42)
        #expect(result.card.prURL == "https://github.com/o/r/pull/42")
        #expect(result.card.branch == "feat/7-x")
        // The fields arrive *alongside* the banner, not instead of it.
        #expect(result.card.lastError == "The pull request was closed without being merged.")
        #expect(result.move == nil)
        #expect(result.changed)
    }

    // MARK: - A `nil` field never clears one the card already carries

    @Test("A merged outcome offering nothing leaves the fields the card already had")
    func mergedWithNoFieldsPreservesWhatTheCardHas() {
        let subject = card(
            in: .inReview, prNumber: 7, prURL: "https://github.com/o/r/pull/7", branch: "feat/4-thing"
        )
        let result = VerifiedOutcome
            .merged(commitSHA: "abc1234", number: nil, url: nil, branch: nil)
            .applied(to: subject)

        #expect(result.card.prNumber == 7)
        #expect(result.card.prURL == "https://github.com/o/r/pull/7")
        #expect(result.card.branch == "feat/4-thing")
        #expect(result.move == .init(column: .done, reason: .prMergedExternally))
    }

    @Test("A closed-unmerged outcome offering nothing leaves the fields the card already had")
    func closedUnmergedWithNoFieldsPreservesWhatTheCardHas() {
        let subject = card(
            in: .inReview, prNumber: 7, prURL: "https://github.com/o/r/pull/7", branch: "feat/4-thing"
        )
        let result = VerifiedOutcome
            .closedUnmerged(number: nil, url: nil, branch: nil)
            .applied(to: subject)

        #expect(result.card.prNumber == 7)
        #expect(result.card.prURL == "https://github.com/o/r/pull/7")
        #expect(result.card.branch == "feat/4-thing")
    }

    @Test("Each field is written on its own — a partial offer fills only what it names")
    func fieldsAreWrittenIndependently() {
        let subject = card(in: .inReview, prNumber: 7, branch: "feat/4-thing")
        let result = VerifiedOutcome
            .merged(commitSHA: nil, number: nil, url: "https://github.com/o/r/pull/7", branch: nil)
            .applied(to: subject)

        #expect(result.card.prURL == "https://github.com/o/r/pull/7")
        #expect(result.card.prNumber == 7)
        #expect(result.card.branch == "feat/4-thing")
    }

    // MARK: - Clearing the error (AC3, AC4)

    @Test("A success clears the error the failed run left behind")
    func successClearsLastError() {
        let failed = card(in: .inProgress, lastError: "implement-issue exited 1")

        let created = VerifiedOutcome
            .issueCreated(number: 42, url: "https://github.com/o/r/issues/42")
            .applied(to: failed)
        #expect(created.card.lastError == nil)

        let opened = prOpenReady.applied(to: failed)
        #expect(opened.card.lastError == nil)

        let merged = VerifiedOutcome.merged(commitSHA: nil, number: nil, url: nil, branch: nil).applied(to: failed)
        #expect(merged.card.lastError == nil)
    }

    @Test("Even a draft pull request clears the error — the draft's existence disproves it")
    func draftAlsoClearsLastError() {
        let failed = card(in: .inProgress, lastError: "implement-issue exited 1")
        #expect(prOpenDraft.applied(to: failed).card.lastError == nil)
    }

    // MARK: - `changed`

    @Test("A merged pull request on a card already in Done changes nothing at all")
    func mergedOnADoneCardIsANoOp() {
        let subject = card(in: .done, prNumber: 7)
        let result = VerifiedOutcome.merged(commitSHA: nil, number: nil, url: nil, branch: nil).applied(to: subject)

        #expect(result.move == nil)
        #expect(result.card == subject)
        #expect(!result.changed)
    }

    @Test("Re-writing the fields a card already carries changes nothing")
    func rewritingIdenticalFieldsIsANoOp() {
        let subject = card(
            in: .inReview, prNumber: 7, prURL: "https://github.com/o/r/pull/7", branch: "feat/4-thing"
        )
        let result = prOpenReady.applied(to: subject)

        #expect(result.card == subject)
        #expect(result.move == nil)
        #expect(!result.changed)
    }

    @Test("Re-stating the same failure reason changes nothing")
    func repeatingTheSameReasonIsANoOp() {
        let subject = card(in: .inReview, lastError: "CI is red")
        let result = VerifiedOutcome.notMerged(reason: "CI is red").applied(to: subject)

        #expect(result.card == subject)
        #expect(!result.changed)
    }

    @Test("An issue whose number is known but whose URL has changed still writes the URL")
    func issueURLIsWrittenEvenWhenTheNumberMatches() {
        let subject = card(in: .todo, issueNumber: 42, issueURL: "https://old.example/42")
        let result = VerifiedOutcome
            .issueCreated(number: 42, url: "https://github.com/o/r/issues/42")
            .applied(to: subject)

        #expect(result.card.issueURL == "https://github.com/o/r/issues/42")
        #expect(result.changed)
    }

    @Test("The pure function never stamps updatedAt — the store owns that")
    func updatedAtIsUntouched() {
        let subject = card(in: .inProgress)
        let result = prOpenReady.applied(to: subject)
        #expect(result.card.updatedAt == subject.updatedAt)
    }

    // MARK: - Attribution

    @Test("Watching the world move records prBecameReady and prMergedExternally")
    func liveAttribution() {
        #expect(
            prOpenReady.applied(to: card(in: .inProgress), attribution: .live).move
                == .init(column: .inReview, reason: .prBecameReady)
        )
        #expect(
            VerifiedOutcome.merged(commitSHA: nil, number: nil, url: nil, branch: nil)
                .applied(to: card(in: .inReview), attribution: .live).move
                == .init(column: .done, reason: .prMergedExternally)
        )
    }

    @Test("Catching up at launch records reconciliation on both moving cases")
    func launchSweepAttribution() {
        #expect(
            prOpenReady.applied(to: card(in: .inProgress), attribution: .launchSweep).move
                == .init(column: .inReview, reason: .reconciliation)
        )
        #expect(
            VerifiedOutcome.merged(commitSHA: nil, number: nil, url: nil, branch: nil)
                .applied(to: card(in: .inReview), attribution: .launchSweep).move
                == .init(column: .done, reason: .reconciliation)
        )
    }

    @Test("Attribution defaults to live — the launch sweep is the caller that must say so")
    func attributionDefaultsToLive() {
        #expect(prOpenReady.applied(to: card(in: .inProgress)).move?.reason == .prBecameReady)
    }

    @Test("Attribution changes only the reason, never whether there is a move")
    func attributionDoesNotCreateOrSuppressMoves() {
        #expect(prOpenDraft.applied(to: card(in: .inProgress), attribution: .launchSweep).move == nil)
        #expect(
            VerifiedOutcome.merged(commitSHA: nil, number: nil, url: nil, branch: nil)
                .applied(to: card(in: .done), attribution: .launchSweep).move == nil
        )
    }
}
