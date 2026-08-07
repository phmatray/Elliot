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
        var passes = 0
        var card: CGRect?
        var list: CGRect?
        var panel: CGRect?

        var ran: Bool { passes > 0 }

        /// Accumulates rather than assigns, and that is not tidiness.
        ///
        /// A preference-driven overlay builder runs more than once per render,
        /// and the first pass classically carries `defaultValue` — all three
        /// nil — before the writers have propagated. Straight assignment is
        /// last-writer-wins, so a trailing nil pass would erase what an earlier
        /// one saw. That is an intermittent red bar on the positive tests, and
        /// something worse on the negative ones: `card == nil` is the *evidence*
        /// that the ancestor form loses the anchor, so a spurious nil would let
        /// the regression detector report success without having observed the
        /// regression at all.
        func record(card: CGRect?, list: CGRect?, panel: CGRect?) {
            passes += 1
            self.card = card ?? self.card
            self.list = list ?? self.list
            self.panel = panel ?? self.panel
        }
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
        // A `ScrollView` whose content is twice its frame, because the claim
        // "the list reports its **viewport**, not its content" is the one thing
        // a plain fixed-height container cannot test: make the two the same
        // height and `list.contains(card)` holds by construction and would hold
        // just as well if the anchor measured the wrong thing. 600pt of content
        // in a 300pt frame makes the two rectangles genuinely different.
        let column = ScrollView {
            VStack(spacing: 0) {
                Color.clear.frame(height: 80)
                Color.red
                    .frame(width: 100, height: 40)
                    .reportsCaretAnchor { CaretAnchors(card: $0) }
                Color.clear.frame(height: 480)
            }
        }
        .frame(width: 120, height: 300)

        let panel = Color.blue
            .frame(width: 200, height: 300)
            .reportsCaretAnchor { CaretAnchors(panel: $0) }

        let row = HStack(spacing: 0) {
            Group {
                if listReportsThroughBackground {
                    // Today's shape, through the production helper itself — so
                    // this exercises `reportsCaretAnchor` rather than a local
                    // imitation of it that could drift from the real one.
                    column.reportsCaretAnchor { CaretAnchors(list: $0) }
                } else {
                    // #159's shape: the modifier sits on an ancestor of the card.
                    // Spelled out here rather than reached through the helper,
                    // because the helper exists precisely to make it unwritable.
                    column.anchorPreference(key: CaretAnchorKey.self, value: .bounds) {
                        CaretAnchors(list: $0)
                    }
                }
            }
            panel
        }
        .overlayPreferenceValue(CaretAnchorKey.self) { anchors in
            GeometryReader { proxy in
                let _ = seen.record(
                    card: anchors.card.map { proxy[$0] },
                    list: anchors.list.map { proxy[$0] },
                    panel: anchors.panel.map { proxy[$0] }
                )
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
    func theRectanglesAreTheRightOnes() throws {
        let seen = render(listReportsThroughBackground: true)
        // `try #require` and not `if let`: an optional binding turns a missing
        // anchor into a *skipped* assertion, so the two claims below — the ones
        // that distinguish "measured the viewport" from "measured the content"
        // — would quietly stop running rather than fail.
        let card = try #require(seen.card)
        let list = try #require(seen.list)
        let panel = try #require(seen.panel)

        // Resolved by one proxy, so these are comparable by construction —
        // that is the property anchors were chosen for over stored measurements.
        #expect(card.size == CGSize(width: 100, height: 40))
        #expect(panel.size == CGSize(width: 200, height: 300))

        // The viewport, not the content. The column scrolls 600pt of content
        // through a 300pt frame, so a `.background` that measured its content
        // would report 600 here and still satisfy every "did it arrive" check.
        #expect(list.size == CGSize(width: 120, height: 300))
        #expect(list.contains(card), "the card is not inside the viewport reported for it")
        // And the panel really is the neighbour, not the column over again.
        #expect(panel.minX >= list.maxX)
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
    /// prove the rule and not the board: point any writer back at an ancestor
    /// and every one of them stays green. This reads the source, the way
    /// `DrainDuplicationTests` does, because what has to be held here is a
    /// **shape** — and a shape is not something a value assertion can see.
    ///
    /// The claim is deliberately not "there is a `.background` near the
    /// writer". A first draft asserted exactly that and it was worth very
    /// little: the most natural way to bring #159 back is to leave the
    /// `.background` in place and move the modifier out of it, which that
    /// version passed. What is checkable without guessing at brace depth is
    /// **who writes the key at all** — one helper does, and the helper is
    /// wrapped correctly by construction.
    @Test("The caret's key is written only by reportsCaretAnchor")
    func theKeyHasExactlyOneWriter() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // ElliotAppKitTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // ElliotKit
            .appendingPathComponent("Sources/ElliotAppKit")

        let files = try FileManager.default
            .contentsOfDirectory(atPath: sources.path)
            .filter { $0.hasSuffix(".swift") }
            .sorted()

        var writers: [String] = []
        for file in files {
            let text = try String(
                contentsOf: sources.appendingPathComponent(file), encoding: .utf8)
            for (offset, line) in text.components(separatedBy: "\n").enumerated() {
                // Comments are stripped before matching, so a gate about code
                // cannot be tripped by prose describing it — and the prose
                // around these call sites names the key repeatedly.
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard !trimmed.hasPrefix("//"), !trimmed.hasPrefix("///") else { continue }
                if line.contains("anchorPreference(key: CaretAnchorKey") {
                    writers.append("\(file):\(offset + 1)")
                }
            }
        }

        #expect(
            writers == ["CaretRail.swift:\(Self.helperLine)"],
            """
            `CaretAnchorKey` is written somewhere other than `reportsCaretAnchor`: \
            \(writers.joined(separator: ", ")).

            A bare `.anchorPreference` is correct on a leaf and quietly wrong on a \
            container — applied to an ancestor of another writer it REPLACES that \
            writer's value instead of merging with it, and `reduce` is never called \
            for the pair. That is #159: the selected card's rectangle was discarded \
            one level below the overlay, `isDetached` answered true for ever, the \
            tether drew at opacity 0 and the caret sat faint at the panel's middle — \
            with a green build and a green suite behind it. Report through \
            `reportsCaretAnchor`, which wraps the modifier in a `.background` so the \
            writers stay siblings.
            """
        )
    }

    /// The one line the test above expects, resolved rather than hardcoded, so
    /// editing `CaretRail.swift` above the helper does not fail this suite with
    /// a message about #159.
    private static var helperLine: Int {
        let file = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/ElliotAppKit/CaretRail.swift")
        let text = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
        let index = text.components(separatedBy: "\n").firstIndex {
            $0.contains("anchorPreference(key: CaretAnchorKey")
                && !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//")
        }
        return (index ?? -1) + 1
    }

    @Test("Losing only the card is enough to detach the whole decoration")
    func aMissingCardDetaches() throws {
        let broken = render(listReportsThroughBackground: false)
        let list = try #require(broken.list)

        // `isDetached` returns true on its first `guard` for a nil card, so the
        // tether drops out and the caret goes faint. One missing rectangle, and
        // nothing arithmetic to blame.
        //
        // What those two opacities *are* is not restated here. `PanelLayoutTests`
        // already pins them, and deliberately as a range (`detachedCaret > 0`,
        // `< 0.5`) so the weight can be tuned without a test edit. Repeating it
        // as an exact 0.35 would put a second, stricter owner on the constant in
        // the file least about it — changing it to 0.3 would leave its real
        // suite green and fail one named for preference delivery.
        #expect(
            PanelLayout.isDetached(
                cardMidY: broken.card?.midY, listTop: list.minY, listBottom: list.maxY)
        )
    }
}
