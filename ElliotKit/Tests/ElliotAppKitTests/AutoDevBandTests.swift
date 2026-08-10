import ElliotModel
import Foundation
import Testing

@testable import ElliotAppKit

/// The auto-dev band's sentences, held where `swift test` can reach them.
///
/// The same argument `AnalysisFooterMessageTests` makes one file over: a
/// sentence written inline in a `body` is a claim nothing can hold, and this
/// band has three states, three controls and a figure to keep consistent with
/// each other.
@Suite("Auto-dev band")
struct AutoDevBandTests {

    private let epoch = Date(timeIntervalSince1970: 1_770_000_000)

    private func session(
        _ state: AutoDevSession.State, cards: Int = 5
    ) -> AutoDevSession {
        AutoDevSession(
            repoID: UUID(), engagedCardIDs: (0..<cards).map { _ in UUID() },
            maxAttemptsPerCard: 3, patience: 900, startedAt: epoch, state: state
        )
    }

    /// Rows for a session that has reported nothing yet.
    private let noRows = AutoDevTally(engaged: 0, merged: 0, blocked: 0)

    // MARK: - Totality

    /// ⛔ The whole difference from `preflightBand`, which is *meant* to vanish.
    /// Preflight is a state nobody has to remember; a session's outcome is a
    /// record. A function with no optional return is what stops this band
    /// becoming conditional by accident.
    ///
    /// Driven off `allCases` rather than a written-out list, so a fourth state
    /// is checked here the moment it exists — the exhaustive `switch` in `of`
    /// makes it a compile error, and this makes the *sentence* a test failure.
    @Test("There is a band for every input, including no session at all")
    func ofIsTotal() {
        let states: [AutoDevSession.State?] = [nil] + AutoDevSession.State.allCases.map { $0 }
        for state in states {
            let band = AutoDevBand.of(
                session: state.map { session($0) },
                tally: AutoDevTally(engaged: 2, merged: 2, blocked: 1),
                repoName: "Elliot"
            )
            #expect(!band.headline.isEmpty, "\(String(describing: state)) has no headline")
            #expect(!band.runNote.isEmpty, "\(String(describing: state)) has no run note")
        }
    }

    /// ⚠️ `band == AutoDevBand.idle` alone is a tautology — `of` returns that
    /// very value — so the idle **sentence** was pinned by nothing. The
    /// literals are what a reader sees, and what nothing else may say.
    @Test("With no session the band says so and offers no control")
    func idleBand() {
        let band = AutoDevBand.of(session: nil, tally: noRows, repoName: "Elliot")
        #expect(band == AutoDevBand.idle)
        #expect(band.headline == "Elliot is not driving anything by itself.")
        #expect(band.runNote == "Nothing is running.")
        #expect(band.controls.isEmpty)
        #expect(band.tone == .quiet)
    }

    /// ⛔ *Never let two different facts produce the same sentence.* Four bands,
    /// four states of the world, and both sentences distinct across all of them
    /// — the idle band's especially, since a state that drifted onto its
    /// wording would read as *"Elliot is not driving anything by itself"* while
    /// it drove.
    @Test("No two bands say the same thing")
    func bandsAreDistinct() {
        let bands = labelledBands(tally: AutoDevTally(engaged: 3, merged: 1, blocked: 1))
        #expect(Set(bands.map(\.band.headline)).count == bands.count)
        #expect(Set(bands.map(\.band.runNote)).count == bands.count)
    }

    /// Every band this type can produce, named — the three states plus idle,
    /// which is a band no `AutoDevSession.State` reaches.
    private func labelledBands(
        tally: AutoDevTally, cards: Int = 5
    ) -> [(name: String, band: AutoDevBand)] {
        var bands: [(name: String, band: AutoDevBand)] = [("idle", .idle)]
        for state in AutoDevSession.State.allCases {
            bands.append(
                (
                    "\(state)",
                    AutoDevBand.of(
                        session: session(state, cards: cards), tally: tally, repoName: "Elliot")
                ))
        }
        return bands
    }

    // MARK: - The three states

    @Test("A running session names the repository, the count and what is left")
    func runningBand() {
        let band = AutoDevBand.of(
            session: session(.running), tally: AutoDevTally(engaged: 3, merged: 1, blocked: 1),
            repoName: "Elliot")
        #expect(band.headline == "Driving 5 cards in Elliot — 2 settled, 3 to go.")
        #expect(band.tone == .armed)
        #expect(band.controls == [.pause, .stop])
    }

