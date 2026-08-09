import ElliotModel
import Foundation
import Testing

@testable import ElliotAppKit

/// A write to the analysis may not report a success that did not happen.
///
/// ⚠️ **Half of #223 is covered here and half is not, and the issue's own
/// acceptance criterion is wrong about why.** It says *"the service is injected,
/// so a stub that throws is the whole seam"* — but `AnalysisService` is a
/// concrete `actor` constructed inside `AppModel.start()`, not a protocol, so
/// there is nothing to substitute a throwing stub for without extracting one.
///
/// What that leaves is an honest split rather than a pretence:
///
/// - the **absent-service** route is driven end to end here, on a real
///   `AppModel` that has never started — and it is the quieter of the two, the
///   one an error path covering only `throw` still gets wrong;
/// - the **throwing** route's *meaning* is pinned by `AnalysisWriteFailureTests`
///   in `ElliotModel`, while the two lines that map a caught error onto it are
///   not executed by any test.
///
/// Extracting a protocol for the sake of those two lines is a change to how the
/// engine is wired, and it belongs to whoever needs the seam for something
/// larger than this.
@MainActor
@Suite("Analysis writes")
struct AnalysisWriteTests {

    private var proposal: StoryProposal {
        StoryProposal(
            analysisID: UUID(),
            runID: UUID(),
            repoID: UUID(),
            angle: .bugs,
            title: "A story",
            story: UserStory(role: "developer", want: "a thing", benefit: "a reason"),
            rationale: "because",
            createdAt: Date(timeIntervalSince1970: 1_754_600_000)
        )
    }

    // MARK: - 1. The silent dismissal

    /// The defect exactly as #223 describes it: with no service the call was a
    /// no-op before any `try?` could be reached, so the editor closed as though
    /// the edit had landed.
    @Test("Saving with no analysis running reports that it did not save")
    func anAbsentServiceIsAFailureAndNotANoOp() async {
        let model = AppModel()
        let failure = await model.updateProposal(proposal)
        #expect(
            failure == .serviceUnavailable,
            """
            updateProposal returned \(String(describing: failure)) with no service. Returning nil \
            here is what closed the editor exactly like a successful save
            """
        )
    }

    // MARK: - 2. The louder half

    /// `rejectProposals` swallowed its error and then asserted success on the
    /// very next line. A silent failure leaves a reader guessing; an asserted
    /// one leaves them certain and wrong.
    @Test("Rejecting with no analysis running does not claim anything was rejected")
    func aFailedRejectDoesNotAssertSuccess() async {
        let model = AppModel()
        let failure = await model.rejectProposals(ids: [UUID(), UUID()])

        #expect(failure == .serviceUnavailable)
        // ⚠️ What the note *says* is asserted in `AnalysisWriteFailureTests`, not
        // here. An assertion about `model.analysis?.note` on this model checks
        // nothing at all — `analysis` is nil until a session is opened — and a
        // draft of this test made exactly that mistake: reverting the guard on
        // purpose left it green.
    }

    /// The undo added in #292 is a write like the other two, and it arrived
    /// after the funnel existed — which is exactly when a new caller reaches
    /// for `try? await analysisService?.…` and reintroduces the silence.
    @Test("Restoring with no analysis running does not claim anything came back")
    func aFailedRestoreDoesNotAssertSuccess() async {
        let model = AppModel()
        let failure = await model.restoreProposals(ids: [UUID(), UUID()])
        #expect(failure == .serviceUnavailable)
        // ⚠️ What the note *says* is asserted in `AnalysisWriteFailureTests`,
        // for the reason recorded above: `analysis` is nil on this model, so an
        // assertion about `model.analysis?.note` here would check nothing.
    }

    // MARK: - 3. One funnel

    /// All three writes go through `analysisWrite`, so none can be repaired into
    /// silence on its own. Asserted through the public surface: a `Void` return
    /// is what made the silent dismissal expressible, and none has one.
    @Test("Every analysis write answers with whether it landed")
    func neitherWriteCanReportSuccessSilently() async {
        let model = AppModel()
        let update: AnalysisWriteFailure? = await model.updateProposal(proposal)
        let reject: AnalysisWriteFailure? = await model.rejectProposals(ids: [UUID()])
        let restore: AnalysisWriteFailure? = await model.restoreProposals(ids: [UUID()])
        #expect(update != nil)
        #expect(reject != nil)
        #expect(restore != nil)
    }
}
