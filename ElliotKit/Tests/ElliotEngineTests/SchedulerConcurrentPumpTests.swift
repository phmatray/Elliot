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
            ghPath: "/usr/bin/true",
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

    /// A scheduler that really spawns, against the fake ACP agent, recording one
    /// line per turn in `spawnLog`.
    ///
    /// The repository path is a directory that genuinely exists. `Process` sets
    /// the child's working directory on the spawn, so a `path` pointing at
    /// nothing makes `AgentRun.start` throw — the run would be marked `.failed`
    /// without ever spawning, and a double-spawn test would then read an empty
    /// log and "pass" for the one reason it must not.
    ///
    /// `PATH` is set for the same class of reason: `ToolConfig.environment`
    /// *replaces* the child's environment rather than extending it, and the
    /// double is reached through `/usr/bin/env python3`.
    ///
    /// ⚠️ **`FAKE_ACP_SPAWN_LOG` counts turns, not processes**, because the prompt that names the
    /// run only exists once `session/prompt` arrives — under `claude -p` it was `-p <text>` on
    /// argv and could be logged at start-up. That is the honest reading for this test: the defect
    /// it exists to catch is two agents each *doing* one run's work, which needs a prompt.
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
            adapterExecutable: "/usr/bin/env",
            adapterArguments: ["python3", root.appendingPathComponent("Scripts/fake-acp.py").path],
            ghPath: "/usr/bin/true", gitPath: "/usr/bin/true",
            environment: [
                "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                "FAKE_ACP_SPAWN_LOG": spawnLog,
                "FAKE_ACP_FIXTURE": root
                    .appendingPathComponent("Fixtures/acp/fake-create-issue.json").path,
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

    /// AC 3. The two pumps are the real ones named in the story: one from
    /// `launch`, one from `finish`. A run in a *second* repository is held by a
    /// synthetic `merge-pr`, so it is blocked for the whole test no matter which
    /// pump wins — which is what makes "the blocked run is still pending" a
    /// statement about the queue's bookkeeping rather than about timing.
    @Test("A pump from launch and a pump from finish neither drop the blocked run nor double-spawn")
    func launchAndFinishPumpTogether() async throws {
        for _ in 0..<10 {
            let log = FileManager.default.temporaryDirectory
                .appendingPathComponent("spawn-\(UUID().uuidString).log").path
            defer { try? FileManager.default.removeItem(atPath: log) }
            let (scheduler, store, repo, home) = try await spawningScheduler(spawnLog: log, cap: 4)
            defer { try? FileManager.default.removeItem(at: home) }

            // A second repository, permanently occupied by a merge, so the run
            // parked in it can never be admitted while this test runs.
            // Its own directory: `repo.path` is UNIQUE in the schema, so this
            // cannot reuse the first repository's path.
            let heldPath = home.appendingPathComponent("held", isDirectory: true)
            try FileManager.default.createDirectory(at: heldPath, withIntermediateDirectories: true)
            let held = Repo(
                path: heldPath.path, nameWithOwner: "phmatray/Held",
                defaultBranch: "main", displayName: "Held"
            )
            try await store.saveRepo(held)
            await scheduler.testOnlyMarkInFlight(
                SkillRun(
                    cardID: UUID(), repoID: held.id, kind: .mergePR, prompt: "holder",
                    cwd: "/tmp", logPath: "/tmp/a", stderrPath: "/tmp/b", createdAt: now
                )
            )

            let blocked = try await seedRun(store, held.id, "blocked")
            let first = try await seedRun(store, repo.id, "first")
            let second = try await seedRun(store, repo.id, "second")

            await scheduler.launch(runID: blocked)   // parks, `.mergeInFlightInRepo`
            #expect(await scheduler.queueSnapshot().map(\.runID) == [blocked])

            // `first` runs and will finish on its own, pumping from `finish`;
            // `second` is launched into that same moment, pumping from `launch`.
            let finished = Task {
                try await withTimeout(.seconds(20)) {
                    for await update in scheduler.updates {
                        if case .runFinished(let id, _, _, _) = update, id == first { return }
                    }
                }
            }
            // ⚠️ Concurrently, and that is the whole test. Awaiting the two
            // launches one after the other cannot produce the overlap AC 3 asks
            // for: `launch` does not return until its own `pump` has run, so by
            // the time the second call starts, the first run is already in
            // `inFlight` and no second pump can consider it. Measured with the
            // launches sequential, this test was green in 5 of 5 samples against
            // the unfixed scheduler — it asserted the right properties over a
            // scenario that could not exhibit the defect.
            await withTaskGroup(of: Void.self) { group in
                group.addTask { await scheduler.launch(runID: first) }
                group.addTask { await scheduler.launch(runID: second) }
            }
            try await finished.value

            try await awaitTerminal(store, [first, second])

            // AC 3, both halves.
            #expect(await scheduler.queueSnapshot().map(\.runID) == [blocked])
            #expect(try await store.run(id: blocked)?.state == .queued)

            let counts = spawnCounts(log)
            #expect(counts["first"] == 1)
            #expect(counts["second"] == 1)
            #expect(counts["blocked"] == nil)
        }
    }

    /// `start` now claims the run in `inFlight` *before* its first `await`
    /// (AC 2), so every early return out of `start` has to give that claim back.
    /// A leaked claim is permanent: nothing clears `inFlight` for a run that
    /// never reaches `finish`, so one failed spawn would cost a writer slot for
    /// the life of the process — and `refusal(for:)` counts `inFlight` against
    /// every later run, so the queue would quietly admit one fewer run for ever.
    ///
    /// ⚠️ The sibling early return — `guard let repo = try? await store.repo(…)`
    /// — is deliberately *not* tested by a missing repository row, because that
    /// state is unreachable through the store. `skillRun.repoID` carries a
    /// foreign key onto `repo` (`Migrations.swift`, `onDelete: .cascade`), so a
    /// run referencing an absent repository cannot be inserted (`SQLite error
    /// 19: FOREIGN KEY constraint failed`) and deleting a repository deletes its
    /// runs with it. That branch is reachable only when the read itself
    /// *throws* — `try?` collapses a thrown error and a nil row into one path —
    /// which no seam here can provoke. It releases the claim and fails the run
    /// on the same grounds as this test; it is just not the case that can be
    /// driven from outside.
    @Test("A run whose spawn fails gives its slot back")
    func aFailedSpawnReleasesTheClaim() async throws {
        let store = try BoardStore.inMemory()
        let home = TestHome.scratch("failed-spawn")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        // The repository path exists, so the only reason the spawn can fail is
        // the one under test: `adapterExecutable` is left at its `""` default,
        // which `AgentRun.start` refuses with `adapterNotResolved` before it
        // spawns anything. It used to be a `claudePath` naming no binary; the
        // refusal moved earlier when the CLI runner died, and the claim this
        // test makes — a failed spawn releases the claim — is unchanged.
        let config = ToolConfig(
            ghPath: "/usr/bin/true",
            gitPath: "/usr/bin/true", environment: ["PATH": "/usr/bin:/bin"]
        )
        let scheduler = RunScheduler(
            store: store, toolConfig: config, verifier: Verifier(gh: .init(config: config))
        )
        let repo = Repo(
            path: home.path, nameWithOwner: "phmatray/Elliot",
            defaultBranch: "main", displayName: "Elliot"
        )
        try await store.saveRepo(repo)
        let id = try await seedRun(store, repo.id, "doomed", kind: .createIssue)

        await scheduler.launch(runID: id)

        // Terminal, and recorded — not left `.queued` for the next launch sweep
        // to rediscover. `pump` has already taken it out of `pending`.
        #expect(try await store.run(id: id)?.state == .failed)
        #expect(try await store.run(id: id)?.endedAt != nil)
        #expect(try await store.nonTerminalRuns().isEmpty)
        #expect(await scheduler.queueSnapshot().isEmpty)
        // The claim, given back.
        #expect(await scheduler.activeRunCount == 0)
        #expect(await scheduler.occupancy == (writers: 0, analyses: 0))

        // And the sentence it leaves behind is Elliot's. No child ever started,
        // so there is nobody to quote — yet this went into the field the panel
        // captions "IT SAID" and sets in demoted italic, which told the reader
        // to discount the only account of the failure there is (#288).
        let failed = try #require(try await store.run(id: id))
        #expect(failed.resultText?.isEmpty == false, "the reason the spawn failed is still shown")
        #expect(failed.resultSource == .elliot)
        #expect(RunVerdict.of(failed).itSaid == nil)
    }
}
