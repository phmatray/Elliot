import ElliotModel
import Foundation
import TestSupport
import Testing

@testable import ElliotStore

/// The one step of the retention sweep that has to touch a real directory.
///
/// Everything it produces is fed to `ArtifactRetention`, which is pure, so this
/// is where a wrong byte count or a silently-guessed timestamp would enter the
/// decision. Every test works inside `TestHome`; nothing here goes near the
/// operator's own `~/Library/Application Support/Elliot`.
@Suite("Artefact inventory")
struct ArtifactInventoryTests {
    private func scratch(_ label: String) throws -> URL {
        let url = TestHome.scratch(label)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func write(_ bytes: Int, to url: URL) throws {
        try Data(repeating: 0x41, count: bytes).write(to: url)
    }

    @Test("Every file in the directory comes back, with the byte count it has on disk")
    func listsFilesWithSizes() throws {
        let dir = try scratch("inventory-sizes")
        try write(10, to: dir.appendingPathComponent("a.ndjson"))
        try write(200, to: dir.appendingPathComponent("b.ndjson"))
        try write(3000, to: dir.appendingPathComponent("c.png"))

        let found = try StoreLocation.inventory(of: dir)
        let sizes = Dictionary(
            uniqueKeysWithValues: found.map { (URL(fileURLWithPath: $0.path).lastPathComponent, $0.bytes) }
        )
        #expect(sizes == ["a.ndjson": 10, "b.ndjson": 200, "c.png": 3000])
        // Not `Date()` — a stamp the sweep could have invented. Every entry
        // carries the file's own modification date, so all three land inside the
        // window the test itself just ran in.
        #expect(found.allSatisfy { abs($0.modified.timeIntervalSinceNow) < 60 })
    }

    @Test("A directory that was never created is empty, not an error")
    func missingDirectoryIsNotAnError() throws {
        // `ensureDirectories()` makes all three at launch, so this is the state a
        // *fresh* home is in for the instant before it — and a sweep that threw
        // there would be a sweep that could stop the app from starting.
        let missing = TestHome.scratch("inventory-absent")
        #expect(try StoreLocation.inventory(of: missing).isEmpty)
    }

    @Test("An entry that cannot be measured is dropped rather than guessed at")
    func unreadableEntryIsSkipped() throws {
        // A dangling symlink is the cheap, real instance of this: it is listed by
        // the directory and has no size or date of its own. Guessing either would
        // put a fabricated age into a decision about deleting things, which is
        // the one kind of wrong answer this whole feature cannot afford.
        let dir = try scratch("inventory-unreadable")
        try write(64, to: dir.appendingPathComponent("real.ndjson"))
        try FileManager.default.createSymbolicLink(
            at: dir.appendingPathComponent("dangling.ndjson"),
            withDestinationURL: dir.appendingPathComponent("nothing-here.ndjson")
        )

        let found = try StoreLocation.inventory(of: dir)
        #expect(found.map { URL(fileURLWithPath: $0.path).lastPathComponent } == ["real.ndjson"])
    }

    @Test("Sub-directories are descended into, and are not themselves artefacts")
    func descendsIntoSubdirectories() throws {
        // `analyses/` is nested two deep — `<analysisID>/<runID>/stories.json` —
        // so a flat listing would report it as three directories and zero bytes,
        // and the sweep would then try to unlink a directory. Both halves are
        // asserted: the file is found, and the directories are not returned.
        let dir = try scratch("inventory-nested")
        let run = dir
            .appendingPathComponent("analysis-1", isDirectory: true)
            .appendingPathComponent("run-1", isDirectory: true)
        try FileManager.default.createDirectory(at: run, withIntermediateDirectories: true)
        try write(500, to: run.appendingPathComponent("stories.json"))

        let found = try StoreLocation.inventory(of: dir)
        #expect(found.count == 1)
        #expect(found.first?.bytes == 500)
        #expect(found.first?.path.hasSuffix("analysis-1/run-1/stories.json") == true)
    }

    @Test("An empty directory yields nothing")
    func emptyDirectory() throws {
        #expect(try StoreLocation.inventory(of: scratch("inventory-empty")).isEmpty)
    }

    @Test("A live run's recorded log path matches what the inventory found")
    func pathsMatchTheOnesRunsRecord() throws {
        // The whole safety rule is a set-membership test between `SkillRun.logPath`
        // and this inventory, and both are strings. The two are produced by
        // different mechanisms — one by `runLogURL`, one by `FileManager`'s
        // enumerator — and they disagreed: the enumerator resolves symlinks and
        // `runLogURL` does not, so under a home like `/tmp/elliot-check` the
        // membership test silently stopped matching and the sweep would have
        // deleted a live run's log. Failing *open*, with nothing on screen.
        //
        // So the guarantee is asserted the way the sweeper must use it: both
        // sides through `canonicalPath`, and the raw `logPath` shown *not* to be
        // enough on its own would be an assertion about the machine's symlinks
        // rather than about the code, so it is left alone.
        _ = TestHome.root
        try StoreLocation.ensureDirectories()
        let log = StoreLocation.runLogURL(runID: UUID())
        try write(8, to: log)
        defer { try? FileManager.default.removeItem(at: log) }

        let found = try StoreLocation.inventory(of: StoreLocation.runsDirectory)
        #expect(found.contains { $0.path == StoreLocation.canonicalPath(log.path) })
    }

    @Test("Canonicalising is idempotent, so a path already through it still matches")
    func canonicalPathIsIdempotent() {
        // The sweeper canonicalises `protected` and the inventory canonicalises
        // itself, so any path can meet the function twice. If a second pass
        // changed the answer, protection would hold on one path and not on a
        // caller that had been careful twice.
        let once = StoreLocation.canonicalPath("/tmp/elliot-check/runs/a.ndjson")
        #expect(StoreLocation.canonicalPath(once) == once)
    }
}
