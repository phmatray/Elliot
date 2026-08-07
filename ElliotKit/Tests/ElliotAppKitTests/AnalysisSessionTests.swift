import ElliotEngine
import ElliotModel
import Foundation
import Testing

@testable import ElliotAppKit

@Suite("Analysis session")
struct AnalysisSessionTests {
    /// An analysis run: `cardID` nil, `kind` `.analyzeRepo`. Built with
    /// `SkillRun`'s own initialiser — the one the scheduler uses — so the
    /// fixture is the real shape rather than a stand-in, exactly as
    /// `AppModelTests.run(cardID:state:)` does it.
    private func run(state: RunState = .running) -> SkillRun {
        var run = SkillRun(
            cardID: nil, repoID: UUID(), analysisID: UUID(), analysisAngle: .bugs,
            kind: .analyzeRepo, prompt: "analyse", cwd: "/tmp",
            logPath: "/tmp/run.ndjson", stderrPath: "/tmp/run.log",
            createdAt: Date(timeIntervalSince1970: 0)
        )
        run.state = state
        return run
    }

    @Test("Every member but the id has a default, which is what makes a new one free")
    func defaults() {
        // AC 4 rests on this: `openAnalysis` names only the id, so a member
        // added later arrives at its default instead of costing a line in
        // `openAnalysis` and another in `closeAnalysis`.
        let session = AnalysisSession(id: UUID())
        #expect(session.runs.isEmpty)
        #expect(session.proposals.isEmpty)
        #expect(session.note == nil)
        #expect(session.observation == nil)
    }

    @Test("Rows are accepted only by the analysis they were read for")
    func acceptsOnlyItsOwnRows() {
        let id = UUID()
        let session = AnalysisSession(id: id)
        #expect(AnalysisSession.accepts(session, rowsFor: id))
        // Closed while the read was in flight.
        #expect(!AnalysisSession.accepts(nil, rowsFor: id))
        // Replaced while the read was in flight — the worse case, because
        // the rows would land in a session that renders them.
        #expect(!AnalysisSession.accepts(AnalysisSession(id: UUID()), rowsFor: id))
    }

    @Test("A stall marks the named run and leaves the others alone")
    func markStalledIsByID() {
        let target = run()
        let other = run()
        var session = AnalysisSession(id: UUID(), runs: [target, other])
        session.markStalled(target.id)
        #expect(session.runs.first(where: { $0.id == target.id })?.state == .stalled)
        #expect(session.runs.first(where: { $0.id == other.id })?.state == .running)
    }

    @Test("Releasing the handle cancels the observation")
    func handleCancelsOnRelease() {
        // The load-bearing claim of the whole change: `analysis = nil` is
        // allowed to be the only line in `closeAnalysis` precisely because
        // dropping the session drops this handle, and ARC cancels here.
        //
        // Synchronous on purpose, and it does not wait on anything: `deinit`
        // runs when the last strong reference goes, and `Task.cancel()` sets
        // the flag whether or not the task has started. Nothing here sleeps,
        // and nothing measures a duration.
        let task = Task<Void, Never> { try? await Task.sleep(for: .seconds(60)) }
        var handle: ObservationHandle? = ObservationHandle(task)
        #expect(handle != nil)
        #expect(!task.isCancelled)

        handle = nil

        #expect(task.isCancelled)
        task.cancel()  // the test owns this one too; leave nothing running
    }
}

@MainActor
@Suite("Analysis session on the model")
struct AppModelAnalysisSessionTests {
    private func model() -> AppModel {
        let model = AppModel()
        model.testOnlySeed(repos: [], cards: [])
        return model
    }

    @Test("Closing leaves nothing behind")
    func closingLeavesNothing() {
        // Asserted as one claim about the optional rather than as one
        // expectation per member: a list of four would go on passing while a
        // fifth member, added later, survived the close. This cannot.
        let model = model()
        model.openAnalysis(id: UUID())
        #expect(model.analysis != nil)

        model.closeAnalysis()

        #expect(model.analysis == nil)
    }

    @Test("Opening replaces the session rather than clearing members one at a time")
    func openingReplaces() {
        // The defect this issue exists for: `openAnalysis` cleared the runs
        // and the proposals and left `analysisNote`, so a note from a failed
        // start was rendered under the analysis you opened next.
        let model = model()
        let first = UUID()
        model.openAnalysis(id: first)
        model.testOnlySeedAnalysis(runs: [], note: "Accepted 3 stories.")
        #expect(model.analysis?.note != nil)

        let second = UUID()
        model.openAnalysis(id: second)

        #expect(model.analysis?.id == second)
        #expect(model.analysis?.note == nil)
        #expect(model.analysis?.runs.isEmpty == true)
        #expect(model.analysis?.proposals.isEmpty == true)
    }

