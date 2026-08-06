import ElliotModel
import Foundation
import Testing

@testable import ElliotAppKit

/// The arithmetic behind the panel's drag handle.
///
/// The gesture is the untestable half — `ElliotApp` has no test target and
/// `swift test` cannot see a cursor, a hover or a drag. The *decision* is not:
/// given a drag translation, a column width and which edge the handle is on,
/// exactly one span wins, and that is a pure function. It lives in
/// `PanelLayout.snappedSpans` for the same reason every other number on this
/// panel does — `.inspector()` shipped three times green and wrecked the window
/// three times (#47, #50, #52, #53), and the lesson was to put the arithmetic
/// somewhere a test can hold it.
///
/// Two things here would be invisible on screen until a reader hit them:
/// the **mirror** (the handle is on the leading edge for Done, so the same
/// physical gesture is a leftward drag there) and the **wash** (a click that
/// does not move must not resize anything). Both get their own test.
@Suite("Panel resize")
struct PanelResizeTests {

    /// The same three board widths the rest of the panel's arithmetic is
    /// replayed at: below the 1190pt hinge where the column floor binds, the
    /// default window, and a large display.
    private let boardWidths: [CGFloat] = [1000, 1640, 2560]

    private var columnWidths: [CGFloat] {
        boardWidths.map { PanelLayout.columnWidth(boardWidth: $0) }
    }

    /// How far the outer edge has to travel for the snap to change its mind:
    /// half of one column plus its gutter.
    private func halfStep(_ columnWidth: CGFloat) -> CGFloat {
        (columnWidth + Metric.gutter) / 2
    }

    // MARK: - 1. The two settings

    /// The choices are not arbitrary numbers to snap to — they are the two
    /// *layouts* the panel has. Anything between them is a panel too wide for
    /// one pane and too narrow for two, which is why the handle snaps at all.
    @Test("The two snap targets are exactly the one-pane and two-pane layouts")
    func spanChoicesAreTheTwoLayouts() {
        #expect(PanelLayout.spanChoices.narrow < PanelLayout.spanChoices.wide)
        #expect(!PanelLayout.showsBothPanes(spans: PanelLayout.spanChoices.narrow))
        #expect(PanelLayout.showsBothPanes(spans: PanelLayout.spanChoices.wide))

        // And the same two the View menu writes, so the menu item and the
        // handle cannot come to disagree about what "narrow" means.
        #expect(PanelLayout.spanChoices.narrow == 2)
        #expect(PanelLayout.spanChoices.wide == 3)
    }

    // MARK: - 2. A drag that goes nowhere changes nothing

