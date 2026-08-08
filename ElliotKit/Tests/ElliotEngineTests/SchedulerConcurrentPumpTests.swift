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

    /// A scheduler that really spawns, against the fake `claude`, recording one
    /// line per child in `spawnLog`.
    ///
    /// The repository path is a directory that genuinely exists. `Process` sets
    /// the child's working directory on the spawn, so a `path` pointing at
    /// nothing makes `ClaudeRun.start` throw — the run would be marked `.failed`
    /// without ever spawning, and a double-spawn test would then read an empty
    /// log and "pass" for the one reason it must not.
    ///
    /// `PATH` is set for the same class of reason: `ToolConfig.environment`
    /// *replaces* the child's environment rather than extending it, and the
    /// fake's spawn-log block shells out to `head`.
    func spawningScheduler(
        spawnLog: String, cap: Int
    ) async throws -> (RunScheduler, BoardStore, Repo, URL) {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let home = TestHome.scratch("concurrent-pump")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)

        let store = try BoardStore.inMemory()
        let config = ToolConfig(
            claudePath: root.appendingPathComponent("Scripts/fake-claude.sh").path,
            ghPath: "/usr/bin/true", gitPath: "/usr/bin/true",
            environment: [
                "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                "FAKE_CLAUDE_SPAWN_LOG": spawnLog,
                "FAKE_CLAUDE_FIXTURE": root
                    .appendingPathComponent("Fixtures/stream-json/create-issue-success.ndjson").path,
            ]
        )
        let repo = Repo(
            path: home.path, nameWithOwner: "phmatray/Elliot",
            defaultBranch: "main", displayName: "Elliot"
        )
        try await store.saveRepo(repo)
        let scheduler = RunScheduler(
            store: store, toolConfig: config,
            verifier: Verifier(gh: .init(config: config)),
            limits: SchedulerLimits(maxConcurrent: cap, maxConcurrentAnalyses: cap)
        )
        return (scheduler, store, repo, home)
    }

    /// One line per spawn, grouped by the prompt that identifies the run.
    func spawnCounts(_ path: String) -> [String: Int] {
        let text = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
        return text.split(separator: "\n", omittingEmptySubsequences: true)
            .reduce(into: [:]) { counts, line in counts[String(line), default: 0] += 1 }
    }

    /// Seeds a queued run, with a card, in `repoID`. The prompt doubles as the
    /// run's name in the spawn log.
    func seedRun(
        _ store: BoardStore, _ repoID: UUID, _ prompt: String, kind: SkillKind = .implementIssue
    ) async throws -> UUID {
        let card = Card(
            repoID: repoID, title: prompt,
            columnEnteredAt: now, createdAt: now, updatedAt: now
        )
        try await store.saveCard(card)
        let run = SkillRun(
            cardID: card.id, repoID: repoID, kind: kind, prompt: prompt, cwd: "/tmp",
            logPath: FileManager.default.temporaryDirectory
                .appendingPathComponent("log-\(UUID().uuidString)").path,
            stderrPath: "/tmp/b", createdAt: now
        )
        try await store.saveRun(run)
        return run.id
    }

    /// Waits, bounded and on a fact, for every one of `ids` to reach a terminal
    /// state in the store. No sleep, no duration asserted.
    func awaitTerminal(_ store: BoardStore, _ ids: [UUID]) async throws {
        try await withTimeout(.seconds(20)) {
            while true {
                var allDone = true
                for id in ids where try await store.run(id: id)?.state.isActive != false {
                    allDone = false
                }
                if allDone { return }
                await Task.yield()
            }
        }
    }

    @Test("Two pumps considering the same run spawn it once, not twice")
    func aRunIsSpawnedExactlyOnce() async throws {
        // Ten iterations rather than forty: each one spawns real children.
        for _ in 0..<10 {
            let log = FileManager.default.temporaryDirectory
                .appendingPathComponent("spawn-\(UUID().uuidString).log").path
            defer { try? FileManager.default.removeItem(atPath: log) }
            let (scheduler, store, repo, home) = try await spawningScheduler(spawnLog: log, cap: 8)
            defer { try? FileManager.default.removeItem(at: home) }

            var ids: [UUID] = []
            for index in 0..<3 {
                ids.append(try await seedRun(store, repo.id, "run \(index)"))
            }

            // Concurrent launches, so several pumps hold the same queue.
            await withTaskGroup(of: Void.self) { group in
                for id in ids { group.addTask { await scheduler.launch(runID: id) } }
            }
            try await awaitTerminal(store, ids)

            let counts = spawnCounts(log)
            for index in 0..<3 {
                #expect(counts["run \(index)"] == 1)
            }
        }
    }
}
