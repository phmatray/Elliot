import ElliotModel
import ElliotProcess
import ElliotStore
import Foundation
import TestSupport
import Testing

@testable import ElliotEngine

/// Duplicated rather than shared with the other end-to-end suites: a private
/// enum in one test file is not visible from another, and one small repetition
/// beats a shared helper target for two constants.
private enum AutoDevPaths {
    static let repoRoot: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // ElliotEngineTests
        .deletingLastPathComponent()  // Tests
        .deletingLastPathComponent()  // ElliotKit
        .deletingLastPathComponent()  // repo root

    static let fakeACP = repoRoot.appendingPathComponent("Scripts/fake-acp.py").path

    /// The double is a Python script, so the executable is an interpreter and the script is
    /// an argument — the same shape the real adapter has, where the executable is `npx` and
    /// the package is an argument.
    static let adapterExecutable = "/usr/bin/env"
    static var adapterArguments: [String] { ["python3", fakeACP] }
    static let fakeGH = repoRoot.appendingPathComponent("Scripts/fake-gh.sh").path

    static func acpFixture(_ name: String) -> String {
        repoRoot.appendingPathComponent("Fixtures/acp/\(name)").path
    }

    static func ghFixture(_ name: String) -> String {
        repoRoot.appendingPathComponent("Fixtures/gh/\(name)").path
    }
}

/// Task 15: a whole unattended session, driven against real fakes rather than
/// spies — a genuine ACP agent child, a real `gh` binary stand-in, a real
/// `BoardStore`. Everything this suite exercises was written in Tasks 5-14;
/// this file's only job is to run it all together and assert on the rows that
/// come out the other end.
///
/// Nested under `EndToEndSuites` and `.serialized`, like the two suites already
/// there (`AnalysisEndToEndTests.swift`, `AppraisalEndToEndTests.swift`): all
/// three share one process-global `ELLIOT_HOME` through `TestHome.root`, so
/// they must not run at the same time.
extension EndToEndSuites {

@Suite("Auto-dev end to end", .serialized)
struct AutoDevEndToEndTests {

    private struct Stack {
        var store: BoardStore
        var board: BoardService
        var scheduler: RunScheduler
        var service: AutoDevService
        var repo: Repo
        var home: URL

        /// Removes this test's own directory only. The shared `ELLIOT_HOME`
        /// above it stays: another suite may still be writing into it.
        func cleanUp() { try? FileManager.default.removeItem(at: home) }

        /// Waits for the session to reach `.finished`. Bounded through
        /// `TestSupport.withTimeout` and waiting on a condition rather than a
        /// duration — the discipline every other end-to-end suite in this
        /// target already follows (`SchedulerConcurrentPumpTests.awaitTerminal`,
        /// `AppraisalInvocationTests`), rather than the plan's own hand-rolled
        /// `ContinuousClock` deadline.
        func awaitFinished(_ sessionID: UUID, timeout: Duration = .seconds(30)) async throws
            -> AutoDevSession
        {
            try await withTimeout(timeout) {
                while true {
                    if let session = try await store.autoDevSession(id: sessionID),
                        session.state == .finished
                    {
                        return session
                    }
                    try await Task.sleep(for: .milliseconds(50))
                }
            }
        }
    }

    /// Two fixture sets, and why they are two tests rather than one.
    /// `FAKE_GH_PR_VIEW` is one path per process, so one stack cannot answer
    /// `pr view` two different ways. The green pull request that must merge and
    /// the `noChecks` one that must settle blocked therefore get a stack each —
    /// which is also the honest shape, since the second never reaches a
    /// `pr view` at all: the *decision* refuses it, and that is the claim.
    ///
    /// `FAKE_GH_PRS` is fixed to `prs-52-a1b2c3.json` for both stacks —
    /// `prs-basic.json` (what an earlier draft of this file used, following
    /// the plan verbatim) lists PRs 201/202 only, so establishing a head for
    /// PR 52 against it always fails and every proposal reads as
    /// `NotGreenReason.noReading` rather than a real sign. `prs-52-a1b2c3.json`
    /// is the fixture `AutoDevServiceTests.swift` already uses for the same
    /// card shape (PR 52, `headRefOid: "a1b2c3"`). Both stacks' cards
    /// therefore track PR 52 — safe, because each stack is its own scratch
    /// `ELLIOT_HOME` subdirectory and its own sqlite file.
    private static func makeStack(prView: String?) async throws -> Stack {
        let home = TestHome.scratch("auto-dev-e2e")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try StoreLocation.ensureDirectories()

        let store = try BoardStore.open(at: home.appendingPathComponent("elliot.sqlite"))
        var environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
        environment["FAKE_ACP_FIXTURE"] = AutoDevPaths.acpFixture("fake-create-issue.json")
        environment["FAKE_GH_PRS"] = AutoDevPaths.ghFixture("prs-52-a1b2c3.json")
        if let prView { environment["FAKE_GH_PR_VIEW"] = AutoDevPaths.ghFixture(prView) }

        let config = ToolConfig(
            adapterExecutable: AutoDevPaths.adapterExecutable,
            adapterArguments: AutoDevPaths.adapterArguments,
            ghPath: AutoDevPaths.fakeGH,
            gitPath: "/usr/bin/false",
            environment: environment)
        let scheduler = RunScheduler(
            store: store, toolConfig: config, verifier: Verifier(gh: .init(config: config)))
        // ⛔ Must pass `verdicts:` explicitly. `BoardService(store:launcher:)`
        // resolves to a `nil`-`gh` `PRVerdictReader`, which answers `nil` for
        // every reading whatever `PRStatus` row a test stores — the trap the
        // override calls out, and the one that would make both tests below
        // read every pull request as unestablished.
        let board = BoardService(
            store: store, launcher: scheduler,
            verdicts: PRVerdictReader(store: store, gh: GHClient(config: config)))
        await scheduler.setSystemMover(board)

        // The brake a session refuses to start without.
        try await store.saveSpendCeiling(SpendCeiling(perRunUSD: nil, perDayUSD: 25))

        let repo = Repo(path: home.path, nameWithOwner: "phmatray/Elliot", displayName: "Elliot")
        try await store.saveRepo(repo)

        let service = AutoDevService(
            store: store, board: board, launcher: scheduler, queue: scheduler)
        await scheduler.setRoundTrigger(service)

        return Stack(
            store: store, board: board, scheduler: scheduler, service: service,
            repo: repo, home: home)
    }

