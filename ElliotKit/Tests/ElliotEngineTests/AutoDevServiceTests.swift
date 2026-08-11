import ElliotIPC
import ElliotModel
import ElliotProcess
import Foundation
import TestSupport
import Testing

@testable import ElliotEngine
// `@testable`, not the plain `import ElliotStore` this file used to have: the
// repo-unreadable-arm test below needs `BoardStore.testOnlyExecute` and
// `UUID.databaseKey`, both `internal`, to produce a `skillRun` row the typed
// API refuses to write — `skillRun.repoID` is a NOT NULL foreign key with
// `ON DELETE CASCADE` (`Migrations.swift`), so an orphaned run cannot be
// created through `saveRun`/`deleteRepo` at all.
@testable import ElliotStore

/// The repository root, climbed once from this file's own path.
///
/// Shared by every fixture in this file — and the ones Tasks 8-14 append —
/// that needs to point a `GHClient` at `Scripts/fake-gh.sh` or a fixture under
/// `Fixtures/gh/`. `#filePath` resolves to wherever *this declaration* lives
/// on disk regardless of which file calls it, so the four
/// `deletingLastPathComponent()` calls below climb `ElliotEngineTests` →
/// `Tests` → `ElliotKit` → the repository root exactly once, rather than
/// being re-derived inline by every fixture that needs it.
///
/// `internal`, not `private` — fix round 1, finding G. `private` at file
/// scope is invisible to another file in the same target even under
/// `@testable import`, which is what forced Task 7's `MergeAdmissionTests`
/// into this file instead of its own: 219 lines before that task, 465 after
/// it alone. `internal` costs nothing this file was relying on (nothing here
/// needed the extra restriction) and lets tasks 8-14 use their own files
/// while still sharing this fixture, rather than every task after Task 7
/// accreting into the same one.
let repositoryRoot: URL = {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // ElliotEngineTests
        .deletingLastPathComponent()  // Tests
        .deletingLastPathComponent()  // ElliotKit
        .deletingLastPathComponent()  // repository root
}()

/// Records what the board asked for without spawning anything — the shape
/// `BoardServiceTests` already uses.
///
/// ⛔ Stays `private`, unlike `repositoryRoot` above — `BoardServiceTests.swift`
/// declares its own file-scoped `private actor FakeLauncher` with the same
/// name, and Swift allows two `private` (file-scoped) types to share a name
/// across files but not one `private` and one `internal`: widening this one
/// collides with that declaration (`invalid redeclaration`, then `is
/// ambiguous for type lookup` inside `BoardServiceTests.swift` itself,
/// measured directly). A file that wants this needs its own copy, or the two
/// existing copies need to be unified under one shared internal name first —
/// out of scope for this fix round.
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
    ///
    /// `stale` widens the fixture for `admissionAdmitsAFreshDemandingMerge`
    /// below, added in fix round 1: nothing before it drove a demanding
    /// merge with a *current* reading through the real derivation and
    /// checked that it actually starts — every existing case here either
    /// short-circuits before `mergeAdmission` reaches `store.prStatus` at all
    /// (`.notDemanded`) or is stale by construction.
    private func drivenAdmissionFixture(demanding: Bool, stale: Bool) async throws -> (
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

        // Stale the moment it is written, or genuinely current — the point of
        // every test built on this fixture is what a run does with the
        // reading it is handed, not how that reading came to be.
        let checkedAt = stale ? Date().addingTimeInterval(-(PRStatus.maximumAge + 60)) : Date()
        try await store.savePRStatus(greenStatus(repoID: repo.id, checkedAt: checkedAt))

        let run = mergeRun(cardID: card.id, repoID: repo.id, demanding: demanding)
        try await store.saveRun(run)
        await scheduler.launch(runID: run.id)
        return (store, scheduler, run.id)
    }

    @Test("Admission derives .notDemanded for a run that asked for nothing, even against a stale reading")
    func admissionDerivesNotDemandedForAPlainMerge() async throws {
        let (store, _, runID) = try await drivenAdmissionFixture(demanding: false, stale: true)
        // Admitted despite the stale row: `/usr/bin/true` spawns and exits at
        // once, so a run still `.queued` would be the witness of a wrongly
        // held merge. Here the witness runs the other way — `.queued`
        // surviving would mean the derivation refused a run that demanded
        // nothing, which is the inversion this test exists to catch.
        #expect(try await store.run(id: runID)?.state != .queued)
    }

    @Test("Admission derives .notEstablished for a run that demanded a green, against the same stale reading")
    func admissionDerivesNotEstablishedForADemandingMerge() async throws {
        let (store, scheduler, runID) = try await drivenAdmissionFixture(demanding: true, stale: true)
        #expect(try await store.run(id: runID)?.state == .queued)
        let queue = await scheduler.queueSnapshot()
        #expect(queue.first?.runID == runID)
        #expect(queue.first?.refusal == .mergeVerdictNotEstablished)
    }

    /// Fix round 1, finding C. `staleVerdictIsRefusedAtAdmission` establishes
    /// a fresh verdict at *propose* time but never observes admission
    /// succeed on it — the sibling it seeds holds the repository busy on the
    /// very first drain, and by the time the repository goes idle the row has
    /// been re-dated stale on purpose. `currentVerdictIsAdmitted` passes
    /// `mergeVerdict: .current` by hand, the same shortcut
    /// `admissionDerivesNotDemandedForAPlainMerge`'s own doc comment names.
    /// Nothing before this proved the `.current` *derivation* — the
    /// `isStale == false` arm of `mergeAdmission`'s own ternary — actually
    /// lets a demanding merge start. Inverting `currentHeadOid: nil` to a
    /// mismatched literal (permanently stale) passed the whole suite clean;
    /// this is the test that would have caught it.
    @Test("Admission derives .current for a demanding run with a genuinely fresh reading, and it starts")
    func admissionAdmitsAFreshDemandingMerge() async throws {
        let (store, _, runID) = try await drivenAdmissionFixture(demanding: true, stale: false)
        #expect(try await store.run(id: runID)?.state != .queued)
    }

    /// Fix round 1, finding E. The `.notEstablished` branch sits above the
    /// repository rules in `refusal` *by construction* — but nothing before
    /// this exercised "repository busy **and** verdict stale" together, so
    /// moving that branch below the repository rules passed the whole suite
    /// clean. Both busy-repo and full-writer-cap variants are asserted, since
    /// they are two different branches of `refusal` the ordering could have
    /// been placed under.
    @Test("A stale verdict outranks a busy repository, and the refusal says so")
    func verdictOutranksRepositoryBusy() async throws {
        let store = try BoardStore.inMemory()
        let scheduler = scheduler(store)
        let repo = UUID()
        await scheduler.testOnlyMarkInFlight(
            SkillRun.card(
                cardID: UUID(), repoID: repo, kind: .mergePR, prompt: "held", cwd: "/tmp",
                logPath: "/tmp/a", stderrPath: "/tmp/b", createdAt: Date()))
        let run = mergeRun(cardID: UUID(), repoID: repo, demanding: true)
        #expect(
            await scheduler.refusal(for: run, overBudget: false, mergeVerdict: .notEstablished)
                == .mergeVerdictNotEstablished)
    }

    @Test("A stale verdict outranks a full writer cap, and the refusal says so")
    func verdictOutranksWriterCap() async throws {
        let store = try BoardStore.inMemory()
        let config = toolConfig()
        let scheduler = RunScheduler(
            store: store, toolConfig: config, verifier: Verifier(gh: .init(config: config)),
            limits: SchedulerLimits(maxConcurrent: 1, maxConcurrentAnalyses: 1))
        await scheduler.testOnlyMarkInFlight(
            SkillRun.card(
                cardID: UUID(), repoID: UUID(), kind: .implementIssue, prompt: "held", cwd: "/tmp",
                logPath: "/tmp/a", stderrPath: "/tmp/b", createdAt: Date()))
        let run = mergeRun(cardID: UUID(), repoID: UUID(), demanding: true)
        #expect(
            await scheduler.refusal(for: run, overBudget: false, mergeVerdict: .notEstablished)
                == .mergeVerdictNotEstablished)
    }

    /// Fix round 1, finding F. `mergeAdmission`'s first guard used to answer
    /// `.notDemanded` — the permissive branch — for a demanding `.mergePR`
    /// run with no card to check, conflating "nothing was asked" with "asked,
    /// and there is nothing to check it against". Per the guard's own stated
    /// philosophy, absence is not a green: the correct answer is
    /// `.notEstablished`.
    ///
    /// Reachable only by bypassing `SkillRun.card(...)` — every real merge
    /// run goes through it, and its `cardID` parameter is non-optional — so
    /// this constructs the one thing that can hold `cardID: nil` and still
    /// satisfy `skillRun`'s `CHECK (("cardID" IS NULL) <> ("analysisID" IS
    /// NULL))` constraint: a `.mergePR` run wearing an analysis's id. Nothing
    /// in the codebase produces this combination; the point is only that the
    /// database schema, not a guard in this file, is what currently stops it.
    @Test("A demanding merge run with no card to check is refused, not admitted")
    func admissionRefusesADemandingMergeWithNoCard() async throws {
        _ = TestHome.root
        let store = try BoardStore.inMemory()
        let scheduler = scheduler(store)
        let repo = Repo(
            path: "/tmp/repo-\(UUID().uuidString)", nameWithOwner: "phmatray/Elliot",
            displayName: "Elliot")
        try await store.saveRepo(repo)
        let analysis = Analysis(repoID: repo.id, angles: [.bugs], createdAt: Date())
        try await store.saveAnalysis(analysis)

        let run = SkillRun(
            cardID: nil, repoID: repo.id, analysisID: analysis.id, kind: .mergePR, prompt: "x",
            cwd: "/tmp", logPath: "/tmp/a", stderrPath: "/tmp/b",
            requiresVerifiedGreen: true, createdAt: Date())
        try await store.saveRun(run)
        await scheduler.launch(runID: run.id)

        #expect(try await store.run(id: run.id)?.state == .queued)
        let queue = await scheduler.queueSnapshot()
        #expect(queue.first?.runID == run.id)
        #expect(queue.first?.refusal == .mergeVerdictNotEstablished)
    }
}

