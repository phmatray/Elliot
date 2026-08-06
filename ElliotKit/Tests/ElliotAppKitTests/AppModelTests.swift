import ElliotModel
import Foundation
import Testing

@testable import ElliotAppKit

/// `AppModel` held 800 lines and no tests, because `ElliotApp` was an
/// `executableTarget` and nothing in it could be imported. These cover it where
/// it *decides* — filtering, ordering, previewing, refusing, wording — and not
/// where it renders.
///
/// `@MainActor` on the suite rather than on each test: `AppModel` is main-actor
/// isolated, so every touch of it needs the hop, and per-test annotations would
/// only be the same thing written thirteen times.
@MainActor
@Suite("App model")
struct AppModelTests {

    // MARK: - Fixtures

    private func repo(_ name: String, enabled: Bool = true) -> Repo {
        var repo = Repo(
            path: "/tmp/\(name)", nameWithOwner: "phmatray/\(name)",
            defaultBranch: "main", displayName: name
        )
        repo.isEnabled = enabled
        return repo
    }

    /// Fixed rather than `Date()`: `Card`'s initialiser takes its three dates
    /// explicitly because `ElliotModel` holds no clock, and a fixture that
    /// reached for the wall clock would make `stagnation` — which reads
    /// `columnEnteredAt` — depend on when the suite happened to run.
    private let epoch = Date(timeIntervalSince1970: 1_770_000_000)

    private func card(
        _ title: String, repoID: UUID, column: ElliotModel.Column, order: Double,
        issue: Int? = nil, pr: Int? = nil
    ) -> Card {
        Card(
            repoID: repoID, title: title, column: column, orderIndex: order,
            issueNumber: issue, prNumber: pr,
            columnEnteredAt: epoch, createdAt: epoch, updatedAt: epoch
        )
    }

    /// Seeds the model without going near a database, a socket or a process.
    ///
    /// `start()` opens the store, captures the login shell and spawns three tool
    /// lookups; none of that is what these tests are about, and a test that
    /// needed it would not be a unit test.
    private func model(repos: [Repo], cards: [Card]) -> AppModel {
        let model = AppModel()
        model.testOnlySeed(repos: repos, cards: cards)
        return model
    }

    // MARK: - Filtering and ordering

    @Test("A column shows its own cards, ordered by orderIndex")
    func columnFiltersAndOrders() {
        let a = repo("Elliot")
        let cards = [
            card("third", repoID: a.id, column: .todo, order: 3),
            card("first", repoID: a.id, column: .todo, order: 1),
            card("second", repoID: a.id, column: .todo, order: 2),
            card("elsewhere", repoID: a.id, column: .backlog, order: 1),
        ]
        let model = model(repos: [a], cards: cards)

        #expect(model.cards(in: .todo).map(\.title) == ["first", "second", "third"])
        #expect(model.cards(in: .backlog).map(\.title) == ["elsewhere"])
        #expect(model.cards(in: .done).isEmpty)
    }

    @Test("Selecting one repository hides the others; selecting none shows them all")
    func repositoryFilter() {
        let a = repo("Elliot")
        let b = repo("Lyrics")
        let model = model(
            repos: [a, b],
            cards: [
                card("from a", repoID: a.id, column: .todo, order: 1),
                card("from b", repoID: b.id, column: .todo, order: 2),
            ]
        )

        model.selectedRepoID = nil
        #expect(model.cards(in: .todo).count == 2)

        model.selectedRepoID = a.id
        #expect(model.cards(in: .todo).map(\.title) == ["from a"])

        model.selectedRepoID = b.id
        #expect(model.cards(in: .todo).map(\.title) == ["from b"])
    }

    // MARK: - Preview agrees with the rule engine

    @Test("preview is the rule engine's answer, not a second opinion")
    func previewMatchesTheRuleEngine() {
        let a = repo("Elliot")
        let backlog = card("write it", repoID: a.id, column: .backlog, order: 1)
        let model = model(repos: [a], cards: [backlog])

        for column in ElliotModel.Column.allCases {
            let expected = evaluateMove(
                from: backlog.column, to: column, card: backlog,
                context: MoveContext(
                    repoIsEnabled: true, activeRunID: nil,
                    allowSideEffects: true, providedFollowUps: nil
                )
            )
            #expect(model.preview(backlog, to: column) == expected, "disagreed about \(column)")
        }
    }

    @Test("A switched-off repository is refused, and preview says so before the drop")
    func disabledRepoIsRefused() {
        let off = repo("Elliot", enabled: false)
        let backlog = card("write it", repoID: off.id, column: .backlog, order: 1)
        let model = model(repos: [off], cards: [backlog])

        guard case .blocked = model.preview(backlog, to: .todo) else {
            Issue.record("a disabled repository must block the move")
            return
        }
    }

