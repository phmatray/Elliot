import ElliotModel
import ElliotProcess
import ElliotStore
import Foundation
import Testing

@testable import ElliotEngine

/// Records what the board asked for without spawning anything.
private actor FakeLauncher: RunLaunching {
    private(set) var launched: [UUID] = []
    private(set) var cancelled: [UUID] = []

    func launch(runID: UUID) async { launched.append(runID) }
    func cancel(runID: UUID) async { cancelled.append(runID) }
    func launchedRuns() -> [UUID] { launched }
}

private struct Fixture {
    var store: BoardStore
    var board: BoardService
    var launcher: FakeLauncher
    var repo: Repo

    static func make(permissionMode: PermissionMode = .bypassPermissions) async throws -> Fixture {
        let store = try BoardStore.inMemory()
        let launcher = FakeLauncher()
        let board = BoardService(store: store, launcher: launcher)
        var repo = Repo(
            path: "/tmp/repo-\(UUID().uuidString)",
            nameWithOwner: "phmatray/Elliot",
            displayName: "Elliot"
        )
        repo.permissionMode = permissionMode
        try await store.saveRepo(repo)
        return Fixture(store: store, board: board, launcher: launcher, repo: repo)
    }

    /// The head `Fixtures/gh/prs-head-oid.json` reports for pull request 7.
    ///
    /// Named here as well as in `PRVerdictReaderTests` because the two suites
    /// are asking different questions of the same fixture — that one tests the
    /// reader, this one tests which policy `BoardService` hands it — and a
    /// shared constant would need a target both can import, which `TestSupport`
    /// deliberately is not (it "depends on nothing", `Package.swift`).
    static let liveHead = "b7c1f0aa5d2e4c9188ff0e6a2d3b4c5d6e7f8091"

    /// A board that can actually establish a verdict, and a card in In Review
    /// whose stored reading is clean, approved and carries a real build check.
    ///
    /// `headRefOid` is the one thing a caller varies: pass `liveHead` and the
    /// row is about the commit `gh` reports, so it is fresh and the merge is
    /// allowed; pass anything else and the row is about a commit that has been
    /// pushed past, which only the sha rule can see.
    static func green(headRefOid: String) async throws -> (Fixture, Card) {
        var f = try await make()
        // A real `PRVerdictReader`, spawning the real `ProcessRunner` against
        // `Scripts/fake-gh.sh`: the seam `GHClient` already has, so the spawn,
        // the subprocess and the ISO-8601 decode all stay under test.
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // ElliotEngineTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // ElliotKit
            .deletingLastPathComponent()  // repository root
        let gh = GHClient(config: ToolConfig(
            claudePath: "", ghPath: root.appendingPathComponent("Scripts/fake-gh.sh").path,
            gitPath: "",
            environment: [
                "FAKE_GH_MODE": "ok",
                "FAKE_GH_PRS": root.appendingPathComponent("Fixtures/gh/prs-head-oid.json").path,
            ]))
        f.board = BoardService(
            store: f.store, launcher: f.launcher,
            verdicts: PRVerdictReader(store: f.store, gh: gh))

        var card = try await f.board.createCard(repoID: f.repo.id, title: "Run log").card
        card.column = .inReview
        card.prNumber = 7
        try await f.store.saveCard(card)

        // Seconds old, so `PRStatus.maximumAge` (600 s) has nothing to say and
        // the sha rule is the only thing that can call this reading stale.
        try await f.store.savePRStatus(PRStatus(
            repoID: f.repo.id, prNumber: 7, headRefOid: headRefOid, checkedAt: Date(),
            rawMergeStateStatus: "CLEAN", rawMergeable: "MERGEABLE",
            rawReviewDecision: "APPROVED",
            checks: [
                GHMergeStatus.StatusCheck(
                    name: "build-and-test", conclusion: "SUCCESS", status: "COMPLETED"),
            ]))
        return (f, card)
    }
}

@Suite("Board service")
struct BoardServiceTests {

