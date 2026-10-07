import ElliotModel
import Foundation
import Testing

@testable import ElliotAppKit

/// What the detail panel leaves out, and what it says about leaving it out.
///
/// Three things in this panel were truncated and only one of them said so.
/// `MoveHistoryBlock` prints "Showing the most recent 100 moves; there may be
/// more" and names the reason in its own comment — *presenting a truncated list
/// as complete is the failure this project keeps finding in other guises* —
/// while the log dropped the head of every long run in silence and the run
/// window capped at 20 with the count printed raw beside it.
///
/// `swift test` cannot see any of the three notes on screen. It can see the
/// choice, which is why the choice is a pure function.
@Suite("Panel truncation")
struct PanelTruncationTests {

    // MARK: - The log window

    @Test("A log shorter than the cap is whole, and says nothing")
    func shortLogIsWhole() {
        let rows = (0..<10).map { RunLogRow.agentText("line \($0)") }
        let window = RunsPane.trimmed(rows, limit: 300)

        #expect(window.rows == rows)
        #expect(window.dropped == 0)
    }

    /// The reassuring answer must not be the one a boundary falls into — the
    /// same reason `MoveHistory.isCapped` uses `>=` rather than `==`.
    @Test("Exactly at the cap nothing is dropped; one past it, one is")
    func theBoundaryIsNotOffByOne() {
        let atLimit = (0..<300).map { RunLogRow.agentText("line \($0)") }
        #expect(RunsPane.trimmed(atLimit, limit: 300).dropped == 0)
        #expect(RunsPane.trimmed(atLimit, limit: 300).rows.count == 300)

        let onePast = atLimit + [.agentText("line 300")]
        let window = RunsPane.trimmed(onePast, limit: 300)
        #expect(window.dropped == 1)
        #expect(window.rows.count == 300)
        // The *newest* are kept: a log you are watching is read at its tail.
        #expect(window.rows.first == .agentText("line 1"))
        #expect(window.rows.last == .agentText("line 300"))
    }

    /// Every row is either drawn or counted. This is the whole claim the note on
    /// screen makes, and it is the one an off-by-one would quietly break.
    @Test("Drawn plus dropped is exactly what went in", arguments: [0, 1, 299, 300, 301, 1_000])
    func nothingVanishesUncounted(count: Int) {
        let rows = (0..<count).map { RunLogRow.agentText("line \($0)") }
        let window = RunsPane.trimmed(rows, limit: 300)

        #expect(window.rows.count + window.dropped == count)
        #expect(window.rows.count <= 300)
    }

    /// ⚠️ The invariant that matters more than the arithmetic.
    ///
    /// The cap is on **rows**, and `RunLog.rows` has already attached each
    /// `tool_result` to its `tool_use` by id — so a row *is* the pair and no
    /// boundary can fall between them. A cap counted in events could land
    /// between a call and its result and leave a call on screen that never
    /// returned, which is indistinguishable from a call still in flight.
    ///
    /// Driven at the boundary rather than in the middle: the pair is made the
    /// first row kept, so a cap that split anything would split this one.
    @Test("A tool call and its result cannot be separated by the cap")
    func aCallKeepsItsResultAcrossTheBoundary() {
        let pair = RunLogRow.toolUse(
            name: "Bash",
            id: "tu_1",
            input: "swift build",
            outcome: ToolOutcome(isError: false, preview: "Build complete!")
        )
        // 5 older rows, then the pair, then 4 newer: a cap of 5 keeps the pair
        // and everything after it, and drops the 5 before.
        let rows =
            (0..<5).map { RunLogRow.agentText("older \($0)") }
            + [pair]
            + (0..<4).map { RunLogRow.agentText("newer \($0)") }

        let window = RunsPane.trimmed(rows, limit: 5)

        #expect(window.dropped == 5)
        #expect(window.rows.first == pair)
        // Not merely present — present *with its outcome*. A row that lost it
        // would read as a call still running.
        guard case .toolUse(_, _, _, let outcome) = window.rows[0] else {
            Issue.record("the first kept row is no longer the tool call")
            return
        }
        #expect(outcome?.preview == "Build complete!")
    }

    // MARK: - The diff window

    /// ⚠️ What these pin is the **contract**, not the allocation. `swift test`
    /// cannot see how much was built and thrown away, any more than it can see
    /// layout — a reimplementation that materialised every line of the file and
    /// then took `.prefix(40)` would keep all three green. What goes red is the
    /// signature: `lines` returns the capped rows *and* the true total, so a
    /// caller cannot report "40 lines" for a file of 4 000 the way one that
    /// returns a bare array invites.
    @Test("A diff shorter than the cap is whole, and its total is its length")
    func aShortDiffIsWhole() {
        let diff = DiffLinesView.lines(oldText: "a\nb\nc", newText: "a\nB\nc")

        #expect(diff.rows.count == 6)
        #expect(diff.total == 6)
        // Removals first, then additions — the order the gutter is read in.
        #expect(diff.rows.prefix(3).count { $0.isRemoval } == 3)
        #expect(diff.rows.suffix(3).count { $0.isRemoval } == 0)
    }