    @Test("A click on the handle that never moves leaves the width alone")
    func aWashIsNotAResize() {
        for columnWidth in columnWidths {
            for opensLeft in [true, false] {
                for spans in [PanelLayout.spanChoices.narrow, PanelLayout.spanChoices.wide] {
                    #expect(
                        PanelLayout.snappedSpans(
                            from: spans,
                            translation: 0,
                            columnWidth: columnWidth,
                            opensLeft: opensLeft
                        ) == spans,
                        "A handle that resizes on a click resizes the panel behind the reader's back."
                    )
                }
            }
        }
    }

    /// Dead level — the drag ended exactly half a column short of either
    /// target. Staying put is the only answer that does not pick for the
    /// reader.
    @Test("A drag that lands exactly between the two settings stays where it was")
    func aTieStaysPut() {
        for columnWidth in columnWidths {
            let half = halfStep(columnWidth)

            #expect(
                PanelLayout.snappedSpans(
                    from: PanelLayout.spanChoices.wide,
                    translation: -half,
                    columnWidth: columnWidth,
                    opensLeft: false
                ) == PanelLayout.spanChoices.wide
            )
            #expect(
                PanelLayout.snappedSpans(
                    from: PanelLayout.spanChoices.narrow,
                    translation: half,
                    columnWidth: columnWidth,
                    opensLeft: false
                ) == PanelLayout.spanChoices.narrow
            )
        }
    }

    // MARK: - 3. Past the halfway point it changes

    @Test("Dragging the outer edge outward past halfway widens; short of it does not")
    func wideningSnapsAtTheHalfwayPoint() {
        for columnWidth in columnWidths {
            let half = halfStep(columnWidth)
            let narrow = PanelLayout.spanChoices.narrow

            #expect(
                PanelLayout.snappedSpans(
                    from: narrow, translation: half + 1,
                    columnWidth: columnWidth, opensLeft: false
                ) == PanelLayout.spanChoices.wide
            )
            #expect(
                PanelLayout.snappedSpans(
                    from: narrow, translation: half - 1,
                    columnWidth: columnWidth, opensLeft: false
                ) == narrow
            )
        }
    }

    @Test("Dragging the outer edge inward past halfway narrows; short of it does not")
    func narrowingSnapsAtTheHalfwayPoint() {
        for columnWidth in columnWidths {
            let half = halfStep(columnWidth)
            let wide = PanelLayout.spanChoices.wide

            #expect(
                PanelLayout.snappedSpans(
                    from: wide, translation: -(half + 1),
                    columnWidth: columnWidth, opensLeft: false
                ) == PanelLayout.spanChoices.narrow
            )
            #expect(
                PanelLayout.snappedSpans(
                    from: wide, translation: -(half - 1),
                    columnWidth: columnWidth, opensLeft: false
                ) == wide
            )
        }
    }

    // MARK: - 4. The flip

    /// The handle sits on the edge that is not against the origin column, so
    /// for the column that opens left it is the *leading* edge and "drag it
    /// away from the card" is a leftward drag. Without the mirror a reader on
    /// Done would find the handle working backwards — and nothing on screen
    /// would explain why.
    @Test("A flipped panel's handle answers the mirrored drag, at every distance")
    func theFlippedHandleMirrors() {
        for columnWidth in columnWidths {
            for translation in stride(from: CGFloat(-900), through: 900, by: 37.5) {
                #expect(
                    PanelLayout.snappedSpans(
                        from: PanelLayout.spanChoices.wide, translation: translation,
                        columnWidth: columnWidth, opensLeft: true
                    ) == PanelLayout.snappedSpans(
                        from: PanelLayout.spanChoices.wide, translation: -translation,
                        columnWidth: columnWidth, opensLeft: false
                    )
                )
                #expect(
                    PanelLayout.snappedSpans(
                        from: PanelLayout.spanChoices.narrow, translation: translation,
                        columnWidth: columnWidth, opensLeft: true
                    ) == PanelLayout.snappedSpans(
                        from: PanelLayout.spanChoices.narrow, translation: -translation,
                        columnWidth: columnWidth, opensLeft: false
                    )
                )
            }
        }
    }

    /// And the flip is a real flip rather than a no-op: on the flipped edge a
    /// rightward drag has to *narrow*.
    @Test("On the flipped edge, dragging right narrows rather than widens")
    func theFlipIsNotANoOp() {
        for columnWidth in columnWidths {
            let far = columnWidth + Metric.gutter

            #expect(
                PanelLayout.snappedSpans(
                    from: PanelLayout.spanChoices.wide, translation: far,
                    columnWidth: columnWidth, opensLeft: true
                ) == PanelLayout.spanChoices.narrow
            )
            #expect(
                PanelLayout.snappedSpans(
                    from: PanelLayout.spanChoices.wide, translation: far,
                    columnWidth: columnWidth, opensLeft: false
                ) == PanelLayout.spanChoices.wide
            )
        }
    }

    // MARK: - 5. It cannot leave the two settings

    @Test("However far the drag goes, the result is one of the two settings")
    func theResultIsAlwaysASetting() {
        let allowed: Set<Int> = [PanelLayout.spanChoices.narrow, PanelLayout.spanChoices.wide]

        for columnWidth in columnWidths {
            for opensLeft in [true, false] {
                for spans in [PanelLayout.spanChoices.narrow, PanelLayout.spanChoices.wide] {
                    for translation in [CGFloat(-100_000), -1_000, -1, 1, 1_000, 100_000] {
                        #expect(
                            allowed.contains(
                                PanelLayout.snappedSpans(
                                    from: spans, translation: translation,
                                    columnWidth: columnWidth, opensLeft: opensLeft
                                )
                            )
                        )
                    }
                }
            }
        }
    }

    /// A window with no width is not a board. There is nothing to snap
    /// against, and inventing an answer would write a preference the reader
    /// never expressed.
    @Test("A board with no column width leaves the preference untouched")
    func noBoardNoDecision() {
        for spans in [1, 2, 3, 4] {
            for columnWidth in [CGFloat(0), -1, -500] {
                #expect(
                    PanelLayout.snappedSpans(
                        from: spans, translation: 400,
                        columnWidth: columnWidth, opensLeft: false
                    ) == spans
                )
            }
        }
    }

    // MARK: - 6. The width it actually produces

    /// The snap has to agree with the width the panel is then laid out at,
    /// which is the same function the board's row measures with. Two settings
    /// that snapped to widths nothing else drew would be a resize that never
    /// resized.
    @Test("Each setting snaps to the width the board lays the panel out at")
    func theSnapAgreesWithTheLayout() {
        for columnWidth in columnWidths {
            let narrow = PanelLayout.panelWidth(
                columnWidth: columnWidth, spans: PanelLayout.spanChoices.narrow
            )
            let wide = PanelLayout.panelWidth(
                columnWidth: columnWidth, spans: PanelLayout.spanChoices.wide
            )
            #expect(wide - narrow == columnWidth + Metric.gutter)

            // Dragging the outer edge by exactly one column-and-gutter lands on
            // the other setting rather than somewhere between.
            #expect(
                PanelLayout.snappedSpans(
                    from: PanelLayout.spanChoices.narrow,
                    translation: wide - narrow,
                    columnWidth: columnWidth,
                    opensLeft: false
                ) == PanelLayout.spanChoices.wide
            )
        }
    }
}
