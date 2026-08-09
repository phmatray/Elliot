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
    /// Total. A predecessor absent from `runs` — a page shorter than the chain
    /// — stops the walk, and a cycle is refused by `seen` rather than followed.
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
