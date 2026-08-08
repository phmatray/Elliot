import Foundation
import Testing

@testable import ElliotModel

/// Mirrors the skills' own argument resolution:
/// `printf '%s' "$ARG" | grep -oE '[0-9]+' | head -1`.
private func firstDigitRun(of s: String) -> Int? {
    var digits = ""
    for ch in s {
        if ch.isNumber {
            digits.append(ch)
        } else if !digits.isEmpty {
            break
        }
    }
    return Int(digits)
}

/// Counts `"` characters that are not escaped by a preceding backslash,
/// accounting for escaped backslashes (`\\"` *is* an unescaped quote).
private func countUnescapedQuotes(in s: String) -> Int {
    var count = 0
    var pendingBackslashes = 0
    for ch in s {
        switch ch {
        case "\\":
            pendingBackslashes += 1
        case "\"":
            if pendingBackslashes.isMultiple(of: 2) { count += 1 }
            pendingBackslashes = 0
        default:
            pendingBackslashes = 0
        }
    }
    return count
}

/// Titles chosen to break a naive builder: quotes, newlines, backslashes,
/// stray issue references, digits, emoji.
private let nastyTitles = [
    #"Add "dark mode" to settings"#,
    "Fix the\nmulti-line\ttitle",
    #"Escape a \backslash\ properly"#,
    "Follow-up to #47 and #1234",
    "Support macOS 26.5 on 2026-08-04",
    "Ship it 🚀 — now",
    "   leading and trailing   ",
    "100% coverage",
]

@Suite("Slash command builder")
struct SlashCommandBuilderTests {

    // MARK: - Exact forms

    @Test("create-issue carries the idea as free text")
    func createIssueForm() {
        let prompt = SlashCommandBuilder.prompt(
            for: .createIssue(idea: "Add a dark mode toggle. Respect the system setting.")
        )
        #expect(prompt == "/ai-migration-kit:create-issue Add a dark mode toggle. Respect the system setting.")
    }

