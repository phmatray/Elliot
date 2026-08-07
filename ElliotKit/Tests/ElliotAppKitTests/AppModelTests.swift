import ElliotEngine
import ElliotModel
import ElliotStore
import Foundation
import Synchronization
import TestSupport
import Testing

@testable import ElliotAppKit

/// A `Bool` an `@Sendable` closure may raise.
///
/// `withObservationTracking`'s `onChange` is `@Sendable`, so it cannot mutate a
/// captured `var` — and `Mutex` is non-copyable, so it cannot be captured
/// directly either. The same shape as `ElliotProcess.Locked`, which this target
/// does not depend on.
private final class ObservationFlag: Sendable {
    private let raised = Mutex(false)
    func raise() { raised.withLock { $0 = true } }
    var isRaised: Bool { raised.withLock { $0 } }
}

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

    // MARK: - Move history

    /// The two reads are separate on purpose, and this is where that stays
    /// true. `refreshRuns` runs from `CardView.task` for **every visible card**,
    /// so widening its audit read from 1 row to 100 would pull the whole history
    /// of the board behind a scroll; `refreshHistory` runs from the panel's own
    /// `.task(id:)`, for the one card that is open.
    ///
    /// Asserted against a real store rather than a fake, because the question is
    /// what SQLite returns for the limit each one passes — a fake would only
    /// echo the limit back.
    @Test("Opening a card's panel loads its whole history, newest first")
    func refreshHistoryLoadsEveryMove() async throws {
        let store = try BoardStore.inMemory()
        let model = AppModel()
        model.testOnlySeedStore(store)

        var repo = Repo(path: "/tmp/r", nameWithOwner: "phmatray/Elliot", displayName: "Elliot")
        repo.isEnabled = true
        try await store.saveRepo(repo)
        let card = Card(
            repoID: repo.id, title: "Run log", column: .backlog,
            columnEnteredAt: epoch, createdAt: epoch, updatedAt: epoch)
        try await store.saveCard(card)

        try await store.commitMove(
            card: card, to: .todo, orderIndex: 1, origin: .userDrag, run: nil, now: epoch)
        // Re-read: `commitMove` takes the card as it was *before* the move, so
        // passing the stale one would record the same `from` twice.
        let afterFirst = try #require(try await store.card(id: card.id))
        try await store.commitMove(
            card: afterFirst, to: .inProgress, orderIndex: 2,
            origin: .mcp(client: "agent-x"), run: nil,
            now: epoch.addingTimeInterval(60))

        await model.refreshHistory(cardID: card.id)
        let history = try #require(model.historyByCard[card.id])

        #expect(history.count == 2)
        #expect(history.map(\.to) == [.inProgress, .todo], "newest first")
        #expect(history[0].origin == .mcp(client: "agent-x"))
        #expect(history[1].origin == .userDrag)
    }

    /// Criterion 4's other half: the header's arrival note is fed by
    /// `refreshRuns`, which this story does not touch. If the two reads were
    /// ever merged, this is what would notice.
    @Test("The arrival note still gets its one audit from refreshRuns")
    func refreshRunsStillFeedsTheArrivalNote() async throws {
        let store = try BoardStore.inMemory()
        let model = AppModel()
        model.testOnlySeedStore(store)

        var repo = Repo(path: "/tmp/r", nameWithOwner: "phmatray/Elliot", displayName: "Elliot")
        repo.isEnabled = true
        try await store.saveRepo(repo)
        let card = Card(
            repoID: repo.id, title: "Run log", column: .backlog,
            columnEnteredAt: epoch, createdAt: epoch, updatedAt: epoch)
        try await store.saveCard(card)

        try await store.commitMove(
            card: card, to: .todo, orderIndex: 1, origin: .userDrag, run: nil, now: epoch)
        let afterFirst = try #require(try await store.card(id: card.id))
        try await store.commitMove(
            card: afterFirst, to: .inProgress, orderIndex: 2,
            origin: .system(reason: .prBecameReady), run: nil,
            now: epoch.addingTimeInterval(60))

        await model.refreshRuns(cardID: card.id)

        let last = try #require(model.lastMove[card.id])
        #expect(last.to == .inProgress, "the arrival note reads the newest move")
        #expect(last.origin == .system(reason: .prBecameReady))
        // And it did not quietly become the history read.
        #expect(model.historyByCard[card.id] == nil)
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

    /// These two used to assert what `AppModel.describe` produced for the log —
    /// which is to say, what the log *lost*: `describe` returns nil for a
    /// successful tool result, for `.system`, `.partial`, `.unknown` and
    /// `.malformed`, and drops every line of an agent turn after the first.
    /// A negative is a poor thing to pin a renderer to, so they now state
    /// positively which row each event produces. `describe` itself is still
    /// asserted, one section down, where it is still the right answer.
    @Test("Every event kind produces its own typed row")
    func eventsBecomeTypedRows() {
        // Decoded rather than constructed: `SystemInit`'s memberwise
        // initialiser is internal to `ElliotModel`, and a real init line is a
        // better fixture than a hand-built one anyway.
        let initLine = Data(
            #"{"type":"system","subtype":"init","session_id":"s1","cwd":"/tmp","model":"claude"}"#.utf8
        )
        let result = RunResult(subtype: "success", isError: false, text: "done")
        let rows = RunLog.rows(
            from: StreamEventDecoder.decodeAll(line: initLine) + [
                .assistantText("hello\nworld"),
                .assistantToolUse(name: "Bash", id: "t1", inputPreview: "ls"),
                .system(subtype: "anything", raw: Data()),
                .partial(text: "hel"),
                .unknown(type: "whatever", raw: Data("{}".utf8)),
                .result(result),
            ],
            denials: ["WebFetch"]
        )

        // Six: five events that carry something, plus the denial. `.system` and
        // `.partial` carry none, and that is the only thing dropped.
        #expect(rows.count == 6)

        guard case .session(let seen) = rows[0] else {
            Issue.record("a system_init becomes a session row, got \(rows[0])")
            return
        }
        #expect(seen.sessionID == "s1")

        // The whole turn, not its first line: this is what the flattened tail
        // was throwing away.
        #expect(rows[1] == .agentText("hello\nworld"))
        #expect(rows[2] == .toolUse(name: "Bash", id: "t1", input: "ls", outcome: nil))
        #expect(rows[3] == .unreadable(text: "{}"))
        // A refusal has no event of its own — it arrives inside the terminal
        // result — and it lands immediately *before* the terminal row: the log
        // only learns of it when the run ends, and a row after the last one
        // would read as something that happened afterwards.
        #expect(rows[4] == .denial(toolName: "WebFetch"))
        #expect(rows[5] == .terminal(result))
    }

    @Test("A tool result lands on its own call — the successful one too")
    func toolResultsNestUnderTheirCall() {
        let rows = RunLog.rows(from: [
            .assistantToolUse(name: "Bash", id: "t1", inputPreview: "ls"),
            .assistantToolUse(name: "Read", id: "t2", inputPreview: "a.swift"),
            // Out of order on purpose: two tools can be in flight at once, and
            // the fold matches by id rather than by arrival.
            .toolResult(toolUseID: "t2", isError: true, preview: "boom"),
            .toolResult(toolUseID: "t1", isError: false, preview: "fine"),
            .toolResult(toolUseID: "gone", isError: false, preview: "orphan"),
        ])

        // A successful tool call is a row now. `describe` returned nil for it,
        // so the run read as though the call had never happened.
        #expect(rows[0] == .toolUse(
            name: "Bash", id: "t1", input: "ls",
            outcome: ToolOutcome(isError: false, preview: "fine")
        ))
        #expect(rows[1] == .toolUse(
            name: "Read", id: "t2", input: "a.swift",
            outcome: ToolOutcome(isError: true, preview: "boom")
        ))
        #expect(rows[2] == .orphanResult(ToolOutcome(isError: false, preview: "orphan")))
        #expect(rows.count == 3)
    }

    // MARK: - The card's running strip

    /// `describe` survives the retyping of `liveLog`, narrowed to the one place
    /// a single collapsed string is still the right answer: `CardView`'s
    /// one-line strip on a card with a run in flight. Its assertions are
    /// unchanged; only what they are said to be *about* has moved, from the log
    /// to the strip.
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
        // On a *card* this is still right: one line has room for the call that
        // went wrong and none for the ones that went fine. The panel's log,
        // which has room, keeps both — see `toolResultsNestUnderTheirCall`.
        #expect(AppModel.describe(.toolResult(toolUseID: "1", isError: false, preview: "fine")) == nil)
        let failed = AppModel.describe(.toolResult(toolUseID: "1", isError: true, preview: "boom"))
        #expect(failed?.hasPrefix("✗") == true)
    }

    // MARK: - The live tail is bounded

    @Test("The live tail keeps the last 300 events and drops the oldest")
    func liveLogCapsAtThreeHundred() {
        let model = model(repos: [], cards: [])
        let runID = UUID()

        // 301, so the cap has to act exactly once and the assertion below can
        // name which end went.
        for index in 0...300 {
            model.apply(.runOutput(runID: runID, event: .assistantText("line \(index)")))
        }

        let events = model.liveLog[runID] ?? []
        #expect(events.count == 300)
        // The oldest goes. A tail that dropped its newest would stop following
        // the run while still looking full.
        #expect(events.first == .assistantText("line 1"))
        #expect(events.last == .assistantText("line 300"))
        #expect(events.contains(.assistantText("line 0")) == false, "the first event should be gone")
    }

    @Test("A run starting empties its tail rather than seeding it with a line")
    func runStartedClearsTheTail() {
        let model = model(repos: [], cards: [])
        let runID = UUID()
        model.apply(.runOutput(runID: runID, event: .assistantText("stale")))

        model.apply(.runStarted(runID: runID, cardID: nil))
        #expect(model.liveLog[runID] == [])
    }

    // MARK: - A stalled run has to reach the screen

    /// A run row, seeded straight into the model's collections.
    ///
    /// `SkillRun`'s own initialiser is the one the scheduler uses, so a fixture
    /// built with it is the real shape rather than a stand-in.
    ///
    /// `repoID` is a parameter with a throwaway default because the collections
    /// do not care which repository a run belongs to, but `skillRun.repoID` is a
    /// foreign key onto `repo` — so the moment a test saves one of these to a
    /// real store it has to name a repository that exists.
    private func run(cardID: UUID?, repoID: UUID = UUID(), state: RunState = .running) -> SkillRun {
        var run = SkillRun(
            cardID: cardID, repoID: repoID, kind: .createIssue,
            prompt: "/ai-migration-kit:create-issue x", cwd: "/tmp",
            logPath: "/tmp/run.ndjson", stderrPath: "/tmp/run.log", createdAt: epoch
        )
        run.state = state
        return run
    }

    @Test("A stalled run reaches every collection the screen draws from")
    func stallReachesTheUI() {
        // `apply(.runStalled)` was a `break`, on the reasoning that the store
        // already held `.stalled`. Nothing re-reads a run row on its own, so
        // every copy on screen went on saying `.running`: the card kept its
        // spinner and "No output for a while" was drawn by nobody. There is
        // deliberately no wall-clock kill — `merge-pr` waiting hours on CI is
        // legitimate — so silence is the only signal a wedged run gives, and
        // losing it leaves nothing between thinking and stuck.
        let model = model(repos: [], cards: [])
        let cardID = UUID()
        let stalling = run(cardID: cardID)
        let analysis = run(cardID: nil)

        model.testOnlySeedRuns(
            active: [cardID: stalling],
            byCard: [cardID: [stalling]],
            recent: [stalling],
            analysis: [analysis]
        )

        model.apply(.runStalled(runID: stalling.id, since: epoch))

        #expect(model.activeRuns[cardID]?.state == .stalled)
        #expect(model.runsByCard[cardID]?.first?.state == .stalled)
        #expect(model.recentRuns.first?.state == .stalled)
        // A different run is untouched: the notice names one run, and the four
        // collections are walked by id rather than blanket-marked.
        #expect(model.analysis?.runs.first?.state == .running)
    }

    @Test("A run that finished before the notice arrived keeps its outcome")
    func stallDoesNotResurrectATerminalRun() {
        // The guard is `RunScheduler.markStalled`'s, spelled the same way on
        // purpose. The idle watcher notices silence and the run can end while
        // the notice is in flight; dragging a succeeded run back to `.stalled`
        // would be a finished run the board says is still going, and `.stalled`
        // is not terminal, so it would also hold its card against a further
        // move.
        for finished in [RunState.succeeded, .failed, .cancelled, .completedWithDenials, .timedOut] {
            let done = run(cardID: UUID(), state: finished)
            #expect(AppModel.stalling(done.id, done).state == finished)
        }
        // Queued and cancelling are not "running" either: a queued run has
        // produced no output because it has not started, and a cancelling one
        // has already had its SIGTERM.
        for other in [RunState.queued, .cancelling] {
            let run = run(cardID: UUID(), state: other)
            #expect(AppModel.stalling(run.id, run).state == other)
        }
        // And the one case that does stall.
        let running = run(cardID: UUID())
        #expect(AppModel.stalling(running.id, running).state == .stalled)
        // Another run's notice changes nothing.
        #expect(AppModel.stalling(UUID(), running).state == .running)
    }

    // MARK: - A run that just started has to reach the panel

    /// One store, one repository, one card in **To Do**, and one `.running` run
    /// for that card — the state the board is in the instant `RunScheduler`
    /// yields `.runStarted`.
    ///
    /// A real `BoardStore` rather than `testOnlySeedRuns`, because the thing
    /// under test *is* the read: `refreshRuns` goes to SQLite, and a seeded
    /// dictionary would prove only that a dictionary can be written to. The
    /// scheduler saves the row (`RunScheduler.swift:381`) before it yields the
    /// update (`:384`), so seeding the row first is the real order, not a
    /// convenience.
    private struct StartedRun {
        var model: AppModel
        var store: BoardStore
        var repo: Repo
        var card: Card
        var run: SkillRun
    }

    private func startedRunFixture() async throws -> StartedRun {
        let store = try BoardStore.inMemory()
        let repo = repo("Elliot")
        let subject = card("watch this run", repoID: repo.id, column: .todo, order: 1)
        let running = run(cardID: subject.id, repoID: repo.id)
        try await store.saveRepo(repo)
        try await store.saveCard(subject)
        try await store.saveRun(running)

        let model = model(repos: [repo], cards: [subject])
        model.testOnlySeedStore(store)
        return StartedRun(model: model, store: store, repo: repo, card: subject, run: running)
    }

    /// Polls `runsByCard[cardID]` until it holds a row, and says what it last
    /// saw when it never does.
    ///
    /// `apply(_:)` spawns its refresh in a `Task`, so there is nothing for a
    /// test to await — the same reason `RunsPaneLiveTests.awaitTerminal` polls.
    /// Bounded by `withTimeout`, because an unbounded wait is how one hung
    /// child once stopped `swift test` from ever exiting. On giving up it
    /// records whether the key was absent or merely empty, so a flake names its
    /// own cause instead of printing "timed out".
    private func awaitRuns(cardID: UUID, in model: AppModel) async throws -> [SkillRun] {
        do {
            return try await withTimeout(.seconds(5)) {
                while true {
                    if let rows = await model.runsByCard[cardID], !rows.isEmpty { return rows }
                    try await Task.sleep(for: .milliseconds(20))
                }
            }
        } catch {
            // The two are different diagnoses: nil is "the refresh never ran",
            // empty is "it ran and the store had nothing" — a seed that did not
            // land rather than an update that did not arrive.
            let seen = model.runsByCard[cardID] == nil ? "still nil" : "empty"
            Issue.record("runsByCard[card] was \(seen) when the wait gave up")
            throw error
        }
    }

    /// The same wait, for the sibling refresh the *same* `apply` call spawns.
    ///
    /// Used as a fence by the negative test below. `activeRuns` filling proves
    /// the unconditional `Task` has run; the guarded refresh is enqueued on the
    /// same actor *ahead* of it, so its window has passed too. That is a fence,
    /// not a proof of ordering — unstructured tasks promise none — and it is
    /// the tighter half of the argument. The other half is structural: with
    /// `cardID` nil there is no key to write an entry under.
    private func awaitActiveRun(cardID: UUID, in model: AppModel) async throws -> SkillRun {
        do {
            return try await withTimeout(.seconds(5)) {
                while true {
                    if let run = await model.activeRuns[cardID] { return run }
                    try await Task.sleep(for: .milliseconds(20))
                }
            }
        } catch {
            Issue.record("activeRuns[card] was still nil when the wait gave up")
            throw error
        }
    }

    @Test("A run that has just started reaches the card's runs")
    func runStartedFillsRunsByCard() async throws {
        // `.runStarted` discarded its `cardID` with `_` and refreshed only
        // `activeRuns`, `analysis?.runs` and `occupancy`, so nothing filled
        // `runsByCard` when a run began. That is the collection `RunsPane`
        // draws from, and neither `.task(id:)` that calls `refreshRuns` is
        // keyed on anything a starting run changes — both key on the card's id
        // — so the panel opened to watch the run said "Nothing has run yet" for
        // the whole run.
        let fixture = try await startedRunFixture()

        fixture.model.apply(.runStarted(runID: fixture.run.id, cardID: fixture.card.id))

        let rows = try await awaitRuns(cardID: fixture.card.id, in: fixture.model)
        #expect(rows.contains { $0.id == fixture.run.id })
    }

    @Test("One runStarted reaches both Cancel affordances")
    func runStartedReachesBothCancelAffordances() async throws {
        // What this pins and what it does not.
        //
        // It pins the two *collections* the two Cancel affordances are gated
        // on, after a single `.runStarted`: `activeRuns[card]` — read by
        // `CardView.activeRun` for `RunningStrip` (`CardView.swift:49`) and for
        // the card's context-menu item (`:165`, `:188`) — and
        // `runsByCard[card]`, read by `RunsPane.body` (`RunsPane.swift:17`) for
        // the `RunBox` whose own Cancel button sits at `:227`. The card's half
        // already worked before this story; it is here as a regression pin, so
        // a change that fills `runsByCard` by emptying `activeRuns` is not a
        // trade this suite would call a fix.
        //
        // It cannot see either control on screen. `swift test` has no layout,
        // and this repository has paid three merges for pretending otherwise
        // (#47, #50, #52, #53). That half is Task 4's look, recorded in the PR.
        let fixture = try await startedRunFixture()

        fixture.model.apply(.runStarted(runID: fixture.run.id, cardID: fixture.card.id))

        let rows = try await awaitRuns(cardID: fixture.card.id, in: fixture.model)
        let active = try await awaitActiveRun(cardID: fixture.card.id, in: fixture.model)
        #expect(active.id == fixture.run.id)
        #expect(rows.first?.id == fixture.run.id)
        // Both gates read `state.isCancellable`, not merely "a run is present",
        // so the pin is about the Cancel being *offered* rather than about a
        // dictionary having been written to.
        #expect(active.state.isCancellable)
        #expect(rows.first?.state.isCancellable == true)
    }

    @Test("A run with no card — an analysis — adds nothing to any card's runs")
    func runStartedWithoutACardTouchesNoCardsRuns() async throws {
        // An analysis run belongs to a repository, not to a card, and
        // `.runFinished`'s guard is `if let cardID`. "The same way
        // `.runFinished` does" carries the guard with it: this passes before
        // the fix as well as after, on purpose — it is what stops the fix
        // inventing an entry for a run that has no card to key one under.
        let fixture = try await startedRunFixture()
        let analysis = Analysis(repoID: fixture.repo.id, angles: [.uxAndUI], createdAt: epoch)
        let analysisRun = SkillRun.analysis(
            repoID: fixture.repo.id, analysisID: analysis.id, analysisAngle: .uxAndUI,
            prompt: "/ai-migration-kit:analyze-repo", cwd: "/tmp", state: .running,
            logPath: "/tmp/analysis.ndjson", stderrPath: "/tmp/analysis.log", createdAt: epoch
        )
        // Saved rather than merely constructed, so the store genuinely holds a
        // running row this update could have been resolved through.
        try await fixture.store.saveAnalysis(analysis, runs: [analysisRun])

        fixture.model.apply(.runStarted(runID: analysisRun.id, cardID: nil))

        // The fence — see `awaitActiveRun`. It also asserts something worth
        // asserting on its own: a card-less run does not cost the card that
        // *does* have one its refresh.
        _ = try await awaitActiveRun(cardID: fixture.card.id, in: fixture.model)
        #expect(fixture.model.runsByCard.isEmpty)
    }

    // MARK: - The panel's width is remembered, and only when asked

    @Test("A width set on a model that was given a file is on disk afterwards")
    func settingTheWidthWritesIt() {
        let url = TestHome.scratch("appmodel-prefs-write")
            .appendingPathComponent("preferences.json")
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )

        let model = AppModel(preferences: PreferencesFile(url: url))
        model.panelSpans = Preferences.spanChoices.narrow

        #expect(PreferencesFile.load(from: url).panelSpans == Preferences.spanChoices.narrow)
    }

    @Test("Setting it back writes the new value, not just the first one")
    func settingItAgainWritesAgain() {
        let url = TestHome.scratch("appmodel-prefs-rewrite")
            .appendingPathComponent("preferences.json")
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )

        let model = AppModel(preferences: PreferencesFile(url: url))
        model.panelSpans = Preferences.spanChoices.narrow
        model.panelSpans = Preferences.spanChoices.wide

        #expect(PreferencesFile.load(from: url).panelSpans == Preferences.spanChoices.wide)
    }

    /// Criterion 4, asserted rather than assumed.
    ///
    /// Every other test in this bundle builds `AppModel()`, and several of them
    /// assign `panelSpans`. What stops them leaving a preference in the
    /// operator's real `~/Library/Application Support/Elliot` is not that they
    /// remember to isolate themselves — it is that the writer they get by
    /// default has nowhere to write. This is that claim, pointed at the path a
    /// default-constructed model would use if it used one at all.
    @Test("A model nobody handed a file writes no preference anywhere")
    func theDefaultModelWritesNothing() {
        _ = TestHome.root
        let wouldBe = StoreLocation.preferencesURL
        try? FileManager.default.removeItem(at: wouldBe)

        let model = AppModel()
        model.panelSpans = Preferences.spanChoices.narrow
        model.panelSpans = Preferences.spanChoices.wide

        #expect(model.panelSpans == Preferences.spanChoices.wide)
        #expect(
            !FileManager.default.fileExists(atPath: wouldBe.path),
            "a test that did not ask for persistence must not have written \(wouldBe.path)"
        )
    }

    /// That `panelSpans` is observable **at all**, now that it is computed over
    /// private storage rather than stored directly.
    ///
    /// If reading it stopped registering a dependency on what the setter mutates,
    /// the board would silently stop re-laying-out on a resize: `swift build`
    /// stays clean, every other test stays green, and nobody but a person
    /// dragging the handle would notice.
    ///
    /// ⚠️ **It does not discriminate between the computed form and a `didSet`** —
    /// measured, by building the `didSet` form and watching this stay green.
    /// `@Observable` tracks a property carrying an observer perfectly well; what
    /// rules the `didSet` out is that the observer fires during `init`, and the
    /// test that catches *that* is `restoringDoesNotWrite`. Kept apart on purpose:
    /// two different claims, and only one of them is about tracking.
    @Test("Changing the width is observable, or the board never re-lays-out")
    func theWidthIsObservable() {
        let model = AppModel()
        // `onChange` is `@Sendable`, so the flag cannot be a captured `var`.
        let fired = ObservationFlag()

        withObservationTracking {
            _ = model.panelSpans
        } onChange: {
            fired.raise()
        }

        model.panelSpans = Preferences.spanChoices.narrow
        #expect(
            fired.isRaised,
            "reading panelSpans must register a dependency on what the setter mutates"
        )
    }

    @Test("A model restored from a stored width opens at it")
    func restoresTheStoredWidth() {
        let model = AppModel(
            initialPreferences: Preferences(panelSpans: Preferences.spanChoices.narrow)
        )
        #expect(model.panelSpans == Preferences.spanChoices.narrow)
    }

    @Test("A stored width the panel was never designed at opens at the default")
    func nonsenseStoredWidthOpensAtTheDefault() {
        for spans in [0, 1, 4, -7] {
            let model = AppModel(initialPreferences: Preferences(panelSpans: spans))
            #expect(model.panelSpans == Preferences.default.panelSpans)
        }
    }

    @Test("Restoring a width does not rewrite the file it was just read from")
    func restoringDoesNotWrite() throws {
        // The first launch after this ships reads a file and must leave it
        // alone: a save fired from `init` would rewrite it before the reader has
        // touched anything, which is harmless today and would silently defeat any
        // later attempt to tell "never set" from "set to the default".
        let url = TestHome.scratch("appmodel-prefs-untouched")
            .appendingPathComponent("preferences.json")
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Data(#"{"panelSpans": 2, "writtenByAnotherVersion": true}"#.utf8).write(to: url)
        let before = try Data(contentsOf: url)

        let model = AppModel(
            preferences: PreferencesFile(url: url),
            initialPreferences: PreferencesFile.load(from: url)
        )

        #expect(model.panelSpans == Preferences.spanChoices.narrow)
        #expect(try Data(contentsOf: url) == before)
    }

    // MARK: - Parsed issue bodies

    @Test("An issue body is parsed once per body, and again when it changes")
    func issueDocumentIsMemoisedOnTheBody() {
        let a = repo("Elliot")
        var subject = card("filed", repoID: a.id, column: .todo, order: 1, issue: 47)
        subject.body = "## Acceptance criteria\n\n1. It builds\n2. It runs\n"
        let model = model(repos: [a], cards: [subject])

        let first = model.issueDocument(for: subject)
        #expect(first.acceptanceCriteria.map(\.plain) == ["It builds", "It runs"])

        // ⚠️ `==` cannot see the memo, and asserting it was this test's whole
        // content until #79. `IssueMarkdownParser.parse` is pure, so a document
        // parsed a second time is *equal* to the cached one — the assertion went
        // green with the cache deleted, which is to say it reported a safety it
        // was not measuring.
        //
        // What a second parse cannot do is hand back the same storage. `first`
        // is still held here, so its buffer cannot have been freed and reused:
        // a re-parse has to allocate a second array at a second address, and a
        // memo has to return the first one.
        let second = model.issueDocument(for: subject)
        #expect(second == first)
        // An empty array shares one global storage, which would make the
        // address below equal either way — vacuous in exactly the manner this
        // test is being repaired for.
        #expect(!first.blocks.isEmpty)
        #expect(storage(of: second.blocks) == storage(of: first.blocks), "the body was parsed twice")

        // The key is the body, not the card: an edit or a re-import must not be
        // served the previous parse. Both halves are asserted — the criteria,
        // which say the answer is the new body's, and the address, which says
        // the work was actually redone rather than a stale document mutated.
        var edited = subject
        edited.body = "## Acceptance criteria\n\n1. Something else\n"
        let reparsed = model.issueDocument(for: edited)
        #expect(reparsed.acceptanceCriteria.map(\.plain) == ["Something else"])
        #expect(storage(of: reparsed.blocks) != storage(of: first.blocks))
    }

    /// Where an array's elements live.
    ///
    /// The only handle a value type gives on *which* value you were handed, as
    /// opposed to what it is equal to — and so the only way to watch a cache
    /// that by construction changes nothing about the answer. Compared as a bit
    /// pattern and never dereferenced; `withUnsafeBufferPointer` does not copy,
    /// so two arrays sharing storage report the same address.
    private func storage(of blocks: [IssueBlock]) -> UInt {
        blocks.withUnsafeBufferPointer { UInt(bitPattern: $0.baseAddress) }
    }
}
