import ElliotModel
import Foundation
import Testing

@testable import ElliotAppKit

/// Hiding the analysis panel does not lose what the reader has typed.
///
/// The panel's own type comment promised this and named the two pieces of state
/// that had been moved to the model to make it true. The editor was the third,
/// and it had not been: `ProposalEditor` built its draft in `init` and held it
/// in `@State`, so `⌘⌥A`, the Analyse toggle or the header `✕` tore the subtree
/// down and took a retyped title and eight acceptance criteria with it —
/// silently, since nothing distinguishes a draft that was lost from one that was
/// never typed.
///
/// ⚠️ CLAUDE.md already records why this survived: the test that "proved" the
/// hide was safe only looked at `analysis`, the half that already lived on the
/// model.
@Suite("Proposal edit survives a hide")
@MainActor
struct ProposalEditSurvivesHideTests {

    private static func proposal(
        analysisID: UUID, title: String = "A proposal"
    ) -> StoryProposal {
        StoryProposal(
            analysisID: analysisID, runID: UUID(), repoID: UUID(), angle: .bugs,
            title: title,
            story: UserStory(
                role: "a maintainer", want: "the thing", benefit: "the reason",
                acceptanceCriteria: ["one", "two"]),
            createdAt: Date(timeIntervalSince1970: 0))
    }

    private func openedModel() -> (AppModel, StoryProposal) {
        let analysis = analysisFixture(repoID: UUID())
        let model = AppModel()
        model.openAnalysis(analysis)
        let proposal = Self.proposal(analysisID: analysis.id)
        model.testOnlySeedAnalysis(runs: [], note: nil, proposals: [proposal])
        return (model, proposal)
    }

    @Test("With no analysis open there is no editor, and a write is swallowed")
    func setupHasNoEditor() {
        let model = AppModel()
        #expect(model.analysisEdit == nil)
        model.analysisEdit = ProposalEdit(proposalID: UUID(), draft: CardDraft())
        #expect(model.analysisEdit == nil)
    }

    @Test("Opening the editor seeds the draft from the proposal")
    func editingSeedsFromTheProposal() {
        let (model, proposal) = openedModel()
        model.beginEditingProposal(proposal)

        let edit = model.analysisEdit
        #expect(edit?.proposalID == proposal.id)
        #expect(edit?.draft.title == proposal.title)
        #expect(edit?.draft.criteria == ["one", "two"])
        #expect(edit?.draft.role == "a maintainer")
    }

    /// ⛔ The regression. Hiding the panel destroys the view; the draft must not
    /// be in it.
    @Test("A typed draft survives the panel being hidden and re-shown")
    func typingSurvivesAHide() {
        let (model, proposal) = openedModel()
        model.beginEditingProposal(proposal)
        model.analysisEdit?.draft.title = "Retyped by hand"
        model.analysisEdit?.draft.criteria = ["a", "b", "c", "d", "e", "f", "g", "h"]

        // What hiding actually does. It must not be `closeAnalysis()`, which
        // ends the session — that distinction is the panel's own rule.
        model.showingAnalysisPanel = false
        model.showingAnalysisPanel = true

        #expect(model.analysisEdit?.draft.title == "Retyped by hand")
        #expect(model.analysisEdit?.draft.criteria.count == 8)
        #expect(model.analysis != nil)
    }

    /// The other direction, and the reason this lives on the session rather than
    /// beside the setup form: an edit belongs to the analysis whose proposal it
    /// is about.
    @Test("Finishing the analysis takes the editor with it")
    func finishingDropsTheEdit() {
        let (model, proposal) = openedModel()
        model.beginEditingProposal(proposal)
        #expect(model.analysisEdit != nil)

        model.closeAnalysis()
        #expect(model.analysisEdit == nil)
    }

    @Test("A fresh analysis does not inherit the previous one's editor")
    func openingAgainStartsClean() {
        let (model, proposal) = openedModel()
        model.beginEditingProposal(proposal)

        model.openAnalysis(analysisFixture(repoID: UUID()))
        #expect(model.analysisEdit == nil)
    }

    @Test("Cancel closes the editor and keeps the analysis")
    func endingEditingKeepsTheSession() {
        let (model, proposal) = openedModel()
        model.beginEditingProposal(proposal)
        model.endEditingProposal()

        #expect(model.analysisEdit == nil)
        #expect(model.analysis != nil)
    }

    // MARK: - A draft must not outlive its proposal's decision

    /// ⚠️ A proposal can be accepted or rejected over MCP while the panel is
    /// hidden. Re-applying a draft over a decided proposal is worse than losing
    /// it: an accepted one already has a Backlog card carrying its text, so a
    /// save would rewrite the proposal that card came from.
    @Test("An edit whose proposal was decided elsewhere is dropped, and said so")
    func aDecidedProposalDropsItsEdit() {
        let (model, proposal) = openedModel()
        model.beginEditingProposal(proposal)

        // Accepted from somewhere else: it is no longer among the open rows.
        model.dropStaleAnalysisEdit(openProposalIDs: [])

        #expect(model.analysisEdit == nil)
        #expect(model.analysis?.note?.contains("decided elsewhere") == true)
    }

