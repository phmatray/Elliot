import ElliotModel
import ElliotProcess
import ElliotStore
import Foundation
import TestSupport
import Testing

@testable import ElliotEngine

/// The repository root, climbed once from this file's own path.
///
/// Shared by every fixture in this file — and the ones Tasks 8-14 append —
/// that needs to point a `GHClient` at `Scripts/fake-gh.sh` or a fixture under
/// `Fixtures/gh/`. `#filePath` resolves to wherever this file lives on disk,
/// so the four `deletingLastPathComponent()` calls below climb
/// `ElliotEngineTests` → `Tests` → `ElliotKit` → the repository root exactly
/// once, rather than being re-derived inline by every fixture that needs it.
private let repositoryRoot: URL = {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // ElliotEngineTests
        .deletingLastPathComponent()  // Tests
        .deletingLastPathComponent()  // ElliotKit
        .deletingLastPathComponent()  // repository root
}()

/// Records what the board asked for without spawning anything — the shape
/// `BoardServiceTests` already uses.
private actor FakeLauncher: RunLaunching {
    private(set) var launched: [UUID] = []
    private(set) var cancelled: [UUID] = []

    func launch(runID: UUID) async { launched.append(runID) }
    func cancel(runID: UUID) async { cancelled.append(runID) }
    func launchedRuns() -> [UUID] { launched }
    func cancelledRuns() -> [UUID] { cancelled }
}

@Suite("Auto-dev — the run carries the rule")
struct AutoDevProposalTests {

    /// A card in In Review with a green, current reading behind it.
    ///
    /// A headless `BoardService` (no `verdicts:` argument) resolves to
    /// `PRVerdictReader(store:gh: nil)`, and `.establish` — what `proposeMove`
    /// always asks for once `requiresVerifiedGreen` is true — answers `nil`
    /// with no `gh` to ask, whatever the stored `PRStatus` says. So this wires a
    /// real `PRVerdictReader` against a real `GHClient` spawning
    /// `Scripts/fake-gh.sh`, the same seam `BoardServiceTests.Fixture.green`
    /// uses, pointed at a fixture whose `headRefOid` matches the stored row's —
    /// otherwise the sha rule alone would call the reading stale.
    private func fixture() async throws -> (BoardStore, BoardService, Repo, Card) {
        // `TestHome` is the only thing in this process allowed to set
        // `ELLIOT_HOME`; its own comment requires any test that resolves a
        // `StoreLocation` path to touch `root` first, and `commitMove` resolves
        // a run's log and stderr paths through `makeRun`.
        _ = TestHome.root
        let store = try BoardStore.inMemory()
        let gh = GHClient(config: ToolConfig(
            claudePath: "", ghPath: repositoryRoot.appendingPathComponent("Scripts/fake-gh.sh").path,
            gitPath: "",
            environment: [
                "FAKE_GH_MODE": "ok",
                "FAKE_GH_PRS": repositoryRoot.appendingPathComponent(
                    "Fixtures/gh/prs-52-a1b2c3.json"
                ).path,
            ]))
        let board = BoardService(
            store: store, launcher: FakeLauncher(),
            verdicts: PRVerdictReader(store: store, gh: gh))
        let repo = Repo(
            path: "/tmp/repo-\(UUID().uuidString)", nameWithOwner: "phmatray/Elliot",
            displayName: "Elliot")
        try await store.saveRepo(repo)

        var card = try await board.createCard(repoID: repo.id, title: "Landing").card
        card.column = .inReview
        card.issueNumber = 47
        card.prNumber = 52
        try await store.saveCard(card)

        try await store.savePRStatus(
            PRStatus(
                repoID: repo.id, prNumber: 52, headRefOid: "a1b2c3", checkedAt: Date(),
                rawMergeStateStatus: "CLEAN", rawMergeable: "MERGEABLE", rawReviewDecision: "",
                checks: [GHMergeStatus.StatusCheck(
                    name: "build-and-test", conclusion: "SUCCESS", status: "COMPLETED")]
            ))
        return (store, board, repo, card)
    }

    @Test("A proposal says which rule it was decided under, and on what reading")
    func proposalCarriesBoth() async throws {
        let (_, board, _, card) = try await fixture()
        let proposal = try await board.proposeMove(
            cardID: card.id, to: .done, origin: .autoDev(sessionID: UUID()),
            followUps: [], requiresVerifiedGreen: true)

        #expect(proposal.requiresVerifiedGreen)
        let verdict = try #require(proposal.prVerdict)
        #expect(verdict.isMergeableUnattended)
        #expect(proposal.outcome == .action(.mergePR(prNumber: 52, followUps: [])))
    }