    @Test("A paused session offers Resume in Pause's place, and keeps Stop")
    func pausedBand() {
        let band = AutoDevBand.of(
            session: session(.paused), tally: AutoDevTally(engaged: 3, merged: 1, blocked: 1),
            repoName: "Elliot")
        #expect(band.headline == "Paused — 5 cards engaged in Elliot, 2 settled.")
        #expect(band.tone == .attention)
        #expect(band.controls == [.resume, .stop])
    }

    /// The report is a record, so it keeps its sentence and loses its controls
    /// — there is nothing left to pause or to cancel.
    @Test("A finished session reports what happened and offers nothing")
    func finishedBand() {
        let band = AutoDevBand.of(
            session: session(.finished), tally: AutoDevTally(engaged: 0, merged: 3, blocked: 2),
            repoName: "Elliot")
        #expect(band.headline == "Finished — 5 cards in Elliot, 3 merged, 2 blocked.")
        #expect(band.controls.isEmpty)
        #expect(band.runNote.contains("Nothing is running"))
    }

    /// A session that blocked everything must not read like a quiet success.
    /// It is also the one outcome nothing else on the board can show: a card
    /// whose merge failed stays in Done, and `Column.naturalNext` is `nil` for
    /// `.done`, so `rankNextSteps` drops it from Up next entirely.
    @Test("A finished session with blocked cards is refused, a clean one is quiet")
    func finishedTone() {
        let dirty = AutoDevBand.of(
            session: session(.finished), tally: AutoDevTally(engaged: 0, merged: 3, blocked: 2),
            repoName: "Elliot")
        #expect(dirty.tone == .refused)

        let clean = AutoDevBand.of(
            session: session(.finished), tally: AutoDevTally(engaged: 0, merged: 5, blocked: 0),
            repoName: "Elliot")
        #expect(clean.tone == .quiet)
    }