    @Test("Backlog to To Do enqueues a create-issue run built from the story")
    func triggersCreateIssue() async throws {
        let f = try await Fixture.make()
        let card = try await f.board.createCard(
            repoID: f.repo.id,
            title: "Run log",
            story: UserStory(
                role: "developer",
                want: "to see the run log inside the card",
                benefit: "I can diagnose without a terminal"
            )
        ).card

        let result = try await f.board.move(
            cardID: card.id, to: .todo, origin: .userDrag, requiresVerifiedGreen: false)
        guard case .moved(let runID?) = result else {
            Issue.record("expected a run, got \(result)")
            return
        }

        let run = try #require(try await f.store.run(id: runID))
        #expect(run.kind == .createIssue)
        #expect(run.prompt == "/ai-migration-kit:create-issue As a developer, I want to see the "
            + "run log inside the card, so that I can diagnose without a terminal.")
        #expect(run.state == .queued)
        #expect(await f.launcher.launchedRuns() == [runID])
        #expect(try await f.store.card(id: card.id)?.column == .todo)
    }

    @Test("To Do to In Progress enqueues implement-issue with only the number")
    func triggersImplementIssue() async throws {
        let f = try await Fixture.make()
        var card = try await f.board.createCard(repoID: f.repo.id, title: "Run log").card
        card.column = .todo
        card.issueNumber = 47
        try await f.store.saveCard(card)

        let result = try await f.board.move(
            cardID: card.id, to: .inProgress, origin: .userDrag, requiresVerifiedGreen: false)
        guard case .moved(let runID?) = result else {
            Issue.record("expected a run")
            return
        }
        let run = try #require(try await f.store.run(id: runID))
        #expect(run.prompt == "/ai-migration-kit:implement-issue 47")
    }

    @Test("In Review to Done asks for follow-ups, then merges")
    func mergeNeedsFollowUpsFirst() async throws {
        let f = try await Fixture.make()
        var card = try await f.board.createCard(repoID: f.repo.id, title: "Run log").card
        card.column = .inReview
        card.prNumber = 279
        try await f.store.saveCard(card)

        let asked = try await f.board.move(
            cardID: card.id, to: .done, origin: .userDrag, requiresVerifiedGreen: false)
        #expect(asked == .needsInput(.followUps(prNumber: 279)))
        // Nothing moved while the question is outstanding.
        #expect(try await f.store.card(id: card.id)?.column == .inReview)

        let merged = try await f.board.move(
            cardID: card.id, to: .done, origin: .userDrag,
            followUps: ["add snapshot tests"], requiresVerifiedGreen: false
        )
        guard case .moved(let runID?) = merged else {
            Issue.record("expected a run")
            return
        }
        let run = try #require(try await f.store.run(id: runID))
        #expect(run.prompt == #"/ai-migration-kit:merge-pr 279 --follow-up "add snapshot tests""#)
        #expect(try await f.store.card(id: card.id)?.column == .done)
    }

    @Test("An MCP move goes through the very same rules as a drag")
    func mcpMoveUsesTheSameRules() async throws {
        let f = try await Fixture.make()
        let card = try await f.board.createCard(repoID: f.repo.id, title: "Add CSV export").card

        let result = try await f.board.move(
            cardID: card.id, to: .todo, origin: .mcp(client: "claude-code"),
            requiresVerifiedGreen: false
        )
        guard case .moved(let runID?) = result else {
            Issue.record("expected a run")
            return
        }
        #expect(try await f.store.run(id: runID)?.kind == .createIssue)

        let audits = try await f.store.audits(cardID: card.id)
        #expect(audits.first?.origin == .mcp(client: "claude-code"))
    }

    // MARK: - Refusals

    @Test("Moving to In Progress with no issue number is refused, and nothing moves")
    func blockedWithoutIssue() async throws {
        let f = try await Fixture.make()
        var card = try await f.board.createCard(repoID: f.repo.id, title: "Run log").card
        card.column = .todo
        try await f.store.saveCard(card)

        let result = try await f.board.move(
            cardID: card.id, to: .inProgress, origin: .userDrag, requiresVerifiedGreen: false)
        #expect(result == .blocked(.missingIssueNumber))
        #expect(try await f.store.card(id: card.id)?.column == .todo)
        #expect(try await f.store.runs(cardID: card.id).isEmpty)
        #expect(try await f.store.audits(cardID: card.id).isEmpty)
    }

    @Test("A card already running refuses a second move")
    func blockedWhileRunning() async throws {
        let f = try await Fixture.make()
        let card = try await f.board.createCard(repoID: f.repo.id, title: "Run log").card
        _ = try await f.board.move(
            cardID: card.id, to: .todo, origin: .userDrag, requiresVerifiedGreen: false)

        var running = try #require(try await f.store.runs(cardID: card.id).first)
        running.state = .running
        try await f.store.saveRun(running)

        let second = try await f.board.move(
            cardID: card.id, to: .inProgress, origin: .userDrag, requiresVerifiedGreen: false)
        #expect(second == .blocked(.runAlreadyInFlight(runID: running.id)))
    }

    @Test("A disabled repo refuses moves")
    func blockedByDisabledRepo() async throws {
        let f = try await Fixture.make()
        var repo = f.repo
        repo.isEnabled = false
        try await f.store.saveRepo(repo)

        let card = try await f.board.createCard(repoID: f.repo.id, title: "Run log").card
        let result = try await f.board.move(
            cardID: card.id, to: .todo, origin: .userDrag, requiresVerifiedGreen: false)
        #expect(result == .blocked(.repoDisabled))
    }

    @Test("An incomplete story is refused before a run is spent on it")
    func blockedByIncompleteStory() async throws {
        let f = try await Fixture.make()
        let card = try await f.board.createCard(
            repoID: f.repo.id,
            title: "Run log",
            story: UserStory(role: "developer", want: "the log", benefit: "")
        ).card
        let result = try await f.board.move(
            cardID: card.id, to: .todo, origin: .userDrag, requiresVerifiedGreen: false)
        #expect(result == .blocked(.incompleteStory))
        #expect(try await f.store.runs(cardID: card.id).isEmpty)
    }

    // MARK: - System moves

    @Test("A system move never triggers a run")
    func systemMoveIsInert() async throws {
        let f = try await Fixture.make()
        var card = try await f.board.createCard(repoID: f.repo.id, title: "Run log").card
        card.column = .inProgress
        card.issueNumber = 47
        card.prNumber = 279
        try await f.store.saveCard(card)

        await f.board.applySystemMove(cardID: card.id, to: .inReview, reason: .prBecameReady)

        #expect(try await f.store.card(id: card.id)?.column == .inReview)
        #expect(try await f.store.runs(cardID: card.id).isEmpty)
        let audits = try await f.store.audits(cardID: card.id)
        #expect(audits.first?.origin == .system(reason: .prBecameReady))
    }

    @Test("A system move lands even while a run holds the card")
    func systemMoveIgnoresActiveRun() async throws {
        // implement-issue flips its PR ready as its last act, so the watcher
        // often sees it before the process has exited.
        let f = try await Fixture.make()
        var card = try await f.board.createCard(repoID: f.repo.id, title: "Run log").card
        card.column = .inProgress
        card.issueNumber = 47
        try await f.store.saveCard(card)

        var run = SkillRun(
            cardID: card.id, repoID: f.repo.id, kind: .implementIssue,
            prompt: "x", cwd: f.repo.path, logPath: "/tmp/a", stderrPath: "/tmp/b",
            createdAt: Date()
        )
        run.state = .running
        try await f.store.saveRun(run)

        await f.board.applySystemMove(cardID: card.id, to: .inReview, reason: .prBecameReady)
        #expect(try await f.store.card(id: card.id)?.column == .inReview)
    }

    // MARK: - Housekeeping

    @Test("Reordering inside a column changes nothing but the order")
    func reordering() async throws {
        let f = try await Fixture.make()
        let card = try await f.board.createCard(repoID: f.repo.id, title: "Run log").card
        try await f.board.reorder(cardID: card.id, between: 100, and: 200)
        #expect(try await f.store.card(id: card.id)?.orderIndex == 150)
        #expect(try await f.store.audits(cardID: card.id).isEmpty)
    }

    @Test("A move that changes nothing is refused as the same column")
    func sameColumnRefused() async throws {
        let f = try await Fixture.make()
        let card = try await f.board.createCard(repoID: f.repo.id, title: "Run log").card
        let result = try await f.board.move(
            cardID: card.id, to: .backlog, origin: .userDrag, requiresVerifiedGreen: false)
        #expect(result == .blocked(.sameColumn))
    }

    @Test("An unknown card is an error, not a silent no-op")
    func unknownCard() async throws {
        let f = try await Fixture.make()
        await #expect(throws: BoardError.self) {
            try await f.board.move(
                cardID: UUID(), to: .todo, origin: .userDrag, requiresVerifiedGreen: false)
        }
    }

    // MARK: - Editing

    @Test("Editing an unfiled card rewrites its label, story and note")
    func editsUnfiledCard() async throws {
        let f = try await Fixture.make()
        let card = try await f.board.createCard(
            repoID: f.repo.id,
            title: "Run lgo",
            story: UserStory(role: "developer", want: "teh log", benefit: "no terminal")
        ).card

        try await f.board.updateCard(
            id: card.id,
            title: "Run log",
            body: "",
            story: UserStory(
                role: "developer", want: "the log", benefit: "no terminal",
                acceptanceCriteria: ["it tails live"]
            )
        )

        let stored = try #require(try await f.store.card(id: card.id))
        #expect(stored.title == "Run log")
        #expect(stored.story?.want == "the log")
        #expect(stored.story?.acceptanceCriteria == ["it tails live"])
    }

    @Test("Editing cannot move a card or touch what the funnel owns")
    func editLeavesTheFunnelAlone() async throws {
        let f = try await Fixture.make()
        var card = try await f.board.createCard(repoID: f.repo.id, title: "Run log").card
        card.column = .todo
        card.orderIndex = 4096
        card.branch = "feat/12-run-log"
        try await f.store.saveCard(card)

        try await f.board.updateCard(id: card.id, title: "Run log v2", body: "note", story: nil)

        let stored = try #require(try await f.store.card(id: card.id))
        #expect(stored.title == "Run log v2")
        #expect(stored.body == "note")
        #expect(stored.column == .todo)
        #expect(stored.orderIndex == 4096)
        #expect(stored.branch == "feat/12-run-log")
    }

    @Test("A filed card is refused — the issue is the record from that point on")
    func refusesFiledCard() async throws {
        let f = try await Fixture.make()
        var card = try await f.board.createCard(repoID: f.repo.id, title: "Run log").card
        card.issueNumber = 42
        try await f.store.saveCard(card)

        await #expect(throws: BoardError.self) {
            try await f.board.updateCard(id: card.id, title: "Renamed", body: "", story: nil)
        }
        #expect(try await f.store.card(id: card.id)?.title == "Run log")
    }

    @Test("Editing a card that is gone reports it rather than resurrecting it")
    func refusesMissingCard() async throws {
        let f = try await Fixture.make()

        await #expect(throws: BoardError.self) {
            try await f.board.updateCard(id: UUID(), title: "Ghost", body: "", story: nil)
        }
    }

    @Test("Editing rewrites the labels the card asks for")
    func editsLabels() async throws {
        let f = try await Fixture.make()
        let card = try await f.board.createCard(
            repoID: f.repo.id, title: "Run log", labels: ["bug"]
        ).card

        try await f.board.updateCard(
            id: card.id, title: "Run log", body: "", story: nil,
            labels: ["documentation", "enhancement"]
        )

        #expect(try await f.store.card(id: card.id)?.labels == ["documentation", "enhancement"])
    }

    /// Labels obey the same rule as every other thing a human wrote on a card:
    /// correctable until it is filed, refused afterwards, because from then on
    /// github.com holds the labels and a card that disagreed would be a card
    /// that lies.
    @Test("A filed card refuses a label edit too")
    func refusesLabelEditOnFiledCard() async throws {
        let f = try await Fixture.make()
        var card = try await f.board.createCard(
            repoID: f.repo.id, title: "Run log", labels: ["bug"]
        ).card
        card.issueNumber = 42
        try await f.store.saveCard(card)

        await #expect(throws: BoardError.self) {
            try await f.board.updateCard(
                id: card.id, title: "Run log", body: "", story: nil, labels: ["documentation"]
            )
        }
        #expect(try await f.store.card(id: card.id)?.labels == ["bug"])
    }

    /// ⚠️ `nil` is "the caller said nothing about labels", and it has to be,
    /// because one caller genuinely says nothing: `board_update_card` is a wire
    /// case that predates labels and names only title, body and story. Were the
    /// parameter a plain `[String]`, that path would have to pass `[]` — and
    /// every agent edit of a card's title would silently strip the labels a
    /// human chose. Same shape as `MoveContext.providedFollowUps`.
    @Test("An edit that says nothing about labels leaves them alone")
    func silentEditKeepsLabels() async throws {
        let f = try await Fixture.make()
        let card = try await f.board.createCard(
            repoID: f.repo.id, title: "Run log", labels: ["bug", "documentation"]
        ).card

        try await f.board.updateCard(id: card.id, title: "Run log v2", body: "", story: nil)

        let stored = try #require(try await f.store.card(id: card.id))
        #expect(stored.title == "Run log v2")
        #expect(stored.labels == ["bug", "documentation"], "an unspoken field is not an empty one")
    }

    // MARK: - The green guard

    @Test("A merge asked for under the green guard is refused when nothing was read")
    func unattendedMergeWithoutAVerdictIsRefused() async throws {
        // The board's half of the guard. `Fixture.make` builds a `BoardService`
        // with no `PRVerdictReader`, so there is nothing that could establish a
        // verdict — and the answer to that has to be a refusal, never a merge.
        let f = try await Fixture.make()
        var card = try await f.board.createCard(repoID: f.repo.id, title: "Run log").card
        card.column = .inReview
        card.prNumber = 279
        try await f.store.saveCard(card)

        let result = try await f.board.move(
            cardID: card.id, to: .done, origin: .autoDev(sessionID: UUID()),
            followUps: [], requiresVerifiedGreen: true
        )
        #expect(result == .blocked(.notVerifiedGreen(reason: .noReading)))
        #expect(try await f.store.card(id: card.id)?.column == .inReview)
        let launched = await f.launcher.launchedRuns()
        #expect(launched.isEmpty, "a merge ran on a verdict nobody established")
    }

    @Test("The same merge, not asked to be verified, still runs")
    func watchedMergeStillRuns() async throws {
        // The control the refusal above cannot be: without it, a board that
        // refused *every* merge would pass.
        let f = try await Fixture.make()
        var card = try await f.board.createCard(repoID: f.repo.id, title: "Run log").card
        card.column = .inReview
        card.prNumber = 279
        try await f.store.saveCard(card)

        let result = try await f.board.move(
            cardID: card.id, to: .done, origin: .userDrag, followUps: [],
            requiresVerifiedGreen: false
        )
        guard case .moved(let runID?) = result else {
            Issue.record("expected a run, got \(result)")
            return
        }
        #expect(try await f.store.run(id: runID)?.kind == .mergePR)
    }

    /// ⛔ **The gate has to be able to open, or it is not a gate.**
    ///
    /// Every other test of `requiresVerifiedGreen: true` in this package asserts
    /// a refusal, so deleting the verdict read from `proposeMove` outright — the
    /// two lines that call `PRVerdictReader` — turns the guard into a permanent
    /// "no" and every one of them stays green. This is the test that goes red,
    /// and it is the only one: measured, by making exactly that deletion.
    @Test("A verified green really does merge — the guard opens, not just closes")
    func unattendedMergeOnAVerifiedGreen() async throws {
        let (f, card) = try await Fixture.green(headRefOid: Fixture.liveHead)

        let result = try await f.board.move(
            cardID: card.id, to: .done, origin: .autoDev(sessionID: UUID()),
            followUps: [], requiresVerifiedGreen: true
        )
        guard case .moved(let runID?) = result else {
            Issue.record("a verified green was refused: \(result)")
            return
        }
        #expect(try await f.store.run(id: runID)?.kind == .mergePR)
        #expect(try await f.store.card(id: card.id)?.column == .done)
    }

    /// ⛔ **The merge path asks `gh` for the real head; the age rule alone is not
    /// enough.**
    ///
    /// `PRVerdictReader` already pins the difference between its two policies
    /// (`PRVerdictReaderTests.movedHeadIsStale`), but nothing pinned which one
    /// `BoardService` picks — so `head: .establish` could be changed to
    /// `.ageAlone` and the suite stayed green, because the only test reaching
    /// this code had no stored row and both policies answer nil to that.
    ///
    /// Here the row is seconds old, so `PRStatus.maximumAge` says nothing at
    /// all: the sha rule is the *only* thing that can catch it, and only
    /// `.establish` asks. Under `.ageAlone` this reading is clean, approved,
    /// build-checked and fresh — it merges. Measured, by making that change.
    @Test("A reading about a commit that is no longer the head refuses the merge")
    func unattendedMergeRefusesAReadingAboutAnOlderCommit() async throws {
        // `gh` reports `liveHead` for this pull request; the stored row is about
        // a commit somebody has since pushed past.
        let (f, card) = try await Fixture.green(
            headRefOid: "0000000000000000000000000000000000000000")

        let result = try await f.board.move(
            cardID: card.id, to: .done, origin: .autoDev(sessionID: UUID()),
            followUps: [], requiresVerifiedGreen: true
        )
        // `.sign(.unknown)`, not `.noReading`: the row was read, and it is about
        // an older commit. That is the sentence `PRSign.unknown.summary` writes.
        #expect(result == .blocked(.notVerifiedGreen(reason: .sign(.unknown))))
        #expect(try await f.store.card(id: card.id)?.column == .inReview)
        #expect(await f.launcher.launchedRuns().isEmpty)
    }
}

