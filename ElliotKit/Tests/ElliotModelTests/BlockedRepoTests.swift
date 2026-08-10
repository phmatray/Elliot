import Foundation
import Testing

@testable import ElliotModel

/// The gate three documents claimed existed and no code implemented.
///
/// `CLAUDE.md`'s seeding recipe said a repository drawn as blocked was safe to
/// leave on screen "because no transition can spawn an agent from it";
/// `PreflightService.isBlocking`'s doc comment said "whether a repo's cards can
/// be dragged at all"; and `labelsCheck` was made a warning rather than a
/// failure *on the strength of that belief*. `evaluateMove` consulted
/// `repoIsEnabled` and nothing else.
///
/// These tests are the gate. Removing the `repoPreflight` guard from
/// `evaluateMove` turns the first four red.
@Suite("Blocked repository")
struct BlockedRepoTests {

    private func card(_ column: Column) -> Card {
        let fixed = Date(timeIntervalSince1970: 1_754_600_000)
        var card = Card(
            repoID: UUID(),
            title: "Give the archive a search field",
            body: "",
            story: UserStory(
                role: "someone reading finished work",
                want: "to search it",
                benefit: "I can find what shipped"
            ),
            column: column,
            columnEnteredAt: fixed,
            createdAt: fixed,
            updatedAt: fixed
        )
        card.issueNumber = 162
        card.prNumber = 226
        return card
    }

    private func context(_ preflight: PreflightState) -> MoveContext {
        // A human's move, and no verdict to carry: this file is about the
        // preflight gate, which sits ahead of the green guard and answers
        // whatever the guard would have said.
        MoveContext(
            repoIsEnabled: true, repoPreflight: preflight,
            method: MethodCatalog.resolve(nil), providedFollowUps: [],
            requiresVerifiedGreen: false, prVerdict: nil
        )
    }

    /// The three transitions that spawn an agent, and one that does not — all
    /// refused, because "this repository is not available" is one idea.
    @Test(
        "A failing repository refuses every move",
        arguments: [
            (Column.backlog, Column.todo),
            (Column.todo, Column.inProgress),
            (Column.inReview, Column.done),
            (Column.inProgress, Column.inReview),
        ]
    )
    func failingRefusesEveryMove(from: Column, to: Column) {
        var subject = card(from)
        subject.column = from

        let outcome = evaluateMove(from: from, to: to, card: subject, context: context(.failing))

        #expect(
            outcome == .blocked(.repoBlocked),
            """
            \(from) → \(to) was permitted in a repository whose Preflight checks are failing. \
            Moving a card is the act of execution, so for three of these four transitions that \
            means `claude -p` at `bypassPermissions` inside a checkout Elliot has already \
            diagnosed as broken.
            """
        )
    }

    /// The one that must **not** be refused, and the reason the guard sits after
    /// `allowSideEffects` rather than before it.
    ///
    /// `PRWatcher` moving a card because a pull request went ready is the board
    /// catching up with the world. Refusing it would leave the card behind
    /// reality in a repository the reader is in the middle of repairing — and it
    /// starts nothing, so there is nothing to refuse.
    @Test("A system move is not refused by a failing repository")
    func systemMoveIsNotRefused() {
        var subject = card(.inProgress)
        var moveContext = context(.failing)
        moveContext.allowSideEffects = false

        let outcome = evaluateMove(
            from: .inProgress, to: .inReview, card: subject, context: moveContext
        )
        subject.column = .inProgress

        #expect(outcome == .noAction)
    }

    @Test("A passing repository is unaffected")
    func passingIsUnaffected() {
        let subject = card(.todo)
        let outcome = evaluateMove(
            from: .todo, to: .inProgress, card: subject, context: context(.passing)
        )
        #expect(outcome == .action(.implementIssue(issueNumber: 162)))
    }

    /// The stated trade, pinned so that changing it is a decision rather than a
    /// drift. See `PreflightState.notChecked`: blocking here would freeze the
    /// board for the first seconds of every launch, and permanently whenever a
    /// rate-limited sweep cannot finish.
    @Test("An unmeasured repository is permitted, and that is deliberate")
    func notCheckedIsPermitted() {
        let subject = card(.todo)
        let outcome = evaluateMove(
            from: .todo, to: .inProgress, card: subject, context: context(.notChecked)
        )
        #expect(outcome == .action(.implementIssue(issueNumber: 162)))
    }

    /// The property that made the hole invisible for as long as it was.
    ///
    /// A `Bool` cannot carry it: `isBlocking([])` is `false`, so "nobody looked"
    /// and "it passed" were the same value. This asserts the type keeps them
    /// apart even though both permit a move today — because the day one of them
    /// stops permitting one, the distinction has to already exist.
    @Test("Not-checked and passing are different values, though both permit a move")
    func notCheckedIsNotPassing() {
        #expect(PreflightState.notChecked != PreflightState.passing)
        #expect(PreflightState.notChecked.allowsMoves)
        #expect(PreflightState.passing.allowsMoves)
        #expect(!PreflightState.failing.allowsMoves)
    }

    /// A caller that has not measured cannot assert a pass by omission.
    @Test("MoveContext defaults to not-checked, never to passing")
    func contextDefaultsToNotChecked() {
        // The three arguments stated here have no defaults, by design
        // (`MoveContext.init`'s ⛔ note — `method` joined the other two when a
        // review measured both its unpinned production sites); `repoPreflight`
        // is the one under test and stays omitted, which is the whole assertion.
        #expect(
            MoveContext(
                method: MethodCatalog.resolve(nil), requiresVerifiedGreen: false, prVerdict: nil
            ).repoPreflight == .notChecked
        )
    }

    /// `board_next` must refuse for the same reason a drag does — one rule
    /// engine, one answer. `rankNextSteps` decides by *calling* `evaluateMove`,
    /// so this asserts the candidate assembly carries the verdict through.
    @Test("nextCandidates carries the verdict, so board_next refuses too")
    func nextCandidatesCarriesTheVerdict() {
        var repo = Repo(
            path: "/tmp/blocked",
            nameWithOwner: "phmatray/blocked",
            displayName: "blocked"
        )
        repo.preflight = .failing

        var subject = card(.todo)
        subject.repoID = repo.id

        let steps = rankNextSteps(
            nextCandidates(cards: [subject], repos: [repo], activeRunIDs: [:])
        )

        #expect(steps.count == 1)
        #expect(steps.first?.block == .repoBlocked)
        #expect(steps.first?.isReady == false)
    }

    /// The refusal has to reach an agent as something it can act on, not as an
    /// unexplained code.
    @Test("The refusal carries a stable code and a sentence naming the remedy")
    func refusalIsLegible() {
        #expect(MoveBlock.repoBlocked.code == "repo_blocked")
    }
}
