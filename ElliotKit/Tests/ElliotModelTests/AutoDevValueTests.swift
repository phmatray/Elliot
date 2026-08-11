import Foundation
import Testing

@testable import ElliotModel

/// The transient verdict a policy round produces, and the total mapping onto the row a session's
/// report persists.
///
/// `AutoDevSession`'s own shape is pinned by `AutoDevSessionTests` (PR5's) and is not repeated
/// here — this task declares nothing about it. What this task adds is `Disposition` and
/// `engagement`, so that is what this suite pins.
@Suite("Auto-dev values")
struct AutoDevValueTests {

    private let epoch = Date(timeIntervalSince1970: 1_770_000_000)

    @Test("A disposition's sentence is written once, on the disposition")
    func dispositionRenders() {
        #expect(Disposition.retry.reason == "Moving this card now.")
        #expect(Disposition.wait(reason: "Waiting on CI.").reason == "Waiting on CI.")
        #expect(Disposition.held(.paused).reason == QueueRefusal.paused.sentence)
        #expect(Disposition.settle(.merged, reason: "Merged.").reason == "Merged.")
        #expect(Disposition.abortSession(reason: "Blocked.").reason == "Blocked.")
    }

    @Test("Only settling and aborting settle a card")
    func settledIsTwoCases() {
        #expect(Disposition.settle(.merged, reason: "x").isSettled)
        #expect(Disposition.settle(.blocked, reason: "x").isSettled)
        #expect(Disposition.abortSession(reason: "x").isSettled)
        #expect(Disposition.retry.isSettled == false)
        #expect(Disposition.wait(reason: "x").isSettled == false)
        #expect(Disposition.held(.paused).isSettled == false)
    }

    @Test("A row agrees with its disposition about being settled")
    func rowAgrees() {
        var row = AutoDevEngagement(
            sessionID: UUID(), cardID: UUID(), attempts: 1,
            disposition: .merged, reason: "Merged.", updatedAt: epoch
        )
        #expect(row.isSettled)
        row.disposition = .blocked
        #expect(row.isSettled)
        row.disposition = .engaged
        #expect(row.isSettled == false)
    }

    /// The whole product of this task: every later task writes a row through `engagement`, so a
    /// gap in this switch is a card silently reported as still engaged.
    @Test("A disposition's engagement is total, and settle's outcome passes straight through")
    func engagementIsTotal() {
        #expect(Disposition.retry.engagement == .engaged)
        #expect(Disposition.wait(reason: "x").engagement == .engaged)
        #expect(Disposition.held(.paused).engagement == .engaged)
        #expect(Disposition.settle(.merged, reason: "x").engagement == .merged)
        #expect(Disposition.settle(.blocked, reason: "x").engagement == .blocked)
        #expect(Disposition.abortSession(reason: "x").engagement == .blocked)
    }
}

// MARK: - Disposition.code no longer exists (Task 3 deleted DispositionCode) — file-private
// probes on the case itself, rather than reintroducing a discriminator on the production type.
// `isSettled` stays on `Disposition` because `advance` reads it; none of these four has a
// production reader, and a test helper named `isSettled` meaning only `.settle` would be a second
// thing wearing that name (`.settle` **and** `.abortSession` both make `Disposition.isSettled`
// true).

private func waits(_ d: Disposition) -> Bool { if case .wait = d { return true }; return false }
private func holds(_ d: Disposition) -> Bool { if case .held = d { return true }; return false }
private func settles(_ d: Disposition) -> Bool { if case .settle = d { return true }; return false }
private func aborts(_ d: Disposition) -> Bool {
    if case .abortSession = d { return true }; return false
}

/// Every `MoveBlock`, every `NotGreenReason`, every `PRSign`, and the clock driven by hand.
///
/// Pure and exhaustive: no store, no scheduler, no real time. The two things this suite is
/// actually protecting are a loop that spins for ever and a loop that gives up on work that was
/// going to land.
@Suite("Auto-dev policy")
struct AutoDevPolicyTests {

    private let epoch = Date(timeIntervalSince1970: 1_770_000_000)
    private let patience: TimeInterval = 600

    private func decide(
        _ outcome: MoveOutcome,
        attempts: Int = 0,
        maxAttempts: Int = 3,
        secondsUnchanged: TimeInterval = 0
    ) -> Disposition {
        AutoDevPolicy.disposition(
            outcome: outcome,
            attempts: attempts,
            maxAttempts: maxAttempts,
            unchangedSince: epoch,
            patience: patience,
            now: epoch.addingTimeInterval(secondsUnchanged)
        )
    }

    @Test("An available move is taken, until the attempts run out")
    func actionRetriesThenSettles() {
        #expect(decide(.action(.implementIssue(issueNumber: 47)), attempts: 0) == .retry)
        #expect(decide(.action(.implementIssue(issueNumber: 47)), attempts: 2) == .retry)
        #expect(settles(decide(.action(.implementIssue(issueNumber: 47)), attempts: 3)))
    }

    @Test("A move that fires nothing is still a move, and costs no attempt")
    func noActionAdvances() {
        #expect(decide(.noAction) == .retry)
    }

    @Test("A move that asks a human settles, because no human is watching")
    func needsInputSettles() {
        #expect(settles(decide(.needsInput(.followUps(prNumber: 279)))))
    }

