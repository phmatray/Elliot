import Foundation
import Testing

@testable import ElliotAppKit

/// Where the auto-dev band sits, and that it sits there always.
///
/// `swift test` cannot see the screen — this project has paid three merges for
/// pretending otherwise (#47, #50, #52, #53) — but it can read the source, which
/// is the idiom `CardAngleMarkTests`, `UpNextBandSourceTests` and
/// `DrainDuplicationTests` already use for claims about a view's *shape*. Six
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
/// 3. **Contents.** Drawn is not the same as drawing *this*: every field
///    `AutoDevBand.of` decides has to reach the screen, and the report's rows
///    have to come from the model.
/// 4. **Wiring.** Each control has to run its own command and no other. The
///    band's whole copy rests on Pause not being Stop, and nothing outside this
///    file can see which one a button calls.
/// 5. **Reach.** The control that starts an unattended session must be where a
///    reader can see it, nowhere a key can reach it, and disabled by the one
///    property that answers whether it may start — *on the button itself*.
/// 6. **Tier.** The band decides the tone and `Consequence.swift` decides the
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
    /// ⚠️ **The parse moved to `HiddenFaceState` when a second gate needed it.**
    /// `BoardAccessibilityTests` reads the status bar's figure the same way, over
    /// the same file, and would have had to copy the two paragraphs above — which
    /// is exactly #146's tell that the invariant is being copied with them. The
    /// judgement stays here, as this suite's header requires; only the reading is
    /// shared.
    private static func codeLines(of file: String) throws -> String {
        try HiddenFaceState.codeLines(of: file)
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

    /// A block with every run of whitespace collapsed to one space.
    ///
    /// ⚠️ Without it a gate over a line of view code is brittle in a way that
    /// would eventually be read as the defect rather than as the instrument: a
    /// rename that pushed a call past 110 columns would be re-wrapped by hand,
    /// turning a correct line into a failure whose obvious "fix" is to delete
    /// the assertion. `MergeOriginSourceTests.flat` carries the same reasoning,
    /// one gate over, for the same reason.
    private static func flat(_ block: String) -> String {
        block.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// The stored properties `AutoDevBand` decides, by name.
    ///
    /// ⛔ **Derived from the type, never listed here.** A written-out list of
    /// four names holds today's four fields and silently covers a fifth not at
    /// all — which is the whole failure mode of the gate it serves, since the
    /// point is that a decision nothing renders looks exactly like a decision
    /// nobody made.
    ///
    /// ⚠️ **Its bound**: it reads `let` declarations at the struct's *own* brace
    /// depth, so a stored property declared inside a nested type is invisible to
    /// it, and so is one written on a line the comment cut has already emptied.
    /// A restructured type reads as an empty list, which its caller fails on
    /// rather than passing.
    private static func bandFields() throws -> [String] {
        let body = try HiddenFaceState.body(
            of: "struct AutoDevBand: Equatable", in: try HiddenFaceState.code(of: "AutoDevBand.swift"))
        var names: [String] = []
        var depth = 0
        for raw in body.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if depth == 0, line.hasPrefix("let ") {
                let name = line.dropFirst(4).prefix { $0.isLetter || $0.isNumber || $0 == "_" }
                if !name.isEmpty { names.append(String(name)) }
            }
            depth += raw.filter { $0 == "{" }.count - raw.filter { $0 == "}" }.count
        }
        return names
    }

    /// What pressing each control must run, and nothing else.
    ///
    /// ⛔ **Exhaustive over `AutoDevBand.Control` on purpose.** A fourth control
    /// does not compile here until someone states which command it runs — the
    /// half of "added unwired" that a scan of the screen's source cannot reach,
    /// because a control nobody wired leaves no text behind to find.
    private static func command(for control: AutoDevBand.Control) -> String {
        switch control {
        case .pause: "model.pauseAutoDev()"
        case .resume: "model.resumeAutoDev()"
        case .stop: "model.stopAutoDev()"
        }
    }

    /// Every auto-dev command an arm could be wired to.
    ///
    /// `startAutoDev` is here although no control runs it: a control wired to
    /// Start is the same defect as one wired to Stop, and it is the one a list
    /// derived from the three controls alone would miss.
    private static var commands: [String] {
        AutoDevBand.Control.allCases.map(command(for:)) + ["model.startAutoDev()"]
    }

    /// One `switch` arm of a declaration's body: its `case` label, and every
    /// line up to the next label.
    ///
    /// ⚠️ **Its bound**: it reads arms written one label per line, which is this
    /// file's hand formatting. A shared `case .pause, .resume:` label, or an arm
    /// folded onto the `switch` line, is not found — and the `#require` then
    /// **fails naming the label** rather than passing, which is the direction
    /// that asks a person to look.
    private static func arm(_ label: String, in body: String) throws -> String {
        let lines = body.components(separatedBy: "\n")
        let start = try #require(
            lines.firstIndex { $0.trimmingCharacters(in: .whitespaces).hasPrefix(label) },
            Comment(
                rawValue: """
                    act(_:) has no `\(label)` arm. Every AutoDevBand.Control must be wired to its \
                    own command here: a control the switch does not name is a button that does \
                    nothing, and a button that silently does nothing looks exactly like a button \
                    nobody pressed.
                    """))
        var arm = [lines[start]]
        for raw in lines[(start + 1)...] {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("case ") || line.hasPrefix("default") { break }
            arm.append(raw)
        }
        return arm.joined(separator: "\n")
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

    /// ⛔ **Every sentence the band decides has to reach the screen**, and until
    /// now nothing said so. Measured by the whole-branch review, on this branch:
    /// deleting `Text(AutoDevBand.caption)` **and** the entire
    /// `ForEach(model.autoDevEngagements)` report left **2628 tests in 300
    /// suites green**, and the same is true of the headline, the run note and
    /// the controls.
    ///
    /// That is `CaretAnchorTests`' shape exactly, and worth naming because both
    /// halves look covered: `AutoDevBandTests` proves the four fields are
    /// *decided* correctly, ``bandIsUnconditional()`` proves the band is
    /// *drawn* at all — and the step between them, which renders one from the
    /// other, had nothing on it. Everything either side of a step is green and
    /// the step itself has no test.
    ///
    /// The field list is **derived from `AutoDevBand`** — see ``bandFields()`` —
    /// so a fifth field cannot arrive unrendered.
    ///
    /// ⚠️ **What it does not catch, said here so nobody over-trusts it.**
    ///
    /// - It holds that each field is *mentioned* in the band's body, never that
    ///   it is legible. A zero `font` or `frame` leaves the field rendered and
    ///   the screen blank — the third evasion `HiddenFaceState.braceDepth`
    ///   names, and one no source scan closes. The other two hiding shapes,
    ///   `.opacity(` and `.hidden()`, are banned in *this same body* by
    ///   ``bandIsUnconditional()``.
    /// - A field mentioned only inside a `.help(…)` string, or handed to a
    ///   helper that drops it, counts as rendered here.
    /// - The button assertion pins the one form that exists. A *second* button
    ///   added beside it, reading one control's title while acting on another,
    ///   leaves this string present and passes.
    @Test("Every sentence the band decides is drawn, and the rows come from the model")
    func theBandDrawsEverythingItIsGiven() throws {
        let body = try HiddenFaceState.body(
            of: "private var autoDevBand: some View", in: try Self.code())
        let fields = try Self.bandFields()

        // A negative needs its positive witness: a restructured or renamed type
        // would leave `fields` empty and the loop below would establish nothing
        // while going green — the failure this whole gate is about, one level up.
        #expect(
            fields.contains("headline"),
            Comment(
                rawValue:
                    "the AutoDevBand field scan read \(fields) — it is looking at the wrong "
                    + "declaration, so this gate is holding nothing at all"))

        for field in fields {
            #expect(
                body.contains("rendering.\(field)"),
                Comment(
                    rawValue: """
                        The band decides `\(field)` and this view never reads it. A field decided \
                        and not drawn looks exactly like a field nobody decided: `AutoDevBand.of` \
                        is total and tested, so the whole of its answer being on screen is what \
                        makes those tests claims about the product rather than about a struct.
                        """))
        }

        #expect(
            body.contains("Text(AutoDevBand.caption)"),
            """
            The band no longer draws `AutoDevBand.caption`. It is the one sentence in this feature \
            that is not a field of what `AutoDevBand.of` returns, and it is what says this band is \
            not the ranking below it — without it two orders are stacked in one window reading as \
            one, which is the whole reason for the adjacency the test above holds.
            """)

        #expect(
            Self.flat(body).contains("Button(AutoDevBand.title(control)) { act(control) }"),
            """
            The band's controls are no longer drawn as `Button(AutoDevBand.title(control)) \
            { act(control) }`. That one line is where the control the reader sees and the control \
            the screen acts on are the same value; written any other way, the title and the act \
            can name two different controls and `eachControlRunsItsOwnCommand` — which reads \
            act(_:) alone — cannot tell.
            """)

        #expect(
            body.contains("ForEach(model.autoDevEngagements)"),
            """
            The report's rows no longer come from `model.autoDevEngagements`. That property is \
            assigned only by `AppModel.adopt`, together with the session and the engaged set, so \
            a row read from anywhere else is the second source of truth `adoptIsTheOnlyWriter` \
            exists to refuse — and a session whose merges failed has no other surface at all.
            """)
        #expect(
            body.contains("engagementRow(engagement)"),
            "the rows are enumerated and nothing is drawn for them")
    }

    /// ⛔ **Which command a control runs is not held by anything else, and the
    /// band's whole copy rests on the distinction.**
    ///
    /// Measured by the whole-branch review, on this branch: rewiring
    /// `case .pause` to `await model.stopAutoDev()` left **2628 tests in 300
    /// suites green**. A button titled *Pause*, under a note promising *"Pause
    /// engages no further move and lets the run already going finish"*, would
    /// **cancel the run already going** — the one act `AutoDevDriving`'s doc,
    /// `AutoDevBand.Control`'s doc and the run note all exist to keep apart from
    /// Pause.
    ///
    /// `AutoDevStateTests` holds the model's half in both directions — pause
    /// leaves the session `.paused`, stop leaves it `.finished` and sets the
    /// fake's `stopped` — but not one of those tests can see the **button**, and
    /// the band is the only production caller there is. That is
    /// `MergeOriginSourceTests`' sentence, one screen over, in this same pull
    /// request, on this same reasoning.
    ///
    /// ⚠️ **Latent today, live the day PR4 lands.** With no conformer every
    /// command returns at `autoDevCommand`'s first guard, so the three are
    /// indistinguishable from outside — which is exactly why the gate is written
    /// now rather than "later", when the button becomes the thing that cancels
    /// an unattended agent.
    ///
    /// ⚠️ **What it does not catch.**
    ///
    /// - It reads the `switch` in `act(_:)` and nothing else. A command reached
    ///   indirectly — through a helper, a stored closure, a key path — leaves
    ///   the arm without its needle and **fails**, which is the safe direction,
    ///   but this gate cannot then say the indirection is right.
    /// - It cannot see that the button carrying a control's *title* is the one
    ///   that hands `act` that same control. The one-line form where both read
    ///   `control` is pinned by ``theBandDrawsEverythingItIsGiven()`` above,
    ///   which is as close as reading source gets.
    /// - It says nothing about what the three commands *do*. That
    ///   `pauseAutoDev` does not cancel a run is `AutoDevDriving`'s contract and
    ///   PR4's obligation; no test in this build can hold it, because no
    ///   conformer exists to hold it against.
    @Test("Each control runs its own command, and none runs another's")
    func eachControlRunsItsOwnCommand() throws {
        let code = try Self.code()
        // Positive witness: a renamed or restructured dispatch would make every
        // claim below vacuously true and this gate would go green having read
        // nothing.
        #expect(
            code.contains("private func act(_ control: AutoDevBand.Control)"),
            "OperationsView no longer declares act(_:) — this gate is reading the wrong thing")

        let body = try HiddenFaceState.body(
            of: "private func act(_ control: AutoDevBand.Control)", in: code)
        #expect(
            body.contains("switch control"),
            "act(_:) no longer switches on the control it was handed")
        #expect(
            !body.contains("default"),
            """
            act(_:) has a catch-all arm. The switch is exhaustive over AutoDevBand.Control, so a \
            fourth control cannot compile unwired — a `default` is the one shape that lets it, and \
            it would send the new control to some other control's command in silence.
            """)

        for control in AutoDevBand.Control.allCases {
            let mine = Self.command(for: control)
            let arm = try Self.arm("case .\(control):", in: body)
            #expect(
                arm.contains(mine),
                Comment(
                    rawValue: """
                        The \(control) control does not run \(mine). Its arm reads: \
                        \(Self.flat(arm)). The band's run note tells the reader what each button \
                        does to the run already going, and that sentence is only true if the \
                        button runs the command it names.
                        """))
            for other in Self.commands where other != mine {
                #expect(
                    !arm.contains(other),
                    Comment(
                        rawValue: """
                            The \(control) control runs \(other). Its arm reads: \
                            \(Self.flat(arm)). Pause and Stop are kept apart by three doc \
                            comments and the note under the buttons — stop cancels the run \
                            already going, pause lets it finish — and one of these two is an \
                            unattended agent killed by a button that promised not to.
                            """))
            }
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
