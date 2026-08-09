import Foundation
import Testing

@testable import ElliotModel

/// When a card stops being Elliot's to rewrite — asked once, in the layer with
/// no dependencies.
///
/// There were three spellings of this rule and they did not agree.
/// `BoardService.updateCard` refused a card carrying an issue **or** a pull
/// request; `CardEditor.begin` and the panel's Edit button each looked only at
/// the issue. So a card imported from a pull request that closes no issue —
/// `issueNumber == nil`, `prNumber != nil` — was offered *Edit story*, entered
/// the editor, and its Save was guaranteed to throw.
@Suite("Card freeze")
struct CardFreezeTests {

    private static let fixed = Date(timeIntervalSince1970: 1_770_000_000)

    private static func card(issue: Int? = nil, pr: Int? = nil) -> Card {
        Card(
            repoID: UUID(), title: "A card",
            issueNumber: issue, prNumber: pr,
            columnEnteredAt: fixed, createdAt: fixed, updatedAt: fixed
        )
    }

    @Test("A card pointing at nothing on GitHub is still ours to change")
    func anUnfiledCardIsEditable() {
        let card = Self.card()
        #expect(card.editRefusal == nil)
        #expect(card.isEditable)
    }

    /// The case the three spellings disagreed about, and the whole reason for
    /// the change.
    @Test("A card imported from a pull request is frozen, with no issue involved")
    func aPullRequestFreezesTheCard() {
        let card = Self.card(pr: 47)
        #expect(card.isEditable == false)
        #expect(card.editRefusal == .tracksPullRequest(47))
    }

    @Test("A filed issue freezes the card")
    func anIssueFreezesTheCard() {
        let card = Self.card(issue: 12)
        #expect(card.isEditable == false)
        #expect(card.editRefusal == .filedAsIssue(12))
    }

    /// A card carrying both is a filed issue that grew a pull request, and the
    /// issue is the record a reader is sent to. Order is a choice, so it is
    /// pinned rather than left to whoever edits the property next.
    @Test("Carrying both, the issue is the record named")
    func theIssueWinsWhenThereAreBoth() {
        #expect(Self.card(issue: 12, pr: 47).editRefusal == .filedAsIssue(12))
    }

    /// The editor's guard is the same question, not a looser one. This is the
    /// half that let the reader *into* an editor whose Save could only fail.
    @Test("The editor refuses to open on a card the service would refuse to save")
    func theEditorAndTheServiceAgree() {
        var editor = CardEditor()

        editor.begin(from: Self.card(pr: 47))
        #expect(editor.isEditing == false)

        editor.begin(from: Self.card(issue: 12))
        #expect(editor.isEditing == false)

        editor.begin(from: Self.card())
        #expect(editor.isEditing)
    }

    /// Each record gets its own sentence, because "edit it on GitHub" points
    /// somewhere different in each case — and a card frozen by a pull request
    /// used to get no sentence at all, only a button that did not work.
    @Test("Each refusal names its own record")
    func eachRefusalSaysWhichRecord() {
        #expect(EditRefusal.filedAsIssue(12).sentence.contains("issue"))
        #expect(EditRefusal.tracksPullRequest(47).sentence.contains("47"))
        #expect(EditRefusal.filedAsIssue(12).sentence != EditRefusal.tracksPullRequest(47).sentence)
    }
}