    @Test("create-issue flattens a multi-line story into one prompt line")
    func createIssueFlattensStory() {
        let story = UserStory(
            role: "developer",
            want: "to see the run log\ninside the card",
            benefit: "I can diagnose without a terminal"
        )
        let prompt = SlashCommandBuilder.prompt(for: .createIssue(idea: story.issueBody))
        #expect(prompt == "/ai-migration-kit:create-issue As a developer, I want to see the run log "
            + "inside the card, so that I can diagnose without a terminal.")
    }

    @Test("implement-issue carries the number and nothing else")
    func implementIssueForm() {
        let prompt = SlashCommandBuilder.prompt(for: .implementIssue(issueNumber: 47))
        #expect(prompt == "/ai-migration-kit:implement-issue 47")
    }

    @Test("merge-pr carries the number and one flag per follow-up")
    func mergePRForm() {
        let prompt = SlashCommandBuilder.prompt(
            for: .mergePR(prNumber: 279, followUps: ["add Rust snapshot tests", "document minimap config"])
        )
        #expect(prompt == #"/ai-migration-kit:merge-pr 279 --follow-up "add Rust snapshot tests" --follow-up "document minimap config""#)
    }

    @Test("merge-pr with no follow-ups is just the number")
    func mergePRWithoutFollowUps() {
        let prompt = SlashCommandBuilder.prompt(for: .mergePR(prNumber: 279, followUps: []))
        #expect(prompt == "/ai-migration-kit:merge-pr 279")
    }

    // MARK: - The property that protects against implementing the wrong issue

    @Test(
        "The first digit run of an implement-issue prompt is the issue number",
        arguments: [1, 4, 7, 9, 10, 47, 99, 100, 279, 1234, 99_999]
    )
    func firstDigitRunIsTheIssueNumber(issue: Int) {
        for strategy in PromptStrategy.allCases {
            let prompt = SlashCommandBuilder.prompt(
                for: .implementIssue(issueNumber: issue), strategy: strategy
            )
            #expect(
                firstDigitRun(of: prompt) == issue,
                "\(strategy) produced \"\(prompt)\", whose first digit run is not \(issue)"
            )
        }
    }

    @Test(
        "The first digit run of a merge-pr prompt is the PR number, whatever the follow-ups say",
        arguments: [1, 4, 47, 279, 1234]
    )
    func firstDigitRunIsThePRNumber(pr: Int) {
        let followUps = nastyTitles + ["fix 3 flaky tests", "0 downtime rollout", "#1 priority"]
        for strategy in PromptStrategy.allCases {
            let prompt = SlashCommandBuilder.prompt(
                for: .mergePR(prNumber: pr, followUps: followUps), strategy: strategy
            )
            #expect(
                firstDigitRun(of: prompt) == pr,
                "\(strategy) produced a prompt whose first digit run is not \(pr): \"\(prompt)\""
            )
        }
    }

    // MARK: - Flattening and escaping

    @Test("A prompt is always a single line", arguments: nastyTitles)
    func promptsAreSingleLine(title: String) {
        let actions: [TriggerAction] = [
            .createIssue(idea: "\(title)\nBody with\na newline"),
            .implementIssue(issueNumber: 47),
            .mergePR(prNumber: 279, followUps: [title]),
        ]
        for action in actions {
            for strategy in PromptStrategy.allCases {
                let prompt = SlashCommandBuilder.prompt(for: action, strategy: strategy)
                #expect(!prompt.contains("\n"), "newline survived in \"\(prompt)\"")
                #expect(!prompt.contains("\t"), "tab survived in \"\(prompt)\"")
                #expect(!prompt.contains("  "), "double space survived in \"\(prompt)\"")
            }
        }
    }

    @Test("Quotes inside a follow-up are escaped so they cannot close the flag")
    func followUpQuotesAreEscaped() {
        let prompt = SlashCommandBuilder.prompt(
            for: .mergePR(prNumber: 279, followUps: [#"add "dark mode" tests"#])
        )
        #expect(prompt == #"/ai-migration-kit:merge-pr 279 --follow-up "add \"dark mode\" tests""#)

        // Exactly two unescaped quotes: the flag's own delimiters. Any more and
        // the skill would read the follow-up as ending early, with stray text
        // after it.
        #expect(countUnescapedQuotes(in: prompt) == 2)
    }

    @Test("Backslashes inside a follow-up are escaped before the quotes")
    func followUpBackslashesAreEscaped() {
        let prompt = SlashCommandBuilder.prompt(
            for: .mergePR(prNumber: 1, followUps: [#"handle C:\path\ and "quotes""#])
        )
        #expect(prompt == #"/ai-migration-kit:merge-pr 1 --follow-up "handle C:\\path\\ and \"quotes\"""#)
    }

    @Test("Blank follow-ups are dropped rather than emitted as empty flags")
    func blankFollowUpsAreDropped() {
        let prompt = SlashCommandBuilder.prompt(
            for: .mergePR(prNumber: 279, followUps: ["", "   ", "\n", "real one"])
        )
        #expect(prompt == #"/ai-migration-kit:merge-pr 279 --follow-up "real one""#)
    }

    // MARK: - The labels the card asked for

    /// The common path must not move. Every other test in this file constructs
    /// `.createIssue(idea:)` without labels and asserts the string this skill
    /// has always been sent; they are unedited, so they say the same thing from
    /// a second direction. This one says it on purpose, against a literal.
    @Test("A card with no labels produces exactly the prompt it produced before")
    func noLabelsIsUnchanged() {
        for strategy in PromptStrategy.allCases {
            let without = SlashCommandBuilder.prompt(
                for: .createIssue(idea: "Add a dark mode toggle."), strategy: strategy
            )
            let empty = SlashCommandBuilder.prompt(
                for: .createIssue(idea: "Add a dark mode toggle.", labels: []), strategy: strategy
            )
            #expect(without == empty)
            #expect(!without.contains("--label"), "\(strategy) emitted a flag for no labels")
        }
        #expect(
            SlashCommandBuilder.prompt(for: .createIssue(idea: "Add a dark mode toggle."))
                == "/ai-migration-kit:create-issue Add a dark mode toggle."
        )
    }

    @Test("create-issue carries one flag per label, after the idea")
    func createIssueCarriesLabels() {
        let prompt = SlashCommandBuilder.prompt(
            for: .createIssue(idea: "Add a dark mode toggle.", labels: ["bug", "documentation"])
        )
        #expect(prompt == #"/ai-migration-kit:create-issue Add a dark mode toggle. --label "bug" --label "documentation""#)
    }

    /// The same sanitiser as `--follow-up`, because it is the same hazard: the
    /// quotes are structural in the argv the skill parses, so one inside the
    /// payload would close the flag early and leave the rest as stray text.
    @Test("Quotes and backslashes in a label are escaped exactly as a follow-up's are")
    func labelQuotesAreEscaped() {
        let prompt = SlashCommandBuilder.prompt(
            for: .createIssue(idea: "Ship it", labels: [#"needs "review""#, #"C:\path\"#])
        )
        #expect(prompt == #"/ai-migration-kit:create-issue Ship it --label "needs \"review\"" --label "C:\\path\\""#)
        // Four unescaped quotes: two flags' worth of delimiters, and nothing else.
        #expect(countUnescapedQuotes(in: prompt) == 4)
    }

    @Test("Blank labels are dropped rather than emitted as empty flags")
    func blankLabelsAreDropped() {
        let prompt = SlashCommandBuilder.prompt(
            for: .createIssue(idea: "Ship it", labels: ["", "   ", "\n", "bug"])
        )
        #expect(prompt == #"/ai-migration-kit:create-issue Ship it --label "bug""#)
    }

    /// `.naturalLanguage` exists so the slash form can be abandoned in one line
    /// if the CLI ever stops expanding it. A fallback that silently dropped the
    /// labels would file differently-labelled issues from the same card
    /// depending on a strategy nobody chose per-card.
    @Test("The natural-language fallback names the labels too", arguments: nastyTitles)
    func naturalLanguageKeepsTheLabels(label: String) {
        let prompt = SlashCommandBuilder.prompt(
            for: .createIssue(idea: "Add a dark mode toggle.", labels: [label]),
            strategy: .naturalLanguage
        )
        #expect(prompt.contains("label"), "the labels vanished from \"\(prompt)\"")
        #expect(!prompt.contains("\n"), "newline survived in \"\(prompt)\"")
        #expect(!prompt.contains("  "), "double space survived in \"\(prompt)\"")
    }

    @Test("A prompt carrying labels is still a single line", arguments: nastyTitles)
    func labelledPromptsAreSingleLine(label: String) {
        for strategy in PromptStrategy.allCases {
            let prompt = SlashCommandBuilder.prompt(
                for: .createIssue(idea: "A story\nover two lines", labels: [label, "bug"]),
                strategy: strategy
            )
            #expect(!prompt.contains("\n"), "newline survived in \"\(prompt)\"")
            #expect(!prompt.contains("\t"), "tab survived in \"\(prompt)\"")
            #expect(!prompt.contains("  "), "double space survived in \"\(prompt)\"")
        }
    }

    /// Labels change nothing about the other two skills, and the invariant that
    /// matters most in this file is the one they carry. Stated here rather than
    /// assumed, because `--label` is the first thing ever appended to a prompt
    /// that is not `merge-pr`'s.
    @Test(
        "Labels on a card do not disturb the implement-issue first digit run",
        arguments: [4, 47, 171, 1234]
    )
    func labelsDoNotDisturbTheIssueNumber(issue: Int) {
        for strategy in PromptStrategy.allCases {
            let prompt = SlashCommandBuilder.prompt(
                for: .implementIssue(issueNumber: issue), strategy: strategy
            )
            #expect(firstDigitRun(of: prompt) == issue)
        }
    }

    // MARK: - Metadata used by the scheduler

    @Test("Each action reports the skill and target the scheduler keys on")
    func actionMetadata() {
        #expect(TriggerAction.createIssue(idea: "x").kind == .createIssue)
        #expect(TriggerAction.createIssue(idea: "x").targetNumber == nil)
        #expect(TriggerAction.implementIssue(issueNumber: 47).kind == .implementIssue)
        #expect(TriggerAction.implementIssue(issueNumber: 47).targetNumber == 47)
        #expect(TriggerAction.mergePR(prNumber: 279, followUps: []).kind == .mergePR)
        #expect(TriggerAction.mergePR(prNumber: 279, followUps: []).targetNumber == 279)
    }

    @Test("Slash names are plugin-qualified with a colon")
    func slashNames() {
        #expect(SkillKind.createIssue.slashName == "/ai-migration-kit:create-issue")
        #expect(SkillKind.implementIssue.slashName == "/ai-migration-kit:implement-issue")
        #expect(SkillKind.mergePR.slashName == "/ai-migration-kit:merge-pr")
    }
}