@Suite("Scheduler admission")
struct SchedulerAdmissionTests {

    private func run(_ kind: SkillKind, repo: UUID) -> SkillRun {
        SkillRun(
            cardID: UUID(), repoID: repo, kind: kind, prompt: "x", cwd: "/tmp",
            logPath: "/tmp/a", stderrPath: "/tmp/b", createdAt: Date()
        )
    }

    private func scheduler(maxConcurrent: Int = 2) throws -> RunScheduler {
        let store = try BoardStore.inMemory()
        let config = ToolConfig(
            claudePath: "/usr/bin/true", ghPath: "/usr/bin/true",
            gitPath: "/usr/bin/true", environment: [:]
        )
        return RunScheduler(
            store: store, toolConfig: config,
            verifier: Verifier(gh: .init(config: config)),
            limits: SchedulerLimits(maxConcurrent: maxConcurrent, maxConcurrentAnalyses: 3)
        )
    }

    @Test("Two implement-issue runs in one repo may overlap — worktrees isolate git")
    func implementRunsOverlap() async throws {
        let scheduler = try scheduler()
        let repo = UUID()
        await scheduler.testOnlyMarkInFlight(run(.implementIssue, repo: repo))
        #expect(await scheduler.canStart(run(.implementIssue, repo: repo)))
    }

