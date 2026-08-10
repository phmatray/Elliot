import ElliotModel
import ElliotProcess
import ElliotStore
import Foundation
import TestSupport
import Testing

@testable import ElliotEngine

/// Starting one appraisal, and the ownership everything downstream rests on.
///
/// The card's write window is symmetric: `commitMove` writes every column from a
/// `Card` read three `await`s earlier, and so do the pollers. A one-directional
/// fix leaves the other half. It is closed by **ownership** — the appraisal run
/// holds its card, so the two writers cannot be in flight at once — and both
/// directions are asserted here.
@Suite("Appraisal service")
struct AppraisalServiceTests {

    private final class LaunchRecorder: RunLaunching, @unchecked Sendable {
        private let lock = NSLock()
        private var _launched: [UUID] = []
        var launched: [UUID] { lock.withLock { _launched } }
        func launch(runID: UUID) async { lock.withLock { _launched.append(runID) } }
        func cancel(runID: UUID) async {}
    }

    /// A gate that states a verdict instead of running six subprocesses and a
    /// networked `gh label list` for one — the same stub shape
    /// `AnalysisServiceTests` uses, and for the same reason.
    ///
    /// ⚠️ `.failing`, never a `Bool`: `RepoGating` answers a three-valued
    /// `PreflightState` precisely so that *nobody looked* cannot be spelled the
    /// same way as *asked and clear*.
    private struct ClosedGate: RepoGating {
        func verdict(for repo: Repo) async -> PreflightState { .failing }
    }

    private struct Stack {
        var store: BoardStore
        var board: BoardService
        var launcher: LaunchRecorder
        var service: AppraisalService
        var repo: Repo
        var card: Card
    }

    private func makeStack(
        gate: any RepoGating = OpenGate(), enabled: Bool = true
    ) async throws -> Stack {
        // `appraise` resolves an artifact path through `StoreLocation` and
        // creates the directory for it, so the home has to be final first.
        _ = TestHome.root
        let store = try BoardStore.inMemory()
        var repo = Repo(path: "/tmp/r", nameWithOwner: "phmatray/Elliot", displayName: "Elliot")
        repo.isEnabled = enabled
        try await store.saveRepo(repo)

        let now = Date()
        let card = Card(
            repoID: repo.id, title: "Cache the login shell environment",
            story: UserStory(
                role: "user", want: "Elliot to start without waiting on a login shell",
                benefit: "the board is usable immediately"),
            columnEnteredAt: now, createdAt: now, updatedAt: now
        )
        try await store.saveCard(card)

        let launcher = LaunchRecorder()
        return Stack(
            store: store,
            board: BoardService(store: store, launcher: launcher),
            launcher: launcher,
            service: AppraisalService(store: store, launcher: launcher, gate: gate),
            repo: repo, card: card
        )
    }

    @Test("An appraisal is one run, carrying the card and no analysis")
    func oneRunPerCard() async throws {
        let stack = try await makeStack()
        let run = try await stack.service.appraise(cardID: stack.card.id)

        #expect(run.kind == .appraiseCards)
        // The XOR the schema checks, satisfied as written: a card, no analysis.
        #expect(run.cardID == stack.card.id)
        #expect(run.analysisID == nil)
        #expect(run.analysisAngle == nil)
        #expect(run.cwd == stack.repo.path)
        #expect(run.state == .queued)
        #expect(stack.launcher.launched == [run.id])

        // It really is in the store, so the CHECK constraint really was met.
        #expect(try await stack.store.run(id: run.id)?.kind == .appraiseCards)
    }

