import Foundation

/// A development method Elliot can drive: what it runs at each board transition,
/// and what it expects a repository to have written down once.
///
/// A pack is **data**. Adding a fifth method is a value in `MethodCatalog`, not a
/// release — and from wave 3, a file under `~/.elliot/methods/`.
///
/// What a pack may decide is bounded on purpose. It picks a command name and an
/// `ArgumentForm`; it never supplies a proof. A **wrong prompt** produces a bad
/// run whose outcome Elliot still verifies through `gh`; a **wrong proof**
/// produces a false success nothing catches. That single line is why both
/// `ArgumentForm` and `Evidence` are closed enums interpreted here, rather than
/// strings executed later — see the design's *Rejected: packs that declare their
/// own proof commands*.
public struct MethodPack: Identifiable, Codable, Sendable, Hashable {
    /// Stable, and the value `Repo.methodID` stores. Renaming one orphans every
    /// repository that chose it: `MethodCatalog.resolve` then answers
    /// `.unknown`, which refuses rather than silently running something else.
    public var id: String

    public var displayName: String

    /// One line, for the picker — and the place a pack states what it does
    /// **not** carry. BMAD ships project requirements and no steps in wave 1;
    /// a reader must read that where the method is chosen rather than discover
    /// it at the first drag.
    public var summary: String

    /// The Claude Code plugin Preflight checks is installed — or the measured
    /// absence of one. See `PluginRequirement` for what each case means and
    /// why a plain `String?` could not say it.
    public var plugin: PluginRequirement

    /// Written once per repository, verified by "this file exists", and repaired
    /// through a seeded card rather than a button — writing a PRD is a judgement
    /// that edits a committed file, which #170 routes through the board and a
    /// pull request.
    public var projectRequirements: [ProjectRequirement]

    /// Keyed by `SkillKind` rather than by transition. That is deliberately the
    /// thing wave 2 changes, and it will be a change of key type rather than a
    /// rewrite.
    ///
    /// A kind may be **absent**, and absent means *this method has no step
    /// there* — never "run the default". `MethodCatalogTests` writes every
    /// absence out by hand, so a step that disappears fails a test instead of a
    /// drag, and `BoardService.makeRun` (Task 7) refuses the move rather than
    /// borrowing another method's command.
    public var steps: [SkillKind: StepSpec]

    public init(
        id: String,
        displayName: String,
        summary: String,
        plugin: PluginRequirement,
        projectRequirements: [ProjectRequirement] = [],
        steps: [SkillKind: StepSpec] = [:]
    ) {
        self.id = id
        self.displayName = displayName
        self.summary = summary
        self.plugin = plugin
        self.projectRequirements = projectRequirements
        self.steps = steps
    }
}

/// Whether a method is distributed as a Claude Code plugin, and how sure we are.
///
/// A **measured** three-way split, not a two-valued guess. `String?` was the
/// plan's original contract, and it could not hold what measurement actually
/// found:
///
/// - ai-migration-kit ships as a plugin named `ai-migration-kit` — what
///   `PreflightService` checks today.
/// - GSD ships **no plugin**: its official `--claude` mode writes slash
///   commands into the project; `--claude-plugin` is an unmerged proposal.
/// - Spec Kit ships **no plugin**: `specify init` writes prompt files (or
///   skills) into the project, and there is no marketplace.
/// - BMAD ships **a plugin whose install name is documented nowhere
///   official** — `bmad-code-org/bmad-plugins-marketplace` is referenced as
///   `bmad-plugins`, but no `/plugin install` line is published, and the
///   official install path is `npx bmad-method install`.
///
/// `nil` would assert "not a plugin" for BMAD, which is false; a guessed name
/// would be worse. `.unestablished` says neither — Preflight (Task 6) reports it
/// as a warning carrying the reason, never a silent pass and never a failure for
/// something nobody has shown to be missing.
public enum PluginRequirement: Codable, Sendable, Hashable {
    /// Measured: this method is not distributed as a Claude Code plugin.
    case none
    /// Measured: it ships as a plugin under this name.
    case required(String)
    /// Nobody established whether it has one, and why. Preflight **says so**
    /// rather than skipping the check in silence.
    case unestablished(reason: String)
}

