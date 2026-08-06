import ElliotModel
import Foundation
import Testing

@testable import ElliotAppKit

/// Folding a card's audits and runs into the rows the panel draws.
///
/// The whole point of `MoveHistory` being a pure function rather than view code
/// is that this file can exist: `swift test` cannot see the block on screen, but
/// it can see every decision the block makes about what to say.
@Suite("Move history")
struct MoveHistoryTests {

    private static let epoch = Date(timeIntervalSince1970: 1_700_000_000)
    private static let cardID = UUID()

    private static func audit(
        from: ElliotModel.Column = .backlog,
        to: ElliotModel.Column = .todo,
        origin: MoveOrigin = .userDrag,
        runID: UUID? = nil,
        secondsAfterEpoch: TimeInterval = 0
    ) -> MoveAudit {
        MoveAudit(
            cardID: cardID, from: from, to: to, origin: origin, runID: runID,
            at: epoch.addingTimeInterval(secondsAfterEpoch))
    }

    private static func run(id: UUID, kind: SkillKind = .createIssue) -> SkillRun {
        SkillRun(
            id: id, cardID: cardID, repoID: UUID(), kind: kind, prompt: "",
            cwd: "/tmp", logPath: "/tmp/log", stderrPath: "/tmp/err", createdAt: epoch)
    }

    /// The four system reasons, listed rather than derived: `SystemReason` is
    /// not `CaseIterable` and this story does not touch `ElliotModel`. The real
    /// guard against a fifth reason going unnamed is that `historyPhrase`
    /// switches without a `default:` — it would not compile. This list is the
    /// witness, not the guard.
    private static let systemReasons: [MoveOrigin.SystemReason] = [
        .prBecameReady, .prMergedExternally, .reconciliation, .githubImport,
    ]

    private static var allOrigins: [MoveOrigin] {
        [.userDrag, .mcp(client: "elliot-mcp")] + systemReasons.map { .system(reason: $0) }
    }

    // MARK: - Order

    /// The store already answers `ORDER BY at DESC`. Re-sorting here would mean
    /// two orderings to keep agreeing, and the one a test pins would stop being
    /// the one SQLite returns — so the rows pass straight through, and this is
    /// the assertion that says so.
    @Test("Rows keep the order they arrived in, and are not re-sorted")
    func orderIsPreservedVerbatim() {
        let audits = [
            Self.audit(from: .inReview, to: .done, secondsAfterEpoch: 300),
            Self.audit(from: .todo, to: .inProgress, secondsAfterEpoch: 100),
            Self.audit(from: .backlog, to: .todo, secondsAfterEpoch: 200),
        ]
        let rows = MoveHistory.rows(audits: audits, runs: [])

        #expect(rows.map(\.at) == audits.map(\.at))
        #expect(rows.map(\.id) == audits.map(\.id))
        #expect(rows.map(\.from) == [.inReview, .todo, .backlog])
        #expect(rows.map(\.to) == [.done, .inProgress, .todo])
    }

    // MARK: - The run join

    @Test("An audit whose run is loaded names the skill it started")
    func joinsARunThatIsLoaded() throws {
        let runID = UUID()
        let rows = MoveHistory.rows(
            audits: [Self.audit(runID: runID)],
            runs: [Self.run(id: runID, kind: .createIssue)])

        let ref = try #require(rows[0].run)
        #expect(ref.id == runID)
        #expect(ref.skillName == "create-issue")
    }

    /// The case that decides whether this block can be trusted. `runsByCard` is
    /// capped at 20 and `audits` at 100, so a move whose run has scrolled out of
    /// the window is reachable — and a row that fell silent would claim the move
    /// started nothing, which is the one thing a board built on "`gh` is the
    /// fact" must never say. It says a run started and admits it cannot name it.
    @Test("An audit whose run is outside the window still says a run started")
    func admitsARunItCannotName() throws {
        let runID = UUID()
        let rows = MoveHistory.rows(audits: [Self.audit(runID: runID)], runs: [])

        let ref = try #require(rows[0].run, "the row fell silent about a run it knows started")
        #expect(ref.id == runID)
        #expect(ref.skillName == nil)
    }

