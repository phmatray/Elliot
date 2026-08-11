import ElliotModel
import Foundation

/// What the auto-dev band says, decided once.
///
/// The band renders it and judges nothing, for the reason `AnalysisFooterMessage`
/// gives one file over: `swift test` cannot enter a view body, so a sentence
/// written inline there is a claim nothing can hold — and this one has three
/// states, three controls and a status-bar figure that all have to agree.
///
/// It holds no `Color`. ``Tone`` is mapped to `Palette` in `Consequence.swift`,
/// the one file where this project's values meet SwiftUI, so a test asserts the
/// decision rather than a colour — and a value that cannot name a colour cannot
/// be where a sixth consequence accent arrives.
///
/// ⛔ **``of(session:tally:repoName:)`` returns a band for every input,
/// including no session at all.** That totality is the difference from
/// `OperationsView.preflightBand`, which is *meant* to vanish: preflight is a
/// **state** nobody has to remember, and a session's outcome is a **record**.
/// The record it has to carry is the failure — `Column.naturalNext` is `nil`
/// for `.done`, so a card whose merge failed, which stays in Done with a
/// `lastError`, is structurally absent from what `rankNextSteps` ranks and so
/// from `UpNextBand`. This is the only surface that shows it, which is why it
/// is permanent rather than conditional.
struct AutoDevBand: Equatable {

    /// Four, and none of them a sixth accent: three are `BrandColor.consequences`
    /// and `quiet` is greyscale.
    enum Tone: Equatable {
        case armed
        case attention
        case refused
        case quiet
    }

    /// A control the band offers.
    ///
    /// ``stop`` is the one that reaches the run already going. The queue's
    /// Pause cannot: `RunScheduler.pause` holds *queued* runs and leaves the
    /// running one alone, so a session cannot lean on it to stop.
    enum Control: Hashable, CaseIterable {
        case pause
        case resume
        case stop
    }

    /// The mark drawn on an engaged card, and the sentence read in its place.
    ///
    /// A card is one combined accessibility element, so an unlabelled glyph is
    /// read aloud as whatever the system calls the character, jammed against the
    /// title — the same reason `CardView`'s lens mark carries a label.
    static let engagedSymbol = "bolt.circle.fill"
    static let engagedLabel = "Auto-dev is driving this card."

    /// Why this band sits immediately above Up next and answers a different
    /// question.
    ///
    /// Not an arbitrary neighbour: Up next is the ranking of possible moves,
    /// auto-dev is one fixed set of them being made, and both read the world
    /// `rankNextSteps` ranks. Two orders stacked in one window read as one
    /// unless the top one says it is not the same order.
    static let caption =
        "Up next below ranks every move Elliot could make, best first. This is the one "
        + "set of cards Elliot is moving by itself — fixed when the session started, "
        + "and not a ranking."

    let headline: String
    /// What the controls do to the run already going.
    ///
    /// Its own sentence, for the reason `queueSentence` is one: a control's
    /// title has no room for it, and a Stop that does not say it cancels the
    /// run is a Stop the reader has to press to find out about.
    ///
    /// ⛔ **One note per set of controls, never one note for two sets, and each
    /// written beside the controls it is about.** A note shared between running
    /// and paused names *Pause* on the screen that dropped Pause for Resume — a
    /// remedy printed under a screen that cannot perform it, which is
    /// `AnalysisFooterMessage`'s own defect one band over, and the reason its
    /// `fixes` travel with its `text` rather than being read separately.
    ///
    /// ⛔ **And the obligation runs both ways: a note must name every control
    /// its band *does* offer.** A screen whose buttons the note does not explain
    /// is the same defect pointed the other way — this value exists because a
    /// control's title has no room to say what pressing it does to the run
    /// already going, so a note that skips a button leaves the reader to press
    /// it and find out. `AutoDevBandTests.runNoteNamesExactlyTheControlsOffered`
    /// checks both directions, over all four bands, deriving each word from
    /// ``title(_:)`` and failing named. It is stated here as a claim about a
    /// test that was measured red both ways, not as a claim about the strings.
    let runNote: String
    let tone: Tone
    let controls: [Control]

    /// No session has run this launch.
    static let idle = AutoDevBand(
        headline: "Elliot is not driving anything by itself.",
        runNote: "Nothing is running.",
        tone: .quiet,
        controls: []
    )

