import Foundation
import Testing

@testable import ElliotModel

@Suite("GH payloads")
struct GHPayloadsTests {

    private func issue(state: String?) -> GHIssue {
        GHIssue(number: 1, title: "x", url: "https://github.com/o/r/issues/1", state: state)
    }

    @Test("An issue's open state is read case-insensitively", arguments: [
        ("OPEN", true), ("open", true), ("Open", true),
        ("CLOSED", false), ("closed", false),
    ])
    func isOpenIsCaseInsensitive(state: String, expected: Bool) {
        #expect(issue(state: state).isOpen == expected)
    }

    @Test("An issue with no state at all defaults to open")
    func isOpenDefaultsWhenStateIsMissing() {
        #expect(issue(state: nil).isOpen)
    }

    // MARK: - Speaking the verifier's vocabulary

    private func pr(state: String, isDraft: Bool = false, mergedAt: Date? = nil) -> GHPullRequest {
        GHPullRequest(
            number: 7,
            url: "https://github.com/o/r/pull/7",
            title: "A pull request",
            headRefName: "feat/4-thing",
            isDraft: isDraft,
            state: state,
            mergedAt: mergedAt
        )
    }

    @Test("A merged pull request reads as merged, with no commit to name")
    func mergedReadsAsMerged() {
        #expect(pr(state: "MERGED", mergedAt: Date()).verifiedOutcome == .merged(commitSHA: nil))
    }

    @Test("A pull request closed without merging reads as closed-unmerged")
    func closedUnmergedReadsAsClosedUnmerged() {
        #expect(pr(state: "CLOSED").verifiedOutcome == .closedUnmerged)
    }

    @Test("An open pull request reads as prOpen, carrying its number, URL, draft flag and branch")
    func openReadyReadsAsPROpen() {
        #expect(
            pr(state: "OPEN").verifiedOutcome
                == .prOpen(
                    number: 7, url: "https://github.com/o/r/pull/7",
                    isDraft: false, branch: "feat/4-thing"
                )
        )
    }

    @Test("An open draft reads as prOpen too, and says it is a draft")
    func openDraftReadsAsDraftPROpen() {
        #expect(
            pr(state: "OPEN", isDraft: true).verifiedOutcome
                == .prOpen(
                    number: 7, url: "https://github.com/o/r/pull/7",
                    isDraft: true, branch: "feat/4-thing"
                )
        )
    }

    /// GitHub reports a merged pull request as `CLOSED` with `mergedAt` set, so
    /// the order of these two checks is the whole correctness of the property:
    /// read state alone and every merge becomes an abandonment.
    @Test("A CLOSED pull request that was in fact merged reads as merged, never as closed-unmerged")
    func mergedIsCheckedBeforeClosed() {
        #expect(pr(state: "CLOSED", mergedAt: Date()).verifiedOutcome == .merged(commitSHA: nil))
    }
}