    // MARK: - Refusal

    @Test("refuse answers true exactly when the move is blocked")
    func refuseMirrorsTheBlock() {
        let a = repo("Elliot")
        let backlog = card("write it", repoID: a.id, column: .backlog, order: 1)
        let todo = card("filed", repoID: a.id, column: .todo, order: 2)
        let model = model(repos: [a], cards: [backlog, todo])

        // Backlog -> To Do is the app's first real act and must be allowed.
        #expect(model.refuse(cardID: backlog.id, to: .todo) == false)

        // A card cannot be dropped where it already is.
        #expect(model.refuse(cardID: backlog.id, to: .backlog) == true)

        // To Do -> In Progress runs `implement-issue <n>`, and this card has no
        // issue number for `<n>`.
        #expect(model.refuse(cardID: todo.id, to: .inProgress) == true)

        // Backlog -> Done is NOT a refusal. It is the `default` arm of the
        // transition matrix — the card moves and nothing runs. Asserted here
        // because the first draft of this suite assumed skipping the pipeline
        // was blocked, and the engine was right: "anything else → nothing".
        #expect(model.refuse(cardID: backlog.id, to: .done) == false)
    }

    @Test("A refusal is recorded against the card it was refused for")
    func refusalNamesItsCard() {
        let a = repo("Elliot")
        let todo = card("filed", repoID: a.id, column: .todo, order: 1)
        let model = model(repos: [a], cards: [todo])

        _ = model.refuse(cardID: todo.id, to: .inProgress)
        #expect(model.refusal?.cardID == todo.id)
        #expect(model.refusal?.message == Consequence.reason(.missingIssueNumber))

        model.dismissRefusal()
        #expect(model.refusal == nil)
    }

    @Test("A card that is not on the board is refused rather than moved")
    func unknownCardIsRefused() {
        let model = model(repos: [repo("Elliot")], cards: [])
        #expect(model.refuse(cardID: UUID(), to: .todo) == true)
    }

    // MARK: - Wording

    @Test("A refusal is worded once, by Consequence, in both places it is shown")
    func refusalWordingLivesOnce() {
        // The card note and the column caption disagreed about the same refusal
        // before `explain` was folded into `Consequence.reason`. This pins that
        // they cannot drift apart again.
        //
        // Listed rather than iterated: `MoveBlock` carries an associated value
        // so it is not `CaseIterable`, and a `default` here would let a new case
        // arrive unworded — which is the failure this test exists to catch.
        let blocks: [MoveBlock] = [
            .sameColumn, .emptyIdea, .incompleteStory, .missingIssueNumber,
            .missingPRNumber, .repoDisabled, .runAlreadyInFlight(runID: UUID()),
        ]
        // Every `code` distinct proves the list above is complete: a case added
        // to the enum and forgotten here leaves `codes` short of `blocks`.
        #expect(Set(blocks.map(\.code)).count == blocks.count)

        for block in blocks {
            #expect(AppModel.explain(block) == Consequence.reason(block))
            #expect(!AppModel.explain(block).isEmpty, "\(block.code) has no wording")
        }
    }

    // MARK: - Keyboard advance

    @Test("Advancing past the end of the board does nothing")
    func nudgeStopsAtTheEnds() async {
        let a = repo("Elliot")
        let done = card("shipped", repoID: a.id, column: .done, order: 1, issue: 1, pr: 2)
        let model = model(repos: [a], cards: [done])
        model.selectedCardID = done.id

        // No board is wired in, so this would crash or move something if the
        // bounds check were not the first thing it did.
        await model.nudgeSelection(forward: true)
        #expect(model.card(id: done.id)?.column == .done)
    }

    @Test("Advancing with nothing selected does nothing")
    func nudgeWithoutSelection() async {
        let model = model(repos: [repo("Elliot")], cards: [])
        await model.nudgeSelection(forward: true)
        #expect(model.selectedCard == nil)
    }

    // MARK: - The merge confirmation must be reachable

    @Test("Arming a merge selects its card and opens the panel, in that order")
    func armingMakesTheConfirmationReachable() {
        // The confirmation moved out of a sheet and into the details panel
        // (#65). The panel only draws for a selected card and only when it is
        // open, so if these three ever came apart the merge would become
        // unreachable — the one way that change could fail *closed*. A sheet did
        // not care what was selected; this does.
        let a = repo("Elliot")
        let review = card("ready", repoID: a.id, column: .inReview, order: 1, issue: 4, pr: 9)
        let other = card("elsewhere", repoID: a.id, column: .todo, order: 2)
        let model = model(repos: [a], cards: [review, other])

        // Deliberately start from the state ⌘→ leaves: another card selected and
        // the panel shut.
        model.selectedCardID = other.id
        model.showingInspector = false

        model.armPendingMerge(cardID: review.id, prNumber: 9)

        #expect(model.selectedCardID == review.id)
        #expect(model.showingInspector)
        #expect(model.pendingFollowUps?.cardID == review.id)
        #expect(model.pendingFollowUps?.prNumber == 9)
    }