    /// ⛔ **The noun counts the session, never the rows.** `AutoDevTally` counts
    /// engagement *rows*; `session.engagedCardIDs` is the set the session closed
    /// at start and the set the board draws ``engagedSymbol`` on. The two
    /// disagree in a window that happens on every single run — between the
    /// driver's `start` returning and its first engagements landing, and again
    /// on any refresh that returns fewer rows than the session engaged. Taking
    /// the noun from `tally.total` there reads *"Driving 0 cards in Elliot — 0
    /// settled, 0 to go."* underneath three cards already wearing the bolt.
    ///
    /// So the count is a parameter of the **session**, and only the words that
    /// are genuinely about rows — settled, merged, blocked — come from the
    /// tally. "To go" is then the difference rather than `tally.engaged`, so the
    /// two halves of the sentence always account for the whole set.
    ///
    /// - Parameter hasLiveRun: whether a run this session started is still
    ///   active, checked only for `.finished` — `AutoDevPolicy`'s
    ///   `.runAlreadyInFlight` branch never consults `RunState`, so patience
    ///   expiry can settle every engaged card and reach `finish()` while a
    ///   `.mergePR` run is genuinely still `.running`, and `finish()`
    ///   correctly leaves a running run alone rather than cancel it. So a
    ///   live `claude -p` child can outlive a session this band reports as
    ///   fully stopped. Defaulted to `false` rather than made non-optional:
    ///   deciding it needs `AppModel.activeRuns`, which every existing caller
    ///   and every existing test here has no reason to thread through for the
    ///   two states where it cannot change anything.
    static func of(
        session: AutoDevSession?, tally: AutoDevTally, repoName: String, hasLiveRun: Bool = false
    ) -> AutoDevBand {
        guard let session else { return .idle }
        let count = session.engagedCardIDs.count
        let cards = "\(count) \(count == 1 ? "card" : "cards")"
        let settled = settledCards(session, tally)
        // No `max(0, …)` needed: ``settledCards(_:_:)`` is already bounded by
        // `count`, so the two halves of the sentence account for the set by
        // construction rather than by a second clamp that could drift from the
        // first.
        let toGo = count - settled
        switch session.state {
        case .running:
            return AutoDevBand(
                headline:
                    "Driving \(cards) in \(repoName) — \(settled) settled, "
                    + "\(toGo) to go.",
                runNote:
                    "Pause engages no further move and lets the run already going finish. "
                    + "Stop ends the session and cancels that run.",
                tone: .armed,
                controls: [.pause, .stop]
            )
        case .paused:
            return AutoDevBand(
                headline: "Paused — \(cards) engaged in \(repoName), \(settled) settled.",
                // Its own, because Pause is not on this screen: Resume has taken
                // its place, and a note telling the reader to press a button
                // that is not there is worse than no note.
                runNote:
                    "No further move will be engaged, and the run already going finishes on "
                    + "its own. Resume starts engaging moves again; Stop ends the session and "
                    + "cancels that run.",
                tone: .attention,
                controls: [.resume, .stop]
            )
        case .finished:
            // ⛔ **Fix round 1, Important 2 — PR5's inherited contract 4,
            // come due.** `stop(sessionID:)` (`AutoDevService.swift`) is the
            // one production path that can reach `.finished` while a row is
            // still `.engaged`: the automatic path never calls `finish()`
            // until `states.allSatisfy(\.isSettled)`
            // (`AutoDevService.round()`), so `tally.engaged > 0` here can
            // only mean a reader pressed Stop before every card settled.
            // Falling through to the sentence below would silently drop
            // every abandoned card — "Finished — 5 cards…, 2 merged, 0
            // blocked" for a session that still had 3 engaged — the exact
            // "quiet success on short rows" the override's 5b principle was
            // invoked to fix for `hasLiveRun`. Checked before `hasLiveRun`:
            // `stop()` also cancels every cancellable active run for the
            // session's cards, so by the time this renders `hasLiveRun` is
            // usually already false, and even where it briefly is not, "left
            // mid-flight" is the more actionable fact.
            if tally.engaged > 0 {
                return AutoDevBand(
                    headline:
                        "Stopped — \(cards) in \(repoName), \(tally.merged) merged, "
                        + "\(tally.blocked) blocked, \(tally.engaged) left mid-flight.",
                    runNote:
                        "The reader stopped this session before every card settled. "
                        + "This report stays until the next session starts.",
                    // Blocked still outranks a mid-flight stop — the same
                    // ordering `hasLiveRun` uses below: a session that both
                    // blocked a card *and* left others mid-flight is still,
                    // first and foremost, a session that failed somewhere.
                    tone: tally.blocked > 0 ? .refused : .attention,
                    controls: []
                )
            }
            return AutoDevBand(
                headline:
                    "Finished — \(cards) in \(repoName), \(tally.merged) merged, "
                    + "\(tally.blocked) blocked.",
                // ⛔ **Must stay conditional on `hasLiveRun`.** "Nothing is
                // running" is false in a state the previous task proved
                // reachable — see this method's own doc on the parameter —
                // and shipping it unconditionally is the defect this branch
                // has already corrected five times elsewhere: prose the same
                // pull request makes untrue.
                runNote: hasLiveRun
                    ? "A run this session started is still going, and will finish on its own. "
                        + "This report stays until the next session starts."
                    : "Nothing is running. This report stays until the next session starts.",
                // A session that blocked everything must not read like a quiet
                // success — it is the outcome nothing else on the board shows.
                // A live run outranks quiet but not refused: a session that
                // both blocked cards *and* left a run going is still, first
                // and foremost, a session that failed somewhere.
                tone: tally.blocked > 0 ? .refused : (hasLiveRun ? .attention : .quiet),
                controls: []
            )
        }
    }