/// `RunQueueReading` is the read-only half of what `RunScheduler` exposes to
/// auto-dev: whether the queue is stopped, and what is holding each pending
/// run. A second protocol beside `RunLaunching` on purpose — see
/// `RunQueueReading.swift`'s header for why widening `RunLaunching` itself
/// would be wrong.
@Suite("Run queue reading")
struct RunQueueReadingTests {

    private func scheduler() throws -> RunScheduler {
        let store = try BoardStore.inMemory()
        let config = ToolConfig(
            claudePath: "/usr/bin/true", ghPath: "/usr/bin/true",
            gitPath: "/usr/bin/true", environment: [:])
        return RunScheduler(
            store: store, toolConfig: config, verifier: Verifier(gh: .init(config: config)))
    }

    @Test("The scheduler answers the protocol auto-dev reads it through")
    func schedulerConforms() async throws {
        let scheduler = try scheduler()
        let queue: any RunQueueReading = scheduler
        #expect(await queue.queueIsPaused() == false)
        #expect(await queue.queueSnapshot().isEmpty)

        await scheduler.pause()
        #expect(await queue.queueIsPaused())
    }

    /// The seam is proven — deleting the `RunQueueReading` conformance is a
    /// compile error — but `schedulerConforms` above only ever asserts the
    /// **empty** snapshot through the existential, so forcing `queueSnapshot()`
    /// to always answer `[]` would not redden it. This drives a real refusal
    /// through the real scheduler and reads it back only through `any
    /// RunQueueReading`, so a queued run's refusal — the one thing Task 12's
    /// `AutoDevService.advance()` actually reads off this protocol — survives
    /// the boundary with its reason intact.
    @Test("A queued run's refusal survives the protocol boundary, reason intact")
    func queueSnapshotCarriesARealRefusal() async throws {
        let store = try BoardStore.inMemory()
        let config = ToolConfig(
            claudePath: "/usr/bin/true", ghPath: "/usr/bin/true",
            gitPath: "/usr/bin/true", environment: [:])
        let scheduler = RunScheduler(
            store: store, toolConfig: config, verifier: Verifier(gh: .init(config: config)))
        await scheduler.pause()

        let repo = Repo(
            path: "/tmp/repo-\(UUID().uuidString)", nameWithOwner: "phmatray/Elliot",
            displayName: "Elliot")
        try await store.saveRepo(repo)
        let card = Card(
            repoID: repo.id, title: "Held",
            columnEnteredAt: Date(), createdAt: Date(), updatedAt: Date())
        try await store.saveCard(card)
        let run = SkillRun.card(
            cardID: card.id, repoID: repo.id, kind: .createIssue, prompt: "x", cwd: repo.path,
            logPath: "/tmp/a", stderrPath: "/tmp/b", createdAt: Date())
        try await store.saveRun(run)

        // `launch` calls `pump()` synchronously to completion, and `isPaused`
        // is the first thing `refusal(for:)` checks — so this run is held, not
        // started, by the time `launch` returns.
        await scheduler.launch(runID: run.id)

        let queue: any RunQueueReading = scheduler
        let snapshot = await queue.queueSnapshot()
        let entry = try #require(snapshot.first { $0.runID == run.id })
        #expect(entry.cardID == card.id)
        #expect(entry.refusal == .paused)
        #expect(entry.refusal.sentence == "The queue is paused.")
    }
}

/// Counts triggers without being an actor's worth of machinery.
///
/// Deviation from the plan's literal text: the plan's sketch paired `.lock()`
/// with `.unlock()` directly, which this toolchain (Swift 6.3.1) refuses —
/// "instance method 'lock' is unavailable from asynchronous contexts; Use
/// async-safe scoped locking instead". `withLock` is the same mutex, scoped,
/// and is the idiom this file's own `ReadOnlyOrphanTests.MoveSpy` already uses.
private final class CountingTrigger: RoundTriggering, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func triggerRound() async {
        lock.withLock { count += 1 }
    }

    var triggers: Int {
        lock.withLock { count }
    }
}

@Suite("Round triggering")
struct RoundTriggeringTests {

    @Test("A finished run tells the registered round trigger, without touching the stream")
    func finishedRunTriggersARound() async throws {
        // The one test in this plan that really spawns a child and really
        // **writes** a run log. Without this the log lands in the operator's own
        // `~/Library/Application Support/Elliot/runs` — the case `TestHome`'s
        // doc comment names outright.
        _ = TestHome.root
        let store = try BoardStore.inMemory()
        let config = ToolConfig(
            claudePath: "/usr/bin/true", ghPath: "/usr/bin/false",
            gitPath: "/usr/bin/false", environment: [:])
        let scheduler = RunScheduler(
            store: store, toolConfig: config, verifier: Verifier(gh: .init(config: config)))
        let trigger = CountingTrigger()
        await scheduler.setRoundTrigger(trigger)

        // Fix round 1: a real, existing directory, not `"/tmp/repo-<uuid>"`.
        // `Foundation.Process.run()` validates `currentDirectoryURL` and throws
        // **synchronously** when it does not exist, which lands in `start()`'s
        // spawn-failure `catch` — the same arm `failedSpawnTriggersARound`
        // covers — instead of `consume()`/`finish()`, the site this test's own
        // name and comment claim to exercise. `TestHome.scratch`, the same
        // seam the end-to-end suites (`Stack.make`) use for exactly this.
        let repoPath = TestHome.scratch("round-trigger-finish")
        try FileManager.default.createDirectory(at: repoPath, withIntermediateDirectories: true)

        let repo = Repo(
            path: repoPath.path, nameWithOwner: "phmatray/Elliot",
            displayName: "Elliot")
        try await store.saveRepo(repo)
        let card = Card(
            repoID: repo.id, title: "Anything",
            columnEnteredAt: Date(), createdAt: Date(), updatedAt: Date())
        try await store.saveCard(card)
        let runID = UUID()
        let run = SkillRun.card(
            id: runID, cardID: card.id, repoID: repo.id, kind: .createIssue, prompt: "x",
            cwd: repo.path,
            logPath: StoreLocation.runLogURL(runID: runID).path,
            stderrPath: StoreLocation.runStderrURL(runID: runID).path, createdAt: Date())
        try await store.saveRun(run)
        await scheduler.launch(runID: run.id)

        // Bounded, and waiting on a condition rather than on a duration: the
        // child is `/usr/bin/true`, so this is milliseconds in practice.
        try await withTimeout(.seconds(20)) {
            while trigger.triggers == 0 { try await Task.sleep(for: .milliseconds(20)) }
        }
        #expect(trigger.triggers >= 1)
        let saved = try await store.run(id: run.id)
        #expect(saved?.state.isTerminal == true)
        // Confirm this is really `finish()`'s path, not `start()`'s
        // spawn-failure `catch` — the exact confusion fix round 1 found.
        // `state(for:)` only ever produces `.succeeded` from a *real*
        // `ClaudeRunOutcome`; the catch block always writes `.failed` with a
        // nil `exitCode` and an `.elliot`-sourced closing remark, never this
        // shape. `/usr/bin/true` exits 0 and prints nothing, so a genuine run
        // is `.succeeded` with `exitCode == 0`.
        #expect(saved?.state == .succeeded)
        #expect(saved?.exitCode == 0)
        #expect(saved?.closing?.source != .elliot)
    }

    @Test("No trigger registered is not an error — the scheduler is unchanged without one")
    func noTriggerIsFine() async throws {
        let store = try BoardStore.inMemory()
        let config = ToolConfig(
            claudePath: "/usr/bin/true", ghPath: "/usr/bin/true",
            gitPath: "/usr/bin/true", environment: [:])
        let scheduler = RunScheduler(
            store: store, toolConfig: config, verifier: Verifier(gh: .init(config: config)))
        await scheduler.testOnlyDrain()
        #expect(await scheduler.queueSnapshot().isEmpty)
    }

    /// The arm the plan's own placement missed: `start` never reaches `finish`
    /// when the spawn itself fails (`ClaudeRun.start` throws before a child
    /// exists), so a trigger hooked only at the end of `finish` would leave a
    /// session waiting out the full stall window for a fact that was knowable
    /// synchronously. `claudePath` names a file that does not exist, so
    /// `ChildProcess.init`'s `isExecutableFile` guard throws before any process
    /// is spawned — this exercises `start`'s `catch` block, not `consume`/`finish`.
    @Test("A run whose spawn fails still tells the registered round trigger")
    func failedSpawnTriggersARound() async throws {
        _ = TestHome.root
        let store = try BoardStore.inMemory()
        let config = ToolConfig(
            claudePath: "/nonexistent/definitely-not-a-binary-\(UUID().uuidString)",
            ghPath: "/usr/bin/false",
            gitPath: "/usr/bin/false", environment: [:])
        let scheduler = RunScheduler(
            store: store, toolConfig: config, verifier: Verifier(gh: .init(config: config)))
        let trigger = CountingTrigger()
        await scheduler.setRoundTrigger(trigger)

        let repo = Repo(
            path: FileManager.default.temporaryDirectory.path, nameWithOwner: "phmatray/Elliot",
            displayName: "Elliot")
        try await store.saveRepo(repo)
        let card = Card(
            repoID: repo.id, title: "Anything",
            columnEnteredAt: Date(), createdAt: Date(), updatedAt: Date())
        try await store.saveCard(card)
        let runID = UUID()
        let run = SkillRun.card(
            id: runID, cardID: card.id, repoID: repo.id, kind: .createIssue, prompt: "x",
            cwd: repo.path,
            logPath: StoreLocation.runLogURL(runID: runID).path,
            stderrPath: StoreLocation.runStderrURL(runID: runID).path, createdAt: Date())
        try await store.saveRun(run)
        await scheduler.launch(runID: run.id)

        // The failure is synchronous — no child is ever spawned — so this
        // resolves fast in practice. Still bounded, per this file's own
        // discipline: nothing waits on a fixed duration.
        try await withTimeout(.seconds(20)) {
            while trigger.triggers == 0 { try await Task.sleep(for: .milliseconds(20)) }
        }
        #expect(trigger.triggers >= 1)
        let saved = try await store.run(id: run.id)
        #expect(saved?.state == .failed)
        #expect(saved?.state.isTerminal == true)
    }

