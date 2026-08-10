import ElliotModel
import Foundation
import Testing

@testable import ElliotAppKit

private let epoch = Date(timeIntervalSince1970: 1_700_000_000)

private func run(
    _ state: RunState,
    repoID: UUID = UUID(),
    kind: SkillKind = .implementIssue,
    startedAt: Date? = epoch
) -> SkillRun {
    var run = SkillRun(
        cardID: kind == .analyzeRepo ? nil : UUID(), repoID: repoID,
        analysisID: kind == .analyzeRepo ? UUID() : nil,
        analysisAngle: kind == .analyzeRepo ? .bugs : nil,
        kind: kind, prompt: "p", cwd: "/tmp",
        logPath: "/tmp/run.ndjson", stderrPath: "/tmp/run.log", createdAt: epoch
    )
    run.state = state
    run.startedAt = startedAt
    return run
}

/// #303: the band reads the collection that was already loaded.
///
/// `RunningNowTests` proves the **rule** purely; this proves the model hands that
/// rule the collection the screen is about, and that the row's Cancel is the same
/// stop every other surface uses.
@MainActor
@Suite("Operations draws what is going")
struct OperationsRunningBandTests {

    @Test("The band reads recentRuns — the collection already loaded and stall-marked")
    func theBandReadsRecentRuns() {
        let model = AppModel()
        let going = run(.running)
        model.testOnlySeedRuns(recent: [going, run(.succeeded), run(.queued)])

        #expect(model.runningNow.shown.map(\.id) == [going.id])
    }

    /// The whole point of using `recentRuns` rather than `activeRuns`: the latter
    /// is keyed by card id, and an analysis run has no card. Before this, an
    /// eight-lens read was in flight with nothing outside the analysis panel
    /// showing it.
    @Test("An analysis run reaches the band, which activeRuns could never hold")
    func analysisRunsReachTheBand() {
        let model = AppModel()
        let analysis = run(.running, kind: .analyzeRepo)
        model.testOnlySeedRuns(active: [:], recent: [analysis])

        #expect(model.activeRuns.isEmpty)
        #expect(model.runningNow.shown.map(\.id) == [analysis.id])
    }

    @Test("With nothing going the band is empty rather than absent")
    func nothingGoing() {
        let model = AppModel()
        model.testOnlySeedRuns(recent: [run(.succeeded), run(.failed)])
        #expect(model.runningNow.isEmpty)
        #expect(model.runningNow.note == nil)
    }

    /// The row says which repository and which lens, and the name comes from the
    /// run's `repoID` — a card cannot answer for an analysis run, which is the
    /// kind this band exists to show.
    @Test("A row names the repository its run belongs to")
    func aRowNamesItsRepository() {
        let model = AppModel()
        let repo = Repo(path: "/tmp/Elliot", nameWithOwner: "phmatray/Elliot", displayName: "Elliot")
        let analysis = run(.running, repoID: repo.id, kind: .analyzeRepo)
        model.testOnlySeed(repos: [repo], cards: [])
        model.testOnlySeedRuns(recent: [analysis])

        let named = model.runningNow.shown[0]
        #expect(named.context(repoName: model.repo(id: named.repoID)?.displayName) == "Elliot · Bugs")
    }

    /// A run whose repository has been forgotten still draws, with what is known.
    /// Dropping the row would hide a run that is holding a card.
    @Test("An unknown repository costs the chip, never the row")
    func anUnknownRepositoryStillDraws() {
        let model = AppModel()
        let orphan = run(.running)
        model.testOnlySeed(repos: [], cards: [])
        model.testOnlySeedRuns(recent: [orphan])

        #expect(model.runningNow.shown.count == 1)
        #expect(model.repo(id: orphan.repoID) == nil)
    }
}

