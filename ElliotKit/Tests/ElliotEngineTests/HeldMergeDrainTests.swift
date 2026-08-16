import ElliotModel
import ElliotProcess
import ElliotStore
import Foundation
import TestSupport
import Testing

@testable import ElliotEngine

/// The seam no single task owned: a merge refused for a stale reading, and the
/// sweep that makes that reading current again.
///
/// ⛔ **Every other test about this guard stops at "still queued and refused"** —
/// `staleVerdictIsRefusedAtAdmission` and
/// `admissionDerivesNotEstablishedForADemandingMerge` both assert the defect's
/// own symptom as the desired outcome, which is exactly why nothing caught it.
/// Admission was correct and *unreachable-from*: `pump()` had seven callers, none
/// of them reachable from a `PRStatus` write, from a round, or from the passage of
/// time, so once a demanding merge was the only unsettled work left — which it is,
/// because everything else in a session queues behind it — nothing ever asked
/// again. It waited out `patience`, settled `.blocked`, and `finish()` cancelled
/// it, while `QueueRefusal.mergeVerdictNotEstablished` told the reader *"the merge
/// starts as soon as a current reading says the pull request is green."*
///
/// So the assertion here is that the merge **starts**. A test that ends on a
/// refusal cannot tell a guard that holds correctly from one nothing releases.
@Suite("A merge held for a stale reading, once the reading is current")
struct HeldMergeDrainTests {

    /// Counts what the watcher asks of the queue, without a scheduler in the way.
    ///
    /// The end-to-end test below proves the merge starts; these two prove *when*
    /// the question is asked, which a real scheduler cannot show — a drain that
    /// happens for the wrong reason and a drain that happens for the right one
    /// both admit the same run.
    private actor DrainSpy: QueueReconsidering {
        private(set) var calls = 0
        func reconsiderQueue() async { calls += 1 }
        func count() -> Int { calls }
    }

    /// The `SystemMoving` the watcher needs, counting rather than swallowing.
    ///
    /// Not a fourth `FakeLauncher`: nothing in this suite launches through a
    /// board, and what these tests must be sure of is the opposite — that a sweep
    /// they describe as "only refreshed a reading" did not also move a card
    /// behind them. A stub that silently accepted moves would make that claim
    /// unfalsifiable.
    private actor MoveSpy: SystemMoving {
        private(set) var moves = 0
        func applySystemMove(
            cardID: UUID, to: ElliotModel.Column, reason: MoveOrigin.SystemReason
        ) async {
            moves += 1
        }
        func count() -> Int { moves }
    }

    private func toolConfig() -> ToolConfig {
        ToolConfig(
            ghPath: "/usr/bin/false", gitPath: "/usr/bin/false",
            environment: [:])
    }

    /// `gh` that lists PR 52 at the same head the clean `pr view` reports, so the
    /// stored row is refreshed for its **age** and for nothing else — the case
    /// this guard is actually about. A head that had moved would make the row
    /// stale a second way and blur which rule was under test.
    ///
    /// `readable: false` leaves `FAKE_GH_PR_VIEW` unset, which makes the fake
    /// exit 65 on `pr view` while `pr list` still answers — the shape of a
    /// per-pull-request read that failed inside a sweep that otherwise worked.
    private func watcherGH(prsPath: String, readable: Bool = true) -> GHClient {
        var environment = ["FAKE_GH_MODE": "ok", "FAKE_GH_PRS": prsPath]
        if readable {
            environment["FAKE_GH_PR_VIEW"] = repositoryRoot.appendingPathComponent(
                "Fixtures/gh/pr-view-clean.json"
            ).path
        }
        return GHClient(config: ToolConfig(
            ghPath: repositoryRoot.appendingPathComponent("Scripts/fake-gh.sh").path,
            gitPath: "", environment: environment))
    }

    private let head = "3be5f1ee906ff61bdedef0072b635ec6ec40c632"

    private func writePRListing() throws -> String {
        let path = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("prs-\(UUID().uuidString).json").path
        try """
            [{"number": 52, "url": "https://github.com/phmatray/Elliot/pull/52",
              "title": "x", "body": "Closes #7", "headRefName": "feat/7-landing",
              "isDraft": false, "state": "OPEN", "createdAt": "2026-08-01T10:00:00Z",
              "mergedAt": null, "headRefOid": "\(head)"}]
            """.write(toFile: path, atomically: true, encoding: .utf8)
        return path
    }

