import Foundation

/// What a run started in one repository is allowed to do.
///
/// The two fields have been columns since the **v1** schema, are read at spawn
/// by `RunScheduler` and emitted by `ClaudeInvocation.arguments()`, and are
/// reported over the wire — and until #333 nothing anywhere ever *wrote* them.
/// Every registered repository ran on identical terms, so `Repo.permissionMode`'s
/// own doc comment ("per-repo so a single repo can be tightened without touching
/// the others") described a capability that did not exist.
///
/// This file is the missing half: the vocabulary a picker needs, the rule that
/// an empty tool list means no flag, and the one value an edit travels in.

// MARK: - What a mode is called, and what may honestly be said about it

extension PermissionMode {
    /// The CLI token rendered as English.
    ///
    /// A rendering, not a claim: `bypassPermissions` and `acceptEdits` are
    /// argument tokens, and a picker showing raw tokens asks the reader to know
    /// Claude Code's grammar before they can bound what an unattended agent may
    /// do to their checkout.
    public var title: String {
        switch self {
        case .manual: "Ask every time"
        case .acceptEdits: "Accept edits"
        case .auto: "Auto"
        case .dontAsk: "Don't ask"
        case .plan: "Plan only"
        case .bypassPermissions: "Bypass permissions"
        }
    }

    /// One sentence about a run **Elliot** starts under this mode.
    ///
    /// ⛔ Deliberately not a description of what each mode does inside Claude
    /// Code. `claude --help` lists the six tokens and **no semantics for any of
    /// them** (verified 2026-08-09), and `bypassPermissions` is the only one
    /// this board has ever run — it is the default on every row precisely
    /// because nothing could write another. Explaining the other five would be
    /// this repository's own most expensive mistake in miniature: prose
    /// asserting behaviour nobody measured, which afterwards reads as a
    /// measurement. See CLAUDE.md on `x402-dotnet`, where a workflow *comment*
    /// froze a wrong conclusion and then served as everyone's evidence.
    ///
    /// So each sentence says only what is checkable here, and the honest
    /// admission is itself the useful information: five of these are untravelled
    /// road.
    public var explanation: String {
        switch self {
        case .bypassPermissions:
            "Every tool call is allowed without asking. This is what makes moving a card "
                + "equivalent to running the skill by hand, and it is what every repository "
                + "has run under until now."
        case .manual, .acceptEdits, .auto, .dontAsk, .plan:
            "Claude Code decides what this run may touch. Elliot has never started a run "
                + "under this mode, so what it does to an unattended one is Claude Code's "
                + "answer to give, not this screen's."
        }
    }

    /// Present when choosing this mode changes what a *triggering move*
    /// accomplishes, rather than only what the run is allowed to touch.
    ///
    /// A closed set rather than free prose, so the two distinct warnings cannot
    /// drift into five near-copies of each other — the failure this codebase has
    /// paid for repeatedly, most recently in the three hand-written switches
    /// #135 collapsed.
    public var caveat: RunTermsCaveat? {
        switch self {
        case .bypassPermissions: nil
        case .plan: .plansRatherThanActs
        case .manual, .acceptEdits, .auto, .dontAsk: .unattended
        }
    }
}

/// The two things worth warning about before a repository leaves
/// `bypassPermissions`.
public enum RunTermsCaveat: String, Codable, Sendable, Hashable, CaseIterable {
    /// A run Elliot starts has nobody to answer a permission prompt.
    ///
    /// This is not speculation about the mode: it is a fact about *Elliot*. Runs
    /// are `claude -p` children with no terminal, and `SkillRun.permissionDenials`
    /// exists because a run can end `subtype: "success"` having been refused a
    /// tool and quietly worked around the gap — which is why a run counts as
    /// clean only when that list is empty.
    case unattended

    /// `plan` is Claude Code's planning mode.
    ///
    /// Named separately from ``unattended`` because the failure is a different
    /// one: not a refused tool that shows up in `permissionDenials`, but a run
    /// that does everything asked of it and creates nothing. `Verifier` then
    /// finds no issue and the card gains no number — a move that succeeded at
    /// accomplishing nothing, which is exactly the false-negative family
    /// CLAUDE.md catalogues.
    case plansRatherThanActs