    /// The other arm the plan's placement missed, and fix round 1 found still
    /// had zero coverage: `start`'s repo-unreadable guard, reached when
    /// `store.repo(id:)` answers with no row at all.
    ///
    /// `skillRun.repoID` is a `NOT NULL` foreign key with `ON DELETE CASCADE`
    /// (`Migrations.swift`), so this row cannot be produced through the typed
    /// API — `saveRun` would refuse an unknown `repoID` outright, and a normal
    /// `deleteRepo` cascades away the very run this test needs to survive.
    /// `testOnlyExecute` exists for exactly this shape of claim (its own doc
    /// comment: "some claims are about rows the type system cannot write").
    /// Foreign-key enforcement has to come down for the one raw `DELETE` that
    /// orphans the row, then back up — GRDB wraps `write` in a transaction,
    /// and SQLite refuses `PRAGMA foreign_keys` while one is open, so both
    /// PRAGMAs are their own `testOnlyExecute` calls, not folded into the
    /// `DELETE`'s.
    @Test("A run whose repository row is gone still tells the registered round trigger")
    func unreadableRepositoryTriggersARound() async throws {
        let store = try BoardStore.inMemory()
        let config = ToolConfig(
            claudePath: "/usr/bin/true", ghPath: "/usr/bin/false",
            gitPath: "/usr/bin/false", environment: [:])
        let scheduler = RunScheduler(
            store: store, toolConfig: config, verifier: Verifier(gh: .init(config: config)))
        let trigger = CountingTrigger()
        await scheduler.setRoundTrigger(trigger)

        let repo = Repo(
            path: FileManager.default.temporaryDirectory.path, nameWithOwner: "phmatray/Elliot",
            displayName: "Elliot")
        try await store.saveRepo(repo)
        let card = Card(
            repoID: repo.id, title: "Anything",
            columnEnteredAt: Date(), createdAt: Date(), updatedAt: Date())
        try await store.saveCard(card)
        let runID = UUID()
        let run = SkillRun.card(
            id: runID, cardID: card.id, repoID: repo.id, kind: .createIssue, prompt: "x",
            cwd: repo.path,
            logPath: StoreLocation.runLogURL(runID: runID).path,
            stderrPath: StoreLocation.runStderrURL(runID: runID).path, createdAt: Date())
        try await store.saveRun(run)

        // Orphan the row `store.repo(id:)` will look up, without cascading
        // away the run itself.
        //
        // Deliberately left **off** for the rest of this test, not restored:
        // `start()`'s repo-unreadable branch ends by writing the run's own
        // row back (`try? store.saveRun(updated)`, setting `.state = .failed`)
        // — and that row's `repoID` still names the now-missing parent. With
        // foreign keys back on, SQLite re-validates the FK on that very
        // `UPDATE` and refuses it; `try?` swallows the failure silently, so
        // the trigger still fires (nothing between the yield and the write
        // depends on the save succeeding) but the persisted `state` never
        // moves off `.queued` — a second, real defect this raw-SQL fixture
        // would otherwise paper over. Confirmed directly: restoring
        // `PRAGMA foreign_keys = ON` here reproduces exactly that — the
        // trigger fires, `saved?.state` stays `.queued`. This in-memory store
        // is single-use and discarded at the end of the test, so leaving
        // enforcement off for its remainder costs nothing.
        try await store.testOnlyExecute("PRAGMA foreign_keys = OFF")
        try await store.testOnlyExecute("DELETE FROM repo WHERE id = '\(repo.id.databaseKey)'")
        #expect(try await store.repo(id: repo.id) == nil)

        await scheduler.launch(runID: run.id)

        // Synchronous once admitted — `store.repo(id:)` answers `nil` with no
        // process ever spawned — but bounded all the same.
        try await withTimeout(.seconds(20)) {
            while trigger.triggers == 0 { try await Task.sleep(for: .milliseconds(20)) }
        }
        #expect(trigger.triggers >= 1)
        let saved = try await store.run(id: run.id)
        #expect(saved?.state == .failed)
        #expect(saved?.state.isTerminal == true)
        // The repo-unreadable arm's own sentence, distinct from the
        // spawn-failure arm's — proof this hit the intended guard, not a
        // neighbour.
        #expect(saved?.closing?.text == "The repository this run belongs to no longer exists.")
    }
}

/// What a session needs from the pull request watcher: a hook it can lean on
/// while a card has nothing else to wake it, a backoff that does not put the
/// watcher to sleep for five minutes exactly while a session is busy, and a
/// reading that keeps flowing to a card whose merge is still queued.
@Suite("PR watcher — what a session needs from it")
struct PRWatcherForSessionsTests {

    @Test("A running session stops the quiet backoff widening past the idle window")
    func sessionCapsTheBackoff() {
        // Sixty quiet rounds is well past the widening threshold of thirty.
        let widened = PRWatcher.interval(
            sawChange: false, anyRunning: false, sessionRunning: false, quietRounds: 60)
        let capped = PRWatcher.interval(
            sawChange: false, anyRunning: false, sessionRunning: true, quietRounds: 60)
        #expect(widened > capped)
        #expect(capped == .seconds(60))
    }

    @Test("Everything else about the interval is exactly what it was")
    func theRestIsUnchanged() {
        #expect(
            PRWatcher.interval(
                sawChange: false, anyRunning: true, sessionRunning: false, quietRounds: 0)
                == .seconds(15))
        #expect(
            PRWatcher.interval(
                sawChange: true, anyRunning: false, sessionRunning: false, quietRounds: 0)
                == .seconds(60))
        #expect(
            PRWatcher.interval(
                sawChange: false, anyRunning: false, sessionRunning: false, quietRounds: 1)
                == .seconds(60))
        // The widening: << 1 at 30 quiet rounds, << 3 and then the 300 s ceiling.
        #expect(
            PRWatcher.interval(
                sawChange: false, anyRunning: false, sessionRunning: false, quietRounds: 30)
                == .seconds(120))
        #expect(
            PRWatcher.interval(
                sawChange: false, anyRunning: false, sessionRunning: false, quietRounds: 120)
                == .seconds(300))
    }

    /// The extraction has to be behaviour-preserving and a spot check cannot
    /// prove that: the widening shift has three steps (at 30, 60 and 90 quiet
    /// rounds) and a ceiling, so this pins both edges of every step. The
    /// expected values are literal seconds, not a second copy of the shift
    /// formula — a refactor that reproduced the same mistake in both places
    /// would still be caught, because nothing here computes an answer to
    /// compare against, only names one.
    @Test("The un-jittered rule matches the inline formula it replaced, at every step boundary")
    func pinsTheWideningFormula() {
        let boundaries: [(quietRounds: Int, expectedSeconds: Int)] = [
            (0, 60), (29, 60), (30, 120), (59, 120), (60, 240), (89, 240), (90, 300), (120, 300),
        ]
        for (quietRounds, expectedSeconds) in boundaries {
            let actual = PRWatcher.interval(
                sawChange: false, anyRunning: false, sessionRunning: false,
                quietRounds: quietRounds)
            #expect(
                actual == .seconds(expectedSeconds),
                "quietRounds \(quietRounds) should back off to \(expectedSeconds)s, got \(actual)")
        }
    }

    @Test("A tick tells the round trigger, so a card waiting on CI is re-evaluated")
    func tickTriggersARound() async throws {
        let store = try BoardStore.inMemory()
        let config = ToolConfig(
            claudePath: "/usr/bin/true", ghPath: "/usr/bin/false",
            gitPath: "/usr/bin/false", environment: [:])
        let board = BoardService(store: store, launcher: FakeLauncher())
        let watcher = PRWatcher(store: store, gh: .init(config: config), mover: board)
        let trigger = CountingTrigger()
        await watcher.setRoundTrigger(trigger)

        await watcher.tick()
        #expect(trigger.triggers == 1)
    }

    /// The sibling hook to the test above, proven the same way. Testing only
    /// `interval(sessionRunning:)` directly would leave `tick()`'s wiring of
    /// `sessionProbe` into it unverified — a version of `tick()` that never
    /// called the probe at all would still leave `sessionCapsTheBackoff`
    /// green, since that test never goes through `tick()`.
    @Test("A tick asks the session probe, not only the pure rule that reads its answer")
    func tickAsksTheSessionProbe() async throws {
        actor ProbeCalls {
            private(set) var count = 0
            func mark() { count += 1 }
        }
        let store = try BoardStore.inMemory()
        let config = ToolConfig(
            claudePath: "/usr/bin/true", ghPath: "/usr/bin/false",
            gitPath: "/usr/bin/false", environment: [:])
        let board = BoardService(store: store, launcher: FakeLauncher())
        let watcher = PRWatcher(store: store, gh: .init(config: config), mover: board)
        let calls = ProbeCalls()
        await watcher.setSessionProbe {
            await calls.mark()
            return true
        }

        await watcher.tick()
        #expect(await calls.count == 1)
    }

    /// The third change's own claim: `commitMove` moves a card to Done before
    /// its merge run finishes, so a queued merge has already left In Review by
    /// the time this runs. Without `alsoRead` its reading would never be
    /// refreshed again, which is what would make Task 7's admission guard's
    /// refusal permanent — confirmed separately by reading, not by a test
    /// here: `RunState.isActive` is `!isTerminal`, and `.queued` is not
    /// terminal, so `BoardStore.activeRuns(cardIDs:)` really does include it.
    ///
    /// No `verdicts:` argument to `BoardService` here — this test never
    /// reaches `proposeMove`/`commitMove`, only `PRWatcher.tick()`, so the
    /// `nil`-`gh` `PRVerdictReader` that a headless `BoardService` resolves to
    /// is never asked anything.
    @Test("A queued merge run still gets its card's pull request status refreshed")
    func queuedMergeCardIsRefreshedToo() async throws {
        _ = TestHome.root
        let store = try BoardStore.inMemory()
        let repo = Repo(
            path: "/tmp/repo-\(UUID().uuidString)", nameWithOwner: "phmatray/Elliot",
            displayName: "Elliot")
        try await store.saveRepo(repo)

        let now = Date()
        let card = Card(
            repoID: repo.id, title: "Something", column: .done, orderIndex: 0,
            issueNumber: 7, prNumber: 52, branch: "feat/7-something",
            columnEnteredAt: now, createdAt: now, updatedAt: now)
        try await store.saveCard(card)

        let runID = UUID()
        let run = SkillRun.card(
            id: runID, cardID: card.id, repoID: repo.id, kind: .mergePR, prompt: "x",
            cwd: repo.path,
            logPath: StoreLocation.runLogURL(runID: runID).path,
            stderrPath: StoreLocation.runStderrURL(runID: runID).path, createdAt: now)
        try await store.saveRun(run)
        #expect(try await store.run(id: runID)?.state == .queued)

        let prsPath = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("prs-\(UUID().uuidString).json").path
        try """
            [{"number": 52, "url": "https://github.com/phmatray/Elliot/pull/52",
              "title": "x", "body": "Closes #7", "headRefName": "feat/7-something",
              "isDraft": false, "state": "OPEN", "createdAt": "2026-08-01T10:00:00Z",
              "mergedAt": null, "headRefOid": "3be5f1ee906ff61bdedef0072b635ec6ec40c632"}]
            """.write(toFile: prsPath, atomically: true, encoding: .utf8)

        let config = ToolConfig(
            claudePath: "", ghPath: repositoryRoot.appendingPathComponent("Scripts/fake-gh.sh").path,
            gitPath: "",
            environment: [
                "FAKE_GH_PRS": prsPath,
                "FAKE_GH_PR_VIEW": repositoryRoot.appendingPathComponent(
                    "Fixtures/gh/pr-view-unstable.json"
                ).path,
            ])
        let board = BoardService(store: store, launcher: FakeLauncher())
        let watcher = PRWatcher(store: store, gh: GHClient(config: config), mover: board)

        await watcher.tick()

        let stored = try #require(try await store.prStatus(repoID: repo.id, prNumber: 52))
        #expect(stored.rawMergeStateStatus == "UNSTABLE")
    }
}

