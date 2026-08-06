import ElliotModel
import Foundation
import Testing

@testable import ElliotAppKit

/// The lens's mark, on the card.
///
/// What this suite can hold is not that the emoji is on screen — nothing in
/// `swift test` can see that, and this project has paid four times for
/// pretending otherwise (#47, #50, #52, #53). What it can hold is that the mark
/// is never drawn unnamed: six emoji are not self-describing, and a card is one
/// combined accessibility element, so an unlabelled `Text(angle.symbol)` is read
/// aloud as whatever the system happens to call the character.
@Suite("The lens's mark on a card")
struct CardAngleMarkTests {

    /// Where the views live, found from this file rather than from the working
    /// directory — `swift test` promises nothing about the latter.
    private static var viewSources: URL {
        URL(filePath: #filePath)          // …/Tests/ElliotAppKitTests/<this file>
            .deletingLastPathComponent()  // …/Tests/ElliotAppKitTests
            .deletingLastPathComponent()  // …/Tests
            .deletingLastPathComponent()  // …/ElliotKit
            .appending(path: "Sources/ElliotAppKit")
    }

    /// The requirement is *a name*, not a particular way of giving one.
    ///
    /// The Analysis window draws `Text(angle.symbol)` with `angle.title` as a
    /// sibling on the next line, in all three of its sites — the mark and its
    /// name are two elements in a row, so the name is already read. `CardView`
    /// cannot do that: the text beside the mark there is the *card's* title, and
    /// a card is one combined accessibility element, so its mark has to carry
    /// `.accessibilityLabel`.
    ///
    /// Demanding the label everywhere — which is what this scan did when it was
    /// first written — flagged both Analysis-window sites, which are not broken.
    /// So the rule is the one that is actually true of all of them: a lens's
    /// mark is never drawn without its name within reach, by either route.
    @Test("Every angle.symbol drawn in a view is given the lens's name")
    func everySymbolIsNamed() throws {
        let directory = Self.viewSources
        let names = try FileManager.default
            .contentsOfDirectory(atPath: directory.path(percentEncoded: false))
            .filter { $0.hasSuffix(".swift") }
            .sorted()

        var sites = 0
        for name in names {
            let source = try String(
                contentsOf: directory.appending(path: name), encoding: .utf8
            )
            let lines = source.components(separatedBy: "\n")
            for (index, raw) in lines.enumerated() {
                let line = raw.trimmingCharacters(in: .whitespaces)
                guard !line.hasPrefix("//"),
                    line.contains("angle?.symbol") || line.contains("angle.symbol")
                else { continue }
                sites += 1
                // The name may sit on the same line or on one of the modifiers
                // just below it — counted in *code* lines, with comments
                // dropped first. A fixed span of raw lines was the first
                // version and it failed on `CardView`'s own site: the four
                // lines explaining why the label is needed pushed the label
                // itself out of the window, so the scan reported the one place
                // that had been done properly. Comments are dense in this
                // repository; a rule that a comment can break is the wrong rule.
                let window = lines[index..<min(lines.count, index + 12)]
                    .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
                    .prefix(4)
                    .joined(separator: "\n")
                // A name is either an accessibility label, or the lens's title
                // drawn as a visible sibling — which is what the Analysis
                // window does in all three of its sites.
                //
                // `.help(angle.title)` is neither, and excluding it is not
                // pedantry: it was the first version of this check, it passed
                // `CardView` with its `.accessibilityLabel` deleted, and a
                // tooltip is invisible to VoiceOver — the one reader this test
                // exists for. A rule a hover can satisfy proves nothing about
                // what gets read aloud.
                let visibleName = window
                    .components(separatedBy: "\n")
                    .contains { $0.contains("angle.title") && !$0.contains(".help(") }
                let named = window.contains(".accessibilityLabel(") || visibleName
                if !named {
                    Issue.record(
                        """
                        \(name):\(index + 1) draws a lens's mark with no name within reach:
                            \(line)
                        Six emoji are not self-describing. Either draw \
                        `angle.title` beside it, as the Analysis window does, or \
                        add `.accessibilityLabel(angle.title)` — which is what a \
                        card needs, being one combined accessibility element.
                        """
                    )
                }
            }
        }

        // A scan that finds nothing passes and looks exactly like a scan that
        // found everything. CardView is one site; the Analysis window's three
        // are not required to be labelled here, but they are counted, so a
        // scan looking in the wrong directory fails loudly.
        #expect(sites >= 1, "found \(sites) sites — the scan is looking in the wrong place")
    }

    /// The other half, and the one a reader of the card cares about: a card
    /// with no lens must draw nothing at all — not a placeholder, not a
    /// reserved gutter. Held as source shape because it is a layout claim: the
    /// mark is inside an `if let`, so "nothing" is structural rather than a
    /// glyph that happens to be blank.
    @Test("The mark is drawn only when there is a lens")
    func markIsConditional() throws {
        let source = try String(
            contentsOf: Self.viewSources.appending(path: "CardView.swift"), encoding: .utf8
        )
        #expect(source.contains("if let angle = card.angle"))
        #expect(source.contains("angle.symbol"))
    }

    /// Six lenses, six names — the label is only worth having if it says
    /// something different each time.
    ///
    /// `everySymbolIsNamed` proves a name is *present*; this proves the names
    /// distinguish. A `title` that returned the same string for two lenses
    /// would satisfy the scan above and still read both marks identically
    /// aloud, which is the failure the label exists to prevent.
    @Test("Every lens names itself, and no two share a name")
    func everyLensHasADistinctName() {
        let titles = AnalysisAngle.allCases.map(\.title)
        #expect(titles.allSatisfy { !$0.trimmingCharacters(in: .whitespaces).isEmpty })
        #expect(Set(titles).count == AnalysisAngle.allCases.count)
    }
}
