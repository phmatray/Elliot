import Foundation

/// A lens that cannot be started again yet, and how far along the run holding
/// it is.
///
/// ⛔ **Two cases rather than a `Date?`.** "Accepted by the scheduler but not
/// yet spawned" and "reading since 14:02" are different sentences, and only the
/// second has an elapsed time to show. An optional date would let a caller
/// spell the one state that cannot exist — a run that is reading since nothing
/// — and the tile would then have to decide what to draw for it, which is a
/// decision no view should be handed.
public enum LensBusy: Sendable, Equatable, Hashable {
    /// Queued, not yet spawned. There is no stopwatch to show because nothing
    /// has begun.
    case queued
    case reading(since: Date)

    /// When the run began, for the one case that has begun.
    public var since: Date? {
        switch self {
        case .queued: nil
        case .reading(let since): since
        }
    }
}

/// Which lenses are already reading a repository — a **snapshot**, and the
/// repository it was taken of.
///
/// ⚠️ **A hint, never the fact.** `AnalysisService.start` re-reads the same
/// rows inside its actor and throws `angleAlreadyRunning`; a run can begin in
/// the gap between this reading and the press. That is the
/// board's own rule — `gh` is the fact, the agent's prose is a hint — one layer
/// in, and it is why nothing here disables a control. It says what was true
/// when it was read; the service says what is true when you act.
///
/// ⛔ **The repository travels with the answer, and every question names one.**
/// The panel's subject can move while a read is in flight — that is #213 on the
/// header and `AppModel.startFailure` on the footer's sentence, the same axis
/// twice — so a bare `Set<AnalysisAngle>` is a value that can be drawn against a
/// repository it was never read for, with nothing on screen saying so. Ask with
/// the repository you are about to draw, and a mismatched snapshot answers with
/// nothing rather than with somebody else's lenses.
public struct BusyLenses: Sendable, Equatable {
    /// The repository these lenses were read for. Identity, so it is a `let`.
    public let repoID: UUID

    /// Deliberately private: the key set *is* the busy set and the values are
    /// how far along each one is, so there is no pair of members that could
    /// disagree — and no way to read the map without naming a repository.
    private let lenses: [AnalysisAngle: LensBusy]

    /// The rule: a lens is busy when a run that belongs to an analysis, names
    /// that lens, and has not reached a terminal state is holding it.
    ///
    /// Pure, and it takes runs rather than a store, so what counts as "still
    /// reading" is one decision testable without a database. `runs` is filtered
    /// here rather than trusted from the caller — a query that widens later
    /// must not silently widen this.
    public init(repoID: UUID, runs: [SkillRun]) {
        var lenses: [AnalysisAngle: LensBusy] = [:]
        for run in runs where run.analysisID != nil && !run.state.isTerminal {
            guard let angle = run.analysisAngle else { continue }
            let busy: LensBusy = run.startedAt.map { .reading(since: $0) } ?? .queued
            lenses[angle] = Self.earlier(lenses[angle], busy)
        }
        self.init(repoID: repoID, lenses: lenses)
    }

    /// Direct construction, for tests and for a caller that already holds the
    /// map. The rule above is the one production path.
    public init(repoID: UUID, lenses: [AnalysisAngle: LensBusy]) {
        self.repoID = repoID
        self.lenses = lenses
    }

    /// Two active runs for one lens is precisely what the service refuses, so
    /// this never fires in a healthy store — which is why it must not be a
    /// crash or an arbitrary last-one-wins. A run that has *started* outranks
    /// one that is queued, and the earlier start outranks the later: the reader
    /// is being told how long they have been waiting, and the honest answer to
    /// that is the longest one.
    private static func earlier(_ existing: LensBusy?, _ candidate: LensBusy) -> LensBusy {
        guard let existing else { return candidate }
        switch (existing.since, candidate.since) {
        case (nil, _): return candidate
        case (_, nil): return existing
        case (let a?, let b?): return a <= b ? existing : candidate
        }
    }

    /// How far along the run holding `angle` is, or `nil` when that lens is
    /// free — and `nil` for every lens when asked about a repository this
    /// snapshot was not read for.
    public func state(of angle: AnalysisAngle, in repoID: UUID?) -> LensBusy? {
        guard repoID == self.repoID else { return nil }
        return lenses[angle]
    }

    /// Which of `armed` this snapshot says cannot start, **in the order the
    /// caller listed them**.
    ///
    /// The order is the caller's on purpose: the panel arms lenses in the
    /// strip's own order and names them in a sentence, and `AnalysisService`
    /// throws about the first clash it meets in the order it was asked. One
    /// method, one ordering rule — a second one would be a second answer to
    /// "which clashing lens comes first".
    public func clashes(with armed: [AnalysisAngle], in repoID: UUID?) -> [AnalysisAngle] {
        guard repoID == self.repoID else { return [] }
        return armed.filter { lenses[$0] != nil }
    }
}
