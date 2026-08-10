import Foundation

/// An analysis's proposals, read by what was decided about them (#331).
///
/// `AnalysisService.reject` marks rather than deletes and says why in as many
/// words — *"an analysis you have been through should still read as what it
/// found, including what you turned down"* — and `accept` writes
/// `acceptedCardID` so a proposal can name the card it became. Both facts were
/// then unreadable, because the panel narrowed the session to one status in one
/// line and everything downstream was built on that single value.
///
/// The cost was an empty list that meant two different things. *"Nothing left
/// to decide. Every proposal has been accepted or rejected."* rendered
/// identically when a lens had harvested twelve stories and you had decided all
/// twelve, and when a lens had finished and proposed nothing at all — and it is
/// flatly wrong in the second case, where nothing was ever there to decide. The
/// lens strip two inches above said `0 kept` in one case and `12 kept` in the
/// other, so the information existed and the list contradicted it.
///
/// ⛔ **No fourth `ProposalStatus`.** `Analysis` has no `state` field and says
/// why: a stored counter is *"a second reservoir of truth that drifts on the
/// first crash"*. The same argument forbids a `reviewed` case here — the three
/// statuses are the truth, and a filter is a way of looking at them, not a
/// fourth one.
///
/// It holds no `Color` and no `View`, for the reason `AnalysisFooterMessage`
/// gives about `Tone`: a test asserts the decision rather than a rendering.
public enum ProposalReview {

    /// The proposals in one group, in the order they were harvested.
    ///
    /// The input order is preserved rather than re-sorted: the rows arrive from
    /// `observeProposals`, already ordered by `createdAt`, and *when it was
    /// rejected* is not recorded anywhere — so inventing an order for the
    /// decided groups would be a claim the data cannot support.
    public static func group(
        _ proposals: [StoryProposal], _ status: ProposalStatus
    ) -> [StoryProposal] {
        proposals.filter { $0.status == status }
    }

    /// How many are in each group.
    ///
    /// **Every case present, zero included.** A missing key and a zero being the
    /// same value is precisely the ambiguity this whole reading exists to close:
    /// a picker that hid the *Rejected* tab because the dictionary had no key
    /// for it would be one more surface that cannot tell "nothing was rejected"
    /// from "nobody looked".
    public static func counts(_ proposals: [StoryProposal]) -> [ProposalStatus: Int] {
        var tally = Dictionary(uniqueKeysWithValues: ProposalStatus.allCases.map { ($0, 0) })
        for proposal in proposals { tally[proposal.status, default: 0] += 1 }
        return tally
    }

    /// What an empty group means — which is different for each one, and for the
    /// undecided group is different again depending on what the run harvested.
    public struct Empty: Equatable, Sendable {
        public let title: String
        public let detail: String
        /// An SF Symbol name. Beside its sentence rather than chosen by the view,
        /// on `AnalysisFooterMessage`'s argument: a symbol that disagrees with
        /// the sentence it labels is the same defect as two sentences.
        public let symbol: String
    }

    /// The crux of this reading, and the reason `harvested` is a parameter.
    ///
    /// It takes the runs' own `AnalysisRunReport.kept` total — **not the row
    /// count**, which is the number the view already has and the number that
    /// cannot tell the two cases apart. A list of zero proposed rows is a list of
    /// zero proposed rows whether the lens found nothing or you decided
    /// everything; only the harvest knows which.
    ///
    /// `running` is the titles of the lenses still reading, and the sentence is
    /// composed **here** rather than by the view. A caller free to splice the
    /// lens names into a title it also chose could put "Reading — Bugs" over the
    /// *Accepted* group's empty state, which is the one place a lens still going
    /// says nothing at all.
    public static func emptyMessage(
        for status: ProposalStatus, harvested: Int, running: [String] = []
    ) -> Empty {
        switch status {
        case .proposed:
            // Still reading outranks both: a lens that has not finished may yet
            // land the rows this list is empty of.
            if !running.isEmpty {
                return Empty(
                    title: "Reading — \(running.joined(separator: ", "))",
                    detail: "Proposals appear here lens by lens, as each run finishes. "
                        + "You can accept the first ones while the rest are still reading.",
                    symbol: "hourglass"
                )
            }
            if harvested == 0 {
                return Empty(
                    title: "This analysis proposed nothing.",
                    detail: "Every lens finished and none of them kept a story. "
                        + "There was never anything here to decide.",
                    symbol: "tray"
                )
            }
            return Empty(
                title: "Nothing left to decide.",
                detail: "Every proposal has been accepted or rejected. "
                    + "Close this panel and the accepted ones are waiting in Backlog.",
                symbol: "checkmark.circle"
            )
        case .accepted:
            return Empty(
                title: "Nothing from this analysis has been accepted.",
                detail: "Accepting a proposal makes a card in Backlog, and names it here.",
                symbol: "tray.and.arrow.down"
            )
        case .rejected:
            return Empty(
                title: "Nothing from this analysis has been rejected.",
                detail: "A rejected proposal is marked rather than deleted, so it would still be "
                    + "readable here.",
                symbol: "xmark.bin"
            )
        }
    }

    /// What an accepted row says about the card it became.
    ///
    /// ⚠️ **Non-optional on purpose: `acceptedCardID` resolving to nothing is a
    /// real state, and it is not "not accepted".** Three ways it happens, and
    /// the first is deliberate: `accept` commits the card and *then* writes the
    /// backlink, because if that second write fails *"the honest state is the
    /// claim's own — `.accepted`, just possibly missing the `acceptedCardID`
    /// backlink"*. The card can also have been deleted since, and the row can be
    /// read mid-flight between the two writes.
    ///
    /// In all three the row must still read as **accepted**. Returning `nil` and
    /// letting a view fall back to the undecided styling would reintroduce this
    /// reading's own defect one level down — a decided proposal reading as
    /// available for acceptance a second time.
    public static func cardLabel(for proposal: StoryProposal, card: Card?) -> String {
        guard proposal.status == .accepted else {
            // Not a card's row at all. Stated rather than crashed on, because
            // the caller is a `ForEach` over whichever group is on screen.
            return "Not accepted."
        }
        guard let card else {
            return "Accepted — the card it became cannot be found."
        }
        let title = card.displayTitle
        return title.isEmpty
            ? "Accepted — in \(card.column.displayName)."
            : "In \(card.column.displayName) — \(title)"
    }
}
