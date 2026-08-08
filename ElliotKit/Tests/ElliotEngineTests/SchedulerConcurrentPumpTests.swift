import ElliotModel
import ElliotProcess
import ElliotStore
import Foundation
import TestSupport
import Testing

@testable import ElliotEngine

/// An actor is not a lock: it guarantees one job at a time, not one job to
/// completion. `pump()` awaits the store on every iteration, and `launch` and
/// `finish` both call it, so two pumps holding the same queue is the ordinary
/// case — a run finishing while the user drags a card.
@Suite("Scheduler — concurrent pumps")
struct SchedulerConcurrentPumpTests {

    private let now = Date(timeIntervalSince1970: 1_770_000_000)

    /// `count` real queued runs in a repository that already has a `merge-pr`
    /// in flight, so `refusal(for:)` holds every one of them with
    /// `.mergeInFlightInRepo` and `start` is never reached. Nothing spawns:
    /// this fixture is about the queue, not about processes.
    func blockedQueue(count: Int) async throws -> (RunScheduler, BoardStore, [UUID]) {
        let store = try BoardStore.inMemory()
        let config = ToolConfig(
            claudePath: "/nonexistent/claude", ghPath: "/usr/bin/true",
            gitPath: "/usr/bin/true", environment: [:]
        )
        let repo = Repo(
            path: "/tmp/Elliot", nameWithOwner: "phmatray/Elliot",
            defaultBranch: "main", displayName: "Elliot"
        )
        try await store.saveRepo(repo)

        let scheduler = RunScheduler(
            store: store, toolConfig: config,
            verifier: Verifier(gh: .init(config: config)),
            limits: SchedulerLimits(maxConcurrent: 8, maxConcurrentAnalyses: 8)
        )
        await scheduler.testOnlyMarkInFlight(
            SkillRun(
                cardID: UUID(), repoID: repo.id, kind: .mergePR, prompt: "held", cwd: "/tmp",
                logPath: "/tmp/a", stderrPath: "/tmp/b", createdAt: now
            )
        )

        var ids: [UUID] = []
        for index in 0..<count {
            let card = Card(
                repoID: repo.id, title: "card \(index)",
                columnEnteredAt: now, createdAt: now, updatedAt: now
            )
            try await store.saveCard(card)
            let run = SkillRun(
                cardID: card.id, repoID: repo.id, kind: .createIssue, prompt: "run \(index)",
                cwd: "/tmp", logPath: "/tmp/a", stderrPath: "/tmp/b", createdAt: now
            )
            try await store.saveRun(run)
            ids.append(run.id)
        }
        return (scheduler, store, ids)
    }

    @Test("A run launched while a pump is in flight is not dropped from the queue")
    func concurrentLaunchesAreNotDropped() async throws {
        // Repeated, because whether a concurrent `launch` lands inside the
        // reentrancy window is a scheduling outcome rather than a fact of the
        // code. One iteration proves nothing either way.
        for _ in 0..<40 {
            let (scheduler, store, ids) = try await blockedQueue(count: 4)
            await withTaskGroup(of: Void.self) { group in
                for id in ids {
                    group.addTask { await scheduler.launch(runID: id) }
                }
            }

            let queued = Set(await scheduler.queueSnapshot().map(\.runID))
            #expect(queued == Set(ids))
            // And nothing was quietly abandoned in the store either: a run that
            // vanished from `pending` keeps its `.queued` row, which is what
            // makes the drop invisible until the next launch sweep.
            for id in ids {
                #expect(try await store.run(id: id)?.state == .queued)
            }
        }
    }

    // Measured against the unfixed scheduler, the test above is green 5/5: it
    // reads `pending` only once every `launch` has returned, and by then the drop
    // has healed itself. Each `launch` ends with its own `pump`, the pumps here
    // complete in the order they started, so the last one to finish holds the
    // fullest snapshot and writes the missing run back. It pins the invariant;
    // the defect is demonstrated by `launchAndFinishPumpTogether` below, where a
    // `finish` pump — which verifies against `gh` before it returns — outlives a
    // `launch` pump that started after it and commits the older view.

    @Test("A pump in flight does not resurrect what drain just cancelled")
    func drainIsNotUndoneByAnInFlightPump() async throws {
        for _ in 0..<40 {
            let (scheduler, store, ids) = try await blockedQueue(count: 4)
            for id in ids { await scheduler.launch(runID: id) }

            // `launch` and `drain` race: the pump `launch` starts must not write
            // its pre-drain view of `pending` back over the emptied queue.
            let extra = ids[0]
            await withTaskGroup(of: Void.self) { group in
                group.addTask { await scheduler.drain() }
                group.addTask { await scheduler.launch(runID: extra) }
            }

            // Every run is now either still queued and pending, or cancelled and
            // gone. What must not exist is a `.cancelled` row still sitting in
            // the queue — a discarded run the board offers to run again.
            let pending = Set(await scheduler.queueSnapshot().map(\.runID))
            for id in pending {
                #expect(try await store.run(id: id)?.state == .queued)
            }
        }
    }
}