    @Test("A half-written story is never completed by repetition")
    func storyRefusalsSettle() {
        #expect(settles(decide(.blocked(.emptyIdea))))
        #expect(settles(decide(.blocked(.incompleteStory))))
    }

    @Test("A missing number means the step before has not landed yet")
    func missingNumbersWait() {
        #expect(waits(decide(.blocked(.missingIssueNumber))))
        #expect(waits(decide(.blocked(.missingPRNumber))))
        #expect(waits(decide(.blocked(.runAlreadyInFlight(runID: UUID())))))
    }

    @Test("A blocked repository ends the session, not one card — an unknown method is one too")
    func repoRefusalsAbort() {
        #expect(aborts(decide(.blocked(.repoDisabled))))
        #expect(aborts(decide(.blocked(.repoBlocked))))
        #expect(aborts(decide(.blocked(.unknownMethod("gsd-2")))))
    }

    @Test("A transition the loop does not own settles — waiting cannot fix a category error")
    func systemOwnedSettles() {
        #expect(settles(decide(.blocked(.systemOwnedTransition))))
        #expect(settles(decide(.blocked(.sameColumn))))
        #expect(settles(decide(.blocked(.methodHasNoStep(method: "GSD", kind: "merge-pr")))))
    }

    @Test("Checks still running are worth waiting for; a verdict against is not")
    func signsSplitWaitFromSettle() {
        #expect(waits(decide(.blocked(.notVerifiedGreen(reason: .sign(.checksRunning))))))
        #expect(waits(decide(.blocked(.notVerifiedGreen(reason: .sign(.unknown))))))

        for sign: PRSign in [
            .noBuild, .conflict, .changesRequested, .reviewRequired, .mergeBlocked,
            .checksFailing(count: 2),
        ] {
            #expect(settles(decide(.blocked(.notVerifiedGreen(reason: .sign(sign))))))
        }
    }

    /// The cross-task contract override §3 calls out: nothing else pins that the `.sign` arm
    /// renders `sign.summary` verbatim rather than a sentence composed in this file — Task 15's
    /// `aNoChecksPullRequestSettlesBlocked` asserts this exact string separately.
    @Test("The `.sign` arm renders `sign.summary` verbatim")
    func signReasonIsSummaryVerbatim() {
        let outcome = decide(.blocked(.notVerifiedGreen(reason: .sign(.noBuild))))
        #expect(outcome.reason == PRSign.noBuild.summary)
    }

    @Test("No reading waits, an unstable merge waits, and no build verdict settles")
    func notGreenReasonsOtherThanSign() {
        #expect(waits(decide(.blocked(.notVerifiedGreen(reason: .noReading)))))
        #expect(waits(decide(.blocked(.notVerifiedGreen(reason: .notClean(.unstable))))))
        #expect(settles(decide(.blocked(.notVerifiedGreen(reason: .noBuildVerdict)))))
    }

    @Test("Patience bounds every wait, so one stuck CI cannot hold a session open for ever")
    func patienceSettlesAWait() {
        #expect(waits(decide(.blocked(.missingPRNumber), secondsUnchanged: 599)))
        #expect(settles(decide(.blocked(.missingPRNumber), secondsUnchanged: 600)))
        #expect(
            settles(
                decide(
                    .blocked(.notVerifiedGreen(reason: .sign(.checksRunning))),
                    secondsUnchanged: 601)))
    }

    @Test("Patience bounds a held run too — `mergeWaitsForRepoToBeIdle` is the case it exists for")
    func patienceSettlesAHold() {
        let held = AutoDevPolicy.held(
            .mergeWaitsForRepoToBeIdle, unchangedSince: epoch, patience: patience,
            now: epoch.addingTimeInterval(10)
        )
        #expect(holds(held))

        let expired = AutoDevPolicy.held(
            .mergeWaitsForRepoToBeIdle, unchangedSince: epoch, patience: patience,
            now: epoch.addingTimeInterval(patience)
        )
        #expect(settles(expired))
        #expect(expired.reason.contains("merge waits"))
    }

    /// Drives every `MoveBlock` case through `disposition` — which makes the switch's
    /// exhaustiveness observable from the test side — and checks `AutoDevEngagement`'s own
    /// invariant: "never blank: a row with no reason is a row the reader stops at with nothing to
    /// go and do" (`AutoDev.swift:117-118`).
    @Test("Every disposition this policy produces carries a non-empty reason")
    func everyDispositionHasAReason() {
        let blocks: [MoveBlock] = [
            .sameColumn, .emptyIdea, .incompleteStory, .missingIssueNumber, .missingPRNumber,
            .repoDisabled, .repoBlocked, .unknownMethod("gsd-2"),
            .methodHasNoStep(method: "GSD", kind: "merge-pr"), .runAlreadyInFlight(runID: UUID()),
            .notVerifiedGreen(reason: .noReading), .notVerifiedGreen(reason: .sign(.noBuild)),
            .notVerifiedGreen(reason: .notClean(.unstable)),
            .notVerifiedGreen(reason: .noBuildVerdict), .systemOwnedTransition,
        ]
        for block in blocks {
            #expect(!decide(.blocked(block)).reason.isEmpty)
        }
        #expect(!decide(.noAction).reason.isEmpty)
        #expect(!decide(.action(.implementIssue(issueNumber: 1))).reason.isEmpty)
        #expect(!decide(.needsInput(.followUps(prNumber: 1))).reason.isEmpty)
    }
}
