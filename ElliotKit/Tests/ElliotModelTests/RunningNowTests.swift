import Foundation
import Testing

@testable import ElliotModel

private let epoch = Date(timeIntervalSince1970: 1_700_000_000)

private func run(
    _ state: RunState,
    kind: SkillKind = .implementIssue,
    startedAt: Date? = epoch,
    createdAt: Date = epoch,
    angle: AnalysisAngle? = nil,
    id: UUID = UUID()
) -> SkillRun {
    var run = SkillRun(
        cardID: kind == .analyzeRepo ? nil : UUID(), repoID: UUID(),
        analysisID: kind == .analyzeRepo ? UUID() : nil, analysisAngle: angle,
        kind: kind, prompt: "p", cwd: "/tmp",
        logPath: "/tmp/run.ndjson", stderrPath: "/tmp/run.log", createdAt: createdAt
    )
    run.id = id
    run.state = state
    run.startedAt = startedAt
    return run
}

/// #303: Operations said *"What the machine is doing"* and answered `2 / 2`.
///
/// Everything the band decides is here rather than in the view, for the standing
/// reason: `swift test` cannot see a screen, so a rule left in a `body` is a rule
/// with no test. What is asserted is the selection — which runs, in what order,
/// how many, and what is said about the rest.
@Suite("The runs that are going")
struct RunningNowTests {

    // MARK: - Which runs

