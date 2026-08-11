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
