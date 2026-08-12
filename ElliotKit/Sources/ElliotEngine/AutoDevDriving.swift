import ElliotModel
import Foundation

/// How a session's cards are chosen.
///
/// The automatic half is what makes "optional automatic selection of the
/// highest-value cards" optional: a caller that has already decided passes
/// ``explicit(_:)``, and the ranking never runs.
///
/// ⛔ **The choice lives behind ``AutoDevDriving`` rather than in the caller**,
/// so that no caller can hand the loop a badly chosen set, and so a future MCP
/// start tool inherits the rule instead of re-deriving it. It is also why
/// ``AutoDevDriving/start(repoID:selection:)`` takes this rather than a bare
/// count: a count is not a choice, and `AppModel` passing one read as though the
/// loop owned the choice while the loop read as though the board did.
public enum AutoDevSelection: Sendable, Hashable {
    /// Rank the repository's Backlog and engage at most `limit` of the cards
    /// that are rankable. Cards nothing has measured are **refused and named**,
    /// never sorted to the bottom — see `CardRanking.rank` (PR2).
    case automatic(limit: Int)
    /// Engage exactly these, in this order.
    case explicit([UUID])
}

/// What the board's auto-dev controls reach.
///
/// A protocol rather than a concrete type, so the board depends on the *surface*
/// and not on the loop: `AutoDevService` conforms, and `AppModel` holds one
/// optional conformer exactly as it holds `analysisService`. The optionality is
/// not vestigial — the driver is attached only after the launch sweep returns
/// (`AppModel.start()`, gated by `AutoDevLaunchOrderShapeTests`), so there is a
/// real window on every launch with none attached, during which every control
/// returns at its guard and `AppModel.autoDevRefusal` says so in a sentence:
/// the #151 shape, an explanation rather than a control that cannot be switched
/// off.
///
/// ⚠️ **`stop` cancels the run already going; `pause` does not.** That is the
/// whole reason a session cannot lean on the queue's Pause
/// (`RunScheduler.pause`), which holds *queued* runs and leaves the running one
/// alone — and it is why the band's stop control says on its face what it does
/// to that run.
///
/// The three mutating calls hand back the session they produced rather than
/// `Void`, so the board's copy and the loop's cannot come apart while nobody is
/// pushing updates. Nothing here forbids adding a push later.
///
/// ⚠️ **`nil` from `pause`/`resume`/`stop` is an answer the caller must render,
/// not one it may drop.** It is a *refusal to confirm* — a session the loop does
/// not know, an actor that would not act — and it deliberately does not say
/// which, because a conformer that guessed would be inventing a cause.
/// `AppModel` therefore reports it rather than returning in silence: a control
/// that cancels an unattended agent and answers nothing at all is this
/// repository's own catalogued failure, *a mechanism that substitutes a
/// different answer instead of erroring*.
///
/// ⛔ **Two obligations on a conformer.** Both are discharged today; both are
/// written here rather than in the implementation, because they bind the *next*
/// conformer just as much, and each was once a dead end for the reader with no
/// remedy wired. There was no read for the *session* — only for its rows — so
/// the board held whatever a call last handed it and could not discover a change
/// by itself. `AppModel.refreshAutoDev` re-read the **rows** and re-adopted them
/// onto the session the board already had, which could never notice that
/// session's own `state` had moved on; and ⚠️ **nothing called it**, so it was a
/// poll-shaped seam with no caller. Meanwhile `AppModel.autoDevRefusal` answers
/// *"A session is already going. Stop it before starting another."* for any
/// state that is not `.finished`. Therefore:
///
/// 1. **A loop that reaches its own end must make that observable.** Left to
///    itself the board shows `.running` for ever and refuses every new session
///    for the rest of the launch. ``session(sessionID:)`` below is the read that
///    discharges it, plus a poll in `AppModel.start()` that calls
///    `refreshAutoDev()` on a timer, unconditionally, not scoped to any window:
///    the whole point of an unattended session is that nobody may be looking at
///    Operations while it runs, and the refusal that gates a *new* session has
///    to see the old one end whether or not anyone opens that screen.
/// 2. **`stop` must return the finished session, including when the session was
///    already finished.** Answering `nil` there is a reasonable-*looking*
///    implementation and it is the trap: the reader is told *"Auto-dev did not
///    stop: the loop gave no session back"*, the board keeps a `.running`
///    session that is over, and **no further session can be started this
///    launch**. `nil` means "I can confirm nothing about this id", never "there
///    was nothing left to do".
public protocol AutoDevDriving: Sendable {
    /// Engages the Backlog cards `selection` names and starts driving them.
    /// The engaged list is closed here and never grows.
    func start(repoID: UUID, selection: AutoDevSelection) async throws -> AutoDevSession

    /// Engages no further move. The run already going finishes.
    func pause(sessionID: UUID) async -> AutoDevSession?

    func resume(sessionID: UUID) async -> AutoDevSession?

    /// Ends the session **and cancels the run already going**. Abandoning a card
    /// and cancelling its run are not the same act, and only the second frees
    /// the card.
    func stop(sessionID: UUID) async -> AutoDevSession?

    /// The session's per-card rows, as the report renders them.
    func engagements(sessionID: UUID) async -> [AutoDevEngagement]

    /// The session itself, exactly as persisted — obligation 1's remedy.
    ///
    /// A pure read: it neither starts, stops nor advances anything, so it is
    /// safe to call on a timer. `AppModel.refreshAutoDev` uses it to notice a
    /// session that settled *itself* — every card merged or blocked, with
    /// nobody pressing Pause, Resume or Stop — which is the one transition none
    /// of the four calls above can ever report, because none of them fires for
    /// it. `nil` means the same as everywhere else on this protocol: this id is
    /// not one the conformer can confirm anything about.
    func session(sessionID: UUID) async -> AutoDevSession?
}
