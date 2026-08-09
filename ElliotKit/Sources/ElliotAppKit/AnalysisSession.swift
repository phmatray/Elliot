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

    /// Marks one run stalled — the fourth of the four collections
    /// `AppModel.markStalled` walks. The rule itself stays in `AppModel`, so
    /// all four ask the same question.
    mutating func markStalled(_ runID: UUID) {
        runs = runs.map { AppModel.stalling(runID, $0) }
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