    /// The one difference between `isUnderway` and `isActive`, walked over every
    /// state so a case added later has to be classified deliberately rather than
    /// inherit an answer by omission.
    @Test("Underway is active minus queued, for every state there is")
    func underwayIsActiveMinusQueued() {
        for state in RunState.allCases {
            let expected = state.isActive && state != .queued
            #expect(
                state.isUnderway == expected,
                Comment(rawValue: "\(state) answered isUnderway wrongly")
            )
        }
    }

    /// A queued run is already drawn, with the rule holding it, in the Waiting
    /// band. Listing it here too would report one run twice and describe it two
    /// ways — and it would be the description with no elapsed time and nothing to
    /// cancel that a reader met first.
    @Test("A queued run belongs to Waiting, not to Running now")
    func queuedRunsAreNotDrawnHere() {
        let running = RunningNow.of([run(.queued), run(.running)])
        #expect(running.all.count == 1)
        #expect(running.all.first?.state == .running)
    }

    @Test("A finished run is not going, whatever it finished as")
    func terminalRunsAreExcluded() {
        let finished: [RunState] = [.succeeded, .completedWithDenials, .failed, .cancelled, .timedOut]
        #expect(RunningNow.of(finished.map { run($0) }).isEmpty)
    }

    /// Stalled and cancelling are the two states this band exists for: a wedged
    /// run and a run being stopped are exactly what a reader opens Operations to
    /// find, and both are things the machine is still doing.
    @Test("A stalled run and a cancelling one are still going")
    func stalledAndCancellingAreGoing() {
        let running = RunningNow.of([run(.stalled), run(.cancelling)])
        #expect(running.all.count == 2)
    }

    /// The reason the band exists at all: an analysis run has no card, so
    /// `activeRuns` cannot hold it and nothing outside the analysis panel showed
    /// an eight-lens read in flight.
    @Test("An analysis run, which no card can carry, is here")
    func analysisRunsAreCarried() {
        let analysis = run(.running, kind: .analyzeRepo, angle: .bugs)
        #expect(analysis.cardID == nil)
        #expect(RunningNow.of([analysis]).all.count == 1)
    }

    // MARK: - In what order

    @Test("Longest-running first, whatever order they arrive in")
    func longestRunningFirst() {
        let old = run(.running, startedAt: epoch)
        let recent = run(.running, startedAt: epoch.addingTimeInterval(600))
        let middle = run(.stalled, startedAt: epoch.addingTimeInterval(60))

        #expect(RunningNow.of([recent, middle, old]).all.map(\.id) == [old.id, middle.id, recent.id])
        // Same answer from the other input order: the rule is the order, not the
        // arrival.
        #expect(RunningNow.of([old, recent, middle]).all.map(\.id) == [old.id, middle.id, recent.id])
    }

    /// `sorted(by:)` is not stable in Swift, so two runs sharing an instant could
    /// swap places between two renders of the same board. The `id` tie-break is
    /// what makes the order total.
    @Test("Two runs that started in the same instant keep one order")
    func tiesAreBrokenDeterministically() {
        let a = run(.running, id: UUID(uuidString: "00000000-0000-0000-0000-0000000000AA")!)
        let b = run(.running, id: UUID(uuidString: "00000000-0000-0000-0000-0000000000BB")!)
        #expect(RunningNow.of([b, a]).all.map(\.id) == [a.id, b.id])
        #expect(RunningNow.of([a, b]).all.map(\.id) == [a.id, b.id])
    }

    /// Not a sentinel that banishes it to the end: a run underway with no start
    /// recorded is placed by when it was made, which is the nearest true thing
    /// known about it.
    @Test("A run with no start is placed by when it was made")
    func aRunWithNoStartIsPlacedByCreation() {
        let started = run(.running, startedAt: epoch.addingTimeInterval(60))
        let unstarted = run(.stalled, startedAt: nil, createdAt: epoch)
        #expect(RunningNow.of([started, unstarted]).all.map(\.id) == [unstarted.id, started.id])
    }

    // MARK: - How many, and what about the rest

    @Test("The default cap is the most runs the machine can ever have going")
    func defaultCapIsTheSchedulerCeiling() {
        #expect(RunningNow.of([]).limit == SchedulerLimits.ceiling)
    }

    /// One `TimelineView(.periodic(by: 1))` per row is main-actor work
    /// proportional to the count, and `recentRuns` holds fifty.
    @Test("Past the cap the rows stop")
    func rowsStopAtTheCap() {
        let runs = (0..<20).map { run(.running, startedAt: epoch.addingTimeInterval(Double($0))) }
        let running = RunningNow.of(runs, limit: 12)
        #expect(running.all.count == 20)
        #expect(running.shown.count == 12)
        // The twelve *oldest*, which is what "longest-running first" is for.
        #expect(running.shown.map(\.id) == runs.prefix(12).map(\.id))
    }

    /// ⛔ The claim this whole type exists for. A band that rendered `prefix(12)`
    /// and said nothing about the thirteenth would read as "that is everything"
    /// while a run nobody can see holds a card — the `unknownCost` lesson, with
    /// work in flight in place of money.
    @Test("What the cap dropped is counted and said, never silently gone")
    func theRemainderIsStated() {
        let runs = (0..<15).map { run(.running, startedAt: epoch.addingTimeInterval(Double($0))) }
        let running = RunningNow.of(runs, limit: 12)
        #expect(running.hidden == 3)
        #expect(running.note == "3 more runs are going and are not listed.")
    }

    @Test("One hidden run is one run, not \"1 runs\"")
    func oneHiddenRunIsSingular() {
        let runs = (0..<13).map { run(.running, startedAt: epoch.addingTimeInterval(Double($0))) }
        #expect(RunningNow.of(runs, limit: 12).note == "1 more run is going and is not listed.")
    }

    @Test("A band that drew everything says nothing about a remainder")
    func nothingHiddenSaysNothing() {
        let running = RunningNow.of([run(.running), run(.stalled)], limit: 12)
        #expect(running.hidden == 0)
        #expect(running.note == nil)
    }

    // MARK: - What the day's spend cannot have counted

    /// The count is of everything in flight, **not** of what fitted on screen:
    /// `BoardStore.spend` keys on `endedAt`, so the runs it cannot have counted
    /// are all of them, cap or no cap.
    @Test("The per-kind count covers the runs past the cap too")
    func countByKindIgnoresTheCap() {
        let analyses = (0..<8).map {
            run(.running, kind: .analyzeRepo, startedAt: epoch.addingTimeInterval(Double($0)))
        }
        let writer = run(.running, kind: .implementIssue, startedAt: epoch.addingTimeInterval(99))
        let running = RunningNow.of(analyses + [writer], limit: 3)

        #expect(running.shown.count == 3)
        #expect(running.countByKind[.analyzeRepo] == 8)
        #expect(running.countByKind[.implementIssue] == 1)
        // A kind with nothing going is absent rather than zero — the caller
        // reads it as "no runs of this kind", which is what absent means.
        #expect(running.countByKind[.mergePR] == nil)
    }

    @Test("A queued run costs nothing yet, so it is not counted as in flight")
    func queuedRunsAreNotInFlight() {
        let running = RunningNow.of([run(.queued, kind: .mergePR), run(.running, kind: .mergePR)])
        #expect(running.countByKind[.mergePR] == 1)
    }

    // MARK: - What a row says it is about

    /// Eight lenses of one analysis are eight runs of the same kind in the same
    /// repository. Without the lens the band draws eight identical rows and reads
    /// as a rendering bug — the mistake `OperationsView.FailingCheck` records one
    /// band up, having been seen on screen before it shipped.
    @Test("An analysis row names its lens, so eight of them are not eight of the same row")
    func anAnalysisRowNamesItsLens() {
        let bugs = run(.running, kind: .analyzeRepo, angle: .bugs)
        let tests = run(.running, kind: .analyzeRepo, angle: .tests)
        #expect(bugs.context(repoName: "Elliot") == "Elliot · Bugs")
        #expect(tests.context(repoName: "Elliot") == "Elliot · Tests")
    }

    @Test("A card run names only its repository")
    func aCardRowNamesItsRepository() {
        #expect(run(.running).context(repoName: "Elliot") == "Elliot")
    }

    @Test("With nothing known the row draws no chip rather than an empty one")
    func nothingKnownIsNil() {
        #expect(run(.running).context(repoName: nil) == nil)
        // A repository that has been forgotten still leaves the lens worth
        // saying, which is the half that tells two rows apart.
        #expect(run(.running, kind: .analyzeRepo, angle: .bugs).context(repoName: nil) == "Bugs")
    }
}