/// Task 11: the guards `AutoDevService.start` composes rather than
/// re-deriving. `UnattendedStartRefusal` and `PreflightState` come from
/// `ElliotModel`, `ElliotErrorCode` from `ElliotIPC` — both already imported by
/// this file's header.
@Suite("Auto-dev — starting")
struct AutoDevStartTests {

    private let epoch = Date(timeIntervalSince1970: 1_770_000_000)

    private struct Fixture {
        var store: BoardStore
        var board: BoardService
        var launcher: FakeLauncher
        /// Here only as the `RunQueueReading` the service reads. It launches
        /// nothing — see the comment in `fixture()`.
        var scheduler: RunScheduler
        var service: AutoDevService
        var repo: Repo
        var cards: [Card]
    }

    private func fixture(dailyCeiling: Double? = 25) async throws -> Fixture {
        // `TestHome` first: `start` ends by calling `advance()`, and from Task 12
        // on that round commits moves, which resolve `StoreLocation` run paths.
        _ = TestHome.root
        let store = try BoardStore.inMemory()
        let config = ToolConfig(
            claudePath: "/usr/bin/true", ghPath: "/usr/bin/false",
            gitPath: "/usr/bin/false", environment: [:])
        // The board launches through a **fake**, and the real scheduler is here
        // only to answer `RunQueueReading`. This suite is about what `start`
        // refuses; `advance()` is a no-op in this task (filled in by Task 12),
        // so no proposal is ever evaluated and the default `verdicts:` a
        // headless `BoardService` resolves to (a `nil`-`gh` `PRVerdictReader`)
        // is never asked anything — unlike `AutoDevProposalTests.fixture()` in
        // this file, which wires a real one for exactly that reason.
        let launcher = FakeLauncher()
        let scheduler = RunScheduler(
            store: store, toolConfig: config, verifier: Verifier(gh: .init(config: config)))
        let board = BoardService(store: store, launcher: launcher)
        if let dailyCeiling {
            try await store.saveSpendCeiling(SpendCeiling(perRunUSD: nil, perDayUSD: dailyCeiling))
        }
        let repo = Repo(
            path: "/tmp/repo-\(UUID().uuidString)", nameWithOwner: "phmatray/Elliot",
            displayName: "Elliot")
        try await store.saveRepo(repo)
        var cards: [Card] = []
        for index in 0..<2 {
            cards.append(try await board.createCard(
                repoID: repo.id, title: "Card \(index)",
                story: UserStory(
                    role: "developer", want: "thing \(index)", benefit: "a reason")).card)
        }
        let service = AutoDevService(
            store: store, board: board, launcher: launcher, queue: scheduler,
            clock: { self.epoch })
        return Fixture(
            store: store, board: board, launcher: launcher, scheduler: scheduler,
            service: service, repo: repo, cards: cards)
    }

    private func session(_ f: Fixture, cards: [UUID]? = nil) -> AutoDevSession {
        AutoDevSession(
            repoID: f.repo.id, engagedCardIDs: cards ?? f.cards.map(\.id),
            maxAttemptsPerCard: 2, patience: 900, startedAt: epoch)
    }

    @Test("A started session persists itself and a row per engaged card, in one write")
    func startPersists() async throws {
        let f = try await fixture()
        let started = try await f.service.start(session: session(f), preflight: .passing)

        #expect(started.state == .running)
        #expect(try await f.store.autoDevSession(id: started.id)?.engagedCardIDs.count == 2)
        let rows = try await f.store.autoDevEngagements(sessionID: started.id)
        #expect(rows.count == 2)
        #expect(Set(rows.map(\.cardID)) == Set(f.cards.map(\.id)))
        // Deliberately **not** an assertion about `attempts`. `start` ends by
        // calling `advance()`, so from Task 12 on the first round has already
        // run by the time these rows are read and both cards may have spent
        // one. What `start` promises is the *set* — a row for every engaged
        // card, written with the session in one transaction — and that is what
        // this test is named for. What a round does to `attempts` is Task 12's.
    }

    // Obligation 1 from `AutoDevDriving.swift:64-68` ("a loop that reaches its
    // own end must make that observable") requires `start` to re-read the
    // session after `advance()` and return the *stored* row, never the
    // in-memory value it opened — see the comment at the end of
    // `AutoDevService.start`. **Deliberately no test claims to verify that
    // here.** With `advance()` a no-op in this task (filled in by Task 12),
    // nothing between the write and the return can make the in-memory `opened`
    // diverge from the stored row — measured directly: reverting the fix to
    // `return opened` left every test in this suite, including a
    // store-vs-return equality check, passing anyway (9/9). A test that cannot
    // fail when the mechanism it names is removed is exactly the trap this
    // task's own instructions warn against, so the honest position is that
    // this obligation is satisfied by inspection now (`return try await
    // store.autoDevSession(id: opened.id) ?? opened`) and becomes provable at
    // Task 12, once `advance()` can actually settle a card within `start`'s own
    // call and give the two values room to disagree.

