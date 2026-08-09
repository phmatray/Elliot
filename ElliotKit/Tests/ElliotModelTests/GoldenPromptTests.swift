import Foundation
import Testing

@testable import ElliotModel

/// The catalogue's own ai-migration-kit pack, resolved exactly the way
/// production resolves a repository that never chose a method.
///
/// Internal rather than file-private: `SlashCommandBuilderTests` and
/// `AnalysisModelTests` are about this same pack, and one resolution shared by
/// the three of them cannot drift from itself.
func aiMigrationKitPack() -> MethodPack? {
    guard case .unset(let pack) = MethodCatalog.resolve(nil) else { return nil }
    return pack
}

/// One frozen prompt. Every `expected` below is a byte-for-byte copy of what
/// the hardcoded builder emitted before `MethodPack` existed — most of them
/// lifted from the assertions that pinned it in `SlashCommandBuilderTests`.
///
/// ⚠️ **Not `private`.** A file-scope `private` type is `fileprivate`, and
/// `slashPromptIsUnchanged` is a member of an *internal* struct: `error: method
/// must be declared fileprivate because its parameter uses a private type`,
/// which fails the whole `ElliotModelTests` target rather than one test.
struct Golden: Sendable {
    var what: String
    var action: TriggerAction
    var expected: String
}

