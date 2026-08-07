import Foundation
import SwiftUI
import Testing

@testable import ElliotAppKit

/// The step between the three `anchorPreference` writers and the one
/// `overlayPreferenceValue` reader.
///
/// This is the link #159 broke, and the reason it went unnoticed for two
/// releases is written into the defect itself: **every part on either side of it
/// was already tested and green.** `PanelLayoutTests` pins `caretY`,
/// `isDetached`, `tetherReach` and all of `CaretMetric`; `CaretAnchorKey.reduce`
/// is three lines anyone can read; `CaretRail.body` places what those functions
/// return. Not one of them was wrong. The card's rectangle simply never arrived,
/// so the whole proven apparatus was fed `nil` and drew — correctly — the
/// decoration for a card that is not there.
///
/// So the claim here is not arithmetic. It is that a board-shaped view hierarchy
/// actually **delivers** three anchors to its overlay, which needs a real layout
/// pass to answer. `ImageRenderer` gives one without a window, a store or a
/// running app, which is what makes it a `swift test` claim rather than a
/// comment asking the next reader to be careful.
///
/// ### The rule these tests exist to hold
///
/// Every writer for `CaretAnchorKey` must be a **sibling** of the others.
/// `reduce` merges siblings and is the entire defence for the three-subtree
/// design — and it is no defence at all one level up, because
/// `.anchorPreference` on a view that is an *ancestor* of another writer
/// replaces that writer's value outright and `reduce` is never called for the
/// pair. `ColumnView.list` was that ancestor: it wrote `list` on the
/// `ScrollView` containing the cards.
@MainActor
@Suite("Caret anchors reaching the overlay")
struct CaretAnchorTests {

    /// What the overlay saw, captured out of a real layout pass.
    ///
    /// `@unchecked Sendable` because it is written and read on the main actor
    /// inside one synchronous `ImageRenderer` render, never handed across a
    /// boundary.
    private final class Seen: @unchecked Sendable {
        var ran = false
        var card: CGRect?
        var list: CGRect?
        var panel: CGRect?
    }

    /// The board's row in miniature, using the **real** `CaretAnchors` and
    /// `CaretAnchorKey` rather than stand-ins — a column whose viewport reports
    /// its own rectangle, one selected card inside it, and the panel beside it.
    ///
    /// `listReportsThroughBackground` is the whole variable under test: `true`
    /// is what `ColumnView.list` does now, `false` is what it did when #159
    /// shipped.
    private func render(listReportsThroughBackground: Bool) -> Seen {
        let seen = Seen()

        // The column: a card inside a container that also reports the viewport.
        //
        // The card's position is chosen, not incidental. It spans 80…120, so its
        // mid-height is **100** — and both neighbouring values are wrong on
        // purpose:
        //
        // - not within 26pt of either end, because `PanelLayout.caretY` clamps
        //   the caret that far clear of the panel's rounded corners, and a card
        //   inside the clamp reports a y that legitimately is not its own
        //   mid-height. (The clamp is `PanelLayoutTests`' claim, not this
        //   suite's.)
        // - not the panel's own mid-height of 150, which is the value
        //   `CaretRail` falls back to when the card is missing. Centre the card
        //   and the two coincide, and the assertion that the fallback was *not*
        //   taken silently stops being able to tell the difference — which is
        //   the same shape of hole this whole suite exists to close.
        let column = VStack(spacing: 0) {
            Color.clear.frame(height: 80)
            Color.red
                .frame(width: 100, height: 40)
                .anchorPreference(key: CaretAnchorKey.self, value: .bounds) {
                    CaretAnchors(card: $0)
                }
            Spacer()
        }
        .frame(width: 120, height: 300)

        let panel = Color.blue
            .frame(width: 200, height: 300)
            .anchorPreference(key: CaretAnchorKey.self, value: .bounds) {
                CaretAnchors(panel: $0)
            }

        let row = HStack(spacing: 0) {
            Group {
                if listReportsThroughBackground {
                    // Today's shape. A background is a separate subtree, so the
                    // card's contribution is never in a position to be replaced.
                    column.background {
                        Color.clear
                            .anchorPreference(key: CaretAnchorKey.self, value: .bounds) {
                                CaretAnchors(list: $0)
                            }
                    }
                } else {
                    // #159's shape: the modifier sits on an ancestor of the card.
                    column.anchorPreference(key: CaretAnchorKey.self, value: .bounds) {
                        CaretAnchors(list: $0)
                    }
                }
            }
            panel
        }
        .overlayPreferenceValue(CaretAnchorKey.self) { anchors in
            GeometryReader { proxy in
                let _ = {
                    seen.ran = true
                    seen.card = anchors.card.map { proxy[$0] }
                    seen.list = anchors.list.map { proxy[$0] }
                    seen.panel = anchors.panel.map { proxy[$0] }
                }()
                Color.clear
            }
        }
        .frame(width: 320, height: 300)

        _ = ImageRenderer(content: row).nsImage
        return seen
    }

    // MARK: - The link itself

    @Test("A card, its list and the panel all reach the overlay together")
    func allThreeAnchorsArrive() {
        let seen = render(listReportsThroughBackground: true)

        #expect(seen.ran, "the overlay never ran — no layout pass happened")
        #expect(seen.card != nil, "the selected card's rectangle did not reach the overlay")
        #expect(seen.list != nil, "the column's viewport did not reach the overlay")
        #expect(seen.panel != nil, "the panel's rectangle did not reach the overlay")
    }