    /// Shown under the picker when the chosen mode carries it.
    public var sentence: String {
        switch self {
        case .unattended:
            "Runs are unattended — nobody is there to answer a permission prompt. A run may "
                + "finish having been refused a tool; Elliot records that and does not count "
                + "the run as clean."
        case .plansRatherThanActs:
            "Claude Code plans rather than acts, so a triggering move may run to completion "
                + "and still leave the card with no issue, branch or pull request."
        }
    }
}

// MARK: - The empty-list rule, in one place

/// The rule that an empty extra-allowed-tools list means *no flag*.
///
/// `ClaudeInvocation.arguments()` emits `--allowedTools` only when the list is
/// non-empty, so a list holding one blank string is not "no tools" — it is
/// `--allowedTools ""`, an empty pattern handed to the CLI. That distinction is
/// invisible in a text field and would only ever be discovered inside a run.
public enum ExtraAllowedTools {
    /// Trims, drops blanks, de-duplicates keeping first position.
    ///
    /// ⛔ Does **not** split on commas. `arguments()` joins with a comma, so a
    /// pattern legitimately containing one — `Bash(git add, git commit)` — must
    /// survive whole; splitting here would silently halve it and the halves
    /// would each look like a plausible pattern.
    ///
    /// ⛔ Does **not** validate. Elliot does not own Claude Code's tool-pattern
    /// grammar, and a validator written against a guess would refuse a legal
    /// pattern — a refusal the reader cannot argue with, which is worse than
    /// passing through something the CLI will reject out loud.
    public static func normalise(_ raw: [String]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for entry in raw {
            let trimmed = entry.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, seen.insert(trimmed).inserted else { continue }
            out.append(trimmed)
        }
        return out
    }
}

// MARK: - One value an edit travels in

/// A change to one repository's run terms.
///
/// A closed pair rather than `setRunTerms(mode: PermissionMode? = nil, tools:
/// [String]? = nil)`, which is the obvious signature and has two representable
/// mistakes the type removes outright: passing neither (a call that writes
/// nothing and looks like a save) and passing both from a screen where only one
/// control moved. Neither can be written now.
///
/// ``applied(to:)`` is the only way it reaches a `Repo`, which is what makes
/// ``ExtraAllowedTools/normalise(_:)`` unskippable rather than merely
/// documented — the same reason `VerifiedOutcome.applied(to:attribution:)`
/// exists, one layer over.
public enum RunTermsEdit: Sendable, Hashable {
    case mode(PermissionMode)
    /// Raw as typed. Normalised on the way in, never by the caller.
    case tools([String])

    /// The repository with this edit applied.
    ///
    /// Exhaustive with no `default`, so a third term added to `Repo` — a
    /// per-repo model, a timeout — fails the build here rather than being
    /// editable everywhere except through the one funnel that saves it.
    public func applied(to repo: Repo) -> Repo {
        var repo = repo
        switch self {
        case .mode(let mode):
            repo.permissionMode = mode
        case .tools(let raw):
            repo.extraAllowedTools = ExtraAllowedTools.normalise(raw)
        }
        return repo
    }

    /// What `status` says after the save lands, naming the repository and the
    /// new value — never a bare "Saved", which is indistinguishable from a save
    /// that wrote the value already there.
    public func sentence(for repo: Repo) -> String {
        switch self {
        case .mode(let mode):
            return "\(repo.displayName) now runs under \(mode.title)."
        case .tools(let raw):
            let tools = ExtraAllowedTools.normalise(raw)
            guard !tools.isEmpty else { return "\(repo.displayName) allows no extra tools." }
            return "\(repo.displayName) also allows \(tools.joined(separator: ", "))."
        }
    }
}

// MARK: - What a row says when it is folded shut

/// The one-line summary under a repository's name in Preflight.
///
/// `nonisolated` and pure for the reason `PreflightView.forgetHelp` is: what a
/// screen *says* is assertable, where its row sits on screen still is not.
public enum RunTermsSummary {
    /// "Bypass permissions" · "Plan only · 2 extra tools".
    ///
    /// The tool count is a quantity, so it is spelled with the noun; the mode is
    /// an identity, so it is spelled with its title. A row on the defaults reads
    /// as the default rather than as blank — "nobody has changed this" and "this
    /// screen could not tell you" must not look the same.
    public static func line(_ repo: Repo) -> String {
        let count = repo.extraAllowedTools.count
        guard count > 0 else { return repo.permissionMode.title }
        let noun = count == 1 ? "1 extra tool" : "\(count) extra tools"
        return "\(repo.permissionMode.title) · \(noun)"
    }
}