    @Test("The merge run remembers the rule, so admission can apply it again")
    func runCarriesTheRule() async throws {
        let (store, board, _, card) = try await fixture()
        let proposal = try await board.proposeMove(
            cardID: card.id, to: .done, origin: .autoDev(sessionID: UUID()),
            followUps: [], requiresVerifiedGreen: true)
        guard case .moved(let runID?) = try await board.commitMove(proposal) else {
            Issue.record("expected a run")
            return
        }
        #expect(try await store.run(id: runID)?.demandsVerifiedGreen == true)
    }

    @Test("A drag's merge run demands nothing, so nothing about a drag changes")
    func aDragIsUnchanged() async throws {
        let (store, board, _, card) = try await fixture()
        guard case .moved(let runID?) = try await board.move(
            cardID: card.id, to: .done, origin: .userDrag, followUps: [],
            requiresVerifiedGreen: false
        ) else {
            Issue.record("expected a run")
            return
        }
        // `demandsVerifiedGreen` reads `requiresVerifiedGreen == true`, so `nil`
        // and `false` both answer `false` — that assertion alone cannot tell "the
        // drag's claim was recorded as false" from "nothing was recorded at all".
        // Reading the field itself makes a `makeRun` that forgot the parameter
        // distinguishable from one that passed `false` explicitly.
        let run = try await store.run(id: runID)
        #expect(run?.requiresVerifiedGreen == false)
        #expect(run?.demandsVerifiedGreen == false)
    }
}

/// `makeRun`'s `unknownMethod`/`methodHasNoStep` guard
/// (`BoardService.swift`, just above the `SkillRun(` call) is documented as an
/// "unreachable floor, not the gate" — `evaluateMove` already refuses both as
/// `MoveBlock`s before a proposal reaches `commitMove`, so nothing built
/// through `proposeMove` can ever trip it. Its own ⛔ comment says it is kept
/// anyway for *"a future caller that reaches `makeRun` by some other path"*.
///
/// `commitMove` is that other path: it switches on `proposal.outcome` alone,
/// so a hand-built `MoveProposal` carrying an `.action` `evaluateMove` would
/// never have produced reaches `makeRun` with none of `evaluateMove`'s guards
/// run first. `MoveProposal` is a public struct with a synthesised memberwise
/// init, so no access-control loosening is needed to build one.
@Suite("Auto-dev — makeRun's unreachable floor, reached anyway")
struct MakeRunUnreachableFloorTests {

    /// A repository on the named method, with a card whose issue and pull
    /// request numbers are already set — the `commitMove` route does not need
    /// `card.column` or `card.prNumber` to line up with the hand-built
    /// proposal's `outcome`, since it never asks `evaluateMove`.
    private func fixture(methodID: String) async throws -> (BoardStore, BoardService, Card) {
        _ = TestHome.root
        let store = try BoardStore.inMemory()
        let board = BoardService(store: store, launcher: FakeLauncher())
        var repo = Repo(
            path: "/tmp/repo-\(UUID().uuidString)", nameWithOwner: "phmatray/Elliot",
            displayName: "Elliot")
        repo.methodID = methodID
        try await store.saveRepo(repo)

        var card = try await board.createCard(repoID: repo.id, title: "Landing").card
        card.column = .inReview
        card.issueNumber = 47
        card.prNumber = 52
        try await store.saveCard(card)
        return (store, board, card)
    }

    /// GSD (`MethodCatalog.builtIn`) declares a step only for `.createIssue` —
    /// `.mergePR` is absent by name, and its own comment says why: `/gsd-ship`
    /// takes a phase number, not the pull-request number Elliot holds at
    /// In Review → Done. So a `.mergePR` action against a GSD repository is
    /// exactly the case `methodHasNoStep` exists to refuse.
    @Test("A method with no step for the action refuses closed, not open")
    func methodWithNoStepRefusesClosed() async throws {
        let (_, board, card) = try await fixture(methodID: "gsd")
        let proposal = MoveProposal(
            card: card, from: .inReview, to: .done, orderIndex: 1024,
            outcome: .action(.mergePR(prNumber: 52, followUps: [])),
            origin: .autoDev(sessionID: UUID()),
            requiresVerifiedGreen: false, prVerdict: nil)

        do {
            _ = try await board.commitMove(proposal)
            Issue.record("expected BoardError.methodHasNoStep")
        } catch BoardError.methodHasNoStep(let method, let kind) {
            #expect(method == "GSD")
            #expect(kind == "merge-pr")
        } catch {
            Issue.record("wrong error: \(error)")
        }
    }

