import ElliotModel
import ElliotProcess
import ElliotStore
import Foundation
import TestSupport
import Testing

@testable import ElliotEngine

/// Pause, resume, drain and promote.
///
/// Nothing here spawns a process: the runs are real rows in an in-memory store,
/// admitted through `launch` and held by a writer cap of one, so `pump()` makes
/// the same decisions it makes in production without a `claude` in sight.
@Suite("Queue commands")
struct QueueCommandsTests {

    private let now = Date(timeIntervalSince1970: 1_770_000_000)

    /// A scheduler whose writer cap is one, and `count` real queued runs in one
    /// repository. The first will not start either — `/usr/bin/true` is not a
    /// valid `claude` and `start` would fail — so all `count` stay pending.
    private func seeded(count: Int, cap: Int = 1) async throws -> (RunScheduler, BoardStore, [UUID]) {
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
            limits: SchedulerLimits(maxConcurrent: cap, maxConcurrentAnalyses: cap)
        )

        var ids: [UUID] = []
        for index in 0..<count {
            let card = Card(
                repoID: repo.id, title: "card \(index)",
                columnEnteredAt: now, createdAt: now, updatedAt: now
            )
            try await store.saveCard(card)
            let run = SkillRun(
                cardID: card.id, repoID: repo.id, kind: .createIssue, prompt: "x", cwd: "/tmp",
                logPath: "/tmp/a", stderrPath: "/tmp/b", createdAt: now
            )
            try await store.saveRun(run)
            ids.append(run.id)
        }
        return (scheduler, store, ids)
    }

    @Test("Pausing holds everything, and says so as the reason")
    func pauseHoldsAndExplains() async throws {
        let (scheduler, _, ids) = try await seeded(count: 3)
        await scheduler.pause()
        for id in ids { await scheduler.launch(runID: id) }

        let queue = await scheduler.queueSnapshot()
        #expect(queue.count == 3)
        // Every reason is `.paused`, not a stale cap. A queue still claiming
        // "cap reached" would send the reader to raise a limit that is not the
        // block.
        #expect(queue.allSatisfy { $0.refusal == .paused })
        #expect(await scheduler.paused)
    }

    @Test("Resuming drains without being asked twice")
    func resumeDrains() async throws {
        let (scheduler, store, ids) = try await seeded(count: 2)
        await scheduler.pause()
        for id in ids { await scheduler.launch(runID: id) }
        #expect(await scheduler.queueSnapshot().count == 2)

        await scheduler.resume()
        #expect(await scheduler.paused == false)
        // The spawn fails — there is no `claude` at that path — so both runs are
        // consumed by `pump()` and end failed rather than sitting in the queue.
        // What matters is that resuming acted at all, without a second nudge.
        #expect(await scheduler.queueSnapshot().count < 2)
        #expect(try await store.run(id: ids[0])?.state != .queued)
    }

    @Test("Draining empties the queue and reports what it discarded")
    func drainReportsCount() async throws {
        let (scheduler, _, ids) = try await seeded(count: 3)
        await scheduler.pause()
        for id in ids { await scheduler.launch(runID: id) }

        let cleared = await scheduler.drain()
        #expect(cleared == 3)
        #expect(await scheduler.queueSnapshot().isEmpty)
    }

    @Test("A drained run is left cancelled, not merely forgotten")
    func drainedRunsAreTerminal() async throws {
        // A run that vanished from `pending` would keep its `.queued` state in
        // the store, and the launch sweep would pick it up on the next start
        // and resolve it against `gh` — reviving work the user just discarded.
        let (scheduler, store, ids) = try await seeded(count: 2)
        await scheduler.pause()
        for id in ids { await scheduler.launch(runID: id) }
        await scheduler.drain()

        for id in ids {
            let run = try await store.run(id: id)
            #expect(run?.state == .cancelled)
            #expect(run?.endedAt != nil)
        }
        #expect(try await store.nonTerminalRuns().isEmpty)
    }

    @Test("Draining an empty queue discards nothing and does not fail")
    func drainEmptyIsZero() async throws {
        let (scheduler, _, _) = try await seeded(count: 0)
        #expect(await scheduler.drain() == 0)
    }

    @Test("Promoting moves an entry to the head, keeping the rest in order")
    func promoteReorders() async throws {
        let (scheduler, _, ids) = try await seeded(count: 3)
        await scheduler.pause()
        for id in ids { await scheduler.launch(runID: id) }

        await scheduler.promote(runID: ids[2])
        let order = await scheduler.queueSnapshot().map(\.runID)
        #expect(order == [ids[2], ids[0], ids[1]])
        // Positions are renumbered, not carried over from before the move.
        #expect(await scheduler.queueSnapshot().map(\.position) == [1, 2, 3])
    }

    @Test("Promoting the head, or something not queued, changes nothing")
    func promoteIsIdempotentAndSafe() async throws {
        let (scheduler, _, ids) = try await seeded(count: 2)
        await scheduler.pause()
        for id in ids { await scheduler.launch(runID: id) }

        await scheduler.promote(runID: ids[0])
        await scheduler.promote(runID: UUID())
        #expect(await scheduler.queueSnapshot().map(\.runID) == ids)
    }

    @Test("Promotion changes the order runs are considered in, never the rules")
    func promoteDoesNotBypassAdmission() async throws {
        // The one way this command could be dangerous: a promoted merge jumping
        // ahead of the same-repo rule and tearing down a worktree under a run.
        let (scheduler, store, ids) = try await seeded(count: 2, cap: 8)
        await scheduler.pause()
        for id in ids { await scheduler.launch(runID: id) }

        guard let run = try await store.run(id: ids[1]) else { return }
        await scheduler.testOnlyMarkInFlight(
            SkillRun(
                cardID: UUID(), repoID: run.repoID, kind: .mergePR, prompt: "x", cwd: "/tmp",
                logPath: "/tmp/a", stderrPath: "/tmp/b", createdAt: now
            )
        )
        await scheduler.resume()
        await scheduler.promote(runID: ids[1])

        // Still waiting, and still for the right reason.
        let queue = await scheduler.queueSnapshot()
        #expect(queue.first?.runID == ids[1])
        #expect(queue.first?.refusal == .mergeInFlightInRepo)
    }

    // MARK: - Cancelling one entry

    @Test("Cancelling one queued run leaves the rest of the queue alone")
    func cancelOneKeepsTheRest() async throws {
        // The whole point of the command: "Discard all" was the only way to
        // clear one stuck entry, so removing it cost every other waiting run.
        let (scheduler, store, ids) = try await seeded(count: 3)
        await scheduler.pause()
        for id in ids { await scheduler.launch(runID: id) }

        await scheduler.cancel(runID: ids[1])

        let queue = await scheduler.queueSnapshot()
        #expect(queue.map(\.runID) == [ids[0], ids[2]])
        // Renumbered, not carrying the gap the removal left.
        #expect(queue.map(\.position) == [1, 2])
        #expect(try await store.run(id: ids[0])?.state == .queued)
        #expect(try await store.run(id: ids[2])?.state == .queued)
    }

    @Test("A cancelled queued run is terminal, so the launch sweep cannot revive it")
    func cancelledQueuedRunIsTerminal() async throws {
        let (scheduler, store, ids) = try await seeded(count: 2)
        await scheduler.pause()
        for id in ids { await scheduler.launch(runID: id) }

        await scheduler.cancel(runID: ids[0])

        let run = try await store.run(id: ids[0])
        #expect(run?.state == .cancelled)
        // Without an `endedAt` the sweep treats it as unfinished work and
        // resolves it against `gh` on the next start.
        #expect(run?.endedAt != nil)
    }

    /// ⚠️ **The regression this pair exists for, and the only one a snapshot
    /// cannot see.** `queueSnapshot()` is computed on demand, so a test that
    /// asks it directly passes whether or not anything told the board. The
    /// pending branch of `cancel` published nothing, so the discarded row stayed
    /// on screen until something else happened to pump the queue — and never
    /// yielded `.runFinished`, which is the single event `AppModel` refreshes
    /// `activeRuns` from, so the card kept showing a run that was gone.
    @Test("Cancelling a queued run tells the board, in that order")
    func cancelPublishesFinishThenQueue() async throws {
        let (scheduler, _, ids) = try await seeded(count: 3)
        await scheduler.pause()
        for id in ids { await scheduler.launch(runID: id) }

        let target = ids[1]
        let observed = Task {
            try await withTimeout(.seconds(20)) {
                var sawFinished = false
                for await update in scheduler.updates {
                    switch update {
                    case .runFinished(let id, _, let state, _) where id == target:
                        #expect(state == .cancelled)
                        sawFinished = true
                    // Only a queue published *after* the cancellation counts:
                    // `launch` publishes too, and its rows are already buffered.
                    case .queueChanged(let rows) where sawFinished:
                        return rows.map(\.runID)
                    default:
                        break
                    }
                }
                return []
            }
        }

        await scheduler.cancel(runID: target)
        #expect(try await observed.value == [ids[0], ids[2]])
    }

    @Test("Cancelling something that is not queued changes nothing")
    func cancelUnknownIsSafe() async throws {
        let (scheduler, _, ids) = try await seeded(count: 2)
        await scheduler.pause()
        for id in ids { await scheduler.launch(runID: id) }

        await scheduler.cancel(runID: UUID())
        #expect(await scheduler.queueSnapshot().map(\.runID) == ids)
    }

    @Test("Pausing twice, or resuming when running, is a no-op")
    func commandsAreIdempotent() async throws {
        let (scheduler, _, _) = try await seeded(count: 0)
        await scheduler.resume()
        #expect(await scheduler.paused == false)
        await scheduler.pause()
        await scheduler.pause()
        #expect(await scheduler.paused)
        await scheduler.resume()
        #expect(await scheduler.paused == false)
    }
}
