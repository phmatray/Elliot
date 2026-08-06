import Foundation

/// A lens the repository is read through.
///
/// The lens is data, not a code path: `briefing` is the paragraph handed to the
/// model, so adding an angle is a case and a paragraph. Each briefing says both
/// what to look for *and* what to leave alone — without the second half every
/// lens drifts back towards generic code review, and eight lenses return the
/// same eight lists.
public enum AnalysisAngle: String, Codable, CaseIterable, Sendable, Hashable {
    case bugs
    case quickWins
    case features
    case techDebt
    case tests
    case docsAndDX
    case uxAndUI
    case bestPractices

    public var title: String {
        switch self {
        case .bugs: "Bugs"
        case .quickWins: "Quick wins"
        case .features: "Features"
        case .techDebt: "Tech debt"
        case .tests: "Tests"
        case .docsAndDX: "Docs & DX"
        case .uxAndUI: "UX & UI"
        case .bestPractices: "Best practices"
        }
    }

    public var symbol: String {
        switch self {
        case .bugs: "🐛"
        case .quickWins: "⚡"
        case .features: "✨"
        case .techDebt: "🧹"
        case .tests: "🧪"
        case .docsAndDX: "📖"
        case .uxAndUI: "🎨"
        case .bestPractices: "📐"
        }
    }

    public var briefing: String {
        switch self {
        case .bugs:
            """
            Look for defects: races and ordering assumptions, errors that are \
            swallowed or logged and then ignored, unhandled edge cases, \
            resources that leak on the failure path, off-by-one and boundary \
            handling, and state that can be observed half-updated. Prefer a \
            defect you can point at in the code over one you can imagine. \
            Leave style, naming and personal preference alone.
            """
        case .quickWins:
            """
            Look for changes with a high ratio of value to effort: something a \
            developer could finish in one sitting, that carries little risk, \
            and that removes a recurring irritation or unblocks something else. \
            Prefer what is already half-built over what must be designed. \
            Leave anything architectural alone — if it needs a new abstraction, \
            it is not a quick win.
            """
        case .features:
            """
            Look for capabilities the shape of this repository is asking for: \
            what the existing types almost support, what a user of this code \
            would reach for next, what a half-finished seam suggests was \
            intended. Ground each one in what is already there. Leave alone \
            anything that duplicates a capability the repository already has \
            elsewhere, and anything that would be a different product.
            """
        case .techDebt:
            """
            Look for structure that is costing something now: duplicated logic \
            that has already drifted, boundaries that leak so callers must know \
            internals, files that have grown to do several unrelated jobs, and \
            abstractions that no longer match how they are used. Say what the \
            cost is. Leave cosmetic renames and reformatting alone.
            """
        case .tests:
            """
            Look for invariants the code depends on but no test asserts: error \
            paths, cancellation, concurrency, boundary values, and the exact \
            behaviours a comment claims. Prefer one test that would have caught \
            a real bug over ten that restate the implementation. Leave alone \
            anything whose only justification is raising a coverage number.
            """
        case .docsAndDX:
            """
            Look for friction a newcomer hits: setup steps that are implied \
            rather than written, error messages that do not say what to do \
            next, commands that need flags nobody would guess, and documented \
            behaviour that no longer matches the code. Leave typos and prose \
            polish alone.
            """
        case .uxAndUI:
            """
            Look for what the person using this app runs into: a state with no \
            empty, loading or error case, a control that gives no sign it \
            worked, a destructive action with no confirmation and no undo, a \
            keyboard or VoiceOver path that dead-ends, and copy that names \
            internals rather than what the reader wants. Prefer a screen you \
            can point at over a principle. Leave visual taste alone — spacing, \
            colour and type are already decided here, and reopening them is a \
            design decision rather than a finding.
            """
        case .bestPractices:
            """
            Look for where the code has left the conventions this project \
            wrote down and the idioms of the language and frameworks it uses: \
            a rule stated in CLAUDE.md or a target's own documentation that \
            the code no longer follows, error handling or concurrency done a \
            different way in each file, an API that fights the platform's \
            naming and lifecycle expectations, and a pattern copied from \
            before a better one existed here. Cite the rule you are measuring \
            against. Leave anything you cannot tie to a written convention or \
            a documented idiom alone — that is taste, and another lens owns it.
            """
        }
    }
}
