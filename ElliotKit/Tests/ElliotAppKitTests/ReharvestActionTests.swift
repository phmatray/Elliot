import ElliotEngine
import ElliotModel
import ElliotProcess
import ElliotStore
import Foundation
import TestSupport
import Testing

@testable import ElliotAppKit

/// Queues nothing. The whole claim of #330's criterion 2 is that no child is
/// started, and the engine suite asserts that with its own recorder; here the
/// launcher exists only so a real `AnalysisService` can be built.
private actor NoLaunches: RunLaunching {
    func launch(runID: UUID) async {}
    func cancel(runID: UUID) async {}
}

/// The lens row's second-harvest action (#330), at the two layers `swift test`
/// can reach: what `AppModel.reharvest` does with a success and with a refusal,
/// and that the button asks the model's rule rather than re-deriving it.
@MainActor
@Suite("Harvest again")
struct ReharvestActionTests {

    private struct Seeded {
        var model: AppModel
        var store: BoardStore
        var analysis: Analysis
        var run: SkillRun
        var artifactURL: URL
    }

    /// A model with an open session over one terminal, kept-nothing analysis
    /// run, and a real `stories.json` on disk at the path `StoreLocation`
    /// promises it is kept at.
    ///
    /// A **real** `AnalysisService`, for the reason `AppModelTests` gives about
    /// `startAnalysis`: the thing under test is what a real refusal and a real
    /// harvest do to the panel, and only the real service produces either.
    private func seed(withArtifact: Bool = true) async throws -> Seeded {
        _ = TestHome.root
        let store = try BoardStore.inMemory()
        let launcher = NoLaunches()
        let service = AnalysisService(
            store: store,
            launcher: launcher,
            board: BoardService(store: store, launcher: launcher),
            gh: GHClient(
                config: ToolConfig(
                    ghPath: "/usr/bin/false",
                    gitPath: "/usr/bin/false", environment: [:])),
            gate: OpenGate()
        )
        let repo = Repo(path: "/tmp/r", nameWithOwner: "phmatray/Elliot", displayName: "Elliot")
        try await store.saveRepo(repo)

        let started = try await service.start(repoID: repo.id, angles: [.bugs], origin: .manual)
        var run = started.runs[0]
        run.state = .failed
        run.analysisReport = AnalysisRunReport(
            harvestSource: .none, dropped: ["Elliot stopped before this run was harvested."])
        try await store.saveRun(run)

        let artifactURL = StoreLocation.analysisArtifactURL(
            analysisID: started.analysis.id, runID: run.id)
        if withArtifact {
            try FileManager.default.createDirectory(
                at: artifactURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try """
                [{"title":"Recovered from disk","role":"dev","want":"w","benefit":"b",
                  "evidence":["Sources/Real.swift:1"],"effort":"small"}]
                """.write(to: artifactURL, atomically: true, encoding: .utf8)
        } else {
            try? FileManager.default.removeItem(at: artifactURL)
        }

        let model = AppModel()
        model.testOnlySeed(repos: [repo], cards: [])
        model.selectedRepoID = repo.id
        model.testOnlySeedStore(store)
        model.testOnlyAttachAnalysisService(service)
        model.openAnalysis(started.analysis)
        model.testOnlySeedAnalysis(runs: [run], note: nil)

        return Seeded(
            model: model, store: store, analysis: started.analysis, run: run,
            artifactURL: artifactURL)
    }

    /// The whole loop, from the reader's side: press it, and the row that read
    /// `0 kept` reads the recovered harvest instead.
    @Test("Harvesting again replaces the run's report on the session it is drawn from")
    func theSessionSeesTheNewReport() async throws {
        let seeded = try await seed()
        defer { try? FileManager.default.removeItem(at: seeded.artifactURL) }

        #expect(seeded.model.analysis?.runs.first?.offersReharvest == true)

        let failure = await seeded.model.reharvest(runID: seeded.run.id)
        #expect(failure == nil)

        // `refreshAnalysisRuns` is what puts it there — the value the row draws
        // is the session's, and a re-harvest that did not refresh would leave
        // the row saying `0 kept` over proposals that had just appeared.
        let refreshed = try #require(seeded.model.analysis?.runs.first)
        #expect(refreshed.analysisReport?.harvestSource == .artifact)
        #expect(refreshed.analysisReport?.kept == 1)
        #expect(
            !refreshed.offersReharvest,
            "the button must go away once there is something to show for the run")
        #expect(try await seeded.store.proposals(runID: seeded.run.id).count == 1)
    }