    /// The status bar's figure, or `nil` when there is no session to be a door
    /// to.
    ///
    /// ⚠️ `nil` only when **no session has run this launch**. A finished session
    /// still shows: the report is a record, and the figure is how a reader
    /// reaches it from the board.
    ///
    /// Both halves come from the same two places the headline's do — the
    /// denominator from the session, the numerator through
    /// ``settledCards(_:_:)`` — because this figure and that headline are the
    /// one number this feature exists to state. A denominator left on
    /// `tally.total` reads `0/0` beside a band reading *"Driving 3 cards"*; a
    /// numerator left unclamped read **`3/2`** beside a headline the clamp had
    /// already made coherent, which is how this shipped and what fix round 1
    /// caught.
    static func figureText(session: AutoDevSession?, tally: AutoDevTally) -> String? {
        guard let session else { return nil }
        return "\(settledCards(session, tally))/\(session.engagedCardIDs.count) auto-dev"
    }

    /// Which repository a session is about, in the reader's words.
    ///
    /// ⛔ **One answer, because two surfaces ask.** The band's headline names the
    /// repository and the status bar's figure is the door to that band, so a
    /// second lookup written beside the first is two answers to *"which
    /// repository is this session about"* — the shape this whole type exists to
    /// refuse, and the one the plan's own audit caught before either copy was
    /// written. It takes what it needs rather than an `AppModel`, so a test can
    /// reach it and so it stays as pure as the sentences around it.
    ///
    /// ⚠️ **The session wins, and when it names a repository the board no longer
    /// holds, the answer is "no repository" rather than the picker's.** Falling
    /// through would print a *different* repository's name into a sentence about
    /// this session — a wrong fact where the reader has no way to tell. The
    /// picker is consulted only **before** a session exists, which is the state
    /// the Start control speaks from.
    ///
    /// Never blank: a headline reading *"Driving 3 cards in  — 1 settled"* reads
    /// as a rendering fault, and a rendering fault is what a reader stops
    /// trusting the whole band for.
    static func repoName(
        session: AutoDevSession?, selectedRepoID: UUID?, repos: [Repo]
    ) -> String {
        guard let id = session?.repoID ?? selectedRepoID,
            let repo = repos.first(where: { $0.id == id })
        else { return "no repository" }
        return repo.displayName
    }

    static func title(_ control: Control) -> String {
        switch control {
        case .pause: "Pause"
        case .resume: "Resume"
        case .stop: "Stop and cancel"
        }
    }

    static func explains(_ control: Control) -> String {
        switch control {
        case .pause: "Engages no further move. The run already going finishes."
        case .resume: "Starts engaging moves again."
        case .stop: "Ends the session and cancels the run already going."
        }
    }

    /// How many of the session's cards are done with, never more than it has.
    ///
    /// ⛔ **One clamp, read by both surfaces.** The session and the rows can
    /// disagree — see ``of(session:tally:repoName:)`` — and an unclamped
    /// numerator prints **`3/2 auto-dev`** in the status bar while the headline
    /// beside it reads *"2 settled, 0 to go"*. That was the shipped state: the
    /// clamp lived inline in ``of(session:tally:repoName:)`` and guarded the
    /// less visible of the two surfaces only. A second clamp beside the first
    /// would be a second answer waiting to drift, which is the whole subject of
    /// this type.
    ///
    /// It bounds rather than reports, deliberately: an impossible pair is a
    /// transient the reader can do nothing about, so it reads as *finished* for
    /// the moment it lasts rather than as arithmetic nobody can parse.
    ///
    /// ⚠️ **Three readers now, which is why it is no longer `private`.**
    /// `BoardAccessibility.autoDevFigure` is the sentence VoiceOver hears in
    /// place of ``figureText``, so it has to state the same pair of numbers;
    /// deriving them from the tally instead — which is what this task's plan
    /// asked for — reads *"0 of 0 cards settled"* beside a figure showing `0/3`,
    /// in the window between a session starting and its first engagement row,
    /// i.e. on every single run. It is exposed rather than copied for the reason
    /// the doc above gives: a second clamp is a second answer waiting to drift.
    static func settledCards(_ session: AutoDevSession, _ tally: AutoDevTally) -> Int {
        min(tally.settled, session.engagedCardIDs.count)
    }
}
