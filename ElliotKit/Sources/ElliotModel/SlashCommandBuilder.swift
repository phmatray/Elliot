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
    ///
    /// ⛔ There is deliberately no `slashName` any more. It hardcoded
    /// `/ai-migration-kit:…` for three of the four cases, which made one
    /// methodology the only one a board could drive. What a kind runs is
    /// `MethodPack.steps[kind]?.command`, chosen per repository — and this
    /// name is what a pack that declares no step falls back to, below.
    public var skillName: String {
        switch self {
        case .createIssue: "create-issue"
        case .implementIssue: "implement-issue"
        case .mergePR: "merge-pr"
        case .analyzeRepo: "analyze-repo"
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
    /// scheduler's dedupe key, and by `.number` below.
    var targetNumber: Int? {
        switch self {
        case .createIssue: nil
        case .implementIssue(let n): n
        case .mergePR(let pr, _): pr
        }
    }
}

public enum SlashCommandBuilder {
    /// The prompt for one action, in the method the repository chose.
    ///
    /// `method` carries **no default value**, on purpose. Defaulting it to
    /// ai-migration-kit would make "this caller never resolved a pack" and
    /// "this repository chose the default" the same call — the two-valued
    /// answer to a three-valued question `MethodResolution` exists to refuse,
    /// one layer up.
    ///
    /// The pack picks the command name and the argument *form*; every byte of
    /// escaping stays in `flags`/`sanitized` below, which is the whole reason
    /// `ArgumentForm` is a closed enum rather than a template string.
    ///
    /// Total by construction: a pack that declares no step for this kind gets
    /// `undeclaredStep` below. The **refusal** lives in `BoardService.makeRun`,
    /// which can decline to move a card; a `String` return cannot.
    public static func prompt(
        for action: TriggerAction,
        method: MethodPack,
        strategy: PromptStrategy = .slashCommand
    ) -> String {
        let step = method.steps[action.kind] ?? undeclaredStep(for: action)
        switch strategy {
        case .slashCommand:
            return step.command + tail(step.arguments, of: action)
        case .naturalLanguage:
            // `{}` is a marker, not a prefix — two of the three shipped
            // sentences carry the payload mid-sentence
            // ("…on issue {}: execute…"), so this cannot be reproduced by
            // concatenating a fixed head and a fixed tail the way the slash
            // form is. `StepSpec.prose`'s contract is exactly one `{}` for
            // every payload-carrying form (`MethodCatalogTests.proseSlots`),
            // so a literal, unconditional replace is correct: for `.none`,
            // `payload` is `""` and the prose carries no `{}` to touch.
            let substituted = step.prose.replacingOccurrences(
                of: "{}", with: payload(step.arguments, of: action)
            )
            return substituted + flagsTail(step.arguments, of: action)
        }
    }

    /// The step a pack does not declare.
    ///
    /// It answers with the skill's own name, never another method's command —
    /// and its prose carries the same `{}` marker every declared step's does,
    /// so `.naturalLanguage` does not silently drop the payload here either.
    private static func undeclaredStep(for action: TriggerAction) -> StepSpec {
        StepSpec(
            command: action.kind.skillName,
            arguments: form(of: action),
            prose: "Use the \(action.kind.skillName) skill: {}"
        )
    }

    private static func form(of action: TriggerAction) -> ArgumentForm {
        switch action {
        case .createIssue: .ideaThenLabels
        case .implementIssue: .number
        case .mergePR: .numberThenFollowUps
        }
    }

    // MARK: - The four argument forms

    /// What the declared form appends, and the only place a payload is escaped.
    ///
    /// The form decides; the action supplies. ⛔ **A form asking for a payload
    /// its action does not carry appends nothing** — not a lone space, which is
    /// what a naive `" \(idea)"` emits and what `promptsAreSingleLine` cannot
    /// see. A pack that does that is misdeclared; `MethodCatalogTests` and
    /// `SlashCommandBuilderTests.everyNumberFormPutsTheNumberFirst` are where to
    /// catch it, and `GoldenPromptTests.aMisdeclaredFormAppendsNothing` is what
    /// makes this sentence true rather than aspirational.
    ///
    /// Each case reproduces the string the hardcoded builder emitted, leading
    /// space included, which is what `GoldenPromptTests` pins:
    /// `--label`/`--follow-up` flags go *after* the free text and never before
    /// it, because the idea is read to the end of.
    ///
    /// Built from `payload` and `flagsTail` below rather than switching again:
    /// those two are also what `.naturalLanguage` substitutes into `prose` and
    /// appends after it, and a second switch here is a second place the two
    /// strategies' payload could quietly stop agreeing.
    private static func tail(_ form: ArgumentForm, of action: TriggerAction) -> String {
        let text = payload(form, of: action)
        return (text.isEmpty ? "" : " \(text)") + flagsTail(form, of: action)
    }

    /// The raw payload — no leading space, no flags — substituted at a
    /// `.naturalLanguage` prose's `{}` marker, and what `tail` above prefixes
    /// with a leading space for the slash form.
    ///
    /// Emitted alone for a number, so the skills' `grep -oE '[0-9]+' | head -1`
    /// reads it: no title, no '#', no year.
    private static func payload(_ form: ArgumentForm, of action: TriggerAction) -> String {
        switch form {
        case .none:
            ""
        case .idea, .ideaThenLabels:
            idea(of: action)
        case .number, .numberThenFollowUps:
            action.targetNumber.map(String.init) ?? ""
        }
    }

    /// The repeatable `--label`/`--follow-up` flags alone, with no payload —
    /// shared by both strategies, which is what keeps the escaping in exactly
    /// one place. Appended *after* the substituted prose for `.naturalLanguage`
    /// and after the payload for `.slashCommand`.
    private static func flagsTail(_ form: ArgumentForm, of action: TriggerAction) -> String {
        switch form {
        case .none, .idea, .number:
            ""
        case .ideaThenLabels:
            flags("--label", labels(of: action))
        case .numberThenFollowUps:
            flags("--follow-up", followUps(of: action))
        }
    }

    /// Flattened because the whole prompt is one argv element and one logical
    /// line — and deliberately **not** escaped: the idea is free text, and the
    /// shipped builder passed it through untouched.
    private static func idea(of action: TriggerAction) -> String {
        switch action {
        case .createIssue(let idea, _): idea.collapsedToSingleLine()
        case .implementIssue, .mergePR: ""
        }
    }

    private static func labels(of action: TriggerAction) -> [String] {
        switch action {
        case .createIssue(_, let labels): labels
        case .implementIssue, .mergePR: []
        }
    }

    private static func followUps(of action: TriggerAction) -> [String] {
        switch action {
        case .mergePR(_, let followUps): followUps
        case .createIssue, .implementIssue: []
        }
    }

    // MARK: - Repeatable quoted arguments

    /// A repeatable `--<flag> "<value>"` tail, one per non-blank value, or the
    /// empty string when there are none.
    ///
    /// Written once because there are two of these — `--follow-up` and
    /// `--label` — and they are the same hazard with different names: the
    /// quotes are structural in the argv the skill parses, so an unescaped one
    /// in the payload closes the flag early and leaves the rest as stray text
    /// the skill reads as something else. A second copy would be a second place
    /// for that escaping to be got wrong, and a pack-supplied template string
    /// would be a third.
    ///
    /// Empty in, empty out — so a card that named no labels produces the prompt
    /// this skill has always been sent, byte for byte.
    private static func flags(_ flag: String, _ values: [String]) -> String {
        sanitized(values).map { " \(flag) \"\($0)\"" }.joined()
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
