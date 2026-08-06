import ElliotModel
import Foundation
import SwiftUI
import Testing

@testable import ElliotAppKit

/// What the board scrolls to, and — more to the point — *when* it recomputes it.
///
/// The framing used to be keyed on `selectedCardID` and the selected card's
/// column. Both are proxies for the row's shape, and three paths change the row
/// without touching either of them, so the board stayed scrolled for the row it
/// had a moment ago. `swift test` cannot see the screen; what it can see is that
/// the value the framing answers to actually changes on all three, and that the
/// offset it produces is the one the row's arithmetic implies.
@Suite("Board framing")
struct BoardFramingTests {

    /// The default window. At 1640pt the floor does not bind, so the columns are
    /// 316pt and the panel is a real multiple of them — the case the framing has
    /// to be right about, rather than the narrow one where everything scrolls
    /// anyway.
    private let boardWidth: CGFloat = 1_640

    private func framing(
        card: UUID? = nil,
        column: ElliotModel.Column?,
        origin: ElliotModel.Column?,
        spans: Int = 3
    ) -> BoardFraming {
        BoardFraming(
            selectedCardID: card ?? UUID(),
            selectedColumn: column,
            panelOrigin: origin,
            spans: spans
        )
    }

    // MARK: - The three paths that used to change nothing

    /// ⚠️ The offset is **not** what these three assert, and finding out why is
    /// worth more than the tests are.
    ///
    /// `PanelLayout.minX` sums the slots *before* its target. For a column that
    /// is not flipped the panel is inserted after it, and for the flipped column
    /// the panel is the target with four plain columns ahead of it — so no panel
    /// width is ever summed, and `offsetX` is invariant to `spans` and, for a
    /// non-flipped column, to whether the panel is open at all. That invariance
    /// is pinned by `offsetIsInvariantToThePanelsWidth` below.
    ///
    /// What changes is whether that offset can be *applied*. With the panel shut
    /// the row fits the window, `scrollDisabled` is true and the scroll clamps
    /// to zero; opening the panel makes the row 1.6–1.7× the viewport, and the
    /// same number suddenly means something. So the framing has to re-run on a
    /// row it computes the same answer for — which is exactly why keying it on a
    /// value that did not move left the board where it was.
    @Test("Opening the panel on a card that is already selected changes the framing")
    func detailsButtonOnAnAlreadySelectedCard() throws {
        // The Details toolbar button toggles `showingInspector` and nothing
        // else. With the card already selected, neither old key moved.
        let card = UUID()
        let shut = framing(card: card, column: .inProgress, origin: nil)
        let open = framing(card: card, column: .inProgress, origin: .inProgress)

        #expect(shut != open, "the toolbar button must reach the framing")

        // And the offset stops being inert across that same toggle: shut, the
        // row fits and nothing can scroll; open, it does not.
        #expect(PanelLayout.contentWidth(boardWidth: boardWidth, spans: nil) <= boardWidth)
        #expect(PanelLayout.contentWidth(boardWidth: boardWidth, spans: 3) > boardWidth)
        #expect(try #require(open.offsetX(boardWidth: boardWidth)) > 0)
    }

