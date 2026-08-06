import ElliotModel
import Foundation
import Testing

@testable import ElliotAppKit

/// The arithmetic behind the inline detail panel.
///
/// This suite exists because of #47, #50, #52 and #53 — `.inspector()` shipped
/// three times, green on `swift build` and `swift test` each time, and wrecked
/// the window each time. `swift test` cannot see where anything sits on screen,
/// so nothing here asserts a pixel position or a duration. It asserts the
/// numbers the placement is built from, which is the half of the problem a test
/// *can* hold.
///
/// Every width below is driven from the real formula at three board widths —
/// 1000pt (where the 226 floor binds), the 1640pt default, and 2560pt — rather
/// than from the floor alone. The earlier map computed everything at the floor
/// and was 2.4× off on the panel.
@Suite("Panel layout")
struct PanelLayoutTests {

    /// The three widths every width assertion is replayed at: below the floor's
    /// 1190pt hinge, the default window, and a large display.
    private let boardWidths: [CGFloat] = [1000, 1640, 2560]

    // MARK: - Column width

    @Test("The column formula is today's, floor and all")
    func columnWidthMatchesTheBoardFormula() {
        // max(226, (W − 60) / 5). The floor binds at 1000 and nowhere above it.
        #expect(PanelLayout.columnWidth(boardWidth: 1000) == 226)
        #expect(PanelLayout.columnWidth(boardWidth: 1640) == 316)
        #expect(PanelLayout.columnWidth(boardWidth: 2560) == 500)
        // The hinge itself: 1190 is exactly where the floor stops binding.
        #expect(PanelLayout.columnWidth(boardWidth: 1190) == Metric.minColumnWidth)
        #expect(PanelLayout.columnWidth(boardWidth: 400) == Metric.minColumnWidth)
    }

    // MARK: - 1. Panel width

