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
        case .createIssue(let idea):
            // Free text; the skill infers scope from it. Flattened because the
            // whole prompt is one argv element and one logical line.
            return "\(name) \(idea.collapsedToSingleLine())"

        case .implementIssue(let n):
            // The skill resolves its argument with `grep -oE '[0-9]+' | head -1`.
            // Emit the number and nothing else — no title, no '#', no year.
            // `SlashCommandBuilderTests.firstDigitRunIsTheIssueNumber` guards this.
            return "\(name) \(n)"

        case .mergePR(let pr, let followUps):
            // The skill parses `--follow-up "<idea>"` out of the text, so quotes
            // are structural here and must be escaped inside the payload.
            let tail = followUps
                .map(sanitizeFollowUp)
                .filter { !$0.isEmpty }
                .map { #" --follow-up "\#($0)""# }
                .joined()
            return "\(name) \(pr)\(tail)"
        }
    }

    private static func naturalPrompt(for action: TriggerAction) -> String {
        switch action {
        case .createIssue(let idea):
            return "Use the create-issue skill to file a GitHub issue for this user story: "
                + idea.collapsedToSingleLine()

        case .implementIssue(let n):
            return "Use the implement-issue skill on issue \(n): execute its implementation "
                + "plan and open a pull request."

        case .mergePR(let pr, let followUps):
            var s = "Use the merge-pr skill to land pull request \(pr)."
            let items = followUps
                .map(sanitizeFollowUp)
                .filter { !$0.isEmpty }
                .map { #""\#($0)""# }
                .joined(separator: ", ")
            if !items.isEmpty {
                s += " File these follow-ups after merging: \(items)."
            }
            return s
        }
    }

    /// Makes a follow-up safe to sit inside `--follow-up "…"`.
    private static func sanitizeFollowUp(_ s: String) -> String {
        s.collapsedToSingleLine()
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
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
