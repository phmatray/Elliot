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
