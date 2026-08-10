import ElliotModel

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
    /// `AutoDevBandTests.runNoteNamesOnlyOfferedControls` derives the words from
    /// ``title(_:)`` and fails naming the state.
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
    static func of(
        session: AutoDevSession?, tally: AutoDevTally, repoName: String
    ) -> AutoDevBand {
        guard let session else { return .idle }
        let count = session.engagedCardIDs.count
        let cards = "\(count) \(count == 1 ? "card" : "cards")"
        // Clamped because the two sources can disagree, and a negative count of
        // work left is a sentence no reader can act on. It cannot go negative
        // from a consistent pair — a row exists only for an engaged card — so
        // this is the inconsistent pair failing legibly rather than loudly.
        let toGo = max(0, count - tally.settled)
        switch session.state {
        case .running:
            return AutoDevBand(
                headline:
                    "Driving \(cards) in \(repoName) — \(tally.settled) settled, "
                    + "\(toGo) to go.",
                runNote:
                    "Pause engages no further move and lets the run already going finish. "
                    + "Stop ends the session and cancels that run.",
                tone: .armed,
                controls: [.pause, .stop]
            )
        case .paused:
            return AutoDevBand(
                headline: "Paused — \(cards) engaged in \(repoName), \(tally.settled) settled.",
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
            return AutoDevBand(
                headline:
                    "Finished — \(cards) in \(repoName), \(tally.merged) merged, "
                    + "\(tally.blocked) blocked.",
                runNote: "Nothing is running. This report stays until the next session starts.",
                // A session that blocked everything must not read like a quiet
                // success — it is the outcome nothing else on the board shows.
                tone: tally.blocked > 0 ? .refused : .quiet,
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
    /// The denominator is the session's engaged set for the same reason the
    /// headline's is — see ``of(session:tally:repoName:)``. A figure reading
    /// `0/0` beside a band reading *"Driving 3 cards"* would be the one number
    /// this feature exists to state, stated twice and differently.
    static func figureText(session: AutoDevSession?, tally: AutoDevTally) -> String? {
        guard let session else { return nil }
        return "\(tally.settled)/\(session.engagedCardIDs.count) auto-dev"
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
}