    @Test("A stall still reaches the analysis window's copy of the run")
    func stallReachesTheSession() {
        // `markStalled` walks four collections because any of them can be the
        // one on screen; the analysis window's is the fourth, and it moved
        // into the session.
        let model = model()
        var stalling = SkillRun(
            cardID: nil, repoID: UUID(), analysisID: UUID(), analysisAngle: .bugs,
            kind: .analyzeRepo, prompt: "analyse", cwd: "/tmp",
            logPath: "/tmp/run.ndjson", stderrPath: "/tmp/run.log",
            createdAt: Date(timeIntervalSince1970: 0)
        )
        stalling.state = .running
        model.openAnalysis(id: UUID())
        model.testOnlySeedAnalysis(runs: [stalling], note: nil)

        model.markStalled(runID: stalling.id)

        #expect(model.analysis?.runs.first?.state == .stalled)
    }

    // MARK: - The panel's visibility, which is not the session

    @Test("Hiding the analysis panel does not end the session")
    func hidingKeepsTheSession() {
        // The whole of #151's criterion 5. `closeAnalysis` drops the session,
        // and `ObservationHandle.deinit` cancels the live proposal observation
        // with it — so a toggle that called it would silently stop proposals
        // landing while eight lenses were still reading.
        let model = model()
        let id = UUID()
        model.openAnalysis(id: id)
        model.showingAnalysisPanel = true
        #expect(model.analysis?.id == id)

        model.showingAnalysisPanel = false
        #expect(model.analysis?.id == id)

        // Re-showing finds the same session, not a new one.
        model.showingAnalysisPanel = true
        #expect(model.analysis?.id == id)

        // Only this ends it.
        model.closeAnalysis()
        #expect(model.analysis == nil)
    }

    /// The gate #151 broke and put back.
    ///
    /// The toolbar button used to carry `.disabled(… || isSelectedRepoBlocked)`,
    /// and that expression was the **only** preflight gate on the whole analysis
    /// path — `AnalysisService.start` checks `isEnabled` and the in-flight
    /// dedupe and nothing else. Dropping the `.disabled` was right (a toggle you
    /// cannot switch off is worse than one that opens onto an explanation) and
    /// it took the gate with it: Start would have spawned up to eight unattended
    /// runs inside a checkout Preflight had already refused.
    @Test("An analysis is refused for a repository Preflight is failing")
    func analysisIsGatedOnPreflight() {
        let healthy = Repo(path: "/tmp/healthy", nameWithOwner: "o/healthy", displayName: "healthy")
        let off = Repo(
            path: "/tmp/off", nameWithOwner: "o/off", displayName: "off", isEnabled: false)
        let blocked = Repo(path: "/tmp/blocked", nameWithOwner: "o/blocked", displayName: "blocked")

        let model = AppModel()
        model.testOnlySeed(repos: [healthy, off, blocked], cards: [])
        model.testOnlySeedChecks(
            repo: blocked.id,
            [CheckResult(id: "worktree", title: "Main checkout", status: .fail, detail: "linked")])

        // No single repository chosen: eight runs against "everything" is not a
        // thing this product does.
        model.selectedRepoID = nil
        #expect(model.analysisRefusal == "Pick a single repository to analyse.")

        model.selectedRepoID = off.id
        #expect(model.analysisRefusal == Consequence.reason(.repoDisabled))

        model.selectedRepoID = blocked.id
        #expect(model.analysisRefusal?.contains("Preflight") == true)

        // And the one case that must be allowed, so the gate is a gate and not a
        // wall.
        model.selectedRepoID = healthy.id
        #expect(model.analysisRefusal == nil)
    }

    @Test("The setup form and the staged selection survive hiding the panel")
    func hidingKeepsTheSetupForm() {
        // The other half of criterion 5, and the half that was still `@State`
        // until the code-review pass: hiding removes `.analysis` from the row,
        // which tears the view down. Ticking six lenses, typing instructions and
        // raising the limit, then glancing at Backlog, must not undo any of it.
        let model = AppModel()
        model.analysisAngles = [.bugs, .tests, .docsAndDX]
        model.analysisInstructions = "Focus on the store layer."
        model.analysisMaxStories = 20
        let staged = UUID()
        model.analysisSelection = [staged]

        model.showingAnalysisPanel = true
        model.showingAnalysisPanel = false

        #expect(model.analysisAngles == [.bugs, .tests, .docsAndDX])
        #expect(model.analysisInstructions == "Focus on the store layer.")
        #expect(model.analysisMaxStories == 20)
        #expect(model.analysisSelection == [staged])
    }

    @Test("The analysis panel is hidden at launch and three columns wide")
    func defaultsAreHiddenAndWide() {
        let model = AppModel()
        // Hidden, unlike the detail panel: that one costs nothing with no card
        // selected, whereas this would claim three columns on every launch for
        // a setup form nobody asked for.
        #expect(model.showingAnalysisPanel == false)
        #expect(model.analysisSpans == PanelLayout.spanChoices.wide)

        // Two panels, two reader preferences. Setting one must not move the
        // other — the board is wide enough to want them at different widths.
        model.analysisSpans = PanelLayout.spanChoices.narrow
        #expect(model.panelSpans == PanelLayout.spanChoices.wide)
        model.panelSpans = PanelLayout.spanChoices.narrow
        model.analysisSpans = PanelLayout.spanChoices.wide
        #expect(model.panelSpans == PanelLayout.spanChoices.narrow)
    }
}