    /// A refusal has to be findable. `analysisWrite` is the funnel that makes
    /// that true for every other analysis write; this is the assertion that the
    /// new one went through it rather than round it.
    @Test("A refused second harvest lands in the panel's note rather than being swallowed")
    func aRefusalIsReadable() async throws {
        let seeded = try await seed()
        defer { try? FileManager.default.removeItem(at: seeded.artifactURL) }

        #expect(await seeded.model.reharvest(runID: seeded.run.id) == nil)
        // Cleared through the seam rather than by assignment: `analysis` is
        // `private(set)`, which is the point — the session is written by the
        // model's own methods and by nothing else.
        seeded.model.testOnlySeedAnalysis(runs: seeded.model.analysis?.runs ?? [], note: nil)

        let failure = await seeded.model.reharvest(runID: seeded.run.id)
        #expect(failure != nil, "the second call must refuse — the run already landed rows")
        let note = try #require(seeded.model.analysis?.note)
        #expect(note.contains("duplicate"), "the note read: \(note)")
    }

    /// The quieter half of #223's rule, one method further along: with no
    /// service the call is a no-op before any `try?` can be reached, and
    /// returning `nil` from it would report a recovery that never happened.
    @Test("Harvesting again with no service reports that it did not harvest")
    func anAbsentServiceIsAFailure() async {
        let model = AppModel()
        #expect(await model.reharvest(runID: UUID()) == .serviceUnavailable)
    }

    // MARK: - The row asks the model's rule

    /// ⛔ **The button is gated on `SkillRun.offersReharvest`, never on an
    /// inline `kept == 0`.**
    ///
    /// A source gate for the reason `CLAUDE.md` gives: `swift test` cannot see a
    /// view, so re-deriving the condition here would leave every behavioural
    /// test above green while the row started offering the action for a run
    /// carrying no report at all — the state nothing in the codebase produces
    /// and that `(analysisReport?.kept ?? 0) == 0` answers `true` for. Same
    /// idiom as `AnalysisPanelViewSourceTests` and `CaretAnchorTests`.
    @Test("The lens row renders the model's flag rather than deciding for itself")
    func theRowDoesNotReDeriveTheRule() throws {
        let source = try Self.lensRunRowCode()

        #expect(
            source.contains("if run.offersReharvest"),
            "LensRunRow no longer gates the second harvest on SkillRun.offersReharvest (#330)")
        #expect(
            source.contains("model.reharvest(runID: run.id)"),
            "the button no longer dispatches to AppModel.reharvest")
        #expect(
            !source.contains("kept == 0"),
            """
            LensRunRow is deciding for itself whether a harvest kept nothing. The rule is \
            SkillRun.offersReharvest — pure, and held by ReharvestRuleTests — and a second \
            spelling here is free to disagree about the run with no report at all (#330)
            """)
    }

    /// `LensRunRow`'s source with every `//` comment cut away, so a *mention* of
    /// a token cannot be read as a use of it — the hazard
    /// `AnalysisPanelViewSourceTests.code(_:)` exists for, and the one CLAUDE.md
    /// records from #186.
    private static func lensRunRowCode() throws -> String {
        let url = URL(filePath: #filePath)          // …/Tests/ElliotAppKitTests/<this file>
            .deletingLastPathComponent()            // …/Tests/ElliotAppKitTests
            .deletingLastPathComponent()            // …/Tests
            .deletingLastPathComponent()            // …/ElliotKit
            .appending(path: "Sources/ElliotAppKit/AnalysisPanelView.swift")
        let source = try String(contentsOf: url, encoding: .utf8)
        let stripped = source
            .components(separatedBy: "\n")
            .map { line -> String in
                guard let comment = line.range(of: "//") else { return line }
                return String(line[line.startIndex..<comment.lowerBound])
            }
            .joined(separator: "\n")

        // A negative needs its positive witness: a renamed row would make the
        // claims above vacuously true.
        let start = try #require(
            stripped.range(of: "struct LensRunRow: View"),
            "LensRunRow has been renamed — this gate has silently stopped covering the lens row")
        var depth = 0
        var open: String.Index?
        var index = start.upperBound
        while index < stripped.endIndex {
            if stripped[index] == "{" {
                if depth == 0 { open = stripped.index(after: index) }
                depth += 1
            } else if stripped[index] == "}" {
                depth -= 1
                if depth == 0, let open { return String(stripped[open..<index]) }
            }
            index = stripped.index(after: index)
        }
        Issue.record("no matching brace for struct LensRunRow")
        return ""
    }
}