    /// The reassuring answer must not be the one the boundary falls into — the
    /// same `>=` / `>` care `MoveHistory.isCapped` takes above.
    @Test("Exactly at the cap the footer stays silent; one past it, it counts")
    func theDiffBoundaryIsNotOffByOne() {
        let atLimit = (0..<40).map { "line \($0)" }.joined(separator: "\n")
        let capped = DiffLinesView.lines(oldText: nil, newText: atLimit)
        #expect(capped.rows.count == 40)
        #expect(capped.total == 40)

        let onePast = atLimit + "\nline 40"
        let over = DiffLinesView.lines(oldText: nil, newText: onePast)
        #expect(over.rows.count == 40)
        #expect(over.total == 41)
        // The footer's arithmetic, which is the whole claim it makes on screen.
        #expect(over.total - over.rows.count == 1)
    }

    /// A whole-file `.diff` is the frame this view expects to be handed — the
    /// one `TurnSummary.truncationEvents` warns about — so the interesting case
    /// is not 41 lines but 4 000, and the budget is one budget: removals eat
    /// into what is left for additions, because both are rows on screen.
    @Test("A whole-file edit draws its budget once, shared between both sides")
    func theCapIsSharedBetweenRemovalsAndAdditions() {
        let old = (0..<30).map { "old \($0)" }.joined(separator: "\n")
        let new = (0..<4_000).map { "new \($0)" }.joined(separator: "\n")

        let diff = DiffLinesView.lines(oldText: old, newText: new)

        #expect(diff.rows.count == DiffLinesView.lineLimit)
        #expect(diff.total == 4_030)
        #expect(diff.rows.count { $0.isRemoval } == 30)
        #expect(diff.rows.count { !$0.isRemoval } == 10)
        // Every line is either drawn or counted, and none is invented.
        #expect(diff.rows.count + (diff.total - diff.rows.count) == 4_030)
    }

    /// ⛔ The counter and the splitter must share **one** notion of a line, and a
    /// `Character` is not it. `\r\n` is a single grapheme cluster, so
    /// `Character("\r\n") != Character("\n")` and a `split(separator: "\n")` over
    /// Characters finds no separator anywhere in CRLF text — while a counter
    /// reading UTF-8 bytes finds every one of them.
    ///
    /// What that costs is not a miscount, it is a sentence on screen that is false
    /// in **both** directions: one unreadable row holding the entire file, beneath
    /// a footer reporting lines withheld that were never withheld. Measured before
    /// the fix, on the 100-line input below: `rows.count == 1`, `total == 100`,
    /// footer *"… 99 more line(s) not shown"* — with nothing whatsoever withheld.
    ///
    /// A diff is a file the agent edited, and a file edited on Windows has CRLF,
    /// so this is an ordinary input rather than a hostile one. The comment that
    /// used to sit over `take` asserted the two counters agreed; asserting it is
    /// what let them disagree.
    @Test("A CRLF diff splits the way it counts, and draws no carriage returns")
    func aCRLFDiffIsNotOneUnreadableRow() {
        let crlf = (0..<100).map { "line \($0)" }.joined(separator: "\r\n")

        let diff = DiffLinesView.lines(oldText: nil, newText: crlf)

        #expect(diff.total == 100)
        #expect(diff.rows.count == DiffLinesView.lineLimit)
        // The terminator is not content: a stray CR draws as a glyph in the row.
        // ⚠️ Over **scalars**, deliberately. `text.contains("\r")` searches by
        // Character and a CR fused into a `\r\n` cluster is not a Character equal
        // to `"\r"` — so that spelling passed against the very input this test
        // exists for. Measured while writing it: the pre-fix run reported two
        // failures, and this was not one of them. The trap under test bit the
        // assertion written to catch it.
        #expect(diff.rows.allSatisfy { !$0.text.unicodeScalars.contains("\r") })
        #expect(diff.rows.first?.text == "line 0")
    }

    // MARK: - The run window

    /// The count drawn beside "Runs" is what `store.runs(cardID:limit:)`
    /// returned, not how many the card has. Read at its own cap it is a floor.
    @Test("A run read at its cap is reported as a floor, not a total")
    func theRunWindowSaysWhenItIsFull() {
        #expect(MoveHistory.isCapped(count: AppModel.runWindow, limit: AppModel.runWindow))
        #expect(!MoveHistory.isCapped(count: AppModel.runWindow - 1, limit: AppModel.runWindow))
        // A count past the cap is still "you may be missing some".
        #expect(MoveHistory.isCapped(count: AppModel.runWindow + 5, limit: AppModel.runWindow))
    }

    // MARK: - What one run says about its own clock

