import ElliotEngine
import Foundation
import Testing

@testable import ElliotAppKit

/// That the launch sweep is wired, where it is wired, and what it is allowed to
/// say when it found nothing.
///
/// `AppModel.start()` opens a real store, captures a login shell and locates
/// three tools, so it is not something a test drives. What a test *can* hold is
/// the same two things `RepositoriesSweepReportTests` holds: the pure rule about
/// what gets said, and the shape of the source that says it.
@Suite("Artefact sweep wiring")
struct ArtifactSweepWiringTests {

    private var source: String {
        get throws {
            let path = URL(filePath: #filePath)  // …/Tests/ElliotAppKitTests/<this file>
                .deletingLastPathComponent()  // …/Tests/ElliotAppKitTests
                .deletingLastPathComponent()  // …/Tests
                .deletingLastPathComponent()  // …/ElliotKit
                .appending(path: "Sources/ElliotAppKit/AppModel.swift")
            return try String(contentsOf: path, encoding: .utf8)
        }
    }

    private func lines(of source: String) -> [Substring] {
        source.split(separator: "\n", omittingEmptySubsequences: false)
    }

    @Test("A sweep that removed nothing has nothing to say")
    func anEmptySweepIsNotAFinding() {
        // The expected result on every launch for the foreseeable future — the
        // constants were chosen so that today's 730 files and 31 MB lose nothing.
        // A status line that announced "pruned 0 files" every morning would train
        // the reader to stop reading it, which costs the one time it says
        // something.
        #expect(SweepReport().sentence == nil)
        #expect(SweepReport(removed: 0, bytes: 0).sentence == nil)
    }

    @Test("A sweep that removed something says how much of both")
    func aRealSweepReportsCountAndBytes() throws {
        // Both numbers, because a count alone cannot tell 700 empty files from
        // 700 MB — which is the difference between housekeeping and the reason
        // the feature exists.
        let sentence = try #require(SweepReport(removed: 43, bytes: 12_000_000).sentence)
        #expect(sentence.contains("43"))
        #expect(sentence.contains("12"))
    }

    @Test("One file is one file, not 1 files")
    func singularIsSpelledOut() throws {
        let sentence = try #require(SweepReport(removed: 1, bytes: 900).sentence)
        #expect(!sentence.contains("1 files"))
    }

    @Test("A fresh model has no sweep report yet")
    @MainActor
    func reportStartsAbsent() {
        // Absent rather than zero: "no sweep has finished" and "a sweep found
        // nothing" are different states, and only the second is a fact about the
        // directories.
        #expect(AppModel().artifactSweep == nil)
    }

    @Test("The sweep is built after the reconciler's, and start-up does not wait on it")
    func theSweepIsWiredAfterTheLaunchSweepAndDetached() throws {
        let lines = lines(of: try source)
        let reconcileIndex = try #require(
            lines.firstIndex { $0.contains("await reconciler.sweep()") },
            "the reconciler's launch sweep is still here"
        )
        let buildIndex = try #require(
            lines.firstIndex { $0.contains("ArtifactSweeper(store:") },
            "AppModel builds an ArtifactSweeper"
        )
        let runIndex = try #require(
            lines.firstIndex { $0.contains("await sweeper.sweep()") },
            "and runs it"
        )
        // Sliced from the build site rather than searched from the top: `Task {`
        // appears a dozen times in this file, and the one that matters is the
        // next one after the sweeper is made. `ArraySlice` keeps the parent's
        // indices, so this is comparable with the others.
        let detachIndex = try #require(
            lines[buildIndex...].firstIndex { $0.contains("Task {") },
            "inside a detached Task"
        )

        // After the reconciler: the runs it marks failed are exactly the ones
        // whose logs must stop being protected, and the ones it re-queues are the
        // ones whose logs must start being.
        #expect(buildIndex > reconcileIndex)
        // The sweep walks three directories and unlinks files. Awaited inline it
        // would sit between the reconciler and `isReady`, which is the stretch
        // where the board already shows "Still starting".
        #expect(detachIndex < runIndex)
    }

    @Test("The sweep never writes to the status line")
    func theSweepDoesNotTouchTheStatusLine() throws {
        // ⛔ This is a regression test for a fix, not a style preference. The
        // first attempt appended the sentence to `status` from inside the task,
        // and it was unfixable by placement: the task shares the main actor with
        // `start()`, so it resumes at the next suspension — which is
        // `importIfNeeded`'s `await importer.importRepo(repo)`, whose very next
        // statement assigns `status`. The message was destroyed within
        // milliseconds on every launch that had one, and nothing else read the
        // report, so it left no trace at all.
        //
        // Read the task's body rather than the whole file: `status` is assigned
        // a dozen times in `start()` legitimately, and only the assignments
        // *inside* this task are the bug.
        let lines = lines(of: try source)
        let buildIndex = try #require(lines.firstIndex { $0.contains("ArtifactSweeper(store:") })
        let taskIndex = try #require(lines[buildIndex...].firstIndex { $0.contains("Task {") })
        // Matched by brace depth rather than by indentation: keying the end of
        // the body off a literal run of spaces makes this test fail on a
        // reformat and pass on a real regression, which is the wrong way round.
        var depth = 0
        var end = taskIndex
        for (offset, line) in lines[taskIndex...].enumerated() {
            depth += line.filter { $0 == "{" }.count - line.filter { $0 == "}" }.count
            if depth == 0 {
                end = taskIndex + offset
                break
            }
        }
        let body = lines[taskIndex...end]
        #expect(body.contains { $0.contains("artifactSweep = report") }, "the report is recorded")
        #expect(
            !body.contains { $0.contains("status =") || $0.contains("status +=") },
            "and the status line, which any later writer owns, is left alone"
        )
    }

    @Test("The status bar shows the count only when a sweep removed something")
    func theStatusBarRendersTheReportConditionally() throws {
        // `swift test` cannot see layout, so what is held here is the same thing
        // `RepositoriesSweepReportTests` holds: the shape of the source. The rule
        // is the one the queue figure beside it already follows — a permanent
        // "0 pruned" is furniture, and this strip has been pushed around by its
        // own contents before.
        let path = URL(filePath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "Sources/ElliotAppKit/BoardView.swift")
        let board = try String(contentsOf: path, encoding: .utf8)

        #expect(
            board.contains("if let sweep = model.artifactSweep, let sentence = sweep.sentence"),
            "the figure is conditional on there being something to report"
        )
        #expect(board.contains("pruned\""), "and it names the count")
    }
}