    @Test("The three rectangles are the ones their owners actually occupy")
    func theRectanglesAreTheRightOnes() {
        let seen = render(listReportsThroughBackground: true)

        // Resolved by one proxy, so these are comparable by construction —
        // that is the property anchors were chosen for over stored measurements.
        #expect(seen.card?.size == CGSize(width: 100, height: 40))
        #expect(seen.list?.size == CGSize(width: 120, height: 300))
        #expect(seen.panel?.size == CGSize(width: 200, height: 300))

        // The list reports the viewport it backs, not the card inside it. A
        // `.background` that measured its content instead would pass the
        // "did it arrive" test above and still detach every card.
        if let card = seen.card, let list = seen.list {
            #expect(list.contains(card), "the card is not inside the viewport reported for it")
        }
        // And the panel really is the neighbour, not the column over again.
        if let list = seen.list, let panel = seen.panel {
            #expect(panel.minX >= list.maxX)
        }
    }

    @Test("Three arriving anchors draw the attached caret, not the detached one")
    func threeAnchorsMeanAttached() throws {
        let seen = render(listReportsThroughBackground: true)
        let card = try #require(seen.card)
        let list = try #require(seen.list)
        let panel = try #require(seen.panel)

        // The same two functions `CaretRail.body` calls, on the rectangles the
        // overlay was actually handed. This is the composition that failed: the
        // functions were right and their input was not.
        #expect(
            PanelLayout.isDetached(
                cardMidY: card.midY, listTop: list.minY, listBottom: list.maxY) == false,
            "a card sitting inside its viewport was judged out of band"
        )

        // The caret lands at the card's mid-height rather than the panel's
        // middle — the `?? panel.midY` fallback is the detached answer, and
        // taking it while a card is on screen is exactly what #159 looked like.
        // The geometry is arranged so these two are different numbers (100 and
        // 150); see `render`.
        let y = panel.minY + PanelLayout.caretY(
            cardMidY: card.midY,
            panelMinY: panel.minY,
            panelHeight: panel.height
        )
        #expect(card.midY != panel.midY, "the geometry can no longer tell the fallback apart")
        #expect(y == card.midY)
        #expect(y != panel.midY)
    }

    // MARK: - The regression, stated as a rule

    @Test("A writer placed above another writer replaces it — this is #159")
    func anAncestorWriterReplacesItsSubtree() {
        // The shape that shipped. Kept as a test rather than a comment because
        // the broken version is indistinguishable from the working one by
        // reading: both compile, both are three plausible lines, and the whole
        // suite was green while this one was live.
        let broken = render(listReportsThroughBackground: false)

        #expect(broken.ran)
        #expect(
            broken.card == nil,
            """
            The ancestor form no longer loses the card's anchor. That is a change \
            in SwiftUI's preference semantics, not a fix — re-read \
            ColumnView.list before relaxing anything on the strength of it.
            """
        )
        // The other two still arrive, which is precisely why the defect was so
        // hard to see: the panel is present, so `CaretRail` draws, and it draws
        // the honest picture of a caret with no card.
        #expect(broken.list != nil)
        #expect(broken.panel != nil)
    }

    // MARK: - And that the board itself is built the safe way

    /// The behavioural tests above build a *miniature* of the board, so they
    /// prove the rule and not the board: revert `ColumnView.list` to the
    /// ancestor form and every one of them stays green. This reads the source,
    /// the way `DrainDuplicationTests` does, because what has to be held here is
    /// a **shape** — and a shape is not something a value assertion can see.
    @Test("ColumnView reports its viewport from a background, not from above the cards")
    func theColumnsWriterIsNotAnAncestorOfTheCards() throws {
        let board = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // ElliotAppKitTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // ElliotKit
            .appendingPathComponent("Sources/ElliotAppKit/BoardView.swift")
        let lines = try String(contentsOf: board, encoding: .utf8).components(separatedBy: "\n")

        let writers = lines.indices.filter { lines[$0].contains("CaretAnchors(list:") }
        #expect(
            writers.count == 1,
            "expected exactly one writer of the list anchor, found \(writers.count)"
        )

        for index in writers {
            // Walk back over the handful of code lines above the writer. The
            // `.background {` wrapper must be among them; if the modifier is
            // applied straight to the container again, it will not be.
            let start = max(0, index - 8)
            let preceding = lines[start..<index]
                .filter { line in
                    let trimmed = line.trimmingCharacters(in: .whitespaces)
                    return !trimmed.hasPrefix("//") && !trimmed.isEmpty
                }
            #expect(
                preceding.contains { $0.contains(".background {") },
                """
                The column's viewport anchor is written without a `.background` wrapper, \
                which puts it on an ancestor of the CardViews — and an ancestor's \
                `.anchorPreference` replaces its subtree's value instead of merging with \
                it. That is #159 exactly: the selected card's rectangle is discarded one \
                level below the overlay, `isDetached` answers true for ever, and the \
                tether draws at opacity 0 while the caret drifts to the panel's middle at \
                0.35. Everything still compiles and every arithmetic test still passes.
                """
            )
        }
    }

    @Test("Losing only the card is enough to detach the whole decoration")
    func aMissingCardDetaches() throws {
        let broken = render(listReportsThroughBackground: false)
        let list = try #require(broken.list)

        // `isDetached` returns true on its first `guard` for a nil card, so the
        // tether goes to opacity 0 and the caret to 0.35 — invisible and nearly
        // invisible. One missing rectangle, and nothing arithmetic to blame.
        #expect(
            PanelLayout.isDetached(
                cardMidY: broken.card?.midY, listTop: list.minY, listBottom: list.maxY)
        )
        #expect(CaretMetric.detachedTether == 0)
        #expect(CaretMetric.detachedCaret == 0.35)
    }
}