    @Test("Resizing the panel changes the framing")
    func resizingThePanel() {
        // The drag handle and View ▸ Narrow/Widen both write `panelSpans`. The
        // row's extent changes with it — narrowing pulls the far edge in, which
        // is where a scroll offset gets clamped — so the framing has to be
        // re-applied even though it computes the same x.
        let card = UUID()
        for column in ElliotModel.Column.allCases {
            let wide = framing(card: card, column: column, origin: column, spans: 3)
            let narrow = framing(card: card, column: column, origin: column, spans: 2)
            #expect(wide != narrow, "a resize must reach the framing, in \(column)")
        }
        #expect(
            PanelLayout.contentWidth(boardWidth: boardWidth, spans: 3)
                > PanelLayout.contentWidth(boardWidth: boardWidth, spans: 2)
        )
    }

    @Test("Arming a merge on the selected card changes the framing")
    func armingAMergeReframes() throws {
        // `armPendingMerge` sets the selection *and* opens the panel. When the
        // card it arms is the one already selected — the Card menu's Advance,
        // the panel's own Next step — the only thing that moved was
        // `showingInspector`, and the framing never re-ran. This is the path to
        // the single irreversible act in the product, so a confirmation opening
        // off-screen is the worst of the three.
        //
        // In Review is also the column it always happens in, and it is past the
        // fold: its offset is a real scroll, not a clamp to zero.
        let card = UUID()
        let before = framing(card: card, column: .inReview, origin: nil)
        let after = framing(card: card, column: .inReview, origin: .inReview)

        #expect(before != after)
        #expect(try #require(after.offsetX(boardWidth: boardWidth)) > 0)
    }

    @Test("The offset is invariant to the panel's width, and says so on purpose")
    func offsetIsInvariantToThePanelsWidth() {
        // Stated rather than left to be rediscovered. `PanelLayout.minX` sums
        // the slots ahead of its target and no panel is ever among them, so
        // `spans` cannot move this number. If that ever stops being true — a
        // panel placed two columns along, say — this fails, and the trigger that
        // already carries `spans` will be the reason nothing else has to change.
        for column in ElliotModel.Column.allCases {
            let wide = framing(column: column, origin: column, spans: 3)
            let narrow = framing(column: column, origin: column, spans: 2)
            #expect(
                wide.offsetX(boardWidth: boardWidth) == narrow.offsetX(boardWidth: boardWidth),
                "\(column)"
            )
        }
    }

    // MARK: - What it must still answer to

    @Test("The paths the old keys did catch still change the framing")
    func selectionAndColumnStillCount() {
        // Both old handlers earned their place — one for the click, one for ⌘→,
        // which advances a card without touching `selectedCardID`. Folding four
        // questions into one value must not drop either.
        let here = framing(card: UUID(), column: .todo, origin: .todo)
        let elsewhere = framing(card: UUID(), column: .todo, origin: .todo)
        #expect(here != elsewhere, "a different card is a different framing")

        let card = UUID()
        let before = framing(card: card, column: .todo, origin: .todo)
        let advanced = framing(card: card, column: .inProgress, origin: .inProgress)
        #expect(before != advanced, "⌘→ never touches selectedCardID")
        #expect(before.offsetX(boardWidth: boardWidth) != advanced.offsetX(boardWidth: boardWidth))
    }

    @Test("Nothing selected frames nothing")
    func noSelectionNoOffset() {
        // `nil` rather than 0: zero is a position, and scrolling to it would
        // yank the board back to Backlog every time a card is deselected.
        #expect(framing(column: nil, origin: nil).offsetX(boardWidth: boardWidth) == nil)
    }

    // MARK: - The offset itself

    @Test("The offset is the row's own arithmetic, not a second copy of it")
    func offsetAgreesWithPanelLayout() throws {
        // Asserted against `PanelLayout` rather than against numbers, because
        // the failure this guards is the two drifting apart. Every column, panel
        // open and shut, at both spans.
        for column in ElliotModel.Column.allCases {
            for origin in [nil, column] as [ElliotModel.Column?] {
                for spans in [PanelLayout.spanChoices.narrow, PanelLayout.spanChoices.wide] {
                    let subject = framing(column: column, origin: origin, spans: spans)
                    let slots = PanelLayout.boardOrder(selected: origin)
                    let columnWidth = PanelLayout.columnWidth(boardWidth: boardWidth)
                    let panelWidth = PanelLayout.panelWidth(
                        columnWidth: columnWidth, spans: spans
                    )
                    let originMinX = try #require(PanelLayout.minX(
                        of: .column(column), in: slots,
                        columnWidth: columnWidth, panelWidth: panelWidth
                    ))
                    let panelMinX = PanelLayout.minX(
                        of: .panel, in: slots,
                        columnWidth: columnWidth, panelWidth: panelWidth
                    )
                    let expected = PanelLayout.frameOffsetX(
                        originMinX: originMinX,
                        panelMinX: panelMinX ?? originMinX,
                        flipped: origin != nil && PanelLayout.opensLeft(of: column)
                    )
                    #expect(
                        subject.offsetX(boardWidth: boardWidth) == expected,
                        "\(column) origin \(String(describing: origin)) spans \(spans)"
                    )
                }
            }
        }
    }

    @Test("The flipped column frames its panel, not itself")
    func flippedColumnFramesThePanel() throws {
        // Done opens its panel to the *left*, so the pair's leading edge is the
        // panel's. Framing on the column would scroll past the panel and leave
        // it off-screen — which is the case the whole `flipped` argument exists
        // for, and the one the merge confirmation lands in.
        let done = framing(column: .done, origin: .done)
        let columnWidth = PanelLayout.columnWidth(boardWidth: boardWidth)
        let panelWidth = PanelLayout.panelWidth(
            columnWidth: columnWidth, spans: PanelLayout.spanChoices.wide
        )
        let slots = PanelLayout.boardOrder(selected: .done)
        let panelMinX = try #require(PanelLayout.minX(
            of: .panel, in: slots, columnWidth: columnWidth, panelWidth: panelWidth
        ))
        let columnMinX = try #require(PanelLayout.minX(
            of: .column(.done), in: slots, columnWidth: columnWidth, panelWidth: panelWidth
        ))

        #expect(panelMinX < columnMinX, "Done's panel is placed before it")
        #expect(done.offsetX(boardWidth: boardWidth) == max(0, panelMinX - 96))
    }

    @Test("Backlog with no panel does not scroll the board at all")
    func firstColumnNeverScrollsNegative() {
        // The lead is larger than Backlog's own leading edge, so the offset
        // clamps at zero rather than going negative. A negative content offset
        // is not a position.
        #expect(framing(column: .backlog, origin: nil).offsetX(boardWidth: boardWidth) == 0)
    }
}
