import Foundation
import Testing

@testable import ElliotAppKit

/// Where the auto-dev band sits, and that it sits there always.
///
/// `swift test` cannot see the screen — this project has paid three merges for
/// pretending otherwise (#47, #50, #52, #53) — but it can read the source, which
/// is the idiom `CardAngleMarkTests`, `UpNextBandSourceTests` and
/// `DrainDuplicationTests` already use for claims about a view's *shape*. Four
/// claims here, and each is load-bearing:
///
/// 1. **Adjacency.** "Above Up next" is not "somewhere above": Up next is the
///    ranking of moves Elliot could make and auto-dev is one fixed set of them
///    being made, so the two have to be read together or the caption explaining
///    the difference is explaining a difference the reader cannot see.
/// 2. **Unconditionality.** `preflightBand` is `@ViewBuilder` and vanishes when
///    nothing is failing, and it is right to: preflight is a state nobody has to
///    remember. A session's outcome is a record — and the record it carries is a
///    failed merge, which stays in Done where `rankNextSteps` cannot see it.
/// 3. **Reach.** The control that starts an unattended session must be where a
///    reader can see it, nowhere a key can reach it, and disabled by the one
///    property that answers whether it may start — *on the button itself*.
/// 4. **Tier.** The band decides the tone and `Consequence.swift` decides the
///    colour, in that order and in those two files.
///
/// ⛔ **Every scan here reads `HiddenFaceState.code`, never the raw file**, and
/// that is not tidiness. The brief this task came from asserted
/// `!source.contains(".toolbar")` over the whole file *and* had the
/// implementation write a comment saying `.toolbar` — so the gate refused its
/// own subject's explanation, and the cheapest way to make it pass would have
/// been to delete the explanation. CLAUDE.md states the general form from #186:
/// a string gate over prose *"can tell neither a claim from a mention nor a live
/// claim from a quoted one"*. Stripping comments makes it a gate about code;
/// slicing one declaration's body makes it a gate about *that* code.
@Suite("Operations band order")
struct OperationsBandOrderTests {

    /// The screen's source with its comments cut away.
    ///
    /// `HiddenFaceState` owns both the path walk and the cut — a fifth copy of
    /// either is what #146 charges three defects for.
    private static func code() throws -> String {
        try HiddenFaceState.code(of: "OperationsView.swift")
    }

    /// The same file with **whole comment lines dropped** and every other line
    /// left intact.
    ///
    /// ⚠️ **The second reading exists because the first one can hide code, and
    /// that was measured rather than reasoned about.** `HiddenFaceState.stripped`
    /// cuts at the first `//` on a line — including one inside a string literal —
    /// and its own doc licenses that with *"none of the needles these gates use
    /// can occur after one"*. This caller's needles can: a real
    /// `.toolbar { Button("Start auto-dev") … }` written after `"https://ops"` on
    /// one line is invisible to the cut, compiles, and leaves the whole suite
    /// green. The two whole-file needles are therefore checked against **both**
    /// readings, which is `DefaultActionTests.isCode`'s rule (a line is code
    /// unless it *starts* with `//`) used as the second opinion rather than as a
    /// replacement.
    ///
    /// ⛔ The trade, stated so it is a rule rather than a surprise: **prose about
    /// `.toolbar` or `.keyboardShortcut(` must live on its own comment line, not
    /// trailing a line of code.** A whole-line comment is dropped by this reading
    /// and cut by the other, so an explanation stays free — which is Override 1's
    /// whole point and is proved by the reviewer's break L.
    private static func codeLines(of file: String) throws -> String {
        try HiddenFaceState.source(of: file)
            .components(separatedBy: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }

    /// The modifiers attached to one control, and to no other.
    ///
    /// ⛔ **Where a modifier is attached is the whole claim**, and a scan of a
    /// declaration's body cannot see it: `.disabled(…)` on the `Stepper` beside
    /// the Start button satisfies "the body contains `.disabled(…)`" while
    /// leaving Start pressable in a repository the model has refused. Measured on
    /// this branch — the modifier moved one control over, all 2617 tests green.
    ///
    /// The walk is the file's own hand formatting: the lines after the control's
    /// opening line that begin with `.`, blank lines skipped so a comment between
    /// two modifiers does not end the chain. **Its bound**: it reads a chain
    /// written directly under a control whose opening line is one line. A
    /// multi-line action closure, or the modifiers moved onto a wrapping view,
    /// reads as an empty chain — which fails, saying so, rather than passing.
    private static func modifiers(of control: String, in body: String) throws -> [String] {
        let lines = body.components(separatedBy: "\n")
        let start = try #require(
            lines.firstIndex { $0.contains(control) },
            "\(control) is not in this declaration — this gate is reading the wrong thing")
        var chain: [String] = []
        for raw in lines[(start + 1)...] {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            guard line.hasPrefix(".") else { break }
            chain.append(line)
        }
        return chain
    }

