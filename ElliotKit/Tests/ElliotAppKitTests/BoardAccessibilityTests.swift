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

    /// The analysis panel has no caret, no tether and no origin column, so the
    /// only thing that says *what repository it is reading* is this sentence.
    /// Three states, one per thing the panel can be, because "Analysis" alone
    /// tells a listener the one thing the toolbar has already told them.
    @Test("The analysis panel says which repository it is reading, and how much is waiting")
    func analysisPanelCaptionNamesTheRepositoryAndTheBacklogOfDecisions() {
        #expect(
            BoardAccessibility.analysisPanelLabel(repoName: nil, proposalCount: nil)
                == "Analysis. Pick a single repository to analyse.")
        #expect(
            BoardAccessibility.analysisPanelLabel(repoName: "Elliot", proposalCount: nil)
                == "Analysis of Elliot. Not started.")
        // Singular written out, for the reason the two captions above give: "1
        // proposals" is what makes a careful product look careless, and this is
        // read aloud.
        #expect(
            BoardAccessibility.analysisPanelLabel(repoName: "Elliot", proposalCount: 1)
                == "Analysis of Elliot, 1 proposal to decide.")
        #expect(
            BoardAccessibility.analysisPanelLabel(repoName: "Elliot", proposalCount: 12)
                == "Analysis of Elliot, 12 proposals to decide.")
        // Nothing left to decide is a state, not an absence: it must not fall
        // back to the "Not started" sentence.
        #expect(
            BoardAccessibility.analysisPanelLabel(repoName: "Elliot", proposalCount: 0)
                == "Analysis of Elliot, 0 proposals to decide.")
    }

    // MARK: - 2b. The auto-dev figure

    /// "3/5 auto-dev" is a screen reader's nightmare for the reason `figure`'s
    /// own comment gives: a number with no sentence around it says nothing to
    /// anyone who cannot see where it sits. And the state matters as much as the
    /// count — a running session and a finished one showing the same numbers are
    /// two different things to be told.
    ///
    /// ⛔ **It takes the session, not only the tally, and that is a correction to
    /// the plan rather than a preference.** The brief's signature was
    /// `autoDevFigure(state:tally:)`, reading `tally.settled` of `tally.total`.
    /// The *visible* figure beside it is `AutoDevBand.figureText`, which counts
    /// `session.engagedCardIDs`, and `AutoDevBand.swift:102` records that the two
    /// disagree *"in a window that happens on every single run — between the
    /// driver's `start` returning and its first engagements landing"*. So a
    /// session that engaged three cards would draw `0/3 auto-dev` and say *"0 of
    /// 0 cards settled"* on every run it ever makes. A tally cannot know the
    /// session's set, so the signature had to change: this is the one number the
    /// feature exists to state, and ``spokenFigureStatesTheVisibleNumbers``
    /// holds the two together.
    @Test("The auto-dev figure says the state and the count, in a sentence")
    func autoDevFigureIsASentence() {
        let five = AutoDevTally(engaged: 2, merged: 2, blocked: 1)
        #expect(
            BoardAccessibility.autoDevFigure(session: Self.session(cards: 5, state: .running), tally: five)
                == "Auto-dev running, 3 of 5 cards settled")
        #expect(
            BoardAccessibility.autoDevFigure(session: Self.session(cards: 5, state: .paused), tally: five)
                == "Auto-dev paused, 3 of 5 cards settled")
        #expect(
            BoardAccessibility.autoDevFigure(session: Self.session(cards: 5, state: .finished), tally: five)
                == "Auto-dev finished, 3 of 5 cards settled")
    }

    /// Singular written out by hand, as this file's header requires of every
    /// caption in it. "1 cards settled" is read aloud.
    ///
    /// ⚠️ **Two inputs, because one of them is degenerate.** 1-of-1 is the only
    /// case where the two candidate nouns agree, so on its own it says nothing
    /// about *which* number the noun counts: `cards(settled)` passes it and then
    /// reads *"1 of 2 card settled"* everywhere else. The second input is where
    /// they disagree, and it is the one that pins the total as the source.
    @Test("One card is a card, in the auto-dev figure too")
    func autoDevFigureSingular() {
        #expect(
            BoardAccessibility.autoDevFigure(
                session: Self.session(cards: 1, state: .finished),
                tally: AutoDevTally(engaged: 0, merged: 1, blocked: 0))
                == "Auto-dev finished, 1 of 1 card settled")
        #expect(
            BoardAccessibility.autoDevFigure(
                session: Self.session(cards: 2, state: .finished),
                tally: AutoDevTally(engaged: 1, merged: 1, blocked: 0))
                == "Auto-dev finished, 1 of 2 cards settled")
    }

    /// Over every case rather than a sample: a fourth state added without a
    /// phrase would be spoken as whatever the third one says.
    @Test("Every session state is spoken, and no two the same")
    func everyAutoDevStateIsSpoken() {
        let tally = AutoDevTally(engaged: 1, merged: 1, blocked: 0)
        let spoken = AutoDevSession.State.allCases.map {
            BoardAccessibility.autoDevFigure(session: Self.session(cards: 2, state: $0), tally: tally)
        }
        #expect(spoken.allSatisfy { !$0.isEmpty })
        #expect(Set(spoken).count == AutoDevSession.State.allCases.count)
    }

    /// ⛔ **The two halves of one figure must state one pair of numbers**, and
    /// nothing held that until now.
    ///
    /// The sighted reader gets `AutoDevBand.figureText`; the listening reader
    /// gets this sentence. Derived from *different* sources they drift silently
    /// and in the direction nobody checks — which is what the plan shipped, and
    /// what `AutoDevBand.settledCards` already exists to stop happening between
    /// the figure and the band's headline.
    ///
    /// The numbers are read back **out of** `figureText` rather than recomputed
    /// here, so this test cannot agree with a wrong answer by making the same
    /// mistake twice. The three inputs are the three ways the session and the
    /// rows can disagree: no rows yet (every run passes through it), more rows
    /// than the session engaged (a refresh returning stale rows — the `3/2`
    /// that shipped once), and the ordinary case where they match.
    @Test("The figure and its spoken sentence state the same two numbers")
    func spokenFigureStatesTheVisibleNumbers() throws {
        let cases: [(cards: Int, tally: AutoDevTally)] = [
            // The window between `start` returning and the first engagement row.
            (3, AutoDevTally(engaged: 0, merged: 0, blocked: 0)),
            // More settled rows than the session ever engaged.
            (2, AutoDevTally(engaged: 0, merged: 2, blocked: 1)),
            // The ordinary case.
            (4, AutoDevTally(engaged: 2, merged: 1, blocked: 1)),
        ]
        for (cards, tally) in cases {
            let session = Self.session(cards: cards, state: .running)
            let figure = try #require(AutoDevBand.figureText(session: session, tally: tally))
            let counts = figure.replacingOccurrences(of: " auto-dev", with: "")
                .components(separatedBy: "/")
            #expect(counts.count == 2, "figureText is no longer `settled/total auto-dev`: \(figure)")
            let spoken = BoardAccessibility.autoDevFigure(session: session, tally: tally)
            #expect(
                spoken.contains("\(counts[0]) of \(counts[1]) "),
                """
                The figure reads "\(figure)" and is spoken as "\(spoken)". Those are two answers to \
                the one number this feature exists to state. `AutoDevBand.settledCards` is the \
                numerator and `session.engagedCardIDs.count` is the denominator, for both.
                """)
        }
    }

    /// The figure is a door to the **report**, so its guard is "a session
    /// exists", never "a session is running". A session that failed everywhere
    /// is the one this feature has to leave visible: its cards stay in Done,
    /// where `Column.naturalNext` is `nil` and `rankNextSteps` drops them.
    ///
    /// It also pins **where the figure's text comes from**. `AutoDevBand.figureText`
    /// is that sentence and `AutoDevBandTests` holds it — including that it is
    /// present for a `finished` session. A second `"…/… auto-dev"` spelled out
    /// inline in the status bar would be two authors for one number, and the
    /// shipped one would be the untested one.
    ///
    /// ⚠️ **Scoped to `StatusBar`'s body, and read twice**, which is a correction
    /// to the brief. The brief asserted `!source.contains("model.autoDev?.state
    /// == .running")` over all ~1650 lines of `BoardView.swift`, so any future
    /// comment *explaining* why the figure is not gated on `.running` — the
    /// comment style this file uses everywhere — would redden it, and the
    /// cheapest way to green it would be to delete the explanation. That is
    /// `OperationsBandOrderTests`' subject one screen over, and CLAUDE.md's #186:
    /// a string gate over prose *"can tell neither a claim from a mention nor a
    /// live claim from a quoted one"*. The converse failure is held too — the
    /// comment cut hides a `//` inside a string literal, so the **negatives** are
    /// checked against both readings and the gate holds only where both agree.
    /// The **positives** are checked against the stripped reading alone: prose
    /// trailing a line of code must not be able to satisfy a claim about code.
    @Test("The figure is gated on a session existing, not on it running")
    func autoDevFigureSurvivesTheReport() throws {
        let readings = [
            try HiddenFaceState.code(of: "BoardView.swift"),
            try HiddenFaceState.codeLines(of: "BoardView.swift"),
        ]
        let bodies = try readings.map { reading -> String in
            let bar = try HiddenFaceState.body(of: "struct StatusBar: View", in: reading)
            return try HiddenFaceState.body(of: "var body: some View", in: bar)
        }

        // Positive witness, once per reading: a renamed or restructured strip
        // would make every claim below vacuously true and this gate would go
        // green having read nothing at all. Both readings need it, because the
        // negatives are checked against both — and the second one keeps trailing
        // comments, so a `{` written in one would throw its brace match off and
        // hand this test a slice of something else to find nothing in.
        for body in bodies {
            #expect(
                body.contains("model.occupancy.writers"),
                "this is not StatusBar's body any more — the gate is reading the wrong thing")
        }

        #expect(bodies[0].contains("if let autoDevSession = model.autoDev,"))
        #expect(
            bodies[0].contains("AutoDevBand.figureText("),
            "the status bar must render AutoDevBand's sentence, not build its own")

        // ⛔ **Every argument the figure is handed, pinned to a value, inside the
        // auto-dev block and nowhere wider.** Both halves of that are paid for.
        //
        // *A value, not a call somewhere near it*: a needle asserting that
        // `AutoDevBand.figureText(` appears is satisfied while the `text:` beside
        // it is composed inline — measured, the figure rendered
        // `"\(autoDevTally.settled)/\(autoDevTally.total) auto-dev"`, the wrong
        // pair of numbers and precisely the defect `autoDevFigure` was changed to
        // prevent, with every call-shaped needle still green.
        //
        // *Inside the block*: `face: .operations` is written on four figures in
        // this strip, so over the whole body it is the **workers** figure that
        // satisfies it. Measured too — scoped to `bodies[0]` this loop was green
        // with the auto-dev figure sending the reader to `.dismissed`, which is
        // the door opening onto the wrong screen in silence. `figure`'s own doc
        // says `face` was made a `ConsoleFace` because "a typo in that string
        // opened nothing at all, silently"; the type removed the typo and could
        // not remove the wrong case, and a needle read too wide removes neither.
        let autoDevBlock = try HiddenFaceState.body(
            of: "if let autoDevSession = model.autoDev,", in: bodies[0])
        for (argument, why) in [
            ("text: autoDevText", "the text must be AutoDevBand.figureText's, not composed here"),
            ("help: autoDevBand.headline", "the tooltip must be the band's headline, not written here"),
            ("tint: autoDevBand.tone.tint", "the tone is the band's and Consequence.swift maps it"),
            ("face: .operations", "this figure is the door into the auto-dev band, and no other screen"),
            (
                "BoardAccessibility.autoDevFigure(",
                "the spoken sentence must be the one a test can hold, not one written here"
            ),
            (
                "AutoDevBand.repoName(",
                """
                the Operations band asks the same function — a second lookup here is how the band \
                and the figure that is its door come to name two different repositories
                """
            ),
        ] {
            #expect(
                autoDevBlock.contains(argument),
                Comment(rawValue: "the auto-dev figure is not handed `\(argument)` — \(why)"))
        }

        // ⛔ **The guard, exactly**, because a *word* list cannot hold this
        // direction: banning `.finished` says nothing about
        // `if !autoDevBand.controls.isEmpty`, which is `[]` for exactly a
        // finished session and hides the figure for every one of them — the
        // outcome the failure message below describes, reached with no banned
        // word anywhere. A clause added to the `if let` (`autoDevTally.total > 0`)
        // does the same for the window before the first engagement row lands.
        //
        // So the condition is read back and compared whole. It fails loudly with
        // what it read, which is the right direction: a reformatting asks a
        // person to look; a new clause is the defect.
        #expect(
            try Self.autoDevGuard(in: bodies[0])
                == "letautoDevText=AutoDevBand.figureText(session:autoDevSession,tally:autoDevTally)",
            """
            The figure's guard is no longer "a session exists, and the band has a sentence for it". \
            Anything else in that condition is a way for the figure to disappear while the session \
            it reports still exists — and the report is the only surface that shows a card whose \
            merge failed, which stays in Done where `rankNextSteps` cannot see it.
            """)

        for body in bodies {
            // And the call is a **direct child** of that guard, at brace depth 0
            // inside it. This is the half that is a guarantee rather than a list:
            // a `ViewBuilder` cannot return early, so every nested branch is a
            // brace, whatever it is spelled — `controls.isEmpty`, a tally
            // threshold, or a condition nobody has thought of yet.
            let block = try HiddenFaceState.body(
                of: "if let autoDevSession = model.autoDev,", in: body)
            let depth = try #require(
                Self.braceDepth(of: "figure(", in: block),
                "the auto-dev block draws no figure at all — this gate is reading the wrong block")
            #expect(
                depth == 0,
                """
                The figure is nested \(depth) level(s) deep inside its own `if let`. Its only \
                guard is that a session exists; a branch around the call is a second one, and \
                whatever it tests, the figure vanishes for some session that has run. That is the \
                report disappearing — a card whose merge failed stays in Done, where \
                `Column.naturalNext` is nil and `rankNextSteps` drops it, so nothing else on the \
                board shows it.
                """)
        }

        for body in bodies {
            for comparison in ["model.autoDev ==", "model.autoDev !="] {
                #expect(
                    !body.contains(comparison),
                    Comment(
                        rawValue: """
                            The status bar carries `\(comparison)`. `if let` is the whole test \
                            this figure needs — a session exists or it does not — and a \
                            comparison is how a second condition, a ternary tint or a hiding \
                            opacity gets in beside it.
                            """))
            }
            for phase in [".running", ".paused", ".finished"] {
                #expect(
                    !body.contains(phase),
                    Comment(
                        rawValue: """
                            The status bar reads a session's phase (\(phase)). The figure is a \
                            door to the **report**, so its only guard is that a session exists: \
                            gated on the phase it disappears when the session ends, taking with \
                            it the one outcome nothing else on the board shows — a card whose \
                            merge failed stays in Done, where `Column.naturalNext` is nil and \
                            `rankNextSteps` drops it. What the phase means is `AutoDevBand`'s \
                            answer, not this strip's.
                            """))
            }
            for shape in [".hidden()", ".opacity("] {
                #expect(
                    !body.contains(shape),
                    Comment(
                        rawValue: """
                            The status bar carries `\(shape)`. A branch is not the only way for \
                            the figure to disappear, and a hiding modifier makes it vanish for \
                            exactly the session it exists to report.
                            """))
            }
        }
    }

    /// The whole condition of the auto-dev `if let`, whitespace squashed.
    ///
    /// Everything between the clause that names the session and the `{` that
    /// opens the block — so a clause added anywhere in it changes this string.
    /// Squashed because the condition is hand-wrapped over three lines and a
    /// reformat is not a defect; a new clause is.
    private static func autoDevGuard(in body: String) throws -> String {
        let signature = "if let autoDevSession = model.autoDev,"
        let start = try #require(
            body.range(of: signature),
            "the status bar no longer opens the figure with `\(signature)`")
        let rest = body[start.upperBound...]
        let brace = try #require(
            rest.firstIndex(of: "{"), "the auto-dev condition never opens a block")
        return rest[..<brace].filter { !$0.isWhitespace }
    }

    /// How many braces deep the first occurrence of `needle` sits, or `nil` if
    /// it does not occur.
    ///
    /// The structural half of the presence gate. A `ViewBuilder` cannot return
    /// early, so *every* way of not drawing something is a brace — which makes
    /// depth an answer about shape rather than about vocabulary.
    private static func braceDepth(of needle: String, in block: String) -> Int? {
        var depth = 0
        var index = block.startIndex
        while index < block.endIndex {
            if block[index...].hasPrefix(needle) { return depth }
            if block[index] == "{" { depth += 1 }
            if block[index] == "}" { depth -= 1 }
            index = block.index(after: index)
        }
        return nil
    }

    /// One session with `cards` engaged cards. The ids are the only thing the
    /// figure reads off it, so they are the only thing that has to be plausible.
    private static func session(cards: Int, state: AutoDevSession.State) -> AutoDevSession {
        AutoDevSession(
            repoID: UUID(),
            engagedCardIDs: (0..<cards).map { _ in UUID() },
            maxAttemptsPerCard: 3,
            patience: 600,
            startedAt: Date(timeIntervalSince1970: 0),
            state: state
        )
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
