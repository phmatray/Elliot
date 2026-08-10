import Foundation

/// What a forked run's terminal event says about the session it tried to
/// resume.
///
/// Two cases, and only two, because this answers one question: did the fork
/// find a conversation? **It decides nothing about what happens next.** Who
/// relaunches, how many times and under what bound belongs to `AutoDevPolicy`;
/// a refused fork costs nothing and returns instantly, so "relaunch, without
/// spending an attempt" written here would be an unbounded spin.
public enum ResumeVerdict: Sendable, Hashable {
    /// The transcript this run was pointed at is not there. Nothing was
    /// attempted, so the run's closing prose is about the CLI, not about the
    /// work.
    case sessionGone
    /// Everything else, including "we do not know". The safe answer: it costs
    /// a verification that would have happened anyway.
    case ran

    /// The CLI's own subtype for a run that failed before its first turn.
    public static let sessionGoneSubtype = "error_during_execution"
    /// The CLI's own wording. Matched as a prefix because the session id
    /// follows it.
    public static let sessionGonePrefix = "No conversation found"

    /// The full predicate, and deliberately not `numTurns` alone.
    ///
    /// Zero turns is the *shape* of several different failures — a credit
    /// balance, a max-turns ceiling, a local slash command that bypassed the
    /// model loop. Only the conjunction of all five names the one failure a
    /// relaunch can fix.
    public static func of(resumedFrom: UUID?, result: RunResult?) -> ResumeVerdict {
        guard resumedFrom != nil, let result else { return .ran }
        guard result.isError,
              result.numTurns == 0,
              result.subtype == Self.sessionGoneSubtype,
              result.errors.contains(where: { $0.hasPrefix(Self.sessionGonePrefix) })
        else { return .ran }
        return .sessionGone
    }
}
