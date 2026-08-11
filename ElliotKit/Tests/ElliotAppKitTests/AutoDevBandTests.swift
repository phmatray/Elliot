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

    // MARK: - A finished session that still has a live run

    /// ⛔ **The sentence this task's own brief exists to fix.** `AutoDevPolicy`'s
    /// `.runAlreadyInFlight` branch never consults `RunState`, so patience expiry
    /// can settle every engaged card — and so the whole session — while a
    /// `.mergePR` run behind one of them is genuinely still `.running`;
    /// `AutoDevService.finish()` correctly leaves that run alone rather than
    /// cancel it. A live `claude -p` child can therefore outlive a session the
    /// band reports as fully stopped, and "Nothing is running." would be a
    /// straightforward lie in that state.
    @Test("A finished session with a live run says so, truthfully, instead of 'Nothing is running'")
    func finishedWithLiveRunTellsTheTruth() {
        let band = AutoDevBand.of(
            session: session(.finished), tally: AutoDevTally(engaged: 0, merged: 3, blocked: 0),
            repoName: "Elliot", hasLiveRun: true)
        #expect(!band.runNote.contains("Nothing is running"))
        #expect(band.runNote.contains("still going"))
        // The report's permanence is still stated — a live run does not make
        // the record disappear any sooner than a quiet one does.
        #expect(band.runNote.contains("This report stays until the next session starts."))
        #expect(band.controls.isEmpty, "a live run belongs to the run scheduler now, not to a control here")
    }

    /// The default matters as much as the new branch: every existing caller and
    /// every other test in this file calls `AutoDevBand.of` without naming
    /// `hasLiveRun` at all, and all of them must keep reading the old sentence.
    @Test("Omitting hasLiveRun reads exactly as it always did")
    func hasLiveRunDefaultsToTheOldSentence() {
        let band = AutoDevBand.of(
            session: session(.finished), tally: AutoDevTally(engaged: 0, merged: 3, blocked: 0),
            repoName: "Elliot")
        #expect(band.runNote == "Nothing is running. This report stays until the next session starts.")
    }

    /// A blocked card is still the more urgent fact: a session that both left a
    /// run going *and* blocked a card reads as refused, not merely attention —
    /// it failed somewhere, and that outranks "something is still moving."
    @Test("A live run alone is attention; a blocked card is refused regardless")
    func liveRunToneRanksBelowBlocked() {
        let quietlyLive = AutoDevBand.of(
            session: session(.finished), tally: AutoDevTally(engaged: 0, merged: 3, blocked: 0),
            repoName: "Elliot", hasLiveRun: true)
        #expect(quietlyLive.tone == .attention)

        let blockedAndLive = AutoDevBand.of(
            session: session(.finished), tally: AutoDevTally(engaged: 0, merged: 1, blocked: 2),
            repoName: "Elliot", hasLiveRun: true)
        #expect(blockedAndLive.tone == .refused)
    }

    /// `hasLiveRun` is read only for `.finished` — a running or paused session
    /// already has its own truthful account of what is going on, and the
    /// parameter must not perturb either.
    @Test("hasLiveRun changes nothing about a running or a paused band")
    func hasLiveRunIsIgnoredOutsideFinished() {
        let tally = AutoDevTally(engaged: 3, merged: 1, blocked: 1)
        let runningIgnored = AutoDevBand.of(
            session: session(.running), tally: tally, repoName: "Elliot", hasLiveRun: true)
        let runningDefault = AutoDevBand.of(session: session(.running), tally: tally, repoName: "Elliot")
        #expect(runningIgnored == runningDefault)

        let pausedIgnored = AutoDevBand.of(
            session: session(.paused), tally: tally, repoName: "Elliot", hasLiveRun: true)
        let pausedDefault = AutoDevBand.of(session: session(.paused), tally: tally, repoName: "Elliot")
        #expect(pausedIgnored == pausedDefault)
    }

    /// ⛔ **Both directions, the same discipline `runNoteNamesExactlyTheControlsOffered`
    /// already holds this file to.** A finished band with a live run still offers
    /// no controls, so its note must not accidentally start naming one just
    /// because the sentence changed.
    @Test("The live-run sentence names no control the finished band does not offer")
    func liveRunSentenceNamesNoControl() {
        let band = AutoDevBand.of(
            session: session(.finished), tally: AutoDevTally(engaged: 0, merged: 3, blocked: 0),
            repoName: "Elliot", hasLiveRun: true)
        for control in AutoDevBand.Control.allCases {
            let word = String(AutoDevBand.title(control).split(separator: " ")[0])
            #expect(!band.runNote.contains(word), "the live-run sentence names \(word)")
        }
    }

    // MARK: - A finished session that still has engaged rows — stop() mid-flight

    /// ⛔ **Fix round 1, Important 2.** `stop(sessionID:)` (`AutoDevService.swift`)
    /// is the one production path that can reach `.finished` with a row still
    /// `.engaged`: the automatic path never calls `finish()` until every row is
    /// settled. Before this fix the sentence below silently dropped every
    /// abandoned card — "Finished — 5 cards…, 2 merged, 0 blocked" for a session
    /// that still had 3 `.engaged` — reading as a clean, unremarkable success.
    /// PR5's inherited contract 4, quoted in the override: *"a `.finished`
    /// session whose engagement rows fall short reads as a quiet success ...
    /// the band needs a sentence it does not have."*
    @Test("A finished session with engaged rows says the reader stopped it, not that it merely finished")
    func stoppedMidFlightTellsTheTruth() {
        let band = AutoDevBand.of(
            session: session(.finished), tally: AutoDevTally(engaged: 3, merged: 2, blocked: 0),
            repoName: "Elliot")
        #expect(band.headline.hasPrefix("Stopped —"))
        #expect(band.headline.contains("2 merged"))
        #expect(band.headline.contains("3 left mid-flight"))
        #expect(!band.headline.hasPrefix("Finished —"))
        #expect(band.runNote.contains("stopped this session"))
        #expect(!band.runNote.contains("Nothing is running"))
        // The permanence clause survives here too — a mid-flight stop does not
        // make the record disappear any sooner than a clean finish does.
        #expect(band.runNote.contains("This report stays until the next session starts."))
        #expect(band.controls.isEmpty, "the report is a record; there is nothing left to press")
    }

    /// The exact discriminator, proven rather than assumed: the same merged
    /// and blocked counts, one card apart in `engaged`, must render two
    /// different headlines.
    @Test("Zero engaged rows reads as a clean finish; any engaged rows read as a stop")
    func engagedCountIsTheDiscriminator() {
        let clean = AutoDevBand.of(
            session: session(.finished, cards: 5), tally: AutoDevTally(engaged: 0, merged: 3, blocked: 0),
            repoName: "Elliot")
        #expect(clean.headline.hasPrefix("Finished —"))

        let stopped = AutoDevBand.of(
            session: session(.finished, cards: 5), tally: AutoDevTally(engaged: 1, merged: 3, blocked: 0),
            repoName: "Elliot")
        #expect(stopped.headline.hasPrefix("Stopped —"))
    }

    /// Blocked still outranks a mid-flight stop, the same ordering `hasLiveRun`
    /// already carries below: a session that both blocked a card *and* left
    /// others engaged is a session that failed somewhere, first and foremost.
    @Test("A mid-flight stop is attention alone; a blocked card is refused regardless")
    func stoppedMidFlightToneRanksBelowBlocked() {
        let attentionOnly = AutoDevBand.of(
            session: session(.finished), tally: AutoDevTally(engaged: 2, merged: 3, blocked: 0),
            repoName: "Elliot")
        #expect(attentionOnly.tone == .attention)

        let blockedAndStopped = AutoDevBand.of(
            session: session(.finished), tally: AutoDevTally(engaged: 2, merged: 1, blocked: 2),
            repoName: "Elliot")
        #expect(blockedAndStopped.tone == .refused)
    }

    /// The stopped-mid-flight sentence offers no controls either — the same
    /// obligation `liveRunSentenceNamesNoControl` holds the live-run sentence
    /// to, applied to its sibling.
    @Test("The stopped-mid-flight sentence names no control the finished band does not offer")
    func stoppedMidFlightSentenceNamesNoControl() {
        let band = AutoDevBand.of(
            session: session(.finished), tally: AutoDevTally(engaged: 3, merged: 2, blocked: 0),
            repoName: "Elliot")
        for control in AutoDevBand.Control.allCases {
            let word = String(AutoDevBand.title(control).split(separator: " ")[0])
            #expect(!band.runNote.contains(word), "the stopped-mid-flight sentence names \(word)")
        }
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

    // MARK: - Which repository the session is about

    /// One repository named by one function, because two surfaces ask.
    ///
    /// The band's headline says it and the status bar's figure is that band's
    /// door; a private copy on each is two answers to one question, in one
    /// module, waiting to drift. The plan had exactly that, and its audit caught
    /// it before either copy existed.
    @Test("The session's repository is the one named, whatever the picker is on")
    func repoNameFollowsTheSession() {
        let driven = Repo(path: "/tmp/driven", nameWithOwner: "o/driven", displayName: "Driven")
        let picked = Repo(path: "/tmp/picked", nameWithOwner: "o/picked", displayName: "Picked")
        var live = session(.running)
        live.repoID = driven.id

        #expect(
            AutoDevBand.repoName(
                session: live, selectedRepoID: picked.id, repos: [driven, picked]) == "Driven")
    }

    /// Before a session exists the band still has a sentence to write, and the
    /// picker is what it is about — this is the state the Start control speaks
    /// from.
    @Test("With no session the picker's repository is named")
    func repoNameFallsBackToThePicker() {
        let picked = Repo(path: "/tmp/picked", nameWithOwner: "o/picked", displayName: "Picked")
        #expect(
            AutoDevBand.repoName(session: nil, selectedRepoID: picked.id, repos: [picked])
                == "Picked")
    }

    /// ⛔ A session naming a repository the board no longer holds does **not**
    /// fall through to the picker: that would print a different repository's
    /// name into a sentence about this session, which is a wrong fact the reader
    /// has no way to catch.
    @Test("A session whose repository is gone is not renamed after the picker's")
    func repoNameDoesNotBorrowThePickersRepository() {
        let picked = Repo(path: "/tmp/picked", nameWithOwner: "o/picked", displayName: "Picked")
        var orphan = session(.finished)
        orphan.repoID = UUID()

        let named = AutoDevBand.repoName(
            session: orphan, selectedRepoID: picked.id, repos: [picked])
        #expect(named != "Picked")
        #expect(named == "no repository")
    }

    /// Never blank, in any of the four ways it can fail to resolve: the headline
    /// interpolates this, and *"Driving 3 cards in  — 1 settled"* reads as a
    /// rendering fault rather than as a missing registration.
    @Test("There is always a name")
    func repoNameIsNeverBlank() {
        let cases: [(AutoDevSession?, UUID?, [Repo])] = [
            (nil, nil, []),
            (nil, UUID(), []),
            (session(.running), nil, []),
            (session(.paused), UUID(), []),
        ]
        for (live, picked, repos) in cases {
            let named = AutoDevBand.repoName(session: live, selectedRepoID: picked, repos: repos)
            #expect(!named.isEmpty)
            #expect(!named.hasPrefix(" "))
        }
    }

    // MARK: - Where the tone meets SwiftUI

    /// The band holds no `Color`; `Consequence.swift` is the one file where this
    /// project's values meet SwiftUI, so the decision is what a test can hold.
    /// That the band holds none is gated by
    /// `OperationsBandOrderTests.theColourIsDecidedInConsequence`, which reads
    /// the file — a comment saying so was all that held it until fix round 1.
    ///
    /// ⚠️ These two restate the mapping one for one, and what earns their place
    /// is the two *decisions* in it: `merged → verified` rather than
    /// `irreversible` (the merge has happened and `gh` confirmed it), and
    /// `quiet → Palette.quiet`, greyscale, spending none of the accent budget. A
    /// regression of either reddens. `Tone` is not `CaseIterable`, so the four
    /// cases are written out; only ``dispositionMarksAreDistinct`` below is
    /// driven off `allCases`, and an earlier version of this comment claimed
    /// otherwise.
    @Test("Every tone has its consequence colour, and quiet spends no accent")
    func tonesAreTinted() {
        #expect(AutoDevBand.Tone.armed.tint == Palette.armed)
        #expect(AutoDevBand.Tone.attention.tint == Palette.attention)
        #expect(AutoDevBand.Tone.refused.tint == Palette.refused)
        #expect(AutoDevBand.Tone.quiet.tint == Palette.quiet)
    }

    /// `merged` is `verified` rather than `irreversible`: the merge has already
    /// happened and `gh` confirmed it, which is exactly what `verified` means.
    @Test("A merged card is verified, a blocked one refused, an engaged one armed")
    func dispositionsAreTinted() {
        #expect(AutoDevDisposition.engaged.tint == Palette.armed)
        #expect(AutoDevDisposition.merged.tint == Palette.verified)
        #expect(AutoDevDisposition.blocked.tint == Palette.refused)
    }

    /// The distinctness rather than the choices: a report where a merged card
    /// and a blocked one carry the same mark has to be read twice to say what it
    /// already said, and an empty symbol name renders as nothing at all — the
    /// silent-absence failure this band exists to contradict.
    @Test("No two dispositions wear the same mark, and none wears none")
    func dispositionMarksAreDistinct() {
        let icons = AutoDevDisposition.allCases.map(\.icon)
        #expect(icons.allSatisfy { !$0.isEmpty })
        #expect(Set(icons).count == AutoDevDisposition.allCases.count)
        // The engaged mark is the board's own bolt: a card wearing it and its
        // row in the report must not disagree about what it means.
        #expect(AutoDevDisposition.engaged.icon == AutoDevBand.engagedSymbol)
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