/// One strip, two screens — and one funnel out of it.
///
/// A source-reading gate in the `DrainDuplicationTests` idiom, because what would
/// be wrong here is a **shape**: a second copy of the strip renders perfectly and
/// drifts from the first, and a Cancel wired past `AppModel.cancelRun` stops a
/// process the scheduler still believes it is running. Neither fails a test that
/// asks what the board looks like.
@Suite("The running strip is one component with one stop")
struct RunningStripReuseTests {

    private static var sources: URL {
        URL(filePath: #filePath)          // …/Tests/ElliotAppKitTests/<this file>
            .deletingLastPathComponent()  // …/Tests/ElliotAppKitTests
            .deletingLastPathComponent()  // …/Tests
            .deletingLastPathComponent()  // …/ElliotKit
            .appending(path: "Sources/ElliotAppKit")
    }

    private static func swiftFiles() throws -> [(name: String, source: String)] {
        let directory = sources
        let names = try FileManager.default
            .contentsOfDirectory(atPath: directory.path(percentEncoded: false))
            .filter { $0.hasSuffix(".swift") }
            .sorted()
        return try names.map {
            ($0, try String(contentsOf: directory.appending(path: $0), encoding: .utf8))
        }
    }

    /// The line with any `//` comment removed, for the reason
    /// `AnalysisPanelViewSourceTests` gives: this rule is *explained* in the very
    /// files it governs, so a gate matching raw text would fail on the
    /// explanation and the obvious way to fix it would be to delete the
    /// explanation.
    private static func code(_ source: String) -> String {
        source.split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> Substring in
                guard let comment = line.range(of: "//") else { return line }
                return line[line.startIndex..<comment.lowerBound]
            }
            .joined(separator: "\n")
    }

    @Test("The strip is declared exactly once, in its own file")
    func declaredOnce() throws {
        let declaring = try Self.swiftFiles()
            .filter { Self.code($0.source).contains("struct RunningStrip") }
            .map(\.name)
        #expect(
            declaring == ["RunningStrip.swift"],
            Comment(rawValue: "declared in \(declaring); a second copy is a second thing to fix")
        )
    }

    /// Both screens draw the component. If one stops, it has grown its own copy —
    /// which is the state this repository has paid for three times in
    /// `ChildProcess` alone.
    @Test("The card and the Operations band both draw it")
    func bothScreensDrawIt() throws {
        let files = try Self.swiftFiles()
        for name in ["CardView.swift", "OperationsView.swift"] {
            let source = files.first { $0.name == name }?.source ?? ""
            #expect(
                Self.code(source).contains("RunningStrip("),
                Comment(rawValue: "\(name) no longer draws RunningStrip")
            )
        }
    }

    /// ⛔ One funnel. Every stop — a card's menu, this band, `board_cancel_run` —
    /// goes to `AppModel.cancelRun`, which is the only thing that tells the
    /// scheduler. A second path kills a process the scheduler still holds a slot
    /// for.
    @Test("The band's Cancel is the same stop every other surface uses")
    func cancelGoesThroughTheOneFunnel() throws {
        let files = try Self.swiftFiles()
        let operations = Self.code(files.first { $0.name == "OperationsView.swift" }?.source ?? "")
        #expect(operations.contains("cancel: { Task { await model.cancelRun(id: run.id) } }"))
    }

    /// The gate on offering a stop lives in the strip, not in the closure each
    /// caller hands it: a rule written per call site is one a call site forgets,
    /// and a Cancel on a run that has already had its SIGTERM is a button that
    /// does nothing.
    ///
    /// ⚠️ Only the strip is asserted about. `CardView` also asks
    /// `isCancellable` — for its **context menu**, which is a different
    /// affordance with the same rule — so a gate forbidding the word in every
    /// caller would fail on correct code.
    @Test("Whether a stop is offered is decided in the strip")
    func theStripDecidesWhetherToOfferAStop() throws {
        let files = try Self.swiftFiles()
        let strip = Self.code(files.first { $0.name == "RunningStrip.swift" }?.source ?? "")
        #expect(strip.contains("run.state.isCancellable"))
    }
}