    /// An id `MethodCatalog.builtIn` does not carry at all.
    @Test("A repository whose method nobody knows refuses closed, not open")
    func unknownMethodRefusesClosed() async throws {
        let (_, board, card) = try await fixture(methodID: "not-a-real-method")
        let proposal = MoveProposal(
            card: card, from: .inReview, to: .done, orderIndex: 1024,
            outcome: .action(.mergePR(prNumber: 52, followUps: [])),
            origin: .autoDev(sessionID: UUID()),
            requiresVerifiedGreen: false, prVerdict: nil)

        do {
            _ = try await board.commitMove(proposal)
            Issue.record("expected BoardError.unknownMethod")
        } catch BoardError.unknownMethod(let id) {
            #expect(id == "not-a-real-method")
        } catch {
            Issue.record("wrong error: \(error)")
        }
    }
}

/// **The second green guard, at admission.**
///
/// `evaluateMove` decides at `proposeMove` time, but `commitMove` writes the
/// card and inserts the run in one transaction, and `pump()` may then hold
/// that run: `refusal(for:)` returns `.mergeWaitsForRepoToBeIdle` while *any*
/// run is going in the repository, the refused run returns to `pending` with
/// no ageing, and `start(_:)` re-reads only the repository. `PRStatus.maximumAge`
/// is 600 s. Under a session that keeps one repository busy, the merge is
/// **structurally** the most-delayed run in the system — so without this
/// guard, auto-dev merges to a default branch on a reading the system itself
/// calls stale, and nothing says so.
///
/// Appended here rather than in a file of its own, so it can reuse this
/// file's `repositoryRoot` and `FakeLauncher` rather than duplicate them —
/// this suite's one end-to-end test needs the same real `GHClient` against
/// `Scripts/fake-gh.sh` that `AutoDevProposalTests.fixture()` uses, for the
/// same reason: a headless `BoardService` (no `verdicts:` argument) resolves
/// to `PRVerdictReader(store:gh: nil)`, and `.establish` — what `proposeMove`
/// always asks for once `requiresVerifiedGreen` is true — answers `nil` with
/// no `gh` to ask, whatever the stored `PRStatus` says. Measured directly
/// against this file's own `AutoDevProposalTests.fixture()` and its comment
/// before writing this suite: the plan this suite was built from pointed
/// `ghPath` at `/usr/bin/false` and passed no `verdicts:` at all, which makes
/// `proposeMove` answer `.blocked(.notVerifiedGreen(...))` for every
/// `requiresVerifiedGreen: true` proposal — never `.action(.mergePR(...))` —
/// so the one test that drives the real board would never have reached the
/// state it means to test.
@Suite("Merge admission — the second green guard")
struct MergeAdmissionTests {

    private func toolConfig() -> ToolConfig {
        ToolConfig(
            claudePath: "/usr/bin/true", ghPath: "/usr/bin/false",
            gitPath: "/usr/bin/false", environment: [:])
    }

    private func scheduler(_ store: BoardStore) -> RunScheduler {
        let config = toolConfig()
        return RunScheduler(
            store: store, toolConfig: config, verifier: Verifier(gh: .init(config: config)))
    }

    /// A `GHClient` that actually answers, wired at `Scripts/fake-gh.sh` the
    /// way `AutoDevProposalTests.fixture()` is — `pr list` returning PR 52 at
    /// `headRefOid` `a1b2c3`, matching `greenStatus(...)` below.
    private func workingGH() -> GHClient {
        GHClient(config: ToolConfig(
            claudePath: "", ghPath: repositoryRoot.appendingPathComponent("Scripts/fake-gh.sh").path,
            gitPath: "",
            environment: [
                "FAKE_GH_MODE": "ok",
                "FAKE_GH_PRS": repositoryRoot.appendingPathComponent(
                    "Fixtures/gh/prs-52-a1b2c3.json"
                ).path,
            ]))
    }

