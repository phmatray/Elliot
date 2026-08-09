import ElliotModel
import Foundation

/// One analysis, and everything on screen that belongs to it.
///
/// These five things used to be five members of `AppModel` with one lifetime
/// and no type saying so, and the two functions that maintained that lifetime
/// had already drifted: `openAnalysis` cleared three of the four values and
/// left the note, so a sentence written during a failed start was rendered
/// under the next analysis you opened. Held together, "what belongs to this
/// analysis" is a fact about the type rather than a rule two functions have to
/// keep agreeing about.
public struct AnalysisSession: Sendable {
    public let id: UUID

    /// The repository this analysis read.
    ///
    /// Identity, beside `id`, and therefore a `let` with **no default** — the
    /// one deliberate exception to "every member but the id has a default".
    /// That rule is about *state* arriving cheaply; a default here would be a
    /// default answer to the question this member exists to settle.
    ///
    /// Its absence was #213. The panel had to ask somewhere else which
    /// repository it was about, and the only thing to hand was
    /// ``AppModel/selectedRepoID`` — the board's toolbar picker, which the
    /// reader can move while the panel is open. The header then named one
    /// repository while the proposals came from another, and each evidence
    /// chip kept its verified seal while aiming its click at a different
    /// checkout, revealing an unrelated file or nothing at all. Nothing on
    /// screen said which.
    ///
    /// ⚠️ This is the *second* time the same axis has been repaired here.
    /// ``AppModel/startFailure`` is computed rather than stored precisely so a
    /// failure thrown for repository A stops being rendered once the picker
    /// moves to B. That fix scoped one **sentence** to its repository and left
    /// the panel's own subject with the picker; this one puts the subject where
    /// it belongs, so nothing downstream has to re-derive it.
    public let repoID: UUID

    public var runs: [SkillRun] = []
    public var proposals: [StoryProposal] = []

    /// The proposals staged for the footer's Accept / Reject.
    ///
    /// The sixth member that did not travel when this type was created, and the
    /// only one whose absence was a *bug* rather than a tidiness problem. As a
    /// free-standing `AppModel.analysisSelection` it outlived both Finish —
    /// whose own tooltip says "Undecided proposals stay in the store" — and
    /// `openAnalysis`. So: stage five, press Finish, start a fresh analysis, and
    /// the footer read "5 selected" over an empty new list; pressing Accept 5
    /// handed the *previous* analysis's ids to `acceptProposals`, `claimProposal`
    /// found them still `.proposed`, and five cards landed in Backlog from an
    /// analysis nobody was looking at.
    ///
    /// Here it cannot: `openAnalysis` is one assignment of a whole new session
    /// and `closeAnalysis` is `analysis = nil`, so the staging is created and
    /// destroyed with the thing it stages. Setup state has no session and
    /// therefore no selection, which is correct — there are no proposals yet.
    public var selection: Set<UUID> = []

    /// The open proposal editor, if one is open.
    ///
    /// The seventh member, and the last state the panel's "hiding loses
    /// nothing" promise was still false about. `ProposalEditor` built its draft
    /// in `init` and held it in `@State`, so hiding the panel tore the subtree
    /// down and a retyped title plus eight acceptance criteria went with it —
    /// silently, since nothing distinguishes a lost draft from one never typed.
    ///
    /// Here for the same reason `selection` is: created and destroyed with the
    /// analysis it belongs to. An edit cannot outlive its proposals.
    public var edit: ProposalEdit?

    /// Which decided group the review list is showing (#331).
    ///
    /// The eighth member, and the default is the mechanism rather than a
    /// convenience: `openAnalysis` is **one assignment of a whole new session**,
    /// so a member defaulting to `.proposed` re-defaults on every open —
    /// including from *Earlier analyses*, the path that never goes through
    /// `startAnalysis`. There is no reset line to forget, and `closeAnalysis()`
    /// is `analysis = nil`, so there is nothing to clear either.
    ///
    /// ⛔ **Not `@State` in `AnalysisPanelView`**, for the reason `selection`
    /// and `edit` are here: hiding the panel removes `.analysis` from
    /// `PanelLayout.boardOrder` and tears the view down.
    ///
    /// ⛔ **And not on `AppModel` beside `analysisAngles`**, which is the
    /// *opposite* error and the one #290 was: a free-standing member outlives
    /// Finish and `openAnalysis`, so you would reopen last week's analysis onto
    /// the *rejected* tab because that is where you left a different one.
    public var review: ProposalStatus = .proposed

    /// Whatever the window needs to say about the last action.
    public var note: String?
    /// The live proposal observation, held so that letting go of the session
    /// cancels it. Internal: the window reads this session, it does not own
    /// the task.
    var observation: ObservationHandle?
}

extension AnalysisSession {
    /// Whether rows read for `analysisID` may still be written into `session`.
    ///
    /// Pure and static so `swift test` can hold it, exactly like
    /// `AppModel.stalling`: the race it guards — the window closing, or a
    /// second analysis opening, while a store read is in flight — is not
    /// reproducible on demand. `nil` is the closed case; a different id is the
    /// worse one, because those rows would be drawn.
    static func accepts(_ session: AnalysisSession?, rowsFor analysisID: UUID) -> Bool {
        session?.id == analysisID
    }

    /// Applies a silence notice — the fourth of the four collections
    /// `AppModel.mark` walks. The rule itself is `SkillRun.applying` in
    /// `ElliotModel`, so all four ask the same question, in both directions.
    mutating func mark(_ notice: RunSilence, _ runID: UUID) {
        runs = runs.map { $0.applying(notice, ifID: runID) }
    }
}

/// Cancels the task it holds when the last owner lets go.
///
/// This is what lets `closeAnalysis` be one assignment. A `Task` stored beside
/// the values it feeds has to be cancelled by somebody remembering to; held
/// here, it is cancelled by ARC the moment the session is replaced or dropped,
/// which is the same instant the values it writes into stop existing.
public final class ObservationHandle: Sendable {
    private let task: Task<Void, Never>

    init(_ task: Task<Void, Never>) { self.task = task }

    deinit { task.cancel() }
}
