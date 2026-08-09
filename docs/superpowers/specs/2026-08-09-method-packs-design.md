# Method packs — Elliot beyond ai-migration-kit

*Design, 2026-08-09. Written in English to match the rest of the repository.*

## Why

Elliot's three board transitions call three skills by name:
`/ai-migration-kit:create-issue`, `implement-issue`, `merge-pr`. That is the only
methodology it can drive. Other development methods exist and people use them —
GSD, GitHub's Spec Kit, BMAD, plain Claude plan mode — and none of them can reach
a board today.

The goal is a product that lets a reader choose a method **per repository**, and
an architecture where adding a fifth method is data rather than a release.

This document specifies **wave 1** of three. It records the measurement that
shaped it, the two architectures rejected, and the boundary correction the design
work forced.

## What these methods actually produce

Measured 2026-08-09 from each project's own documentation, because the design
turns entirely on what each step leaves behind.

| Method | Steps | Artefacts on disk | GitHub objects |
|---|---|---|---|
| **ai-migration-kit** *(today)* | 3 | none of its own | **issue → branch → PR → merge** (all of it) |
| **Spec Kit** | 7 + 4 optional | `specs/NNN-slug/{spec,plan,research,data-model,quickstart,tasks}.md`, `contracts/`, `.specify/` | **branch auto-created** per feature (`003-chat-system`); **issues** via `/speckit.taskstoissues`. PR undocumented |
| **BMAD** | 4 phases, ~15 agents | `prd.md`, `SPEC.md`, `DESIGN.md`, `EXPERIENCE.md`, `ARCHITECTURE-SPINE.md`, epics/stories, `sprint-status.yaml` | **none** |
| **GSD** | 11 commands | `.planning/{PROJECT,REQUIREMENTS,ROADMAP,STATE}.md`, `.planning/phases/NN-name/NN-YY-{PLAN,SUMMARY}.md`, CONTEXT/RESEARCH/VERIFICATION | atomic **commits**, **PR** via `/gsd-ship`. No issues, and **no branch created** — it works on the current branch |
| **claude plan** | 1 | nothing persisted | none |