    @Test("A merge waits for everything else in its repo")
    func mergeIsExclusive() async throws {
        let scheduler = try scheduler()
        let repo = UUID()
        await scheduler.testOnlyMarkInFlight(run(.implementIssue, repo: repo))
        #expect(!(await scheduler.canStart(run(.mergePR, repo: repo))))
    }

    @Test("Nothing else starts in a repo that is merging")
    func nothingRunsDuringAMerge() async throws {
        let scheduler = try scheduler()
        let repo = UUID()
        await scheduler.testOnlyMarkInFlight(run(.mergePR, repo: repo))
        #expect(!(await scheduler.canStart(run(.implementIssue, repo: repo))))
        #expect(!(await scheduler.canStart(run(.createIssue, repo: repo))))
        #expect(!(await scheduler.canStart(run(.mergePR, repo: repo))))
    }

    @Test("Two create-issue runs in one repo would each miss the other's issue")
    func createIssueIsSerialisedPerRepo() async throws {
        let scheduler = try scheduler()
        let repo = UUID()
        await scheduler.testOnlyMarkInFlight(run(.createIssue, repo: repo))
        #expect(!(await scheduler.canStart(run(.createIssue, repo: repo))))
        // A different repo is unaffected.
        #expect(await scheduler.canStart(run(.createIssue, repo: UUID())))
    }

