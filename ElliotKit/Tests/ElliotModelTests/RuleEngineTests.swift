import Foundation
import Testing

@testable import ElliotModel

private let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)
private let repoID = UUID(uuidString: "00000000-0000-0000-0000-0000000000AA")!

private func makeCard(
    title: String = "Add a dark mode toggle",
    body: String = "",
    column: Column = .backlog,
    issueNumber: Int? = nil,
    prNumber: Int? = nil
) -> Card {
    Card(
        repoID: repoID,
        title: title,
        body: body,
        column: column,
        issueNumber: issueNumber,
        prNumber: prNumber,
        columnEnteredAt: fixedDate,
        createdAt: fixedDate,
        updatedAt: fixedDate
    )
}

/// The three transitions that fire a skill, and nothing else does.
private let triggerTransitions: Set<[Column]> = [
    [.backlog, .todo],
    [.todo, .inProgress],
    [.inReview, .done],
]

/// The context every test in this file that is *not* about the green guard
/// wants: a move somebody is watching, with no reading of a pull request.
///
/// `MoveContext` deliberately defaults nothing for the last two parameters —
/// that is the guard on production call sites, and it is doing its job here by
/// having forced this file to state an answer once. Written once rather than
/// twenty times so the suite stays about the rules.
private func watched(
    repoIsEnabled: Bool = true,
    activeRunID: UUID? = nil,
    allowSideEffects: Bool = true,
    providedFollowUps: [String]? = nil
) -> MoveContext {
    MoveContext(
        repoIsEnabled: repoIsEnabled,
        activeRunID: activeRunID,
        allowSideEffects: allowSideEffects,
        providedFollowUps: providedFollowUps,
        requiresVerifiedGreen: false,
        prVerdict: nil
    )
}

/// A resolved reading, built directly. `sign` is stated rather than derived:
/// deriving it is `PRStatus.sign`'s job and is tested in `PRStatusTests`.
private func verdict(
    ci: CIState = .passing(["build-and-test"]),
    merge: MergeState = .clean,
    review: ReviewState = .approved,
    isStale: Bool = false,
    sign: PRSign? = nil
) -> ResolvedPRStatus {
    ResolvedPRStatus(
        ci: ci, merge: merge, review: review,
        checkedAt: fixedDate, headRefOid: "a1b2c3d4e5f6", isStale: isStale, sign: sign)
}

/// The context an unattended caller builds: nobody to ask, so follow-ups are an
/// explicit "none", and the verdict is whatever `gh` established.
private func unattended(_ prVerdict: ResolvedPRStatus?) -> MoveContext {
    MoveContext(
        repoIsEnabled: true,
        activeRunID: nil,
        allowSideEffects: true,
        providedFollowUps: [],
        requiresVerifiedGreen: true,
        prVerdict: prVerdict
    )
}

/// One row of the merge matrix.
///
/// A named struct rather than a tuple: swift-testing wants `arguments:` to be a
/// `Sendable` collection of `Sendable` elements, and a struct also puts a
/// readable name in the failure message, which a positional tuple does not.
private struct MergeReading: Sendable, CustomStringConvertible {
    var name: String
    var verdict: ResolvedPRStatus?
    var merges: Bool

    var description: String { name }
}

/// Every reading a merge can be asked to act on, and what it must answer.
///
/// Eight signs, plus a green with no sign, plus a stale reading, plus no
/// reading at all — not three cases. `PRSign` is not `CaseIterable`, so this is
/// written out; `MergeableUnattendedTests` is where the predicate itself is
/// cornered, and this is where the *rule* is.
private let mergeReadings: [MergeReading] = [
    MergeReading(name: "green", verdict: verdict(), merges: true),
    MergeReading(name: "conflict", verdict: verdict(sign: .conflict), merges: false),
    MergeReading(name: "checksFailing", verdict: verdict(sign: .checksFailing(count: 2)), merges: false),
    MergeReading(name: "changesRequested", verdict: verdict(sign: .changesRequested), merges: false),
    MergeReading(name: "reviewRequired", verdict: verdict(sign: .reviewRequired), merges: false),
    MergeReading(name: "mergeBlocked", verdict: verdict(sign: .mergeBlocked), merges: false),
    MergeReading(name: "checksRunning", verdict: verdict(sign: .checksRunning), merges: false),
    MergeReading(name: "noBuild", verdict: verdict(sign: .noBuild), merges: false),
    MergeReading(name: "unknown", verdict: verdict(sign: .unknown), merges: false),
    MergeReading(name: "stale", verdict: verdict(isStale: true), merges: false),
    MergeReading(name: "nothing read", verdict: nil, merges: false),
]