    @Test("Cancelling a pending merge leaves the card where it was")
    func cancellingMovesNothing() {
        let a = repo("Elliot")
        let review = card("ready", repoID: a.id, column: .inReview, order: 1, issue: 4, pr: 9)
        let model = model(repos: [a], cards: [review])

        model.armPendingMerge(cardID: review.id, prNumber: 9)
        model.cancelPendingMerge()

        #expect(model.pendingFollowUps == nil)
        // Still in review, and still selected: cancelling a confirmation is not
        // a reason to lose your place.
        #expect(model.card(id: review.id)?.column == .inReview)
        #expect(model.selectedCardID == review.id)
    }

    // MARK: - What to do next

    @Test("nextSteps is rankNextSteps' answer, not a second opinion")
    func nextStepsMatchesTheRanking() {
        // `BoardService.nextSteps` — what `board_next` answers over MCP —
        // assembles `nextCandidates(cards:repos:activeRunIDs:)` and ranks it.
        // This asserts the app builds the identical thing, because the moment
        // the two differ the board and the agent disagree about what to do next
        // and nothing says so.
        let a = repo("Elliot")
        let b = repo("Lyrics")
        let cards = [
            card("ready to file", repoID: a.id, column: .backlog, order: 1),
            card("filed", repoID: a.id, column: .todo, order: 2, issue: 7),
            card("no issue yet", repoID: b.id, column: .todo, order: 3),
            card("merged", repoID: b.id, column: .done, order: 4, issue: 1, pr: 2),
        ]
        let model = model(repos: [a, b], cards: cards)

        let expected = rankNextSteps(
            nextCandidates(cards: cards, repos: [a, b], activeRunIDs: [:])
        )
        #expect(model.nextSteps == expected)
    }

    @Test("Ready steps come before blocked ones")
    func readyFirst() {
        // The ordering is the whole point of the view: it exists so the reader
        // stops rebuilding it in their head. A stray `.sorted` in AppModel would
        // silently undo it, and this is what would catch that.
        let a = repo("Elliot")
        let blocked = card("no issue yet", repoID: a.id, column: .todo, order: 1)
        let ready = card("write it", repoID: a.id, column: .backlog, order: 2)
        let model = model(repos: [a], cards: [blocked, ready])

        let steps = model.nextSteps
        #expect(steps.count == 2)
        #expect(steps[0].card.id == ready.id)
        #expect(steps[0].isReady)
        #expect(!steps[1].isReady)
    }

    @Test("A card with nowhere to go does not appear at all")
    func doneCardsAreDropped() {
        // `Done` has no `naturalNext`, so `rankNextSteps` drops it. The view
        // must not invent a row for it — the same contract `board_next` has.
        let a = repo("Elliot")
        let done = card("shipped", repoID: a.id, column: .done, order: 1, issue: 1, pr: 2)
        #expect(model(repos: [a], cards: [done]).nextSteps.isEmpty)
    }

    @Test("A card whose repository is unknown is dropped, not shown as ready")
    func orphanCardsAreDropped() {
        // `nextCandidates` drops it deliberately: no repository means no
        // checkout to run in and no permission mode to run under. Showing it as
        // actionable would offer a move that cannot be made.
        let model = model(
            repos: [],
            cards: [card("orphan", repoID: UUID(), column: .backlog, order: 1)]
        )
        #expect(model.nextSteps.isEmpty)
    }

    // MARK: - Log rendering

    @Test("A stream event becomes one readable line, or none")
    func describeRendersTheLine() {
        #expect(AppModel.describe(.assistantText("hello\nworld")) == "hello")
        #expect(
            AppModel.describe(.assistantToolUse(name: "Bash", id: "1", inputPreview: "ls"))
                == "⚙ Bash ls"
        )
        #expect(AppModel.describe(.system(subtype: "anything", raw: Data())) == nil)
    }

    @Test("A failed tool result is shown; a successful one is not")
    func describeKeepsFailures() {
        // The log is a tail, not a transcript: a successful tool call is noise,
        // and a failed one is the line worth seeing.
        #expect(AppModel.describe(.toolResult(toolUseID: "1", isError: false, preview: "fine")) == nil)
        let failed = AppModel.describe(.toolResult(toolUseID: "1", isError: true, preview: "boom"))
        #expect(failed?.hasPrefix("✗") == true)
    }
}
