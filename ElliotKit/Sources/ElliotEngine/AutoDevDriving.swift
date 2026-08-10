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
/// A protocol rather than a concrete type, because the loop that conforms to it
/// is the **next** pull request: this one ships the screen. `AppModel` holds one
/// optional conformer exactly as it holds `analysisService`, so with none
/// attached every control returns at its guard and `AppModel.autoDevRefusal`
/// says so in a sentence — the #151 shape, an explanation rather than a control
/// that cannot be switched off.
///
/// ⚠️ **`stop` cancels the run already going; `pause` does not.** That is the
/// whole reason a session cannot lean on the queue's Pause
/// (`RunScheduler.pause`), which holds *queued* runs and leaves the running one
/// alone — and it is why the band's stop control says on its face what it does
/// to that run.
///
/// The three mutating calls hand back the session they produced rather than
/// `Void`, so the board's copy and the loop's cannot come apart while nobody is
/// pushing updates. PR4 may add a push; nothing here forbids one.
///
/// ⚠️ **`nil` from `pause`/`resume`/`stop` is an answer the caller must render,
/// not one it may drop.** It is a *refusal to confirm* — a session the loop does
/// not know, one already over, an actor that would not act — and it deliberately
/// does not say which, because a conformer that guessed would be inventing a
/// cause. `AppModel` therefore reports it rather than returning in silence: a
/// control that cancels an unattended agent and answers nothing at all is this
/// repository's own catalogued failure, *a mechanism that substitutes a
/// different answer instead of erroring*.
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
}