    private static func run(
        state: RunState = .succeeded,
        startedAt: Date? = nil,
        endedAt: Date? = nil
    ) -> SkillRun {
        SkillRun(
            cardID: nil, repoID: UUID(), kind: .createIssue, prompt: "p", cwd: "/tmp",
            state: state, startedAt: startedAt, endedAt: endedAt,
            logPath: "/tmp/none.ndjson", stderrPath: "/tmp/none.log",
            createdAt: Date(timeIntervalSince1970: 1_770_000_000)
        )
    }

    private static let created = Date(timeIntervalSince1970: 1_770_000_000)

    /// ⛔ The one thing this function must never do. A queued run has no
    /// `endedAt` and may have no `startedAt`; falling back to `createdAt` is
    /// right, and captioning that fallback "Finished" would be a claim about a
    /// run that has not started.
    @Test("A queued run's stamp is named as queued, and has no duration")
    func createdAtIsNeverPresentedAsAFinishTime() {
        let clock = RunsPane.timing(
            of: Self.run(state: .queued), at: Self.created.addingTimeInterval(90)
        )

        #expect(clock.help.hasPrefix("Queued "))
        #expect(clock.duration == nil)
        #expect(clock.age == "1m ago")
    }

    @Test("A running run is aged from its start, and still has no duration")
    func aRunningRunHasNoDuration() {
        let clock = RunsPane.timing(
            of: Self.run(state: .running, startedAt: Self.created.addingTimeInterval(10)),
            at: Self.created.addingTimeInterval(70)
        )

        #expect(clock.help.hasPrefix("Started "))
        #expect(clock.duration == nil)
        #expect(clock.age == "1m ago")
    }

    @Test("A finished run is aged from its end, and carries how long it took")
    func aFinishedRunCarriesItsDuration() {
        let clock = RunsPane.timing(
            of: Self.run(
                startedAt: Self.created.addingTimeInterval(10),
                endedAt: Self.created.addingTimeInterval(200)
            ),
            at: Self.created.addingTimeInterval(3_800)
        )

        #expect(clock.help.hasPrefix("Finished "))
        #expect(clock.duration == "3m 10s")
        #expect(clock.age == "1h ago")
    }

    /// The hours branch is not decoration: there is deliberately no wall-clock
    /// kill, because `merge-pr` waiting on CI for hours is legitimate.
    @Test("A four-hour merge run reads in hours, not in minutes")
    func aLongRunReadsInHours() {
        let clock = RunsPane.timing(
            of: Self.run(startedAt: Self.created, endedAt: Self.created.addingTimeInterval(14_580)),
            at: Self.created.addingTimeInterval(14_580)
        )

        #expect(clock.duration == "4h 03m")
    }

    // MARK: - The Issue pane's empty state

    private static func card(
        column: ElliotModel.Column = .backlog, issueNumber: Int? = nil
    ) -> Card {
        Card(
            repoID: UUID(),
            title: "A card",
            column: column,
            issueNumber: issueNumber,
            columnEnteredAt: created,
            createdAt: created,
            updatedAt: created
        )
    }

    /// A filed issue whose body GitHub holds is empty is a *finished* state. It
    /// must not be told to go and write one — which is the whole reason
    /// `issueNumber` separates the two cases rather than one sentence covering
    /// both.
    @Test("A filed issue with an empty body says so, and asks for nothing")
    func aFiledIssueWithNoBodyIsNotAskedForAStory() {
        let copy = IssuePane.emptyState(
            for: Self.card(column: .inProgress, issueNumber: 42), outcome: .noAction
        )

        #expect(copy.message.contains("#42"))
        #expect(!copy.message.lowercased().contains("write"))
    }

    @Test("An unfiled card names the move that would file it, and what that starts")
    func anUnfiledCardNamesItsNextMove() {
        let copy = IssuePane.emptyState(
            for: Self.card(),
            outcome: .action(.createIssue(idea: "s", labels: []))
        )

        #expect(copy.message.contains(ElliotModel.Column.todo.displayName))
        #expect(copy.title == "Nothing written yet")
    }

    /// ⚠️ Derived, never tabulated — the same rule `RunsPane.emptyState`
    /// follows. A refusal is repeated from `Consequence`, so this cannot go on
    /// promising a run for a card whose repository Preflight switched off.
    @Test("A refused move is reported as refused, in the rule engine's own words")
    func aRefusedMoveIsNotDressedUpAsAnInvitation() {
        let outcome = MoveOutcome.blocked(.repoDisabled)
        let copy = IssuePane.emptyState(for: Self.card(), outcome: outcome)

        #expect(copy.message.contains("refused"))
        #expect(copy.message.contains(Consequence.of(outcome).summary))
    }

    /// Done has nowhere to go, so "nothing has been written *yet*" would be a
    /// promise. It gets its own sentence.
    @Test("A terminal column promises nothing")
    func doneMakesNoPromise() {
        let copy = IssuePane.emptyState(for: Self.card(column: .done), outcome: nil)

        #expect(copy.message.contains(ElliotModel.Column.done.displayName))
        #expect(copy.message.contains("end of the board"))
    }
}
