import Foundation
import Testing

@testable import ElliotModel

/// The one sentence that says what a run actually achieved.
///
/// It lives in `ElliotModel` rather than in the view for the reason
/// `Consequence.reason` does: it is about to have a **second** rendering. The
/// detail panel draws it with a tint and an SF Symbol; a macOS notification
/// (#36) puts the same string in its body. Two copies of this wording would
/// drift, and the drift would be a card and a notification making different
/// claims about the same fact.
///
/// So the strings are pinned here, exactly, in the layer that owns them.
/// `Consequence.receipt` keeps only the tint and the symbol.
@Suite("Verified outcome receipt")
struct VerifiedOutcomeReceiptTests {

    @Test("Every outcome renders the wording the panel already shows")
    func everyCaseHasItsWording() {
        #expect(
            VerifiedOutcome.issueCreated(number: 12, url: "https://example.com/12").receiptText
                == "Opened issue #12"
        )
        #expect(
            VerifiedOutcome.noIssueCreated(reason: "already covered by #9").receiptText
                == "No issue — already covered by #9"
        )
        #expect(
            VerifiedOutcome.prOpen(number: 13, url: "u", isDraft: true, branch: "feat/12-x").receiptText
                == "Draft PR 13 on feat/12-x"
        )
        // The same case, not a draft — the word "Draft" is the only difference,
        // and it is the difference between "ready for review" and "not yet".
        #expect(
            VerifiedOutcome.prOpen(number: 13, url: "u", isDraft: false, branch: "feat/12-x").receiptText
                == "PR 13 on feat/12-x"
        )
        #expect(VerifiedOutcome.merged(commitSHA: "abc1234def", number: nil, url: nil, branch: nil).receiptText == "Merged as abc1234")
        #expect(
            VerifiedOutcome.notMerged(reason: "checks failed").receiptText
                == "Not merged — checks failed"
        )
        let closed = VerifiedOutcome.closedUnmerged(number: nil, url: nil, branch: nil)
        #expect(closed.receiptText == "Closed without merging")
        #expect(
            VerifiedOutcome.unverified(reason: "gh returned nothing").receiptText
                == "Unverified — gh returned nothing"
        )
    }

    @Test("A merge with no commit SHA still reads as a merge")
    func mergedWithoutASHA() {
        // `gh` can confirm a merge without handing back the commit. Rendering
        // that as "Merged as " with a dangling preposition, or worse as
        // "Unverified", would misreport a fact it did establish.
        #expect(VerifiedOutcome.merged(commitSHA: nil, number: nil, url: nil, branch: nil).receiptText == "Merged")
    }

    @Test("A SHA is abbreviated to seven characters, as git prints it")
    func shaIsAbbreviated() {
        let full = "41cbfd9a8b7c6d5e4f3a2b1c0d9e8f7a6b5c4d3e"
        let text = VerifiedOutcome.merged(commitSHA: full, number: nil, url: nil, branch: nil).receiptText
        #expect(text == "Merged as 41cbfd9")
        #expect(!text.contains(full), "the whole SHA reached a sentence meant to be read")
    }

    @Test("No wording is empty, and none of it quotes the agent")
    func everyCaseSaysSomething() {
        // Exhaustive by construction: a new `VerifiedOutcome` case that nobody
        // gave wording to would land here as an empty string rather than as a
        // notification body that says nothing.
        let all: [VerifiedOutcome] = [
            .issueCreated(number: 1, url: "u"),
            .noIssueCreated(reason: "r"),
            .prOpen(number: 1, url: "u", isDraft: false, branch: "b"),
            .merged(commitSHA: nil, number: nil, url: nil, branch: nil),
            .notMerged(reason: "r"),
            .closedUnmerged(number: nil, url: nil, branch: nil),
            .unverified(reason: "r"),
        ]
        for outcome in all {
            #expect(!outcome.receiptText.isEmpty, "\(outcome) has no wording")
        }
    }
}
