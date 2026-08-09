import Foundation

/// Everything a verified outcome does to a card, in one value.
///
/// `Verifier` decides *what happened* by reading `gh --json`, once. This is the
/// other half — what that fact means for the card — and it is also decided
/// once, here, because it used to be decided three times: `RunScheduler`,
/// `Reconciler` and `PRWatcher` each carried their own switch, and the three
/// had already drifted apart on whether a success clears `lastError`.
///
/// The card and the move travel together deliberately. A caller that can save
/// the fields and forget the move — or the reverse — is exactly the bug this
/// type exists to make unwritable.
public struct CardOutcome: Sendable, Equatable {

    /// The move the outcome implies. This *names* a move; it does not perform
    /// one. `BoardService.applySystemMove` is still the only thing that changes
    /// a card's column.
    public struct Move: Sendable, Equatable {
        public var column: Column
        public var reason: MoveOrigin.SystemReason

        public init(column: Column, reason: MoveOrigin.SystemReason) {
            self.column = column
            self.reason = reason
        }
    }

    /// The card as it should now be saved.
    public var card: Card
    /// The move the outcome implies, if any.
    public var move: Move?
    /// Whether anything is actually different. `false` means the caller may
    /// skip the save entirely rather than write back an identical row.
    public var changed: Bool

    public init(card: Card, move: Move? = nil, changed: Bool) {
        self.card = card
        self.move = move
        self.changed = changed
    }
}

public extension VerifiedOutcome {

    /// Which family of `SystemReason` a move records — the only thing that
    /// legitimately differs between the three callers.
    ///
    /// It is a parameter rather than three switches that happen to differ
    /// because the difference is *true*: one is the board watching the world
    /// move, the other is the board catching up after not running. It is
    /// persisted in `MoveAudit` and rendered from there, so collapsing the two
    /// would quietly rewrite history rather than simplify code.
    enum Attribution: Sendable, Hashable {
        /// The world moved while Elliot was watching: `.prBecameReady` /
        /// `.prMergedExternally`.
        case live
        /// Elliot is catching up after not running: `.reconciliation`.
        case launchSweep

        /// The reason to record, given what this move would be called had
        /// Elliot been watching it happen.
        func reason(whenLive live: MoveOrigin.SystemReason) -> MoveOrigin.SystemReason {
            switch self {
            case .live: live
            case .launchSweep: .reconciliation
            }
        }
    }

    /// What this outcome does to `card`: the fields it writes, the error it
    /// sets or clears, and the move it implies.
    ///
    /// Pure — no clock, no I/O. `updatedAt` in particular is left alone, since
    /// `BoardStore.saveCard` stamps it; touching it here would make every
    /// outcome look like a change and defeat `changed`.
    func applied(to card: Card, attribution: Attribution = .live) -> CardOutcome {
        var updated = card
        var move: CardOutcome.Move?

        switch self {
        case .issueCreated(let number, let url):
            updated.issueNumber = number
            updated.issueURL = url
            updated.lastError = nil

        case .noIssueCreated(let reason):
            updated.lastError = reason

        case .prOpen(let number, let url, let isDraft, let branch):
            updated.prNumber = number
            updated.prURL = url
            updated.branch = branch
            // Clearing on a draft is correct: the draft's existence is what
            // disproves whatever error the run left behind.
            updated.lastError = nil
            // implement-issue flips the PR ready as its last act, so this is
            // usually already true by the time the run exits.
            if !isDraft, card.column == .inProgress {
                move = .init(column: .inReview, reason: attribution.reason(whenLive: .prBecameReady))
            }

        // A card whose pull request merged while Elliot was closed never sees a
        // `.prOpen`, so this is the only place it can learn which pull request
        // finished it. Each field is guarded, because an outcome that reached
        // here through `GHMergeStatus` has no number or branch to offer and a
        // blind write would blank the ones the card already had.
        case .merged(_, let number, let url, let branch):
            if let number { updated.prNumber = number }
            if let url { updated.prURL = url }
            if let branch { updated.branch = branch }
            updated.lastError = nil
            if card.column != .done {
                move = .init(column: .done, reason: attribution.reason(whenLive: .prMergedExternally))
            }

        case .notMerged(let reason), .unverified(let reason):
            updated.lastError = reason

        case .closedUnmerged(let number, let url, let branch):
            if let number { updated.prNumber = number }
            if let url { updated.prURL = url }
            if let branch { updated.branch = branch }
            // The only copy of this sentence in the package, and the only one
            // of these strings a user actually reads.
            updated.lastError = "The pull request was closed without being merged."
        }

        return CardOutcome(
            card: updated,
            move: move,
            // `Card` is `Hashable`, so this is a total comparison — including
            // over fields added later, which a hand-written per-case guard has
            // to be remembered for and this does not.
            changed: updated != card || move != nil
        )
    }
}
