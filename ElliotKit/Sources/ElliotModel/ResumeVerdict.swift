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

    /// The ACP-shaped answer to the one question this type asks: **did the fork
    /// find a conversation?**
    ///
    /// Under `claude -p` the answer was a conjunction of four things read off
    /// the terminal event, because the CLI reported a missing session as an
    /// ordinary failed run and only the conjunction named the one failure a
    /// relaunch can fix. Under ACP it is a single fact: `session/fork` either
    /// returned a session or the agent answered it with a JSON-RPC error, and
    /// the runner knows which. Fewer moving parts, same meaning — and
    /// `of(resumedFrom:result:)` above stays for logs written before this build
    /// and for `Reconciler`, which has no terminal event at all.
    ///
    /// ⛔ Takes no `summary`. There is nothing in a turn's outcome that can make
    /// a fork that succeeded into one that did not, or the reverse — the runner
    /// knows, and this reads what it knows. A parameter here that no branch
    /// consults would read as a fact still to be folded in.
    ///
    /// ⚠️ **`sessionResumeFailed` is narrower than "the fork did not work", and
    /// the narrowing is this task's whole subject.** `AgentRun.start` sets it
    /// only for `ClientError.agentError` — the agent *answering* that it will
    /// not fork — and leaves it false for a transport that died, a response that
    /// would not decode, or a handshake that never got that far. Those are
    /// "could not establish", and `.ran` is what this type calls that: the safe
    /// answer, which costs a verification that would have happened anyway.
    /// Reporting `.sessionGone` for them would assert a transcript is missing on
    /// evidence that says only that nobody could ask.
    public static func of(resumedFrom: UUID?, sessionResumeFailed: Bool) -> ResumeVerdict {
        guard resumedFrom != nil, sessionResumeFailed else { return .ran }
        return .sessionGone
    }
}