    @Test("An edit whose proposal is still open is left alone, and says nothing")
    func anOpenProposalKeepsItsEdit() {
        let (model, proposal) = openedModel()
        model.beginEditingProposal(proposal)
        model.analysisEdit?.draft.title = "Still mine"

        model.dropStaleAnalysisEdit(openProposalIDs: [proposal.id])

        #expect(model.analysisEdit?.draft.title == "Still mine")
        #expect(model.analysis?.note == nil)
    }

    /// A reconcile with no editor open must not invent a note about one.
    @Test("Reconciling with nothing open changes nothing")
    func reconcilingWithNoEditIsQuiet() {
        let (model, _) = openedModel()
        model.dropStaleAnalysisEdit(openProposalIDs: [])
        #expect(model.analysis?.note == nil)
    }
}

/// The state that may stay in the view, and why.
///
/// ⚠️ A source gate, and the reason it is one is written into CLAUDE.md: the
/// test that "proved" hiding was lossless only looked at the half of the state
/// that already lived on the model. A behavioural test cannot see a `@State`
/// nobody thought to move — only reading the declarations can.
@Suite("Analysis panel holds no lossy state")
struct AnalysisPanelStateTests {

    /// Each of these is genuinely re-derivable after the view is destroyed, so
    /// losing it costs the reader nothing:
    ///
    /// - `past` is re-fetched by the `.task` that keys on the repository.
    /// - `lensesExpanded` is a disclosure preference with a computed default.
    /// - `showingDropped` is a disclosure toggle over a report the run owns.
    /// - `showingCriteria` is the same, over the proposal's own criteria.
    /// - `hovering` is pointer state, recomputed by the next mouse move.
    ///
    /// The line these four sit on the right side of: they are *views of data
    /// that is intact*, so re-showing the panel redraws them from the source. A
    /// draft is not — the characters exist nowhere else.
    ///
    /// Anything the reader can *type into* or *choose* belongs on the model:
    /// `analysisAngles`, `analysisInstructions`, `analysisMaxStories`,
    /// `analysisSelection`, and since #291 `analysisEdit`.
    ///
    /// ✅ This gate earned its place again in #292: the *Rejected* disclosure's
    /// open/closed flag was written as `@State` and the suite went red naming
    /// it, which is the review conversation happening in the build rather than
    /// in somebody's memory. It was allowed to stay because a folded disclosure
    /// is not typed and reopens onto the same rows.
    ///
    /// ⚠️ **It is gone again in #331, and the second gate is why this entry is
    /// worth reading.** The disclosure became one of the review picker's three
    /// groups, so `rejectedExpanded` had nothing left to fold — and the
    /// *sibling* test below, which refuses an allow-list entry naming a property
    /// that no longer exists, went red the moment it was removed. Which group is
    /// on screen is a **choice**, so it did not inherit the exemption: it lives
    /// on `AnalysisSession` (#290's home), where it dies with its analysis.
    private static let allowed: Set<String> = [
        "past", "lensesExpanded", "showingDropped", "showingCriteria", "hovering",
    ]

    /// ⚠️ **The whole file, not just `AnalysisPanelView`** — and the scan itself
    /// is `HiddenFaceState.declared(in:)`, which says at length why it reads a
    /// file rather than a type. It lives there because the New story face needs
    /// the same reading (#314) and the two must not drift; what stays here is the
    /// allow-list, which is a judgement about *this* panel's data.
    private static var declaredState: [String] {
        get throws { try HiddenFaceState.declared(in: "AnalysisPanelView.swift") }
    }

    @Test("Every @State in the panel's subtree is state a hide may destroy")
    func noLossyStateInTheView() throws {
        let declared = Set(try Self.declaredState)
        #expect(declared.isEmpty == false, "the parse found nothing — check the file layout")
        let unexpected = declared.subtracting(Self.allowed)
        #expect(
            unexpected.isEmpty,
            Comment(
                rawValue:
                    "\(unexpected.sorted().joined(separator: ", ")) is @State in AnalysisPanelView.swift. "
                    + "Hiding the panel destroys the whole subtree. Move it to AppModel or the "
                    + "session, or add it to `allowed` with a reason it is re-derivable."))
    }

    /// The allow-list must not outlive what it allows: an entry for a property
    /// that no longer exists is a rule nobody is reading any more.
    @Test("The allow-list names nothing that has already gone")
    func theAllowListIsNotStale() throws {
        let declared = Set(try Self.declaredState)
        #expect(Self.allowed.subtracting(declared).isEmpty)
    }

    /// ⛔ The specific one. `editingID` was the id half; the draft it named lived
    /// in `ProposalEditor`'s own `@State`, seeded in `init`.
    @Test("The editor is driven from the model, not from a local id and draft")
    func theEditorIsNotLocal() throws {
        #expect(Set(try Self.declaredState).contains("editingID") == false)

        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/ElliotAppKit/AnalysisPanelView.swift")
        let source = try String(contentsOf: url, encoding: .utf8)
        // A `Binding`, so the characters live where the panel does not.
        #expect(source.contains("@Binding private var draft: CardDraft"))
        #expect(source.contains("_draft = State(initialValue: CardDraft(proposal:") == false)
    }
}
