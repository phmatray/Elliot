import ElliotModel
import Foundation

/// Reading the page a resumed run's create-issue window is anchored on.
///
/// One place rather than one per caller: `RunScheduler` and `Reconciler` both
/// feed `Verifier.verify`, they need the same distinction, and it is exactly
/// the distinction that is easy to lose. Two copies of it would be two chances
/// to write `?? []` back.
enum ResumeWindow {

    /// The page, or `nil` when it could not be read **and** that changes the
    /// answer.
    ///
    /// ⛔ Never `(try? await store.runs(cardID:)) ?? []`. An empty page and an
    /// unreadable one are the same value and opposite facts, and the fact that
    /// collapse hides is the whole subject of this file:
    /// `ResumeChain.firstAttemptStart` over `[]` returns the resumed run's
    /// *own* start, which is the pre-fix window. A transient store failure
    /// would therefore restore the defect — no log line, no `lastError`,
    /// `isError: false` — and file a second issue on github.com. The rule is
    /// already written down for this very table: *"No protected set, no sweep …
    /// A failure to read the board is a reason not to touch the disk"*
    /// (`CLAUDE.md`, *Artefact retention*).
    ///
    /// ⚠️ It refuses **narrowly**, and the narrowness is the point. A run that
    /// never resumed carries `resumedFrom == nil`, and `firstAttemptStart`
    /// never enters its walk for such a run — it builds the dictionary and
    /// never reads it — so an unreadable page there is *irrelevant* rather than
    /// wrong. Refusing uniformly would cost every ordinary run its verification
    /// on any transient failure: a larger harm, in the far commoner case, than
    /// the one being closed.
    ///
    /// The read is a parameter rather than a `BoardStore`, so the refusal can
    /// be asserted. There is no seam through which a real store read can be
    /// made to fail — `RunScheduler` and `Reconciler` take a concrete
    /// `BoardStore` — and a rule nothing can re-run is a rule that drifts.
    ///
    /// `@Sendable` because one caller is an actor: without it the closure is
    /// `self`-isolated and cannot be handed to a nonisolated function. Both
    /// call sites capture only `BoardStore` (a `Sendable` final class) and a
    /// `UUID`, so nothing actor-isolated crosses.
    static func page(
        resumedFrom: UUID?, reading read: @Sendable () async throws -> [SkillRun]
    ) async -> [SkillRun]? {
        if let page = try? await read() { return page }
        return unreadable(resumedFrom: resumedFrom)
    }

    /// What an unreadable page amounts to, as a rule rather than a `try?`.
    static func unreadable(resumedFrom: UUID?) -> [SkillRun]? {
        resumedFrom == nil ? [] : nil
    }

    /// Why a resumed run whose page could not be read is not verified at all.
    ///
    /// `.unverified(reason:)` and not `nil`: `CardOutcome.applied` routes this
    /// to `lastError`, writes no other field and implies no move, so the card
    /// says the window is unknown. Returning nothing would be the silence this
    /// whole type exists to end, wearing a different coat.
    static let unknownWindowReason =
        "Could not read this card's earlier runs, so the window this resumed run would have to be "
        + "verified over is unknown."
}
