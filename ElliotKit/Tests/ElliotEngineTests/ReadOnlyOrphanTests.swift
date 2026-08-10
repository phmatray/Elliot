import ElliotModel
import ElliotProcess
import ElliotStore
import Foundation
import Testing

@testable import ElliotEngine

/// The launch sweep, on a run that carries a card but has nothing on GitHub.
///
/// `Reconciler` split orphans on `run.isAnalysis`, which is
/// `kind == .analyzeRepo`. An appraisal carries a `cardID`, so it took the
/// other branch: verified against `gh`, answered `.unverified`, and
/// `CardOutcome.applied` writes that sentence into `card.lastError`. A Backlog
/// card that has never been filed would come back from a crash wearing an error
/// banner about a pull request it does not have.
@Suite("Reconciler — a read-only orphan")
struct ReadOnlyOrphanTests {

    /// A mover that records rather than acts, so a move the sweep should not
    /// make is visible instead of silently applied.
    private final class MoveSpy: SystemMoving, @unchecked Sendable {
        private let lock = NSLock()
        private var _moves: [(UUID, ElliotModel.Column)] = []
        var moves: [(UUID, ElliotModel.Column)] { lock.withLock { _moves } }
        func applySystemMove(
            cardID: UUID, to: ElliotModel.Column, reason: MoveOrigin.SystemReason
        ) async {
            lock.withLock { _moves.append((cardID, to)) }
        }
    }

    private final class InertLauncher: RunLaunching, @unchecked Sendable {
        func launch(runID: UUID) async {}
        func cancel(runID: UUID) async {}
    }

    @Test("An appraisal killed by a crash reports itself instead of asking gh")
    func appraisalOrphanIsReportedNotVerified() async throws {
        let store = try BoardStore.inMemory()
        let config = ToolConfig(
            claudePath: "/usr/bin/false", ghPath: "/usr/bin/false",
            gitPath: "/usr/bin/false", environment: [:]
        )
        let repo = Repo(path: "/tmp/r", nameWithOwner: "phmatray/Elliot", displayName: "Elliot")
        try await store.saveRepo(repo)
        let now = Date()
        let card = Card(
            repoID: repo.id, title: "Unfiled story",
            columnEnteredAt: now, createdAt: now, updatedAt: now
        )
        try await store.saveCard(card)

        var run = SkillRun.card(
            cardID: card.id, repoID: repo.id, kind: .appraiseCards, prompt: "…",
            cwd: repo.path, logPath: "/tmp/a.ndjson", stderrPath: "/tmp/a.log",
            createdAt: now
        )
        run.state = .running
        try await store.saveRun(run)

        let mover = MoveSpy()
        let summary = await Reconciler(
            store: store, verifier: Verifier(gh: .init(config: config)),
            mover: mover, launcher: InertLauncher()
        ).sweep()

        #expect(summary.orphanedRuns == 1)
        // Reported, not corrected: nothing about this run says anything about
        // the card.
        #expect(summary.cardsCorrected == 0)

        let swept = try #require(try await store.run(id: run.id))
        #expect(swept.state == .failed)
        // Its own report, and no verdict: there was never anything on GitHub to
        // check an estimate against.
        #expect(swept.verifiedOutcome == nil)

        // The card is untouched. Asserted **before** the `#require` below, on
        // purpose: a `#require` that fails throws and ends the test, so putting
        // the consequence after the report would hide it behind an absent
        // `analysisReport` in exactly the run this suite is about.
        let after = try #require(try await store.card(id: card.id))
        #expect(after.lastError == nil)
        #expect(after.column == .backlog)
        #expect(mover.moves.isEmpty)

        let report = try #require(swept.analysisReport)
        #expect(report.harvestSource == .none)
        #expect(report.dropped.contains { $0.contains("harvested") })
    }
}
