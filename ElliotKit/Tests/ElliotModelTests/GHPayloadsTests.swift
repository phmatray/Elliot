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

@Suite("A repository summary knows whether it holds code")
struct GHRepoSummaryLanguageTests {

    private func summary(_ lang: String?, isEmpty: Bool = false) -> GHRepoSummary {
        GHRepoSummary(
            nameWithOwner: "phmatray/Foo", visibility: "PUBLIC",
            primaryLanguage: lang.map { GHLanguage(name: $0) }, isEmpty: isEmpty)
    }

    @Test("A language on the allowlist is code")
    func allowlistedLanguageIsCode() {
        #expect(summary("C#").isCode)
        #expect(summary("Swift").isCode)
        #expect(summary("HTML").isCode)
    }

    /// The seven LaTeX papers are the reason this allowlist exists: they are
    /// writing, and the axes that measure code do not apply to them.
    @Test("TeX is not code")
    func texIsNotCode() {
        #expect(!summary("TeX").isCode)
        #expect(!summary(nil).isCode)
    }

    /// GitHub classifies on byte volume, not on what a repository builds:
    /// AtypWebsite is HTML, Linelo JavaScript, github-toolkit TypeScript — all
    /// three carry .csproj files. This decides SCOPE only. It must never pick a
    /// template, which is how the Python tool posted the 26-line base
    /// editorconfig onto the company's own site.
    @Test("A missing repositoryTopics-style null decodes rather than throwing")
    func nullLanguageDecodes() throws {
        let json = """
            {"nameWithOwner":"phmatray/Foo","visibility":"PUBLIC","isFork":false,
             "isArchived":false,"primaryLanguage":null,"isEmpty":false}
            """
        let decoded = try JSONDecoder().decode(GHRepoSummary.self, from: Data(json.utf8))
        #expect(decoded.primaryLanguage == nil)
        #expect(!decoded.isCode)
    }

    /// The `--json` list is pinned, so a payload missing one of these means the
    /// request changed underneath us. `isFork == false` would then put every
    /// fork back in scope — the exact defect measured in the Python tooling,
    /// where `isFork` is requested and never read. Throwing is the loud
    /// failure; defaulting is the silent one, and this subsystem exists to
    /// refuse the silent one.
    @Test("A payload missing a scope field is refused, not defaulted")
    func missingScopeFieldThrows() {
        let payloads = [
            #"{"nameWithOwner":"p/F","visibility":"PUBLIC","isArchived":false,"isEmpty":false}"#,
            #"{"nameWithOwner":"p/F","visibility":"PUBLIC","isFork":false,"isEmpty":false}"#,
            #"{"nameWithOwner":"p/F","visibility":"PUBLIC","isFork":false,"isArchived":false}"#,
        ]
        for json in payloads {
            #expect(throws: DecodingError.self) {
                try JSONDecoder().decode(GHRepoSummary.self, from: Data(json.utf8))
            }
        }
    }
}
