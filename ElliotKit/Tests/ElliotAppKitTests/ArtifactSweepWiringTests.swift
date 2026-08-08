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

    @Test("An empty report leaves the status line exactly as it was")
    func anEmptySweepDoesNotTouchTheStatusLine() throws {
        // The rule stated where it is applied, not only where it is computed:
        // the assignment must be conditional on there being a sentence at all.
        // Written as `status += report.sentence ?? ""` this test still passes and
        // the status line still ends with a stray space, so the guard is on the
        // *statement*, not on the string.
        let source = try source
        #expect(
            source.contains("if let sentence = report.sentence"),
            "the status line is only touched when there is something to say"
        )
    }
}
