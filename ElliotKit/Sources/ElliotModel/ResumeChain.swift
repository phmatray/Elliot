import Foundation

/// Walking a run back to the attempt its chain started with.
///
/// Pure: no store, no clock, no I/O. The caller supplies whatever rows it has
/// and this reads `resumedFrom` backwards through them.
public enum ResumeChain {

    /// When the first attempt of `run`'s chain began.
    ///
    /// This is the window every `gh` question about a resumed run has to be
    /// asked over. A resumed run's own `startedAt` is when the *resume* began,
    /// so anything the first attempt did falls outside it — and for
    /// `create-issue` that means the verifier reports nothing created and an
    /// unattended loop files a second issue on github.com. The principle is
    /// already written three files away: *"recency must never be a filter"*
    /// (`PRMatcher.swift:26`).
    ///
    /// `run` is passed separately from `runs` on purpose: the caller usually
    /// holds a fresher copy than the store does, and the walk must start from
    /// the copy that carries this attempt's `resumedFrom`.
    ///
    /// Total, and that is all it is. Both of the ways this stops early return a
    /// moment **later** than the truth — which is the narrow-window direction,
    /// the one that files a second issue. Neither is a safe failure; they are
    /// cases to know about.
    ///
    /// A predecessor absent from `runs` — a page shorter than the chain — stops
    /// the walk at the oldest attempt actually present. It never extrapolates
    /// earlier, because it has no evidence to extrapolate from; the caller that
    /// paginated is the one that can widen.
    ///
    /// A cycle is refused by `seen` rather than followed, so the walk always
    /// terminates in at most `runs.count` hops. ⚠️ It does **not** return the
    /// chronological minimum: measured on a two-node mutual cycle, starting the
    /// same walk from the other node stops on a different attempt and returns a
    /// different, non-minimal moment. Termination is guaranteed; correctness on
    /// corrupt data is not, and `resumedFrom` is written in exactly one place,
    /// so a cycle means something else is already wrong.
    public static func firstAttemptStart(of run: SkillRun, among runs: [SkillRun]) -> Date {
        let byID = Dictionary(runs.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var oldest = run
        var seen: Set<UUID> = [run.id]
        while let previousID = oldest.resumedFrom,
            !seen.contains(previousID),
            let previous = byID[previousID]
        {
            seen.insert(previousID)
            oldest = previous
        }
        return oldest.startedAt ?? oldest.createdAt
    }
}
