import Foundation
import Testing

@testable import ElliotModel

@Suite("Run terms")
struct RunTermsTests {

    // MARK: - Vocabulary

    @Test("Every mode is named and explained, and no title is a raw CLI token")
    func everyModeIsNamed() {
        for mode in PermissionMode.allCases {
            #expect(!mode.title.isEmpty, "\(mode.rawValue) has no title")
            #expect(!mode.explanation.isEmpty, "\(mode.rawValue) has no explanation")
            #expect(
                mode.title != mode.rawValue,
                "\(mode.rawValue) shows the reader an argument token"
            )
        }
    }

    /// The claim this file is careful about. `claude --help` lists the six
    /// tokens and no semantics, and `bypassPermissions` is the only mode this
    /// board has ever run — so five explanations say they are unmeasured, and
    /// this test is what stops a later edit quietly promoting a guess to a fact.
    @Test("Only the mode Elliot has actually run claims to know what it does")
    func onlyTheDefaultMakesAClaim() {
        let unmeasured = PermissionMode.allCases.filter { $0 != .bypassPermissions }
        for mode in unmeasured {
            #expect(
                mode.explanation.contains("never started a run"),
                "\(mode.rawValue) explains behaviour Elliot has not measured"
            )
        }
        #expect(!PermissionMode.bypassPermissions.explanation.contains("never started a run"))
    }

    @Test("The two caveats land on the right modes, and the default carries none")
    func caveatsLandCorrectly() {
        #expect(PermissionMode.bypassPermissions.caveat == nil)
        #expect(PermissionMode.plan.caveat == .plansRatherThanActs)
        for mode in [PermissionMode.manual, .acceptEdits, .auto, .dontAsk] {
            #expect(mode.caveat == .unattended, "\(mode.rawValue) warns nobody")
        }
    }

    @Test("A caveat that says nothing is not a caveat", arguments: RunTermsCaveat.allCases)
    func caveatsSpeak(_ caveat: RunTermsCaveat) {
        #expect(caveat.sentence.count > 40)
    }

    /// `PermissionMode` mirrors `claude --permission-mode`'s accepted values, so
    /// the count is a fact about another program. Pinned so that a seventh case
    /// arriving in the CLI is noticed here rather than silently unofferable in
    /// the picker.
    @Test("Six modes, the set `claude --help` accepts")
    func theModeSetIsTheCLIsSet() {
        #expect(
            Set(PermissionMode.allCases.map(\.rawValue)) == [
                "acceptEdits", "auto", "bypassPermissions", "manual", "dontAsk", "plan",
            ]
        )
    }

    // MARK: - The empty-list rule

    @Test("An empty list stays empty, and so does a list of nothing but blanks")
    func blanksCollapseToEmpty() {
        #expect(ExtraAllowedTools.normalise([]) == [])
        #expect(ExtraAllowedTools.normalise([""]) == [])
        #expect(ExtraAllowedTools.normalise(["   ", "\n", "\t"]) == [])
    }

    @Test("Entries are trimmed, de-duplicated, and keep the order they were typed")
    func normaliseTrimsAndDeduplicates() {
        #expect(ExtraAllowedTools.normalise([" Read ", "Read"]) == ["Read"])
        #expect(
            ExtraAllowedTools.normalise(["Bash(git status *)", "Read"])
                == ["Bash(git status *)", "Read"]
        )
        #expect(ExtraAllowedTools.normalise(["b", "a", "b"]) == ["b", "a"])
    }

    /// `arguments()` joins with a comma, so a pattern containing one must
    /// survive whole — split it here and both halves still look like plausible
    /// patterns, which is a defect nothing downstream can detect.
    @Test("A pattern containing a comma is one pattern, not two")
    func commasAreNotSeparators() {
        let pattern = "Bash(git add, git commit)"
        #expect(ExtraAllowedTools.normalise([pattern]) == [pattern])
    }

    // MARK: - The edit

    @Test("A mode edit writes the mode and leaves the tools alone")
    func modeEditIsNarrow() {
        let repo = Self.repo(mode: .bypassPermissions, tools: ["Read"])
        let after = RunTermsEdit.mode(.plan).applied(to: repo)
        #expect(after.permissionMode == .plan)
        #expect(after.extraAllowedTools == ["Read"])
    }

    @Test("A tools edit writes the tools and leaves the mode alone")
    func toolsEditIsNarrow() {
        let repo = Self.repo(mode: .plan, tools: [])
        let after = RunTermsEdit.tools(["Read"]).applied(to: repo)
        #expect(after.extraAllowedTools == ["Read"])
        #expect(after.permissionMode == .plan)
    }

    /// The reason `applied(to:)` is the only way in: a caller cannot forget to
    /// normalise, because there is no route that skips it.
    @Test("An edit normalises on the way into the repository, not at the caller")
    func theEditNormalisesItself() {
        let repo = Self.repo(mode: .bypassPermissions, tools: [])
        #expect(RunTermsEdit.tools([" Read ", "", "Read"]).applied(to: repo)
            .extraAllowedTools == ["Read"])
        #expect(RunTermsEdit.tools(["  "]).applied(to: repo).extraAllowedTools == [])
    }

    @Test("Every other field of the repository survives an edit untouched")
    func anEditTouchesNothingElse() {
        let repo = Self.repo(mode: .bypassPermissions, tools: [])
        let after = RunTermsEdit.mode(.manual).applied(to: repo)
        #expect(after.id == repo.id)
        #expect(after.path == repo.path)
        #expect(after.nameWithOwner == repo.nameWithOwner)
        #expect(after.defaultBranch == repo.defaultBranch)
        #expect(after.displayName == repo.displayName)
        #expect(after.isEnabled == repo.isEnabled)
        #expect(after.visibility == repo.visibility)
        #expect(after.preflight == repo.preflight)
    }

    @Test("The sentence names the repository and the new value, never a bare 'saved'")
    func theSentenceIsSpecific() {
        let repo = Self.repo(mode: .bypassPermissions, tools: [])
        #expect(RunTermsEdit.mode(.plan).sentence(for: repo) == "Elliot now runs under Plan only.")
        #expect(
            RunTermsEdit.tools(["Read", "Bash"]).sentence(for: repo)
                == "Elliot also allows Read, Bash."
        )
        #expect(
            RunTermsEdit.tools([" "]).sentence(for: repo) == "Elliot allows no extra tools."
        )
    }

    // MARK: - The folded summary

    /// "Nobody has changed this" and "this screen could not tell you" must not
    /// render the same, which is why a row on the defaults still reads as its
    /// mode rather than as an empty line.
    @Test("A row on the defaults says so rather than going blank")
    func theSummaryNeverGoesBlank() {
        #expect(RunTermsSummary.line(Self.repo(mode: .bypassPermissions, tools: []))
            == "Bypass permissions")
    }

    @Test("The summary counts the tools, and counts one of them singularly")
    func theSummaryCountsTools() {
        #expect(RunTermsSummary.line(Self.repo(mode: .plan, tools: ["Read"]))
            == "Plan only · 1 extra tool")
        #expect(RunTermsSummary.line(Self.repo(mode: .plan, tools: ["Read", "Bash"]))
            == "Plan only · 2 extra tools")
    }

    // MARK: -

    static func repo(mode: PermissionMode, tools: [String]) -> Repo {
        Repo(
            path: "/tmp/elliot", nameWithOwner: "phmatray/Elliot", displayName: "Elliot",
            permissionMode: mode, extraAllowedTools: tools
        )
    }
}
