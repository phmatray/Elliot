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
