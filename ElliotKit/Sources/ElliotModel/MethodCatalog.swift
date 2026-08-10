import Foundation

/// The methods compiled into this build.
///
/// The **definition** lives outside every repository on purpose. `.elliot/settings.json`
/// (wave 3) will only ever *name* one of these. Elliot spawns `claude -p` at
/// `bypassPermissions` inside a real checkout, so "I pick my method" and "this
/// repository declares what Elliot runs" are not the same product.
public enum MethodCatalog {
    /// The default method's id, and **the only occurrence of this literal in the
    /// sources**: the pack below names itself with it, `resolve` falls back to it,
    /// and every test that means "the default" reads it from here. Two spellings
    /// in two files is how `resolve(nil)` would start answering
    /// `.unknown("ai-migration-kit")` for every repository registered before packs
    /// existed, caught only at test time.
    public static let defaultPackID = "ai-migration-kit"

    /// Order is the picker's, so it is the order a reader meets them in: today's
    /// method first, then the three measured on 2026-08-09.
    public static let builtIn: [MethodPack] = [aiMigrationKit, gsd, speckit, bmad]

    // MARK: - ai-migration-kit

    /// Today's method, and what a repository runs until it chooses another.
    ///
    /// Internal rather than public: outside this module a pack is reached through
    /// `resolve` or `builtIn`, which is the whole contract. `@testable` reaches it
    /// so `GoldenPromptTests` (Task 4) can name the pack whose prompts must stay
    /// identical.
    static let aiMigrationKit = MethodPack(
        id: defaultPackID,
        displayName: "ai-migration-kit",
        summary: "Files a GitHub issue, implements it on its own branch, and lands the pull "
            + "request. The method Elliot has always driven, and what a repository runs until "
            + "it chooses another.",
        // Measured: this method ships as a Claude Code plugin named
        // `ai-migration-kit` — exactly what `PreflightService` checks today.
        plugin: .required(defaultPackID),
        // None, and measured: everything this method produces is a GitHub object.
        // An empty list is a fact about the method, not a pack somebody left
        // half-written.
        projectRequirements: [],
        steps: [
            .createIssue: StepSpec(
                command: "/ai-migration-kit:create-issue",
                arguments: .ideaThenLabels,
                prose: "Use the create-issue skill to file a GitHub issue for this user story: {}"
            ),
            .implementIssue: StepSpec(
                command: "/ai-migration-kit:implement-issue",
                arguments: .number,
                prose: "Use the implement-issue skill on issue {}: execute its implementation "
                    + "plan and open a pull request."
            ),
            .mergePR: StepSpec(
                command: "/ai-migration-kit:merge-pr",
                arguments: .numberThenFollowUps,
                prose: "Use the merge-pr skill to land pull request {}."
            ),
        ]
        // `.analyzeRepo` is deliberately absent here and everywhere: there is no
        // `analyze-repo` skill in any plugin — that prompt is Elliot's own, built
        // by `AnalysisPromptBuilder`.
    )

    // MARK: - GSD

    /// Get Shit Done. Wave 1 wires exactly one transition — amendment A3,
    /// forced by measurement: `/gsd-plan-phase [N]` and `/gsd-ship [N]` both take
    /// a **phase** number resolved against `ROADMAP.md`, where Elliot holds an
    /// **issue** number at To Do and a **pull request** number at Done. Passing
    /// one as the other would plan or ship the wrong phase, so neither is wired
    /// — a step this pack does not carry is refused by
    /// `MoveBlock.methodHasNoStep`, inside `evaluateMove`, rather than run
    /// against the wrong object.
    static let gsd = MethodPack(
        id: "gsd",
        displayName: "GSD",
        summary: "Get Shit Done: a planning trail under .planning/, atomic commits, and a pull "
            + "request opened by /gsd-ship. Wave 1 wires only its capture step — Backlog to "
            + "To Do — so every other transition on this board runs nothing until wave 2's "
            + "generalised triggers exist.",
        // Measured: GSD's official `--claude` mode writes its slash commands
        // straight into the project. `--claude-plugin` is an unmerged proposal
        // (discussion #3432), and `jnuyens/gsd-plugin` is an unofficial fork —
        // there is no plugin for Preflight to check.
        plugin: .none,
        projectRequirements: gsdRequirements,
        steps: [
            // `/gsd-capture "<idea>"` — amendment A1/A3. Measured: its documented
            // flags are `--note`, `--backlog`, `--seed`, `--list`; it does
            // **not** accept `--label`, so `.idea` (free text, no flag tail) is
            // the form, not `.ideaThenLabels`.
            .createIssue: StepSpec(
                command: "/gsd-capture",
                arguments: .idea,
                prose: "Use GSD's capture command to turn this idea into a tracked todo: {}"
            )
            // `.implementIssue` absent: GSD's execution command is not named in
            // the sources this pack was built from, and a guessed command here
            // starts an unattended agent inside a real checkout.
            //
            // `.mergePR` absent: `/gsd-ship [N]` is what *creates* the pull
            // request and takes a phase number, not the pull-request number
            // Elliot holds at In Review → Done. Wave 2's generalised
            // `TriggerAction` is where this becomes expressible.
        ]
    )