    /// ⚠️ **What the band says today about a state nobody has written a sentence
    /// for**: a session that finished with fewer rows than it engaged.
    ///
    /// It reports the rows as rows — three merged, none blocked — names nothing
    /// about the two cards they do not account for, and is `quiet`. That is a
    /// deliberate boundary rather than a decision: `merged` and `blocked` are
    /// counts of things that happened, and clamping *them* would falsify a
    /// record, where clamping ``AutoDevTally/settled`` only bounds a derived
    /// figure. This pins the wording so that deciding a quiet success on
    /// incomplete data is wrong becomes a change to a named assertion instead of
    /// a discovery on screen.
    @Test("A finished session with fewer rows than cards reports only what the rows say")
    func finishedWithFewerRowsThanCards() {
        let partial = AutoDevTally(engaged: 0, merged: 3, blocked: 0)
        let band = AutoDevBand.of(
            session: session(.finished, cards: 5), tally: partial, repoName: "Elliot")
        #expect(band.headline == "Finished — 5 cards in Elliot, 3 merged, 0 blocked.")
        #expect(band.tone == .quiet)
        #expect(band.controls.isEmpty)
        // The figure is the one place the shortfall is visible at all.
        #expect(
            AutoDevBand.figureText(session: session(.finished, cards: 5), tally: partial)
                == "3/5 auto-dev")
    }

    @Test("One card is a card")
    func singularIsWrittenOut() {
        let band = AutoDevBand.of(
            session: session(.running, cards: 1),
            tally: AutoDevTally(engaged: 1, merged: 0, blocked: 0),
            repoName: "Elliot")
        #expect(band.headline == "Driving 1 card in Elliot — 0 settled, 1 to go.")
        #expect(!band.headline.contains("1 cards"))
    }

    // MARK: - The count is the session's, never the rows'

    /// ⛔ The band's noun counts ``AutoDevSession/engagedCardIDs``, not
    /// ``AutoDevTally/total``, and this is the window where the two disagree:
    /// the driver's `start` has returned — the cards on the board already carry
    /// the bolt — and not one engagement row has landed yet. Counting the rows
    /// makes the band read *"Driving 0 cards in Elliot — 0 settled, 0 to go."*
    /// underneath three marked cards, for the first moments of **every** run.
    @Test("A session whose rows have not arrived still says how many cards it drives")
    func countsTheSessionNotTheRows() {
        let band = AutoDevBand.of(
            session: session(.running, cards: 3), tally: noRows, repoName: "Elliot")
        #expect(band.headline == "Driving 3 cards in Elliot — 0 settled, 3 to go.")
        #expect(AutoDevBand.figureText(session: session(.running, cards: 3), tally: noRows)
            == "0/3 auto-dev")
    }

    /// The same disagreement one refresh later, and pointed the other way: a
    /// pass that returns *fewer* rows than the session engaged. The count must
    /// not shrink under the marks already on the board.
    @Test("A partial refresh does not shrink the count")
    func partialRowsDoNotShrinkTheCount() {
        let partial = AutoDevTally(engaged: 1, merged: 1, blocked: 0)
        let band = AutoDevBand.of(
            session: session(.running, cards: 4), tally: partial, repoName: "Elliot")
        #expect(band.headline == "Driving 4 cards in Elliot — 1 settled, 3 to go.")
        #expect(AutoDevBand.figureText(session: session(.running, cards: 4), tally: partial)
            == "1/4 auto-dev")

        let held = AutoDevBand.of(
            session: session(.paused, cards: 4), tally: partial, repoName: "Elliot")
        #expect(held.headline == "Paused — 4 cards engaged in Elliot, 1 settled.")
    }

    /// The disagreement's third shape, and the only one that produces nonsense
    /// rather than an understatement: more rows settled than the session ever
    /// engaged — a session row read beside engagements fresher than it is.
    ///
    /// ⛔ **Both surfaces, because the clamp shipped on one.** The headline read
    /// *"2 settled, 0 to go"* while the figure beside it read **`3/2 auto-dev`**
    /// — the loud failure the clamp exists to avoid, on the more visible of the
    /// two, and the one number this whole type exists to state once.
    ///
    /// ⚠️ The clamp itself was written because break-testing found it pinned by
    /// nothing: deleting it left every other test green, which is a finding
    /// rather than a pass. It was then asserted on the headline alone, which is
    /// the same lesson one surface over.
    @Test("More settled rows than engaged cards is clamped on the band and on the figure")
    func settledNeverExceedsTheEngagedSet() {
        // A repository name carrying a hyphen on purpose: the assertion below
        // must be about a negative number, not about this fixture happening to
        // be spelled without one.
        let impossible = AutoDevTally(engaged: 0, merged: 2, blocked: 1)
        let band = AutoDevBand.of(
            session: session(.running, cards: 2), tally: impossible, repoName: "repo-audit")
        #expect(band.headline == "Driving 2 cards in repo-audit — 2 settled, 0 to go.")
        // The separator above is an em dash, U+2014. A hyphen-minus *following a
        // space* could only be introducing a negative count.
        #expect(!band.headline.contains(" -"))
        #expect(band.headline.contains("repo-audit"))

        #expect(
            AutoDevBand.figureText(session: session(.running, cards: 2), tally: impossible)
                == "2/2 auto-dev")

        let held = AutoDevBand.of(
            session: session(.paused, cards: 2), tally: impossible, repoName: "repo-audit")
        #expect(held.headline == "Paused — 2 cards engaged in repo-audit, 2 settled.")
    }

    // MARK: - The controls say what they do to the run already going

    /// The design's requirement, word for word: the stop control says on its
    /// face what it does to the run already in flight, and it cannot lean on
    /// the queue's Pause, which holds *queued* runs and leaves the running one
    /// alone.
    @Test("Stop says it cancels the run already going; Pause says it does not")
    func controlsNameTheRunInFlight() {
        #expect(AutoDevBand.title(.stop) == "Stop and cancel")
        #expect(AutoDevBand.explains(.stop).contains("cancels the run already going"))
        #expect(AutoDevBand.explains(.pause).contains("run already going finishes"))
        // And the band repeats it where a title has no room: the same shape
        // `queueSentence` uses in the band above this one.
        let band = AutoDevBand.of(
            session: session(.running), tally: AutoDevTally(engaged: 5, merged: 0, blocked: 0),
            repoName: "Elliot")
        #expect(band.runNote.contains("already going"))
        #expect(band.runNote.contains("cancels"))
    }

    @Test("Every control has a distinct title and a distinct explanation")
    func controlsAreDistinct() {
        let titles = AutoDevBand.Control.allCases.map(AutoDevBand.title)
        let explains = AutoDevBand.Control.allCases.map(AutoDevBand.explains)
        #expect(Set(titles).count == AutoDevBand.Control.allCases.count)
        #expect(Set(explains).count == AutoDevBand.Control.allCases.count)
        #expect(titles.allSatisfy { !$0.isEmpty })
        #expect(explains.allSatisfy { $0.hasSuffix(".") })
    }

    /// ⛔ **Both directions, over all four bands.**
    ///
    /// A note that names a control the band does *not* offer is a remedy printed
    /// under a screen that cannot perform it — `AnalysisFooterMessage`'s defect,
    /// one band over. The paused band is the one that catches: it drops Pause
    /// for Resume, so a note written once for both live states tells the reader
    /// to press something that is not there.
    ///
    /// ⚠️ The other direction is the half that was **missing until fix round 1**,
    /// and its absence let a note naming *neither* paused control pass. It is
    /// the same defect pointed the other way: this value exists precisely
    /// because a control's title has no room to say what pressing it does to the
    /// run already going, so a button the note skips is a button the reader has
    /// to press to find out about.
    ///
    /// The word is derived from ``AutoDevBand/title(_:)`` rather than written
    /// out, so renaming a control cannot leave this checking a word nothing says.
    @Test("A band's run note names exactly the controls that band offers")
    func runNoteNamesExactlyTheControlsOffered() {
        for (name, band) in labelledBands(tally: AutoDevTally(engaged: 3, merged: 1, blocked: 1)) {
            for control in AutoDevBand.Control.allCases {
                let word = String(AutoDevBand.title(control).split(separator: " ")[0])
                if band.controls.contains(control) {
                    #expect(
                        band.runNote.contains(word),
                        "\(name)'s run note offers \(word) and never says what it does")
                } else {
                    #expect(
                        !band.runNote.contains(word),
                        "\(name)'s run note names \(word), which that band does not offer")
                }
            }
        }
    }

    /// Two states that offer different controls must not answer with one
    /// sentence: the note is what the reader consults to find out what the
    /// buttons in front of them do.
    @Test("Running and paused do not share a run note")
    func liveStatesDoNotShareANote() {
        let tally = AutoDevTally(engaged: 3, merged: 1, blocked: 1)
        let running = AutoDevBand.of(session: session(.running), tally: tally, repoName: "Elliot")
        let paused = AutoDevBand.of(session: session(.paused), tally: tally, repoName: "Elliot")
        #expect(running.runNote != paused.runNote)
        #expect(paused.runNote.contains("already going"))
        #expect(paused.runNote.contains("cancels"))
    }

    // MARK: - Why this band is not Up next

    /// Two orders stacked in one window read as one unless the top one says it
    /// is not the same order. Both bands read `rankNextSteps`' world; only one
    /// of them is a ranking.
    @Test("The caption says it answers a different question from Up next")
    func captionDistinguishesItselfFromUpNext() {
        #expect(AutoDevBand.caption.contains("Up next"))
        #expect(AutoDevBand.caption.contains("not a ranking"))
    }

    // MARK: - The status bar's figure

    /// ⚠️ `nil` only when **no session has run this launch** — never because a
    /// session finished. The report is a record, and the figure is its door.
    @Test("The figure is absent only when no session exists")
    func figureIsPermanentThroughTheReport() {
        let tally = AutoDevTally(engaged: 0, merged: 3, blocked: 2)
        #expect(AutoDevBand.figureText(session: nil, tally: tally) == nil)
        for state in AutoDevSession.State.allCases {
            #expect(
                AutoDevBand.figureText(session: session(state), tally: tally) == "5/5 auto-dev",
                "\(state) lost the figure"
            )
        }
    }

    @Test("The figure counts settled against the whole engaged set")
    func figureCounts() {
        #expect(
            AutoDevBand.figureText(
                session: session(.running), tally: AutoDevTally(engaged: 3, merged: 1, blocked: 1)
            ) == "2/5 auto-dev"
        )
    }

    // MARK: - The mark on an engaged card

    @Test("The engaged mark is named, because a card is one accessibility element")
    func engagedMarkIsNamed() {
        // The glyph itself, not merely that there is one: an SF Symbol name
        // that does not resolve renders as nothing at all, and a card silently
        // missing its bolt is the state this whole band exists to contradict.
        #expect(AutoDevBand.engagedSymbol == "bolt.circle.fill")
        #expect(!AutoDevBand.engagedSymbol.isEmpty)
        #expect(AutoDevBand.engagedLabel.hasSuffix("."))
        #expect(AutoDevBand.engagedLabel.lowercased().contains("auto-dev"))
    }
}