    private func greenStatus(repoID: UUID, checkedAt: Date) -> PRStatus {
        PRStatus(
            repoID: repoID, prNumber: 52, headRefOid: "a1b2c3", checkedAt: checkedAt,
            rawMergeStateStatus: "CLEAN", rawMergeable: "MERGEABLE", rawReviewDecision: "",
            checks: [GHMergeStatus.StatusCheck(
                name: "build-and-test", conclusion: "SUCCESS", status: "COMPLETED")]
        )
    }

    private func mergeRun(cardID: UUID, repoID: UUID, demanding: Bool) -> SkillRun {
        SkillRun.card(
            cardID: cardID, repoID: repoID, kind: .mergePR, prompt: "x", cwd: "/tmp",
            logPath: "/tmp/a", stderrPath: "/tmp/b",
            requiresVerifiedGreen: demanding ? true : nil, createdAt: Date())
    }

    @Test("A merge whose reading aged out while it waited does not start")
    func staleVerdictIsRefusedAtAdmission() async throws {
        // `TestHome` is the only thing in this process allowed to set
        // `ELLIOT_HOME`, and its own comment makes the rule: any test that
        // resolves a `StoreLocation` path touches `root` first, so the home is
        // already final when the path is computed. `commitMove` below resolves
        // two through `makeRun`.
        _ = TestHome.root
        let store = try BoardStore.inMemory()
        let scheduler = scheduler(store)
        let board = BoardService(
            store: store, launcher: scheduler, verdicts: PRVerdictReader(store: store, gh: workingGH()))
        await scheduler.setSystemMover(board)

        let repo = Repo(
            path: "/tmp/repo-\(UUID().uuidString)", nameWithOwner: "phmatray/Elliot",
            displayName: "Elliot")
        try await store.saveRepo(repo)

        var card = try await board.createCard(repoID: repo.id, title: "Landing").card
        card.column = .inReview
        card.issueNumber = 47
        card.prNumber = 52
        try await store.saveCard(card)

        // A green reading, taken now — and the head `gh` reports for PR 52 via
        // `workingGH()` is the same `a1b2c3`, so `proposeMove`'s `.establish`
        // read finds a current, mergeable-unattended verdict and the decision
        // below passes on it.
        try await store.savePRStatus(greenStatus(repoID: repo.id, checkedAt: Date()))

        // A sibling run in the same repository, so the merge is held by
        // `.mergeWaitsForRepoToBeIdle` exactly as a session would hold it —
        // the verdict is still fresh at this instant, so that is the only
        // thing that can be holding it.
        let sibling = SkillRun.card(
            cardID: card.id, repoID: repo.id, kind: .implementIssue, prompt: "x",
            cwd: repo.path, logPath: "/tmp/a", stderrPath: "/tmp/b", createdAt: Date())
        await scheduler.testOnlyMarkInFlight(sibling)

        let proposal = try await board.proposeMove(
            cardID: card.id, to: .done, origin: .autoDev(sessionID: UUID()),
            followUps: [], requiresVerifiedGreen: true)
        #expect(proposal.outcome == .action(.mergePR(prNumber: 52, followUps: [])))
        guard case .moved(let runID?) = try await board.commitMove(proposal) else {
            Issue.record("expected a queued merge")
            return
        }
        #expect(try await store.run(id: runID)?.state == .queued)

        // The clock advances past `maximumAge` — expressed by re-dating the row
        // rather than by sleeping, because no assertion here may measure an
        // absolute duration and no test may sleep a fixed interval.
        try await store.savePRStatus(
            greenStatus(
                repoID: repo.id,
                checkedAt: Date().addingTimeInterval(-(PRStatus.maximumAge + 60))))

        // The sibling finishes: the repository is idle and the merge is next —
        // and is refused anyway, for the reading, not the repository.
        await scheduler.testOnlyClearInFlight(sibling.id)
        await scheduler.testOnlyDrain()

        // The whole point.
        #expect(try await store.run(id: runID)?.state == .queued)
        let queue = await scheduler.queueSnapshot()
        #expect(queue.first?.runID == runID)
        #expect(queue.first?.refusal == .mergeVerdictNotEstablished)
    }