    private static let gsdRequirements: [ProjectRequirement] = [
        ProjectRequirement(
            id: "gsd-project",
            title: "GSD project brief",
            evidence: .file(".planning/PROJECT.md"),
            remedy: "Run /gsd-new-project in this repository — it writes .planning/PROJECT.md.",
            seed: CardDraft(
                title: "Write the GSD project brief",
                role: "maintainer of this repository",
                want: ".planning/PROJECT.md written by /gsd-new-project",
                benefit: "every later GSD command starts from this project's own answer to "
                    + "what it is for",
                criteria: [
                    ".planning/PROJECT.md exists at the repository root.",
                    "It was produced by /gsd-new-project rather than written by hand.",
                    "Elliot's Preflight no longer reports the GSD project brief missing.",
                ]
            )
        ),
        ProjectRequirement(
            id: "gsd-requirements",
            title: "GSD requirements",
            evidence: .file(".planning/REQUIREMENTS.md"),
            remedy: "Run /gsd-new-project in this repository — it writes "
                + ".planning/REQUIREMENTS.md alongside the brief.",
            seed: CardDraft(
                title: "Write the GSD requirements",
                role: "maintainer of this repository",
                want: ".planning/REQUIREMENTS.md filled in for this project",
                benefit: "a phase can be planned against what this project must do, instead of "
                    + "against whoever is at the keyboard",
                criteria: [
                    ".planning/REQUIREMENTS.md exists and names real requirements, not a TODO.",
                    "Elliot's Preflight no longer reports the GSD requirements missing.",
                ]
            )
        ),
        ProjectRequirement(
            id: "gsd-roadmap",
            title: "GSD roadmap",
            evidence: .file(".planning/ROADMAP.md"),
            remedy: "Run /gsd-new-project in this repository — it writes .planning/ROADMAP.md, "
                + "which is what /gsd-plan-phase reads a phase from.",
            seed: CardDraft(
                title: "Write the GSD roadmap",
                role: "maintainer of this repository",
                want: ".planning/ROADMAP.md listing this project's phases",
                benefit: "/gsd-plan-phase has a phase to plan instead of inventing one",
                criteria: [
                    ".planning/ROADMAP.md exists and lists at least one phase.",
                    "Elliot's Preflight no longer reports the GSD roadmap missing.",
                ]
            )
        ),
    ]

    // MARK: - Spec Kit

    static let speckit = MethodPack(
        id: "speckit",
        displayName: "Spec Kit",
        summary: "GitHub's spec-driven method: a specification per feature under specs/, then "
            + "plan, tasks and implement. Wave 1 carries its specify step and the two artefacts "
            + "every /speckit.* command reads.",
        // Measured: `uv tool install specify-cli` then `specify init` writes
        // slash-command prompt files straight into the checkout. No marketplace,
        // no plugin — this `.none` is the contract's meaning, not an absence of
        // measurement, and the missing scaffolding is covered by a project
        // requirement below rather than by this field.
        plugin: .none,
        projectRequirements: speckitRequirements,
        steps: [
            // The one binding the measurement supports outright:
            // `/speckit.specify <description>` takes free text.
            .createIssue: StepSpec(
                command: "/speckit.specify",
                arguments: .ideaThenLabels,
                prose: "Use Spec Kit to write the specification for this work: {}"
            )
            // `.implementIssue` and `.mergePR` absent: Spec Kit's plan → tasks →
            // implement chain is several commands per transition, and
            // `/speckit.taskstoissues` fans one feature out to N issues, which
            // wave 1's cardinality cannot express and which the design names as
            // out of scope. Guessing one command for a three-command step would
            // run a third of a method and report a whole one.
        ]
    )