    /// The bare band identifiers inside the screen's one `VStack`, in order.
    private static func bandOrder(in code: String) throws -> [String] {
        let lines = code.components(separatedBy: "\n")
        let start = try #require(
            lines.firstIndex { $0.contains("VStack(alignment: .leading, spacing: 18) {") },
            "the screen's band stack has been restructured — this scan is now looking at nothing"
        )
        var order: [String] = []
        for raw in lines[(start + 1)...] {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line == "}" { break }
            guard line.hasSuffix("Band") else { continue }
            order.append(line)
        }
        return order
    }

    /// Whether a declaration carries `@ViewBuilder`, which is the annotation that
    /// lets a band draw nothing at all.
    ///
    /// Walks back over the blank lines the comment cut leaves behind, so a
    /// documented declaration is read the same as an undocumented one.
    private static func isViewBuilder(_ declaration: String, in code: String) -> Bool {
        let lines = code.components(separatedBy: "\n")
        guard let index = lines.firstIndex(where: { $0.contains(declaration) }) else { return false }
        for raw in lines[..<index].reversed() {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            return line == "@ViewBuilder"
        }
        return false
    }

    /// ⚠️ Adjacency, not a fixed index. A written-out list of the whole stack
    /// fails the day a seventh band lands above — which is not a defect, and a
    /// gate that cries about one teaches people to edit the gate. `upNextBand`
    /// resolving at all is this scan's positive witness: it exists in exactly one
    /// place, so finding it means the block being read is the real one.
    @Test("The auto-dev band is drawn immediately above Up next")
    func bandSitsDirectlyAboveUpNext() throws {
        let order = try Self.bandOrder(in: try Self.code())
        let auto = try #require(
            order.firstIndex(of: "autoDevBand"),
            "the screen draws no auto-dev band at all — read \(order)")
        let upNext = try #require(
            order.firstIndex(of: "upNextBand"),
            "the screen draws no Up next band — this scan is reading the wrong block: \(order)")
        #expect(
            auto + 1 == upNext,
            """
            The auto-dev band is not immediately above Up next — read \(order). Up next ranks \
            every move Elliot could make; this is the one fixed set it is making by itself. \
            Stacked apart, the two read as one order, and `AutoDevBand.caption` — which says \
            they are not — is explaining a difference the reader cannot see.
            """)
    }

    /// The one thing a source scan can say about permanence, and the reason it
    /// is worth saying: the failure this band exists to show is invisible
    /// everywhere else, so a band that learned to hide itself would take the
    /// evidence with it.
    ///
    /// Every arm was measured red — `@ViewBuilder` on the declaration, an `if` in
    /// the body, a ternary on the session, `.hidden()` — because a gate nobody
    /// has broken is a gate nobody has checked.
    ///
    /// ⚠️ **What it does not catch, said here so nobody over-trusts it.** This is
    /// a scan for *shapes*, and the first version knew only two of them:
    /// `@ViewBuilder` and a literal `if `. The reviewer's break I —
    /// `.opacity(model.autoDev == nil ? 0 : 1)` on the band's body — made the
    /// band vanish for exactly the input this test defends and left the suite
    /// green. The comparison and the two hiding modifiers are banned now, so that
    /// break reddens; a view that hid itself by some *other* means would still
    /// pass. **The honest claim is that no shape here decides whether to draw,
    /// not that no such shape can exist** — the band's permanence on screen is
    /// Task 8's to see.
    @Test("The band is not conditional on there being a session")
    func bandIsUnconditional() throws {
        let code = try Self.code()
        // Positive witness: a renamed declaration would make every claim below
        // vacuously true and this gate would go green having read nothing.
        #expect(
            code.contains("private var autoDevBand: some View"),
            "OperationsView no longer declares autoDevBand — this gate is reading the wrong thing")

        #expect(
            !Self.isViewBuilder("private var autoDevBand: some View", in: code),
            """
            autoDevBand is a `@ViewBuilder`, which is the annotation that lets a band draw \
            nothing at all. `preflightBand` is one and is right to be: preflight is a state \
            nobody has to remember. A session's outcome is a record — `Column.naturalNext` is \
            nil for `.done`, so a card whose merge failed is structurally absent from Up next \
            below, and this band is the only surface that shows it.
            """)

        let body = try HiddenFaceState.body(of: "private var autoDevBand: some View", in: code)
        #expect(
            body.contains("AutoDevBand.of("),
            "the band's sentences must come from AutoDevBand.of, which decides them once")
        #expect(
            !body.contains("if "),
            """
            The band's body branches. `AutoDevBand.of` is total — it returns a band for every \
            input, including no session at all — so there is nothing here to decide. A \
            conditional band renders a session that failed everywhere exactly like a session \
            that never happened.
            """)
        for shape in ["model.autoDev ==", "model.autoDev !=", ".hidden()", ".opacity("] {
            #expect(
                !body.contains(shape),
                Comment(
                    rawValue: """
                        The band's body carries `\(shape)`. A branch is not the only way to \
                        disappear: a ternary on whether a session exists, or a hiding modifier, \
                        makes the band vanish for exactly the input it exists to report — a \
                        session that failed everywhere, which `rankNextSteps` cannot see and \
                        Up next below therefore never shows.
                        """))
        }
    }

    /// ⛔ The start control claims more unattended runs than the analysis panel
    /// does, and it merges. Two places it must not be: `.toolbar`, the one
    /// region `board_screenshot` renders blank, and the Return key, which it
    /// would share with `DetailPanelView`'s Save with nothing deciding between
    /// them.
    ///
    /// The key check is the whole `.keyboardShortcut(` family rather than
    /// `.defaultAction` alone, for `UpNextBandSourceTests`' reason: a
    /// scoped-looking `.keyboardShortcut(.return)` is the same key.
    ///
    /// ⚠️ **Two readings of each file, never one** — see ``codeLines(of:)``. The
    /// comment cut can hide a real `.toolbar` behind a `//` inside a string
    /// literal; dropping whole comment lines cannot, and cannot be satisfied by
    /// prose either. The gate holds only where both agree.
    @Test("The start control is neither in the toolbar nor on Return")
    func startControlIsWhereItCanBeSeenAndNotWhereItCanBeHit() throws {
        let readings = [try Self.code(), try Self.codeLines(of: "OperationsView.swift")]
        #expect(readings[0].contains("Button(\"Start auto-dev\")"))

        for reading in readings {
            #expect(
                !reading.contains(".toolbar"),
                """
                The Operations screen puts something in a toolbar. `board_screenshot` renders \
                that region blank — measured: seven toolbar items came back as two empty \
                capsules — so a control that starts an unattended session would be unverifiable \
                by the one channel an agent has.
                """)
            #expect(
                !reading.contains(".keyboardShortcut("),
                "nothing on this screen may be reached by a key; the start control starts agents")
        }

        // And it is not hiding in the board's toolbar either.
        #expect(!(try HiddenFaceState.code(of: "BoardView.swift")).contains("Start auto-dev"))
        #expect(!(try Self.codeLines(of: "BoardView.swift")).contains("Start auto-dev"))
    }

    /// ⛔ The gate is on the **act**, and the refusal is on the **screen**.
    ///
    /// `AutoDevStateTests` holds the model's half in both directions — no
    /// driver, a blocked repository, a switched-off one and no repository picked
    /// each yield a sentence, an unswept one yields `nil` — but no behavioural
    /// test can see whether the control is wired to it. This is that wiring, and
    /// four ways of getting it wrong are visible here: an inverted condition
    /// (`== nil`) disables the control exactly when it may be pressed, a
    /// hard-coded `.disabled(true)` refuses for ever, dropping the sentence
    /// leaves a control that cannot be pressed and will not say what would let it
    /// be — the state #151 removed one panel over — and **the modifier attached
    /// to the wrong control**.
    ///
    /// ⛔ **That fourth one is why this reads a modifier chain rather than the
    /// declaration's body**, and it is a correction: this comment used to claim
    /// three ways *"visible here and nowhere else"* while the gate matched
    /// `.disabled(…)` anywhere in `startRow`. Measured — the modifier moved onto
    /// the `Stepper` beside the button left all 2617 tests green with Start
    /// pressable in a repository the model refuses. `AppModel.startAutoDev`'s own
    /// guard makes that press a silent no-op rather than an unattended run, which
    /// is not comfort: *a button that silently does nothing looks exactly like a
    /// button nobody pressed*, on the claimant that merges.
    ///
    /// ⚠️ The chain walk has a bound, written on ``modifiers(of:in:)``: it reads
    /// modifiers written directly under a one-line control. Rewrapping the button
    /// reads as an empty chain and **fails**, saying what shape it expects —
    /// wrong in the direction that asks a person to look.
    @Test("Start is disabled exactly when the model refuses, and says why")
    func startIsGatedOnTheModelsRefusal() throws {
        let body = try HiddenFaceState.body(
            of: "private var startRow: some View", in: try Self.code())

        #expect(body.contains("Button(\"Start auto-dev\")"))
        let chain = try Self.modifiers(of: "Button(\"Start auto-dev\")", in: body)
        #expect(
            chain.contains(".disabled(model.autoDevRefusal != nil)"),
            """
            The Start button is not itself disabled by `model.autoDevRefusal`. Its own \
            modifiers are \(chain). That property is the one answer to "may auto-dev start", \
            and it delegates the repository half to `UnattendedStartRefusal` — the rule the \
            analysis panel, the service and the appraisal also ask. Gated on anything else, or \
            attached to a neighbour like the Stepper, the button stays pressable while the \
            model refuses: the press is swallowed by `startAutoDev`'s own guard and the reader \
            is told nothing at all.
            """)
        #expect(
            body.contains("if let refusal = model.autoDevRefusal"),
            """
            The refusal is not shown beside the control. A disabled Start with no sentence is a \
            control that cannot be pressed and does not say what would let it be — which is what \
            #151 replaced one panel over with an explanation the reader can act on.
            """)
    }

    /// The denial is on the record, so re-adding a shortcut reads as reversing a
    /// decision rather than as an edit nobody flagged.
    ///
    /// `DefaultAction.denied` is where this codebase keeps that record, and
    /// `DefaultActionTests.deniedControlsClaimNothing` is what enforces it. This
    /// test guards the entry itself: deleted, that enforcement silently covers
    /// one control fewer.
    @Test("The start control is on the record as denied Return")
    func startControlIsRecordedAsDenied() {
        #expect(
            DefaultAction.denied.contains { $0.label == "Start auto-dev" },
            """
            "Start auto-dev" is not listed in `DefaultAction.denied`. A control that never had \
            a default action and one that was denied one on purpose look identical in a diff — \
            naming it is what makes re-adding one reversible on the record.
            """)
    }

    /// ⛔ **The tone is the band's; the colour is `Consequence.swift`'s.** Both
    /// halves of that were prose only until now, and both were measured green
    /// while broken.
    ///
    /// `AutoDevBand.swift:11` states *"It holds no `Color`"* as a fact — the
    /// reviewer's break K put `import SwiftUI` and a `Color` property inside the
    /// type and nothing noticed, which is this repository's asserted-in-a-comment
    /// / implemented-nowhere shape. And break J had the view pick its own tint
    /// from `rendering.tone` with a ternary, leaving the mapping in
    /// `Consequence.swift` correct, tested, and bypassed.
    ///
    /// The pair matters more than either half: a value that cannot name a colour
    /// cannot be where a sixth consequence accent arrives, and a view that names
    /// one is where it arrives instead.
    @Test("The band names no colour, and the view does not pick one")
    func theColourIsDecidedInConsequence() throws {
        let band = try HiddenFaceState.code(of: "AutoDevBand.swift")
        // Positive witness: a moved or renamed type would leave this reading
        // empty and every claim below vacuously true.
        #expect(band.contains("struct AutoDevBand"))
        #expect(
            !band.contains("import SwiftUI"),
            """
            AutoDevBand imports SwiftUI. It is the file that decides the band's *sentences*, and \
            it holds no colour so that a test can assert the decision rather than a colour — \
            `Consequence.swift` is the one place this project's values meet SwiftUI.
            """)
        #expect(
            !band.contains("Color"),
            "AutoDevBand names a colour type; the tone is its answer and Consequence maps it")

        let body = try HiddenFaceState.body(
            of: "private var autoDevBand: some View", in: try Self.code())
        #expect(
            body.contains(".foregroundStyle(rendering.tone.tint)"),
            """
            The band's headline is not drawn in `rendering.tone.tint`. The view choosing its own \
            colour from the tone leaves `AutoDevBand.Tone.tint` correct, tested and bypassed — \
            and the status bar's figure, which draws the same tone, would then disagree with the \
            band it is the door to.
            """)
    }

    /// ⛔ Which repository a session is about is **one** question, and the answer
    /// lives on `AutoDevBand` so the two surfaces that ask cannot drift.
    ///
    /// The plan had this screen and the status bar each grow a private
    /// `autoDevRepoName`, with bodies that already differed before either was
    /// written. This is the second copy of one question, in one module, and the
    /// audit of the plan called it out before it existed.
    @Test("The repository name is asked of AutoDevBand, not worked out here")
    func theRepositoryNameIsNotReDerived() throws {
        let body = try HiddenFaceState.body(
            of: "private var autoDevBand: some View", in: try Self.code())
        #expect(
            body.contains("AutoDevBand.repoName("),
            "the band must ask AutoDevBand for the session's repository name")
        #expect(
            !body.contains("repos.first(where:"),
            """
            The band looks the repository up itself. `AutoDevBand.repoName` is that lookup, and \
            the status bar's figure asks the same function — a second copy here is how the band \
            and the figure come to name two different repositories.
            """)
    }
}
