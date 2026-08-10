import AppKit
import Foundation
import Testing

@testable import ElliotAppKit

/// The auto-dev mark, on the card.
///
/// The same bound `CardAngleMarkTests` states one file over: nothing in
/// `swift test` can see that a glyph is on screen, and this project has paid
/// four times for pretending otherwise (#47, #50, #52, #53). What a test *can*
/// hold is that the symbol resolves at all, **where** in the source the mark is
/// drawn, and **what decides** whether it is drawn. All three matter here:
/// "title row, not facts row" is the design decision, and the two rows behave
/// differently.
///
/// ⚠️ **Every gate below reads the file with comments cut** — `HiddenFaceState
/// .code(of:)`. This file's subject is documented at length in `CardView.swift`
/// itself, so a raw-text scan would be satisfied by the paragraph *explaining*
/// the rule and the obvious way to make a red one pass would be to delete the
/// explanation. That is the trap `HiddenFaceState`'s own header records, met
/// again here.
@Suite("The auto-dev mark on a card")
struct AutoDevCardMarkTests {

    /// A symbol name that does not resolve draws **nothing** and errors
    /// nowhere — a member of this repository's family of mechanisms that
    /// substitute different behaviour instead of saying no. One line of
    /// measurement closes it.
    @Test("The mark's symbol exists on this system")
    func symbolResolves() {
        #expect(
            NSImage(systemSymbolName: AutoDevBand.engagedSymbol, accessibilityDescription: nil)
                != nil,
            "\(AutoDevBand.engagedSymbol) does not resolve — the card would draw an empty gap"
        )
    }

    /// The design's placement, measured rather than assumed.
    ///
    /// The title row is unconditional and survives a run. The facts row's guard
    /// is what makes *that* row absent for a freshly engaged card — no issue, no
    /// pull request, and `stagnation` and `prSign` both suppressed while a run is
    /// going. A mark that landed there would be invisible for exactly the cards
    /// it is about.
    ///
    /// Indexes, never line numbers: this task adds lines above the facts row, so
    /// an absolute number would be wrong the moment it was written.
    @Test("The mark is drawn in the title row, above the facts row's guard")
    func markIsInTheTitleRow() throws {
        let lines = try Self.codeLines()
        let titleRow = try #require(
            lines.firstIndex { $0.contains("HStack(alignment: .firstTextBaseline, spacing: 5)") },
            "the card's title row has moved — this scan is looking at nothing")
        let factsRow = try #require(
            lines.firstIndex { $0.contains("if !facts.isEmpty || repoName != nil") },
            "the facts row's guard has moved — this scan is looking at nothing")
        let mark = try #require(
            lines.firstIndex { $0.contains("AutoDevBand.engagedSymbol") },
            "the mark is not drawn anywhere in CardView")

        #expect(mark > titleRow, "the mark must be inside the title row")
        #expect(mark < factsRow, "the mark must not be in the facts row, which can be absent")
    }

    /// What decides whether the mark is drawn — read whole, and read at the
    /// draw site rather than in the property it calls.
    ///
    /// ⛔ **Three brace-shaped ways to lose this arm, and a needle only closes
    /// the first.** A condition gaining a clause (`isEngagedByAutoDev, activeRun
    /// == nil`); a second `if` *inside* it; a second `if` *around* it. The first
    /// two are caught by comparing the nearest enclosing condition whole — the
    /// backwards search finds the innermost `if`, so a nested one is read instead
    /// of the intended one and fails naming what it read. The third is caught by
    /// depth, which reads the shape rather than the words.
    ///
    /// ⚠️ **A fourth way is not brace-shaped, and neither check here sees it: a
    /// view can be present and draw nothing.** `.opacity(0)`, `.hidden()`, a zero
    /// `font` or `frame` *inside the correct branch* leaves the condition right
    /// and the depth right. Measured, not supposed —
    /// `.opacity(activeRun == nil ? 1 : 0)` on the mark restored this task's
    /// whole arm-3 defect with 2628 tests in 300 suites green. It is closed by
    /// the needle in ``markSurvivesARun``, which is where that arm lives; this
    /// test holds the shape, not the modifiers.
    ///
    /// The last depth check is about the row rather than the mark: the whole
    /// point of choosing the title row is that it is **unconditional**, so a
    /// condition around it would take the mark down with the title.
    @Test("The mark is drawn on engagement alone, at the top of the title row")
    func markIsDrawnOnEngagementAlone() throws {
        let code = try HiddenFaceState.code(of: "CardView.swift")

        // Bound rather than called inside `#expect`: swift-testing does not
        // expand a `try` sub-expression, so the failure would read
        // "Expectation failed: try Self.markGuard(in: code) == …" and say
        // nothing about what was actually read — measured, on this very gate,
        // during its own break-test. A gate whose doc promises it "fails naming
        // what it read" has to do that.
        let condition = try Self.markGuard(in: code)
        #expect(
            condition == "isEngagedByAutoDev",
            """
            The mark's guard is no longer "this card is engaged", full stop. It read: \(condition)
            Anything else in that condition is a way for the mark to vanish from a card auto-dev \
            is driving — and the card most worth marking is the one whose run is going, which is \
            exactly what a borrowed `activeRun == nil` would hide.
            """)

        let titleRow = try HiddenFaceState.body(
            of: "HStack(alignment: .firstTextBaseline, spacing: 5)", in: code)
        let markDepth = try #require(
            HiddenFaceState.braceDepth(of: "Image(systemName: AutoDevBand.engagedSymbol)",
                in: titleRow),
            "the title row draws no mark at all — this gate is reading the wrong row")
        #expect(
            markDepth == 1,
            """
            The mark sits \(markDepth) brace(s) deep in the title row rather than 1 — one for its \
            own `if isEngagedByAutoDev`, and nothing else. A branch around that `if` is a second \
            guard whose condition this gate cannot read, and whatever it tests, the mark vanishes \
            for some engaged card.
            """)

        let card = try HiddenFaceState.body(of: "VStack(alignment: .leading, spacing: 6)", in: code)
        let rowDepth = HiddenFaceState.braceDepth(
            of: "HStack(alignment: .firstTextBaseline, spacing: 5)", in: card)
        #expect(
            rowDepth == 0,
            """
            The title row is no longer an unconditional child of the card. It being unconditional \
            is the entire reason the mark lives there rather than in the facts row — a condition \
            around it puts the mark back where the design refuses to put it, and takes the card's \
            title with it.
            """)
    }

    /// `stagnation` and `prSign` both open with `guard activeRun == nil`, and
    /// both are right to: `RunningStrip` owns the card's attention while a run is
    /// going, and two elapsed times on one card read as one contradicting the
    /// other. The engagement mark is not that kind of fact — a card auto-dev is
    /// driving is **most** interesting while its run is going — so it must not
    /// learn the same habit from its neighbours.
    ///
    /// ⛔ **The property's own body, not a window of lines after it.** A fixed
    /// `lines[start..<start + 4]` passes only because of *where* the declaration
    /// happens to sit: moved three properties down, immediately above
    /// `stagnation` — whose body is `guard activeRun == nil` — the same window
    /// reads the neighbour and fails while this code is perfectly correct. The
    /// window measures placement; brace matching measures the declaration.
    ///
    /// ⚠️ **Compared whole rather than swept for a banned word**, which is the
    /// lesson `BoardAccessibilityTests` paid for one task ago: a word list holds
    /// one direction only. `!activeRun.isNil` contains the banned word and is
    /// correct; `false` contains nothing and silently unmarks every card in every
    /// session. Equality holds both — a rewrite fails loudly naming what it read,
    /// which asks a person to look, and that is the right direction for the one
    /// expression this whole feature's visibility rests on.
    ///
    /// ⛔ **The property is one of two places a run can suppress the mark, and
    /// the second is not a branch at all.** A view can be present and draw
    /// nothing: `.opacity(activeRun == nil ? 1 : 0)` on the `Image`, inside the
    /// correct `if`, leaves this body untouched, the draw-site condition
    /// untouched and the brace depth untouched. Measured rather than imagined —
    /// it restored this whole arm's defect with 2628 tests in 300 suites green,
    /// which is what fix round 1 found. So the mark's own block is swept too.
    ///
    /// ⚠️ **That second half is a needle, and it is disclosed as one**, unlike
    /// the whole-value comparison above it. It holds the three shapes that have
    /// actually been measured — the same pair `BoardAccessibilityTests` bans in
    /// the status strip, plus the name this arm is about. It does **not** hold a
    /// zero `font` or `frame`, nor a sibling `markFont` computing one, and both
    /// of those are live. `.font(` cannot be banned here because the mark draws
    /// with it, which is the honest reason the list stops where it does.
    @Test("The mark reads the engaged set, and nothing else — a run does not suppress it")
    func markSurvivesARun() throws {
        let code = try HiddenFaceState.code(of: "CardView.swift")
        let body = try HiddenFaceState.body(of: "private var isEngagedByAutoDev", in: code)
        let block = try HiddenFaceState.body(of: "if isEngagedByAutoDev", in: code)

        // `activeRun` catches `model.activeRuns[card.id]` written inline too —
        // the plural contains the singular — so the one name this arm is about
        // is closed by both routes into it.
        for shape in ["activeRun", ".opacity(", ".hidden()"] {
            #expect(
                !block.contains(shape),
                Comment(
                    rawValue: """
                        The mark's own block carries `\(shape)`. A branch is not the only way to \
                        lose this arm — a view can be present and draw nothing — and a hiding \
                        modifier here makes the mark vanish for exactly the card auto-dev is \
                        working on, with the condition and the brace depth both still right.
                        """))
        }

        #expect(
            body.filter { !$0.isWhitespace } == "model.autoDevEngagedCardIDs.contains(card.id)",
            """
            `isEngagedByAutoDev` no longer reads the session's engaged set and nothing else. It \
            read: \(body.trimmingCharacters(in: .whitespacesAndNewlines))
            Two failures live here. Consulting `activeRun` — the habit `stagnation` and `prSign` \
            have, and are right to — takes the mark off exactly the cards auto-dev is working on. \
            Answering from anything narrower than `autoDevEngagedCardIDs` takes it off cards the \
            session engaged: that set is closed at start, so the mark is right from the instant \
            the session exists and stays right through the report, where a card whose merge \
            failed is still a card the session engaged.
            """)
    }

    /// No sixth tint, and never an unnamed glyph.
    ///
    /// Engaged cards are `armed`, which is what `armed` already means, so the
    /// mark spends no new accent. And a card is one combined accessibility
    /// element: an unlabelled glyph is read aloud as whatever the system calls
    /// the character, jammed against the title — the same reason the lens mark
    /// two lines above carries a label.
    ///
    /// ⛔ **`.accessibilityLabel`, not merely the constant appearing somewhere.**
    /// `CardAngleMarkTests` measured this exact hole one file over: a `.help(…)`
    /// satisfies a bare `contains` and is invisible to VoiceOver, the one reader
    /// a label exists for.
    ///
    /// Read from the mark's **own block** rather than a window of lines after it,
    /// for the reason `markSurvivesARun` gives: a window is an artefact of how
    /// many comment lines happen to sit inside the block.
    @Test("The mark spends no new accent, and is never drawn unnamed")
    func markUsesArmed() throws {
        let code = try HiddenFaceState.code(of: "CardView.swift")
        let block = try HiddenFaceState.body(of: "if isEngagedByAutoDev", in: code)

        #expect(
            block.contains("Image(systemName: AutoDevBand.engagedSymbol)"),
            "the mark must be AutoDevBand's symbol, not a string literal written here")
        #expect(
            block.contains("Palette.armed"),
            "no sixth accent: an engaged card is armed, which is what `armed` already means")
        #expect(
            block.contains(".accessibilityLabel(AutoDevBand.engagedLabel)"),
            """
            The mark is drawn without `.accessibilityLabel(AutoDevBand.engagedLabel)`. A card is \
            one combined accessibility element, so the glyph is read aloud as whatever the system \
            calls the character, jammed against the title. A `.help(…)` does not close this — it \
            is invisible to VoiceOver, which `CardAngleMarkTests` measured one file over.
            """)
    }

    /// `CardView.swift` with every `//` comment cut, split into lines.
    ///
    /// The cut preserves line count, so an index measured here is an index into
    /// the real file — which is what `markIsInTheTitleRow` compares.
    private static func codeLines() throws -> [String] {
        try HiddenFaceState.code(of: "CardView.swift").components(separatedBy: "\n")
    }

    /// The condition of the `if` the mark is drawn under, whitespace squashed.
    ///
    /// Backwards from the mark, so it finds the **innermost** enclosing `if`:
    /// that is what makes a nested guard fail this gate rather than hide behind
    /// the intended one. Squashed because the condition may be hand-wrapped and a
    /// reformat is not a defect; a new clause is.
    private static func markGuard(in code: String) throws -> String {
        let mark = try #require(
            code.range(of: "Image(systemName: AutoDevBand.engagedSymbol)"),
            "the mark is not drawn as `Image(systemName: AutoDevBand.engagedSymbol)`")
        let head = code[..<mark.lowerBound]
        let keyword = try #require(
            head.range(of: "if ", options: .backwards),
            "nothing conditions the mark — it would be drawn on every card, engaged or not")
        let condition = head[keyword.upperBound...]
        let brace = try #require(
            condition.firstIndex(of: "{"),
            "the mark's condition opens no block — this gate is reading something else")
        return condition[..<brace].filter { !$0.isWhitespace }
    }
}
