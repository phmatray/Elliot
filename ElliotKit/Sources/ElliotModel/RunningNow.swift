import Foundation

/// What the machine is doing right now, and what a band drawing it would leave
/// out.
///
/// Operations promised *"What the machine is doing"* and answered with `2 / 2`.
/// The runs themselves were already loaded, already stall-marked and already
/// documented as feeding the overview — the reader was missing, not the data
/// (#303). They are also the **only** collection carrying an analysis run, since
/// `activeRuns` is keyed by card id and an analysis has no card: an eight-lens
/// read could be in flight with nothing outside the analysis panel showing it.
///
/// ⛔ **The cap and the remainder are one value, and that is the whole point of
/// the type.** A band that took `[SkillRun]` would render `prefix(12)` and say
/// nothing about the thirteenth, which is this codebase's oldest defect wearing
/// a new hat: `Spend` carries `unknownCost` and `SpendFigure` carries `inFlight`
/// for exactly this reason — *a figure that quietly under-reports is worse than
/// no figure*. Here the under-report would be of work in flight rather than of
/// money, and it would read as "that is everything" while a run nobody can see
/// holds a card.
///
/// Pure: no clock, no store, no view. The band renders what this decides.
public struct RunningNow: Sendable, Equatable {

    /// Every run underway, longest-running first — **including** the ones past
    /// the cap. `shown` applies the cap; `hidden` counts what it dropped.
    public private(set) var all: [SkillRun]

    /// How many rows a band may draw.
    ///
    /// One `TimelineView(.periodic(by: 1))` per row is main-actor work
    /// proportional to the count, so the fifty runs `recentRuns` holds are not a
    /// list to render. `SchedulerLimits.ceiling` is the number of runs the
    /// machine can ever have going at once, so at the default it is not a
    /// truncation at all — it is the point past which the list stops being a
    /// reading of the present.
    public private(set) var limit: Int

    /// Sorts and clamps, so no caller can build one that is out of order.
    public init(all: [SkillRun], limit: Int = SchedulerLimits.ceiling) {
        self.all = all.sorted(by: Self.longestFirst)
        self.limit = max(0, limit)
    }

    /// The runs underway, out of whatever collection the caller has.
    ///
    /// Takes every run rather than a pre-filtered list because the filter *is*
    /// the rule — see `RunState.isUnderway`, which is where a queued run is kept
    /// out of a band that says things are going.
    public static func of(_ runs: [SkillRun], limit: Int = SchedulerLimits.ceiling) -> RunningNow {
        RunningNow(all: runs.filter { $0.state.isUnderway }, limit: limit)
    }

    /// Longest-running first.
    ///
    /// Not `recentRuns`' own order, which is `createdAt` descending — that is an
    /// order for a *log*, and it puts the run most worth looking at last. When
    /// the cap bites, dropping a run that started a moment ago costs a reader
    /// far less than hiding the one that has been going four hours, which is the
    /// only kind this band exists to catch.
    ///
    /// `startedAt ?? createdAt` rather than a sentinel: a run underway normally
    /// has a start, and one that somehow has not is placed by when it was made
    /// rather than banished to the end. The `id` tie-break makes the order
    /// **total** — `sorted(by:)` is not a stable sort in Swift, so without it
    /// two runs sharing an instant could swap places between two renders.
    private static func longestFirst(_ a: SkillRun, _ b: SkillRun) -> Bool {
        let first = a.startedAt ?? a.createdAt
        let second = b.startedAt ?? b.createdAt
        if first != second { return first < second }
        return a.id.uuidString < b.id.uuidString
    }

    /// The rows to draw.
    public var shown: [SkillRun] { Array(all.prefix(limit)) }

    /// How many are going and are not drawn.
    public var hidden: Int { max(0, all.count - limit) }

    public var isEmpty: Bool { all.isEmpty }

    /// What the band says about the runs it did not draw, and `nil` when it drew
    /// them all.
    ///
    /// A sentence rather than a number so the band does not invent a second
    /// wording, the reason `Spend.sentence` is written the same way.
    public var note: String? {
        guard hidden > 0 else { return nil }
        return hidden == 1
            ? "1 more run is going and is not listed."
            : "\(hidden) more runs are going and are not listed."
    }

    /// How many runs of each kind are underway — **all** of them, cap or no cap.
    ///
    /// This is what the day's spend cannot have counted yet: `BoardStore.spend`
    /// keys on `endedAt`, so a run still going contributes nothing. The count
    /// therefore has to be of everything in flight and not of what happened to
    /// fit on screen, which is the one place `shown` would be the wrong input.
    public var countByKind: [SkillKind: Int] {
        all.reduce(into: [:]) { counts, run in counts[run.kind, default: 0] += 1 }
    }
}

public extension SkillRun {
    /// What this run is about, in one line: the repository, and the lens when
    /// there is one.
    ///
    /// The lens is not decoration. Eight lenses of one analysis are eight runs of
    /// the same kind in the same repository, so without it a band draws eight
    /// identical rows and reads as a rendering bug rather than as an analysis —
    /// which is the mistake `OperationsView.FailingCheck` records one band up,
    /// having been seen on screen before it shipped.
    ///
    /// `nil` when nothing is known, so a caller draws nothing rather than an
    /// empty chip.
    func context(repoName: String?) -> String? {
        let parts = [repoName, analysisAngle?.title].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}
