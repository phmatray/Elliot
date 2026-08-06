import ElliotModel
import Foundation
import Testing

@testable import ElliotAppKit

/// Task 0 of #54 — "measure before building" — kept as arithmetic rather than
/// as a paragraph in a comment thread.
///
/// Criterion 2 of that issue asks that with the panel open at its default width
/// on a 1510pt window, all five columns stay reachable without horizontal
/// scrolling, "or the panel narrows until they are". The plan's Step 2 offered
/// to close the issue if a smaller constant made them fit.
///
/// **No constant makes them fit, and there is no longer a constant to shrink.**
/// The panel stopped being a fixed `Metric.inspectorWidth` and became a multiple
/// of the column width, and `columnWidth` divides the *whole* viewport among
/// five columns — so five columns and their gutters already consume the window
/// exactly, and any panel at all overflows it. The overflow is not a bad default
/// that could be tuned down; it is what the formula says at every width the app
/// allows. These tests pin that, so the next person to read criterion 2 gets the
/// number instead of the intention.
///
/// Nothing here asserts a pixel on screen — same discipline as `PanelLayoutTests`,
/// for the same reason: `swift test` cannot see layout, so it holds the numbers
/// the layout is built from.
@Suite("Panel fit")
struct PanelFitTests {

    /// The window criterion 2 names, and the two the app is actually bounded by.
    private let criterionWidth: CGFloat = 1510
    private let boardWidths: [CGFloat] = [1000, 1190, 1510, 1640, 2560]

    /// Five columns and six gutters come to the viewport exactly, whenever the
    /// 226pt floor is not binding.
    ///
    /// This is the whole finding in one line. `columnWidth` shares out the
    /// entire board width, so a shut board fits by construction and an open one
    /// cannot: there is no slack for the panel to occupy, at any window size.
    @Test("With the panel shut the row is exactly the viewport, so there is no slack to give it")
    func shutBoardExactlyFillsTheViewport() {
        for boardWidth in boardWidths where boardWidth >= 1190 {
            #expect(
                PanelLayout.contentWidth(boardWidth: boardWidth, spans: nil) == boardWidth,
                "at \(boardWidth)pt"
            )
        }
    }

    /// Below 1190pt the floor binds and the row is *wider* than the window even
    /// with the panel shut — the board already scrolls there, before any of this
    /// issue's arithmetic applies.
    @Test("Below the floor's hinge the shut board already overflows")
    func belowTheHingeTheShutBoardOverflows() {
        #expect(PanelLayout.contentWidth(boardWidth: 1000, spans: nil) > 1000)
        // 5 × 226 + 6 × 10.
        #expect(PanelLayout.contentWidth(boardWidth: 1000, spans: nil) == 1190)
    }

    /// Criterion 2's own window, with the numbers it asks about.
    ///
    /// 290pt columns, a 590pt panel at the narrow setting and 890pt at the wide
    /// one, against a 1510pt viewport: the row comes to 2110pt and 2410pt. The
    /// board overflows by 600pt at the setting criterion 2 calls "narrowed", and
    /// by 900pt at the default.
    @Test("At criterion 2's 1510pt window the row is 2110pt narrow and 2410pt wide")
    func theCriterionWindowOverflowsAtBothSettings() {
        let columnWidth = PanelLayout.columnWidth(boardWidth: criterionWidth)
        #expect(columnWidth == 290)

        let narrow = PanelLayout.contentWidth(
            boardWidth: criterionWidth, spans: PanelLayout.spanChoices.narrow
        )
        let wide = PanelLayout.contentWidth(
            boardWidth: criterionWidth, spans: PanelLayout.spanChoices.wide
        )
        #expect(narrow == 2110)
        #expect(wide == 2410)
        #expect(narrow - criterionWidth == 600)
        #expect(wide - criterionWidth == 900)
    }

    /// And it is not particular to 1510pt: neither setting fits at **any** width.
    ///
    /// Above the hinge the row grows as `1.4 × boardWidth − 4` narrow and
    /// `1.6 × boardWidth − 6` wide, so it outruns the viewport faster than the
    /// viewport grows — a wider window never catches up. Below the hinge the row
    /// is a constant 1662pt and 1892pt while the window is under 1190pt, so it
    /// cannot fit there either. Widening the window is not a workaround, which
    /// is what the user story asks for ("without dragging the window wider").
    @Test("Neither setting fits at any window width the app allows")
    func noWindowWidthFitsAnOpenPanel() {
        for boardWidth in boardWidths {
            for spans in [PanelLayout.spanChoices.narrow, PanelLayout.spanChoices.wide] {
                let content = PanelLayout.contentWidth(boardWidth: boardWidth, spans: spans)
                #expect(content > boardWidth, "\(spans) spans at \(boardWidth)pt fits, unexpectedly")
            }
        }
    }

    /// What criterion 2 would actually cost, stated as the number a human has to
    /// rule on rather than as a recommendation.
    ///
    /// To fit five columns *and* a narrow panel in 1510pt, the row's seven
    /// column-widths and eight gutters have to come to 1510 — which puts the
    /// column at 204pt against today's 226pt floor. The wide setting needs eight
    /// column-widths and nine gutters: 177pt.
    ///
    /// So criterion 2 is reachable only by lowering `Metric.minColumnWidth`,
    /// whose whole stated job is that "a card title needs about this much to stay
    /// readable". That is a legibility trade, not an implementation detail, which
    /// is why this test records the figure and changes nothing.
    @Test("Criterion 2 is reachable only by lowering the column floor, to 204pt or 177pt")
    func theCriterionCostsTheColumnFloor() {
        // Five columns plus the panel's spans, and one gutter for every gap:
        // one leading, one after each of the six slots, plus the panel's own
        // internal gutters.
        func floorThatWouldFit(spans: Int) -> CGFloat {
            let columnWidths = CGFloat(ElliotModel.Column.allCases.count + spans)
            let gutters = CGFloat(ElliotModel.Column.allCases.count + 2 + (spans - 1))
            return (criterionWidth - Metric.gutter * gutters) / columnWidths
        }

        let narrowFloor = floorThatWouldFit(spans: PanelLayout.spanChoices.narrow)
        let wideFloor = floorThatWouldFit(spans: PanelLayout.spanChoices.wide)

        #expect(abs(narrowFloor - 204.28) < 0.01)
        #expect(abs(wideFloor - 177.5) < 0.01)
        #expect(narrowFloor < Metric.minColumnWidth)
        #expect(wideFloor < Metric.minColumnWidth)

        // The arithmetic above is only trustworthy if it reproduces the real
        // formula, so: a board laid out at that floor does come to the window.
        let atNarrowFloor =
            CGFloat(ElliotModel.Column.allCases.count) * narrowFloor
            + PanelLayout.panelWidth(
                columnWidth: narrowFloor, spans: PanelLayout.spanChoices.narrow
            )
            + Metric.gutter * CGFloat(ElliotModel.Column.allCases.count + 2)
        #expect(abs(atNarrowFloor - criterionWidth) < 0.01)
    }
}
