import ElliotModel
import ElliotProcess
import ElliotStore
import Foundation
import Testing

@testable import ElliotEngine

/// The durable half of the silence mark: what the scheduler writes to the run's
/// row, in both directions.
///
/// The mark used to be one-way — `markStalled` wrote `.stalled` and nothing
/// anywhere wrote it back — so a `merge-pr` that waited on CI and then produced
/// its next tool call carried the mark until it exited. Nothing here spawns a
/// process: `mark` is asked directly, which is exactly what `consume` does when
/// a notice arrives off `ClaudeRun.updates`.
@Suite("Scheduler — the silence mark")
struct RunSilenceSchedulerTests {

    private struct Fixture {
        var store: BoardStore
        var scheduler: RunScheduler
        var repo: Repo
    }

    private func fixture() throws -> Fixture {
        let store = try BoardStore.inMemory()
        let config = ToolConfig(
            ghPath: "/usr/bin/true",
            gitPath: "/usr/bin/true", environment: [:]
        )
        return Fixture(
            store: store,
            scheduler: RunScheduler(
                store: store, toolConfig: config, verifier: Verifier(gh: .init(config: config))
            ),
            repo: Repo(path: "/tmp", nameWithOwner: "phmatray/Elliot", displayName: "Elliot")
        )
    }

    /// A saved run row in a given state.
    ///
    /// The repository and the card are saved first because both are foreign
    /// keys, and `skillRun` additionally CHECKs that exactly one of `cardID` and
    /// `analysisID` is set — a run row cannot be conjured out of nothing, which
    /// is the point of measuring the write against a real store rather than a
    /// dictionary.
    private func saveRun(_ state: RunState, in fixture: Fixture) async throws -> SkillRun {
        try await fixture.store.saveRepo(fixture.repo)
        let now = Date()
        let card = Card(
            repoID: fixture.repo.id, title: "A run that waits on CI",
            column: .inReview, columnEnteredAt: now, createdAt: now, updatedAt: now
        )
        try await fixture.store.saveCard(card)
        var run = SkillRun.card(
            cardID: card.id, repoID: fixture.repo.id, kind: .mergePR,
            prompt: "/ai-migration-kit:merge-pr 279", cwd: "/tmp",
            logPath: "/tmp/run.ndjson", stderrPath: "/tmp/run.log", createdAt: now
        )
        run.state = state
        try await fixture.store.saveRun(run)
        return run
    }

    @Test("A running run goes quiet, and a quiet one comes back")
    func theMarkGoesBothWays() async throws {
        let fixture = try fixture()
        let run = try await saveRun(.running, in: fixture)

        await fixture.scheduler.mark(.wentQuiet, on: run.id)
        #expect(try await fixture.store.run(id: run.id)?.state == .stalled)

        // The half that did not exist.
        await fixture.scheduler.mark(.startedTalkingAgain, on: run.id)
        #expect(try await fixture.store.run(id: run.id)?.state == .running)
    }

    @Test("Neither notice applies twice")
    func neitherNoticeAppliesTwice() async throws {
        // Not merely harmless: the watchdog announces once per silence and the
        // mirror clears once per silence, so a repeated notice means something
        // upstream lost its latch. It must still not corrupt the row.
        let fixture = try fixture()
        let run = try await saveRun(.running, in: fixture)

        await fixture.scheduler.mark(.wentQuiet, on: run.id)
        await fixture.scheduler.mark(.wentQuiet, on: run.id)
        #expect(try await fixture.store.run(id: run.id)?.state == .stalled)

        await fixture.scheduler.mark(.startedTalkingAgain, on: run.id)
        await fixture.scheduler.mark(.startedTalkingAgain, on: run.id)
        #expect(try await fixture.store.run(id: run.id)?.state == .running)
    }

    @Test("A late recovery never resurrects a run that has ended")
    func aLateRecoveryNeverResurrects() async throws {
        // The race the issue names, on the row that outlives the process: the
        // run can finish between the mirror clearing the latch and this write.
        // `.stalled` and `.running` are both non-terminal, so a resurrected run
        // holds its card against any further move.
        for finished in [RunState.succeeded, .failed, .cancelled, .completedWithDenials, .timedOut] {
            let fixture = try fixture()
            let run = try await saveRun(finished, in: fixture)
            for notice in RunSilence.allCases {
                await fixture.scheduler.mark(notice, on: run.id)
            }
            #expect(
                try await fixture.store.run(id: run.id)?.state == finished,
                Comment(rawValue: "a \(finished) run was dragged back to life")
            )
        }
    }

    @Test("A cancelling run is not dragged back by its last byte")
    func aCancellingRunIsNotDraggedBack() async throws {
        // ⛔ The sharp case, and the one the terminal loop above cannot cover:
        // `cancel` writes `.cancelling` over whatever the run was, `.stalled`
        // included, and `.cancelling` is *not* terminal. The last byte a stalled
        // run emits on its way out must not put it back to `.running`, where the
        // board would show it as going and offer a Cancel that changes nothing.
        let fixture = try fixture()
        let run = try await saveRun(.cancelling, in: fixture)

        await fixture.scheduler.mark(.startedTalkingAgain, on: run.id)
        #expect(try await fixture.store.run(id: run.id)?.state == .cancelling)

        await fixture.scheduler.mark(.wentQuiet, on: run.id)
        #expect(try await fixture.store.run(id: run.id)?.state == .cancelling)
    }

    @Test("A notice for a run that does not exist writes nothing")
    func anUnknownRunIsIgnored() async throws {
        let fixture = try fixture()
        let run = try await saveRun(.running, in: fixture)

        await fixture.scheduler.mark(.wentQuiet, on: UUID())

        #expect(try await fixture.store.run(id: run.id)?.state == .running)
    }
}
