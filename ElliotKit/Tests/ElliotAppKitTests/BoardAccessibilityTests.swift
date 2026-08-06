import ElliotModel
import Foundation
import Testing

@testable import ElliotAppKit

/// What a test can hold of the board's reduce-motion and VoiceOver behaviour.
///
/// Not the announcement itself: `swift test` cannot run VoiceOver, and this
/// project has paid four times for pretending a green suite says something about
/// the screen (#47, #50, #52, #53). Two things it *can* hold, and both were
/// unholdable until the views moved into `ElliotAppKit`:
///
/// 1. the **sentences** the board says, now that they are pure functions rather
///    than string literals inside a `body`;
/// 2. the **shape of the source** — that no animation in the app's views is
///    written without an answer to reduce motion. #79 states that as a `grep` a
///    maintainer runs by hand. A `grep` nobody runs is a rule nothing checks.
@Suite("Board accessibility")
struct BoardAccessibilityTests {

    // MARK: - 1. The five captions

    /// #79 asks for the five column captions to survive a panel being inserted
    /// between the columns. Over every case rather than a sample: the claim is
    /// about the set, and a sixth column added without a caption would draw
    /// perfectly and read as nothing.
    @Test("Every column keeps a caption that names it, counts it and states its rule")
    func everyColumnHasACaption() {
        for column in ElliotModel.Column.allCases {
            let caption = BoardAccessibility.columnCaption(
                name: column.displayName, count: 3, rule: column.standingRule
            )
            #expect(caption.hasPrefix(column.displayName))
            #expect(caption.contains("3 cards"))
            #expect(caption.hasSuffix(column.standingRule))
            // The rule is the longest part of the sentence and the one that
            // carries the meaning. A caption that is only a name and a number
            // is the caption this pass exists to keep from happening.
            #expect(caption.count > column.displayName.count + "3 cards. ".count)
        }
    }

