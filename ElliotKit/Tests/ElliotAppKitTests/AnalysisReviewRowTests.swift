import ElliotModel
import Foundation
import Testing

@testable import ElliotAppKit

/// What a decided row may be asked to do, and what it may say (#331).
///
/// `ProposalRowActions` is a closed enum precisely so those two questions have
/// one answer each: *"not four closures beside an `isRejected` flag … a row in
/// the Rejected disclosure that still held an `accept` closure would compile,
/// and the only thing keeping that button off screen would be a view
/// remembering an `if`"*. Adding the accepted group put that claim under load
/// for the first time, because an accepted row is **decided but not refused** —
/// the one combination the type had never had to express.
@Suite("A decided proposal's row")
struct AnalysisReviewRowTests {

    /// Criterion 3, and the half of it that is easy to get backwards: the
    /// demotion says *refused*, and an accepted story was not refused — its card
    /// is on the board. This read `if case .decide { false } else { true }`, so
    /// the day a fourth case arrived it struck through a story that had been
    /// taken.
    @Test("Rejected rows are demoted; accepted and undecided ones are not")
    func onlyARefusalIsStruckThrough() {
        #expect(ProposalRowActions.restore({}).isRefusal)
        #expect(ProposalRowActions.settled.isRefusal)
        #expect(!ProposalRowActions.accepted("In Backlog — Bound the await").isRefusal)
        #expect(
            !ProposalRowActions
                .decide(isSelected: false, toggle: {}, edit: {}, accept: {}, reject: {})
                .isRefusal)
    }

    /// ⛔ **Only an undecided row can be staged.** `AppModel.analysisSelection`
    /// feeds the footer's *Accept N* / *Reject N*, which act on proposals still
    /// open for decision, so a decided row must not be able to enter it at all
    /// — not merely "must not be drawn with a checkbox". The selection travels
    /// *inside* `.decide` for exactly that reason, and this is what says so.
    @Test("A decided row cannot be staged for the footer's bulk verbs")
    func onlyAnUndecidedRowCanBeStaged() {
        #expect(!ProposalRowActions.accepted("In Backlog — Bound the await").isStaged)
        #expect(!ProposalRowActions.restore({}).isStaged)
        #expect(!ProposalRowActions.settled.isStaged)
        #expect(
            ProposalRowActions
                .decide(isSelected: true, toggle: {}, edit: {}, accept: {}, reject: {})
                .isStaged)
    }

    // MARK: - The panel hands the row the right case

    /// The mapping is `AnalysisPanelView.actions(for:)`, and it is a `switch`
    /// over `ProposalStatus` with no `default` — so a fourth status would have
    /// to be classified rather than inherit whichever answer the shorter
    /// spelling gave, and here that answer decides whether a row carries an
    /// *Accept* button.
    ///
    /// A source gate, because `swift test` cannot enter a view: swapping the
    /// `switch` for `proposal.status == .proposed ? .decide(…) : .settled` would
    /// leave every test above green while every accepted row lost its card line
    /// **and gained a strikethrough**.
    @Test("The row's verbs are chosen by an exhaustive switch over the status")
    func theMappingIsExhaustive() throws {
        let source = try Self.panelCode()
        let body = try Self.body(of: "private func actions(for proposal: StoryProposal)", in: source)

        #expect(body.contains("switch proposal.status"), "actions(for:) no longer switches on status")
        for status in ["case .proposed", "case .accepted", "case .rejected"] {
            #expect(
                body.contains(status),
                Comment(rawValue: "actions(for:) does not classify \(status) (#331)"))
        }
        #expect(
            !body.contains("default"),
            """
            actions(for:) has acquired a `default`. A status added later would then inherit \
            whichever case happened to be written first — and that case decides whether a row \
            carries an Accept button (#331)
            """)
        #expect(
            body.contains("ProposalReview.cardLabel("),
            "the accepted case no longer asks the model what to say about the card")
        #expect(
            body.contains("model.card(id: proposal.acceptedCardID)"),
            """
            the accepted case no longer resolves its card through AppModel.card(id:), which \
            searches the unfiltered cards — so a card in a repository the board's picker has \
            filtered out would stop being nameable (#331 criterion 2)
            """)
    }

    private static func panelCode() throws -> String {
        let url = URL(filePath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "Sources/ElliotAppKit/AnalysisPanelView.swift")
        let source = try String(contentsOf: url, encoding: .utf8)
        // Comments cut away, so a *mention* of a token cannot be read as a use
        // of it — the hazard CLAUDE.md records from #186, and the reason
        // `AnalysisPanelViewSourceTests` carries the same helper.
        return source
            .components(separatedBy: "\n")
            .map { line -> String in
                guard let comment = line.range(of: "//") else { return line }
                return String(line[line.startIndex..<comment.lowerBound])
            }
            .joined(separator: "\n")
    }

    private static func body(of signature: String, in source: String) throws -> String {
        let start = try #require(
            source.range(of: signature),
            Comment(rawValue: "\(signature) is not in AnalysisPanelView.swift — renamed?"))
        var depth = 0
        var open: String.Index?
        var index = start.upperBound
        while index < source.endIndex {
            if source[index] == "{" {
                if depth == 0 { open = source.index(after: index) }
                depth += 1
            } else if source[index] == "}" {
                depth -= 1
                if depth == 0, let open { return String(source[open..<index]) }
            }
            index = source.index(after: index)
        }
        Issue.record("no matching brace for \(signature)")
        return ""
    }
}