let goldens: [Golden] = [
    Golden(
        what: "create-issue, no labels",
        action: .createIssue(idea: "Add a dark mode toggle."),
        expected: "/ai-migration-kit:create-issue Add a dark mode toggle."
    ),
    Golden(
        what: "create-issue, an explicitly empty label list",
        action: .createIssue(idea: "Add a dark mode toggle.", labels: []),
        expected: "/ai-migration-kit:create-issue Add a dark mode toggle."
    ),
    Golden(
        what: "create-issue, two labels",
        action: .createIssue(idea: "Add a dark mode toggle.", labels: ["bug", "documentation"]),
        expected: #"/ai-migration-kit:create-issue Add a dark mode toggle. --label "bug" --label "documentation""#
    ),
    Golden(
        what: "create-issue, blank labels dropped",
        action: .createIssue(idea: "Ship it", labels: ["", "   ", "\n", "bug"]),
        expected: #"/ai-migration-kit:create-issue Ship it --label "bug""#
    ),
    Golden(
        what: "create-issue, quotes and backslashes in the labels",
        action: .createIssue(idea: "Ship it", labels: [#"needs "review""#, #"C:\path\"#]),
        expected: #"/ai-migration-kit:create-issue Ship it --label "needs \"review\"" --label "C:\\path\\""#
    ),
    Golden(
        // The idea is collapsed and *never* escaped — routing it through
        // `sanitized` would be a plausible tidy-up and a behaviour change.
        what: "create-issue, quotes, backslashes and newlines in the idea",
        action: .createIssue(idea: "Add \"dark mode\"\nwith a \\back\\slash inside"),
        expected: #"/ai-migration-kit:create-issue Add "dark mode" with a \back\slash inside"#
    ),
    Golden(
        what: "implement-issue, the number and nothing else",
        action: .implementIssue(issueNumber: 47),
        expected: "/ai-migration-kit:implement-issue 47"
    ),
    Golden(
        what: "implement-issue, four digits",
        action: .implementIssue(issueNumber: 1234),
        expected: "/ai-migration-kit:implement-issue 1234"
    ),
    Golden(
        what: "merge-pr, no follow-ups",
        action: .mergePR(prNumber: 279, followUps: []),
        expected: "/ai-migration-kit:merge-pr 279"
    ),
    Golden(
        what: "merge-pr, two follow-ups",
        action: .mergePR(prNumber: 279, followUps: ["add Rust snapshot tests", "document minimap config"]),
        expected: #"/ai-migration-kit:merge-pr 279 --follow-up "add Rust snapshot tests" --follow-up "document minimap config""#
    ),
    Golden(
        what: "merge-pr, blank follow-ups dropped",
        action: .mergePR(prNumber: 279, followUps: ["", "   ", "\n", "real one"]),
        expected: #"/ai-migration-kit:merge-pr 279 --follow-up "real one""#
    ),
    Golden(
        what: "merge-pr, quotes and backslashes in a follow-up",
        action: .mergePR(prNumber: 1, followUps: [#"handle C:\path\ and "quotes""#]),
        expected: #"/ai-migration-kit:merge-pr 1 --follow-up "handle C:\\path\\ and \"quotes\"""#
    ),
]

/// The single most important test of wave 1.
///
/// While it passes, method packs are a refactor for every repository in the
/// field: the pack the catalogue answers for "never chose one" reproduces the
/// hardcoded builder byte for byte. If it reddens, 100 % of current users'
/// behaviour changed while we thought we were opening the product up.
@Suite("Golden prompts")
struct GoldenPromptTests {

    @Test("The ai-migration-kit pack reproduces the shipped prompt byte for byte", arguments: goldens)
    func slashPromptIsUnchanged(golden: Golden) throws {
        let kit = try #require(aiMigrationKitPack(), "the catalogue answered no default pack")
        #expect(
            SlashCommandBuilder.prompt(for: golden.action, method: kit) == golden.expected,
            "\(golden.what) drifted"
        )
    }

    /// The one paid-for trap in this subject: backslashes are escaped **before**
    /// quotes, and reversing the two turns `\"` back into a live delimiter. The
    /// payload here is the discriminator — a backslash immediately followed by a
    /// quote — and the wrong order leaves three unescaped quotes where two is the
    /// whole flag. Asserted through *both* tails, because they must be the one
    /// sanitiser and not two.
    @Test("Backslash-then-quote survives both tails, in the shipped order")
    func theOneEscapingOrderThatMatters() throws {
        let kit = try #require(aiMigrationKitPack())
        let payload = #"a\"b"#

        let labelled = SlashCommandBuilder.prompt(
            for: .createIssue(idea: "Ship it", labels: [payload]), method: kit
        )
        #expect(labelled == #"/ai-migration-kit:create-issue Ship it --label "a\\\"b""#)
        #expect(countUnescapedQuotes(in: labelled) == 2)

        let followed = SlashCommandBuilder.prompt(
            for: .mergePR(prNumber: 7, followUps: [payload]), method: kit
        )
        #expect(followed == #"/ai-migration-kit:merge-pr 7 --follow-up "a\\\"b""#)
        #expect(countUnescapedQuotes(in: followed) == 2)
    }

    /// What a golden table cannot pin: the fallback's exact sentence, which is
    /// now the pack's `prose` and so is data rather than code. What is pinned is
    /// the rendering rule — the prose, then the very same escaped tail the slash
    /// form emits — which is why there is one renderer and not two.
    @Test("The natural-language fallback is the prose plus the same escaped tail")
    func naturalFallbackIsProseThenTail() throws {
        let kit = try #require(aiMigrationKitPack())
        let step = try #require(kit.steps[.createIssue])
        let prompt = SlashCommandBuilder.prompt(
            for: .createIssue(idea: "Add a dark mode toggle.", labels: ["bug"]),
            method: kit,
            strategy: .naturalLanguage
        )
        #expect(prompt == step.prose + #" Add a dark mode toggle. --label "bug""#)
        #expect(!prompt.contains("\n"))
    }

    /// A pack may legitimately declare no step for a kind — the catalogue ships a
    /// BMAD pack carrying project requirements and nothing else — and this
    /// builder returns `String`, so it has to answer something. It answers with
    /// the skill's own name and **never** another method's command: substituting
    /// one is the silent substitution `MethodResolution` was made three-valued to
    /// refuse, and it would run ai-migration-kit inside a repository that chose
    /// something else.
    ///
    /// Unreachable from the board once `BoardService.makeRun` refuses first
    /// (Task 7); pinned here because the rest of this file assumes a total
    /// function.
    @Test("A pack with no step names the skill rather than borrowing a command")
    func aPackWithNoStepBorrowsNothing() {
        let stepless = MethodPack(
            id: "stepless",
            displayName: "Stepless",
            summary: "carries project requirements and no steps",
            plugin: .none,
            projectRequirements: [],
            steps: [:]
        )
        #expect(
            SlashCommandBuilder.prompt(for: .implementIssue(issueNumber: 47), method: stepless)
                == "implement-issue 47"
        )
        let created = SlashCommandBuilder.prompt(
            for: .createIssue(idea: "Ship it", labels: ["bug"]), method: stepless
        )
        #expect(created == #"create-issue Ship it --label "bug""#)
        #expect(!created.contains("ai-migration-kit"), "a stepless pack borrowed another's command")
    }

    /// ⛔ A form whose action carries no payload appends **nothing**, not a lone
    /// trailing space. `promptsAreSingleLine` forbids `"  "` and newlines and
    /// would not see a single trailing one; this is the assertion that does.
    @Test("A form asking for a payload its action does not carry appends nothing")
    func aMisdeclaredFormAppendsNothing() {
        let misdeclared = MethodPack(
            id: "misdeclared", displayName: "Misdeclared", summary: "s", plugin: .none,
            steps: [.implementIssue: StepSpec(
                command: "/x:go", arguments: .ideaThenLabels, prose: "Go: {}")]
        )
        let prompt = SlashCommandBuilder.prompt(
            for: .implementIssue(issueNumber: 47), method: misdeclared)
        #expect(prompt == "/x:go", "a misdeclared form emitted \(String(reflecting: prompt))")
    }

    /// `.idea` is `.ideaThenLabels` minus the flag tail — GSD's `/gsd-capture`
    /// documents `--note`, `--backlog`, `--seed` and `--list`, and does **not**
    /// accept `--label`. A card's labels are carried by the action regardless of
    /// which pack the repository chose, so this is the one place a form that
    /// silently reused `.ideaThenLabels`' flattening would be caught: the label
    /// would reach a command that cannot parse it.
    @Test("A pack declaring .idea drops labels rather than flagging them")
    func ideaFormDropsLabels() throws {
        let gsd = try #require(MethodCatalog.builtIn.first { $0.id == "gsd" })
        #expect(gsd.steps[.createIssue]?.arguments == .idea)
        let prompt = SlashCommandBuilder.prompt(
            for: .createIssue(idea: "Add a dark mode toggle.", labels: ["bug", "documentation"]),
            method: gsd
        )
        #expect(prompt == "/gsd-capture Add a dark mode toggle.")
        #expect(!prompt.contains("--label"), "the .idea form must not carry a label flag: \(prompt)")
    }

    /// Protects `promptsAreSingleLine` for every pack rather than for the one
    /// this file resolves: a command or a prose sentence carrying a newline, a
    /// tab or a double space would produce a multi-line prompt for the pack that
    /// declared it, and no test of the default pack could see it.
    @Test("No built-in pack declares a command or a prose sentence that is not one line")
    func packStringsAreSingleLine() {
        for pack in MethodCatalog.builtIn {
            for kind in SkillKind.allCases {
                guard let step = pack.steps[kind] else { continue }
                for text in [step.command, step.prose] {
                    #expect(!text.contains("\n"), "\(pack.id) \(kind.skillName): newline in \"\(text)\"")
                    #expect(!text.contains("\t"), "\(pack.id) \(kind.skillName): tab in \"\(text)\"")
                    #expect(!text.contains("  "), "\(pack.id) \(kind.skillName): double space in \"\(text)\"")
                }
            }
        }
    }
}
