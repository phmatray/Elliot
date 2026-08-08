import Foundation

/// How a `TriggerAction` is expressed to `claude -p`.
///
/// `.slashCommand` is the documented form: user-invocable skills expand from
/// `/plugin:skill` in a `-p` prompt. `.naturalLanguage` exists as a fallback in
/// case a future release stops expanding them, so swapping is one line and one
/// test update rather than a rewrite.
public enum PromptStrategy: String, Codable, CaseIterable, Sendable, Hashable {
    case slashCommand
    case naturalLanguage
}

public enum SkillKind: String, Codable, CaseIterable, Sendable, Hashable {
    case createIssue
    case implementIssue
    case mergePR
    /// Reading a repository through one lens. Not a plugin skill — see below.
    case analyzeRepo

    /// The bare skill name, and the one word every layer uses for this skill:
    /// `RunDTO.kind`, `MoveDTO.triggered` and `NextDTO.wouldTrigger` all read
    /// the same string, so an agent correlating them needs no table.
    ///
    /// Not the raw value, which is persisted and therefore stuck with
    /// `createIssue`. Decoupling the two is what makes this rename free.
    ///
    /// `.analyzeRepo` is named here even though it is no plugin skill: an
    /// analysis run reaches `RunDTO` like any other, and a run whose kind
    /// rendered as empty would be the one an agent could not correlate.
    public var skillName: String {
        switch self {
        case .createIssue: "create-issue"
        case .implementIssue: "implement-issue"
        case .mergePR: "merge-pr"
        case .analyzeRepo: "analyze-repo"
        }
    }

    /// Plugin-qualified slash name, for the three kinds that *are* plugin
    /// skills. The CLI builds component ids as `"\(pluginName):\(name)"`.
    ///
    /// `.analyzeRepo` has none: there is no `analyze-repo` skill anywhere, that
    /// prompt is Elliot's own and is built by `AnalysisPromptBuilder`.
    public var slashName: String? {
        switch self {
        case .createIssue: "/ai-migration-kit:create-issue"
        case .implementIssue: "/ai-migration-kit:implement-issue"
        case .mergePR: "/ai-migration-kit:merge-pr"
        case .analyzeRepo: nil
        }
    }
}

public extension TriggerAction {
    var kind: SkillKind {
        switch self {
        case .createIssue: .createIssue
        case .implementIssue: .implementIssue
        case .mergePR: .mergePR
        }
    }

    /// The issue or PR number this action targets, if any. Used for the
    /// scheduler's dedupe key.
    var targetNumber: Int? {
        switch self {
        case .createIssue: nil
        case .implementIssue(let n): n
        case .mergePR(let pr, _): pr
        }
    }
}

public enum SlashCommandBuilder {
    public static func prompt(
        for action: TriggerAction,
        strategy: PromptStrategy = .slashCommand
    ) -> String {
        switch strategy {
        case .slashCommand: slashPrompt(for: action)
        case .naturalLanguage: naturalPrompt(for: action)
        }
    }

    private static func slashPrompt(for action: TriggerAction) -> String {
        // A `TriggerAction` is by construction one of the three plugin skills,
        // so this is never nil on this path. Falling back rather than forcing
        // keeps the function total if that ever stops being true.
        guard let name = action.kind.slashName else { return naturalPrompt(for: action) }

        switch action {
        case .createIssue(let idea, let labels):
            // Free text; the skill infers scope from it. Flattened because the
            // whole prompt is one argv element and one logical line.
            //
            // The flags go *after* the idea and never before it: the idea is
            // free text the skill reads to the end of, so a flag in front of it
            // would be swallowed as part of what the issue is about.
            return "\(name) \(idea.collapsedToSingleLine())\(flags("--label", labels))"

        case .implementIssue(let n):
            // The skill resolves its argument with `grep -oE '[0-9]+' | head -1`.
            // Emit the number and nothing else — no title, no '#', no year.
            // `SlashCommandBuilderTests.firstDigitRunIsTheIssueNumber` guards this.
            return "\(name) \(n)"

        case .mergePR(let pr, let followUps):
            return "\(name) \(pr)\(flags("--follow-up", followUps))"
        }
    }

    private static func naturalPrompt(for action: TriggerAction) -> String {
        switch action {
        case .createIssue(let idea, let labels):
            var s = "Use the create-issue skill to file a GitHub issue for this user story: "
                + idea.collapsedToSingleLine()
            // Named here too, so the fallback files the same issue the slash
            // form would. A strategy nobody chose per-card silently dropping
            // the one thing the card was allowed to decide is exactly the
            // divergence `.naturalLanguage` exists to be a *drop-in* for.
            let wanted = quoted(labels)
            if !wanted.isEmpty { s += " Apply these labels to it: \(wanted)." }
            return s

        case .implementIssue(let n):
            return "Use the implement-issue skill on issue \(n): execute its implementation "
                + "plan and open a pull request."

        case .mergePR(let pr, let followUps):
            var s = "Use the merge-pr skill to land pull request \(pr)."
            let items = quoted(followUps)
            if !items.isEmpty {
                s += " File these follow-ups after merging: \(items)."
            }
            return s
        }
    }

    // MARK: - Repeatable quoted arguments

    /// A repeatable `--<flag> "<value>"` tail, one per non-blank value, or the
    /// empty string when there are none.
    ///
    /// Written once because there are now two of these — `--follow-up` and
    /// `--label` — and they are the same hazard with different names: the
    /// quotes are structural in the argv the skill parses, so an unescaped one
    /// in the payload closes the flag early and leaves the rest as stray text
    /// the skill reads as something else. A second copy would be a second place
    /// for that escaping to be got wrong.
    ///
    /// Empty in, empty out — so a card that named no labels produces the prompt
    /// this skill has always been sent, byte for byte.
    private static func flags(_ flag: String, _ values: [String]) -> String {
        sanitized(values).map { " \(flag) \"\($0)\"" }.joined()
    }

    /// The same values as a comma-separated quoted list, for the prose form.
    private static func quoted(_ values: [String]) -> String {
        sanitized(values).map { #""\#($0)""# }.joined(separator: ", ")
    }

    /// Flattened, escaped, and blanks dropped — an empty flag would ask the
    /// skill to apply a label named nothing.
    ///
    /// Backslashes first, then quotes: reversing the two would escape the
    /// backslash this function just introduced and turn `\"` back into a live
    /// delimiter.
    private static func sanitized(_ values: [String]) -> [String] {
        values
            .map {
                $0.collapsedToSingleLine()
                    .replacingOccurrences(of: "\\", with: "\\\\")
                    .replacingOccurrences(of: "\"", with: "\\\"")
            }
            .filter { !$0.isEmpty }
    }
}

extension String {
    /// Collapses every run of whitespace (including newlines and tabs) into a
    /// single space, and trims the ends.
    func collapsedToSingleLine() -> String {
        split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
    }
}
