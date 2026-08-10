import ElliotModel
import Foundation
import Testing

/// The two pure rules a repeat harvest is made of (#330).
///
/// Both live in `ElliotModel` for the reason the layer exists: what a second
/// read of `stories.json` is allowed to say about a run is a rule, not a
/// rendering, and the engine and the lens row must not each hold their own
/// answer to it.
@Suite("Re-harvest rules")
struct ReharvestRuleTests {

    private func run(
        state: RunState,
        kind: SkillKind = .analyzeRepo,
        report: AnalysisRunReport?
    ) -> SkillRun {
        var run = SkillRun(
            cardID: kind == .analyzeRepo ? nil : UUID(),
            repoID: UUID(),
            analysisID: kind == .analyzeRepo ? UUID() : nil,
            analysisAngle: kind == .analyzeRepo ? .bugs : nil,
            kind: kind,
            prompt: "read the repository",
            cwd: "/tmp",
            logPath: "/tmp/run.ndjson",
            stderrPath: "/tmp/run.log",
            createdAt: Date(timeIntervalSince1970: 0)
        )
        run.state = state
        run.analysisReport = report
        return run
    }

    // MARK: - What a repeat harvest leaves on the run

    /// Criterion 5, and the one place this feature could quietly lie. The
    /// sentinel's baseline lived in the scheduler's memory and died with the
    /// app; nothing a second read of the file can do brings it back.
    @Test("An unchecked working tree stays unchecked, however much the re-read kept")
    func nilSentinelSurvivesASuccessfulReharvest() {
        let orphaned = AnalysisRunReport(
            harvestSource: .none,
            kept: 0,
            dropped: ["Elliot stopped before this run was harvested."]
        )
        #expect(orphaned.workingTreeChanged == nil, "the fixture is the orphan Reconciler writes")

        let fresh = AnalysisRunReport(harvestSource: .artifact, kept: 6)
        let carried = fresh.inheritingSentinel(from: orphaned)

        #expect(
            carried.workingTreeChanged == nil,
            """
            a repeat harvest claimed a sentinel reading it never took. `false` here would say the \
            run left the repository clean, which is a claim about a `git status` that was never \
            run — the collapse #39 introduced the tri-state to prevent
            """
        )
        #expect(carried.workingTreeDiff == nil)
    }

    /// The mirror image, and the one that matters most for the reader: a run
    /// that edited the repository must not become clean by being read again.
    @Test("A run that edited the repository stays marked, diff and all")
    func dirtySentinelAndItsDiffAreCarried() {
        let previous = AnalysisRunReport(
            harvestSource: .none,
            kept: 0,
            workingTreeChanged: true,
            workingTreeDiff: " M Sources/ElliotEngine/AnalysisService.swift"
        )
        let carried = AnalysisRunReport(harvestSource: .artifact, kept: 3)
            .inheritingSentinel(from: previous)

        #expect(carried.workingTreeChanged == true)
        #expect(carried.workingTreeDiff == " M Sources/ElliotEngine/AnalysisService.swift")
    }

    /// `false` is a reading too — checked, and clean — so it is inherited
    /// rather than recomputed for the same reason `true` is.
    @Test("A checked-clean tree stays checked-clean")
    func cleanSentinelIsCarried() {
        let previous = AnalysisRunReport(harvestSource: .artifact, kept: 2, workingTreeChanged: false)
        let carried = AnalysisRunReport(harvestSource: .artifact, kept: 2)
            .inheritingSentinel(from: previous)

        #expect(carried.workingTreeChanged == false)
        #expect(carried.workingTreeDiff == nil)
    }

    /// Criterion 3. Everything the harvest itself answered comes from the fresh
    /// read, and the previous complaints do not survive — a `dropped` that
    /// merged would keep reporting a parse failure that has since been fixed by
    /// hand, which is the situation the whole feature exists for.
    @Test("The harvest's own answer is replaced, never merged")
    func theFreshReadWins() {
        let previous = AnalysisRunReport(
            harvestSource: .none,
            kept: 0,
            dropped: ["No artifact was written at /tmp/x/stories.json.", "and another complaint"],
            workingTreeChanged: false
        )
        let fresh = AnalysisRunReport(
            harvestSource: .artifact, kept: 4, dropped: ["Run had no recorded angle; defaulted to bugs."]
        )
        let carried = fresh.inheritingSentinel(from: previous)

        #expect(carried.harvestSource == .artifact)
        #expect(carried.kept == 4)
        #expect(carried.dropped == ["Run had no recorded angle; defaulted to bugs."])
    }

    /// A report inheriting from nothing is itself. Worth pinning because it is
    /// the shape every other caller of a `from previous:` API eventually hits,
    /// and "nothing to inherit" must not mean "nothing was read".
    @Test("Inheriting from no previous report changes nothing")
    func inheritingFromNilIsIdentity() {
        let fresh = AnalysisRunReport(
            harvestSource: .resultText, kept: 1, dropped: ["one"],
            workingTreeChanged: true, workingTreeDiff: " M a"
        )
        #expect(fresh.inheritingSentinel(from: nil).workingTreeChanged == nil)
        #expect(fresh.inheritingSentinel(from: nil).workingTreeDiff == nil)
        #expect(fresh.inheritingSentinel(from: nil).kept == 1)
        #expect(fresh.inheritingSentinel(from: nil).harvestSource == .resultText)
    }

    // MARK: - Which runs offer the action

    /// Criterion 1's whole condition, so the lens row renders a flag rather
    /// than deciding one.
    @Test("A finished analysis run that kept nothing offers a second harvest")
    func theTwoRecoverableCases() {
        // The Reconciler's orphan: `.failed`, `.none`, nothing kept — and the
        // case with the best chance of a complete artifact on disk.
        #expect(run(
            state: .failed,
            report: AnalysisRunReport(
                harvestSource: .none,
                dropped: ["Elliot stopped before this run was harvested."])
        ).offersReharvest)

        // The parse that kept nothing: the file was there and unusable, or the
        // store refused the write.
        #expect(run(
            state: .succeeded,
            report: AnalysisRunReport(harvestSource: .none, kept: 0, dropped: ["unparseable"])
        ).offersReharvest)

        // And cancelled, which is terminal and can perfectly well have written
        // its file before the SIGTERM arrived.
        #expect(run(
            state: .cancelled, report: AnalysisRunReport(harvestSource: .none)
        ).offersReharvest)
    }

    @Test("Nothing else offers it")
    func theRefusals() {
        #expect(
            !run(state: .succeeded, report: AnalysisRunReport(harvestSource: .artifact, kept: 3))
                .offersReharvest,
            "a harvest that kept something has nothing to recover")
        #expect(
            !run(state: .running, report: AnalysisRunReport(harvestSource: .none)).offersReharvest,
            "a run still in flight will be harvested by completeAnalysisRun")
        #expect(
            !run(state: .stalled, report: AnalysisRunReport(harvestSource: .none)).offersReharvest,
            "stalled is not terminal — the child is still alive")
        #expect(
            !run(state: .succeeded, kind: .implementIssue, report: nil).offersReharvest,
            "a card run has no artifact to read")
        #expect(
            !run(state: .failed, report: nil).offersReharvest,
            """
            a terminal analysis run with no report at all has never been through \
            completeAnalysisRun. `(analysisReport?.kept ?? 0) == 0` answers true here, which is \
            the two-valued answer to a three-valued question
            """)
    }
}