@Suite("Rule engine")
struct RuleEngineTests {

    // MARK: - The three active transitions

    @Test("Backlog to To Do files an issue from a plain card's title and body")
    func backlogToTodoCreatesIssue() {
        let card = makeCard(title: "Add a dark mode toggle", body: "Respect the system setting.")
        let outcome = evaluateMove(from: .backlog, to: .todo, card: card, context: watched())
        #expect(outcome == .action(.createIssue(
            idea: "Add a dark mode toggle. Respect the system setting."
        )))
    }

    @Test("A story card files its narrative and criteria, not its board label")
    func backlogToTodoUsesTheStory() {
        var card = makeCard(title: "Run log")
        card.story = UserStory(
            role: "developer",
            want: "to see the run log inside the card",
            benefit: "I can diagnose a failure without opening a terminal",
            acceptanceCriteria: ["the log streams live", "the log survives a relaunch"]
        )
        let outcome = evaluateMove(from: .backlog, to: .todo, card: card, context: watched())
        #expect(outcome == .action(.createIssue(
            idea: "As a developer, I want to see the run log inside the card, so that I can "
                + "diagnose a failure without opening a terminal. Acceptance criteria: "
                + "1) the log streams live 2) the log survives a relaunch"
        )))
    }

    @Test("A story missing one of its three parts is refused before it reaches the skill")
    func incompleteStoryBlocked() {
        var card = makeCard(title: "Run log")
        card.story = UserStory(role: "developer", want: "to see the run log", benefit: "  ")
        let outcome = evaluateMove(from: .backlog, to: .todo, card: card, context: watched())
        #expect(outcome == .blocked(.incompleteStory))
    }

    @Test("To Do to In Progress implements the card's issue")
    func todoToInProgressImplements() {
        let card = makeCard(column: .todo, issueNumber: 47)
        let outcome = evaluateMove(from: .todo, to: .inProgress, card: card, context: watched())
        #expect(outcome == .action(.implementIssue(issueNumber: 47)))
    }

    @Test("In Review to Done merges once follow-ups are settled")
    func inReviewToDoneMerges() {
        let card = makeCard(column: .inReview, prNumber: 279)
        let context = watched(providedFollowUps: ["add snapshot tests"])
        let outcome = evaluateMove(from: .inReview, to: .done, card: card, context: context)
        #expect(outcome == .action(.mergePR(prNumber: 279, followUps: ["add snapshot tests"])))
    }

    @Test("In Progress to In Review fires nothing — implement-issue already did the work")
    func inProgressToInReviewIsInert() {
        let card = makeCard(column: .inProgress, issueNumber: 47, prNumber: 279)
        let outcome = evaluateMove(from: .inProgress, to: .inReview, card: card, context: watched())
        #expect(outcome == .noAction)
    }

    // MARK: - Refusals

    @Test("A move to the same column is refused")
    func sameColumnBlocked() {
        for column in Column.allCases {
            let outcome = evaluateMove(
                from: column, to: column, card: makeCard(column: column), context: watched()
            )
            #expect(outcome == .blocked(.sameColumn))
        }
    }

    @Test("Implementing without an issue number is refused")
    func todoToInProgressWithoutIssue() {
        let card = makeCard(column: .todo, issueNumber: nil)
        let outcome = evaluateMove(from: .todo, to: .inProgress, card: card, context: watched())
        #expect(outcome == .blocked(.missingIssueNumber))
    }

    @Test("Merging without a PR number is refused")
    func inReviewToDoneWithoutPR() {
        let card = makeCard(column: .inReview, prNumber: nil)
        let context = watched(providedFollowUps: [])
        let outcome = evaluateMove(from: .inReview, to: .done, card: card, context: context)
        #expect(outcome == .blocked(.missingPRNumber))
    }

    @Test("A card with nothing in it cannot become an issue", arguments: ["", "   ", "\n\t "])
    func backlogToTodoWithBlankIdea(title: String) {
        let card = makeCard(title: title, body: "")
        let outcome = evaluateMove(from: .backlog, to: .todo, card: card, context: watched())
        #expect(outcome == .blocked(.emptyIdea))
    }

    @Test("A disabled repo refuses every move")
    func disabledRepoBlocks() {
        let context = watched(repoIsEnabled: false)
        let card = makeCard(column: .todo, issueNumber: 47)
        let outcome = evaluateMove(from: .todo, to: .inProgress, card: card, context: context)
        #expect(outcome == .blocked(.repoDisabled))
    }

    @Test("A card with a run in flight refuses every move")
    func activeRunBlocks() {
        let runID = UUID()
        let context = watched(activeRunID: runID)
        let card = makeCard(column: .todo, issueNumber: 47)
        let outcome = evaluateMove(from: .todo, to: .inProgress, card: card, context: context)
        #expect(outcome == .blocked(.runAlreadyInFlight(runID: runID)))
    }

    // MARK: - Re-filing guard

    @Test("A card that already has an issue is not filed again")
    func backlogToTodoWithExistingIssueIsInert() {
        let card = makeCard(issueNumber: 47)
        let outcome = evaluateMove(from: .backlog, to: .todo, card: card, context: watched())
        #expect(outcome == .noAction)
    }

    // MARK: - Follow-ups

    @Test("Merging asks for follow-ups when they have not been collected")
    func inReviewToDoneNeedsFollowUps() {
        let card = makeCard(column: .inReview, prNumber: 279)
        let context = watched(providedFollowUps: nil)
        let outcome = evaluateMove(from: .inReview, to: .done, card: card, context: context)
        #expect(outcome == .needsInput(.followUps(prNumber: 279)))
    }

    @Test("An explicit empty follow-up list means 'none', and merges")
    func emptyFollowUpsIsAnAnswer() {
        let card = makeCard(column: .inReview, prNumber: 279)
        let context = watched(providedFollowUps: [])
        let outcome = evaluateMove(from: .inReview, to: .done, card: card, context: context)
        #expect(outcome == .action(.mergePR(prNumber: 279, followUps: [])))
    }

    // MARK: - The system-move invariant

    @Test(
        "A system move never triggers a skill",
        arguments: Column.allCases, Column.allCases
    )
    func systemMovesNeverTrigger(from: Column, to: Column) {
        // Fully-populated card: every trigger's precondition is satisfied, so
        // only `allowSideEffects` can be what holds the action back.
        let card = makeCard(column: from, issueNumber: 47, prNumber: 279)
        let context = watched(allowSideEffects: false, providedFollowUps: [])
        let outcome = evaluateMove(from: from, to: to, card: card, context: context)

        if from == to {
            #expect(outcome == .blocked(.sameColumn))
        } else {
            #expect(outcome == .noAction)
        }
    }

    @Test("A system move is not held back by an in-flight run")
    func systemMoveIgnoresActiveRun() {
        // The PR watcher sees the PR go ready while implement-issue is still
        // wrapping up. That move must land, not wait for the run to exit.
        let card = makeCard(column: .inProgress, issueNumber: 47, prNumber: 279)
        let context = watched(activeRunID: UUID(), allowSideEffects: false)
        let outcome = evaluateMove(from: .inProgress, to: .inReview, card: card, context: context)
        #expect(outcome == .noAction)
    }

    // MARK: - Exhaustive matrix

    @Test(
        "Only the three declared transitions ever produce an action",
        arguments: Column.allCases, Column.allCases
    )
    func onlyDeclaredTransitionsAct(from: Column, to: Column) {
        let card = makeCard(column: from, issueNumber: 47, prNumber: 279)
        let context = watched(providedFollowUps: [])
        let outcome = evaluateMove(from: from, to: to, card: card, context: context)

        let isTrigger = triggerTransitions.contains([from, to])
        switch outcome {
        case .action:
            #expect(isTrigger, "\(from) → \(to) produced an action but is not a declared trigger")
        case .noAction:
            // backlog → todo on a card that already has an issue is a declared
            // trigger that correctly declines to re-file.
            #expect(!isTrigger || [from, to] == [.backlog, .todo])
        case .blocked(let block):
            #expect(from == to && block == .sameColumn)
        case .needsInput:
            Issue.record("\(from) → \(to) asked for input despite follow-ups being supplied")
        }
    }

    @Test(
        "Every transition is decided — no crash, no ambiguity",
        arguments: Column.allCases, Column.allCases
    )
    func totality(from: Column, to: Column) {
        // A bare card: no issue, no PR, nothing collected. Exercises the
        // refusal paths across the whole matrix.
        let card = makeCard(column: from)
        _ = evaluateMove(from: from, to: to, card: card, context: watched())
    }

    // MARK: - `NotGreenReason.of`

    @Test("No reading at all, and a reading that has aged out, both answer noReading")
    func notGreenReasonNoReading() {
        #expect(NotGreenReason.of(nil) == .noReading)
        #expect(NotGreenReason.of(verdict(isStale: true)) == .noReading)
    }

    @Test("A stale reading outranks a sign it would otherwise carry")
    func notGreenReasonStaleOutranksSign() {
        // Built directly with both set: `sign` is stated rather than derived
        // in this file, so this combination need not be one `PRStatus.resolved`
        // would ever produce. The point is the *order* `of` checks in.
        let reading = verdict(merge: .conflict, isStale: true, sign: .conflict)
        #expect(NotGreenReason.of(reading) == .noReading)
    }

    @Test("A sign outranks an unclean merge state")
    func notGreenReasonSignOutranksNotClean() {
        let reading = verdict(merge: .behind, sign: .reviewRequired)
        #expect(NotGreenReason.of(reading) == .sign(.reviewRequired))
    }

    @Test("An unclean merge state with no sign names the merge state")
    func notGreenReasonNotClean() {
        // `.unstable` is the state `PRStatus.sign` deliberately lets through as
        // `nil` — `isMergeableUnattended`'s reason 1 — so it is the merge state
        // that reaches here with `sign == nil` in practice.
        let reading = verdict(merge: .unstable, sign: nil)
        #expect(NotGreenReason.of(reading) == .notClean(.unstable))
    }

    @Test("Clean, unsigned, analyser-only checks: the one remaining claim is no build verdict")
    func notGreenReasonNoBuildVerdict() {
        // `isMergeableUnattended`'s reason 2: every passing check is an
        // analyser. Tied to the predicate itself rather than a hand-copied
        // restatement of its conjuncts — a restatement would keep passing if a
        // fifth conjunct were ever added and `.noBuildVerdict` started lying.
        // The tripwire is the flip: the same reading, given one real build
        // check, must become mergeable (the shape `analyserOnlyGreenRefuses`
        // in `MergeableUnattendedTests` already uses).
        let reading = verdict(ci: .passing(["CodeQL"]), merge: .clean, isStale: false, sign: nil)
        #expect(!reading.isMergeableUnattended)
        #expect(verdict(ci: .passing(["build-and-test"])).isMergeableUnattended)
        #expect(NotGreenReason.of(reading) == .noBuildVerdict)
    }

    // MARK: - The unattended guard

    @Test(
        "A merge that requires a verified green answers the whole PRSign matrix",
        arguments: mergeReadings)
    fileprivate func mergeUnderTheGreenGuard(reading: MergeReading) {
        let card = makeCard(column: .inReview, prNumber: 279)
        let outcome = evaluateMove(
            from: .inReview, to: .done, card: card, context: unattended(reading.verdict))

        if reading.merges {
            #expect(
                outcome == .action(.mergePR(prNumber: 279, followUps: [])),
                "\(reading.name) should have merged, got \(outcome)")
        } else {
            #expect(
                outcome == .blocked(.notVerifiedGreen(reason: NotGreenReason.of(reading.verdict))),
                "\(reading.name) should have been refused, got \(outcome)")
        }
    }

    @Test(
        "A watched merge is not held to a verified green, on the same readings",
        arguments: mergeReadings)
    fileprivate func watchedMergeIgnoresTheVerdict(reading: MergeReading) {
        // The other half, and the reason the field is named for the rule rather
        // than for the caller: a person dragging a card onto Done has read the
        // pull request themselves and is entitled to merge a red one.
        let card = makeCard(column: .inReview, prNumber: 279)
        var context = watched(providedFollowUps: [])
        context.prVerdict = reading.verdict
        let outcome = evaluateMove(from: .inReview, to: .done, card: card, context: context)

        #expect(outcome == .action(.mergePR(prNumber: 279, followUps: [])), "\(reading.name)")
    }

    @Test("A missing pull request number outranks the green guard")
    func missingPRNumberIsStillTheFirstAnswer() {
        // Order matters: refusing "not a verified green" on a card that has no
        // pull request at all would send the reader to look at CI for something
        // that does not exist.
        let card = makeCard(column: .inReview, prNumber: nil)
        let outcome = evaluateMove(from: .inReview, to: .done, card: card, context: unattended(nil))
        #expect(outcome == .blocked(.missingPRNumber))
    }

    @Test("In Progress to In Review is refused outright for a caller that has no human")
    func inProgressToInReviewIsSystemOwned() {
        // Elliot fills this column itself, when `PRWatcher` sees the pull
        // request go ready. A caller requiring a verified green asking for it is
        // asking to skip the pull request entirely — and `arrivalNote` could not
        // explain such an arrival, since the note it would need is about a
        // reason nobody supplied.
        let card = makeCard(column: .inProgress, issueNumber: 47, prNumber: 279)
        let outcome = evaluateMove(
            from: .inProgress, to: .inReview, card: card, context: unattended(verdict()))
        #expect(outcome == .blocked(.systemOwnedTransition))

        // Unchanged for everyone else: it still moves the card and runs nothing.
        let watchedOutcome = evaluateMove(
            from: .inProgress, to: .inReview, card: card, context: watched())
        #expect(watchedOutcome == .noAction)
    }

    /// The twin of `systemMovesNeverTrigger`, and built the same way: the same
    /// 25 transitions, the same fully-populated card, one field of the context
    /// changed.
    ///
    /// `.needsInput` is information "only a human (or an explicit tool argument)
    /// can supply". A caller with no human can read it only as "blocked, I will
    /// try again", which is a loop that spins — so the answer to a caller that
    /// requires a verified green is never a question.
    ///
    /// It survives a `.needsInput` added to some *other* transition later, which
    /// one assertion inside the merge branch could not.
    @Test(
        "A move that requires a verified green is never asked for input",
        arguments: Column.allCases, Column.allCases
    )
    func unattendedMovesAreNeverAskedForInput(from: Column, to: Column) {
        let card = makeCard(column: from, issueNumber: 47, prNumber: 279)
        let outcome = evaluateMove(from: from, to: to, card: card, context: unattended(verdict()))

        if case .needsInput(let need) = outcome {
            Issue.record("\(from) → \(to) asked an unattended caller for \(need)")
        }
    }

    /// The one input under which the invariant above is *not* structural, named
    /// rather than left for someone to trip over.
    @Test("An unattended caller that collected no follow-up list is still asked for one")
    func theOneRemainingQuestion() {
        // `providedFollowUps: nil` means "not collected yet", and the green
        // guard sits before it: every refusal an unattended caller can meet is a
        // `.blocked`, but a *green* pull request with no list still produces the
        // question. `AutoDevService` therefore always passes `followUps: []` —
        // merge, filing nothing of its own — and this is the measurement that
        // says why that is a requirement on the caller and not a nicety.
        let card = makeCard(column: .inReview, prNumber: 279)
        var context = unattended(verdict())
        context.providedFollowUps = nil
        #expect(
            evaluateMove(from: .inReview, to: .done, card: card, context: context)
                == .needsInput(.followUps(prNumber: 279)))
    }

    /// The one input class where the two guards' order is observable: a caller
    /// requiring a verified green, an uncollected follow-up list, and a
    /// verdict that is *not* mergeable. Every other test either supplies
    /// `providedFollowUps: []` (making the follow-ups guard transparent) or
    /// pairs a nil list with a green verdict (`theOneRemainingQuestion`,
    /// where both orders agree). Swap the two guards in `evaluateMove` and
    /// every other test in this file still passes — only this one would turn
    /// `.needsInput(.followUps)`, which is exactly the spin the ordering
    /// exists to prevent: an unattended caller can read `.needsInput` only as
    /// "blocked, try again."
    @Test("A red pull request with no follow-up list is refused, never asked for input")
    func redPRWithNoFollowUpsIsBlockedNotAsked() {
        let card = makeCard(column: .inReview, prNumber: 279)
        var context = unattended(verdict(sign: .conflict))
        context.providedFollowUps = nil
        #expect(
            evaluateMove(from: .inReview, to: .done, card: card, context: context)
                == .blocked(.notVerifiedGreen(reason: .sign(.conflict))))
    }
}