    @Test("The prompt announces the run's own artifact path")
    func promptAnnouncesTheArtifact() async throws {
        let stack = try await makeStack()
        let run = try await stack.service.appraise(cardID: stack.card.id)
        let announced = AnalysisPromptBuilder.outputPath(in: run.prompt)
        #expect(announced == StoreLocation.appraisalArtifactURL(runID: run.id).path)
        // And the directory exists, so `--add-dir` points somewhere real.
        #expect(FileManager.default.fileExists(
            atPath: StoreLocation.appraisalRunDirectory(runID: run.id).path))
        // The card's own words reached it.
        #expect(run.prompt.contains("Cache the login shell environment"))
    }

    @Test("A repository Preflight is failing refuses the appraisal, and launches nothing")
    func gateRefuses() async throws {
        let stack = try await makeStack(gate: ClosedGate())
        await #expect(throws: AppraisalError.repoRefused(.preflightBlocked)) {
            try await stack.service.appraise(cardID: stack.card.id)
        }
        #expect(stack.launcher.launched.isEmpty)
        #expect(try await stack.store.runs(cardID: stack.card.id).isEmpty)
    }

    @Test("A disabled repository refuses the appraisal by the same rule")
    func disabledRefuses() async throws {
        let stack = try await makeStack(enabled: false)
        await #expect(throws: AppraisalError.repoRefused(.repoDisabled)) {
            try await stack.service.appraise(cardID: stack.card.id)
        }
    }

    /// The order `evaluateMove` uses, and the one `UnattendedStartRefusal` is
    /// written to agree with: a switch the reader threw is named before a
    /// diagnosis Elliot made, because the remedy for one is a toggle and the
    /// remedy for the other is a repair.
    @Test("A repository that is both off and blocked is named as off")
    func disabledWinsOverBlocked() async throws {
        let stack = try await makeStack(gate: ClosedGate(), enabled: false)
        await #expect(throws: AppraisalError.repoRefused(.repoDisabled)) {
            try await stack.service.appraise(cardID: stack.card.id)
        }
    }

    @Test("An unknown card is named, not silently ignored")
    func unknownCard() async throws {
        let stack = try await makeStack()
        let missing = UUID()
        await #expect(throws: AppraisalError.cardNotFound(missing)) {
            try await stack.service.appraise(cardID: missing)
        }
    }

    @Test("A second appraisal of the same card cannot start")
    func deduplication() async throws {
        let stack = try await makeStack()
        let first = try await stack.service.appraise(cardID: stack.card.id)
        await #expect(throws: AppraisalError.cardAlreadyHeld(stack.card.id)) {
            try await stack.service.appraise(cardID: stack.card.id)
        }
        #expect(stack.launcher.launched == [first.id])
        #expect(try await stack.store.runs(cardID: stack.card.id).count == 1)
    }

    @Test("A card already held by a skill cannot be appraised")
    func aHeldCardIsRefused() async throws {
        let stack = try await makeStack()
        var writer = SkillRun.card(
            cardID: stack.card.id, repoID: stack.repo.id, kind: .implementIssue,
            prompt: "x", cwd: stack.repo.path, logPath: "/tmp/a", stderrPath: "/tmp/b",
            createdAt: Date()
        )
        writer.state = .running
        try await stack.store.saveRun(writer)

        await #expect(throws: AppraisalError.cardAlreadyHeld(stack.card.id)) {
            try await stack.service.appraise(cardID: stack.card.id)
        }
        #expect(stack.launcher.launched.isEmpty)
    }

    /// The write window, direction one: **a move cannot land while an appraisal
    /// holds the card**, so no `commitMove` can carry a stale appraisal back.
    @Test("A move is refused while an appraisal holds the card")
    func anAppraisalHoldsTheCardAgainstAMove() async throws {
        let stack = try await makeStack()
        let run = try await stack.service.appraise(cardID: stack.card.id)
        #expect(run.state == .queued)   // queued is active: it holds the card

        let result = try await stack.board.move(
            cardID: stack.card.id, to: .todo, origin: .userDrag, requiresVerifiedGreen: false)
        // The case carries its run — `case runAlreadyInFlight(runID: UUID)`
        // (`ElliotModel/RuleEngine.swift:106`) — so the assertion names *which*
        // run holds the card, and would fail if some other one did.
        #expect(result == .blocked(.runAlreadyInFlight(runID: run.id)))
        #expect(try await stack.store.card(id: stack.card.id)?.column == .backlog)
        // And the refusal really was a refusal: nothing else was launched.
        #expect(stack.launcher.launched == [run.id])
    }

    /// The write window, direction two: **an appraisal cannot start while a move
    /// is in flight**, so no appraisal write can carry a stale column back.
    @Test("An appraisal is refused while a move's run holds the card")
    func aMoveHoldsTheCardAgainstAnAppraisal() async throws {
        let stack = try await makeStack()
        // A real move through the funnel, which commits the card and its run in
        // one transaction — the exact state the appraisal must not step into.
        let result = try await stack.board.move(
            cardID: stack.card.id, to: .todo, origin: .userDrag, requiresVerifiedGreen: false)
        guard case .moved(let runID?) = result else {
            Issue.record("expected the move to start a run, got \(result)")
            return
        }
        #expect(try await stack.store.run(id: runID)?.kind == .createIssue)

        await #expect(throws: AppraisalError.cardAlreadyHeld(stack.card.id)) {
            try await stack.service.appraise(cardID: stack.card.id)
        }
        // And the card kept the move: nothing wrote over it.
        #expect(try await stack.store.card(id: stack.card.id)?.column == .todo)
        // The appraisal launched nothing, so the write it was refused really
        // never happened — a refusal that still spawned would be worse than none.
        #expect(stack.launcher.launched == [runID])
    }
}
