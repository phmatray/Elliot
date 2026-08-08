import ElliotModel
import ElliotStore
import Foundation
import TestSupport
import Testing

@testable import ElliotEngine

/// The sweep's whole job is to delete files, so what it must *not* delete is
/// what these tests are mostly about.
///
/// Every one works inside `TestHome` and points the sweeper at directories it
/// made itself. Nothing here can reach the operator's own
/// `~/Library/Application Support/Elliot`.
@Suite("Artefact sweeper")
struct ArtifactSweeperTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func makeDirectory(_ label: String) throws -> URL {
        let url = TestHome.scratch(label)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @discardableResult
    private func write(_ bytes: Int, named name: String, in dir: URL, daysOld: Double) throws -> URL {
        let url = dir.appendingPathComponent(name)
        try Data(repeating: 0x41, count: bytes).write(to: url)
        try FileManager.default.setAttributes(
            [.modificationDate: now.addingTimeInterval(-daysOld * 24 * 3600)],
            ofItemAtPath: url.path
        )
        return url
    }

    /// A store holding one run, in the state the caller names, whose log and
    /// stderr are the two paths given.
    private func store(
        runState: RunState,
        logPath: String,
        stderrPath: String
    ) async throws -> BoardStore {
        let store = try BoardStore.inMemory()
        let repo = Repo(path: "/tmp/r", nameWithOwner: "phmatray/Elliot", displayName: "Elliot")
        try await store.saveRepo(repo)
        let card = Card(
            repoID: repo.id, title: "A card", column: .inProgress,
            columnEnteredAt: now, createdAt: now, updatedAt: now
        )
        try await store.saveCard(card)
        try await store.saveRun(
            SkillRun.card(
                cardID: card.id, repoID: repo.id, kind: .implementIssue,
                prompt: "…", cwd: "/tmp/r", state: runState,
                logPath: logPath, stderrPath: stderrPath, createdAt: now
            )
        )
        return store
    }

    private func names(in dir: URL) throws -> Set<String> {
        Set(try FileManager.default.contentsOfDirectory(atPath: dir.path))
    }

    @Test("The log of a run still in flight survives, and everything else old goes")
    func aLiveRunsLogIsNeverRemoved() async throws {
        // The safety rule, and the reason the sweep may run unattended. The live
        // run's log is made the *worst* candidate the rule could be offered —
        // ancient and by far the largest — so nothing about it but the
        // protection can be what saves it.
        let dir = try makeDirectory("sweeper-live")
        let log = try write(5_000, named: "live.ndjson", in: dir, daysOld: 400)
        let stderr = try write(500, named: "live.stderr.log", in: dir, daysOld: 400)
        try write(100, named: "dead-a.ndjson", in: dir, daysOld: 400)
        try write(200, named: "dead-b.ndjson", in: dir, daysOld: 90)
        try write(9_000, named: "today.ndjson", in: dir, daysOld: 0)

        // Recorded unresolved, exactly as `runLogURL` produces it — which is the
        // spelling that differs from what `FileManager`'s enumerator reports on a
        // home reached through a symlink. If the sweeper compares raw strings,
        // this run's log is not protected and this test is what says so.
        let sweeper = ArtifactSweeper(
            store: try await store(runState: .running, logPath: log.path, stderrPath: stderr.path),
            directories: [dir],
            ceiling: 0
        )
        let report = await sweeper.sweep(now: now)

        #expect(try names(in: dir) == ["live.ndjson", "live.stderr.log", "today.ndjson"])
        #expect(report.removed == 2)
        #expect(report.bytes == 300)
    }

    @Test("A finished run's log is ordinary, and is pruned like anything else")
    func aTerminalRunsLogIsNotProtected() async throws {
        // The complement, and the whole point of the feature: protection is for
        // work still in flight. If a finished run's log were protected too, the
        // rule would bound nothing — 730 of the 730 files measured belong to runs
        // that ended.
        let dir = try makeDirectory("sweeper-terminal")
        let log = try write(100, named: "done.ndjson", in: dir, daysOld: 400)
        let stderr = try write(100, named: "done.stderr.log", in: dir, daysOld: 400)

        let sweeper = ArtifactSweeper(
            store: try await store(runState: .succeeded, logPath: log.path, stderrPath: stderr.path),
            directories: [dir],
            ceiling: 0
        )
        let report = await sweeper.sweep(now: now)

        #expect(try names(in: dir).isEmpty)
        #expect(report.removed == 2)
    }

    @Test("Nothing is old enough, so nothing is removed and the report is empty")
    func aYoungDirectoryLosesNothing() async throws {
        // Today's expected answer against the real directory: 730 files, 31 MB,
        // all written inside the fortnight. The ceiling is set to zero so that a
        // pass here cannot be the budget being generous — only the horizon can
        // produce it.
        let dir = try makeDirectory("sweeper-young")
        for i in 0..<20 { try write(1_000_000, named: "f\(i).ndjson", in: dir, daysOld: Double(i % 14)) }

        let sweeper = ArtifactSweeper(
            store: try await store(runState: .succeeded, logPath: "/nowhere", stderrPath: "/nowhere"),
            directories: [dir],
            ceiling: 0
        )
        let report = await sweeper.sweep(now: now)

        #expect(try names(in: dir).count == 20)
        #expect(report == SweepReport())
    }

