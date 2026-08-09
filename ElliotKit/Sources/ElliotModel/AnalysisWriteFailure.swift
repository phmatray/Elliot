import Foundation

/// Why a write to the analysis did not happen, and what to tell the reader.
///
/// Two cases, because there are exactly two ways for one of these writes to not
/// happen and they were being answered differently — or not at all:
///
/// - the service **threw**, which `try?` discarded;
/// - the service was **absent**, which `analysisService?` turned into a silent
///   no-op before any `try?` could even be reached.
///
/// The second is the one that hides: an error path covering only `throw` still
/// dismisses an editor silently when the service is nil, which is the same
/// outcome by a different route. One type answers both, so a caller cannot
/// handle one and forget the other.
///
/// In `ElliotModel` rather than on `AppModel` because deciding *what a failed
/// write means* is a rule, and the view has to render it rather than judge it.
public enum AnalysisWriteFailure: Equatable, Sendable {

    /// The analysis service does not exist — the board has not finished starting,
    /// or it failed to start at all.
    case serviceUnavailable

    /// The service was there and refused, carrying its own description.
    case refused(String)

    /// What the reader is told.
    ///
    /// ⚠️ **Both sentences say the edit was *not* saved, in the app's own voice
    /// for a failed write.** That is the whole point of the type: the failure a
    /// reader must never meet is the silent one, where an editor closes exactly
    /// as it does on success and the next screen shows the old text — which
    /// reads as the app having forgotten rather than as a write having failed.
    public var sentence: String {
        switch self {
        case .serviceUnavailable:
            "Not saved — the analysis is not running. Nothing was changed."
        case .refused(let reason):
            "Not saved — \(reason)"
        }
    }

    /// What the panel says after rejecting `count` proposals — which is the
    /// failure's sentence when there was one, and never a claim of success.
    ///
    /// ⛔ **Here, and not as an `if` in `AppModel`, because an `if` there is
    /// unreachable by any test.** `rejectProposals` writes to `analysis?.note`,
    /// and `analysis` is nil on a model that has never opened one — so an
    /// assertion about that note silently checks nothing. That is exactly what
    /// happened: the first version of this fix guarded the success sentence in
    /// `AppModel`, and reverting the guard on purpose left the suite **green**,
    /// because the note it asserted about was never written in the first place.
    ///
    /// A rule that a test cannot reach is a rule that will be undone. Pure and
    /// total, this one is held by `AnalysisWriteFailureTests` at every count and
    /// both failures.
    public static func rejectionNote(count: Int, failure: AnalysisWriteFailure?) -> String {
        if let failure { return failure.sentence }
        return count == 1 ? "Rejected 1 proposal." : "Rejected \(count) proposals."
    }
}