public extension MethodPack {
    /// What proves a project requirement is met: a **closed** vocabulary Elliot
    /// interprets, never a command a pack supplies.
    ///
    /// ⚠️ **Nested rather than top-level**, and not by taste: `ElliotModel.Evidence`
    /// is already a shipped type — `StoryProposal`'s file-and-line pointer, used in
    /// 5 sources and 7 test files and carried on the analysis wire. Two different
    /// ideas may not share one name at module scope. Inside `MethodPack`'s own
    /// extensions the bare name resolves here, which is why `projectGaps` below
    /// reads as the contract spells it; everywhere else it is `MethodPack.Evidence`.
    ///
    /// The GitHub cases (`.githubIssue`, `.githubPR`, `.merged`) arrive in wave 2
    /// **with their consumer**. Adding them now would be an enum case no code
    /// reads — exactly the dead code the wave boundary was corrected to avoid.
    ///
    /// The path is relative to the checkout root and never escapes it. That is
    /// enforced where the catalogue is validated (`MethodCatalogTests`) rather
    /// than at probe time: wave 1's packs are compiled in, so the runtime check
    /// belongs with wave 3's loader, which is the first thing that can be handed
    /// a path nobody reviewed. `ArtifactProbe` still refuses one — a second lock,
    /// not the gate.
    enum Evidence: Codable, Sendable, Hashable {
        /// A **file** at exactly this path: `.planning/PROJECT.md`.
        ///
        /// ⛔ A directory at that path does not satisfy it. `FileManager`'s
        /// `fileExists(atPath:)` answers `true` for a directory (measured), so
        /// the probe must ask `isDirectory` as well — otherwise `.file("specs")`
        /// reads as satisfied by an empty `specs/`, which is precisely the state
        /// `.anyFileUnder` exists to refuse.
        case file(String)
        /// At least one file anywhere beneath this directory: `specs/`.
        case anyFileUnder(String)
    }

    /// The requirements this repository has not met, in the pack's own order.
    ///
    /// Pure: the probe touches disk and returns booleans, this decides — the same
    /// split `nextCandidates` / `rankNextSteps` already practise, and the reason
    /// this is testable with no temporary directory.
    ///
    /// ⛔ **An `Evidence` absent from the map counts as unsatisfied**, never as
    /// satisfied. This is `ArtifactSweeper`'s "no protected set, no sweep" rule
    /// one layer over: a failure to find out is not a pass. `ArtifactProbe.evaluate`
    /// throws rather than returning a partial map for the same reason — an empty
    /// map must not read as "everything is missing" *there*, and a truncated one
    /// must not read as "everything is fine" *here*.
    func projectGaps(satisfied: [Evidence: Bool]) -> [ProjectRequirement] {
        projectRequirements.filter { satisfied[$0.evidence] != true }
    }

    /// The idempotency key one of this pack's requirements is seeded under.
    ///
    /// ⛔ **The repository is in the key, and the spec's `"method:<pack>:req:<req>"`
    /// was wrong.** `card_on_idempotencyKey` is `unique: true` on the key alone —
    /// `Migrations.swift:34-42` states the choice and its reason — and
    /// `BoardStore.card(idempotencyKey:)` filters on the key alone. Without the
    /// repository, the second repository to choose GSD finds the first one's card
    /// and is seeded nothing, while `PreflightService.apply` reports
    /// *"Added a card to Backlog."* — a success that did not happen, which is the
    /// one failure mode this project has an explicit rule against.
    ///
    /// The `UUID` rather than `nameWithOwner`, to match the shipped fix-id family
    /// (`"seedCard:\(repoID):\(title)"`, `CheckFix.id`) and because a rename does
    /// not move a row's id.
    ///
    /// One function, called by `PreflightService.projectChecks` and by every test
    /// that asserts the key — a format string repeated in prose is a key nothing
    /// can keep honest.
    func idempotencyKey(for requirement: ProjectRequirement, in repoID: UUID) -> String {
        "method:\(repoID):\(id):req:\(requirement.id)"
    }
}

