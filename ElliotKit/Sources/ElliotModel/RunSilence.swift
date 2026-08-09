import Foundation

/// Which way a live run just crossed the silence line.
///
/// One type rather than two booleans, and one type rather than two unrelated
/// functions, because the two directions are mirrors and the defect this exists
/// to end is precisely that **only one of them was ever written**. The idle
/// watcher marked a run `.stalled` and nothing anywhere could take the mark off
/// again: a `merge-pr` that waited twenty-one minutes on CI and then produced
/// its next tool call kept the attention tint and "No output for a while" until
/// it exited.
///
/// That is not cosmetic. There is deliberately no wall-clock kill — `merge-pr`
/// waiting hours on CI is legitimate — so silence is the *only* signal a wedged
/// run gives, and a mark that never clears makes the signal mean nothing.
///
/// `CaseIterable` so a test can walk both directions rather than name one and
/// hope the other was written too, which is the whole history here.
public enum RunSilence: Sendable, Hashable, CaseIterable {
    /// Nothing has been written for longer than the idle window.
    case wentQuiet
    /// Output arrived again, after a silence that had already been announced.
    case startedTalkingAgain
}

public extension RunState {
    /// The state a run in this state reaches when a silence notice arrives, or
    /// `nil` when the notice does not apply to it.
    ///
    /// **The pair of guards, written once and adjacent**, which is the point:
    /// they were two hand-copied `guard run.state == .running` lines in two
    /// modules — `RunScheduler.markStalled` and `AppModel.stalling` — each
    /// carrying a comment saying it was deliberately spelled the same way as the
    /// other. When the *explanation* of an invariant has been copied word for
    /// word, the invariant has been copied too, and this one had only ever been
    /// copied in one direction.
    ///
    /// ⛔ The resume guard is what stops a late notice resurrecting a run that
    /// has since ended: a `.succeeded` run is not `.stalled`, so it stays
    /// `.succeeded`. The cancellation path is the sharp case, because
    /// `RunScheduler.cancel` writes `.cancelling` over whatever the run was —
    /// so the last byte a stalled run emits on its way out cannot drag it back
    /// to `.running` and hold its card against a further move.
    ///
    /// Exhaustive over `RunSilence` with **no `default`**, so a third direction
    /// is a compile error here rather than a silent `nil`. The `RunState` side
    /// is deliberately an equality test instead: a state added later takes
    /// neither notice, which is the conservative answer and the one both
    /// original guards gave.
    func applying(_ notice: RunSilence) -> RunState? {
        switch notice {
        case .wentQuiet: self == .running ? .stalled : nil
        case .startedTalkingAgain: self == .stalled ? .running : nil
        }
    }
}

public extension SkillRun {
    /// This run with a silence notice applied — unchanged when the notice names
    /// a different run, or when this one is in no state to take it.
    ///
    /// The collection-walk form. `AppModel` holds four copies of the same run
    /// and any of them can be the one on screen, so the notice is applied by id
    /// across all four; `AnalysisSession` owns the fourth. Both call this rather
    /// than either owning the rule, and the rule itself is `RunState.applying`
    /// above — one question, one answer, three call sites.
    func applying(_ notice: RunSilence, ifID runID: UUID) -> SkillRun {
        guard id == runID, let next = state.applying(notice) else { return self }
        var marked = self
        marked.state = next
        return marked
    }
}

/// The idle watcher's whole decision, as a value.
///
/// Pure, and told the time rather than reading it, so `swift test` can drive a
/// silence and a recovery through it without spawning anything, sleeping for
/// anything, or asserting a duration. What used to live here was a `Date` and a
/// `Bool` in two separate boxes inside `ClaudeRun.start`, mutated from two
/// closures: the announce latch was *set* by the watchdog and *cleared* by the
/// output mirror, and because the clearing said nothing to anybody it was
/// invisible from outside the process. Making the latch a value that answers
/// with a `RunSilence?` is what makes the clearing announceable at all.
public struct IdleWatch: Sendable, Hashable {
    /// When the child last wrote something.
    public private(set) var lastOutput: Date

    /// Whether the current silence has already been announced.
    ///
    /// The latch is what makes the two notices strictly alternate — one
    /// `.wentQuiet` per silence and one `.startedTalkingAgain` per silence,
    /// never two of either in a row. Without it the watchdog would repeat "still
    /// quiet" at every poll, and the mirror would announce a recovery on every
    /// byte of a run that had never gone quiet at all.
    public private(set) var announced: Bool

    public init(lastOutput: Date, announced: Bool = false) {
        self.lastOutput = lastOutput
        self.announced = announced
    }

    /// The child wrote something.
    ///
    /// Returns `.startedTalkingAgain` exactly when this is the output that ends
    /// an announced silence, and `nil` for the ordinary case of a run talking
    /// while nobody was worried about it.
    public mutating func sawOutput(at now: Date) -> RunSilence? {
        lastOutput = now
        guard announced else { return nil }
        announced = false
        return .startedTalkingAgain
    }

    /// The watchdog looked.
    ///
    /// Returns `.wentQuiet` on the tick that first crosses `idleTimeout`, and
    /// `nil` on every tick after it until output clears the latch.
    public mutating func tick(now: Date, idleTimeout: Duration) -> RunSilence? {
        guard !announced, now.timeIntervalSince(lastOutput) > Self.seconds(idleTimeout)
        else { return nil }
        announced = true
        return .wentQuiet
    }

    /// A `Duration` in seconds, sub-second component included.
    ///
    /// ⚠️ `components.seconds` on its own truncates, and that is not academic:
    /// a twenty-millisecond window reads as **zero**, so every tick crosses it
    /// and a run is announced stalled the instant it starts. The shipped window
    /// is twenty minutes and could never show it; a test has to use a short one
    /// to reach this code at all, which is exactly where the truncation bites.
    static func seconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds)
            + Double(duration.components.attoseconds) / 1e18
    }
}