    private func agedGreenStatus(repoID: UUID) -> PRStatus {
        PRStatus(
            repoID: repoID, prNumber: 52, headRefOid: head,
            // Older than `maximumAge`, expressed by dating the row rather than by
            // sleeping: no test here may sleep a fixed interval or measure an
            // absolute duration.
            checkedAt: Date().addingTimeInterval(-(PRStatus.maximumAge + 60)),
            rawMergeStateStatus: "CLEAN", rawMergeable: "MERGEABLE", rawReviewDecision: "",
            checks: [GHMergeStatus.StatusCheck(
                name: "build-and-test", conclusion: "SUCCESS", status: "COMPLETED")]
        )
    }

    /// A card already in Done — where `commitMove` puts it *before* its merge run
    /// — with that merge queued and demanding a verified green.
    private func seedHeldMerge(
        store: BoardStore, scheduler: RunScheduler, stale: Bool
    ) async throws -> (repo: Repo, card: Card, runID: UUID) {
        let repo = Repo(
            path: "/tmp/repo-\(UUID().uuidString)", nameWithOwner: "phmatray/Elliot",
            displayName: "Elliot")
        try await store.saveRepo(repo)

        let now = Date()
        let card = Card(
            repoID: repo.id, title: "Landing", column: .done, orderIndex: 0,
            issueNumber: 7, prNumber: 52, branch: "feat/7-landing",
            columnEnteredAt: now, createdAt: now, updatedAt: now)
        try await store.saveCard(card)

        var status = agedGreenStatus(repoID: repo.id)
        if !stale { status.checkedAt = now }
        try await store.savePRStatus(status)

        let runID = UUID()
        let run = SkillRun.card(
            id: runID, cardID: card.id, repoID: repo.id, kind: .mergePR, prompt: "x",
            // `/tmp` rather than `repo.path`: the repository row has to exist for
            // `start` to get past its own guard, but the directory does not, and
            // nothing here should depend on a checkout being on disk.
            cwd: "/tmp",
            logPath: StoreLocation.runLogURL(runID: runID).path,
            stderrPath: StoreLocation.runStderrURL(runID: runID).path,
            requiresVerifiedGreen: true, createdAt: now)
        try await store.saveRun(run)
        await scheduler.launch(runID: runID)
        return (repo, card, runID)
    }

    /// **The gate.** Nothing else in the suite drives a refreshed reading and then
    /// asks whether the merge lands.
    @Test("The watcher refreshes the reading, and the merge that was held starts")
    func aHeldMergeStartsOnceItsReadingIsCurrent() async throws {
        // `TestHome` before any `StoreLocation` path is resolved — the rule its
        // own comment states, and `seedHeldMerge` resolves two.
        _ = TestHome.root
        let store = try BoardStore.inMemory()
        // The adapter is unresolved, so `AgentRun.start` refuses at once and the
        // run leaves `.queued` either way: what is asserted is that it stopped
        // being queued, never that it succeeded. A run still `.queued` after the
        // sweep is the witness of a merge nothing released. This is the same
        // witness `admissionAdmitsAFreshDemandingMerge` uses.
        let config = toolConfig()
        let scheduler = RunScheduler(
            store: store, toolConfig: config, verifier: Verifier(gh: .init(config: config)))
        let (_, _, runID) = try await seedHeldMerge(
            store: store, scheduler: scheduler, stale: true)

        // The precondition, asserted rather than assumed: without it a merge that
        // was never held would make the rest of this test pass for free.
        #expect(try await store.run(id: runID)?.state == .queued)
        #expect(await scheduler.queueSnapshot().first?.refusal == .mergeVerdictNotEstablished)

        let watcher = PRWatcher(
            store: store, gh: watcherGH(prsPath: try writePRListing()),
            mover: MoveSpy())
        await watcher.setQueueReconsidering(scheduler)

        await watcher.tick()

        #expect(try await store.run(id: runID)?.state != .queued)
        #expect(await scheduler.queueSnapshot().isEmpty)
    }

