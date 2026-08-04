import ElliotModel
import ElliotProcess
import ElliotStore
import Foundation

/// Puts the board back in touch with reality after Elliot was not running.
///
/// Quitting the app kills its child processes, and both long skills are
/// resume-safe, so the honest thing on launch is to admit which runs died and
/// re-derive every card's state from `gh` rather than trust what was recorded.
public struct Reconciler: Sendable {
    private let store: BoardStore
    private let verifier: Verifier
    private let mover: any SystemMoving
    private let launcher: any RunLaunching

    public init(
        store: BoardStore,
        verifier: Verifier,
        mover: any SystemMoving,
        launcher: any RunLaunching
    ) {
        self.store = store
        self.verifier = verifier
        self.mover = mover
        self.launcher = launcher
    }

    public struct Summary: Sendable, Equatable {
        public var orphanedRuns = 0
        public var requeuedRuns = 0
        public var cardsCorrected = 0
    }

    @discardableResult
    public func sweep() async -> Summary {
        var summary = Summary()

        for run in (try? await store.nonTerminalRuns()) ?? [] {
            switch run.state {
            case .queued:
                // Committed but never launched — the crash window between the
                // transaction and the hand-off to the scheduler.
                summary.requeuedRuns += 1
                await launcher.launch(runID: run.id)

            case .running, .cancelling, .stalled:
                // The child died with the app. Say so, then find out what it
                // actually managed to do.
                var orphan = run
                orphan.state = .failed
                orphan.endedAt = Date()
                orphan.resultText = "Elliot stopped while this run was in flight."

                if let card = try? await store.card(id: run.cardID),
                   let repo = try? await store.repo(id: run.repoID) {
                    let outcome = await verifier.verify(run: orphan, card: card, repo: repo)
                    orphan.verifiedOutcome = outcome
                    if await apply(outcome, to: card) { summary.cardsCorrected += 1 }
                }
                try? await store.saveRun(orphan)
                summary.orphanedRuns += 1

            default:
                break
            }
        }
        return summary
    }

    /// Writes a verified outcome onto a card, moving it if reality has moved on.
    private func apply(_ outcome: VerifiedOutcome, to card: Card) async -> Bool {
        var updated = card
        var move: (ElliotModel.Column, MoveOrigin.SystemReason)?

        switch outcome {
        case .issueCreated(let number, let url):
            guard card.issueNumber != number else { return false }
            updated.issueNumber = number
            updated.issueURL = url

        case .prOpen(let number, let url, let isDraft, let branch):
            updated.prNumber = number
            updated.prURL = url
            updated.branch = branch
            if !isDraft, card.column == .inProgress {
                move = (.inReview, .reconciliation)
            }

        case .merged:
            if card.column != .done { move = (.done, .reconciliation) }

        case .noIssueCreated(let reason), .notMerged(let reason), .unverified(let reason):
            guard card.lastError != reason else { return false }
            updated.lastError = reason

        case .closedUnmerged:
            updated.lastError = "The pull request was closed without being merged."
        }

        try? await store.saveCard(updated)
        if let (column, reason) = move {
            await mover.applySystemMove(cardID: card.id, to: column, reason: reason)
        }
        return true
    }
}