    @Test("A repository Preflight blocks refuses the whole session, by name")
    func preflightBlocks() async throws {
        let f = try await fixture()
        await #expect(throws: AutoDevError.repoRefused(.preflightBlocked)) {
            try await f.service.start(session: session(f), preflight: .failing)
        }
        #expect(try await f.store.runningAutoDevSessions().isEmpty)
    }

    @Test("A disabled repository refuses the whole session too")
    func disabledRepoRefuses() async throws {
        let f = try await fixture()
        var repo = f.repo
        repo.isEnabled = false
        try await f.store.saveRepo(repo)
        await #expect(throws: AutoDevError.repoRefused(.repoDisabled)) {
            try await f.service.start(session: session(f), preflight: .passing)
        }
    }

    @Test("No daily ceiling, no session — the brake was sized against a human's rhythm")
    func noCeilingRefuses() async throws {
        let f = try await fixture(dailyCeiling: nil)
        await #expect(throws: AutoDevError.noDailySpendCeiling) {
            try await f.service.start(session: session(f), preflight: .passing)
        }
    }

    @Test("A card from another repository is refused rather than quietly dropped")
    func foreignCardRefuses() async throws {
        let f = try await fixture()
        let other = Repo(
            path: "/tmp/other-\(UUID().uuidString)", nameWithOwner: "phmatray/Other",
            displayName: "Other")
        try await f.store.saveRepo(other)
        let stranger = try await f.board.createCard(repoID: other.id, title: "Elsewhere").card

        await #expect(throws: AutoDevError.foreignCard(stranger.id)) {
            try await f.service.start(
                session: session(f, cards: f.cards.map(\.id) + [stranger.id]),
                preflight: .passing)
        }
    }

    @Test("An empty engagement is refused, because a session with nothing to do is a mistake")
    func emptyRefuses() async throws {
        let f = try await fixture()
        await #expect(throws: AutoDevError.noCards) {
            try await f.service.start(session: session(f, cards: []), preflight: .passing)
        }
    }

    @Test("The same card twice is one engagement, not two")
    func duplicatesAreOne() async throws {
        let f = try await fixture()
        let started = try await f.service.start(
            session: session(f, cards: [f.cards[0].id, f.cards[0].id]),
            preflight: .passing)
        #expect(started.engagedCardIDs == [f.cards[0].id])
        #expect(try await f.store.autoDevEngagements(sessionID: started.id).count == 1)
    }

    @Test("Every refusal has a wire code and a next action")
    func refusalsMapToTheWire() {
        for error: AutoDevError in [
            .repoNotFound(UUID()), .repoRefused(.repoDisabled), .repoRefused(.preflightBlocked),
            .noCards, .foreignCard(UUID()), .noDailySpendCeiling,
        ] {
            let response = error.response
            #expect(response.message.isEmpty == false)
            #expect(response.hint?.isEmpty == false)
        }
        #expect(AutoDevError.repoRefused(.preflightBlocked).response.code == .autoDevRefused)
        #expect(AutoDevError.repoRefused(.repoDisabled).response.code == .autoDevRefused)
        #expect(AutoDevError.repoNotFound(UUID()).response.code == .repoNotFound)
        #expect(ElliotErrorCode.autoDevRefused.rawValue == "auto_dev_refused")
    }

    /// Fix round 1, finding 2: `refusalsMapToTheWire` above only checks
    /// non-emptiness, which a fixed unrelated string and a swapped hint both
    /// satisfy — measured directly: both breaks left the whole suite green.
    /// The wire *code* was already pinned; this pins the *text*, which is the
    /// entire explanation a person gets when a session refuses to start.
    @Test("A repoRefused response's message is the rule's sentence, and each hint names its own fix")
    func repoRefusedTextIsPinned() {
        // The message half: not a copy of the rule's two sentences (that copy
        // would itself be a second home for them, which `eachSentenceHasOneHome`
        // in `UnattendedStartDelegationTests` polices for `Sources/`) but a
        // comparison against the one place they live, so a placeholder replacing
        // `refusal.sentence` in `AutoDevError.response` cannot pass by
        // coincidence.
        #expect(
            AutoDevError.repoRefused(.repoDisabled).response.message
                == UnattendedStartRefusal.repoDisabled.sentence)
        #expect(
            AutoDevError.repoRefused(.preflightBlocked).response.message
                == UnattendedStartRefusal.preflightBlocked.sentence)

        // The hint half: `AutoDevError.response`'s own words, pinned as
        // literals — the convention `RefusalHintTests` uses for exactly this
        // reason, "the text is the interface here". Two separate equalities,
        // not a not-equal-to-each-other check: a hint that drifted to some
        // *third* wrong sentence would still differ from its sibling and slip
        // past a mere inequality.
        #expect(
            AutoDevError.repoRefused(.repoDisabled).response.hint
                == "Enable the repository in Elliot's Preflight screen.")
        #expect(
            AutoDevError.repoRefused(.preflightBlocked).response.hint
                == "Open Elliot's Preflight screen and clear the failing check.")
    }
}

/// A queue that answers without a scheduler, so a round is decided by what the
/// test says is holding a run rather than by what a real drain happened to do.
private actor FakeQueue: RunQueueReading {
    private var paused = false
    private var rows: [QueuedRun] = []

    func queueIsPaused() async -> Bool { paused }
    func queueSnapshot() async -> [QueuedRun] { rows }
    func setPaused(_ value: Bool) { paused = value }
    func setRows(_ value: [QueuedRun]) { rows = value }
}

/// A clock a test can move, and that the actor can read from any isolation.
///
/// At file scope rather than nested in one suite: Task 13 needs it too, and a
/// `private` type nested inside `AutoDevRoundTests` is not reachable from a
/// sibling suite in the same file.
private final class LockedDate: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date
    init(_ value: Date) { self.value = value }
    var date: Date {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
    func advance(by seconds: TimeInterval) {
        lock.lock()
        value = value.addingTimeInterval(seconds)
        lock.unlock()
    }
}

/// Task 12: one coalesced round of re-evaluation, the per-card rule, and the
/// one-merge-at-a-time serialisation.
///
/// ⛔ Adapted from the plan's Step-1 code for six stale APIs — see
/// `task-12-report.md`'s anchor table. The four the override names:
/// `AutoDevPolicy.disposition` has no `reading:` parameter (`NotGreenReason`
/// already carries what `PRReading` used to); `Disposition.code` →
/// `Disposition.engagement`; `AutoDevCardState` → `AutoDevEngagement`;
/// `store.autoDevCards`/`saveAutoDevCard` → `store.autoDevEngagements`/
/// `saveAutoDevEngagement`. Two more found independently: `AutoDevService
/// .start` takes `preflight: PreflightState`, not `preflightChecks:
/// [CheckResult]`; `VerifiedOutcome.merged` takes four non-defaulted
/// associated values, not one.
@Suite("Auto-dev — one round")
struct AutoDevRoundTests {

    private let epoch = Date(timeIntervalSince1970: 1_770_000_000)

    private struct Fixture {
        var store: BoardStore
        var board: BoardService
        var launcher: FakeLauncher
        var queue: FakeQueue
        var repo: Repo
        /// Moves the injected clock. A patience window is expressed by moving
        /// this, never by sleeping.
        var now: LockedDate
    }

