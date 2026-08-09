import Foundation

public extension ResolvedPRStatus {
    /// Whether an agent with nobody behind it may merge this.
    ///
    /// **Stricter than `sign == nil`, deliberately.** `sign` answers "is there
    /// one thing worth drawing on a card", and it was measured too weak for
    /// merge authority in two ways:
    ///
    /// 1. `PRStatus.sign` blocks `.conflict`, `.blocked` and `.behind`, so
    ///    `MergeState.unstable` reaches `return nil` — the state
    ///    `PRStatusBlock` paints in `Palette.attention` and calls *mergeable,
    ///    not every check is green*. Hence `merge == .clean`.
    /// 2. `StatusCheck.isNonVerdict` filters `SKIPPED|NEUTRAL|STALE` and
    ///    nothing else, so a pull request whose only green is a hosted analyser
    ///    is `.passing`. Hence `ci.hasBuildVerdict`, which reads
    ///    `NonBuildChecks`.
    ///
    /// `isStale` is asked first and separately: a reading that aged out, or is
    /// about a commit that is no longer the head, resolves to `sign: .unknown`
    /// today — but that is a consequence of `resolved(now:currentHeadOid:)`
    /// rather than a fact this predicate is entitled to lean on, and a merge is
    /// the one decision where "I do not know" must not read as "nothing to
    /// report".
    ///
    /// ⚠️ To downgrade this to the design's **Option B**, delete
    /// `&& ci.hasBuildVerdict` and delete `NonBuildChecks.swift` with the
    /// `CIState.passing([String])` change it depends on. Option B closes the
    /// `unstable` hole and leaves the analyser one open, and nothing else in the
    /// board reads either.
    ///
    /// One property on one type, read from one place: `evaluateMove`'s
    /// `(.inReview, .done)` branch. Changing what counts as green is changing
    /// this expression and nothing else.
    var isMergeableUnattended: Bool {
        !isStale && sign == nil && merge == .clean && ci.hasBuildVerdict
    }
}
