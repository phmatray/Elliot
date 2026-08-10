import Foundation
import Testing

/// One ranking, drawn once, and the drawing can refuse.
///
/// #304's finding was not that the Operations band was ugly — it was that the
/// same `rankNextSteps` answer was rendered in two files with **different
/// behaviour**. `NextStepsView`'s rows were buttons through
/// `model.move(cardID:to:)` guarded by `.disabled(consequence.isRefused)`;
/// `OperationsView`'s were inert `HStack`s that read `isRefused` for a colour and
/// offered nothing. Both looked correct in their own file, and the copy had
/// already lost the guard.
///
/// A source gate for the reason `CLAUDE.md` gives and `DefaultActionTests`,
/// `DrainDuplicationTests` and `CaretAnchorTests` already act on: `swift test`
/// cannot press a button, so deleting `.disabled(…)` here leaves every
/// behavioural test in the package green while a row that a move would refuse
/// becomes pressable — and pressing an Up next row is a real move through
/// `BoardService`, three of whose five transitions start an unattended `claude
/// -p` at `bypassPermissions` inside a real checkout.
@Suite("The Up next band's source")
struct UpNextBandSourceTests {

    private static var viewSources: URL {
        URL(fileURLWithPath: #filePath)   // …/Tests/ElliotAppKitTests/<this file>
            .deletingLastPathComponent()  // …/Tests/ElliotAppKitTests
            .deletingLastPathComponent()  // …/Tests
            .deletingLastPathComponent()  // …/ElliotKit
            .appendingPathComponent("Sources/ElliotAppKit")
    }

    /// A file with its `//` comments cut away.
    ///
    /// ⚠️ Load-bearing, and the trap this kind of test walks into. Both files
    /// read here *document* the rule at length — `UpNextBand` explains why the
    /// `.disabled` is there and `OperationsView` explains what it stopped
    /// drawing — so a gate matching raw text would be satisfied, or tripped, by
    /// the explanation of the very rule it enforces.
    private static func code(_ name: String) throws -> String {
        let text = try String(
            contentsOf: viewSources.appendingPathComponent(name), encoding: .utf8)
        return text.components(separatedBy: "\n")
            .map { line -> String in
                guard let comment = line.range(of: "//") else { return line }
                return String(line[line.startIndex..<comment.lowerBound])
            }
            .joined(separator: "\n")
    }

    // MARK: - 1. The row can refuse

    @Test("A row the rules refuse is not pressable")
    func aRefusedRowIsDisabled() throws {
        let band = try Self.code("UpNextBand.swift")

        // A negative needs its positive witness: a renamed band, or one that
        // stopped acting at all, would make the claim below vacuously true.
        #expect(
            band.contains("model.move(cardID: step.card.id, to: step.to)"),
            """
            UpNextBand no longer moves a card. Either it has been renamed — in which case this \
            gate has silently stopped covering anything — or the acting half of #304 has been \
            undone and the band is a preview again
            """)

        #expect(
            band.contains(".disabled(consequence.isRefused)"),
            """
            the Up next row has lost its guard. `Consequence.isRefused` is `evaluateMove`'s \
            verdict, and a row without this modifier is a live button on a move BoardService \
            will refuse — or worse, one it will not. Stating the refusal in the row's sentence \
            is not the same as declining to offer it (#304)
            """)
    }

    /// ⛔ Not a style rule. Inside the board window Return is already contested —
    /// `DefaultAction` names the three controls allowed to claim it and the two
    /// deliberately denied — and a control that *moves a card* is exactly what
    /// must not become what Return does by accident. `DefaultActionTests` catches
    /// `.defaultAction` specifically; this catches the whole family, because a
    /// scoped-looking `.keyboardShortcut(.return)` on a row is the same key.
    @Test("Nothing in the band claims a keyboard shortcut")
    func theBandClaimsNoKey() throws {
        #expect(!(try Self.code("UpNextBand.swift")).contains(".keyboardShortcut("))
    }

    // MARK: - 2. Drawn once

    /// ⛔ **Operations renders the band; it does not word a move of its own.**
    ///
    /// `Consequence.of` is how a move's sentence, tint and refusal are decided,
    /// and this screen calling it is the signature of the defect: it means a step
    /// is being rendered somewhere other than the one place that knows to refuse
    /// it. Scoped to this file rather than banned across `ElliotAppKit`, because
    /// the board's own columns and cards legitimately caption moves — it is
    /// *this* screen that had a second copy of the ranking.
    @Test("The Operations screen draws the ranking through the band, never itself")
    func operationsHoldsNoSecondDrawing() throws {
        let operations = try Self.code("OperationsView.swift")

        #expect(
            operations.contains("UpNextBand()"),
            "OperationsView no longer renders UpNextBand — the Up next band has lost its body")

        #expect(
            !operations.contains("Consequence.of("),
            """
            OperationsView is wording a move itself. That is the shape #304 removed: this screen \
            drew its own Up next rows, and the copy dropped `.disabled(consequence.isRefused)` \
            while the original kept it. The ranking is UpNextBand's, once
            """)

        #expect(
            !operations.contains("model.nextSteps"),
            """
            OperationsView is reading the ranking directly. `AppModel.nextSteps` is the \
            *unfiltered* board — what `board_next` answers — while the band renders \
            `nextStepsView`, which the repository picker and the blocked toggle have narrowed. \
            Mixing the two is what made "See all 12" open a list of four (#304)
            """)
    }
}