/// What a step's argument looks like on the command line.
///
/// Closed rather than a template string, and that is the same decision as
/// `Evidence` being closed: a template reopens a syntax, an escaping and a
/// validation. `SlashCommandBuilder.sanitized()` already carries a paid-for trap
/// — backslashes first, then quotes, or `\"` becomes a live delimiter again —
/// which a pack-supplied template would bypass. **The pack picks the command
/// name and the form; every byte of escaping stays in existing code.**
public enum ArgumentForm: String, Codable, CaseIterable, Sendable, Hashable {
    /// The command alone: `/gsd-ship`.
    ///
    /// ⚠️ No built-in pack uses this in wave 1. It is in the canonical contract
    /// and is kept; `MethodPackTests.argumentFormIsClosed` records the asymmetry
    /// with `Evidence`'s deferred GitHub cases rather than papering over it.
    case none
    /// Free text and nothing else — no flag tail: `/gsd-capture "<idea>"`.
    ///
    /// Added after measurement, not part of the plan's original contract: GSD's
    /// idea-capture command documents `--note`, `--backlog`, `--seed` and
    /// `--list`, and **does not accept `--label`** — `.ideaThenLabels` would send
    /// it a flag it cannot parse. `.idea` is `.ideaThenLabels` minus the
    /// `--label` tail, and whatever renders it must reuse the same
    /// `collapsedToSingleLine()` flattening rather than a second one.
    case idea
    /// Free text, then one `--label "…"` per label — what `create-issue` and
    /// `/speckit.specify <description>` take.
    case ideaThenLabels
    /// One number and nothing else: no `#`, no title, no year. `implement-issue`
    /// resolves its argument with `grep -oE '[0-9]+' | head -1`, so the first
    /// digit run of the whole prompt *is* the number.
    case number
    /// A number, then one `--follow-up "…"` per idea: `merge-pr`.
    case numberThenFollowUps
}

/// One board transition's command, for one method.
public struct StepSpec: Codable, Sendable, Hashable {
    /// What is typed, leading slash included: `/ai-migration-kit:merge-pr`,
    /// `/speckit.specify`, `/gsd-plan-phase`.
    public var command: String

    public var arguments: ArgumentForm

    /// The `.naturalLanguage` sentence, with `{}` standing exactly where the
    /// payload goes:
    /// `"Use the implement-issue skill on issue {}: execute its implementation
    /// plan and open a pull request."`
    ///
    /// A marker rather than a prefix, because the payload is **not always last**
    /// — two of today's three sentences carry it mid-sentence, and this field has
    /// to reproduce them byte for byte or wave 1 stops being a refactor for every
    /// existing repository (`GoldenPromptTests`, created by Task 4).
    ///
    /// ⚠️ **Exactly one `{}` for every form but `.none`, which carries none.**
    /// Pinned by `MethodCatalogTests.proseSlots`. The repeatable tails —
    /// `" Apply these labels to it: …"`, `" File these follow-ups after merging: …"`
    /// — belong to the **form**, not to the pack, and stay in `SlashCommandBuilder`
    /// where their escaping already lives.
    public var prose: String

    public init(command: String, arguments: ArgumentForm, prose: String) {
        self.command = command
        self.arguments = arguments
        self.prose = prose
    }
}

/// Something a method expects a repository to have written down once.
///
/// Not a column and not a card lifecycle: a constitution, a PRD, a roadmap is
/// done once and verified by "this file exists in this repository", which is the
/// shape of a `CheckResult`. Preflight notices the gap, seeds a card, the card
/// crosses the board, a pull request lands it.
public struct ProjectRequirement: Codable, Sendable, Hashable {
    /// Stable, and half of the seeded card's idempotency key — see
    /// ``MethodPack/idempotencyKey(for:in:)``, which is the only thing that
    /// builds it. Renaming one seeds a second card for work already on the board.
    public var id: String

    public var title: String
    public var evidence: MethodPack.Evidence

    /// One sentence a reader can act on without leaving the row.
    public var remedy: String

    /// The card seeded when the artefact is absent.
    ///
    /// It must be complete: a seed that fails `CardDraft.isValid` would be
    /// seeded and then refused at its first drag by `evaluateMove`'s
    /// `incompleteStory` guard. `MethodCatalogTests.seedsAreSaveable` holds it.
    public var seed: CardDraft

    public init(
        id: String,
        title: String,
        evidence: MethodPack.Evidence,
        remedy: String,
        seed: CardDraft
    ) {
        self.id = id
        self.title = title
        self.evidence = evidence
        self.remedy = remedy
        self.seed = seed
    }
}