    /// The other half of the same claim: the drain is asked for a *fact*, not on
    /// every sweep. Without this, "ask unconditionally at the end of `tick`" would
    /// pass the gate above while telling the reader nothing about why.
    @Test("A sweep that refreshed a queued merge's reading asks the queue exactly once")
    func aRefreshedHeldMergeAsksOnce() async throws {
        _ = TestHome.root
        let store = try BoardStore.inMemory()
        let config = toolConfig()
        let scheduler = RunScheduler(
            store: store, toolConfig: config, verifier: Verifier(gh: .init(config: config)))
        _ = try await seedHeldMerge(store: store, scheduler: scheduler, stale: true)

        let spy = DrainSpy()
        let watcher = PRWatcher(
            store: store, gh: watcherGH(prsPath: try writePRListing()),
            mover: MoveSpy())
        await watcher.setQueueReconsidering(spy)

        await watcher.tick()
        #expect(await spy.count() == 1)
    }

    /// The placement of one line: the flag is set **after** the row is written,
    /// never at the top of the loop body.
    ///
    /// A `gh pr view` that fails writes nothing and erases nothing — the old row
    /// stands and stays stale — so the rule holding the merge still holds. A
    /// drain here would be the queue reconsidering a fact that did not change,
    /// and worse, it would make "the reading was refreshed" mean "the reading was
    /// *attempted*". Moving the assignment above the read's own guard passes
    /// every other test in this file.
    @Test("A sweep whose read of the pull request failed does not ask the queue")
    func aFailedReadAsksNothing() async throws {
        _ = TestHome.root
        let store = try BoardStore.inMemory()
        let config = toolConfig()
        let scheduler = RunScheduler(
            store: store, toolConfig: config, verifier: Verifier(gh: .init(config: config)))
        let (repo, _, runID) = try await seedHeldMerge(
            store: store, scheduler: scheduler, stale: true)

        let spy = DrainSpy()
        let watcher = PRWatcher(
            store: store, gh: watcherGH(prsPath: try writePRListing(), readable: false),
            mover: MoveSpy())
        await watcher.setQueueReconsidering(spy)

        await watcher.tick()

        #expect(await spy.count() == 0)
        // And the two facts that make that the right answer: the row really was
        // left alone, and the merge really is still held.
        let stored = try #require(try await store.prStatus(repoID: repo.id, prNumber: 52))
        #expect(stored.checkedAt.timeIntervalSinceNow < -PRStatus.maximumAge)
        #expect(try await store.run(id: runID)?.state == .queued)
    }

    /// A card in In Review has no queued run for a reading to release, so its
    /// refresh is not an event the queue needs to hear about. Asking anyway would
    /// be harmless and would also make the signal meaningless — a drain on every
    /// tick is a poll wearing the shape of a fact.
    @Test("A sweep that only refreshed an In Review card does not ask the queue at all")
    func aRefreshedInReviewCardAsksNothing() async throws {
        _ = TestHome.root
        let store = try BoardStore.inMemory()
        let repo = Repo(
            path: "/tmp/repo-\(UUID().uuidString)", nameWithOwner: "phmatray/Elliot",
            displayName: "Elliot")
        try await store.saveRepo(repo)

        let now = Date()
        let card = Card(
            repoID: repo.id, title: "Waiting on CI", column: .inReview, orderIndex: 0,
            issueNumber: 7, prNumber: 52, branch: "feat/7-landing",
            columnEnteredAt: now, createdAt: now, updatedAt: now)
        try await store.saveCard(card)
        try await store.savePRStatus(agedGreenStatus(repoID: repo.id))

        let spy = DrainSpy()
        let moves = MoveSpy()
        let watcher = PRWatcher(
            store: store, gh: watcherGH(prsPath: try writePRListing()),
            mover: moves)
        await watcher.setQueueReconsidering(spy)

        await watcher.tick()

        // The reading really was refreshed — otherwise this test would pass on a
        // sweep that did nothing at all, which is a different thing entirely.
        let stored = try #require(try await store.prStatus(repoID: repo.id, prNumber: 52))
        #expect(now.timeIntervalSince(stored.checkedAt) < PRStatus.maximumAge)
        #expect(await moves.count() == 0)
        #expect(await spy.count() == 0)
    }
}