    @Test("The global cap holds across repos — worktrees isolate git, not .build")
    func globalCap() async throws {
        let scheduler = try scheduler(maxConcurrent: 2)
        await scheduler.testOnlyMarkInFlight(run(.implementIssue, repo: UUID()))
        await scheduler.testOnlyMarkInFlight(run(.implementIssue, repo: UUID()))
        #expect(!(await scheduler.canStart(run(.implementIssue, repo: UUID()))))
    }

    @Test("A refused tool makes a zero-exit run something other than a success")
    func runStateFromOutcome() {
        let clean = RunResult(
            subtype: "success", isError: false, text: "done", numTurns: 3, durationMS: 1,
            totalCostUSD: 0.1, sessionID: nil, stopReason: nil, terminalReason: "completed",
            permissionDenials: [], errors: []
        )
        #expect(RunScheduler.state(for: .init(
            exitCode: 0, wasTerminated: false, result: clean, stderr: ""
        )) == .succeeded)

        var denied = clean
        denied.permissionDenials = [PermissionDenial(toolName: "Bash", toolUseID: "tu_1")]
        #expect(RunScheduler.state(for: .init(
            exitCode: 0, wasTerminated: false, result: denied, stderr: ""
        )) == .completedWithDenials)

        var errored = clean
        errored.isError = true
        errored.subtype = "error_max_turns"
        #expect(RunScheduler.state(for: .init(
            exitCode: 0, wasTerminated: false, result: errored, stderr: ""
        )) == .failed)

        #expect(RunScheduler.state(for: .init(
            exitCode: 143, wasTerminated: true, result: nil, stderr: ""
        )) == .cancelled)

        #expect(RunScheduler.state(for: nil) == .failed)
    }
}