Sources: [spec-kit](https://github.com/github/spec-kit),
[spec-driven.md](https://raw.githubusercontent.com/github/spec-kit/main/spec-driven.md),
[BMAD workflow map](https://docs.bmad-method.org/reference/workflow-map/),
[GSD user guide](https://github.com/gsd-build/get-shit-done/blob/main/docs/USER-GUIDE.md).

### What real usage adds

- **Scott Logic, two real increments** ([writeup](https://blog.scottlogic.com/2025/11/26/putting-spec-kit-through-its-paces-radical-idea-or-reinvented-waterfall.html)):
  increment 1 produced **2 577 lines of markdown for ~700 lines of code**;
  increment 2, 2 262 lines for ~300. And: *"rather than iterating on specs, the
  author created new specifications for each feature increment."*
- **Spec Kit's most-reported friction is that you cannot iterate on a spec**
  ([issue #1191](https://github.com/github/spec-kit/issues/1191), aggregating
  #1130, #620, #1118, #1173, #1066). Workarounds are *"unclear, error-prone, and
  not universally documented."* Hitting an obvious bug, Scott Logic asked *"how
  to express this bug from a specification perspective?"* — the method has no
  answer.
- **GSD ships an escape hatch from its own ceremony**: `/gsd:quick` exists
  explicitly *"for ad-hoc tasks… without the full research and planning
  overhead."*

## Three findings that decided the design

**1. All four methods converge on the same unit of work, and it is already
Elliot's card: whatever gets its own branch.** Spec Kit creates
`003-chat-system` plus `specs/003-chat-system/`. GSD's `.planning/phases/NN-name/`
ends in one `/gsd-ship`, one PR. BMAD: one story, one dev cycle.
ai-migration-kit: one issue, one branch, one PR. `Card.branch` exists;
`PRMatcher` already anchors on it. **Cardinality is not to be invented — it is to
be left alone.**

**2. Project-level steps are not columns; they are Preflight checks, and the
mechanism already exists.** Constitution, PRD, architecture, roadmap: done once,
verified by "this file exists in this repository", which is the shape of a
`CheckResult`. Because writing a PRD *is* a judgement that edits a committed
file, the repository's own rule (#170) routes it through **`seedCard`**, not a
button. Preflight notices the gap → seeds a card → the card crosses the board →
a pull request. Nothing new to design.

**3. The common denominator is not GitHub — it is a file at a predictable path.**
Three of five touch git; two touch issues; all five write files. "This file
exists" is a fact Elliot establishes itself, at the same rank as `gh --json`, and
`GitClient` is already in `ElliotProcess`. The invariant does not weaken; it
gains a second source of the same rank.

  ⚠️ **With one trap inside that finding**: GSD documents `commit_docs: false` —
  *"planning artifacts stay local and never touch git."* So "the file exists" and
  "the file is committed" are two different facts, and the second is not always
  available. The universal one is the first, outside git.

**Product corollary.** Spec Kit's top complaint is that a spec cannot be revisited.
A Kanban is inherently iterative — a card moves back, replays, re-verifies. Elliot
would not merely host these methods; it would repair their most-reported defect.

## Architecture

### Chosen: declarative packs with a **closed** evidence vocabulary

A `MethodPack` declares its steps and its project requirements — and, from wave 2,
its columns. **Evidence is a closed enum interpreted by Elliot** — never a command
supplied by the pack.

The pack **definition** lives outside the repository (compiled in for wave 1,
`~/.elliot/methods/` in wave 3). `.elliot/settings.json` **inside** the repository
only ever *names* one. A cloned repository therefore chooses from a catalogue the
reader controls; it cannot declare what Elliot executes. Elliot spawns `claude -p`
at `bypassPermissions` inside a real checkout, so that distinction is the
difference between "I pick my method" and "this repository made me run its
prompt".

### Rejected: packs that declare their own proof commands

`evidence: {cmd: "gh pr view --json state", expect: "MERGED"}` has no ceiling, and
that is its problem. **It makes the invariant configurable**: a pack may declare
that the agent's own output is the proof, and nothing would report it. "`gh` is
the fact" becomes "whatever the pack calls a fact is a fact". It also builds a
mini-language with its own escaping and validation, and opens arbitrary command
execution from a config file.

### Rejected: prompts only

Keep `SkillKind`'s three cases and let a pack supply slash names and templates.
Ships in days — and **hosts none of the three methods measured**. GSD has eight
steps per phase; BMAD has no issue at all. It is cosmetic decoupling that must be
redone, and redoing it costs more once repositories carry a settings file in that
shape.

### The line between what data may decide

A **wrong prompt** produces a bad run whose outcome Elliot still verifies. A
**wrong proof** produces a false success nothing catches. Supplied data is
therefore admissible on the prompt side and not on the evidence side. This is the
principle behind both `ArgumentForm` and `Evidence` being closed.

## Waves

The boundary below is a **correction** of the first decomposition, which read
"wave 1 = the proof, without touching the board". Designed out, that wave has no
consumer: `VerifiedOutcome` is a closed enum whose cases each write a specific
card field, so an `.artefactPresent` case would write nothing and imply no move —
dead code shipped as a wave. The real consumer is the Preflight project
requirement, and for Preflight to know whether to look for `.planning/PROJECT.md`
or `docs/prd.md`, the repository must already have chosen a method. `MethodPack`
therefore cannot wait for wave 2.

| | Wave 1 | Wave 2 | Wave 3 |
|---|---|---|---|
| `MethodPack` type + built-in catalogue | ✅ | | |
| Per-repository choice (`Repo.methodID`) | ✅ | | |
| `Evidence` + file-backed proof | ✅ | | |
| Project requirements → Preflight → `seedCard` | ✅ | | |
| Per-method slash names and argument forms | ✅ | | |
| Declared columns, `evaluateMove` over a table, migration | | ✅ | |
| Generalised `TriggerAction`, GitHub `Evidence` cases | | ✅ | |
| `.elliot/settings.json`, user-authored packs, editor UI | | | ✅ |

**Unchanged in wave 1**: `Column`, `TriggerAction`, `PRMatcher`, cardinality,
`PanelLayout`. The board keeps five columns and three transitions. What changes is
*which commands they run*, plus a screen that reports what the repository lacks.

## Types

All in `ElliotModel` except the probe.

```swift
public struct MethodPack: Identifiable, Codable, Sendable, Hashable {
    public var id: String                    // "ai-migration-kit" · "gsd" · "speckit" · "bmad"
    public var displayName: String
    public var summary: String               // one line, for the picker
    public var pluginName: String?           // what Preflight checks is installed
    public var projectRequirements: [ProjectRequirement]
    public var steps: [SkillKind: StepSpec]
}
```

`pluginName` is `nil` when the method is not a Claude Code plugin at all — plain
plan mode is the case — and Preflight then **skips** the installed-plugin check
rather than failing it. A method that needs no plugin must not read as a method
whose plugin is missing.

`steps` is keyed by `SkillKind` rather than by transition. That is deliberately
the thing wave 2 changes, and it will be a change of key type rather than a
rewrite.

```swift
public struct StepSpec: Codable, Sendable, Hashable {
    public var command: String          // "/gsd-plan-phase"
    public var arguments: ArgumentForm
    public var prose: String            // the .naturalLanguage fallback sentence
}

public enum ArgumentForm: String, Codable, CaseIterable, Sendable, Hashable {
    case none
    case ideaThenLabels      // "<idea>" --label "a" --label "b"
    case number              // "47" — the first digit run, nothing else
    case numberThenFollowUps // "47" --follow-up "a"
}
```

`ArgumentForm` is closed rather than a template string. A template would reopen
what approach B was rejected for: a syntax, an escaping, a validation. And
`SlashCommandBuilder.sanitized()` already carries a paid-for trap — *backslashes
first, then quotes, or `\"` becomes a live delimiter again* — which a
pack-supplied template would bypass. The pack picks the command name and the
form; every byte of escaping stays in existing code.

Checked against the four methods measured: `/speckit.specify <description>` →
`.ideaThenLabels`; `/gsd-plan-phase [N]` and `/gsd-ship [N]` → `.number`;
ai-migration-kit unchanged.

```swift
public struct ProjectRequirement: Codable, Sendable, Hashable {
    public var id: String            // "gsd-project" — stable; this is the idempotency key
    public var title: String
    public var evidence: Evidence    // .file(".planning/PROJECT.md")
    public var remedy: String        // "Run /gsd-new-project in this repository."
    public var seed: CardDraft       // the card seeded when the artefact is absent
}

public enum Evidence: Codable, Sendable, Hashable {
    case file(String)
    case anyFileUnder(String)
}
```

`Evidence` has two cases in wave 1. The GitHub cases (`.githubIssue`,
`.githubPR`, `.merged`) arrive in wave 2 **with their consumer** — adding them now
is exactly the dead code the wave correction above avoided.

Seeded cards carry `idempotencyKey = "method:\(pack.id):req:\(req.id)"`, so the
hourly sweep never seeds twice. The field already exists on `Card`.

```swift
public struct ArtifactProbe: Sendable {                       // ElliotProcess
    public init(repoRoot: String)
    public func evaluate(_ evidence: [Evidence]) throws -> [Evidence: Bool]
}

public extension MethodPack {                                  // ElliotModel, pure
    func projectGaps(satisfied: [Evidence: Bool]) -> [ProjectRequirement]
}
```

The probe touches disk and returns booleans; `projectGaps` decides without
reading anything — the same split `nextCandidates` / `rankNextSteps` already
practise. **An `Evidence` absent from the map counts as unsatisfied**, never as
satisfied: `ArtifactSweeper`'s "no protected set, no sweep" rule, applied here.

### The field on the repository, and the trap it triggers

```swift
public var methodID: String?
public var method: MethodResolution { MethodCatalog.resolve(methodID) }
```

The accessor returns the three-valued `MethodResolution` defined under *Error
handling*, never a bare `MethodPack` — mirroring `preflightVerdict`, which exists
so that "not measured" cannot be read as "measured and fine".

`methodID` is `Optional`, **not** a `String` with a default value. Swift's synthesised decoder
ignores a property's default and emits `decode(_:forKey:)`, so `methodID: String
= "…"` would throw `keyNotFound` on every database predating the column when read
through `BoardStore.openReadOnly` — breaking precisely the tolerance that keeps
the MCP helper answering between a new bundle landing and the app next launching.
The `Optional` form, with an accessor modelled on `preflightVerdict`, avoids the
subject entirely.

**Deleted in wave 1**: `SkillKind.slashName`'s three hardcoded lines, and the two
`"ai-migration-kit"` literals in `PreflightService` — 6 of the 7 Swift
occurrences.

## Flows

**Preflight sweep.** `PreflightService` resolves the repository's pack, asks
`ArtifactProbe` to evaluate its requirements' evidence, passes the map to the pure
`projectGaps`, and emits one `.warn` `CheckResult` per gap, each carrying a
`seedCard` `CheckFix`.

**Prompt construction.** `RunScheduler` already holds the `Repo` when it builds a
run. It resolves the pack and passes it to
`SlashCommandBuilder.prompt(for:method:strategy:)`. `SkillRun.argv` is already
persisted whole, so a run stays reproducible by hand with no addition.

**Choosing a method.** A row on the Repositories page writing `Repo.methodID`.
Wave 3 adds `.elliot/settings.json` as an override.

## Error handling

An earlier draft of the accessor read
`MethodCatalog.pack(id: methodID) ?? .aiMigrationKit`. **That is a silent
substitution** — a repository set to `"gsd"` whose pack disappeared would run
ai-migration-kit's commands with nothing reporting it. The resolution is
three-valued because the question is:

```swift
public enum MethodResolution: Sendable, Hashable {
    case unset(MethodPack)     // never chosen → ai-migration-kit, today's behaviour
    case chosen(MethodPack)
    case unknown(String)       // an id the catalogue does not know
}
```

This is `PreflightState.notChecked`'s lesson verbatim: *a two-valued answer to a
three-valued question is how the gap hid for as long as it did.*

| Situation | Verdict | Why |
|---|---|---|
| Project artefact missing | **`.warn`** | A repository without a PRD still works. Freezing it would be absurd. |
| `methodID` unknown | **`.fail`**, blocks moves (#249) | We do not know what to run. Running something else is worse than refusing. |
| Checkout unreadable | **one `.warn`** naming the cause | Not N false gaps. "I could not look" is not "there is nothing there". |

The last row is why `evaluate` throws rather than returning an empty map: an empty
map reads as "everything is missing", which is the exact lie the sweeper's rule
exists to prevent.

**Path escapes** are refused when the catalogue is validated, not at probe time.
Built-in packs are compiled in, so for wave 1 this is a test rather than a runtime
check; wave 3's loader needs the runtime one.

## Testing

The most important test is not a new behaviour but an **identity**:

> **`GoldenPromptTests`** — the ai-migration-kit pack produces prompts
> **byte-for-byte identical** to today's hardcoded builder, for all three actions,
> with and without labels, with and without follow-ups, including payloads
> containing quotes and backslashes.

While it passes, wave 1 is a refactor for every existing repository. If it reddens,
100 % of current users' behaviour changed while we thought we were opening the
product up.

Around it:

- **`SlashCommandBuilderTests`, generalised** — the existing invariant (*the first
  digit run of an `implement-issue` prompt is the issue number*, because the skill
  resolves with `grep -oE '[0-9]+' | head -1`) must hold for **every pack** using
  `.number`.
- **`MethodCatalogTests`** — for all four packs: unique ids, unique idempotency
  keys, relative paths, no `..`, every `SkillKind` present or explicitly absent.
- **`ArtifactProbeTests`** — real temporary directories, escape refusal, and the
  `/tmp` → `/private/tmp` canonicalisation that already cost a bug in #167.
- **`MethodPackTests`** — `projectGaps` pure, tested with no disk; an `Evidence`
  absent from the map counts as unsatisfied.
- **`PreflightMethodTests`** — unknown ⇒ `.fail`; missing artefact ⇒ `.warn`,
  **never** `.fail`. Named, because #249 made that distinction load-bearing.

**What `swift test` cannot see**: the method picker on the Repositories page is a
layout change. It needs the documented on-screen pass — `./Scripts/build-app.sh`,
launch against a short `ELLIOT_HOME`, then read the accessibility tree or
`board_screenshot`. That page has already cost this repository three merges
(#47, #50, #52, #53).

## Out of scope for wave 1

Named so the plan does not drift into them: dynamic columns; a generalised
`TriggerAction`; `.elliot/settings.json`; user-authored packs; a pack editor UI;
multi-issue units (Spec Kit's `/speckit.taskstoissues` fans one feature out to N
issues, which the current cardinality cannot express); and the two-level
project/unit board BMAD and GSD both imply.

## Open questions for wave 2

- Spec Kit creates its own branch inside `/speckit.specify`, before Elliot has a
  pull request to match. `PRMatcher` anchors on `^<issue>-`; a Spec Kit branch is
  `003-chat-system`. Whether that matches by accident, and what it should do, is
  unmeasured.
- BMAD produces no GitHub object at all, so a BMAD card has nothing for
  `Verifier` to confirm until wave 2's file-backed transition evidence exists. A
  BMAD pack shipped in wave 1 can only carry project requirements, not steps —
  which is honest, and should be stated in its `summary` rather than discovered.