    /// Wires a real `GHClient` against `Scripts/fake-gh.sh`, the same seam
    /// `AutoDevProposalTests.fixture()` uses — per the override's ⛔ on
    /// `BoardService(store:launcher:)`: a headless board resolves to a
    /// `nil`-`gh` `PRVerdictReader`, which answers `nil` for every reading
    /// whatever `PRStatus` row a test stores. Only `mergesAreSerialised` below
    /// actually needs a green verdict to reach `.action(.mergePR(...))`, but
    /// every test in this suite shares one fixture, and a headless board here
    /// would silently be a trap for the next test appended to this suite.
    private func fixture() async throws -> (Fixture, AutoDevService) {
        // Every round below commits moves, which resolve `StoreLocation` run
        // paths — so the shared home has to be final before the first one.
        _ = TestHome.root
        let store = try BoardStore.inMemory()
        let launcher = FakeLauncher()
        let queue = FakeQueue()
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
            store: store, launcher: launcher,
            verdicts: PRVerdictReader(store: store, gh: gh))
        try await store.saveSpendCeiling(SpendCeiling(perRunUSD: nil, perDayUSD: 25))
        let repo = Repo(
            path: "/tmp/repo-\(UUID().uuidString)", nameWithOwner: "phmatray/Elliot",
            displayName: "Elliot")
        try await store.saveRepo(repo)
        let now = LockedDate(epoch)
        let service = AutoDevService(
            store: store, board: board, launcher: launcher, queue: queue,
            clock: { now.date })
        return (
            Fixture(
                store: store, board: board, launcher: launcher, queue: queue, repo: repo, now: now),
            service
        )
    }

    private func story(_ index: Int) -> UserStory {
        UserStory(role: "developer", want: "thing \(index)", benefit: "a reason")
    }

    @Test("A round moves a Backlog card and files its issue, and counts one attempt")
    func aRoundAdvances() async throws {
        let (f, service) = try await fixture()
        let card = try await f.board.createCard(
            repoID: f.repo.id, title: "One", story: story(1)).card
        let started = try await service.start(
            session: AutoDevSession(
                repoID: f.repo.id, engagedCardIDs: [card.id], maxAttemptsPerCard: 2,
                patience: 900, startedAt: epoch),
            preflight: .passing)

        #expect(try await f.store.card(id: card.id)?.column == .todo)
        let run = try #require(try await f.store.runs(cardID: card.id).first)
        #expect(run.kind == .createIssue)
        #expect(await f.launcher.launchedRuns() == [run.id])

        let row = try #require(try await f.store.autoDevEngagements(sessionID: started.id).first)
        #expect(row.attempts == 1)

        // The audit says who asked, and it is the session.
        let audits = try await f.store.audits(cardID: card.id)
        #expect(audits.first?.origin == .autoDev(sessionID: started.id))
    }

    @Test("A card its own run is holding waits, and spends no second attempt")
    func aHeldCardWaits() async throws {
        let (f, service) = try await fixture()
        let card = try await f.board.createCard(
            repoID: f.repo.id, title: "One", story: story(1)).card
        let started = try await service.start(
            session: AutoDevSession(
                repoID: f.repo.id, engagedCardIDs: [card.id], maxAttemptsPerCard: 2,
                patience: 900, startedAt: epoch),
            preflight: .passing)

        await service.advance()
        let row = try #require(try await f.store.autoDevEngagements(sessionID: started.id).first)
        #expect(row.attempts == 1)
        #expect(row.disposition == .engaged)
        #expect(try await f.store.runs(cardID: card.id).count == 1)
    }

    @Test("Nothing else in a session starts while one of its merges is pending")
    func mergesAreSerialised() async throws {
        let (f, service) = try await fixture()
        // One card ready to merge, one ready to be implemented.
        var merging = try await f.board.createCard(repoID: f.repo.id, title: "Merging").card
        merging.column = .inReview
        merging.issueNumber = 47
        merging.prNumber = 52
        try await f.store.saveCard(merging)
        // ⚠️ `checkedAt: Date()`, **never** `epoch`. The session's clock is
        // injected and frozen at `epoch`, but the *verdict* is resolved against
        // the wall clock inside `BoardService` — `epoch` is months old, so
        // `resolved(now:)` would call the reading stale, the decision would be
        // `.blocked(.notVerifiedGreen(...))`, and no merge would ever be queued.
        try await f.store.savePRStatus(
            PRStatus(
                repoID: f.repo.id, prNumber: 52, headRefOid: "a1b2c3", checkedAt: Date(),
                rawMergeStateStatus: "CLEAN", rawMergeable: "MERGEABLE", rawReviewDecision: "",
                checks: [GHMergeStatus.StatusCheck(
                    name: "build-and-test", conclusion: "SUCCESS", status: "COMPLETED")]))

        var waiting = try await f.board.createCard(repoID: f.repo.id, title: "Waiting").card
        waiting.column = .todo
        waiting.issueNumber = 48
        try await f.store.saveCard(waiting)

        let started = try await service.start(
            session: AutoDevSession(
                repoID: f.repo.id, engagedCardIDs: [merging.id, waiting.id],
                maxAttemptsPerCard: 2, patience: 900, startedAt: epoch),
            preflight: .passing)

        // The merge was queued; the implement-issue was not started beside it.
        // `pump()` steps over a refused run and admits the next
        // (`RunScheduler.swift:428-436`), so anything running here is one more
        // thing `.mergeWaitsForRepoToBeIdle` waits for.
        #expect(try await f.store.runs(cardID: merging.id).first?.kind == .mergePR)
        #expect(try await f.store.runs(cardID: waiting.id).isEmpty)

        let rows = try await f.store.autoDevEngagements(sessionID: started.id)
        let waitingRow = try #require(rows.first { $0.cardID == waiting.id })
        #expect(waitingRow.disposition == .engaged)
        #expect(waitingRow.reason == QueueRefusal.mergeWaitsForRepoToBeIdle.sentence)
        #expect(waitingRow.attempts == 0)
    }

    @Test("A paused queue stops the round rather than burning the patience window")
    func aPausedQueueStopsTheRound() async throws {
        let (f, service) = try await fixture()
        let card = try await f.board.createCard(
            repoID: f.repo.id, title: "One", story: story(1)).card
        await f.queue.setPaused(true)

        let started = try await service.start(
            session: AutoDevSession(
                repoID: f.repo.id, engagedCardIDs: [card.id], maxAttemptsPerCard: 2,
                patience: 900, startedAt: epoch),
            preflight: .passing)

        #expect(try await f.store.card(id: card.id)?.column == .backlog)
        let row = try #require(try await f.store.autoDevEngagements(sessionID: started.id).first)
        #expect(row.reason == "Not started yet.")
        #expect(row.updatedAt == epoch)
    }

    @Test("A reason that has not changed for the patience window settles the card")
    func patienceSettles() async throws {
        let (f, service) = try await fixture()
        var card = try await f.board.createCard(repoID: f.repo.id, title: "Stuck").card
        card.column = .todo
        try await f.store.saveCard(card)   // To Do with no issue number: blocked for ever.

        let started = try await service.start(
            session: AutoDevSession(
                repoID: f.repo.id, engagedCardIDs: [card.id], maxAttemptsPerCard: 2,
                patience: 600, startedAt: epoch),
            preflight: .passing)

        var row = try #require(try await f.store.autoDevEngagements(sessionID: started.id).first)
        #expect(row.disposition == .engaged)

        f.now.advance(by: 601)
        await service.advance()
        row = try #require(try await f.store.autoDevEngagements(sessionID: started.id).first)
        #expect(row.disposition == .blocked)
        #expect(row.reason.contains("601") == false)   // the window, not the elapsed time
        #expect(row.reason.contains("600 seconds"))
    }

    @Test("A card in Done whose merge did not land is not a success")
    func doneIsNotMerged() async throws {
        let (f, service) = try await fixture()
        var card = try await f.board.createCard(repoID: f.repo.id, title: "Fell over").card
        card.column = .done
        card.prNumber = 52
        card.lastError = "Checks are failing: build."
        try await f.store.saveCard(card)
        // The run `merge-pr` left behind: terminal, and `gh` said it did not merge.
        var run = SkillRun.card(
            cardID: card.id, repoID: f.repo.id, kind: .mergePR, prompt: "x", cwd: f.repo.path,
            logPath: "/tmp/a", stderrPath: "/tmp/b",
            requiresVerifiedGreen: true, createdAt: epoch)
        run.state = .succeeded
        run.verifiedOutcome = .notMerged(reason: "The pull request is still open.")
        try await f.store.saveRun(run)

        let started = try await service.start(
            session: AutoDevSession(
                repoID: f.repo.id, engagedCardIDs: [card.id], maxAttemptsPerCard: 2,
                patience: 900, startedAt: epoch),
            preflight: .passing)

        let row = try #require(try await f.store.autoDevEngagements(sessionID: started.id).first)
        #expect(row.disposition == .blocked)
        // The column says Done for both outcomes; only the run separates them.
        #expect(row.reason == "Checks are failing: build.")
        #expect(try await f.store.card(id: card.id)?.column == .done)
    }

    @Test("A card in Done whose merge landed is a success, decided on the run")
    func mergedIsASuccess() async throws {
        let (f, service) = try await fixture()
        var card = try await f.board.createCard(repoID: f.repo.id, title: "Landed").card
        card.column = .done
        card.prNumber = 52
        try await f.store.saveCard(card)
        var run = SkillRun.card(
            cardID: card.id, repoID: f.repo.id, kind: .mergePR, prompt: "x", cwd: f.repo.path,
            logPath: "/tmp/a", stderrPath: "/tmp/b",
            requiresVerifiedGreen: true, createdAt: epoch)
        run.state = .succeeded
        run.verifiedOutcome = .merged(commitSHA: "deadbeef", number: nil, url: nil, branch: nil)
        try await f.store.saveRun(run)

        let started = try await service.start(
            session: AutoDevSession(
                repoID: f.repo.id, engagedCardIDs: [card.id], maxAttemptsPerCard: 2,
                patience: 900, startedAt: epoch),
            preflight: .passing)

        let row = try #require(try await f.store.autoDevEngagements(sessionID: started.id).first)
        #expect(row.reason == "Merged.")
        #expect(row.disposition == .merged)
    }

    /// **Task 11's obligation, provable for the first time here.** `start`
    /// ends by calling `advance()` and then re-reading the session row rather
    /// than returning the in-memory value it opened with —
    /// `AutoDevDriving.swift:64-68`'s "a loop that reaches its own end must
    /// make that observable." Task 11 could not write a test that discriminates
    /// this: `advance()` was a no-op in that task, so nothing could make the
    /// in-memory value diverge from the stored row, and it removed its own
    /// test after proving that by actually deleting the re-read and watching
    /// 9/9 stay green anyway.
    ///
    /// A single card already `.done` with a terminal, merged run settles in
    /// round one — the round `start()` itself runs — so `finish(session)`
    /// flips the *stored* row to `.finished` before `start` returns. If
    /// `start` returned the in-memory `opened` instead of re-reading, this
    /// would observe `.running` here and the row would already say
    /// `.finished`: the two values would disagree, which is exactly the gap
    /// Task 11 could never construct.
    @Test("A session that settles its only card in round one reports itself finished, not running")
    func aSessionThatSettlesInRoundOneReportsFinished() async throws {
        let (f, service) = try await fixture()
        var card = try await f.board.createCard(repoID: f.repo.id, title: "Landed").card
        card.column = .done
        card.prNumber = 52
        try await f.store.saveCard(card)
        var run = SkillRun.card(
            cardID: card.id, repoID: f.repo.id, kind: .mergePR, prompt: "x", cwd: f.repo.path,
            logPath: "/tmp/a", stderrPath: "/tmp/b",
            requiresVerifiedGreen: true, createdAt: epoch)
        run.state = .succeeded
        run.verifiedOutcome = .merged(commitSHA: "deadbeef", number: nil, url: nil, branch: nil)
        try await f.store.saveRun(run)

        let started = try await service.start(
            session: AutoDevSession(
                repoID: f.repo.id, engagedCardIDs: [card.id], maxAttemptsPerCard: 2,
                patience: 900, startedAt: epoch),
            preflight: .passing)

        #expect(started.state == .finished)
        #expect(try await f.store.autoDevSession(id: started.id)?.state == .finished)
        #expect(started.endedAt != nil)
    }

    @Test("A blocked repository ends the session, not one card")
    func abortSettlesEveryCard() async throws {
        let (f, service) = try await fixture()
        // Three cards in In Review with a pull request and **no reading**.
        //
        // The shape matters: `start` runs a round before this test can do
        // anything, and a card that round can *advance* comes back holding its
        // own run — after which every later round answers
        // `.runAlreadyInFlight` and never reaches `evaluateMove` at all, so
        // `.repoDisabled` could never be seen. These three settle on nothing:
        // the first round answers `.blocked(.notVerifiedGreen(reason:
        // .noReading))` (no `PRStatus` row at all for these numbers), which the
        // policy reads as `.wait` and spawns nothing.
        var cards: [Card] = []
        for index in 0..<3 {
            var card = try await f.board.createCard(
                repoID: f.repo.id, title: "Card \(index)", story: story(index)).card
            card.column = .inReview
            card.issueNumber = 40 + index
            card.prNumber = 60 + index
            try await f.store.saveCard(card)
            cards.append(card)
        }
        let started = try await service.start(
            session: AutoDevSession(
                repoID: f.repo.id, engagedCardIDs: cards.map(\.id),
                maxAttemptsPerCard: 2, patience: 900, startedAt: epoch),
            preflight: .passing)

        let waiting = try await f.store.autoDevEngagements(sessionID: started.id)
        #expect(waiting.allSatisfy { $0.disposition == .engaged })
        #expect(try await f.store.runs(cardID: cards[0].id).isEmpty)

        // The repository is turned off under the session, which is what
        // `evaluateMove` answers `.repoDisabled` to.
        var repo = f.repo
        repo.isEnabled = false
        try await f.store.saveRepo(repo)
        await service.advance()

        let rows = try await f.store.autoDevEngagements(sessionID: started.id)
        #expect(rows.allSatisfy { $0.disposition == .blocked })
        #expect(
            rows.allSatisfy {
                $0.reason == "The repository is disabled in Elliot, so nothing in this session can run."
            })
    }

    // MARK: - Fix round 1

    /// **The central invariant, on the one path that merges to a default
    /// branch unattended.** `gh` is the fact; the agent's — and the loop's
    /// own — prose is a hint. The round that decides to *attempt* a merge and
    /// queues the run must not itself report the card `.merged`: that fact is
    /// established later, and only by `didMerge` reading a *terminal* run's
    /// persisted `verifiedOutcome`. A regression that reports `.merged` the
    /// instant `.mergePR` is committed — before `gh` has said anything — would
    /// leave every other test in this suite green, including
    /// `mergesAreSerialised`, whose own setup this test reuses: that test only
    /// asserts what the *waiting* card's disposition is, never what the
    /// *merging* card's own disposition is in the round its merge is queued.
    @Test("A queued merge is not reported merged until gh confirms it, only queued")
    func aQueuedMergeIsNotReportedMergedYet() async throws {
        let (f, service) = try await fixture()
        var card = try await f.board.createCard(repoID: f.repo.id, title: "Merging").card
        card.column = .inReview
        card.issueNumber = 47
        card.prNumber = 52
        try await f.store.saveCard(card)
        try await f.store.savePRStatus(
            PRStatus(
                repoID: f.repo.id, prNumber: 52, headRefOid: "a1b2c3", checkedAt: Date(),
                rawMergeStateStatus: "CLEAN", rawMergeable: "MERGEABLE", rawReviewDecision: "",
                checks: [GHMergeStatus.StatusCheck(
                    name: "build-and-test", conclusion: "SUCCESS", status: "COMPLETED")]))

        let started = try await service.start(
            session: AutoDevSession(
                repoID: f.repo.id, engagedCardIDs: [card.id], maxAttemptsPerCard: 2,
                patience: 900, startedAt: epoch),
            preflight: .passing)

        // The merge run exists and was queued this very round — nothing has
        // confirmed it yet.
        let run = try #require(try await f.store.runs(cardID: card.id).first)
        #expect(run.kind == .mergePR)
        #expect(run.state == .queued)
        #expect(run.verifiedOutcome == nil)

        // The one assertion that actually discriminates: not "the row says
        // `.merged` when the PR really merged" (a defect that writes
        // `.merged` early would pass that too), but that the row does **not**
        // say `.merged` while the only thing that has happened is the loop
        // deciding to try.
        let row = try #require(try await f.store.autoDevEngagements(sessionID: started.id).first)
        #expect(row.disposition == .engaged)
        #expect(row.disposition != .merged)
    }

    /// **`attempts` counts runs started, not rounds taken — unprotected by
    /// every other test in this suite.** None of the tests above ever drives
    /// a `.noAction` round, so nothing catches a regression that charges an
    /// attempt for a move that spawned nothing. A card already filed (its
    /// `issueNumber` set) moving Backlog → To Do is `.noAction`
    /// (`RuleEngine.swift`: "already filed — moving it again must not open a
    /// second issue"); `maxAttemptsPerCard: 1` makes the failure mode
    /// concrete — a card wrongly charged for the free move would already be
    /// exhausted by round two and settle `.blocked` on "Tried 1 time…"
    /// without ever reaching the real `implement-issue` run.
    @Test("A .noAction move advances the card for free and spends no attempt")
    func noActionRoundCostsNoAttempt() async throws {
        let (f, service) = try await fixture()
        var card = try await f.board.createCard(
            repoID: f.repo.id, title: "Already filed", story: story(9)).card
        card.issueNumber = 999
        try await f.store.saveCard(card)

        let started = try await service.start(
            session: AutoDevSession(
                repoID: f.repo.id, engagedCardIDs: [card.id], maxAttemptsPerCard: 1,
                patience: 900, startedAt: epoch),
            preflight: .passing)

        // Round one, inside `start()`: the card advances for free.
        #expect(try await f.store.card(id: card.id)?.column == .todo)
        #expect(try await f.store.runs(cardID: card.id).isEmpty)
        var row = try #require(try await f.store.autoDevEngagements(sessionID: started.id).first)
        #expect(row.attempts == 0)
        #expect(row.disposition == .engaged)

        // Round two: a card wrongly charged in round one would already read
        // `attempts == maxAttemptsPerCard` here and settle blocked instead of
        // reaching this real run.
        await service.advance()
        let run = try #require(try await f.store.runs(cardID: card.id).first)
        #expect(run.kind == .implementIssue)
        row = try #require(try await f.store.autoDevEngagements(sessionID: started.id).first)
        #expect(row.attempts == 1)
        #expect(row.disposition == .engaged)
    }

    /// **The `held[card.id]` branch — untested by every other test in this
    /// suite.** `RunQueueReading` exists precisely to let a session tell a run
    /// the *scheduler* is holding (the writer cap, the daily ceiling, a pause,
    /// a duplicate `create-issue`, a merge waiting for its repository to be
    /// idle, a merge verdict not yet established) apart from one genuinely
    /// still working — `.paused`, `.dailyCeilingReached` and
    /// `.mergeWaitsForRepoToBeIdle` send the reader somewhere else entirely
    /// than "wait for this run to finish." Every other test in this suite
    /// leaves `FakeQueue`'s rows empty, so `held` is always empty and this
    /// branch is never reached — deleting it entirely leaves the rest of the
    /// suite, and the whole package, green.
    @Test("An active run the scheduler itself is holding reports the scheduler's own reason")
    func heldBranchReportsSchedulersReason() async throws {
        let (f, service) = try await fixture()
        let card = try await f.board.createCard(
            repoID: f.repo.id, title: "Held by the scheduler", story: story(1)).card
        // An active run for this card, saved directly rather than through a
        // committed move — what the branch under test reads is
        // `activeRuns(cardIDs:)` and `queue.queueSnapshot()`, not how the run
        // came to exist.
        let run = SkillRun.card(
            cardID: card.id, repoID: f.repo.id, kind: .createIssue, prompt: "x", cwd: f.repo.path,
            logPath: "/tmp/a", stderrPath: "/tmp/b", createdAt: epoch)
        try await f.store.saveRun(run)
        let refusal = QueueRefusal.writerCapReached(inFlight: 2, cap: 2)
        await f.queue.setRows([
            QueuedRun(
                runID: run.id, cardID: card.id, repoID: f.repo.id,
                repoName: f.repo.nameWithOwner, cardTitle: card.title, kind: .createIssue,
                position: 1, refusal: refusal, queuedAt: epoch),
        ])

        let started = try await service.start(
            session: AutoDevSession(
                repoID: f.repo.id, engagedCardIDs: [card.id], maxAttemptsPerCard: 2,
                patience: 900, startedAt: epoch),
            preflight: .passing)

        let row = try #require(try await f.store.autoDevEngagements(sessionID: started.id).first)
        #expect(row.disposition == .engaged)
        // The scheduler's own reason, not the generic "a run is already
        // working on this card" `AutoDevPolicy` would say for a run held by
        // no queue entry at all.
        #expect(row.reason == refusal.sentence)
        #expect(row.reason != "A run is already working on this card.")
    }
}