    @Test("An audit that started nothing has no run at all")
    func noRunMeansNoRef() {
        #expect(MoveHistory.rows(audits: [Self.audit(runID: nil)], runs: [])[0].run == nil)
    }

    /// A wrong join is worse than no join: it would name the wrong skill.
    @Test("A run belonging to a different move is not borrowed")
    func doesNotBorrowAnUnrelatedRun() throws {
        let mine = UUID()
        let theirs = UUID()
        let rows = MoveHistory.rows(
            audits: [Self.audit(runID: mine)],
            runs: [Self.run(id: theirs, kind: .mergePR)])

        #expect(try #require(rows[0].run).skillName == nil)
    }

    // MARK: - The origin fragment

    @Test("Every origin and every system reason produces a non-empty fragment")
    func historyLabelIsTotal() {
        let origins = Self.allOrigins
        for origin in origins {
            #expect(!origin.historyLabel.isEmpty, "\(origin)")
        }
        // And they say different things — one fragment for four system reasons
        // would lose exactly the detail this block exists to show.
        #expect(Set(origins.map(\.historyLabel)).count == origins.count)
    }

    @Test("An MCP origin renders the client it holds")
    func mcpNamesItsClient() {
        #expect(MoveOrigin.mcp(client: "agent-x").historyLabel.contains("agent-x"))
    }

    /// Before #101 every MCP move recorded the literal `"mcp"`; a row rendering
    /// an empty name must not leave a dangling separator behind it.
    @Test("An MCP origin with no name renders no trailing separator")
    func mcpWithoutANameHasNoDanglingSeparator() {
        let label = MoveOrigin.mcp(client: "").historyLabel
        #expect(label == "MCP")
        #expect(!label.hasSuffix("·"))
        #expect(!label.hasSuffix(" "))
    }

    // MARK: - Criterion 4, made structural

    /// The arrival sentence in the header and the origin fragment in a row
    /// describe the same event, and criterion 4 is that they never converge into
    /// the same words. Asserted rather than remembered: they are two functions
    /// with two registers, and the day someone "unifies" them this fails.
    ///
    /// Substring in both directions, because containment either way is how a
    /// row would end up reading as the header's sentence.
    @Test("No history fragment is, or is inside, an arrival sentence")
    func historyLabelNeverConvergesWithArrivalNote() {
        let origins = Self.allOrigins
        let notes = origins.compactMap(\.arrivalNote)
        #expect(!notes.isEmpty, "arrivalNote answered for nothing — the test proves nothing")

        for origin in origins {
            let label = origin.historyLabel
            for note in notes {
                #expect(label != note)
                #expect(!note.contains(label), "\"\(label)\" reads as part of \"\(note)\"")
                #expect(!label.contains(note))
            }
        }
    }

    /// The other half of criterion 4, and the reason the header keeps working
    /// untouched: `arrivalNote` was never a summary of the newest move. It is
    /// silent for a drag and for MCP, so it could not have covered the history
    /// even if someone wanted it to.
    @Test("The arrival sentence still speaks only for system moves")
    func arrivalNoteRemainsSystemOnly() {
        #expect(MoveOrigin.userDrag.arrivalNote == nil)
        #expect(MoveOrigin.mcp(client: "agent-x").arrivalNote == nil)
        for reason in Self.systemReasons {
            #expect(MoveOrigin.system(reason: reason).arrivalNote != nil)
        }
    }

    // MARK: - The cap

    /// A list read at its limit might be missing older moves, and presenting it
    /// as complete would be the same failure as reporting an unchecked thing as
    /// fine. The block says so instead.
    @Test("A read that came back at the cap is reported as possibly partial")
    func capIsDetected() {
        #expect(MoveHistory.isCapped(count: 100, limit: 100))
        #expect(!MoveHistory.isCapped(count: 99, limit: 100))
        #expect(!MoveHistory.isCapped(count: 0, limit: 100))
        // Defensive rather than reachable: a count past the limit is still the
        // "you may be missing some" answer, never the reassuring one.
        #expect(MoveHistory.isCapped(count: 101, limit: 100))
    }

    @Test("An empty history yields no rows")
    func emptyIsEmpty() {
        #expect(MoveHistory.rows(audits: [], runs: []).isEmpty)
    }
}