    @Test("A directory that does not exist is not an error")
    func missingDirectoryIsNotAnError() async throws {
        // The sweep runs at launch. Anything it can throw is something that can
        // stop the app from starting, and housekeeping has no business doing that.
        let sweeper = ArtifactSweeper(
            store: try await store(runState: .succeeded, logPath: "/nowhere", stderrPath: "/nowhere"),
            directories: [TestHome.scratch("sweeper-absent")],
            ceiling: 0
        )
        #expect(await sweeper.sweep(now: now) == SweepReport())
    }

    @Test("All three directories are swept, and the report is their total")
    func everyDirectoryIsSwept() async throws {
        // `runs/`, `screenshots/` and `analyses/` are the three that grow, and
        // the report is what the status line shows — one number for the sweep,
        // not one per directory.
        let runs = try makeDirectory("sweeper-multi-runs")
        let shots = try makeDirectory("sweeper-multi-shots")
        let analyses = try makeDirectory("sweeper-multi-analyses")
        try write(10, named: "a.ndjson", in: runs, daysOld: 400)
        try write(20, named: "b.png", in: shots, daysOld: 400)
        let nested = analyses.appendingPathComponent("a-1/r-1", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try write(30, named: "stories.json", in: nested, daysOld: 400)

        let sweeper = ArtifactSweeper(
            store: try await store(runState: .succeeded, logPath: "/nowhere", stderrPath: "/nowhere"),
            directories: [runs, shots, analyses],
            ceiling: 0
        )
        let report = await sweeper.sweep(now: now)

        #expect(report.removed == 3)
        #expect(report.bytes == 60)
        #expect(try names(in: runs).isEmpty)
        #expect(try names(in: shots).isEmpty)
        // The nested file goes; the directories that held it are left alone,
        // because unlinking a directory is a different act from unlinking a file.
        #expect(try FileManager.default.contentsOfDirectory(atPath: nested.path).isEmpty)
    }

    @Test("A file that cannot be deleted is skipped, and is not counted as removed")
    func anUndeletableFileIsSkippedNotCounted() async throws {
        // Two separate claims, and the second is the one worth the trouble: the
        // sweep must not throw, *and* the report must count what actually went.
        // A report that counted intentions would say the directory had shrunk
        // when it had not — an accounting error in the one number the reader is
        // given to trust.
        let dir = try makeDirectory("sweeper-locked")
        let locked = dir.appendingPathComponent("locked", isDirectory: true)
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
        try write(70, named: "stuck.ndjson", in: locked, daysOld: 400)
        try write(5, named: "free.ndjson", in: dir, daysOld: 400)

        // A directory without write permission refuses the unlink of a file that
        // is itself perfectly readable — so the file is inventoried and then
        // cannot be removed, which is the case being described.
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: locked.path)
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o700], ofItemAtPath: locked.path
            )
        }

        let sweeper = ArtifactSweeper(
            store: try await store(runState: .succeeded, logPath: "/nowhere", stderrPath: "/nowhere"),
            directories: [dir],
            ceiling: 0
        )
        let report = await sweeper.sweep(now: now)

        #expect(report.removed == 1)
        #expect(report.bytes == 5)
        #expect(FileManager.default.fileExists(atPath: locked.appendingPathComponent("stuck.ndjson").path))
    }

    @Test("The horizon can be turned off, which is how the sweep is shown to delete at all")
    func horizonCanBeDisabled() async throws {
        // Task 5 of the plan runs the real app this way against a copy of the
        // real `runs/`: a no-op that is a no-op for the wrong reason is not
        // evidence that the rule works.
        let dir = try makeDirectory("sweeper-horizon")
        try write(100, named: "fresh.ndjson", in: dir, daysOld: 0)

        let store = try await store(runState: .succeeded, logPath: "/nowhere", stderrPath: "/nowhere")
        #expect(
            await ArtifactSweeper(store: store, directories: [dir], ceiling: 0)
                .sweep(now: now) == SweepReport()
        )
        #expect(
            await ArtifactSweeper(store: store, directories: [dir], ceiling: 0, horizon: 0)
                .sweep(now: now) == SweepReport(removed: 1, bytes: 100)
        )
    }

    @Test("The default directories are Elliot's three artefact directories")
    func defaultsPointAtTheRealDirectories() async throws {
        // The wiring, pinned: the sweeper AppModel builds with no directory
        // argument must be the one that sweeps `runs/`, `screenshots/` and
        // `analyses/`. A default that quietly pointed somewhere else would leave
        // the shipped app doing nothing while every test above stayed green.
        //
        // ⚠️ `TestHome.root` first, and not as a formality — written without it,
        // this test read `ArtifactSweeper.defaultDirectories` and got the
        // operator's **real** `~/Library/Application Support/Elliot` for `runs/`
        // and `screenshots/` and `TestHome` for `analyses/`, from one expression:
        // a suite running in parallel called `setenv` partway through evaluating
        // it. That is the hazard `TestHome` is documented to remove, and the rule
        // it states — touch `root` before resolving any `StoreLocation` path —
        // is the whole of the fix.
        _ = TestHome.root
        #expect(
            ArtifactSweeper.defaultDirectories == [
                StoreLocation.runsDirectory,
                StoreLocation.screenshotsDirectory,
                StoreLocation.analysesDirectory,
            ]
        )
    }
}