/// Task 13: what `finish(_:)` owes the runs a settled card is still holding.
///
/// **Abandoning a card and cancelling its run are not the same act, and only
/// the second frees the card.** A `.stalled` run is non-terminal
/// (`RunState.isTerminal`), so `activeRun(cardID:)` answers with it for ever —
/// the card is held by a run nobody is waiting for. A `.queued` run is the
/// same shape one refusal over.
///
/// ⛔ **A `.running` run is never cancelled by termination.** `finish` reaches
/// every kind of held run through the same `activeRun(cardID:)` read, so the
/// distinction has to be made by `finish` itself, not by what the store hands
/// back. `aRunningRunIsNeverCancelledByTermination` below is what pins it —
/// see that test's own comment for why the session can still reach `finish`
/// with a `.running` run on an engaged card, which is narrower than "a running
/// run keeps the session alive" and is the actual mechanism this file found
/// while tracing `AutoDevPolicy.decide(block:...)`.
///
/// Every fixture here is headless (`BoardService(store:launcher:)`, no
/// `verdicts:`) rather than wired to `Scripts/fake-gh.sh` the way
/// `AutoDevProposalTests`/`AutoDevRoundTests` are: no card constructed below
/// carries both `requiresVerifiedGreen` reachability *and* a live
/// `proposeMove` call — the blocked-by-empty-idea card has no `prNumber` at
/// all, and every held-run card is caught by the `if let run = active[card.id]`
/// branch in `AutoDevService.advance(_:)` before `proposeMove` is ever called,
/// so `BoardService.proposeMove`'s verdict read (`BoardService.swift:153`,
/// gated on `requiresVerifiedGreen && card.prNumber != nil`) is never reached.
@Suite("Auto-dev — termination")
struct AutoDevTerminationTests {

    private let epoch = Date(timeIntervalSince1970: 1_770_000_000)