    @Test("The panel is spans-many columns plus the gutters between them")
    func panelWidthIsMeasuredInColumns() {
        // The default window's column width, so these two numbers are the ones
        // actually on screen rather than floor arithmetic.
        #expect(PanelLayout.panelWidth(columnWidth: 316, spans: 3) == 968)
        #expect(PanelLayout.panelWidth(columnWidth: 316, spans: 2) == 642)

        // And that it is derived, not tabulated: one span is one column, with
        // no gutter to add.
        for boardWidth in boardWidths {
            let column = PanelLayout.columnWidth(boardWidth: boardWidth)
            #expect(PanelLayout.panelWidth(columnWidth: column, spans: 1) == column)
            #expect(
                PanelLayout.panelWidth(columnWidth: column, spans: 3)
                    == 3 * column + 2 * Metric.gutter
            )
        }
    }

    // MARK: - 2. Content width, and the scroll predicate

    @Test("With the panel open the board always overflows, at every allowed width")
    func contentWidthAlwaysExceedsTheBoardWhenOpen() {
        // The whole point: `.scrollDisabled(contentWidth <= boardWidth)` must be
        // false in every window the app allows, or the panel or Done ends up
        // silently unreachable with no scrollbar — a failure invisible to both
        // `swift build` and `swift test`.
        let expected: [CGFloat: (three: CGFloat, two: CGFloat)] = [
            1000: (three: 1898, two: 1662),
            1640: (three: 2618, two: 2292),
            2560: (three: 4090, two: 3580),
        ]

        for boardWidth in boardWidths {
            let three = PanelLayout.contentWidth(boardWidth: boardWidth, spans: 3)
            let two = PanelLayout.contentWidth(boardWidth: boardWidth, spans: 2)

            #expect(three == expected[boardWidth]?.three)
            #expect(two == expected[boardWidth]?.two)
            #expect(three > boardWidth)
            #expect(two > boardWidth)
        }
    }

    @Test("With the panel closed the board is exactly what it is today")
    func contentWidthClosedIsTheCurrentLayout() {
        // Five columns and six gutters — so the derived scroll predicate is a
        // no-op with the panel shut, and the board looks identical.
        for boardWidth in boardWidths {
            let closed = PanelLayout.contentWidth(boardWidth: boardWidth, spans: nil)
            let column = PanelLayout.columnWidth(boardWidth: boardWidth)
            #expect(closed == 5 * column + 6 * Metric.gutter)

            // It agrees with today's `width > Metric.minColumnWidth` predicate:
            // the board scrolls exactly when the floor is binding.
            let wouldScroll = closed > boardWidth
            #expect(wouldScroll == (column <= Metric.minColumnWidth))
        }
    }

    // MARK: - 3. Which edge the panel opens on

    @Test("Exactly one column opens left, and it is Done")
    func onlyTheLastColumnOpensLeft() {
        let opening = ElliotModel.Column.allCases.filter(PanelLayout.opensLeft(of:))
        #expect(opening == [.done])
        #expect(opening.count == 1)

        // Asserted over every case rather than the one, so a sixth column added
        // after Done moves the flip with it instead of stranding it.
        for column in ElliotModel.Column.allCases {
            #expect(
                PanelLayout.opensLeft(of: column)
                    == (column.boardIndex == ElliotModel.Column.allCases.count - 1)
            )
        }
    }

    // MARK: - 4. Board order

    @Test("Selecting a card inserts one panel and loses no column")
    func boardOrderHoldsEveryColumnPlusOnePanel() {
        for selected in ElliotModel.Column.allCases {
            let slots = PanelLayout.boardOrder(selected: selected)

            #expect(slots.count == ElliotModel.Column.allCases.count + 1)
            #expect(slots.filter { $0 == .panel }.count == 1)
            // Every column still present, still in board order.
            #expect(
                slots.compactMap(\.column) == ElliotModel.Column.allCases
            )

            // And the panel sits beside its origin, on the right edge for the
            // four forward columns and the left edge for Done.
            let panelIndex = slots.firstIndex(of: .panel)
            let originIndex = slots.firstIndex(of: .column(selected))
            if PanelLayout.opensLeft(of: selected) {
                #expect(panelIndex.map { $0 + 1 } == originIndex)
            } else {
                #expect(originIndex.map { $0 + 1 } == panelIndex)
            }
        }
    }

    @Test("With nothing selected the board is five columns and no panel")
    func boardOrderIsJustTheColumnsWhenNothingIsSelected() {
        let slots = PanelLayout.boardOrder(selected: nil)
        #expect(slots.count == 5)
        #expect(!slots.contains(.panel))
        #expect(slots == ElliotModel.Column.allCases.map(BoardSlot.column))
    }

    // MARK: - 5. Caret

    @Test("The caret clamps to both insets and is the identity between them")
    func caretYClampsToTheRoundedCorners() {
        let panelMinY: CGFloat = 100
        let panelHeight: CGFloat = 600

        // Above the panel, and far above it: pinned to the inset so the caret
        // stays off the top corner radius.
        #expect(caret(cardMidY: 0, panelMinY, panelHeight) == 26)
        #expect(caret(cardMidY: 100, panelMinY, panelHeight) == 26)
        #expect(caret(cardMidY: 120, panelMinY, panelHeight) == 26)
        #expect(caret(cardMidY: -4_000, panelMinY, panelHeight) == 26)

        // Below it: pinned to `panelHeight − inset`.
        #expect(caret(cardMidY: 700, panelMinY, panelHeight) == 574)
        #expect(caret(cardMidY: 4_000, panelMinY, panelHeight) == 574)

        // Between: the plain difference, both at the bounds and in the middle.
        #expect(caret(cardMidY: 126, panelMinY, panelHeight) == 26)
        #expect(caret(cardMidY: 400, panelMinY, panelHeight) == 300)
        #expect(caret(cardMidY: 674, panelMinY, panelHeight) == 574)

        // Never outside the panel, whatever it is handed — including a panel
        // shorter than twice the inset, which would otherwise invert the range.
        for y in stride(from: CGFloat(-500), through: 1_500, by: 37) {
            let value = caret(cardMidY: y, panelMinY, panelHeight)
            #expect(value >= 26)
            #expect(value <= panelHeight - 26)
        }
        #expect(caret(cardMidY: 0, panelMinY, 10) == 26)
        #expect(caret(cardMidY: 9_999, panelMinY, 10) == 26)
    }

    private func caret(
        cardMidY: CGFloat, _ panelMinY: CGFloat, _ panelHeight: CGFloat
    ) -> CGFloat {
        PanelLayout.caretY(
            cardMidY: cardMidY, panelMinY: panelMinY, panelHeight: panelHeight
        )
    }

    // MARK: - 6. Detached

    @Test("Detached at and past the inset on both edges, and for a card never built")
    func isDetachedTreatsAbsenceAsOutOfBand() {
        let top: CGFloat = 200
        let bottom: CGFloat = 800

        // A card that a `LazyVStack` never built reports no rect at all.
        // Reading that as `y = 0` would aim the caret at the top of the panel
        // and assert a card is there.
        #expect(PanelLayout.isDetached(cardMidY: nil, listTop: top, listBottom: bottom))

        // At the inset on both edges — the boundary is detached, not attached.
        #expect(detached(206, top, bottom))
        #expect(detached(794, top, bottom))
        // And past it.
        #expect(detached(205, top, bottom))
        #expect(detached(200, top, bottom))
        #expect(detached(0, top, bottom))
        #expect(detached(795, top, bottom))
        #expect(detached(800, top, bottom))
        #expect(detached(5_000, top, bottom))

        // Inside the band, it is attached.
        #expect(!detached(207, top, bottom))
        #expect(!detached(500, top, bottom))
        #expect(!detached(793, top, bottom))
    }

    private func detached(_ y: CGFloat, _ top: CGFloat, _ bottom: CGFloat) -> Bool {
        PanelLayout.isDetached(cardMidY: y, listTop: top, listBottom: bottom)
    }

    // MARK: - 7. Framing offset

    @Test("The framing offset leads the pair, flips with it, and never goes negative")
    func frameOffsetXLeadsTheLeadingViewOfThePair() {
        // Not flipped: the origin column leads, the panel follows it.
        #expect(
            PanelLayout.frameOffsetX(originMinX: 500, panelMinX: 826, flipped: false) == 404
        )
        // Flipped: the panel leads. Using `originMinX` here would scroll past
        // the panel and leave it off-screen to the left.
        #expect(
            PanelLayout.frameOffsetX(originMinX: 1_600, panelMinX: 622, flipped: true) == 526
        )

        // Which input is read is *only* decided by `flipped` — same pair, two
        // answers.
        let flat = PanelLayout.frameOffsetX(originMinX: 1_600, panelMinX: 622, flipped: false)
        let flipped = PanelLayout.frameOffsetX(originMinX: 1_600, panelMinX: 622, flipped: true)
        #expect(flat != flipped)
        #expect(flat == 1_504)

        // Never negative: a negative content offset is not a position. Near the
        // leading edge of the board the whole lead is unavailable.
        #expect(PanelLayout.frameOffsetX(originMinX: 10, panelMinX: 336, flipped: false) == 0)
        #expect(PanelLayout.frameOffsetX(originMinX: 96, panelMinX: 422, flipped: false) == 0)
        #expect(PanelLayout.frameOffsetX(originMinX: 400, panelMinX: 0, flipped: true) == 0)
        #expect(PanelLayout.frameOffsetX(originMinX: -900, panelMinX: -900, flipped: true) == 0)

        for x in stride(from: CGFloat(-2_000), through: 4_000, by: 53) {
            #expect(PanelLayout.frameOffsetX(originMinX: x, panelMinX: x, flipped: false) >= 0)
            #expect(PanelLayout.frameOffsetX(originMinX: x, panelMinX: x, flipped: true) >= 0)
        }
    }

    // MARK: - 8. Where a slot sits in the row

    @Test("A slot's leading edge is the gutter plus everything before it")
    func minXWalksTheRow() {
        for boardWidth in boardWidths {
            let column = PanelLayout.columnWidth(boardWidth: boardWidth)
            let panel = PanelLayout.panelWidth(columnWidth: column, spans: 3)
            let closed = PanelLayout.boardOrder(selected: nil)

            // Closed: five columns, the first one a gutter in — the row's own
            // padding — and each one a column and a gutter after the last.
            for (index, slot) in closed.enumerated() {
                #expect(
                    PanelLayout.minX(
                        of: slot, in: closed, columnWidth: column, panelWidth: panel
                    ) == Metric.gutter + CGFloat(index) * (column + Metric.gutter)
                )
            }
            // And there is no panel to find in it. `nil`, not `0`: zero is a
            // position, and a caller that scrolled to it would scroll to the
            // leading edge of the board and look like it had worked.
            #expect(
                PanelLayout.minX(
                    of: .panel, in: closed, columnWidth: column, panelWidth: panel
                ) == nil
            )
        }
    }

    @Test("The row `minX` walks is the row `contentWidth` measures")
    func minXAgreesWithContentWidth() {
        // The reason this is worth asserting: the scroll predicate is built on
        // `contentWidth` and the framing on `minX`. If they described two
        // different rows the board could frame a pair it had also decided was
        // unreachable — and neither `swift build` nor `swift test` would say so.
        for boardWidth in boardWidths {
            for spans in [2, 3] {
                let column = PanelLayout.columnWidth(boardWidth: boardWidth)
                let panel = PanelLayout.panelWidth(columnWidth: column, spans: spans)

                for selected in [nil] + ElliotModel.Column.allCases.map(Optional.some) {
                    let slots = PanelLayout.boardOrder(selected: selected)
                    guard let last = slots.last,
                          let lastMinX = PanelLayout.minX(
                              of: last, in: slots, columnWidth: column, panelWidth: panel
                          )
                    else { Issue.record("empty board order"); return }

                    // The trailing edge of the last slot, plus the row's own
                    // trailing padding, is the whole content width.
                    let width = last == .panel ? panel : column
                    #expect(
                        lastMinX + width + Metric.gutter
                            == PanelLayout.contentWidth(
                                boardWidth: boardWidth, spans: selected == nil ? nil : spans
                            )
                    )
                }
            }
        }
    }

    @Test("The panel sits one gutter from its origin column, on the side it opens")
    func minXPutsThePanelBesideItsOrigin() {
        for boardWidth in boardWidths {
            let column = PanelLayout.columnWidth(boardWidth: boardWidth)
            let panel = PanelLayout.panelWidth(columnWidth: column, spans: 3)

            for selected in ElliotModel.Column.allCases {
                let slots = PanelLayout.boardOrder(selected: selected)
                guard let originMinX = PanelLayout.minX(
                          of: .column(selected), in: slots,
                          columnWidth: column, panelWidth: panel
                      ),
                      let panelMinX = PanelLayout.minX(
                          of: .panel, in: slots, columnWidth: column, panelWidth: panel
                      )
                else { Issue.record("no pair for \(selected)"); return }

                if PanelLayout.opensLeft(of: selected) {
                    // Done: the panel comes first, so the column starts a panel
                    // and a gutter after it.
                    #expect(originMinX - panelMinX == panel + Metric.gutter)
                } else {
                    #expect(panelMinX - originMinX == column + Metric.gutter)
                }
            }
        }
    }

    // MARK: - 9. Framing the pair

    @Test("Framing leads the pair by 96pt, or by everything there is")
    func framingLeadsThePair() {
        for boardWidth in boardWidths {
            for spans in [2, 3] {
                for selected in ElliotModel.Column.allCases {
                    let pair = framed(boardWidth: boardWidth, spans: spans, selected: selected)

                    // The lead in full, except at the leading edge of the board
                    // where there is not 96pt of row to give.
                    #expect(pair.offset >= 0)
                    #expect(pair.leadingMinX - pair.offset == min(96, pair.leadingMinX))
                }
            }
        }
    }

    @Test("The framed pair fits the window, except at the narrowest one")
    func framedPairFitsTheViewport() {
        // The one measurement that is not free: the lead costs 96pt of
        // viewport, and at the 1000pt minimum window with the panel at three
        // spans the pair is 934pt — 1030 with the lead, which is 30pt more than
        // there is. Every other combination fits outright.
        //
        // Pinned rather than smoothed over: the shortfall belongs to the lead,
        // not to the panel, and a reader who wants the pair whole at that size
        // has Narrow details (2 spans, 794pt with the lead). Anyone changing
        // the lead or the span default should have to change this number too.
        for boardWidth in boardWidths {
            for spans in [2, 3] {
                for selected in ElliotModel.Column.allCases {
                    let pair = framed(boardWidth: boardWidth, spans: spans, selected: selected)
                    let overflow = pair.trailingMaxX - (pair.offset + boardWidth)

                    if boardWidth == 1_000, spans == 3, pair.offset > 0 {
                        #expect(overflow == 30)
                        // Without the lead it would fit: the pair itself is
                        // narrower than the window.
                        #expect(pair.trailingMaxX - pair.leadingMinX < boardWidth)
                    } else {
                        #expect(overflow <= 0)
                    }
                }
            }
        }
    }

    /// The framed pair at one board width, one span setting and one selection:
    /// where it starts, where it ends, and where the board scrolls to show it.
    private func framed(
        boardWidth: CGFloat, spans: Int, selected: ElliotModel.Column
    ) -> (offset: CGFloat, leadingMinX: CGFloat, trailingMaxX: CGFloat) {
        let column = PanelLayout.columnWidth(boardWidth: boardWidth)
        let panel = PanelLayout.panelWidth(columnWidth: column, spans: spans)
        let slots = PanelLayout.boardOrder(selected: selected)
        let flipped = PanelLayout.opensLeft(of: selected)

        let originMinX = PanelLayout.minX(
            of: .column(selected), in: slots, columnWidth: column, panelWidth: panel
        ) ?? 0
        let panelMinX = PanelLayout.minX(
            of: .panel, in: slots, columnWidth: column, panelWidth: panel
        ) ?? 0

        return (
            offset: PanelLayout.frameOffsetX(
                originMinX: originMinX, panelMinX: panelMinX, flipped: flipped
            ),
            leadingMinX: flipped ? panelMinX : originMinX,
            trailingMaxX: flipped ? originMinX + column : panelMinX + panel
        )
    }

    // MARK: - The tether

    @Test("The tether reaches the gutter plus the column's own list padding")
    func tetherReachCrossesBothLiterals() {
        // 18 — but asserted as the sum, so it stays true the day either moves.
        #expect(PanelLayout.tetherReach == Metric.gutter + Metric.columnListPadding)
        #expect(PanelLayout.tetherReach == 18)
        #expect(Metric.columnListPadding == 8)
    }

    // MARK: - The caret against the panel's edge

    /// Nothing here is a pixel position: every assertion is stated against a
    /// panel edge handed in as a parameter, which is the only thing the caret's
    /// placement is a function of. Where that edge falls on screen is the
    /// board's business and is measured, not computed.

    @Test("The caret's point clears the panel and its mouth covers the border")
    func caretStraddlesThePanelEdge() {
        let edge: CGFloat = 500
        let width = CaretMetric.depth + CaretMetric.border
        let centre = CaretMetric.caretCenterX(panelEdgeX: edge, flipped: false)

        // The mouth sits *inside* the panel by exactly the border width, which
        // is what stops the panel's own outline running across it: a triangle
        // with a line drawn over its base is glued to the wall rather than
        // notched out of it.
        #expect(centre + width / 2 == edge + CaretMetric.border)
        #expect(centre - width / 2 == edge - CaretMetric.depth)
    }

    @Test("Flipping mirrors the caret and the tether about the panel's edge")
    func flippingMirrorsBothDecorations() {
        // The case that is invisible in exactly one column and nowhere else.
        for edge: CGFloat in [0, 320, 1_280] {
            let caretRight = CaretMetric.caretCenterX(panelEdgeX: edge, flipped: true)
            let caretLeft = CaretMetric.caretCenterX(panelEdgeX: edge, flipped: false)
            #expect(caretRight - edge == edge - caretLeft)

            let tetherRight = CaretMetric.tetherCenterX(panelEdgeX: edge, flipped: true)
            let tetherLeft = CaretMetric.tetherCenterX(panelEdgeX: edge, flipped: false)
            #expect(tetherRight - edge == edge - tetherLeft)
        }
    }

    @Test("The tether starts at the panel's edge and ends at the card's")
    func tetherSpansEdgeToCard() {
        let edge: CGFloat = 500
        let half = PanelLayout.tetherReach / 2

        let near = CaretMetric.tetherCenterX(panelEdgeX: edge, flipped: false)
        #expect(near + half == edge)
        #expect(near - half == edge - PanelLayout.tetherReach)

        let far = CaretMetric.tetherCenterX(panelEdgeX: edge, flipped: true)
        #expect(far - half == edge)
        #expect(far + half == edge + PanelLayout.tetherReach)

        // The caret is drawn over the tether, so a caret that reached as far as
        // the rail does would swallow it whole and leave a triangle with no line
        // leaving it — which is the dash-near-the-card failure the reach exists
        // to avoid, arrived at from the other end.
        #expect(CaretMetric.depth < PanelLayout.tetherReach)
    }

    @Test("Detached drops the tether outright and leaves the caret faint")
    func detachedStatesSayTheyDoNotKnow() {
        // The tether cannot point at a card that is not on screen, so it goes
        // rather than fades. The caret stays visible — the panel still has an
        // edge the reader has to be able to find — but at a weight that is
        // plainly not the attached one.
        #expect(CaretMetric.detachedTether == 0)
        #expect(CaretMetric.detachedCaret > 0)
        #expect(CaretMetric.detachedCaret < 0.5)
    }
}

private extension BoardSlot {
    /// The column this slot holds, or `nil` for the panel — so a test can say
    /// "every column is still here, in order" without a `switch` at each site.
    var column: ElliotModel.Column? {
        if case .column(let column) = self { return column }
        return nil
    }
}
