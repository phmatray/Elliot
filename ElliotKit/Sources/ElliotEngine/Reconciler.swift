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

        public init() {}
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
                // Elliot's own words about a child that died with it. The agent
                // never got to say anything, which is precisely the point of
                // the sentence — so it must not be dressed as its prose (#288).
                orphan.setClosing(.elliot("Elliot stopped while this run was in flight."))

                if run.kind.isReadOnly {
                    // The artifact may well have been written before the app
                    // died, but the sentinel baseline died with it — say so
                    // rather than claim the tree was clean.
                    //
                    // `kind.isReadOnly` and not `isAnalysis`: an appraisal run
                    // carries a `cardID`, so the boolean sent it down the other
                    // branch, where `Verifier` answered `.unverified` and
                    // `CardOutcome.applied` wrote that sentence into
                    // `card.lastError` — an error banner about a pull request
                    // the card has never had.
                    orphan.analysisReport = AnalysisRunReport(
                        harvestSource: .none,
                        dropped: ["Elliot stopped before this run was harvested."]
                    )
                } else if let cardID = run.cardID,
                          let card = try? await store.card(id: cardID),
                          let repo = try? await store.repo(id: run.repoID) {
                    // The same rule as `RunScheduler.completeCardRun`, through
                    // the same code. The shape differs only in what happens on
                    // a refusal: this method returns nothing, so the refusal is
                    // recorded on the orphan and on the card and then falls
                    // into the same `apply`.
                    let outcome: VerifiedOutcome
                    if let cardRuns = await ResumeWindow.page(
                        resumedFrom: orphan.resumedFrom,
                        reading: { try await store.runs(cardID: cardID) }
                    ) {
                        outcome = await verifier.verify(
                            run: orphan, card: card, repo: repo, cardRuns: cardRuns,
                            // An orphan has no terminal result at all — the app
                            // died before one arrived — so nothing establishes
                            // that its session was gone. Asked rather than
                            // asserted, so this stays right if the verdict ever
                            // gains a case.
                            resume: ResumeVerdict.of(resumedFrom: orphan.resumedFrom, result: nil)
                        )
                    } else {
                        outcome = .unverified(reason: ResumeWindow.unknownWindowReason)
                    }
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
    /// Returns whether anything actually changed — which is what
    /// `Summary.cardsCorrected` counts.
    private func apply(_ outcome: VerifiedOutcome, to card: Card) async -> Bool {
        // `.launchSweep`: the board is catching up after not running, so its
        // moves are recorded as `.reconciliation` rather than as something it
        // watched happen. That distinction is persisted in `MoveAudit`.
        let result = outcome.applied(to: card, attribution: .launchSweep)
        guard result.changed else { return false }

        try? await store.saveCard(result.card)
        if let move = result.move {
            await mover.applySystemMove(cardID: card.id, to: move.column, reason: move.reason)
        }
        return true
    }
}
