import ElliotEngine
import ElliotModel
import Foundation
import Testing

@testable import ElliotAppKit

/// One stored analysis. `repoID` is the whole subject of #213, so it and the id
/// are the only parameters. At file scope because both suites below need it.
func analysisFixture(repoID: UUID, id: UUID = UUID()) -> Analysis {
    Analysis(id: id, repoID: repoID, angles: [.bugs], createdAt: Date(timeIntervalSince1970: 0))
}

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

    @Test("Every state member has a default, which is what makes a new one free")
    func defaults() {
        // AC 4 rests on this: `openAnalysis` names only what a session cannot
        // be built without, so a member added later arrives at its default
        // instead of costing a line in `openAnalysis` and another in
        // `closeAnalysis`.
        //
        // ⚠️ `repoID` is the deliberate second exception, beside `id`, and the
        // rule above is why: it is *identity*, not state. A default for it
        // would be a default answer to "which repository is this analysis
        // about" — the exact question whose absence sent the panel to the
        // board's picker (#213).
        let session = AnalysisSession(id: UUID(), repoID: UUID())
        #expect(session.runs.isEmpty)
        #expect(session.proposals.isEmpty)
        #expect(session.note == nil)
        #expect(session.observation == nil)
    }

    @Test("Rows are accepted only by the analysis they were read for")
    func acceptsOnlyItsOwnRows() {
        let id = UUID()
        let session = AnalysisSession(id: id, repoID: UUID())
        #expect(AnalysisSession.accepts(session, rowsFor: id))
        // Closed while the read was in flight.
        #expect(!AnalysisSession.accepts(nil, rowsFor: id))
        // Replaced while the read was in flight — the worse case, because
        // the rows would land in a session that renders them.
        #expect(!AnalysisSession.accepts(AnalysisSession(id: UUID(), repoID: UUID()), rowsFor: id))
    }

    @Test("A silence notice marks the named run and leaves the others alone")
    func markIsByID() {
        let target = run()
        let other = run()
        var session = AnalysisSession(id: UUID(), repoID: UUID(), runs: [target, other])

        session.mark(.wentQuiet, target.id)
        #expect(session.runs.first(where: { $0.id == target.id })?.state == .stalled)
        #expect(session.runs.first(where: { $0.id == other.id })?.state == .running)

        // And back again: the fourth collection takes both directions, which is
        // the half that was never written — the analysis window kept "No output
        // for a while" on a run that had started talking again.
        session.mark(.startedTalkingAgain, target.id)
        #expect(session.runs.first(where: { $0.id == target.id })?.state == .running)
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
        model.openAnalysis(analysisFixture(repoID: UUID()))
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
        model.openAnalysis(analysisFixture(repoID: UUID(), id: first))
        model.testOnlySeedAnalysis(runs: [], note: "Accepted 3 stories.")
        #expect(model.analysis?.note != nil)

        let second = UUID()
        model.openAnalysis(analysisFixture(repoID: UUID(), id: second))

        #expect(model.analysis?.id == second)
        #expect(model.analysis?.note == nil)
        #expect(model.analysis?.runs.isEmpty == true)
        #expect(model.analysis?.proposals.isEmpty == true)
    }

    @Test("A stall, and the recovery after it, still reach the analysis window")
    func stallReachesTheSession() {
        // `mark` walks four collections because any of them can be the one on
        // screen; the analysis window's is the fourth, and it moved into the
        // session.
        let model = model()
        var stalling = SkillRun(
            cardID: nil, repoID: UUID(), analysisID: UUID(), analysisAngle: .bugs,
            kind: .analyzeRepo, prompt: "analyse", cwd: "/tmp",
            logPath: "/tmp/run.ndjson", stderrPath: "/tmp/run.log",
            createdAt: Date(timeIntervalSince1970: 0)
        )
        stalling.state = .running
        model.openAnalysis(analysisFixture(repoID: UUID()))
        model.testOnlySeedAnalysis(runs: [stalling], note: nil)

        model.mark(.wentQuiet, runID: stalling.id)
        #expect(model.analysis?.runs.first?.state == .stalled)

        model.mark(.startedTalkingAgain, runID: stalling.id)
        #expect(model.analysis?.runs.first?.state == .running)
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
        model.openAnalysis(analysisFixture(repoID: UUID(), id: id))
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

        // ⚠️ Seeded **through a session**, which it was not until #290. The
        // staging belongs to an analysis, so staging with no analysis open is
        // not a state a reader can reach — and asserting it survived a hide was
        // asserting the wrong thing about the right value. The claim under test
        // is unchanged and still true: the session lives on the model, so
        // hiding the panel loses nothing.
        model.openAnalysis(analysisFixture(repoID: UUID()))
        let staged = UUID()
        model.analysisSelection = [staged]

        model.showingAnalysisPanel = true
        model.showingAnalysisPanel = false

        #expect(model.analysisAngles == [.bugs, .tests, .docsAndDX])
        #expect(model.analysisInstructions == "Focus on the store layer.")
        #expect(model.analysisMaxStories == 20)
        #expect(model.analysisSelection == [staged])
    }

    /// The defect the move exists to make unrepresentable.
    ///
    /// Stage five proposals, press Finish — whose own tooltip says "Undecided
    /// proposals stay in the store" — start a fresh analysis, and the footer
    /// read "5 selected" over an empty new list. Pressing Accept 5 then handed
    /// the *previous* analysis's ids to `acceptProposals`; `claimProposal` found
    /// them still `.proposed`, and five cards landed in Backlog from an analysis
    /// nobody was looking at.
    @Test("Staging does not outlive the analysis it stages")
    func selectionDiesWithItsAnalysis() {
        let model = AppModel()
        let repoID = UUID()
        model.openAnalysis(analysisFixture(repoID: repoID))
        model.analysisSelection = [UUID(), UUID(), UUID(), UUID(), UUID()]
        #expect(model.analysisSelection.count == 5)

        // Finish.
        model.closeAnalysis()
        #expect(model.analysisSelection.isEmpty)

        // And a *second* analysis starts clean rather than inheriting the
        // staging of the first — `openAnalysis` is one assignment of a whole
        // new session, so this cannot be forgotten in a future edit.
        model.openAnalysis(analysisFixture(repoID: repoID))
        #expect(model.analysisSelection.isEmpty)
    }

    /// In setup there are no proposals, so there is nothing a write could mean.
    /// Reading empty is the correct answer, not a swallowed failure.
    @Test("With no analysis open there is no selection to hold")
    func setupHasNoSelection() {
        let model = AppModel()
        #expect(model.analysis == nil)
        #expect(model.analysisSelection.isEmpty)

        model.analysisSelection = [UUID()]
        #expect(model.analysisSelection.isEmpty)
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

// MARK: - Which repository the panel is about (#213)

/// The panel had one expression for its subject and it was the board's toolbar
/// picker, which the reader can move while an analysis is open. The header then
/// named one repository while the proposals came from another, and every
/// evidence chip kept its verified seal while aiming its click at a different
/// checkout — the family of defect this project has now written down six times:
/// **a mechanism that silently substitutes different behaviour instead of
/// erroring.**
@MainActor
@Suite("The analysis panel's repository")
struct AnalysisRepoScopeTests {
    private func repo(_ name: String) -> Repo {
        Repo(path: "/tmp/\(name)", nameWithOwner: "o/\(name)", displayName: name)
    }

    private func model(_ repos: [Repo]) -> AppModel {
        let model = AppModel()
        model.testOnlySeed(repos: repos, cards: [])
        return model
    }

    // MARK: - Criterion 4: with nothing open, the picker is the subject

    @Test("In setup the panel is about whatever the board is filtered by")
    func setupFollowsThePicker() {
        let a = repo("alpha")
        let b = repo("beta")
        let model = model([a, b])

        model.selectedRepoID = a.id
        #expect(model.analysisRepoID == a.id)
        #expect(model.analysisRepo?.displayName == "alpha")

        // And it *keeps* following it — this is the half that must stay live,
        // because in setup the picker is what Start will target.
        model.selectedRepoID = b.id
        #expect(model.analysisRepo?.displayName == "beta")

        // "All repositories" is a legitimate state: nothing is picked, nothing
        // is resolved, and `analysisRefusal` is what explains it.
        model.selectedRepoID = nil
        #expect(model.analysisRepoID == nil)
        #expect(model.analysisRepo == nil)
    }

    // MARK: - Criteria 1 and 2: once open, the analysis is the subject

    @Test("An open analysis is about its own repository, whatever the picker says")
    func anOpenSessionOwnsTheSubject() {
        let a = repo("alpha")
        let b = repo("beta")
        let model = model([a, b])
        model.selectedRepoID = b.id

        model.openAnalysis(analysisFixture(repoID: a.id))

        #expect(
            model.analysisRepoID == a.id,
            """
            the panel is showing an analysis of alpha while the board is filtered to beta, and it \
            resolved to \(model.analysisRepo?.displayName ?? "nothing") — the header, the run rows \
            and every evidence link read through this
            """
        )
        #expect(model.analysisRepo?.displayName == "alpha")
    }

    /// Criterion 2 stated as the **act**, not as a state: the reader moves the
    /// picker with the panel open, which is the gesture that produced the bug.
    @Test("Moving the picker under an open analysis changes nothing in the panel")
    func movingThePickerDoesNotReachTheSession() {
        let a = repo("alpha")
        let b = repo("beta")
        let model = model([a, b])
        model.selectedRepoID = a.id
        model.openAnalysis(analysisFixture(repoID: a.id))

        model.selectedRepoID = b.id
        #expect(model.analysisRepoID == a.id)

        model.selectedRepoID = nil  // "All repositories" — the same claim
        #expect(model.analysisRepoID == a.id)

        // Finishing hands the subject back to the picker, which is criterion 4
        // reached by the route a reader actually takes.
        model.selectedRepoID = b.id
        model.closeAnalysis()
        #expect(model.analysisRepoID == b.id)
    }

    // MARK: - The forgotten repository

    @Test("An analysis of a repository that is gone resolves to nothing, not to the picked one")
    func aForgottenRepositoryDoesNotFallThrough() {
        let b = repo("beta")
        let model = model([b])
        model.selectedRepoID = b.id

        let vanished = UUID()
        model.openAnalysis(analysisFixture(repoID: vanished))

        #expect(model.analysisRepoID == vanished)
        #expect(
            model.analysisRepo == nil,
            """
            the analysis's repository is no longer registered and the panel resolved to \
            \(model.analysisRepo?.displayName ?? "nil") — falling through to the picked repository \
            here is the defect, not a graceful default: the header would name it and every \
            evidence chip would open files inside it
            """
        )
    }

    // MARK: - The refusal deliberately stays on the picker

    @Test("The Start refusal still speaks for the picked repository, not for an open analysis")
    func theRefusalIsUnaffected() {
        let healthy = repo("healthy")
        let off = Repo(
            path: "/tmp/off", nameWithOwner: "o/off", displayName: "off", isEnabled: false)
        let model = model([healthy, off])

        // A session open on a healthy repository must not make the refusal go
        // quiet about the disabled one Start would actually target.
        model.selectedRepoID = off.id
        model.openAnalysis(analysisFixture(repoID: healthy.id))

        #expect(model.analysisRepoID == healthy.id)
        #expect(model.analysisRefusal == Consequence.reason(.repoDisabled))
    }
}