    /// "1 cards" is the kind of thing that makes a careful product look
    /// careless, and it is *read aloud*. The group header had been written out
    /// in the singular and the column caption above it had not — the two labels
    /// on one column disagreed. One function, one spelling.
    @Test("One card is a card, in both captions")
    func singularIsWrittenOut() {
        #expect(
            BoardAccessibility.columnCaption(name: "To Do", count: 1, rule: "Files an issue.")
                == "To Do, 1 card. Files an issue."
        )
        #expect(
            BoardAccessibility.columnCaption(name: "To Do", count: 0, rule: "Files an issue.")
                == "To Do, 0 cards. Files an issue."
        )
        #expect(
            BoardAccessibility.groupCaption(repoName: "Elliot", count: 1, column: "Backlog")
                == "Elliot, 1 card in Backlog"
        )
        #expect(
            BoardAccessibility.groupCaption(repoName: "Elliot", count: 2, column: "Backlog")
                == "Elliot, 2 cards in Backlog"
        )
    }

    // MARK: - 1b. A move in the history

    /// The visible row is tabular; read field by field it would be four
    /// disconnected fragments. This is the same move as one sentence.
    @Test("A history row reads as a sentence naming both columns")
    func historyRowNamesBothColumns() {
        #expect(
            BoardAccessibility.historyRowLabel(
                from: "In Progress", to: "In Review", age: "3h ago",
                origin: "Elliot: the pull request went ready", run: nil)
                == "In Progress to In Review, 3h ago, Elliot: the pull request went ready"
        )
    }

    /// The clause is omitted rather than emptied. A move that started nothing
    /// must not be read out as having started something — the same rule the
    /// verdict block follows about never claiming more than was established.
    @Test("A history row mentions a run only when there is one")
    func historyRowOnlyClaimsARunItHas() {
        let started = BoardAccessibility.historyRowLabel(
            from: "Backlog", to: "To Do", age: "1d ago", origin: "Dragged",
            run: "create-issue")
        #expect(started == "Backlog to To Do, 1d ago, Dragged. Started create-issue")

        let inert = BoardAccessibility.historyRowLabel(
            from: "Backlog", to: "To Do", age: "1d ago", origin: "Dragged", run: nil)
        #expect(!inert.lowercased().contains("started"))
        #expect(inert == "Backlog to To Do, 1d ago, Dragged")
    }

    // MARK: - 2. What the panel announces

    /// The panel's announcement has to carry the **column**, not only the card.
    ///
    /// Everything else that says which column the panel belongs to is drawn: the
    /// caret notched into its edge, the tether across the gutter, the rail
    /// across its top. All three are `.accessibilityHidden(true)` on purpose —
    /// they are decoration for a relationship that has to be stated in words.
    /// This sentence is the statement, so the column cannot fall out of it.
    @Test("The panel announces the card and the column it belongs to")
    func panelLabelNamesBoth() {
        for column in ElliotModel.Column.allCases {
            let label = BoardAccessibility.panelLabel(title: "Inline detail panel", column: column)
            #expect(label == "Details for Inline detail panel, in \(column.displayName)")
            #expect(label.contains(column.displayName))
        }
    }

    // MARK: - 3. Reduce motion, as a property of the source

    /// #79's acceptance criterion 20, mechanised.
    ///
    /// Every `.animation`, `withAnimation` or `.transition` in `ElliotAppKit`
    /// must answer to reduce motion in one of three ways, and the third is the
    /// one that needs the test:
    ///
    /// - it is written `reduceMotion ? nil : …` where it stands;
    /// - it is `.animation(nil, …)`, which is off for everyone and therefore
    ///   *stricter* than reduce motion asks for;
    /// - it is a `.transition` with no animation of its own, driven by a gated
    ///   `.animation(…, value:)` above it — in which case a comment beside it
    ///   has to name that gate. A transition cannot state its own gate, so the
    ///   only place the claim can live is prose, and prose that is checked is
    ///   worth more than prose that is not.
    ///
    /// The failure message is the file, the line and the text, because the fix
    /// is never "add a gate here" without reading what drives it.
    ///
    /// ⚠️ **What this cannot catch, measured rather than guessed.** Run against
    /// a deliberately broken tree — `CardView`'s transition ungated — it caught
    /// it only once the comment above it went too: a comment naming reduce
    /// motion excuses the line below it, so a gate *removed while its comment
    /// stayed* reads as gated. That is inherent to admitting the third case at
    /// all, since a transition cannot state its own gate. It bounds the claim:
    /// this suite catches an animation written **without** an answer, not one
    /// whose answer went stale. Nothing here replaces switching reduce motion
    /// on and selecting a card.
    @Test("Every animation in the app's views answers to reduce motion")
    func everyAnimationAnswersToReduceMotion() throws {
        let sites = try Self.motionSites()

        // A scan that finds nothing passes, and looks exactly like a scan that
        // found everything — the same failure `swift test --filter` has on a
        // name that matches no test. This is the count as of #79; it is a floor,
        // not a pin, so adding a gated animation does not break it.
        #expect(
            sites.count >= 12,
            "found \(sites.count) animation sites — the scan is looking in the wrong place"
        )

        for site in sites where !Self.answersToReduceMotion(site) {
            Issue.record(
                """
                \(site.file):\(site.line) animates with no answer to reduce motion:
                    \(site.text)
                Either write it `reduceMotion ? nil : …`, or — if a gated \
                `.animation(…, value:)` above it is what drives it — say which \
                one in a comment beside it.
                """
            )
        }
    }

    // MARK: - The scan

    /// One `.animation`, `withAnimation` or `.transition` written in the app's
    /// views, with the comment block immediately above it.
    private struct MotionSite {
        var file: String
        var line: Int
        var text: String
        /// Only the comment lines just above, which is where a transition's
        /// gate can be named. Filtering to comments is what keeps an unrelated
        /// `reduceMotion` a few lines up from excusing an ungated animation.
        var preamble: [String]
    }

    /// Where the views live, found from this file rather than from the working
    /// directory — `swift test` promises nothing about the latter.
    private static var viewSources: URL {
        URL(filePath: #filePath)          // …/Tests/ElliotAppKitTests/<this file>
            .deletingLastPathComponent()  // …/Tests/ElliotAppKitTests
            .deletingLastPathComponent()  // …/Tests
            .deletingLastPathComponent()  // …/ElliotKit
            .appending(path: "Sources/ElliotAppKit")
    }

    private static func motionSites() throws -> [MotionSite] {
        let directory = viewSources
        let names = try FileManager.default
            .contentsOfDirectory(atPath: directory.path(percentEncoded: false))
            .filter { $0.hasSuffix(".swift") }
            .sorted()

        var sites: [MotionSite] = []
        for name in names {
            let source = try String(
                contentsOf: directory.appending(path: name), encoding: .utf8
            )
            let lines = source.components(separatedBy: "\n")
            for (index, raw) in lines.enumerated() {
                let line = raw.trimmingCharacters(in: .whitespaces)
                // A doc comment that *mentions* an animation is prose, not an
                // animation. `PanelLayout` opens with one, and counting it
                // would make this suite demand a gate on a sentence.
                guard !line.hasPrefix("//") else { continue }
                guard line.contains(".animation(")
                    || line.contains("withAnimation(")
                    || line.contains(".transition(")
                else { continue }

                let preamble = lines[max(0, index - 10)..<index]
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { $0.hasPrefix("//") }

                sites.append(
                    MotionSite(file: name, line: index + 1, text: line, preamble: preamble)
                )
            }
        }
        return sites
    }

    private static func answersToReduceMotion(_ site: MotionSite) -> Bool {
        // Gated where it stands.
        if squashed(site.text).contains("reducemotion") { return true }
        // Off for everyone, which is more than reduce motion asks for.
        if site.text.contains(".animation(nil") { return true }
        // Driven by a gated animation elsewhere, and named as such right here.
        return site.preamble.contains { squashed($0).contains("reducemotion") }
    }

    /// So that "reduce motion" in prose and `reduceMotion` in code are the same
    /// claim. They are.
    private static func squashed(_ text: String) -> String {
        text.lowercased().filter { !$0.isWhitespace }
    }
}