    /// A session where every card is blocked must finish. Under `withTimeout`
    /// because the failure this guards against is not a wrong answer, it is a
    /// loop that never gives one.
    @Test("A session whose every card is blocked finishes")
    func everyCardBlockedStillFinishes() async throws {
        try await withTimeout(.seconds(20)) {
            let store = try BoardStore.inMemory()
            let launcher = FakeLauncher()
            let queue = FakeQueue()
            let board = BoardService(store: store, launcher: launcher)
            try await store.saveSpendCeiling(SpendCeiling(perRunUSD: nil, perDayUSD: 25))
            let repo = Repo(
                path: "/tmp/repo-\(UUID().uuidString)", nameWithOwner: "phmatray/Elliot",
                displayName: "Elliot")
            try await store.saveRepo(repo)

            // Three cards with nothing on them: `.backlog → .todo` is
            // `.blocked(.emptyIdea)`, which settles without repetition.
            var ids: [UUID] = []
            for _ in 0..<3 {
                let card = try await board.createCard(repoID: repo.id, title: "").card
                ids.append(card.id)
            }

            let service = AutoDevService(
                store: store, board: board, launcher: launcher, queue: queue,
                clock: { self.epoch })
            let started = try await service.start(
                session: AutoDevSession(
                    repoID: repo.id, engagedCardIDs: ids, maxAttemptsPerCard: 2,
                    patience: 600, startedAt: self.epoch),
                preflight: .passing)

            let ended = try #require(try await store.autoDevSession(id: started.id))
            #expect(ended.state == .finished)
            #expect(ended.endedAt == self.epoch)
            #expect(try await store.runningAutoDevSessions().isEmpty)
        }
    }

    /// A fixture shared by the three "a settled card is still holding a run"
    /// tests below: one card in Done behind a failed merge attempt (settled —
    /// `didMerge` reads its `verifiedOutcome`, not the column), holding a
    /// second, still-active run in the caller-chosen state. The card's own
    /// history — a terminal, non-merged run — is what makes Done mean
    /// "attempted, not landed" rather than "nothing happened here yet", the
    /// same shape `AutoDevRoundTests.doneIsNotMerged` exercises.
    private func fixtureWithHeldRun(_ heldState: RunState) async throws
        -> (store: BoardStore, launcher: FakeLauncher, queue: FakeQueue, card: Card, held: SkillRun)
    {
        let store = try BoardStore.inMemory()
        let launcher = FakeLauncher()
        let queue = FakeQueue()
        let board = BoardService(store: store, launcher: launcher)
        try await store.saveSpendCeiling(SpendCeiling(perRunUSD: nil, perDayUSD: 25))
        let repo = Repo(
            path: "/tmp/repo-\(UUID().uuidString)", nameWithOwner: "phmatray/Elliot",
            displayName: "Elliot")
        try await store.saveRepo(repo)

        var card = try await board.createCard(repoID: repo.id, title: "Fell over").card
        card.column = .done
        card.prNumber = 52
        try await store.saveCard(card)

        var attempted = SkillRun.card(
            cardID: card.id, repoID: repo.id, kind: .mergePR, prompt: "x", cwd: repo.path,
            logPath: "/tmp/a", stderrPath: "/tmp/b", createdAt: epoch)
        attempted.state = .failed
        attempted.verifiedOutcome = .notMerged(reason: "Still open.")
        try await store.saveRun(attempted)

        var held = SkillRun.card(
            cardID: card.id, repoID: repo.id, kind: .mergePR, prompt: "x", cwd: repo.path,
            logPath: "/tmp/c", stderrPath: "/tmp/d",
            createdAt: epoch.addingTimeInterval(1))
        held.state = heldState
        try await store.saveRun(held)

        return (store, launcher, queue, card, held)
    }

    /// A `.queued` run held by a settled card is cancelled when the session
    /// ends — the queued-only half of the plan's combined test, kept separate
    /// per the override: one test covering both `.queued` and `.stalled` would
    /// let either arm rot behind the other.
    @Test("Ending a session cancels a queued run its settled card is still holding")
    func queuedRunIsCancelledWhenTheSessionEnds() async throws {
        let (store, launcher, queue, card, held) = try await fixtureWithHeldRun(.queued)

        // A clock this test moves, because the cut is reached **through** the
        // patience window and not around it: an active run is what
        // `activeRun(cardID:)` keeps answering with regardless of its state,
        // so every round short of the patience window reads
        // `.runAlreadyInFlight` — a `.wait`. Under a frozen clock that wait
        // never expires, the card never settles, `finish` is never reached and
        // nothing is ever cancelled.
        let now = LockedDate(epoch)
        let service = AutoDevService(
            store: store, board: BoardService(store: store, launcher: launcher),
            launcher: launcher, queue: queue, clock: { now.date })
        let started = try await service.start(
            session: AutoDevSession(
                repoID: card.repoID, engagedCardIDs: [card.id], maxAttemptsPerCard: 1,
                patience: 600, startedAt: epoch),
            preflight: .passing)

        // While the run still holds the card the session waits, and cancels
        // nothing: abandoning a card mid-wait would be the opposite mistake.
        #expect(await launcher.cancelledRuns().isEmpty)
        #expect(try await store.autoDevSession(id: started.id)?.state == .running)

        now.advance(by: 601)
        await service.advance()

        #expect(try await store.autoDevSession(id: started.id)?.state == .finished)
        #expect(await launcher.cancelledRuns() == [held.id])
    }

    /// The `.stalled` counterpart — `.stalled` is the subtle arm, because it
    /// is **non-terminal** (`RunState.isTerminal`), so `activeRun(cardID:)`
    /// answers with it for ever and the card is held by a run nobody is
    /// waiting for unless `finish` cuts it loose.
    @Test("Ending a session cancels a stalled run its settled card is still holding")
    func stalledRunIsCancelledWhenTheSessionEnds() async throws {
        let (store, launcher, queue, card, held) = try await fixtureWithHeldRun(.stalled)

        let now = LockedDate(epoch)
        let service = AutoDevService(
            store: store, board: BoardService(store: store, launcher: launcher),
            launcher: launcher, queue: queue, clock: { now.date })
        let started = try await service.start(
            session: AutoDevSession(
                repoID: card.repoID, engagedCardIDs: [card.id], maxAttemptsPerCard: 1,
                patience: 600, startedAt: epoch),
            preflight: .passing)

        #expect(await launcher.cancelledRuns().isEmpty)
        #expect(try await store.autoDevSession(id: started.id)?.state == .running)

        now.advance(by: 601)
        await service.advance()

        #expect(try await store.autoDevSession(id: started.id)?.state == .finished)
        #expect(await launcher.cancelledRuns() == [held.id])
    }

    /// ⛔ **The arm the plan states as a rule and tests nowhere.** `finish`
    /// reaches this card exactly the way it reaches the `.queued`/`.stalled`
    /// cases above — `AutoDevPolicy.decide(block:...)`'s `.runAlreadyInFlight`
    /// arm does not read the held run's `RunState` at all, so patience expiry
    /// settles the card `.blocked` and the session reaches `finish` with a
    /// live `.running` run still on an engaged card. That is *narrower* than
    /// "a running run keeps the session alive" — the session genuinely
    /// finishes — and it is exactly why this line has to be pinned in code:
    /// the one thing standing between "the session gave up" and "the session
    /// killed a child mid-merge" is that `finish` must not call
    /// `launcher.cancel(runID:)` for a `.running` run. Nothing upstream of
    /// `finish` protects that; only `finish`'s own `run.state == .queued ||
    /// run.state == .stalled` guard does.
    @Test("A running run is never cancelled by termination")
    func aRunningRunIsNeverCancelledByTermination() async throws {
        let (store, launcher, queue, card, held) = try await fixtureWithHeldRun(.running)

        let now = LockedDate(epoch)
        let service = AutoDevService(
            store: store, board: BoardService(store: store, launcher: launcher),
            launcher: launcher, queue: queue, clock: { now.date })
        let started = try await service.start(
            session: AutoDevSession(
                repoID: card.repoID, engagedCardIDs: [card.id], maxAttemptsPerCard: 1,
                patience: 600, startedAt: epoch),
            preflight: .passing)

        #expect(await launcher.cancelledRuns().isEmpty)

        now.advance(by: 601)
        await service.advance()

        // The session gave up on the card — that much patience expiry always
        // does — but the live run it is still holding is untouched.
        #expect(try await store.autoDevSession(id: started.id)?.state == .finished)
        #expect(await launcher.cancelledRuns().isEmpty)
        #expect(try await store.activeRun(cardID: card.id)?.id == held.id)
        #expect(try await store.activeRun(cardID: card.id)?.state == .running)
    }

    /// A finished session is not resumed, and not advanced again: `round()`
    /// only ever reads `runningAutoDevSessions()`, so a `.finished` row is
    /// invisible to every later `advance()` call.
    @Test("A finished session is not resumed, and not advanced again")
    func aFinishedSessionStaysFinished() async throws {
        let store = try BoardStore.inMemory()
        let launcher = FakeLauncher()
        let queue = FakeQueue()
        let board = BoardService(store: store, launcher: launcher)
        try await store.saveSpendCeiling(SpendCeiling(perRunUSD: nil, perDayUSD: 25))
        let repo = Repo(
            path: "/tmp/repo-\(UUID().uuidString)", nameWithOwner: "phmatray/Elliot",
            displayName: "Elliot")
        try await store.saveRepo(repo)
        let card = try await board.createCard(repoID: repo.id, title: "").card

        let service = AutoDevService(
            store: store, board: board, launcher: launcher, queue: queue, clock: { self.epoch })
        let started = try await service.start(
            session: AutoDevSession(
                repoID: repo.id, engagedCardIDs: [card.id], maxAttemptsPerCard: 1,
                patience: 600, startedAt: epoch),
            preflight: .passing)
        #expect(try await store.autoDevSession(id: started.id)?.state == .finished)

        await service.advance()
        #expect(await launcher.launchedRuns().isEmpty)
        #expect(try await store.card(id: card.id)?.column == .backlog)
    }
}