    private static let speckitRequirements: [ProjectRequirement] = [
        ProjectRequirement(
            id: "speckit-scaffold",
            title: "Spec Kit scaffolding",
            evidence: .anyFileUnder(".specify"),
            remedy: "Initialise Spec Kit in this checkout — every /speckit.* command reads "
                + ".specify/.",
            seed: CardDraft(
                title: "Initialise Spec Kit in this repository",
                role: "maintainer of this repository",
                want: "Spec Kit's .specify/ scaffolding committed to this repository",
                benefit: "the /speckit.* commands have the templates and constitution they read",
                criteria: [
                    ".specify/ exists and is committed, not left untracked.",
                    "A /speckit.* command runs in this checkout without asking to be set up.",
                ]
            )
        ),
        ProjectRequirement(
            id: "speckit-specs",
            title: "At least one specification",
            evidence: .anyFileUnder("specs"),
            remedy: "Run /speckit.specify for the first feature — it writes "
                + "specs/NNN-slug/spec.md.",
            seed: CardDraft(
                title: "Write the first Spec Kit specification",
                role: "maintainer of this repository",
                want: "one feature specified under specs/",
                benefit: "the method has a specification to plan and implement against",
                criteria: [
                    "specs/ holds at least one NNN-slug directory with a spec.md in it.",
                    "The specification describes a feature, not the tool that produced it.",
                ]
            )
        ),
    ]

    // MARK: - BMAD

    static let bmad = MethodPack(
        id: "bmad",
        displayName: "BMAD Method",
        summary: "A PRD and an architecture spine written up front, then epics and stories. It "
            + "produces no GitHub object at all, so wave 1 carries its project requirements and "
            + "no board steps — a BMAD card has nothing for Elliot to verify until wave 2.",
        // Measured, and genuinely the odd one out among the three non-default
        // packs: a plugin marketplace for BMAD does exist —
        // `bmad-code-org/bmad-plugins-marketplace`, "the official registry of
        // BMad modules", referenced as `bmad-plugins` — but it documents no
        // `/plugin install` line, and the official install path is
        // `npx bmad-method install`. So unlike GSD and Spec Kit, whose `.none`
        // is a measured fact about the method, nobody has established whether a
        // Claude Code plugin install exists for BMAD at all. `.unestablished`
        // says that in Preflight (Task 6: a `.warn`, never a silent skip and
        // never a `.fail` for something not shown to be missing).
        plugin: .unestablished(
            reason: "bmad-code-org/bmad-plugins-marketplace is documented as the official "
                + "registry of BMad modules, referenced as bmad-plugins, but it names no "
                + "/plugin install line — the official install path is npx bmad-method "
                + "install — so whether a Claude Code plugin install exists for BMAD has not "
                + "been established."
        ),
        projectRequirements: bmadRequirements,
        // Deliberately empty, and stated in `summary` above rather than left to be
        // discovered at the first drag. `Verifier` reads `gh`; a method that
        // creates no issue, no branch and no pull request gives it nothing to
        // confirm, so a step here would spawn an agent whose outcome Elliot could
        // not judge. `evaluateMove` refuses the move by name, so the board says
        // so before the drop rather than after it.
        steps: [:]
    )

    private static let bmadRequirements: [ProjectRequirement] = [
        ProjectRequirement(
            id: "bmad-prd",
            title: "Product requirements document",
            evidence: .file("docs/prd.md"),
            remedy: "Run BMAD's planning phase — it writes docs/prd.md.",
            seed: CardDraft(
                title: "Write the product requirements document",
                role: "maintainer of this repository",
                want: "docs/prd.md written through BMAD's planning phase",
                benefit: "epics and stories are cut from a stated product rather than from memory",
                criteria: [
                    "docs/prd.md exists and states goals, users and scope.",
                    "Elliot's Preflight no longer reports the PRD missing.",
                ]
            )
        ),
        ProjectRequirement(
            id: "bmad-architecture",
            title: "Architecture spine",
            evidence: .file("docs/ARCHITECTURE-SPINE.md"),
            remedy: "Run BMAD's architecture phase — it writes docs/ARCHITECTURE-SPINE.md.",
            seed: CardDraft(
                title: "Write the architecture spine",
                role: "maintainer of this repository",
                want: "docs/ARCHITECTURE-SPINE.md describing how this system is put together",
                benefit: "a story is implemented against a stated architecture instead of "
                    + "inventing one per story",
                criteria: [
                    "docs/ARCHITECTURE-SPINE.md exists and names the system's parts and their "
                        + "boundaries.",
                    "Elliot's Preflight no longer reports the architecture spine missing.",
                ]
            )
        ),
    ]
}