    @Test("A merge with a current reading is admitted once the repository is idle")
    func currentVerdictIsAdmitted() async throws {
        let store = try BoardStore.inMemory()
        let scheduler = scheduler(store)
        #expect(
            await scheduler.refusal(
                for: mergeRun(cardID: UUID(), repoID: UUID(), demanding: true),
                overBudget: false, mergeVerdict: .current) == nil)
    }

    @Test("A merge nobody has read is refused, because absence is not a green")
    func absentReadingIsRefused() async throws {
        let store = try BoardStore.inMemory()
        let scheduler = scheduler(store)
        #expect(
            await scheduler.refusal(
                for: mergeRun(cardID: UUID(), repoID: UUID(), demanding: true),
                overBudget: false, mergeVerdict: .notEstablished)
                == .mergeVerdictNotEstablished)
    }

    @Test("A drag's merge is admitted exactly as it always was")
    func aDragIsUnaffected() async throws {
        let store = try BoardStore.inMemory()
        let scheduler = scheduler(store)
        #expect(
            await scheduler.refusal(
                for: mergeRun(cardID: UUID(), repoID: UUID(), demanding: false),
                overBudget: false, mergeVerdict: .notDemanded) == nil)
    }

    @Test("The pause and the ceiling both outrank the verdict")
    func orderingIsStated() async throws {
        let store = try BoardStore.inMemory()
        let scheduler = scheduler(store)
        let run = mergeRun(cardID: UUID(), repoID: UUID(), demanding: true)
        #expect(
            await scheduler.refusal(for: run, overBudget: true, mergeVerdict: .notEstablished)
                == .dailyCeilingReached)
        await scheduler.pause()
        #expect(
            await scheduler.refusal(for: run, overBudget: false, mergeVerdict: .notEstablished)
                == .paused)
    }

    /// **The derivation, not just the branch.** `aDragIsUnaffected` above
    /// passes `mergeVerdict: .notDemanded` by hand, which tests `refusal`'s
    /// branch but nothing about what `pump()` itself decides for a run whose
    /// move demanded nothing. This is the arm an implementer inverts —
    /// `run.demandsVerifiedGreen` read the wrong way round — and inverted it
    /// refuses every human drag's merge on a ten-minute-old reading. Both
    /// halves below share one fixture, one flag apart, driven through the
    /// real `pump()` rather than through a hand-supplied `MergeAdmission`.
    private func drivenAdmissionFixture(demanding: Bool) async throws -> (
        store: BoardStore, scheduler: RunScheduler, runID: UUID
    ) {
        _ = TestHome.root
        let store = try BoardStore.inMemory()
        let scheduler = scheduler(store)
        let repo = Repo(
            path: "/tmp/repo-\(UUID().uuidString)", nameWithOwner: "phmatray/Elliot",
            displayName: "Elliot")
        try await store.saveRepo(repo)
        let board = BoardService(store: store, launcher: scheduler)
        var card = try await board.createCard(repoID: repo.id, title: "Landing").card
        card.column = .inReview
        card.prNumber = 52
        try await store.saveCard(card)

        // Already stale the moment it is written — the point of both tests is
        // what a run does with a reading this old, not how it got that way.
        try await store.savePRStatus(
            greenStatus(
                repoID: repo.id,
                checkedAt: Date().addingTimeInterval(-(PRStatus.maximumAge + 60))))

        let run = mergeRun(cardID: card.id, repoID: repo.id, demanding: demanding)
        try await store.saveRun(run)
        await scheduler.launch(runID: run.id)
        return (store, scheduler, run.id)
    }

    @Test("Admission derives .notDemanded for a run that asked for nothing, even against a stale reading")
    func admissionDerivesNotDemandedForAPlainMerge() async throws {
        let (store, _, runID) = try await drivenAdmissionFixture(demanding: false)
        // Admitted despite the stale row: `/usr/bin/true` spawns and exits at
        // once, so a run still `.queued` would be the witness of a wrongly
        // held merge. Here the witness runs the other way — `.queued`
        // surviving would mean the derivation refused a run that demanded
        // nothing, which is the inversion this test exists to catch.
        #expect(try await store.run(id: runID)?.state != .queued)
    }

    @Test("Admission derives .notEstablished for a run that demanded a green, against the same stale reading")
    func admissionDerivesNotEstablishedForADemandingMerge() async throws {
        let (store, scheduler, runID) = try await drivenAdmissionFixture(demanding: true)
        #expect(try await store.run(id: runID)?.state == .queued)
        let queue = await scheduler.queueSnapshot()
        #expect(queue.first?.runID == runID)
        #expect(queue.first?.refusal == .mergeVerdictNotEstablished)
    }
}