@Suite("Deleting and editing imported cards")
struct ImportedCardLifecycleTests {

    @Test("Deleting a filed card dismisses its issue so a refresh cannot resurrect it")
    func deletingDismisses() async throws {
        let f = try await Fixture.make()
        let card = try await f.board.adoptCard(CardSeed(
            repoID: f.repo.id, title: "Dependency Dashboard", body: "",
            column: .todo, issueNumber: 4, createdAt: Date(timeIntervalSince1970: 0)))

        try await f.board.deleteCard(id: card.id)

        #expect(try await f.store.dismissals(repoID: f.repo.id) == [ExternalRef(kind: .issue, number: 4)])
    }

    @Test("Deleting an unfiled card dismisses nothing")
    func deletingAPlainCardDismissesNothing() async throws {
        let f = try await Fixture.make()
        let card = try await f.board.createCard(repoID: f.repo.id, title: "just an idea").card
        try await f.board.deleteCard(id: card.id)
        #expect(try await f.store.dismissals(repoID: f.repo.id).isEmpty)
    }

    @Test("A card carrying only a pull request refuses an edit")
    func pullRequestOnlyCardIsNotEditable() async throws {
        let f = try await Fixture.make()
        let card = try await f.board.adoptCard(CardSeed(
            repoID: f.repo.id, title: "chore(deps): bump GRDB", body: "",
            column: .inReview, prNumber: 20, createdAt: Date(timeIntervalSince1970: 0)))

        await #expect(throws: BoardError.self) {
            try await f.board.updateCard(id: card.id, title: "mine now", body: "", story: nil)
        }
    }
}