    private static func seedStatus(
        _ stack: Stack, prNumber: Int, checks: [GHMergeStatus.StatusCheck]
    ) async throws {
        try await stack.store.savePRStatus(
            PRStatus(
                repoID: stack.repo.id, prNumber: prNumber, headRefOid: "a1b2c3",
                checkedAt: Date(), rawMergeStateStatus: "CLEAN", rawMergeable: "MERGEABLE",
                rawReviewDecision: "", checks: checks))
    }

    @Test("A green pull request is merged, and the session finishes saying so")
    func aGreenPullRequestMerges() async throws {
        let stack = try await Self.makeStack(prView: "pr-view-merged.json")
        defer { stack.cleanUp() }

        var card = try await stack.board.createCard(repoID: stack.repo.id, title: "Landing").card
        card.column = .inReview
        card.issueNumber = 47
        card.prNumber = 52
        try await stack.store.saveCard(card)
        try await Self.seedStatus(
            stack, prNumber: 52,
            checks: [GHMergeStatus.StatusCheck(
                name: "build-and-test", conclusion: "SUCCESS", status: "COMPLETED")])

        let started = try await stack.service.start(
            session: AutoDevSession(
                repoID: stack.repo.id, engagedCardIDs: [card.id], maxAttemptsPerCard: 2,
                patience: 600, startedAt: Date()),
            preflight: .passing)

        let ended = try await stack.awaitFinished(started.id)
        #expect(ended.state == .finished)

        // The run really spawned, really parsed a stream, and `gh` really
        // decided the outcome.
        let run = try #require(try await stack.store.runs(cardID: card.id).first)
        #expect(run.kind == .mergePR)
        #expect(run.state == .succeeded)
        #expect(run.demandsVerifiedGreen)
        if case .merged = run.verifiedOutcome {} else {
            Issue.record("expected a merged outcome, got \(String(describing: run.verifiedOutcome))")
        }

        let row = try #require(
            try await stack.store.autoDevEngagements(sessionID: started.id).first)
        #expect(row.reason == "Merged.")
        #expect(row.disposition == .merged)
    }

    @Test("A pull request nothing has judged settles blocked, and never starts a merge")
    func aNoChecksPullRequestSettlesBlocked() async throws {
        let stack = try await Self.makeStack(prView: nil)
        defer { stack.cleanUp() }

        var card = try await stack.board.createCard(repoID: stack.repo.id, title: "Unjudged").card
        card.column = .inReview
        card.issueNumber = 48
        card.prNumber = 52
        try await stack.store.saveCard(card)
        // An empty rollup: `CIState.noChecks`, `PRSign.noBuild`. Not a pass — an
        // absence of measurement, which is the false green this whole design is
        // written against.
        try await Self.seedStatus(stack, prNumber: 52, checks: [])

        let started = try await stack.service.start(
            session: AutoDevSession(
                repoID: stack.repo.id, engagedCardIDs: [card.id], maxAttemptsPerCard: 2,
                patience: 600, startedAt: Date()),
            preflight: .passing)

        let ended = try await stack.awaitFinished(started.id)
        #expect(ended.state == .finished)

        // No merge was attempted at all: the decision refused it, so `pr view`
        // was never called — which is why this stack has no fixture for it.
        #expect(try await stack.store.runs(cardID: card.id).isEmpty)
        #expect(try await stack.store.card(id: card.id)?.column == .inReview)

        let row = try #require(
            try await stack.store.autoDevEngagements(sessionID: started.id).first)
        #expect(row.disposition == .blocked)
        #expect(row.reason == PRSign.noBuild.summary)
    }
}

}  // extension EndToEndSuites
