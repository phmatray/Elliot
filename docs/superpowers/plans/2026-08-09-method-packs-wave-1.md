# Method Packs (Wave 1) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let a reader choose a development method **per repository**, so that a board drag runs that method's commands and Preflight reports what that method expects the project to have written down — with ai-migration-kit's prompts unchanged byte for byte for every repository already registered.

**Architecture:** A `MethodPack` is data in `ElliotModel`: a command plus a **closed** `ArgumentForm` per `SkillKind`, and a list of `ProjectRequirement`s proved by a **closed** `MethodPack.Evidence` vocabulary Elliot interprets — never a command a pack supplies, because a wrong prompt produces a bad run Elliot still verifies while a wrong proof produces a false success nothing catches. `Repo.methodID` is an `Optional` column resolved three-valued through `MethodCatalog.resolve` (`unset` / `chosen` / `unknown`), so "never chosen" and "chose something this build has lost" stay different facts. `ArtifactProbe` (`ElliotProcess`) reads disk and decides nothing; `MethodPack.projectGaps` decides and reads nothing.

**Tech Stack:** Swift 6.3.1 / SwiftPM, swift-testing, GRDB (SQLite), SwiftUI (macOS 15), `gh` + `git` via `ElliotProcess`.

## Global Constraints

- **Swift 6.3.1 tools-version — the patch is load-bearing.** SwiftPM resolves a bare `6.3` as `6.3.0`; `swift build` is green from 6.2 but `swift build --build-tests` / `swift test` need 6.3.1, and `swift test` is this repo's only gate, so the manifest declares the higher floor to turn a mystery `#expect` type-check timeout into a named refusal.
- **`swiftLanguageModes: [.v6]`, deployment target macOS 15.** Strict concurrency: every new type crossing an isolation boundary must be `Sendable`.
- **Build/test:** `cd ElliotKit && swift build` · `swift test` · `swift test --filter <TypeName>`. ⚠️ `--filter` matches the **type** name, not the `@Suite` display name, and a filter matching nothing prints `warning: No matching test cases were run` and **exits 0** — never read that as a pass.
- **Tests use swift-testing (`@Suite` / `@Test` / `#expect`), not XCTest.** Every async wait bounded through `withTimeout` in `TestSupport`; no fixed sleeps; no assertion measures an absolute duration.
- **⛔ Never run `swift format` over the tree.** Hand-formatted, 4 spaces, 110 columns. Match the neighbouring lines by hand.
- **Migrations in `ElliotStore/Migrations.swift` are append-only and shipped ones are frozen; a migration's NAME is its identity in `grdb_migrations`.** When two unmerged branches claim the same number, the one that reached `main` first keeps it and the unshipped one moves.
- **A new persisted field must be `Optional` or `@DefaultsToEmpty`.** Swift's synthesised decoder ignores a property's default and emits `decode(_:forKey:)`, so a non-optional field throws `keyNotFound` in `BoardStore.openReadOnly` — the tolerance that keeps the MCP helper answering between a new bundle landing and the app next launching.
- **`MethodPack.Evidence` and `ArgumentForm` are CLOSED vocabularies, and a pack never supplies a command to prove anything.** A wrong prompt produces a bad run whose outcome Elliot still verifies through `gh`; a wrong proof produces a false success nothing catches.
- **A project-artefact gap is `.warn` and never `.fail`.** Since #249 a `.fail` blocks every drag in that repository; a repository without a PRD still works and freezing it would be absurd.
- **An unknown `methodID` is `.fail`, and it blocks moves.** We do not know what to run there, and running some other method's commands unannounced is worse than refusing.
- **A checkout the probe could not read is ONE `.warn` naming the cause**, never N false gaps — "I could not look" is not "there is nothing there".
- **Conventional Commits with the layer as scope:** `feat(model|store|process|engine|ipc|mcp|app): subject`. Multi-layer commits use the multi-scope form, e.g. `feat(model,store): …`.
- **Conflict hot-spots (union-merged):** `Package.swift`, `AppModel.swift`, `Migrations.swift`, `README.md`, test files. `Package.resolved` is regenerated, never hand-merged.
- **⚠️ A stale `.build` fails in ways that look like real breakage.** Adding an associated value to an enum case, or changing a stored-property set, has produced two unattributable signal 11s here with no checkout involved. If a reported failure could not possibly have happened, `rm -rf ElliotKit/.build` before believing it.
- **⚠️ Several agent worktrees share this repository's `.git`.** Re-read `git rev-parse --abbrev-ref HEAD` immediately before every commit and after every push.

### The four deviations from the canonical type contract, named once here

Every one of these is forced by the real tree, was measured, and is applied identically in every task below. Nothing else deviates.

1. **`Evidence` is nested as `MethodPack.Evidence`.** `ElliotModel` already declares `public struct Evidence` (`StoryProposal.swift:107`) — a proposal's file-and-line pointer, used in **5 sources and 7 test files**, and carried on the analysis wire. A second top-level `Evidence` is a redeclaration error, and renaming the shipped one is a twelve-file change to a wire type for no wave-1 gain. The case names are unchanged. Inside `MethodPack`'s own extensions the bare name resolves to the nested type, so `func projectGaps(satisfied: [Evidence: Bool])` is written **exactly as the contract spells it**; everywhere else it is spelled `MethodPack.Evidence`, including `ArtifactProbe.evaluate(_ evidence: [MethodPack.Evidence]) throws -> [MethodPack.Evidence: Bool]`.
2. **`CardDraft` gains `Codable`** (`CardDraft.swift:9`). `ProjectRequirement` is `Codable` and carries a `CardDraft`; the conformance is forced by the contract itself. All eight stored properties are `String`/`Bool`/`[String]`, so synthesis is free.
3. **The seeded-card idempotency key carries the repository.** The spec writes `"method:\(pack.id):req:\(req.id)"`. Measured against the schema, that is wrong: `card_on_idempotencyKey` is `unique: true` on `["idempotencyKey"]` **alone** (`Migrations.swift:34-42`, with a comment saying the choice is deliberate), `BoardStore.card(idempotencyKey:)` filters on the key alone, and `CreateCardTool` reports "already existed in \(repo)" — i.e. it hands back **another repository's card**. So the second repository to choose GSD would be seeded nothing, and `CheckFixOutcome` would report `succeeded: true`. The key is therefore `"method:\(repoID):\(pack.id):req:\(requirement.id)"`, matching the shipped `"seedCard:\(repoID):\(title)"` family, and it is produced by **one function** — `ProjectRequirement.idempotencyKey(in:)`, Task 1 — rather than by a format string repeated in prose.
4. **Three additions outside the contract**, each declared where it is introduced: `BoardError.unknownMethod(String)` and `BoardError.methodHasNoStep(method:kind:)` (Tasks 4 and 7 — the builder returns non-optional `String`, so the refusal cannot live in it), and `CheckFix.seedCard`'s new `key: String?` payload (Task 6 — `nil` preserves the historical id of cards already in the field).

⚠️ **The contract files `Repo.methodID` / `Repo.method` under `// ElliotStore`. `Repo` is actually `ElliotKit/Sources/ElliotModel/Repo.swift:7`**, persisted through `ElliotStore/Records.swift`. Task 3 edits the model file and the migration; nothing depends on which header the field was listed under.

### Dependency order

Types (1–2) → store (3) → prompt (4) → probe (5) → Preflight (6) → the repository's own pack reaching the prompt (7) → the picker (8) → the seeded card end-to-end (9). No task consumes anything a later task produces.

---

### Task 1: The method-pack model types

**Files:**
- Create: `ElliotKit/Sources/ElliotModel/MethodPack.swift`
- Modify: `ElliotKit/Sources/ElliotModel/CardDraft.swift:9` (add `Codable` to the declaration line)
- Test: `ElliotKit/Tests/ElliotModelTests/MethodPackTests.swift`

**Interfaces:**
- Consumes: `SkillKind` (`ElliotModel/SlashCommandBuilder.swift:14-53`, `Codable, CaseIterable, Sendable, Hashable`, cases `createIssue`/`implementIssue`/`mergePR`/`analyzeRepo`); `CardDraft.init(title:isStory:role:want:benefit:criteria:note:labels:)` (`CardDraft.swift:27-45`); `CardDraft.isValid` (`:169`), `CardDraft.story` (`:153`).
- Produces:
  - `public struct MethodPack: Identifiable, Codable, Sendable, Hashable` with `id/displayName/summary/pluginName/projectRequirements/steps` and a **public** memberwise `init(id:displayName:summary:pluginName:projectRequirements:steps:)`
  - `public enum MethodPack.Evidence: Codable, Sendable, Hashable { case file(String); case anyFileUnder(String) }` — deviation 1
  - `public enum ArgumentForm: String, Codable, CaseIterable, Sendable, Hashable`
  - `public struct StepSpec: Codable, Sendable, Hashable` + a **public** `init(command:arguments:prose:)`
  - `public struct ProjectRequirement: Codable, Sendable, Hashable` + a **public** `init(id:title:evidence:remedy:seed:)`
  - `public func ProjectRequirement.idempotencyKey(in repoID: UUID) -> String` — **not in the canonical contract**, and deviation 3's single implementation. A method, not a field: the shape of `Card` is untouched.
  - `public extension MethodPack { func projectGaps(satisfied: [Evidence: Bool]) -> [ProjectRequirement] }`
  - `CardDraft: Codable` — deviation 2
- ⚠️ **Both memberwise initialisers must be `public`.** `PreflightMethodTests` (Task 6) lives in `ElliotEngineTests`, which imports `ElliotModel` **non-`@testable`**, and constructs a `MethodPack` and a `StepSpec` by hand to state the `pluginName == nil` and "command is not `plugin:skill`" cases without depending on what the catalogue happens to ship.

- [ ] **Step 1: Write the failing test**

`ElliotKit/Tests/ElliotModelTests/MethodPackTests.swift`:

```swift
import Foundation
import Testing

@testable import ElliotModel

/// A pack that exists only in this suite. The catalogue's own four are pinned by
/// `MethodCatalogTests` (Task 2); what is under test here is the rule, not the data.
private func makePack(
    requirements: [ProjectRequirement],
    steps: [SkillKind: StepSpec] = [:]
) -> MethodPack {
    MethodPack(
        id: "fixture",
        displayName: "Fixture",
        summary: "A method that exists only in this suite.",
        pluginName: nil,
        projectRequirements: requirements,
        steps: steps
    )
}

private func makeRequirement(_ id: String, _ evidence: MethodPack.Evidence) -> ProjectRequirement {
    ProjectRequirement(
        id: id,
        title: "The artefact \(id)",
        evidence: evidence,
        remedy: "Write it.",
        seed: CardDraft(
            title: "Write \(id)",
            role: "maintainer of this repository",
            want: "the artefact \(id) written down",
            benefit: "the method has the file it reads",
            criteria: ["The file exists."]
        )
    )
}

@Suite("Method pack")
struct MethodPackTests {
    @Test("A requirement whose evidence never reached the map is a gap")
    func absentEvidenceIsAGap() {
        // `ArtifactSweeper`'s rule, one screen over: a lookup that did not answer
        // must not read as a pass. Reporting a gap that is not there costs a
        // warning row; missing one costs the requirement.
        let pack = makePack(requirements: [makeRequirement("a", .file("A.md"))])
        #expect(pack.projectGaps(satisfied: [:]).map(\.id) == ["a"])
    }

    @Test("A requirement whose evidence is satisfied is not a gap")
    func satisfiedIsNotAGap() {
        let pack = makePack(requirements: [makeRequirement("a", .file("A.md"))])
        #expect(pack.projectGaps(satisfied: [.file("A.md"): true]).isEmpty)
    }

    @Test("False and absent are the same answer")
    func falseIsAGapToo() {
        let pack = makePack(requirements: [makeRequirement("a", .file("A.md"))])
        #expect(pack.projectGaps(satisfied: [.file("A.md"): false]).map(\.id) == ["a"])
    }

    @Test("Gaps keep the pack's own order, so two sweeps report the same list")
    func orderIsThePacks() {
        let pack = makePack(
            requirements: [
                makeRequirement("one", .file("One.md")),
                makeRequirement("two", .file("Two.md")),
                makeRequirement("three", .anyFileUnder("specs")),
            ]
        )
        #expect(pack.projectGaps(satisfied: [.file("Two.md"): true]).map(\.id) == ["one", "three"])
    }

    @Test("A pack with no project requirements has no gaps, whatever the map says")
    func noRequirementsNoGaps() {
        // ai-migration-kit's measured shape: it writes no artefact of its own.
        let pack = makePack(requirements: [])
        #expect(pack.projectGaps(satisfied: [:]).isEmpty)
        #expect(pack.projectGaps(satisfied: [.file("A.md"): false]).isEmpty)
    }

    @Test("The two evidence kinds are different keys, even on the same path")
    func evidenceKindsAreDistinctKeys() {
        // A probe that answered `.file("specs")` for `.anyFileUnder("specs")`
        // would be answering a different question — "there is a directory" is
        // not "there is something in it".
        let pack = makePack(requirements: [makeRequirement("dir", .anyFileUnder("specs"))])
        #expect(pack.projectGaps(satisfied: [.file("specs"): true]).map(\.id) == ["dir"])
    }

    /// ⛔ The most expensive correction in this plan, pinned where the key is built.
    @Test("The seeded-card key carries the repository, the pack and the requirement")
    func idempotencyKeyCarriesTheRepository() {
        // `card_on_idempotencyKey` is unique board-wide, not per repository —
        // `Migrations.swift:34-42` says so deliberately, and
        // `BoardStore.card(idempotencyKey:)` filters on the key alone. A
        // repo-free key means the SECOND repository to choose GSD is seeded
        // nothing, while `CheckFixOutcome` reports "Added a card to Backlog."
        // Task 9 is where that is watched end to end; this pins the string.
        let requirement = makeRequirement("gsd-project", .file(".planning/PROJECT.md"))
        let pack = makePack(requirements: [requirement])
        let a = UUID(), b = UUID()
        #expect(
            pack.idempotencyKey(for: requirement, in: a)
                == "method:\(a):fixture:req:gsd-project"
        )
        #expect(
            pack.idempotencyKey(for: requirement, in: a)
                != pack.idempotencyKey(for: requirement, in: b)
        )
    }

    @Test("A pack survives a Codable round trip, seeded cards and all")
    func codableRoundTrip() throws {
        // Wave 3 loads packs from `~/.elliot/methods/`. The conformance is
        // declared now so the shape cannot drift into something unserialisable
        // — and because `ProjectRequirement` carrying a `CardDraft` is what
        // forced `CardDraft: Codable` in the first place.
        let original = makePack(
            requirements: [
                makeRequirement("a", .file("A.md")),
                makeRequirement("b", .anyFileUnder("specs")),
            ],
            steps: [
                .createIssue: StepSpec(
                    command: "/x:create", arguments: .ideaThenLabels, prose: "File this: {}"
                ),
                .mergePR: StepSpec(
                    command: "/x:merge", arguments: .numberThenFollowUps, prose: "Land {}."
                ),
            ]
        )
        let data = try JSONEncoder().encode(original)
        #expect(try JSONDecoder().decode(MethodPack.self, from: data) == original)
    }

    /// ⚠️ Measured, not assumed, and recorded so wave 3 meets it deliberately.
    @Test("steps encodes as an alternating array, which is not hand-writable JSON")
    func stepsEncodeAsAnAlternatingArray() throws {
        // A `String`-raw-value enum is **not** auto-conformed to
        // `CodingKeyRepresentable`, so `[SkillKind: StepSpec]` encodes as an
        // unkeyed array — `{"steps":["createIssue",{…}]}` — rather than an
        // object. Equality round-trips, so `codableRoundTrip` above cannot see
        // it. Nothing in wave 1 hand-writes a pack (the catalogue is compiled
        // in), so this is pinned rather than changed: wave 3's loader is where
        // conforming `SkillKind: CodingKeyRepresentable` belongs, and it must
        // be a deliberate act with its own migration of any file already
        // written in this shape.
        let pack = makePack(
            requirements: [],
            steps: [.createIssue: StepSpec(command: "/x:c", arguments: .none, prose: "go")]
        )
        let json = try #require(String(data: try JSONEncoder().encode(pack), encoding: .utf8))
        #expect(json.contains("[\"createIssue\","), "steps stopped encoding as an array: \(json)")
    }

    @Test("A step's argument form is a closed vocabulary, not a template")
    func argumentFormIsClosed() {
        // Pinned so a later task cannot quietly add a `.template(String)` case:
        // that is approach B, which was rejected for reopening a syntax, an
        // escaping and a validation that `SlashCommandBuilder.sanitized()`
        // already paid for.
        //
        // ⚠️ `.none` is carried by the canonical contract and by **no built-in
        // pack** in wave 1, so nothing exercises it end to end. That is an
        // asymmetry with `Evidence`'s GitHub cases, which this plan refuses to
        // add early for exactly that reason. It is kept because the contract
        // fixes this enum's shape, and because inventing a `.none` step for a
        // method nobody measured would be worse — see Task 2's judgement calls.
        #expect(ArgumentForm.allCases.count == 4)
        #expect(
            Set(ArgumentForm.allCases.map(\.rawValue))
                == ["none", "ideaThenLabels", "number", "numberThenFollowUps"]
        )
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd ElliotKit && swift test --filter MethodPackTests`

Expected: FAIL to compile — `error: cannot find type 'ProjectRequirement' in scope`, `error: cannot find type 'MethodPack' in scope`, `error: cannot find 'StepSpec' in scope`, `error: cannot find 'ArgumentForm' in scope`.

⚠️ A `--filter` that matches nothing prints `warning: No matching test cases were run` and **exits 0**. That is not what you want to see here: the failure must be those compile errors.

- [ ] **Step 3: Write the minimal implementation**

`ElliotKit/Sources/ElliotModel/MethodPack.swift`:

```swift
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

    /// The Claude Code plugin Preflight checks is installed, or `nil`.
    ///
    /// `nil` means *do not check*. Spec Kit installs slash commands into the
    /// checkout rather than a plugin, and plain plan mode has none at all: a
    /// method that needs no plugin must not read as a method whose plugin is
    /// missing.
    ///
    /// ⚠️ **It also, today, carries a second meaning this type cannot tell
    /// apart: "nobody established which plugin, if any."** GSD's and BMAD's
    /// `nil`s are that, not the first meaning. Two states in one optional is
    /// the shape `MethodResolution` exists to refuse one type over, and the
    /// honest fix is a three-valued field — which the canonical contract fixes
    /// as `String?` for wave 1. Until then the distinction lives in each pack's
    /// own comment and is pinned by `MethodCatalogTests.unmeasuredPluginsAreNamed`.
    public var pluginName: String?

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
        pluginName: String?,
        projectRequirements: [ProjectRequirement] = [],
        steps: [SkillKind: StepSpec] = [:]
    ) {
        self.id = id
        self.displayName = displayName
        self.summary = summary
        self.pluginName = pluginName
        self.projectRequirements = projectRequirements
        self.steps = steps
    }
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
```

And the one-word change at `ElliotKit/Sources/ElliotModel/CardDraft.swift:9`:

```swift
public struct CardDraft: Codable, Sendable, Hashable {
```

⚠️ The synthesised decoder bypasses `init`'s `criteria.isEmpty ? [""] : criteria` normalisation. Harmless in wave 1 — every value encoded came through that `init`, and nothing decodes a hand-written pack while the catalogue is compiled in. **Wave 3's loader must re-normalise**, and `stepsEncodeAsAnAlternatingArray` above is the other half of that note.

- [ ] **Step 4: Run the test to verify it passes**

Run: `cd ElliotKit && swift test --filter MethodPackTests`
Expected: PASS — 9 test functions.

Then sample the whole suite, because `CardDraft` gained a conformance and `ElliotAppKit` binds to it in several views, and because one green run cannot detect an intermittent regression — a defect failing 53 % of the time once reached `main` past 21 single-sample merges:

```bash
cd ElliotKit && swift test && swift test && swift test
```

- [ ] **Step 5: Commit**

```bash
git rev-parse --abbrev-ref HEAD          # several worktrees share this .git
git add ElliotKit/Sources/ElliotModel/MethodPack.swift \
        ElliotKit/Sources/ElliotModel/CardDraft.swift \
        ElliotKit/Tests/ElliotModelTests/MethodPackTests.swift
git commit -m "feat(model): a method pack declares its steps and what a project must carry"
```

---

### Task 2: The built-in catalogue — four packs, and a three-valued resolution

**Files:**
- Create: `ElliotKit/Sources/ElliotModel/MethodCatalog.swift`
- Create: `ElliotKit/Sources/ElliotModel/MethodResolution.swift`
- Test: `ElliotKit/Tests/ElliotModelTests/MethodCatalogTests.swift`
- Test: `ElliotKit/Tests/ElliotModelTests/MethodResolutionTests.swift`

**Interfaces:**
- Consumes (all from Task 1): `MethodPack.init(…)`, `MethodPack.Evidence.file(_:)` / `.anyFileUnder(_:)`, `MethodPack.idempotencyKey(for:in:)`, `StepSpec.init(command:arguments:prose:)`, `ArgumentForm`, `ProjectRequirement.init(…)`. Plus `CardDraft.init(title:isStory:role:want:benefit:criteria:note:labels:)`, `SkillKind`, and `String.trimmed()` (`UserStory.swift:83`, internal to `ElliotModel`).
- Produces:
  - `public enum MethodResolution: Sendable, Hashable { case unset(MethodPack); case chosen(MethodPack); case unknown(String) }`
  - `public enum MethodCatalog { public static let builtIn: [MethodPack]; public static func resolve(_ id: String?) -> MethodResolution }`
  - `public static let MethodCatalog.defaultPackID = "ai-migration-kit"` — **not in the canonical contract**, and the *single* occurrence of that literal in the sources. It is public because Task 6's `PreflightMethodTests` and Task 8's `RepositoriesMethodTests` both name the default pack from targets that import `ElliotModel` non-`@testable`.
  - **internal** `MethodCatalog.aiMigrationKit` / `.gsd` / `.speckit` / `.bmad` — reachable from `@testable import ElliotModel` (so `GoldenPromptTests`, **created by Task 4**, can name the default pack) and from nowhere else, keeping the public surface to the three members above.
  - `private extension MethodCatalog { static func pack(id: String) -> MethodPack? }` — file-scoped in `MethodResolution.swift`; a later task that needs it publicly promotes it and says why.
- Deliberately **not** produced: a `MethodResolution.pack` convenience accessor. Callers switch exhaustively, which is what makes `.unknown` impossible to skip past — the whole reason the resolution is three-valued.
- ⚠️ **For the tasks that consume this:** three of the four packs have **missing steps** (`gsd` and `speckit` carry one each, `bmad` none). The builder returns non-optional `String` and therefore stays total (Task 4 gives it a bare-skill-name fallback that borrows nothing). **The refusal lives one layer up, in `BoardService.makeRun`** — `BoardError.methodHasNoStep(method:kind:)`, added by Task 7 — because that is the thing that can decline to move a card. A card in a BMAD repository silently running `/ai-migration-kit:create-issue` is the substitution `MethodResolution` exists to prevent, one layer down.

**Three judgement calls in the pack data, recorded here so they are reviewed rather than inherited:**

1. **The spec's sentence `/gsd-plan-phase [N]` and `/gsd-ship [N]` → `.number` is a claim about the enum covering their documented argument shapes, not about which transition they bind to.** At Backlog → To Do Elliot holds free text and no number; at In Review → Done it holds a **pull request** number, and `/gsd-ship [N]` takes a *phase* number. Binding `.number` there would pass a right-looking wrong argument. So GSD carries `/gsd-plan-phase` under `.createIssue` with `.ideaThenLabels` (the only form that carries free text), and nothing else.
2. **An absent step is recorded, never guessed.** GSD's execution command and Spec Kit's plan/tasks/implement chain are not named in the sources this pack was built from, and a guessed command here starts an unattended `claude -p` at `bypassPermissions` inside a real checkout. #249's lesson cuts both ways: write down what is *not* carried.
3. **`pluginName: nil` means two different things across these four packs, and the type cannot tell them apart.** Spec Kit's `nil` is the contract's meaning (its commands install into the checkout; there is no plugin). GSD's and BMAD's are *unmeasured* — nobody established whether a plugin exists or under which id. Preflight will silently skip a check that may be required. That is the two-valued-answer-to-a-three-valued-question shape this plan otherwise refuses, kept only because the canonical contract fixes the field as `String?`; `unmeasuredPluginsAreNamed` pins the *record* of the distinction so it is visible rather than lost. **It is on the human-decision list at the end of this plan.**

- [ ] **Step 1: Write the failing tests**

`ElliotKit/Tests/ElliotModelTests/MethodCatalogTests.swift`:

```swift
import Foundation
import Testing

@testable import ElliotModel

/// The path a piece of evidence points at, whichever kind it is.
private func path(of evidence: MethodPack.Evidence) -> String {
    switch evidence {
    case .file(let p), .anyFileUnder(let p): p
    }
}

/// What each pack is declared to carry — written out by hand rather than derived
/// from the packs themselves, which would assert nothing. A step that disappears
/// fails here instead of at someone's first drag, and a new `SkillKind` forces
/// four deliberate answers rather than four silent absences.
private let declaredSteps: [String: Set<SkillKind>] = [
    // Today's method, unchanged: the three transitions Elliot has always driven.
    "ai-migration-kit": [.createIssue, .implementIssue, .mergePR],
    // Plans a phase. Its execution command is not named in the sources measured,
    // and `/gsd-ship` takes a phase number where Elliot holds a PR number.
    "gsd": [.createIssue],
    // `/speckit.specify <description>` only. The plan/tasks/implement chain is
    // several commands per transition, and `/speckit.taskstoissues` fans one
    // feature out to N issues — out of scope for wave 1's cardinality.
    "speckit": [.createIssue],
    // Produces no GitHub object at all, so there is nothing for `Verifier` to
    // confirm until wave 2's file-backed transition evidence exists.
    "bmad": [],
]

/// The packs whose `pluginName: nil` means *unmeasured* rather than *not a
/// plugin*. Written out because the type cannot tell the two apart — see Task 2's
/// judgement call 3.
private let unmeasuredPlugins: Set<String> = ["gsd", "bmad"]

@Suite("Built-in method catalogue")
struct MethodCatalogTests {
    @Test("The catalogue is the four packs, in the order the picker shows them")
    func theFourPacks() {
        #expect(MethodCatalog.builtIn.map(\.id) == ["ai-migration-kit", "gsd", "speckit", "bmad"])
        // The one literal, tied to the pack it names.
        #expect(MethodCatalog.defaultPackID == "ai-migration-kit")
        #expect(MethodCatalog.aiMigrationKit.id == MethodCatalog.defaultPackID)
    }

    @Test("Ids are unique — Repo.methodID stores one and must resolve to one pack")
    func idsAreUnique() {
        #expect(Set(MethodCatalog.builtIn.map(\.id)).count == MethodCatalog.builtIn.count)
        for pack in MethodCatalog.builtIn {
            #expect(!pack.id.isEmpty)
            #expect(!pack.displayName.isEmpty, "\(pack.id) has no display name")
            #expect(!pack.summary.isEmpty, "\(pack.id) has nothing to show in the picker")
        }
    }

    @Test("Every seeded card's idempotency key is unique across the whole catalogue")
    func idempotencyKeysAreUnique() {
        // ⛔ Built through the SAME function Preflight seeds with
        // (`MethodPack.idempotencyKey(for:in:)`), not through a format string
        // repeated here: an assertion about a shape no code produces cannot
        // fail, and the previous draft of this test had exactly that defect.
        let repoID = UUID()
        let keys = MethodCatalog.builtIn.flatMap { pack in
            pack.projectRequirements.map { pack.idempotencyKey(for: $0, in: repoID) }
        }
        #expect(!keys.isEmpty, "no pack declares a project requirement — the wave has no consumer")
        #expect(Set(keys).count == keys.count, "duplicate seeded-card keys among \(keys)")
        // And the repository is genuinely in them, which is what stops the second
        // repository to choose a method finding the first one's card.
        #expect(keys.allSatisfy { $0.contains(repoID.uuidString) })
    }

    @Test("Evidence paths are relative to the checkout and never escape it")
    func pathsStayInsideTheCheckout() {
        // Refused where the catalogue is validated, not at probe time: wave 1's
        // packs are compiled in. Wave 3's loader needs this as a runtime check.
        for pack in MethodCatalog.builtIn {
            for requirement in pack.projectRequirements {
                let p = path(of: requirement.evidence)
                let where_ = "\(pack.id)/\(requirement.id)"
                #expect(!p.isEmpty, "\(where_) points at nothing")
                #expect(!p.hasPrefix("/"), "\(where_) is absolute: \(p)")
                #expect(!p.hasPrefix("~"), "\(where_) is a home path: \(p)")
                #expect(
                    !p.split(separator: "/").contains(".."),
                    "\(where_) escapes the checkout: \(p)"
                )
            }
        }
    }

    @Test("Every SkillKind is either carried or explicitly absent, for every pack")
    func everyKindIsAnswered() {
        #expect(Set(declaredSteps.keys) == Set(MethodCatalog.builtIn.map(\.id)))
        for pack in MethodCatalog.builtIn {
            let declared = declaredSteps[pack.id] ?? []
            for kind in SkillKind.allCases {
                #expect(
                    (pack.steps[kind] != nil) == declared.contains(kind),
                    "\(pack.id) disagrees with the table about \(kind.skillName)"
                )
            }
        }
    }

    @Test("ai-migration-kit runs exactly the commands Elliot has always run")
    func aiMigrationKitCommands() {
        let pack = MethodCatalog.aiMigrationKit
        #expect(pack.steps[.createIssue]?.command == "/ai-migration-kit:create-issue")
        #expect(pack.steps[.implementIssue]?.command == "/ai-migration-kit:implement-issue")
        #expect(pack.steps[.mergePR]?.command == "/ai-migration-kit:merge-pr")
        #expect(pack.steps[.createIssue]?.arguments == .ideaThenLabels)
        #expect(pack.steps[.implementIssue]?.arguments == .number)
        #expect(pack.steps[.mergePR]?.arguments == .numberThenFollowUps)
        // Measured: this method writes no artefact of its own. Zero is a fact
        // about the method, not a pack somebody left half-written.
        #expect(pack.projectRequirements.isEmpty)
    }

    /// ⛔ The literals, pinned. `commandsAreWellFormed` below only checks shape,
    /// so without this a rename of `/speckit.specify` to `/speckit.plan` leaves
    /// every test green — while by this plan's own argument a wrong command
    /// starts an unattended `claude -p` at `bypassPermissions`.
    @Test("GSD's one declared command is the planning one")
    func gsdCommands() {
        let pack = MethodCatalog.gsd
        #expect(pack.steps[.createIssue]?.command == "/gsd-plan-phase")
        #expect(pack.steps[.createIssue]?.arguments == .ideaThenLabels)
    }

    @Test("Spec Kit's one declared command is specify")
    func speckitCommands() {
        let pack = MethodCatalog.speckit
        #expect(pack.steps[.createIssue]?.command == "/speckit.specify")
        #expect(pack.steps[.createIssue]?.arguments == .ideaThenLabels)
    }

    /// ⛔ A wrong path makes Preflight seed a card that can never be satisfied.
    @Test("The project-artefact paths are the ones these methods actually write")
    func requirementPathsArePinned() {
        func paths(_ pack: MethodPack) -> [String] {
            pack.projectRequirements.map { path(of: $0.evidence) }
        }
        #expect(
            paths(MethodCatalog.gsd)
                == [".planning/PROJECT.md", ".planning/REQUIREMENTS.md", ".planning/ROADMAP.md"]
        )
        #expect(paths(MethodCatalog.speckit) == [".specify", "specs"])
        #expect(paths(MethodCatalog.bmad) == ["docs/prd.md", "docs/ARCHITECTURE-SPINE.md"])
        // The kind matters as much as the path: `.specify` and `specs` are
        // directories that must contain something, not directories that exist.
        for requirement in MethodCatalog.speckit.projectRequirements {
            guard case .anyFileUnder = requirement.evidence else {
                Issue.record("\(requirement.id) is not .anyFileUnder")
                continue
            }
        }
    }

    @Test("ai-migration-kit's prose is today's fallback sentence, slot and all")
    func aiMigrationKitProse() {
        // The byte-for-byte identity of the built *prompts* is `GoldenPromptTests`'
        // job — created by Task 4, once the builder takes a pack. This pins the
        // ingredient: the same sentences, with `{}` where the interpolation was.
        let pack = MethodCatalog.aiMigrationKit
        #expect(
            pack.steps[.createIssue]?.prose
                == "Use the create-issue skill to file a GitHub issue for this user story: {}"
        )
        #expect(
            pack.steps[.implementIssue]?.prose
                == "Use the implement-issue skill on issue {}: execute its implementation "
                + "plan and open a pull request."
        )
        #expect(pack.steps[.mergePR]?.prose == "Use the merge-pr skill to land pull request {}.")
    }

    @Test("A step carrying a payload has exactly one slot; one carrying none has no slot")
    func proseSlots() {
        for pack in MethodCatalog.builtIn {
            for (kind, step) in pack.steps {
                let slots = step.prose.components(separatedBy: "{}").count - 1
                let expected = step.arguments == ArgumentForm.none ? 0 : 1
                #expect(
                    slots == expected,
                    "\(pack.id)/\(kind.skillName) has \(slots) slots for \(step.arguments)"
                )
            }
        }
    }

    @Test("Every command is one slash-prefixed word")
    func commandsAreWellFormed() {
        // Whitespace in a command would put the payload after an argument the
        // pack never declared — the escaping is the builder's, the shape is ours.
        for pack in MethodCatalog.builtIn {
            for (kind, step) in pack.steps {
                let where_ = "\(pack.id)/\(kind.skillName)"
                #expect(step.command.hasPrefix("/"), "\(where_): \(step.command)")
                #expect(step.command.count > 1, "\(where_) has an empty command")
                #expect(
                    !step.command.contains(where: \.isWhitespace),
                    "\(where_) has whitespace in \(step.command)"
                )
            }
        }
    }

    @Test("Every seeded card is complete enough to be saved and then dragged")
    func seedsAreSaveable() {
        // A seed failing `isValid` would be seeded by Preflight and refused by
        // `evaluateMove`'s incompleteStory guard at the first drag — a card the
        // board created and will not move.
        for pack in MethodCatalog.builtIn {
            for requirement in pack.projectRequirements {
                let where_ = "\(pack.id)/\(requirement.id)"
                #expect(!requirement.title.isEmpty, "\(where_) has no title")
                #expect(!requirement.remedy.isEmpty, "\(where_) offers no remedy")
                #expect(requirement.seed.isValid, "\(where_) seeds a card that cannot be saved")
                #expect(
                    requirement.seed.story?.isComplete == true,
                    "\(where_) seeds a half-written story"
                )
            }
        }
    }

    @Test("BMAD carries project requirements, no steps, and says so in its own summary")
    func bmadIsRequirementsOnly() {
        let bmad = MethodCatalog.bmad
        #expect(!bmad.projectRequirements.isEmpty)
        #expect(bmad.steps.isEmpty)
        #expect(
            bmad.summary.contains("no board steps"),
            "a method that cannot move a card must say so where it is chosen: \(bmad.summary)"
        )
    }

    @Test("Only a plugin that was actually established is named")
    func pluginNames() {
        // `nil` means Preflight skips the check. Naming a guessed plugin would
        // make Preflight fail about our guess rather than about this machine.
        #expect(
            MethodCatalog.builtIn.filter { $0.pluginName != nil }.map(\.id) == ["ai-migration-kit"]
        )
        #expect(MethodCatalog.aiMigrationKit.pluginName == MethodCatalog.defaultPackID)
    }

    /// ⚠️ `pluginName: nil` carries two meanings this type cannot separate, and
    /// this is the record of which packs mean which. Spec Kit genuinely has no
    /// plugin — its commands install into the checkout, and that is a *measured*
    /// nil. GSD's and BMAD's are *unmeasured*: nobody established whether a
    /// plugin exists. Preflight skips both identically, so this test is the only
    /// place the difference is written down until the field becomes three-valued.
    @Test("The packs whose plugin was never established are named as such")
    func unmeasuredPluginsAreNamed() {
        for pack in MethodCatalog.builtIn where unmeasuredPlugins.contains(pack.id) {
            #expect(pack.pluginName == nil, "\(pack.id) now names a plugin — update the table")
        }
        // Spec Kit is deliberately NOT in that set: its nil is a fact about the
        // method, not an absence of measurement.
        #expect(!unmeasuredPlugins.contains("speckit"))
        #expect(MethodCatalog.speckit.pluginName == nil)
    }
}
```

`ElliotKit/Tests/ElliotModelTests/MethodResolutionTests.swift`:

```swift
import Foundation
import Testing

@testable import ElliotModel

/// Three values, because the question has three answers.
///
/// An earlier draft of the accessor read `MethodCatalog.pack(id:) ?? .aiMigrationKit`.
/// That is a **silent substitution**: a repository set to `"gsd"` whose pack
/// disappeared would run ai-migration-kit's commands, at `bypassPermissions`,
/// inside a real checkout, with nothing reporting it. `PreflightState.notChecked`'s
/// lesson applied one type over — *a two-valued answer to a three-valued question
/// is how the gap hid for as long as it did* (#249).
@Suite("Resolving a method id")
struct MethodResolutionTests {
    @Test("A repository that never chose resolves to ai-migration-kit, and says it never chose")
    func unsetIsAiMigrationKit() {
        guard case .unset(let pack) = MethodCatalog.resolve(nil) else {
            Issue.record("nil resolved to \(MethodCatalog.resolve(nil)), not .unset")
            return
        }
        // Today's behaviour for every repository already registered: the packs
        // feature must be a refactor for them, not a change of method.
        #expect(pack.id == MethodCatalog.defaultPackID)
    }

    /// SQLite can hold `''` — a picker that cleared the field writes one — and
    /// `.unknown("")` would report *"the method  is not known"*, naming nothing.
    /// Blank is not a choice; it is the absence of one.
    @Test(
        "A blank id reads as never chosen, not as an unknown method named nothing",
        arguments: ["", "   ", "\n", "\t "]
    )
    func blankIsUnset(id: String) {
        guard case .unset = MethodCatalog.resolve(id) else {
            Issue.record("\(String(reflecting: id)) resolved to \(MethodCatalog.resolve(id))")
            return
        }
    }

    @Test("Every built-in pack resolves to itself, as a chosen one")
    func everyBuiltInResolvesToItself() {
        #expect(!MethodCatalog.builtIn.isEmpty, "an empty catalogue would make this test vacuous")
        for pack in MethodCatalog.builtIn {
            #expect(MethodCatalog.resolve(pack.id) == .chosen(pack))
        }
    }

    @Test("An id the catalogue does not know is named, never substituted")
    func unknownIsNamedRatherThanSubstituted() {
        #expect(MethodCatalog.resolve("gsd-2") == .unknown("gsd-2"))
        // A near-miss is a repository pointing at a pack we do not have, not a
        // typo to be forgiven: coercing it would run another method's commands.
        #expect(MethodCatalog.resolve("GSD") == .unknown("GSD"))
        // ⚠️ The id is reported **trimmed**, because that is the value `resolve`
        // looked up. Pinned so a reader knows which spelling reaches the screen.
        #expect(MethodCatalog.resolve("  gsd-2  ") == .unknown("gsd-2"))
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd ElliotKit && swift test --filter MethodCatalogTests`
Expected: FAIL to compile — `error: cannot find 'MethodCatalog' in scope`, repeated at every call site.

Run: `cd ElliotKit && swift test --filter MethodResolutionTests`
Expected: FAIL to compile — the same, plus `error: cannot infer contextual base in reference to member 'unset'`.

- [ ] **Step 3: Write the minimal implementation**

`ElliotKit/Sources/ElliotModel/MethodResolution.swift`:

```swift
import Foundation

/// What a repository's `methodID` resolves to — in three values, because the
/// question has three answers.
///
/// An earlier draft of `Repo.method` read `MethodCatalog.pack(id: methodID) ??
/// .aiMigrationKit`. That is a **silent substitution**: a repository set to
/// `"gsd"` whose pack disappeared would run ai-migration-kit's commands, at
/// `bypassPermissions`, inside a real checkout, with nothing reporting it.
///
/// `PreflightState.notChecked`'s lesson verbatim — *a two-valued answer to a
/// three-valued question is how the gap hid for as long as it did.* "Never
/// chosen" and "chose something I do not know" are different facts.
///
/// ⚠️ **This type carries no verdict of its own.** `.unknown` is *intended* to
/// become a Preflight `.fail` that blocks moves and a `BoardService` refusal;
/// **Task 6 and Task 7 are what implement that**, and until they land nothing
/// acts on this case. Saying otherwise here would be the shape `PreflightState`'s
/// own header warns about: three documents asserting a gate nobody had written.
///
/// There is deliberately no `pack` convenience accessor. Callers switch
/// exhaustively, which is what makes `.unknown` impossible to skip past.
public enum MethodResolution: Sendable, Hashable {
    /// Never chosen. Carries ai-migration-kit, which is what every board ran
    /// before packs existed — the fold is the *absence* of a choice being given
    /// a meaning, not an unknown choice being overruled.
    case unset(MethodPack)
    case chosen(MethodPack)
    /// An id the catalogue does not know, carried so whoever reports it can name
    /// it. Naming the id is the entire point: "unknown" alone is unactionable.
    case unknown(String)
}

public extension MethodCatalog {
    /// Reads a stored id as one of the three answers.
    ///
    /// A blank id resolves to `.unset` rather than `.unknown("")`: SQLite can
    /// hold `''` — a picker that cleared the field writes one — and
    /// *"the method  is not known"* names nothing. Blank is the absence of a
    /// choice, which is exactly what `.unset` means.
    ///
    /// The id is **trimmed before lookup and before being reported**, so
    /// `"  gsd-2  "` answers `.unknown("gsd-2")`. Pinned by
    /// `MethodResolutionTests.unknownIsNamedRatherThanSubstituted`.
    static func resolve(_ id: String?) -> MethodResolution {
        guard let named = id?.trimmed(), !named.isEmpty else {
            // Unreachable in a shipped build — the catalogue is compiled in and
            // `MethodCatalogTests` pins this pack's presence — but a force
            // unwrap in a function every drag calls is not worth the two lines
            // saved, and `.unknown` at least names what went missing.
            guard let fallback = pack(id: defaultPackID) else {
                return .unknown(defaultPackID)
            }
            return .unset(fallback)
        }
        guard let chosen = pack(id: named) else { return .unknown(named) }
        return .chosen(chosen)
    }
}

/// File-scoped: the lookup `resolve` uses. Not public — a task that needs it
/// promotes it and says why.
private extension MethodCatalog {
    static func pack(id: String) -> MethodPack? {
        builtIn.first { $0.id == id }
    }
}
```

`ElliotKit/Sources/ElliotModel/MethodCatalog.swift`:

```swift
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
        pluginName: defaultPackID,
        // None, and measured: everything this method produces is a GitHub object.
        // An empty list is a fact about the method, not an unfinished pack.
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

    static let gsd = MethodPack(
        id: "gsd",
        displayName: "GSD",
        summary: "Get Shit Done: a planning trail under .planning/, atomic commits, and a pull "
            + "request from /gsd-ship. It files no issue and creates no branch — it works on the "
            + "current one — and wave 1 carries only its planning step.",
        // ⚠️ **Unmeasured, not "no plugin".** The sources measured show both
        // `/gsd-plan-phase` and `/gsd:quick`, so whether these commands come from
        // a plugin — and under which id — was never settled. `nil` skips
        // Preflight's plugin check; a guessed id would produce a failure about
        // our guess rather than about this machine. The two meanings of `nil` are
        // recorded in `MethodCatalogTests.unmeasuredPluginsAreNamed`.
        pluginName: nil,
        projectRequirements: gsdRequirements,
        steps: [
            // ⚠️ `.ideaThenLabels`, not `.number`, and the reason is worth keeping.
            // GSD documents `/gsd-plan-phase [N]`, where N selects an *existing*
            // phase from ROADMAP.md. At Backlog → To Do Elliot holds free text and
            // no number at all, and `.ideaThenLabels` is the only form that carries
            // free text. A card naming no label emits `/gsd-plan-phase <idea>` and
            // nothing else; one naming labels emits a tail GSD does not parse —
            // the same "instruction to a reader, not a flag to a parser" status
            // `--label` already has in `create-issue`.
            .createIssue: StepSpec(
                command: "/gsd-plan-phase",
                arguments: .ideaThenLabels,
                prose: "Use GSD to plan a phase for this work: {}"
            )
            // `.implementIssue` absent: GSD's execution command is not named in the
            // sources this pack was built from, and a guessed command here starts an
            // unattended agent inside a real checkout.
            //
            // `.mergePR` absent: `/gsd-ship` is what *creates* the pull request, so
            // in Elliot's flow it belongs before In Review, not at In Review → Done;
            // and its `[N]` is a phase number where Elliot holds a PR number.
            // Binding it with `.none` would drop the follow-ups the merge sheet
            // collects, silently. Wave 2's generalised `TriggerAction` is where
            // this becomes expressible.
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
        // Spec Kit installs its commands *into the checkout* (`.specify/` and the
        // `speckit.*` slash commands), so there is no plugin to check. This is a
        // **measured** nil — the contract's meaning — not a stand-in for
        // "unknown", and the scaffolding is covered by a project requirement
        // below, which is the honest place to notice it is not installed here.
        pluginName: nil,
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
        // ⚠️ Unmeasured, like GSD's — see `unmeasuredPluginsAreNamed`.
        pluginName: nil,
        projectRequirements: bmadRequirements,
        // Deliberately empty, and stated in `summary` above rather than left to be
        // discovered at the first drag. `Verifier` reads `gh`; a method that
        // creates no issue, no branch and no pull request gives it nothing to
        // confirm, so a step here would spawn an agent whose outcome Elliot could
        // not judge. `BoardService.makeRun` (Task 7) refuses the move by name.
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
```

- [ ] **Step 4: Run the tests to verify they pass**

```bash
cd ElliotKit
swift test --filter MethodCatalogTests     # PASS — 16 test functions
swift test --filter MethodResolutionTests  # PASS — 4 test functions, 7 cases
swift test && swift test && swift test     # sample the whole suite
```

⚠️ If any of those reports a failure that could not have happened — a literal reporting as a different enum case, a link error naming a symbol you just wrote — that is a stale `.build`, not a defect: `rm -rf ElliotKit/.build` and re-run before believing it. This task adds new types next to an enum whose shape Task 1 just changed, which is exactly the pattern that has produced two unattributable signal 11s here.

- [ ] **Step 5: Commit**

```bash
git rev-parse --abbrev-ref HEAD
git add ElliotKit/Sources/ElliotModel/MethodCatalog.swift \
        ElliotKit/Sources/ElliotModel/MethodResolution.swift \
        ElliotKit/Tests/ElliotModelTests/MethodCatalogTests.swift \
        ElliotKit/Tests/ElliotModelTests/MethodResolutionTests.swift
git commit -m "feat(model): four built-in method packs, resolved three-valued"
```

---

### Task 3: `Repo.methodID` and the additive `v11` column

**Files:**
- Modify: `ElliotKit/Sources/ElliotModel/Repo.swift` — insert two members after `preflightVerdict` (which ends at `:61`), then **replace** the existing initialiser at `:63-85` with the one below. ⚠️ The block is the two properties *plus a whole initialiser*: inserting it without deleting the old init produces a duplicate `init` and an unbalanced brace.
- Modify: `ElliotKit/Sources/ElliotStore/Migrations.swift` — append `v11_repoMethodID` between the `v10_repoPreflight` closure (ends `:228`) and `return migrator` (`:230`)
- Modify: `ElliotKit/Sources/ElliotStore/Records.swift:16` (document why the mapping needs no code)
- Test: `ElliotKit/Tests/ElliotModelTests/RepoMethodTests.swift`
- Test: `ElliotKit/Tests/ElliotStoreTests/RepoMethodMigrationTests.swift`

**Interfaces:**
- Consumes, from Task 2: `MethodResolution`, `MethodCatalog.resolve(_:)`, `MethodCatalog.defaultPackID`.
- Produces:
  - `public var Repo.methodID: String?` (Optional, **never** a `String` with a default)
  - `public var Repo.method: MethodResolution { MethodCatalog.resolve(methodID) }`
  - a new `methodID: String? = nil` parameter on `Repo.init`
  - GRDB migration `"v11_repoMethodID"`, adding a nullable `TEXT` column `repo.methodID` **with no `DEFAULT`**
- ⚠️ `MethodResolution` and `MethodCatalog.resolve` are **Task 2's**, not this task's. An earlier draft produced them here as well; two tasks producing one type is a merge conflict waiting in `ElliotModel`.

- [ ] **Step 1: Write the failing tests**

`ElliotKit/Tests/ElliotModelTests/RepoMethodTests.swift`:

```swift
import Foundation
import Testing

@testable import ElliotModel

/// The accessor is one fold, in one place, mirroring `preflightVerdict`.
@Suite("A repository's method field")
struct RepoMethodTests {
    private func repository() -> Repo {
        Repo(
            path: "/tmp/repo-\(UUID().uuidString)",
            nameWithOwner: "phmatray/Elliot",
            displayName: "Elliot"
        )
    }

    @Test("A new registration has chosen nothing, and that resolves to the default")
    func aNewRegistrationHasChosenNothing() {
        let repo = repository()
        #expect(repo.methodID == nil, "a new registration has chosen nothing")
        // ⚠️ Asserted as a **value**, not as `== MethodCatalog.resolve(nil)`.
        // That comparison is tautological: it holds for any `resolve`, including
        // one that always answered `.unknown("")`, so it can only fail if the
        // accessor passes a *different argument* — which is not what is at stake.
        guard case .unset(let pack) = repo.method else {
            Issue.record("a repository that never chose resolved to \(repo.method)")
            return
        }
        #expect(pack.id == MethodCatalog.defaultPackID)
    }

    @Test("An id the catalogue does not know is named, not substituted")
    func unknownIsNamed() {
        var repo = repository()
        repo.methodID = "not-a-method"
        #expect(repo.method == .unknown("not-a-method"))
    }

    @Test("A chosen id resolves to that pack")
    func chosenResolves() throws {
        let other = try #require(
            MethodCatalog.builtIn.first { $0.id != MethodCatalog.defaultPackID },
            "this test needs a second built-in pack; the catalogue ships four")
        var repo = repository()
        repo.methodID = other.id
        #expect(repo.method == .chosen(other))
    }
}
```

`ElliotKit/Tests/ElliotStoreTests/RepoMethodMigrationTests.swift`:

```swift
import ElliotModel
import Foundation
import GRDB
import Testing

@testable import ElliotStore

/// Apart from `BoardStoreTests` for the reason `MigrationsTests` is: it drives
/// the migrator directly and so needs `import GRDB`, whose `Column` collides
/// with the board's five columns.
@Suite("A repository row written before the method column")
struct RepoMethodMigrationTests {

    /// Named once. When the next migration lands on top of this one, the tests
    /// below must keep asking about the schema *before* the method column rather
    /// than silently starting to test the newest thing instead.
    private static let migrationBeforeMethod = "v10_repoPreflight"

    /// A database migrated only as far as the release before this column, with
    /// one repository row seeded through raw SQL — the record type knows about a
    /// column these fixtures must not have.
    private func preV11Database() throws -> (url: URL, repoID: String, remove: () -> Void) {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("elliot-v10-\(UUID().uuidString).sqlite")
        let queue = try DatabaseQueue(path: url.path)
        try Migrations.migrator.migrate(queue, upTo: Self.migrationBeforeMethod)
        let repoID = UUID().uuidString.uppercased()
        try queue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO "repo"
                    ("id", "path", "nameWithOwner", "defaultBranch", "displayName",
                     "permissionMode", "extraAllowedTools", "isEnabled")
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    repoID, "/R/phmatray/private/Koine", "phmatray/Koine", "main", "Koine",
                    "bypassPermissions", "[]", true,
                ])
        }
        try queue.close()
        return (url, repoID, { try? FileManager.default.removeItem(at: url) })
    }

    /// The trap this field's whole shape exists to avoid, measured rather than
    /// trusted.
    ///
    /// `BoardStore.openReadOnly` never migrates: it accepts a database *older*
    /// than the build reading it, which is what keeps the MCP helper answering
    /// between a new bundle landing and the app next launching. Swift's
    /// synthesised decoder **ignores a property's default value** — it emits
    /// `decode(_:forKey:)`, not `decodeIfPresent` — so `methodID: String =
    /// "ai-migration-kit"` would compile, read correctly everywhere the app
    /// looks, and throw `keyNotFound` here, refusing **every** repository in
    /// exactly the window `openReadOnly` is there to serve. This is the class of
    /// regression `OlderDatabaseTests` exists to catch.
    @Test("A pre-v11 database still decodes its repositories through openReadOnly")
    func olderDatabaseStillDecodesRepositories() async throws {
        let fixture = try preV11Database()
        defer { fixture.remove() }

        // The fixture is genuinely pre-v11 rather than a current database that
        // happens to hold a NULL. Without this self-check the test would pass
        // against the newest schema and prove nothing at all.
        let check = try DatabaseQueue(path: fixture.url.path)
        let columns = try check.read { db in
            Set(try Row.fetchAll(db, sql: "PRAGMA table_info(repo)")
                .compactMap { $0["name"] as String? })
        }
        #expect(!columns.contains("methodID"), "the fixture is not actually a pre-v11 database")
        try check.close()

        let older = try BoardStore.openReadOnly(at: fixture.url)
        let loaded = try #require(
            try await older.repos().first,
            "openReadOnly answered no repository at all on a pre-v11 database")
        #expect(loaded.displayName == "Koine", "the pre-v11 row is still there, unchanged")
        #expect(loaded.methodID == nil, "the added column reads as absent, not as a decode failure")

        guard case .unset(let pack) = loaded.method else {
            Issue.record("a repository that never chose resolved to \(loaded.method)")
            return
        }
        #expect(pack.id == MethodCatalog.defaultPackID)
    }

    /// ⛔ The test the migration's own fifteen-line comment needs in order to be
    /// worth anything.
    @Test("Running v11 over an existing row leaves methodID NULL — there is no DEFAULT")
    func v11DoesNotBackfillExistingRows() throws {
        // Without this, `ADD COLUMN methodID TEXT DEFAULT 'ai-migration-kit'`
        // passes every other test in this plan: SQLite backfills every existing
        // row, every pre-packs repository silently becomes `.chosen` instead of
        // `.unset`, and the whole suite stays green. `olderDatabaseStillDecodes…`
        // cannot see it because it stops *before* v11 runs.
        let fixture = try preV11Database()
        defer { fixture.remove() }

        let queue = try DatabaseQueue(path: fixture.url.path)
        try Migrations.migrator.migrate(queue)   // the full set, v11 included
        let loaded = try queue.read { db in try Repo.fetchOne(db, key: fixture.repoID) }
        let repo = try #require(loaded)
        #expect(repo.methodID == nil, "v11 backfilled an existing row — it must carry no DEFAULT")
        guard case .unset = repo.method else {
            Issue.record("an existing row stopped reading as never-chosen: \(repo.method)")
            return
        }
        try queue.close()
    }

    /// The other half: the column is real, and the id survives the round trip
    /// with no `Repo.Columns` entry and no `CodingKeys` — which is the mapping
    /// this task deliberately does not write.
    @Test("A chosen method round-trips through the new column")
    func chosenMethodRoundTrips() async throws {
        let store = try BoardStore.inMemory()
        var repository = Repo(
            path: "/tmp/repo-\(UUID().uuidString)",
            nameWithOwner: "phmatray/Elliot",
            displayName: "Elliot"
        )
        repository.methodID = "gsd"
        try await store.saveRepo(repository)

        let loaded = try #require(try await store.repo(id: repository.id))
        #expect(loaded.methodID == "gsd", "the column carries the id verbatim")
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

```bash
cd ElliotKit
swift test --filter RepoMethodTests           # error: value of type 'Repo' has no member 'methodID'
swift test --filter RepoMethodMigrationTests  # the same, plus 'no member .method'
```

⚠️ Both filters name the **type**, not the `@Suite` display name; a filter that matches nothing prints `warning: No matching test cases were run` and **exits 0**, so read the output rather than the exit code. And if a failure here looks impossible — a member that plainly exists reported missing — `rm -rf ElliotKit/.build` before believing it.

- [ ] **Step 3: Write the minimal implementation**

**(a) `ElliotKit/Sources/ElliotModel/Repo.swift`** — insert these two members after `preflightVerdict` (line 61), and **replace** the existing initialiser (lines 63-85) with the one below:

```swift
    /// Which method pack this repository's transitions run.
    ///
    /// ⚠️ **Optional, for `preflight`'s reason plus one of its own.**
    /// `BoardStore.openReadOnly` deliberately accepts a database *older* than
    /// the helper (`applied.isSubset(of: known)`), and that tolerance is
    /// precisely "an added column reads as absent" — which only holds for an
    /// optional. On top of that, Swift's synthesised decoder **ignores a
    /// property's default value**: it emits `decode(_:forKey:)`, never
    /// `decodeIfPresent`, so `methodID: String = "ai-migration-kit"` would
    /// compile, read correctly everywhere the app looks, and throw
    /// `keyNotFound` on every database predating the column — refusing every
    /// repository in exactly the window `openReadOnly` exists to serve.
    /// `RepoMethodMigrationTests` is what says so.
    ///
    /// Read it through ``method``, never directly: `nil` is a state — *never
    /// chosen* — not a missing value, and it is emphatically not the same state
    /// as an id the catalogue does not know.
    public var methodID: String?

    /// The three-valued answer, modelled on ``preflightVerdict``.
    ///
    /// Not `?? aiMigrationKit`: folding an unknown id into a working pack would
    /// run another method's commands in this checkout, at `bypassPermissions`,
    /// with nothing reporting it. The fold this accessor *does* perform — NULL
    /// to `.unset` — is a resolution rather than a substitution, and it stays
    /// distinguishable because `.unknown` is a third value rather than the same
    /// one.
    ///
    /// ⚠️ Nothing in this task acts on `.unknown`. Turning it into a Preflight
    /// `.fail` is **Task 6**; refusing the move is **Task 7**. Saying otherwise
    /// here would be the shape `PreflightState`'s header warns about — three
    /// documents asserting a gate nobody had written.
    public var method: MethodResolution { MethodCatalog.resolve(methodID) }

    public init(
        id: UUID = UUID(),
        path: String,
        nameWithOwner: String,
        defaultBranch: String = "main",
        displayName: String,
        permissionMode: PermissionMode = .bypassPermissions,
        extraAllowedTools: [String] = [],
        isEnabled: Bool = true,
        visibility: RepoVisibility? = nil,
        preflight: PreflightState? = nil,
        methodID: String? = nil
    ) {
        self.id = id
        self.path = path
        self.nameWithOwner = nameWithOwner
        self.defaultBranch = defaultBranch
        self.displayName = displayName
        self.permissionMode = permissionMode
        self.extraAllowedTools = extraAllowedTools
        self.isEnabled = isEnabled
        self.visibility = visibility
        self.preflight = preflight
        self.methodID = methodID
    }
```

**(b) `ElliotKit/Sources/ElliotStore/Migrations.swift`** — append between the `v10_repoPreflight` closure and `return migrator`:

```swift
        // v11, additive: which method pack this repository's transitions run.
        //
        // **Nullable, with no default**, and both halves are deliberate.
        //
        // Nullable because `Repo.methodID` is an `Optional` and has to be. The
        // synthesised decoder emits `decode(_:forKey:)` and ignores a property's
        // default, so a non-optional field throws `keyNotFound` on every
        // database predating this column when read through `openReadOnly` — the
        // window that keeps the MCP helper answering between a new bundle
        // landing and the app next launching. A `NOT NULL` column under an
        // optional property is the mirror mistake, and would fail on the first
        // repository registered without a method.
        //
        // No `DEFAULT 'ai-migration-kit'` either, even though that *is* what a
        // row written before this column runs. A default spells one state two
        // ways — NULL, from `openReadOnly` on an older file, and the literal,
        // from this build — and "never chosen" then becomes a question nothing
        // can ask. `Repo.method` folds NULL into `.unset` once, and it can only
        // do that honestly because the fold has a third value beside it: an id
        // the catalogue has lost resolves to `.unknown`, never to the default.
        // `RepoMethodMigrationTests.v11DoesNotBackfillExistingRows` is what
        // makes this paragraph enforceable rather than aspirational.
        migrator.registerMigration("v11_repoMethodID") { db in
            try db.alter(table: "repo") { t in
                t.add(column: "methodID", .text)
            }
        }
```

**(c) `ElliotKit/Sources/ElliotStore/Records.swift:16`** — the mapping needs **no code**, and that is the fact worth writing down, since nothing here would fail to compile if it stopped being true:

```swift
/// `Repo` has no `Columns` enum and no `CodingKeys`: every column name is the
/// Swift property name verbatim, and the synthesised `Codable` is what reads and
/// writes the row. A stored property added to `Repo` therefore needs a column of
/// the **identical** name — `methodID`, added by `v11_repoMethodID` — and gets no
/// compiler error if the two ever part, only a failure at the first **write**: a
/// fetch reads the mismatch as `nil`, silently, which is the same tolerance
/// `openReadOnly` depends on, while `PersistableRecord` encodes the property and
/// `repo.save(db)` throws *"table repo has no column named methodID"*.
extension Repo: FetchableRecord, PersistableRecord {
```

- [ ] **Step 4: Run the tests to verify they pass**

```bash
cd ElliotKit
swift test --filter RepoMethodTests           # PASS — 3 tests
swift test --filter RepoMethodMigrationTests  # PASS — 3 tests
swift test                                    # whole suite
```

Expected on the full run: no failures, **+2 suites and +6 test functions** against the previous task's run, with `MigrationsTests` and `SchemaUpgradeTests` green — their pinned identifiers (`v8_prStatus`, the rewind list) are untouched by an appended migration, and no test asserts an exhaustive `repo` column set.

- [ ] **Step 5: Commit**

```bash
git rev-parse --abbrev-ref HEAD
git add ElliotKit/Sources/ElliotModel/Repo.swift \
        ElliotKit/Sources/ElliotStore/Migrations.swift \
        ElliotKit/Sources/ElliotStore/Records.swift \
        ElliotKit/Tests/ElliotModelTests/RepoMethodTests.swift \
        ElliotKit/Tests/ElliotStoreTests/RepoMethodMigrationTests.swift
git commit -m "feat(model,store): a repository names the method its transitions run"
git rev-parse --abbrev-ref HEAD
```

⚠️ `Migrations.swift` is a union-merged conflict hot-spot, and a migration's **name** is its identity in `grdb_migrations`. If another unmerged branch has also claimed `v11`, the branch that reaches `main` first keeps the number and **this one renumbers** — never the other way round.

---

### Task 4: SlashCommandBuilder takes a MethodPack

**Files:**
- Modify: `ElliotKit/Sources/ElliotModel/SlashCommandBuilder.swift:40-52` (delete `SkillKind.slashName`), `:75-203` (new signature, `ArgumentForm`-driven suffixes, `quoted` removed)
- Modify: `ElliotKit/Sources/ElliotEngine/BoardService.swift:20-38` (one new `BoardError` case), `:173-189` (`makeRun` hands the builder a pack — an **interim** resolution that Task 7 replaces)
- Modify: `ElliotKit/Tests/ElliotModelTests/SlashCommandBuilderTests.swift:22` (one helper stops being `private`), `:53-296` (call sites go through a wrapper; `slashNames()` deleted; the number invariant generalised)
- Modify: `ElliotKit/Tests/ElliotModelTests/AnalysisModelTests.swift:112-119` (`onlySkillsHaveSlashNames` rewritten against the pack)
- Modify: `ElliotKit/Tests/ElliotProcessTests/ClaudeRunnerTests.swift:562` (the one call outside `ElliotModelTests`)
- Test: `ElliotKit/Tests/ElliotModelTests/GoldenPromptTests.swift`

**Interfaces:**
- Consumes: `MethodPack`, `StepSpec(command:arguments:prose:)`, `ArgumentForm.{none,ideaThenLabels,number,numberThenFollowUps}`, `MethodCatalog.builtIn`, `MethodCatalog.resolve(_:) -> MethodResolution`, `MethodResolution.{unset,chosen,unknown}` — all from Tasks 1-2.
- Produces:
  - `SlashCommandBuilder.prompt(for action: TriggerAction, method: MethodPack, strategy: PromptStrategy = .slashCommand) -> String`
  - **Deleted**: `SkillKind.slashName` — no replacement; the command a kind runs is `MethodPack.steps[kind]?.command`. (This is the spec's *"Deleted in wave 1"* row, first half.)
  - `BoardError.unknownMethod(String)` — ⚠️ **not in the canonical type contract.** It is required *here* rather than in Task 7 because changing the builder's signature breaks `BoardService.swift:183`, so the package does not compile until that call site is patched, and the patched site must switch exhaustively over a `MethodResolution`. `.unknown` is unreachable from `resolve(nil)`; **Task 7 makes it reachable**. Refusing rather than substituting is the spec's *Error handling* row: `methodID` unknown ⇒ we do not know what to run.
  - **`GoldenPromptTests`** — the suite the spec names as *"the most important test"*. It does not exist before this task; every earlier reference to it in this plan is a forward reference to here.
  - Test helper `aiMigrationKitPack() -> MethodPack?` (internal to `ElliotModelTests`), and `countUnescapedQuotes(in:)` promoted from `private` to internal so `GoldenPromptTests` shares it instead of holding a second copy.
- ⚠️ **`firstDigitRun(of:)` and `nastyTitles` stay `private`.** Their only new consumer, `everyNumberFormPutsTheNumberFirst`, is added **inside `SlashCommandBuilderTests.swift`**, where file-private already suffices. Promoting them would be widening access for no reader.

⚠️ **The golden identity is over `.slashCommand`, and that bound is deliberate.** `.naturalLanguage` embedded its payload *mid-sentence* (`"…on issue 47: execute its implementation plan…"`), which a `StepSpec.prose` string reproduces through its `{}` marker — but the *tail* rendering changes, because the fallback now appends the same escaped tail as the slash form instead of a hand-written sentence. It reaches no user (measured: no production call site passes `strategy:`, the default is `.slashCommand`), so what is pinned for the fallback is the rendering **rule** plus every structural invariant the existing suite already asserts.

- [ ] **Step 1: Write the failing test**

First promote the one shared helper — **now, not in Step 3**, or Step 2's failure is a `cannot find 'countUnescapedQuotes' in scope` that reads like a different bug:

```bash
cd /Users/phmatray/Repositories/phmatray/private/Elliot/.claude/worktrees/hidden-forging-muffin
/usr/bin/sed -i '' \
  -e 's/^private func countUnescapedQuotes/func countUnescapedQuotes/' \
  ElliotKit/Tests/ElliotModelTests/SlashCommandBuilderTests.swift
```

Then create `ElliotKit/Tests/ElliotModelTests/GoldenPromptTests.swift`:

```swift
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
            pluginName: nil,
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
            id: "misdeclared", displayName: "Misdeclared", summary: "s", pluginName: nil,
            steps: [.implementIssue: StepSpec(
                command: "/x:go", arguments: .ideaThenLabels, prose: "Go: {}")]
        )
        let prompt = SlashCommandBuilder.prompt(
            for: .implementIssue(issueNumber: 47), method: misdeclared)
        #expect(prompt == "/x:go", "a misdeclared form emitted \(String(reflecting: prompt))")
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
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd ElliotKit && swift test --filter GoldenPromptTests`

Expected: FAIL — and as a **build** failure, not an assertion one, so it is the whole `swift test` invocation that stops:

```
error: extra argument 'method' in call
```

once per call site in the new file.

⚠️ Do not read this as "the filter matched nothing". A filter that matches nothing prints `warning: No matching test cases were run` and **exits 0**; this exits non-zero with the compiler diagnostic above.

- [ ] **Step 3: Write the minimal implementation**

Replace `ElliotKit/Sources/ElliotModel/SlashCommandBuilder.swift` with:

```swift
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
        let head =
            switch strategy {
            case .slashCommand: step.command
            case .naturalLanguage: step.prose
            }
        return head + tail(step.arguments, of: action)
    }

    /// The step a pack does not declare.
    ///
    /// It answers with the skill's own name, never another method's command.
    private static func undeclaredStep(for action: TriggerAction) -> StepSpec {
        StepSpec(
            command: action.kind.skillName,
            arguments: form(of: action),
            prose: "Use the \(action.kind.skillName) skill:"
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
    private static func tail(_ form: ArgumentForm, of action: TriggerAction) -> String {
        switch form {
        case .none:
            return ""
        case .ideaThenLabels:
            let text = idea(of: action)
            return (text.isEmpty ? "" : " \(text)") + flags("--label", labels(of: action))
        case .number:
            return number(of: action)
        case .numberThenFollowUps:
            return number(of: action) + flags("--follow-up", followUps(of: action))
        }
    }

    /// Emitted alone, so the skills' `grep -oE '[0-9]+' | head -1` reads it:
    /// no title, no '#', no year.
    private static func number(of action: TriggerAction) -> String {
        action.targetNumber.map { " \($0)" } ?? ""
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
```

`quoted(_:)` is gone with the hand-written prose sentences it served: the fallback now appends the same escaped tail as the slash form, so there is one renderer.

**Keep the package compiling** — `ElliotKit/Sources/ElliotEngine/BoardService.swift`. Add the case at `:25`:

```swift
    case runNotFound(UUID)
    case unknownMethod(String)
```

and its arm at `:35`:

```swift
        case .runNotFound(let id): "No run with id \(id)."
        case .unknownMethod(let id):
            "This repository is set to the method \"\(id)\", which this build does not know. "
                + "Choose one on the Repositories page."
```

then replace `makeRun` (`:173-189`):

```swift
    private func makeRun(for action: TriggerAction, card: Card) async throws -> SkillRun {
        guard let repo = try await store.repo(id: card.repoID) else {
            throw BoardError.repoNotFound(card.repoID)
        }
        // ⚠️ Interim, replaced by Task 7, which reads `repo.method`: the builder
        // needs a pack, and `resolve(nil)` answers the pack a repository that
        // never chose one gets — today's behaviour by construction, which is
        // what keeps `BoardServiceTests`' prompt literals green through this
        // change.
        //
        // `.unknown` is unreachable from `nil` and is refused rather than
        // substituted anyway: the reason `MethodResolution` has three cases is
        // that a repository whose method the catalogue does not know must not
        // quietly run another method's commands.
        let method: MethodPack
        switch MethodCatalog.resolve(nil) {
        case .unset(let pack), .chosen(let pack): method = pack
        case .unknown(let id): throw BoardError.unknownMethod(id)
        }
        let runID = UUID()
        return SkillRun(
            id: runID,
            cardID: card.id,
            repoID: card.repoID,
            kind: action.kind,
            prompt: SlashCommandBuilder.prompt(for: action, method: method),
            cwd: repo.path,
            logPath: StoreLocation.runLogURL(runID: runID).path,
            stderrPath: StoreLocation.runStderrURL(runID: runID).path,
            createdAt: Date()
        )
    }
```

Now the three test files. The mechanical part of `SlashCommandBuilderTests` — every call in it is about the default pack, so it says so once instead of twenty times:

```bash
cd /Users/phmatray/Repositories/phmatray/private/Elliot/.claude/worktrees/hidden-forging-muffin
/usr/bin/sed -i '' \
  -e 's/SlashCommandBuilder\.prompt(/kitPrompt(/g' \
  ElliotKit/Tests/ElliotModelTests/SlashCommandBuilderTests.swift
grep -c 'kitPrompt(' ElliotKit/Tests/ElliotModelTests/SlashCommandBuilderTests.swift   # expect 20
```

Then insert the wrapper immediately after the `nastyTitles` array (after line 50, before `@Suite`):

```swift
/// Every test in this file predates method packs, and every one of them is
/// about the pack a repository that never chose one gets — which is the pack
/// whose prompts `GoldenPromptTests` freezes. Saying that once here keeps the
/// twenty assertions below readable as what they are: the shipped behaviour.
private func kitPrompt(
    for action: TriggerAction,
    strategy: PromptStrategy = .slashCommand
) -> String {
    guard let kit = aiMigrationKitPack() else {
        // One named failure rather than twenty mismatches against "".
        Issue.record("MethodCatalog.resolve(nil) did not answer .unset with a pack")
        return ""
    }
    return SlashCommandBuilder.prompt(for: action, method: kit, strategy: strategy)
}
```

Delete `slashNames()` (the last test in the suite, `:290-295`) — `slashName` no longer exists — and add, at the end of the *"The property that protects against implementing the wrong issue"* section:

```swift
    /// The existing invariant, one pack wider. `implement-issue` resolves its
    /// argument with `grep -oE '[0-9]+' | head -1`, so **any** pack whose step
    /// takes a number must put that number first — which makes this the place a
    /// digit inside a command or a prose sentence is refused. A pack naming its
    /// command `/gsd-2-ship` would implement issue 2, silently, in every
    /// repository that chose it.
    ///
    /// Iterated over `SkillKind.allCases` rather than over `pack.steps`, so the
    /// order is the enum's and not a dictionary's.
    @Test(
        "Every built-in pack that takes a number puts that number first",
        arguments: [1, 4, 7, 9, 10, 47, 99, 100, 279, 1234, 99_999]
    )
    func everyNumberFormPutsTheNumberFirst(number: Int) {
        let noisy = nastyTitles + ["fix 3 flaky tests", "0 downtime rollout", "#1 priority"]
        for pack in MethodCatalog.builtIn {
            for kind in SkillKind.allCases {
                guard let step = pack.steps[kind],
                      step.arguments == .number || step.arguments == .numberThenFollowUps
                else { continue }

                let action: TriggerAction
                switch kind {
                case .implementIssue: action = .implementIssue(issueNumber: number)
                case .mergePR: action = .mergePR(prNumber: number, followUps: noisy)
                case .createIssue, .analyzeRepo:
                    Issue.record("\(pack.id) takes a number for \(kind.skillName), which carries none")
                    continue
                }
                for strategy in PromptStrategy.allCases {
                    let prompt = SlashCommandBuilder.prompt(
                        for: action, method: pack, strategy: strategy
                    )
                    #expect(
                        firstDigitRun(of: prompt) == number,
                        "\(pack.id) \(kind.skillName) \(strategy) produced \"\(prompt)\""
                    )
                }
            }
        }
    }
```

Replace `AnalysisModelTests.onlySkillsHaveSlashNames` (`:112-119`) with the same claim against the pack:

```swift
    @Test("The default method declares the three plugin skills and no analyze-repo step")
    func onlySkillsHaveCommands() throws {
        let kit = try #require(aiMigrationKitPack())
        #expect(kit.steps[.createIssue]?.command == "/ai-migration-kit:create-issue")
        #expect(kit.steps[.implementIssue]?.command == "/ai-migration-kit:implement-issue")
        #expect(kit.steps[.mergePR]?.command == "/ai-migration-kit:merge-pr")
        // There is no analyze-repo skill; that prompt is Elliot's own and is
        // built by `AnalysisPromptBuilder`, which never reaches a pack.
        #expect(kit.steps[.analyzeRepo] == nil)
    }
```

And the one call outside `ElliotModelTests` — `ClaudeRunnerTests.swift:562`, which runs a **real** child process and so is the end-to-end half of the golden. Replace that single line with:

```swift
        guard case .unset(let method) = MethodCatalog.resolve(nil) else {
            Issue.record("a repository that never chose a method must resolve to the default pack")
            return
        }
        let prompt = SlashCommandBuilder.prompt(for: action, method: method)
```

Its expected argv literal at `:580-582` is unchanged, which is the point.

- [ ] **Step 4: Run the test to verify it passes**

```bash
cd ElliotKit
swift test --filter GoldenPromptTests      # PASS — 6 functions, 17 cases
swift test --filter SlashCommandBuilderTests
swift test --filter AnalysisModelTests
swift test --filter ClaudeRunnerTests
swift test --filter BoardServiceTests      # its prompt literals must not have moved
swift test                                  # whole suite green
```

⚠️ **Do not compare the suite total against a number copied out of `CLAUDE.md`.** This task deletes one test, adds a new `@Suite` and adds a parameterised one, so the count *must* move; what matters is that there are **no failures** and that `BoardServiceTests`' prompt literals are untouched.

⚠️ If any run reports a failure that could not have happened — a literal reading as a different value, an unresolved symbol that is plainly declared — `rm -rf ElliotKit/.build` first: this change removes a member from an enum and changes a function's signature, which is exactly the stale-object trigger.

- [ ] **Step 5: Commit**

```bash
git rev-parse --abbrev-ref HEAD
git add ElliotKit/Sources/ElliotModel/SlashCommandBuilder.swift \
        ElliotKit/Sources/ElliotEngine/BoardService.swift \
        ElliotKit/Tests/ElliotModelTests/GoldenPromptTests.swift \
        ElliotKit/Tests/ElliotModelTests/SlashCommandBuilderTests.swift \
        ElliotKit/Tests/ElliotModelTests/AnalysisModelTests.swift \
        ElliotKit/Tests/ElliotProcessTests/ClaudeRunnerTests.swift
git commit -m "feat(model,engine): the prompt builder takes a method pack"
```

⚠️ The scope is `model,engine`, not `model`: the staged set includes `BoardService.swift`, which gains a `BoardError` case and a rewritten `makeRun`.

---

### Task 5: ArtifactProbe — the read-only half of the project-requirement proof

**Files:**
- Create: `ElliotKit/Sources/ElliotProcess/ArtifactProbe.swift`
- Test: `ElliotKit/Tests/ElliotProcessTests/ArtifactProbeTests.swift`

**Interfaces:**
- Consumes: `MethodPack.Evidence` (`ElliotModel`) — `case file(String)`, `case anyFileUnder(String)`, `Codable, Sendable, Hashable`. `ElliotProcess` already depends on `ElliotModel` (`Package.swift:144`), so nothing in the dependency graph moves.
- Produces:
  - `public struct ArtifactProbe: Sendable` with `public init(repoRoot: String)` and `public func evaluate(_ evidence: [MethodPack.Evidence]) throws -> [MethodPack.Evidence: Bool]`
  - `public enum ArtifactProbeError: Error, LocalizedError, Sendable` with `case escapesRepository(root: String, path: String)`, `case malformed(path: String)`, `case unreadable(root: String, reason: String)`, `case unlistable(path: String)` — Task 6 renders `error.localizedDescription` into its single "I could not look" warning

⛔ **`Package.swift` is NOT edited, and an earlier draft's reason for editing it was a misreading.** That draft added `ElliotStore` to `ElliotProcess` so the probe could canonicalise through `StoreLocation.canonicalPath`, citing that function's own *"**Both sides** of the protection test must come through here"*. But that sentence is about a **set-membership comparison between two independently-built strings** — the retention sweep's protected set. `ArtifactProbe` compares nothing: it joins root + components and hands the result to `FileManager`, which follows symlinks, so `/tmp/x/docs/prd.md` and `/private/tmp/x/docs/prd.md` answer identically. The only observable effect of canonicalising is the string inside `ArtifactProbeError`. A new edge in the layer graph and an edit to a union-merged hot-spot are not worth an error message, so the probe resolves symlinks in **two lines of its own**, with a comment saying it is deliberately not the sweep's rule. The spec's Testing row — *"the `/tmp` → `/private/tmp` canonicalisation that already cost a bug in #167"* — is still covered, by `escapesAreRefusedAtTheCanonicalRoot` below.

⚠️ **Measured on this machine, and the earlier draft asserted it backwards.** `URL(fileURLWithPath:).resolvingSymlinksInPath()` **strips** `/private` when the result is an existing path, and leaves it when the path does not exist:

| input | output |
|---|---|
| `/tmp/<existing>` | `/tmp/<existing>` |
| `/private/tmp/<existing>` | `/tmp/<existing>` |
| `/private/tmp/<absent>` | `/private/tmp/<absent>` |

So for a checkout that exists, the canonical root is the **`/tmp`** spelling, not the `/private/tmp` one. The two tests below assert both halves of that asymmetry rather than one of them backwards.

- [ ] **Step 1: Write the failing test**

`ElliotKit/Tests/ElliotProcessTests/ArtifactProbeTests.swift`:

```swift
import ElliotModel
import Foundation
import Testing

@testable import ElliotProcess

/// The disk-touching half of a method's project requirements.
///
/// `MethodPack.projectGaps` decides without reading anything; this reads without
/// deciding anything. The split is the one `nextCandidates` / `rankNextSteps`
/// already practise, and it is what makes the deciding half testable with no
/// filesystem at all.
///
/// Real temporary directories rather than a fake `FileManager`: what is asserted
/// here is what the filesystem answered, including the `/tmp` → `/private/tmp`
/// symlink that cost this repository a bug in #167.
@Suite("Artifact probe")
struct ArtifactProbeTests {

    /// A checkout under `/private/tmp`, addressable by both spellings.
    ///
    /// Deliberately **not** `FileManager.default.temporaryDirectory`: that hands
    /// back `/var/folders/…`, whose symlink hop is real but is not the one the
    /// project's own verification recipe walks into. `/tmp/elliot-check` is the
    /// scratch home CLAUDE.md tells everyone to use.
    private func checkout() throws -> (short: String, long: String, remove: () -> Void) {
        let name = "elliot-probe-\(UUID().uuidString)"
        let long = "/private/tmp/\(name)"
        try FileManager.default.createDirectory(atPath: long, withIntermediateDirectories: true)
        return ("/tmp/\(name)", long, { try? FileManager.default.removeItem(atPath: long) })
    }

    private func write(_ relative: String, under root: String) throws {
        let url = URL(fileURLWithPath: root).appendingPathComponent(relative)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: url)
    }

    // MARK: - What it answers

    @Test("A file that is there is true, and one that is not is false")
    func filePresence() throws {
        let (short, long, remove) = try checkout()
        defer { remove() }
        try write(".planning/PROJECT.md", under: long)

        let answer = try ArtifactProbe(repoRoot: short)
            .evaluate([.file(".planning/PROJECT.md"), .file("docs/prd.md")])

        #expect(answer[.file(".planning/PROJECT.md")] == true)
        // Present and `false`, never absent. `projectGaps` counts a missing key
        // as unsatisfied, so a probe that omitted the answer would produce the
        // right gap for the wrong reason — and would go on producing it after
        // the file appeared.
        #expect(answer[.file("docs/prd.md")] == false)
        #expect(answer.count == 2)
    }

    /// ⛔ Measured: `FileManager.fileExists(atPath:)` answers `true` for a
    /// directory. Without the `isDirectory` check, `.file("specs")` reads as
    /// satisfied by an empty `specs/` — the exact state the sibling test below
    /// exists to refuse, passing under a different case name.
    @Test("A directory does not satisfy .file")
    func fileEvidenceIsNotSatisfiedByADirectory() throws {
        let (short, long, remove) = try checkout()
        defer { remove() }
        try FileManager.default.createDirectory(
            atPath: long + "/docs", withIntermediateDirectories: true)

        let answer = try ArtifactProbe(repoRoot: short).evaluate([.file("docs")])
        #expect(answer[.file("docs")] == false)
    }

    @Test("anyFileUnder is about files, not about the directory existing")
    func anyFileUnderNeedsAFile() throws {
        let (short, long, remove) = try checkout()
        defer { remove() }
        // An empty directory is exactly the state a half-run method leaves, and
        // it must not read as satisfied.
        try FileManager.default.createDirectory(
            atPath: long + "/specs", withIntermediateDirectories: true)

        let probe = ArtifactProbe(repoRoot: short)
        #expect(try probe.evaluate([.anyFileUnder("specs")])[.anyFileUnder("specs")] == false)
        #expect(try probe.evaluate([.anyFileUnder("nope")])[.anyFileUnder("nope")] == false)

        // At any depth, and hidden files count: `.specify/` and `.planning/` are
        // the shapes these methods actually write, and a walk that skipped
        // hidden entries would report an empty tree for a method that had run.
        try write("specs/003-chat/.spec.md", under: long)
        #expect(try probe.evaluate([.anyFileUnder("specs")])[.anyFileUnder("specs")] == true)
    }

    @Test("The same evidence asked twice is answered once")
    func duplicatesCollapse() throws {
        let (short, long, remove) = try checkout()
        defer { remove() }
        try write("docs/prd.md", under: long)

        let answer = try ArtifactProbe(repoRoot: short)
            .evaluate([.file("docs/prd.md"), .file("docs/prd.md")])
        #expect(answer.count == 1)
        #expect(answer[.file("docs/prd.md")] == true)
    }

    // MARK: - What it refuses

    @Test("A path leaving the checkout is refused, and the refusal names the canonical root")
    func escapesAreRefusedAtTheCanonicalRoot() throws {
        let (short, long, remove) = try checkout()
        defer { remove() }

        do {
            _ = try ArtifactProbe(repoRoot: long).evaluate([.file("../escape.md")])
            Issue.record("a path leaving the checkout must be refused")
        } catch let error as ArtifactProbeError {
            guard case .escapesRepository(let root, let path) = error else {
                Issue.record("expected an escape refusal, got \(error)")
                return
            }
            #expect(path == "../escape.md")
            // ⛔ The canonicalisation, made observable — and in the direction it
            // actually goes. `resolvingSymlinksInPath()` **strips** `/private`
            // for an existing path, so a caller who spelled the root
            // `/private/tmp/…` is reported the `/tmp/…` spelling. Asserting the
            // reverse is what an earlier draft did, and it fails on this machine.
            #expect(root == short)
            #expect(root != long)
        }
    }

    @Test("An absolute path is refused rather than read")
    func absolutePathsAreRefused() throws {
        let (short, _, remove) = try checkout()
        defer { remove() }

        #expect(throws: ArtifactProbeError.self) {
            _ = try ArtifactProbe(repoRoot: short).evaluate([.file("/etc/hosts")])
        }
    }

    @Test("Evidence naming nothing inside the checkout is malformed, not satisfied")
    func emptyPathIsMalformed() throws {
        let (short, _, remove) = try checkout()
        defer { remove() }

        // `.file("")` would otherwise test the checkout directory itself and
        // answer `true` — a requirement reported satisfied by a path that names
        // no artefact at all.
        #expect(throws: ArtifactProbeError.self) {
            _ = try ArtifactProbe(repoRoot: short).evaluate([.file("")])
        }
    }

    @Test("A checkout it cannot read throws — it never answers with an empty map")
    func unreadableThrows() {
        // ⛔ The whole reason `evaluate` throws. An empty map reads as "every
        // requirement is missing", which would put N false gaps on a screen for
        // a directory nobody could open — the same lie `ArtifactSweeper`'s
        // "no protected set, no sweep" rule exists to prevent, one layer over.
        let absent = "/private/tmp/elliot-probe-absent-\(UUID().uuidString)"
        do {
            let answer = try ArtifactProbe(repoRoot: absent)
                .evaluate([.file("docs/prd.md"), .anyFileUnder("specs")])
            Issue.record("expected a refusal, got \(answer.count) answers")
        } catch let error as ArtifactProbeError {
            guard case .unreadable(let root, let reason) = error else {
                Issue.record("expected an unreadable refusal, got \(error)")
                return
            }
            // ⚠️ The other half of the asymmetry: `resolvingSymlinksInPath()`
            // only strips `/private` for a path that exists, so an absent root
            // is reported exactly as the caller spelled it.
            #expect(root == absent)
            #expect(!reason.isEmpty)
            // The sentence Preflight puts on screen has to name a cause.
            #expect(error.localizedDescription.contains("could not be read"))
        } catch {
            Issue.record("unexpected error \(error)")
        }
    }

    /// ⛔ The refusal the doc comment claims and an earlier draft did not
    /// implement. Measured: on a `chmod 000` directory the enumerator is
    /// **non-nil** and yields **zero** entries, so a walk alone answers `false`
    /// — "there is nothing there" for a directory nobody could read, which is
    /// exactly the lie this type exists to refuse.
    @Test("A directory that cannot be listed throws rather than answering false")
    func unlistableDirectoryThrows() throws {
        // As root every directory is readable, and the check would be vacuous.
        guard getuid() != 0 else { return }
        let (short, long, remove) = try checkout()
        defer { remove() }
        try write("specs/003/spec.md", under: long)
        let locked = long + "/specs"
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked)
        defer { try? FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: locked) }

        do {
            let answer = try ArtifactProbe(repoRoot: short).evaluate([.anyFileUnder("specs")])
            Issue.record("an unreadable directory answered \(String(describing: answer.first))")
        } catch let error as ArtifactProbeError {
            guard case .unlistable(let path) = error else {
                Issue.record("expected .unlistable, got \(error)")
                return
            }
            #expect(path.hasSuffix("/specs"))
        }
    }

    @Test("A file where a checkout was expected is a refusal, not a directory with nothing in it")
    func aFileIsNotACheckout() throws {
        let (short, long, remove) = try checkout()
        defer { remove() }
        try write("notADirectory", under: long)

        #expect(throws: ArtifactProbeError.self) {
            _ = try ArtifactProbe(repoRoot: short + "/notADirectory").evaluate([.file("a.md")])
        }
    }

    @Test("No evidence is no work, and no refusal")
    func emptyInput() throws {
        let (short, _, remove) = try checkout()
        defer { remove() }
        #expect(try ArtifactProbe(repoRoot: short).evaluate([]).isEmpty)
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd ElliotKit && swift test --filter ArtifactProbeTests`

Expected: FAIL at compile time — `error: cannot find 'ArtifactProbe' in scope` and `error: cannot find type 'ArtifactProbeError' in scope`, repeated at every use.

⚠️ `--filter` matches the **type** name, so `ArtifactProbeTests` is right and `"Artifact probe"` is not. A filter that matches nothing prints `warning: No matching test cases were run` and **exits 0** — read the summary line, not the exit code.

- [ ] **Step 3: Write the minimal implementation**

`ElliotKit/Sources/ElliotProcess/ArtifactProbe.swift`:

```swift
import ElliotModel
import Foundation

/// Why a probe would not answer.
///
/// Four cases, and two of them are the same point: **"I could not look" is not
/// "there is nothing there".** Preflight turns either into one warning naming
/// the cause rather than one false gap per requirement.
public enum ArtifactProbeError: Error, LocalizedError, Sendable {
    /// The evidence names a path that leads out of the checkout.
    case escapesRepository(root: String, path: String)
    /// The evidence names nothing inside the checkout — `""`, `"."`, `"./"`.
    case malformed(path: String)
    /// The checkout **root** could not be read.
    case unreadable(root: String, reason: String)
    /// A directory inside the checkout exists and could not be listed. Distinct
    /// from `.unreadable`, which is about the root: rendering a subdirectory as
    /// "the checkout could not be read" would send a reader to the wrong path.
    case unlistable(path: String)

    public var errorDescription: String? {
        switch self {
        case .escapesRepository(let root, let path):
            "\(path) leads outside \(root)"
        case .malformed(let path):
            "\"\(path)\" does not name anything inside the repository"
        case .unreadable(let root, let reason):
            "\(root) could not be read: \(reason)"
        case .unlistable(let path):
            "\(path) could not be read: it exists but could not be listed"
        }
    }
}

/// Whether a method's project artefacts are on disk. Reads, and decides nothing.
///
/// The impure half of a project requirement. `MethodPack.projectGaps` is the
/// other half and takes this map — the same split `nextCandidates` and
/// `rankNextSteps` already practise, so the rule stays testable with no
/// filesystem and the filesystem stays testable with no rule.
///
/// ⛔ **It only ever reads.** No `create`, no `write`, no `remove`. A diagnostic
/// that repaired what it measured could not be re-run to check itself.
///
/// `evaluate` is not `async`, unlike every other method in this target: the
/// siblings here spawn subprocesses and this touches `FileManager` only. There
/// is nothing to await, and an `async` that never suspends is a signature making
/// a promise about its cost that is not true.
public struct ArtifactProbe: Sendable {
    private let root: String

    public init(repoRoot: String) {
        // ⚠️ Deliberately **not** `StoreLocation.canonicalPath`, and not because
        // of layering taste. That function's contract is about a *set-membership
        // comparison between two independently-built strings* — the retention
        // sweep's protected set, #167 — and this probe compares nothing: it
        // joins root + components and hands the result to `FileManager`, which
        // follows symlinks, so both spellings of `/tmp` answer identically. The
        // resolution here exists so an **error message** names the same path the
        // rest of the machine would print. Importing `ElliotStore` into
        // `ElliotProcess` and editing a union-merged manifest to buy a sentence
        // is not a trade worth making.
        //
        // ⚠️ It resolves asymmetrically, measured: `/private/tmp/<existing>`
        // comes back as `/tmp/<existing>`, while a path that does **not** exist
        // is returned unchanged. `ArtifactProbeTests` pins both halves, because
        // one of them looks like a bug from the other's side.
        self.root = URL(fileURLWithPath: repoRoot).resolvingSymlinksInPath().path
    }

    /// One answer per distinct piece of evidence.
    ///
    /// ⛔ **Throws rather than returning an empty map.** An empty map reads as
    /// "everything is missing", which is the exact lie `ArtifactSweeper`'s
    /// "no protected set, no sweep" rule exists to prevent — here it would put a
    /// gap on screen for every requirement of a repository nobody could open,
    /// each with a button offering to file a card about it.
    public func evaluate(_ evidence: [MethodPack.Evidence]) throws -> [MethodPack.Evidence: Bool] {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root, isDirectory: &isDirectory) else {
            throw ArtifactProbeError.unreadable(root: root, reason: "there is nothing at this path")
        }
        guard isDirectory.boolValue else {
            throw ArtifactProbeError.unreadable(root: root, reason: "it is a file, not a directory")
        }
        guard FileManager.default.isReadableFile(atPath: root) else {
            throw ArtifactProbeError.unreadable(root: root, reason: "it is not readable")
        }

        var answer: [MethodPack.Evidence: Bool] = [:]
        // Exhaustive with no `default:`, for the reason every other switch over
        // a closed vocabulary in this project is: wave 2 adds `.githubIssue`,
        // `.githubPR` and `.merged`, and each must fail to compile here so
        // someone decides what proves it rather than inheriting `false`.
        for item in evidence {
            switch item {
            case .file(let relative):
                answer[item] = isRegularFile(at: try resolve(relative))
            case .anyFileUnder(let relative):
                answer[item] = try containsRegularFile(at: try resolve(relative))
            }
        }
        return answer
    }

    /// ⛔ A **file**, not merely something at that path.
    ///
    /// `fileExists(atPath:)` answers `true` for a directory (measured), so
    /// `.file("specs")` would read as satisfied by an empty `specs/` — the state
    /// `.anyFileUnder` exists to refuse, passing under the other case's name.
    private func isRegularFile(at path: String) -> Bool {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else {
            return false
        }
        return !isDirectory.boolValue
    }

    /// The absolute path this evidence names, refused if it leaves the checkout.
    ///
    /// **Lexical, and deliberately so.** It must answer the same way for a path
    /// that exists and one that does not — a *missing* artefact is the whole
    /// point of this probe — and `standardizingPath` resolves symlinks only for
    /// paths that exist, so a resolver here would classify a present file and an
    /// absent one by different rules. `..` is popped, `.` and empty components
    /// dropped, an absolute path refused outright.
    ///
    /// ⚠️ It does **not** stop a symlink *inside* the checkout that points out of
    /// it. Following one is a read of a file the repository itself points at, and
    /// this probe only reads. The design puts the real gate on catalogue
    /// validation, where the paths come from; this is the second lock.
    private func resolve(_ relative: String) throws -> String {
        guard !relative.hasPrefix("/") else {
            throw ArtifactProbeError.escapesRepository(root: root, path: relative)
        }
        var components: [String] = []
        for raw in relative.split(separator: "/", omittingEmptySubsequences: true) {
            let component = String(raw)
            if component == "." { continue }
            if component == ".." {
                guard !components.isEmpty else {
                    throw ArtifactProbeError.escapesRepository(root: root, path: relative)
                }
                components.removeLast()
                continue
            }
            components.append(component)
        }
        guard !components.isEmpty else {
            // The checkout itself is not an artefact. Answering `true` here
            // would report a requirement satisfied by a path naming nothing.
            throw ArtifactProbeError.malformed(path: relative)
        }
        return ([root] + components).joined(separator: "/")
    }

    /// Whether any regular file lives under this directory, at any depth.
    ///
    /// Hidden entries are **kept**: `.planning/`, `.specify/` and `.claude/` are
    /// the shapes these methods actually write, and a walk that skipped them
    /// would report an empty tree for a method that had run. This is the one
    /// place it differs from `StoreLocation.inventory`, which skips them because
    /// it is looking for artefacts Elliot itself wrote.
    ///
    /// A missing directory is `false` — a finding. ⛔ **A directory that exists
    /// and cannot be read throws**, and the readability is checked *before* the
    /// walk rather than inferred from it: measured on a `chmod 000` directory,
    /// `enumerator(at:…)` returns **non-nil** and yields **zero** entries, so a
    /// walk alone answers `false` and reports "there is nothing there" about a
    /// directory nobody could open.
    ///
    /// ⚠️ **The check covers this directory, not every directory beneath it.** A
    /// deeper subdirectory that cannot be listed still contributes no files and
    /// is not distinguished from an empty one. Closing that needs the
    /// enumerator's `errorHandler`, whose escaping closure cannot capture a
    /// local under strict concurrency without a reference box — bought when
    /// something needs it, and said here rather than left to be assumed.
    private func containsRegularFile(at directory: String) throws -> Bool {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory, isDirectory: &isDirectory),
              isDirectory.boolValue
        else { return false }

        guard FileManager.default.isReadableFile(atPath: directory) else {
            throw ArtifactProbeError.unlistable(path: directory)
        }

        guard let walk = FileManager.default.enumerator(
            at: URL(fileURLWithPath: directory),
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [],
            errorHandler: { _, _ in true }
        ) else {
            throw ArtifactProbeError.unlistable(path: directory)
        }

        for case let url as URL in walk {
            if (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true {
                return true
            }
        }
        return false
    }
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `cd ElliotKit && swift test --filter ArtifactProbeTests`

Expected: PASS — **11 tests**.

Sample it rather than trusting one green run: `for i in 1 2 3 4 5; do swift test --filter ArtifactProbeTests; done` after the first build costs about eight seconds, and these tests write to a shared `/private/tmp`, which is exactly where an unlabelled collision between parallel suites would hide (each checkout carries a `UUID`, which is what makes them safe — that is the property the repetition is checking).

Then `cd ElliotKit && swift test` once for the whole package.

- [ ] **Step 5: Commit**

```bash
git rev-parse --abbrev-ref HEAD
git add ElliotKit/Sources/ElliotProcess/ArtifactProbe.swift \
        ElliotKit/Tests/ElliotProcessTests/ArtifactProbeTests.swift
git commit -m "feat(process): a read-only probe for a method's project artefacts"
```

---

### Task 6: Preflight answers for the repository's method

**Files:**
- Modify: `ElliotKit/Sources/ElliotEngine/PreflightService.swift:47` (`CheckFix.seedCard` gains `key: String?`), `:62-69` (`id`), `:77-81` (`repoID`), `:136-201` (`globalChecks` takes packs), `:274-349` (`repoChecks` becomes method-aware), `:416-430` (the labels seed passes `key: nil`), `:522` (`apply`'s binding)
- Modify: `ElliotKit/Sources/ElliotAppKit/AppModel.swift:679` (the one `globalChecks` call site)
- Modify: `ElliotKit/Tests/ElliotEngineTests/PreflightTests.swift:50,253,273,316` and `ElliotKit/Tests/ElliotAppKitTests/PreflightFixTests.swift:39,66` — six existing `.seedCard(…)` constructions gain `key: nil`. (The `if case .seedCard =` at `PreflightTests.swift:134` needs no change.)
- Test: `ElliotKit/Tests/ElliotEngineTests/PreflightMethodTests.swift`

**Interfaces:**
- Consumes:
  - `MethodPack` — `id`, `displayName`, `summary`, `pluginName: String?`, `projectRequirements`, `steps`, and `idempotencyKey(for:in:)` (Task 1)
  - `MethodPack.projectGaps(satisfied: [MethodPack.Evidence: Bool]) -> [ProjectRequirement]`
  - `MethodResolution` · `MethodCatalog.builtIn` · `MethodCatalog.resolve(_:)` · `MethodCatalog.defaultPackID` (Task 2)
  - `ProjectRequirement` — `id`, `title`, `evidence`, `remedy`, `seed`
  - `Repo.methodID`, `Repo.method` (Task 3)
  - `ArtifactProbe(repoRoot:)`, `evaluate(_:) throws`, `ArtifactProbeError` (Task 5)
- Produces:
  - `CheckFix.seedCard(repoID:title:story:key:)` — `key: nil` keeps the historical id
  - `PreflightService.globalChecks(layout:packs:) async -> [CheckResult]`
  - `PreflightService.packsInUse(_ repos: [Repo]) -> [MethodPack]`
  - `PreflightService.requiredSkills(of: MethodPack) -> [String]`
  - `PreflightService.profileHint(_ pack: MethodPack?) -> String` and `PreflightService.profilePath`
  - `PreflightService.projectChecks(repo:pack:satisfied:) -> [CheckResult]`
  - `PreflightService.probeRefusal(pack:repo:error:) -> CheckResult`
  - `PreflightService.projectResults(repo:pack:) async -> [CheckResult]` — **not in the canonical contract**, and the reason is finding-driven: without it the `catch` arm inside `repoChecks` is unreachable from any test (see below), so deleting it would leave every test green.
  - check ids: `repo.method`, `method.<packID>.<reqID>`, `method.<packID>.probe`, `plugin.<packID>`
- ⚠️ **This task needs Task 1's `MethodPack.init` *and* `StepSpec.init` to be `public`.** `PreflightMethodTests` lives in `ElliotEngineTests`, which imports `ElliotModel` **non-`@testable`**, and builds both by hand to state the `pluginName == nil` case and the "command is not `plugin:skill`" case without depending on what the catalogue ships. Task 1 declares both public; if that changes, these two tests must be rewritten against `MethodCatalog.builtIn.first { … }` and would then be **silently skipped** whenever no such pack exists — which is worse.
- ⚠️ **A user-visible check id changes: `plugin.aiMigrationKit` → `plugin.ai-migration-kit`**, because the loop derives it from `pack.id`. `PreflightService.swift:185` is the sole occurrence in the tree and no test asserts it, so nothing breaks — but it is a change to a string a reader may have seen, and it is named rather than slipped in.

⚠️ **What this task does not fix, said out loud.** `repo.profile` stays a `.fail` for any method that dispatches plugin skills, so a repository choosing such a method without `.claude/skills/repo-profile.md` will have a frozen board. The rule below narrows that to methods whose steps actually name plugin skills — which spares GSD, Spec Kit and plan mode — but a *new* plugin-based method that does not read a profile would still be frozen. Making the profile a `ProjectRequirement` of the ai-migration-kit pack is the real fix and it is wave-2 work; wave 1 ships no field that says "this method reads a profile".

- [ ] **Step 1: Write the failing test**

`ElliotKit/Tests/ElliotEngineTests/PreflightMethodTests.swift`:

```swift
import ElliotModel
import ElliotProcess
import ElliotStore
import Foundation
import TestSupport
import Testing

@testable import ElliotEngine

/// Preflight, once a repository can choose what Elliot runs there.
///
/// Two verdicts carry this whole suite and they are one character apart:
///
/// - **a missing project artefact is a `.warn`, never a `.fail`.** Since #249 a
///   `.fail` blocks every drag in that repository, so a repository without a PRD
///   would be frozen for lacking a file it has every right not to have.
/// - **an unknown `methodID` is a `.fail`.** We do not know what to run there,
///   and running a different method's commands unannounced is worse than
///   refusing — that is the silent substitution `MethodResolution` exists to stop.
///
/// The end-to-end tests drive `repoChecks` against a real `git init` under the
/// temporary directory, because a suite that only exercised the pure statics
/// would stay green if `repoChecks` stopped calling them — the gap
/// `CaretAnchorTests` was written to close, one screen over.
@Suite("Preflight methods")
struct PreflightMethodTests {

    private enum Paths {
        static let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // ElliotEngineTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // ElliotKit
            .deletingLastPathComponent()   // repo root

        static let fakeGH = repoRoot.appendingPathComponent("Scripts/fake-gh.sh").path
    }

    /// A real `git`, a fake `gh`, no network and no token.
    ///
    /// `gh repo view` is not a subcommand the fake answers, so it exits 64 and
    /// `repoInfo` comes back nil — which is what a checkout with no GitHub
    /// remote looks like, and it keeps the labels check (and its network call)
    /// out of every test here.
    private func service() -> PreflightService {
        PreflightService(
            environment: LoginShellEnvironment(variables: [:], capturedVia: "test"),
            config: ToolConfig(
                claudePath: "/usr/bin/false",
                ghPath: Paths.fakeGH,
                gitPath: "/usr/bin/git",
                environment: [
                    "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                    "HOME": NSHomeDirectory(),
                    "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_SYSTEM": "/dev/null",
                    "GIT_TERMINAL_PROMPT": "0",
                ]
            )
        )
    }

    /// An empty checkout Elliot can legally sweep: a main checkout, on a branch,
    /// with nothing in it — which is exactly "every project requirement missing".
    private func checkout() async throws -> (path: String, remove: () -> Void) {
        let path = "/private/tmp/elliot-method-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        try await git(["init", "--initial-branch=main"], in: path)
        return (path, { try? FileManager.default.removeItem(atPath: path) })
    }

    private func repo(at path: String, methodID: String?) -> Repo {
        var repo = Repo(path: path, nameWithOwner: "phmatray/sandbox", displayName: "sandbox")
        repo.methodID = methodID
        return repo
    }

    /// The pack a project-requirement test can be written against without
    /// guessing what the catalogue named things.
    private func packWithRequirements() throws -> MethodPack {
        try #require(
            MethodCatalog.builtIn.first { !$0.projectRequirements.isEmpty },
            "wave 1 must ship at least one pack carrying project requirements"
        )
    }

    // MARK: - The two verdicts

    @Test("A missing project artefact warns, and warning never freezes the board")
    func missingArtefactWarnsAndDoesNotBlock() async throws {
        let pack = try packWithRequirements()
        let (path, remove) = try await checkout()
        defer { remove() }

        let results = await service().repoChecks(repo(at: path, methodID: pack.id))
        let method = results.filter { $0.id.hasPrefix("method.\(pack.id).") }

        // Every requirement is a gap in an empty checkout, and every gap is one
        // check. This is also what stops `repoChecks` quietly ceasing to call
        // `projectResults`: the statics below are tested directly, this is not.
        #expect(method.count == pack.projectRequirements.count)
        #expect(method.allSatisfy { $0.status == .warn })
        // ⛔ The claim #249 made load-bearing. A repository without a PRD still
        // works; freezing it would be absurd.
        #expect(!PreflightService.isBlocking(method))
    }

    @Test("Each gap carries a card seeded under the requirement's own key")
    func gapsSeedCardsKeyedByRequirement() async throws {
        let pack = try packWithRequirements()
        let requirement = pack.projectRequirements[0]
        let (path, remove) = try await checkout()
        defer { remove() }

        let subject = repo(at: path, methodID: pack.id)
        let results = await service().repoChecks(subject)
        let check = try #require(results.first { $0.id == "method.\(pack.id).\(requirement.id)" })

        #expect(check.fixHint == requirement.remedy)
        let fix = try #require(check.fixes.first)
        // ⛔ Built through the one function that builds it, and it CARRIES THE
        // REPOSITORY. `apply` passes `fix.id` straight into
        // `createCard(idempotencyKey:)`, and `card_on_idempotencyKey` is unique
        // board-wide, so a repo-free key would hand the second repository to
        // choose this method the first one's card while reporting
        // "Added a card to Backlog."
        #expect(fix.id == pack.idempotencyKey(for: requirement, in: subject.id))
        #expect(fix.id.contains(subject.id.uuidString))
        #expect(fix.repoID == subject.id)
        #expect(fix.label == "Add a card")
    }

    @Test("A requirement that is satisfied produces no check at all")
    func satisfiedRequirementsAreSilent() async throws {
        let pack = try packWithRequirements()
        let (path, remove) = try await checkout()
        defer { remove() }

        let requirement = pack.projectRequirements[0]
        let relative: String
        switch requirement.evidence {
        case .file(let named): relative = named
        case .anyFileUnder(let directory): relative = directory + "/seeded.md"
        }
        let url = URL(fileURLWithPath: path).appendingPathComponent(relative)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("# there\n".utf8).write(to: url)

        let results = await service().repoChecks(repo(at: path, methodID: pack.id))
        #expect(!results.contains { $0.id == "method.\(pack.id).\(requirement.id)" })
    }

    @Test("An unknown method fails, blocks, and names what it was set to")
    func unknownMethodBlocks() async throws {
        let (path, remove) = try await checkout()
        defer { remove() }

        let results = await service().repoChecks(repo(at: path, methodID: "no-such-method"))
        let check = try #require(results.first { $0.id == "repo.method" })

        #expect(check.status == .fail)
        #expect(PreflightService.isBlocking([check]))
        #expect(check.detail.contains("no-such-method"))
        // And nothing was probed on its behalf: we do not know which artefacts
        // to look for, so reporting gaps would be reporting another method's.
        #expect(!results.contains { $0.id.hasPrefix("method.") })
    }

    @Test("A repository that never chose reads as unset, not as a choice")
    func unsetIsItsOwnState() async throws {
        let (path, remove) = try await checkout()
        defer { remove() }

        let check = try #require(
            await service().repoChecks(repo(at: path, methodID: nil))
                .first { $0.id == "repo.method" })
        #expect(check.status == .pass)
        // "Not chosen" and "chose the default" are the same commands and two
        // different facts, and only one of them follows the default if it moves.
        #expect(check.detail.lowercased().contains("not chosen"))
    }

    // MARK: - Refusing to guess

    @Test("A probe that refused produces one warning naming the cause, not N false gaps")
    func unreadableCheckoutIsOneWarning() throws {
        let pack = try packWithRequirements()
        let subject = repo(at: "/private/tmp/elliot-absent-\(UUID())", methodID: pack.id)

        var thrown: (any Error)?
        do {
            _ = try ArtifactProbe(repoRoot: subject.path)
                .evaluate(pack.projectRequirements.map(\.evidence))
        } catch {
            thrown = error
        }
        let check = PreflightService.probeRefusal(
            pack: pack, repo: subject, error: try #require(thrown))

        #expect(check.status == .warn)
        #expect(check.detail.lowercased().contains("could not be established"))
        // ⛔ It must not read as a verdict about the artefacts. "I could not
        // look" is not "there is nothing there" — the same duty `labelsCheck`
        // discharges when `gh` does not answer.
        #expect(!check.detail.contains(pack.projectRequirements[0].title))
        #expect(check.fixes.isEmpty)
    }

    /// ⛔ The refusal reached through the code path that will actually run it.
    ///
    /// `repoChecks` returns early on `guard isRepo` (`PreflightService.swift:284`),
    /// which covers every case `ArtifactProbe` throws `.unreadable` for — so by
    /// the time the probe runs, the root is a readable git directory and the
    /// `catch` is reachable only from **malformed pack evidence**. Calling
    /// `probeRefusal` directly (the test above) leaves that arm untested, and
    /// deleting it would keep every test green. `projectResults` exists so this
    /// one can drive the arm with a hand-built pack.
    @Test("Malformed pack evidence reaches the refusal instead of crashing the sweep")
    func malformedPackEvidenceReachesTheRefusal() async throws {
        let (path, remove) = try await checkout()
        defer { remove() }

        let broken = MethodPack(
            id: "broken", displayName: "Broken", summary: "s", pluginName: nil,
            projectRequirements: [
                ProjectRequirement(
                    id: "escape", title: "An artefact outside the checkout",
                    evidence: .file("../elsewhere.md"), remedy: "Fix the pack.",
                    seed: CardDraft(
                        title: "Fix the pack", role: "maintainer", want: "a valid path",
                        benefit: "the probe can look", criteria: ["The path is relative."]))
            ]
        )
        let results = await service().projectResults(repo: repo(at: path, methodID: nil), pack: broken)

        let refusal = try #require(results.first, "a refusal must still produce a row")
        #expect(results.count == 1, "one warning, never one per requirement")
        #expect(refusal.id == "method.broken.probe")
        #expect(refusal.status == .warn)
        #expect(refusal.fixes.isEmpty)
    }

    // MARK: - The plugin, and the method that has none

    @Test("A method that is not a plugin is skipped, never failed")
    func noPluginIsSkipped() async {
        let plain = MethodPack(
            id: "plan-mode", displayName: "Plan mode",
            summary: "Claude Code's own plan mode. Nothing is written to disk.",
            pluginName: nil, projectRequirements: [], steps: [:]
        )
        let results = await service().globalChecks(layout: .portfolio, packs: [plain])

        // No row at all. A method that needs no plugin must not read as a method
        // whose plugin is missing — that is a `.fail` for a correct setup.
        #expect(!results.contains { $0.id == "plugin.plan-mode" })
        // And the global sweep still ran everything else.
        #expect(results.contains { $0.id == "plugin.superpowers" })
    }

    @Test("A plugin pack is checked for the skills its own steps name")
    func requiredSkillsComeFromTheSteps() throws {
        let kit = try #require(
            MethodCatalog.builtIn.first { $0.id == MethodCatalog.defaultPackID })
        // Alphabetical, because a dictionary has no order and a check whose
        // detail string reshuffled between sweeps would read as movement.
        #expect(
            PreflightService.requiredSkills(of: kit)
                == ["create-issue", "implement-issue", "merge-pr"])

        // A command that does not name a plugin skill contributes none. GSD's
        // `/gsd-plan-phase` is a command, not `plugin:skill`, so there is no
        // `SKILL.md` to look for.
        let gsdShaped = MethodPack(
            id: "gsd-shaped", displayName: "GSD", summary: "s", pluginName: "gsd",
            projectRequirements: [],
            steps: [.createIssue: StepSpec(
                command: "/gsd-plan-phase", arguments: .ideaThenLabels, prose: "p {}")]
        )
        #expect(PreflightService.requiredSkills(of: gsdShaped).isEmpty)
    }

    @Test("The profile freezes a board only for a method whose skills read it")
    func profileFailsOnlyForSkillDispatchingMethods() async throws {
        let (path, remove) = try await checkout()
        defer { remove() }

        // Today's behaviour, unchanged: the default pack dispatches three plugin
        // skills, all of which read the profile at their preconditions step.
        let unset = await service().repoChecks(repo(at: path, methodID: nil))
        #expect(try #require(unset.first { $0.id == "repo.profile" }).status == .fail)

        // And the rule that made that conditional rather than hardcoded.
        #expect(PreflightService.profileHint(nil).contains("by hand"))
        let kit = try #require(
            MethodCatalog.builtIn.first { $0.id == MethodCatalog.defaultPackID })
        #expect(PreflightService.profileHint(kit).contains("/ai-migration-kit:get-repo-profile"))
    }

    @Test("The packs a global sweep checks always include the default")
    func packsInUseAlwaysIncludesTheDefault() {
        // `globalChecks` runs at launch, before the repository table has been
        // read. An empty list there must not make the plugin check quietly
        // disappear — "nobody looked" wearing a pass is the shape this whole
        // change exists to remove.
        #expect(PreflightService.packsInUse([]).map(\.id) == [MethodCatalog.defaultPackID])

        var unknown = Repo(path: "/x", nameWithOwner: "o/r", displayName: "r")
        unknown.methodID = "no-such-method"
        // An unknown id contributes no pack — it has its own `.fail`, per
        // repository, and there is no plugin name to check.
        #expect(PreflightService.packsInUse([unknown]).map(\.id) == [MethodCatalog.defaultPackID])
    }

    /// ⛔ Without this, `packsInUse` passes as `{ _ in MethodCatalog.builtIn }` —
    /// which answers every question the test above asks and none of the ones the
    /// function exists for.
    @Test("A chosen pack reaches the sweep, and an unchosen one does not")
    func packsInUseCarriesAChosenPack() throws {
        let other = try #require(
            MethodCatalog.builtIn.first { $0.id != MethodCatalog.defaultPackID })
        var chooser = Repo(path: "/x", nameWithOwner: "o/r", displayName: "r")
        chooser.methodID = other.id

        let packs = PreflightService.packsInUse([chooser])
        #expect(packs.contains { $0.id == other.id }, "a chosen pack must be swept")
        #expect(packs.count == 2, "the default plus the chosen one, not the whole catalogue")
        #expect(packs.map(\.id) == packs.map(\.id).sorted(), "order is stable, so rows do not move")
    }

    // MARK: - The key that must not move

    @Test("A seed with no key keeps the exact id it had before methods existed")
    func historicalSeedKeyIsUnchanged() {
        // ⛔ `apply` passes `fix.id` as the card's `idempotencyKey`, and cards
        // seeded by the labels check are already in databases in the field under
        // this exact string. Changing how it is computed would let a second,
        // identical card be created for a finding that had already been seeded.
        let repoID = UUID()
        let fix = CheckFix.seedCard(
            repoID: repoID, title: "Decide this repository's label taxonomy",
            story: UserStory(role: "r", want: "w", benefit: "b"), key: nil
        )
        #expect(fix.id == "seedCard:\(repoID):Decide this repository's label taxonomy")
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd ElliotKit && swift test --filter PreflightMethodTests`

Expected: FAIL at compile time — `error: extra argument 'key' in call` at `CheckFix.seedCard(…)`, `error: extra argument 'packs' in call` at `globalChecks`, and `error: type 'PreflightService' has no member 'probeRefusal'` / `'requiredSkills'` / `'profileHint'` / `'packsInUse'` / `'projectResults'`.

⚠️ Before Step 3, also run the whole suite once (`swift test`) and note it green — Step 3 changes an existing enum case's payload, and the six pre-existing call sites must be repaired in the same commit or `swift build` never completes.

- [ ] **Step 3: Write the minimal implementation**

**(a) `PreflightService.swift:47` — the case, and why it grew a field:**

```swift
    /// Put a card in Backlog describing work someone should look at.
    ///
    /// `key` is this fix's identity, and `nil` means *derive it from the title*,
    /// which is what it did before methods existed. Both spellings are needed
    /// and neither is a default anyone should change:
    ///
    /// - ⛔ The labels seed passes `nil` and must keep passing it. `apply` hands
    ///   `fix.id` to `createCard(idempotencyKey:)`, so this string is already in
    ///   databases in the field; recomputing it would let a second identical
    ///   card be created for a finding that had already been seeded.
    /// - A project requirement passes `MethodPack.idempotencyKey(for:in:)`,
    ///   which is `"method:<repoID>:<packID>:req:<reqID>"` — keyed on *what it
    ///   is about* rather than on what it says, so rewording a requirement's
    ///   title does not produce a duplicate card, **and carrying the repository**,
    ///   because `card_on_idempotencyKey` is unique board-wide.
    case seedCard(repoID: UUID, title: String, story: UserStory, key: String?)
```

**(b) `:62-69` — `id`:**

```swift
    public var id: String {
        switch self {
        case .createLabels(let repoID, _, let labels):
            "createLabels:\(repoID):\(labels.map(\.name).joined(separator: ","))"
        case .seedCard(let repoID, let title, _, let key):
            key ?? "seedCard:\(repoID):\(title)"
        }
    }
```

**(c) `:77-81` — `repoID`:**

```swift
        case .createLabels(let repoID, _, _), .seedCard(let repoID, _, _, _): repoID
```

**(d) `:416-430` — the labels seed keeps its historical key:** append `key: nil` as the last argument of that `.seedCard(…)`, with the comment

```swift
                    // ⛔ `nil`, not a key of its own: this fix's id is already
                    // the idempotency key of cards in the field.
                    key: nil
```

**(e) `:522` — `apply`'s binding:**

```swift
        case .seedCard(_, let title, let story, _):
```

**(f) `:136` — `globalChecks` takes the packs in use, and `:184-189` becomes a loop:**

```swift
    /// - Parameter packs: the methods this machine's repositories actually run.
    ///   A plugin check per pack, rather than one hardcoded name — which is what
    ///   made "the method Elliot drives" a property of the build instead of a
    ///   property of the repository.
    public func globalChecks(
        layout: RepoTreeLayout = .portfolio, packs: [MethodPack]
    ) async -> [CheckResult] {
```

```swift
        for pack in packs {
            // ⛔ `nil` means this method is not a Claude Code plugin at all —
            // plain plan mode is the case — and the check is **skipped**, never
            // failed. A method that needs no plugin must not read as a method
            // whose plugin is missing: that is a red row for a correct setup,
            // and a red row nobody can clear is a red row people learn to skim.
            //
            // ⚠️ It also silently skips a pack whose plugin was never
            // *established* — GSD's and BMAD's `nil`s. That is a real gap in the
            // field's shape, recorded in `MethodCatalogTests.unmeasuredPluginsAreNamed`
            // and on this plan's human-decision list.
            guard let plugin = pack.pluginName else { continue }
            // ⚠️ The id is now `plugin.<pack.id>`, so the default pack's row
            // moves from `plugin.aiMigrationKit` to `plugin.ai-migration-kit`.
            // Nothing reads it, and the change is deliberate.
            results.append(pluginCheck(
                id: "plugin.\(pack.id)",
                title: "\(plugin) skills",
                plugin: plugin,
                required: Self.requiredSkills(of: pack)
            ))
        }
        results.append(pluginCheck(
            id: "plugin.superpowers",
            title: "superpowers skills",
            plugin: "superpowers",
            required: ["using-git-worktrees", "test-driven-development"],
            statusWhenMissing: .warn
        ))
```

**(g) the four new statics, next to `isBlocking`:**

```swift
    /// The one path both the profile check and its hint name.
    static let profilePath = ".claude/skills/repo-profile.md"

    /// The distinct methods a machine's repositories run, plus the default.
    ///
    /// The default is always in, even for an empty list: `globalChecks` runs at
    /// launch, before the repository table has been read, and a plugin check
    /// that silently disappeared on a fresh install would be "nobody looked"
    /// wearing a pass — `isBlocking([])`'s lesson, one screen over.
    ///
    /// `.unknown` contributes nothing. It has no pack, so it names no plugin;
    /// `repoChecks` fails it per repository, which is where the reader can act.
    public static func packsInUse(_ repos: [Repo]) -> [MethodPack] {
        var byID: [String: MethodPack] = [:]
        if case .unset(let fallback) = MethodCatalog.resolve(nil) { byID[fallback.id] = fallback }
        for repo in repos {
            switch repo.method {
            case .unset(let pack), .chosen(let pack): byID[pack.id] = pack
            case .unknown: continue
            }
        }
        return byID.values.sorted { $0.id < $1.id }
    }

    /// The plugin skills this pack dispatches, read off its own step commands.
    ///
    /// Derived rather than declared, because `MethodPack` has no field for it
    /// and inventing one would put the same list in two places. A command of the
    /// shape `/<plugin>:<skill>` names a `SKILL.md` that must exist; anything
    /// else — GSD's `/gsd-plan-phase`, Spec Kit's `/speckit.specify` — names a
    /// command, and there is no skill directory to look for.
    ///
    /// **Sorted**, because `steps` is a dictionary and has no order: an unsorted
    /// list would make the check's own detail string reshuffle between sweeps,
    /// which reads as something changing. Alphabetical also happens to be the
    /// order the hardcoded list had, so the default pack's detail is unchanged
    /// byte for byte.
    public static func requiredSkills(of pack: MethodPack) -> [String] {
        guard let plugin = pack.pluginName else { return [] }
        let prefix = "/\(plugin):"
        return pack.steps.values
            .compactMap {
                $0.command.hasPrefix(prefix) ? String($0.command.dropFirst(prefix.count)) : nil
            }
            .sorted()
    }

    /// How to get a repo profile, in the resolved method's own words.
    public static func profileHint(_ pack: MethodPack?) -> String {
        guard let plugin = pack?.pluginName else {
            return "Write \(profilePath) by hand — this method installs no plugin that writes it."
        }
        return "Run /\(plugin):get-repo-profile in this repo, or write \(profilePath) by hand."
    }
```

**(h) the project-requirement statics, also next to `isBlocking`:**

```swift
    /// The probe, the decision and the refusal, in one place a test can drive.
    ///
    /// ⛔ Extracted rather than inlined into `repoChecks`, and not for tidiness:
    /// `repoChecks` returns early on `guard isRepo` (`:284`), which covers every
    /// case `ArtifactProbe` throws `.unreadable` for, so from inside `repoChecks`
    /// the `catch` is reachable **only** through malformed pack evidence — which
    /// no catalogue pack has. Left inline, the refusal arm could be deleted with
    /// every test still green. `PreflightMethodTests.malformedPackEvidenceReachesTheRefusal`
    /// drives this function with a hand-built pack;
    /// `missingArtefactWarnsAndDoesNotBlock` drives `repoChecks` end to end, so
    /// the two together also catch `repoChecks` ceasing to call it.
    public static func projectResults(repo: Repo, pack: MethodPack) async -> [CheckResult] {
        guard !pack.projectRequirements.isEmpty else { return [] }
        do {
            let satisfied = try ArtifactProbe(repoRoot: repo.path)
                .evaluate(pack.projectRequirements.map(\.evidence))
            return projectChecks(repo: repo, pack: pack, satisfied: satisfied)
        } catch {
            return [probeRefusal(pack: pack, repo: repo, error: error)]
        }
    }

    /// One `.warn` per missing project artefact — **never a `.fail`**.
    ///
    /// ⛔ Since #249 a `.fail` blocks every drag in that repository. A repository
    /// without a PRD, a constitution or a roadmap still works, and freezing its
    /// board over a file it has every right not to have would be absurd. The two
    /// verdicts are one character apart and only one of them is reversible by a
    /// reader, so the distinction is named here rather than left to the caller.
    ///
    /// `static` and pure: what the screen *says* is assertable without a disk.
    public static func projectChecks(
        repo: Repo, pack: MethodPack, satisfied: [MethodPack.Evidence: Bool]
    ) -> [CheckResult] {
        pack.projectGaps(satisfied: satisfied).map { requirement in
            CheckResult(
                id: "method.\(pack.id).\(requirement.id)",
                title: requirement.title,
                status: .warn,
                detail: "\(pack.displayName) expects \(sentence(requirement.evidence)); "
                    + "it is not there.",
                command: command(requirement.evidence, in: repo.path),
                fixHint: requirement.remedy,
                fixes: seedFix(requirement, pack: pack, repoID: repo.id)
            )
        }
    }

    /// "I could not look" is not "there is nothing there".
    ///
    /// **One** warning naming the cause, never N false gaps — the singular
    /// return type is the guarantee, not a convention. It is the same duty
    /// `labelsCheck` discharges when `gh` does not answer, and it carries no fix
    /// for the same reason: a button here would act on a guess about a checkout
    /// nobody could open.
    public static func probeRefusal(
        pack: MethodPack, repo: Repo, error: any Error
    ) -> CheckResult {
        CheckResult(
            id: "method.\(pack.id).probe",
            title: "\(pack.displayName) project files",
            status: .warn,
            detail: "Could not be established: \(error.localizedDescription)",
            command: "ls -1 \(repo.path)",
            fixHint: "Check that \(repo.path) is readable, then press Check again."
        )
    }

    /// Exhaustive with no `default:`: wave 2's GitHub evidence cases must fail
    /// to compile here so someone writes the sentence rather than inheriting a
    /// wrong one.
    private static func sentence(_ evidence: MethodPack.Evidence) -> String {
        switch evidence {
        case .file(let path): "the file \(path)"
        case .anyFileUnder(let directory): "at least one file under \(directory)"
        }
    }

    private static func command(_ evidence: MethodPack.Evidence, in root: String) -> String {
        switch evidence {
        case .file(let path): "ls -l \(root)/\(path)"
        case .anyFileUnder(let directory): "find \(root)/\(directory) -type f"
        }
    }

    /// The card this gap offers to file, keyed through the one function that
    /// builds that key — see `MethodPack.idempotencyKey(for:in:)`, and the
    /// board-wide uniqueness of `card_on_idempotencyKey` it exists to survive.
    ///
    /// A note-mode draft has no `UserStory` and `.seedCard` demands one, so the
    /// honest answer is no button — the remedy is still in `fixHint`.
    /// `MethodCatalogTests` pins every built-in seed as a story, so this guard is
    /// a floor rather than a path.
    private static func seedFix(
        _ requirement: ProjectRequirement, pack: MethodPack, repoID: UUID
    ) -> [CheckFix] {
        guard let story = requirement.seed.story else { return [] }
        return [.seedCard(
            repoID: repoID,
            title: requirement.seed.title,
            story: story,
            key: pack.idempotencyKey(for: requirement, in: repoID)
        )]
    }
```

**(i) `:274-349` — `repoChecks`.** Insert the resolution after the `isMainCheckout` block, rework the profile block, and append the requirement checks after the labels check.

⛔ **The profile block replaces `:299-308`, which deletes the local `let profilePath`. Lines 310-323 survive and reference that name three times** (`git.isTracked(path: profilePath, …)`, the `ls-files` command string, the `git add` hint). Change all three to `Self.profilePath` in the same edit, or the file does not compile.

```swift
        // Which method this repository runs, in three values rather than two.
        // `.unknown` is the one that blocks: we do not know what to run, and
        // running some other method's commands unannounced is worse than
        // refusing — the silent substitution `MethodResolution` exists to stop.
        let pack: MethodPack?
        switch repo.method {
        case .unset(let chosen):
            pack = chosen
            results.append(CheckResult(
                id: "repo.method", title: "Method", status: .pass,
                // "Not chosen" and "chose the default" run the same commands and
                // are different facts: only one of them follows the default if
                // it ever moves.
                detail: "Not chosen — using \(chosen.displayName). \(chosen.summary)",
                fixHint: "Pick one on the Repositories page."
            ))
        case .chosen(let chosen):
            pack = chosen
            results.append(CheckResult(
                id: "repo.method", title: "Method", status: .pass,
                detail: "\(chosen.displayName). \(chosen.summary)"
            ))
        case .unknown(let id):
            pack = nil
            results.append(CheckResult(
                id: "repo.method", title: "Method", status: .fail,
                detail: "Set to \"\(id)\", which this build has no pack for. "
                    + "Nothing will be dragged here until it names a method Elliot knows.",
                fixHint: "Pick one of "
                    + MethodCatalog.builtIn.map(\.id).sorted().joined(separator: ", ")
                    + " on the Repositories page."
            ))
        }

        let profileURL = URL(fileURLWithPath: repo.path)
            .appendingPathComponent(Self.profilePath)
        let profileExists = FileManager.default.fileExists(atPath: profileURL.path)
        // `.fail` only when this method dispatches plugin skills: the profile is
        // the config *those* read at their preconditions step. A method that
        // dispatches none — GSD's `/gsd-plan-phase`, plain plan mode — has
        // nothing that opens the file, and freezing its board over an absence
        // that costs it nothing is #249's gate answering the wrong question.
        let dispatchesSkills = pack.map { !Self.requiredSkills(of: $0).isEmpty } ?? false
        results.append(CheckResult(
            id: "repo.profile", title: "Repo profile",
            status: profileExists ? .pass : (dispatchesSkills ? .fail : .warn),
            detail: profileExists
                ? Self.profilePath
                : "No \(Self.profilePath); the skills read it at their preconditions step.",
            command: "cat \(profileURL.path)",
            fixHint: profileExists ? nil : Self.profileHint(pack)
        ))
```

…and at the end of the method, after the labels check and before `return results`:

```swift
        // The method's project requirements, last: they are the only checks here
        // that depend on which method this repository chose, and an `.unknown`
        // one has no requirements to look for — reporting another pack's would
        // be the substitution the `.fail` above refuses.
        if let pack {
            results.append(contentsOf: await Self.projectResults(repo: repo, pack: pack))
        }

        return results
```

**(j) `AppModel.swift:679` — the one call site:**

```swift
            // The packs the registered repositories actually run, read from the
            // store rather than from `repos`: this runs inside `start()`, before
            // the repo observation has published anything, so `repos` is still
            // empty here. `packsInUse` folds the default in either way.
            let registered = (try? await store.repos()) ?? []
            globalChecks = await preflight.globalChecks(
                layout: layout, packs: PreflightService.packsInUse(registered))
```

**(k) the six existing `.seedCard(…)` constructions** — `PreflightTests.swift:50, 253, 273, 316` and `PreflightFixTests.swift:39, 66` — each gains `key: nil` as its last argument. No other change: they are asserting the historical id, which `nil` preserves.

- [ ] **Step 4: Run the test to verify it passes**

```bash
cd ElliotKit
swift test --filter PreflightMethodTests   # PASS — 13 tests
swift test --filter PreflightTests
swift test --filter PreflightFixTests
swift test                                  # whole suite, no failures
```

⚠️ Do not compare the suite total against a figure copied from `CLAUDE.md` — those numbers age (the file itself carries both `1418` and `1736` from different months). What matters is **no failures**.

⚠️ **This step changes an existing enum case's payload, which is the exact shape #171 hit twice with no checkout involved: two consecutive signal 11s, no failing test named.** If that happens, `rm -rf ElliotKit/.build` and run again before believing any of it — a failure that could not have happened is a stale binary, not a defect.

- [ ] **Step 5: Commit**

```bash
git rev-parse --abbrev-ref HEAD
git add ElliotKit/Sources/ElliotEngine/PreflightService.swift \
        ElliotKit/Sources/ElliotAppKit/AppModel.swift \
        ElliotKit/Tests/ElliotEngineTests/PreflightTests.swift \
        ElliotKit/Tests/ElliotEngineTests/PreflightMethodTests.swift \
        ElliotKit/Tests/ElliotAppKitTests/PreflightFixTests.swift
git commit -m "feat(engine,app): Preflight answers for the repository's own method"
```

---

### Task 7: The repository's own pack reaches the prompt

⚠️ **The spec says `RunScheduler` resolves the pack; measured, it cannot.** `RunScheduler` never builds a prompt — it reads the already-persisted `run.prompt` at `RunScheduler.swift:425` and hands it to `ClaudeInvocation`. The single production call site in the package is `BoardService.makeRun` (`BoardService.swift:183`), and a full `Repo` is already bound **nine** lines above it at `:174` for `cwd: repo.path`. So this task is one method in `BoardService`, with no plumbing at all — which is what the spec meant by *"already holds the `Repo` when it builds a run"*.

**Files:**
- Modify: `ElliotKit/Sources/ElliotEngine/BoardService.swift:20-38` (one more `BoardError` case), `:173-189` (`makeRun` reads `repo.method` instead of `MethodCatalog.resolve(nil)`)
- Test: `ElliotKit/Tests/ElliotEngineTests/MethodPromptTests.swift`

**Interfaces:**
- Consumes: `Repo.methodID` / `Repo.method` (Task 3 — the contract files them under `ElliotStore`; the type is `ElliotKit/Sources/ElliotModel/Repo.swift:7`, persisted through `ElliotStore/Records.swift`, and nothing here depends on which); `MethodCatalog.builtIn`; `MethodPack.steps`; `StepSpec.command`/`.arguments`; `SlashCommandBuilder.prompt(for:method:strategy:)` and `BoardError.unknownMethod(String)` from Task 4.
- Produces:
  - `BoardError.methodHasNoStep(method: String, kind: String)` — ⚠️ **not in the canonical type contract**, and needed because wave 1 ships a pack with no steps by design (*"a BMAD pack shipped in wave 1 can only carry project requirements, not steps"*). A repository set to it, dragging a card, is reachable on day one; without this the builder's stepless fallback would spawn `claude -p` with a bare skill name.
  - The guarantee that a run's prompt is built from **the repository's** pack, and that neither an unknown method nor a missing step is answered by another method's command.

- [ ] **Step 1: Write the failing test**

`ElliotKit/Tests/ElliotEngineTests/MethodPromptTests.swift`:

```swift
import ElliotModel
import ElliotProcess
import ElliotStore
import Foundation
import Testing

@testable import ElliotEngine

/// Records what the board asked for without spawning anything.
private actor RecordingLauncher: RunLaunching {
    private(set) var launched: [UUID] = []
    func launch(runID: UUID) async { launched.append(runID) }
    func cancel(runID: UUID) async {}
    func launchedRuns() -> [UUID] { launched }
}

private struct Fixture {
    var store: BoardStore
    var board: BoardService
    var launcher: RecordingLauncher
    var repo: Repo

    static func make(methodID: String? = nil) async throws -> Fixture {
        let store = try BoardStore.inMemory()
        let launcher = RecordingLauncher()
        let board = BoardService(store: store, launcher: launcher)
        var repo = Repo(
            path: "/tmp/repo-\(UUID().uuidString)",
            nameWithOwner: "phmatray/Elliot",
            displayName: "Elliot"
        )
        repo.methodID = methodID
        try await store.saveRepo(repo)
        return Fixture(store: store, board: board, launcher: launcher, repo: repo)
    }

    /// A card sitting in To Do with an issue on it — the one transition whose
    /// argument form is `.number` in every pack that has it.
    func filedCard() async throws -> Card {
        var card = try await board.createCard(repoID: repo.id, title: "Run log").card
        card.column = .todo
        card.issueNumber = 47
        try await store.saveCard(card)
        return card
    }
}

/// A built-in pack, other than the default, whose `implement-issue` step is a
/// *different* command **and takes a number**.
///
/// ⛔ Both halves matter. Without the command difference, a builder that ignored
/// its `method` argument entirely would still pass. Without
/// `arguments == .number`, the assertion `"\(expected) 47"` is a claim about a
/// tail shape this predicate never selected for — a pack whose step took
/// `.ideaThenLabels` would fail this test for a reason unrelated to the wiring.
private func contrastingPack(against base: MethodPack) -> MethodPack? {
    MethodCatalog.builtIn.first { pack in
        guard pack.id != base.id, let step = pack.steps[.implementIssue] else { return false }
        return step.arguments == .number && step.command != base.steps[.implementIssue]?.command
    }
}

@Suite("The repository's method decides the command")
struct MethodPromptTests {

    /// Wave 1's claim, measured one layer above `GoldenPromptTests`: a
    /// repository that never chose a method runs exactly what it ran before.
    @Test("A repository with no method chosen produces the shipped prompt")
    func unsetRepositoryIsUnchanged() async throws {
        let f = try await Fixture.make()
        let card = try await f.filedCard()

        let result = try await f.board.move(cardID: card.id, to: .inProgress, origin: .userDrag)
        guard case .moved(let runID?) = result else {
            Issue.record("expected a run, got \(result)")
            return
        }
        let run = try #require(try await f.store.run(id: runID))
        #expect(run.prompt == "/ai-migration-kit:implement-issue 47")
    }

    /// The point of the wave: the row decides. Asserted against the pack's own
    /// declared command rather than a literal, so this test measures the wiring
    /// and not the catalogue's wording.
    @Test("The repository's pack supplies the command")
    func chosenPackSuppliesTheCommand() async throws {
        guard case .unset(let base) = MethodCatalog.resolve(nil) else {
            Issue.record("MethodCatalog.resolve(nil) did not answer .unset with a pack")
            return
        }
        guard let other = contrastingPack(against: base) else {
            // ⚠️ Wave 1's catalogue may genuinely contain no such pack — GSD and
            // Spec Kit both declare only `.createIssue`. Say so rather than pass
            // in silence, so the gap is visible the day it can be closed.
            Issue.record(
                "no built-in pack declares a different .number implement-issue step; "
                    + "the repository-decides claim is untested at this transition")
            return
        }
        let expected = try #require(other.steps[.implementIssue]).command

        let f = try await Fixture.make(methodID: other.id)
        let card = try await f.filedCard()

        let result = try await f.board.move(cardID: card.id, to: .inProgress, origin: .userDrag)
        guard case .moved(let runID?) = result else {
            Issue.record("expected a run, got \(result)")
            return
        }
        let run = try #require(try await f.store.run(id: runID))
        #expect(run.prompt == "\(expected) 47")
        #expect(!run.prompt.contains("ai-migration-kit"))
    }

    /// ⛔ The refusal that matters. A repository set to a method this build does
    /// not know has no commands, and running another method's inside it — at
    /// `bypassPermissions`, in a real checkout — is the silent substitution the
    /// three-valued `MethodResolution` exists to refuse. The card must not move
    /// either: `makeRun` runs before the move's transaction, so a throw leaves
    /// the board exactly as it was.
    @Test("An unknown method refuses the move and names the id")
    func unknownMethodRefuses() async throws {
        let f = try await Fixture.make(methodID: "no-such-method")
        let card = try await f.filedCard()

        do {
            let result = try await f.board.move(cardID: card.id, to: .inProgress, origin: .userDrag)
            Issue.record("the move was allowed with an unknown method: \(result)")
        } catch let error as BoardError {
            #expect(
                error.errorDescription?.contains("no-such-method") == true,
                "the refusal did not name the method: \(error.errorDescription ?? "nil")"
            )
        } catch {
            Issue.record("expected a BoardError, got \(error)")
        }

        #expect(try await f.store.card(id: card.id)?.column == .todo)
        #expect(await f.launcher.launchedRuns().isEmpty)
    }

    /// A pack may declare no step for a kind — the catalogue ships one that
    /// declares none at all. The builder stays total and answers with the bare
    /// skill name; the *board* is what must refuse, because it is the thing that
    /// can decline to move a card.
    @Test("A pack with no step for the transition refuses rather than borrowing one")
    func steplessPackRefuses() async throws {
        guard let stepless = MethodCatalog.builtIn.first(where: { $0.steps[.implementIssue] == nil })
        else {
            // ⛔ Not `#expect(builtIn.allSatisfy { … != nil })`, which is true by
            // construction here and can never fail — the previous draft's
            // fallback said it was refusing to pass in silence while doing
            // exactly that, leaving `BoardError.methodHasNoStep` shipped with
            // zero coverage.
            Issue.record(
                "no built-in pack is stepless at .implementIssue; "
                    + "BoardError.methodHasNoStep is unreachable and untested")
            return
        }

        let f = try await Fixture.make(methodID: stepless.id)
        let card = try await f.filedCard()

        do {
            let result = try await f.board.move(cardID: card.id, to: .inProgress, origin: .userDrag)
            Issue.record("the move was allowed with no step to run: \(result)")
        } catch let error as BoardError {
            #expect(error.errorDescription?.contains(stepless.displayName) == true)
        } catch {
            Issue.record("expected a BoardError, got \(error)")
        }

        #expect(try await f.store.card(id: card.id)?.column == .todo)
        #expect(await f.launcher.launchedRuns().isEmpty)
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd ElliotKit && swift test --filter MethodPromptTests`

Expected: FAIL. `makeRun` still resolves `MethodCatalog.resolve(nil)`, so the repository's own field is never read:

```
✘ "An unknown method refuses the move and names the id" — the move was allowed with an unknown method: moved(runID: Optional(…))
✘ "A pack with no step for the transition refuses rather than borrowing one" — the move was allowed with no step to run
```

(`unsetRepositoryIsUnchanged` passes already — that is Task 4's interim doing its job, and it gates nothing on its own. `chosenPackSuppliesTheCommand` records an issue rather than failing if the catalogue has no contrasting pack.)

- [ ] **Step 3: Write the minimal implementation**

In `ElliotKit/Sources/ElliotEngine/BoardService.swift`, add the second case after `unknownMethod`:

```swift
    case unknownMethod(String)
    case methodHasNoStep(method: String, kind: String)
```

and its arm:

```swift
        case .methodHasNoStep(let method, let kind):
            "The \(method) method declares no \(kind) step, so this move has nothing to run."
```

Then replace the interim block in `makeRun` — the `switch MethodCatalog.resolve(nil)` and its comment — with the row's own resolution:

```swift
    private func makeRun(for action: TriggerAction, card: Card) async throws -> SkillRun {
        guard let repo = try await store.repo(id: card.repoID) else {
            throw BoardError.repoNotFound(card.repoID)
        }
        // Read off the row this method already loaded, for the same reason
        // `repoPreflight` is: the funnel every move passes through gets it with
        // no new collaborator, so a drag and `board_move_card` cannot answer
        // differently.
        //
        // ⛔ Both refusals fail closed, and they run *before* the transaction at
        // the call site (`commitMove`, `:143`), so a refused move leaves the card
        // where it was. A repository whose method the catalogue does not know has
        // no commands, and a pack that declares no step for this kind has none
        // either — running another method's would be the silent substitution
        // `MethodResolution` was made three-valued to refuse, at
        // `bypassPermissions` inside a real checkout.
        let method: MethodPack
        switch repo.method {
        case .unset(let pack), .chosen(let pack): method = pack
        case .unknown(let id): throw BoardError.unknownMethod(id)
        }
        guard method.steps[action.kind] != nil else {
            throw BoardError.methodHasNoStep(
                method: method.displayName, kind: action.kind.skillName
            )
        }
        let runID = UUID()
        return SkillRun(
            id: runID,
            cardID: card.id,
            repoID: card.repoID,
            kind: action.kind,
            prompt: SlashCommandBuilder.prompt(for: action, method: method),
            cwd: repo.path,
            logPath: StoreLocation.runLogURL(runID: runID).path,
            stderrPath: StoreLocation.runStderrURL(runID: runID).path,
            createdAt: Date()
        )
    }
```

- [ ] **Step 4: Run the test to verify it passes**

```bash
cd ElliotKit
swift test --filter MethodPromptTests   # PASS — 4 tests
swift test --filter BoardServiceTests   # its prompt literals are the unset path
swift test --filter EndToEndTests
swift test --filter GoldenPromptTests
swift test
for i in 1 2 3 4 5; do swift test >/dev/null || echo "sample $i failed"; done
```

Expected: PASS, and **no existing engine test edited** — which is the wave-1 refactor claim measured one layer above `GoldenPromptTests`: every registered repository has `methodID == nil`, resolves `.unset`, and runs what it ran before.

- [ ] **Step 5: Commit**

```bash
git rev-parse --abbrev-ref HEAD
git add ElliotKit/Sources/ElliotEngine/BoardService.swift \
        ElliotKit/Tests/ElliotEngineTests/MethodPromptTests.swift
git commit -m "feat(engine): a run is built from the repository's own method pack"
```

---

### Task 8: The method picker on the Repositories page

**Files:**
- Modify: `ElliotKit/Sources/ElliotAppKit/RepositoriesView.swift:385-398` (the row's trailing column gains the picker), `:508`+ (the status-vocabulary section gains three statics)
- Modify: `ElliotKit/Sources/ElliotAppKit/AppModel.swift:2037-2041` (`setRepoMethod`, beside `setRepoEnabled`)
- Test: `ElliotKit/Tests/ElliotAppKitTests/RepositoriesMethodTests.swift`

**Interfaces:**
- Consumes: `MethodCatalog.builtIn` · `.resolve(_:)` · `.defaultPackID`; `MethodResolution`; `MethodPack.displayName`/`summary`/`id`; `Repo.methodID`/`Repo.method`; `PreflightService.repoChecks(_:)` (Task 6); `AppModel.record(_:for:)` (private, same type).
- Produces: `AppModel.setRepoMethod(_ repo: Repo, methodID: String?) async`; `RepositoriesView.unsetMethodLabel()`, `.unknownMethodLabel(_:)`, `.methodHelp(_:)`.
- ⚠️ **This task assumes the catalogue ships at least two packs.** `setRepoMethodWritesThrough` does `#require(MethodCatalog.builtIn.first { $0.id != MethodCatalog.defaultPackID })` and fails outright if it does not — an honest failure rather than a silent skip, but an unstated dependency on Task 2's contents unless it is written down, which is what this bullet is.

⛔ **`swift test` cannot see this task's actual subject.** The picker is a layout change on the page that has already cost this repository three merges (#47, #50, #52, #53). Steps 1–4 pin what the page *says* and what the model *writes*; **Step 5 is not optional and is not a formality** — it is the only step that establishes the row renders, sits somewhere sane, and writes through.

- [ ] **Step 1: Write the failing test**

`ElliotKit/Tests/ElliotAppKitTests/RepositoriesMethodTests.swift`:

```swift
import ElliotModel
import ElliotStore
import Foundation
import TestSupport
import Testing

@testable import ElliotAppKit

/// The one control on the Repositories page that changes what a drag will
/// *execute*, and the sentences it says about the three states a method can be
/// in.
///
/// `nonisolated static` vocabulary, read here rather than rendered: what the
/// page *says* is assertable, where its row sits on screen still is not — which
/// is what Step 5's on-screen pass is for.
@Suite("Repositories method")
struct RepositoriesMethodTests {

    @Test("Unset, chosen and unknown do not read alike")
    func theThreeStatesAreDistinguishable() throws {
        let pack = try #require(MethodCatalog.builtIn.first)
        let unset = RepositoriesView.methodHelp(.unset(pack))
        let chosen = RepositoriesView.methodHelp(.chosen(pack))
        let unknown = RepositoriesView.methodHelp(.unknown("no-such-method"))

        // "Never chosen" and "chose this one" run the same commands today and
        // are different facts: only one of them follows the default if it moves.
        #expect(unset != chosen)
        #expect(unset.lowercased().contains("never chosen"))
        #expect(chosen.contains(pack.displayName))

        // An id this build has no pack for must be named, not hidden. A blank
        // menu reads as "no method", which is the silent substitution
        // `MethodResolution.unknown` exists to stop.
        #expect(unknown.contains("no-such-method"))
        #expect(unknown != unset)
        #expect(unknown != chosen)
    }

    @Test("The unset row names the default it resolves to, and says it is a default")
    func unsetRowNamesItsFallback() throws {
        let label = RepositoriesView.unsetMethodLabel()
        guard case .unset(let fallback) = MethodCatalog.resolve(nil) else {
            Issue.record("resolve(nil) must be .unset")
            return
        }
        #expect(label.contains(fallback.displayName))
        #expect(label.lowercased().contains("default"))
        // And it is not the same string as picking that pack on purpose, or the
        // menu would show two rows a reader cannot tell apart.
        #expect(label != fallback.displayName)
    }

    @Test("An unknown id is offered as leaveable, and does not read like a choice")
    func unknownRowIsMarked() {
        let label = RepositoriesView.unknownMethodLabel("gsd-v2")
        #expect(label.contains("gsd-v2"))
        #expect(label != "gsd-v2")
        #expect(!MethodCatalog.builtIn.map(\.displayName).contains(label))
    }

    // MARK: - The write

    @MainActor
    @Test("Choosing a method writes it, and choosing none clears it")
    func setRepoMethodWritesThrough() async throws {
        _ = TestHome.root
        let store = try BoardStore.inMemory()
        let repo = Repo(
            path: "/tmp/sandbox", nameWithOwner: "phmatray/sandbox", displayName: "sandbox")
        try await store.saveRepo(repo)

        let model = AppModel()
        model.testOnlySeedStore(store)
        model.testOnlySeed(repos: [repo], cards: [])

        // ⚠️ Depends on the catalogue shipping a second pack — see the task's
        // Interfaces note. A hard failure here means Task 2's contents changed.
        let pack = try #require(
            MethodCatalog.builtIn.first { $0.id != MethodCatalog.defaultPackID })
        await model.setRepoMethod(repo, methodID: pack.id)
        #expect(try await store.repos().first?.methodID == pack.id)

        // Back to unset. `nil` is a state and not a missing value, so the menu
        // must be able to return to it — a control you can leave but not come
        // back to is a one-way door on a setting that decides what runs.
        var chosen = try #require(try await store.repos().first)
        await model.setRepoMethod(chosen, methodID: nil)
        chosen = try #require(try await store.repos().first)
        #expect(chosen.methodID == nil)
        if case .unset = chosen.method {} else {
            Issue.record("a cleared methodID must resolve as .unset")
        }
    }

    @MainActor
    @Test("A write that lands on an unknown id is still stored, and still resolves as unknown")
    func unknownIdSurvivesTheRoundTrip() async throws {
        // Not reachable from the menu, but reachable from `.elliot/settings.json`
        // in wave 3 and from a pack that was removed between builds. The store
        // must not quietly normalise it: Preflight's `.fail` is what tells the
        // reader, and it can only fire on a value that survived.
        _ = TestHome.root
        let store = try BoardStore.inMemory()
        let repo = Repo(path: "/tmp/sandbox2", nameWithOwner: "phmatray/s2", displayName: "s2")
        try await store.saveRepo(repo)

        let model = AppModel()
        model.testOnlySeedStore(store)
        model.testOnlySeed(repos: [repo], cards: [])

        await model.setRepoMethod(repo, methodID: "no-such-method")
        let stored = try #require(try await store.repos().first)
        #expect(stored.methodID == "no-such-method")
        if case .unknown(let id) = stored.method {
            #expect(id == "no-such-method")
        } else {
            Issue.record("an id the catalogue does not know must resolve as .unknown")
        }
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd ElliotKit && swift test --filter RepositoriesMethodTests`

Expected: FAIL at compile time — `error: type 'RepositoriesView' has no member 'methodHelp'` (likewise `unsetMethodLabel`, `unknownMethodLabel`) and `error: value of type 'AppModel' has no member 'setRepoMethod'`.

- [ ] **Step 3: Write the minimal implementation**

**(a) `AppModel.swift`, immediately after `setRepoEnabled` at `:2041`:**

```swift
    /// Chooses the method a repository runs — the one setting on that page that
    /// changes what a drag *executes*.
    ///
    /// It re-runs this repository's checks rather than only saving, and that is
    /// the point rather than tidiness: the project-requirement warnings, the
    /// plugin the profile hint names and — for an id no pack answers — the
    /// `.fail` that blocks the board are all functions of the value just
    /// written. Leaving them until the next sweep would show the previous
    /// method's verdict beside the new method's name, which is a screen lying
    /// about what will happen on the next drag.
    ///
    /// Only **this** repository's, through `record`, exactly as `apply(_ fix:)`
    /// does: pressing one menu item must not start a full-board sweep at ~6
    /// subprocesses per repository with no progress and no re-entrancy guard.
    ///
    /// The save is not `try?`. If it is lost the menu shows a method the store
    /// does not hold, and the next drag runs the old one.
    public func setRepoMethod(_ repo: Repo, methodID: String?) async {
        guard let store else {
            status = "Elliot is still starting; try again in a moment."
            return
        }
        var updated = repo
        updated.methodID = methodID
        do {
            try await store.saveRepo(updated)
        } catch {
            status = "Could not set the method for \(updated.displayName): "
                + error.localizedDescription
            return
        }

        guard let toolConfig else { return }
        let preflight = PreflightService(
            environment: LoginShellEnvironment(
                variables: toolConfig.environment, capturedVia: "session"
            ),
            config: toolConfig
        )
        // `updated`, never `repo`: `record` writes the verdict back onto the row
        // it is handed, and handing it the pre-write value would save the old
        // `methodID` over the one just chosen.
        await record(await preflight.repoChecks(updated), for: updated)
    }
```

**(b) `RepositoriesView.swift:385` — the row's trailing column:**

```swift
            VStack(alignment: .trailing, spacing: 4) {
                // Above the actions, because it is not one: it is the setting
                // that decides what those actions will run. `boardButton` keeps
                // its place directly beneath, as the only non-repair button.
                methodPicker(row)

                boardButton(row)

                // One button per legal fix, and nothing here deletes: `RepoFix`
                // has no `.delete` case, deliberately.
                ForEach(row.fixes, id: \.self) { fix in
                    Button(fix.label) { Task { await model.apply(fix) } }
                        .controlSize(.small)
                        .disabled(model.isReconciling)
                        .help(explain(fix, in: row))
                }
            }
```

**(c) the picker itself, next to `boardButton` at `:420`:**

```swift
    /// The method this repository runs — or nothing at all for a row that is not
    /// registered.
    ///
    /// Nothing rather than a disabled control: an unregistered clone has no
    /// `Repo` to write to, and a greyed picker beside it would name a setting
    /// that does not exist yet — the confident-looking no-op this file keeps
    /// refusing to ship. The row's own `Register` fix is the way in.
    ///
    /// ⚠️ **The gate is registration — `repoID != nil` — and that is deliberate,
    /// not the mistake `RepoRow.showsBoardFigures` warns about.** That property
    /// says *"Not `repoID != nil`"* because *figures* are meaningless for an
    /// out-of-scope row; but the *cards* of a registered fork are still on the
    /// board and still draggable, which is exactly `boardAction`'s own rule —
    /// *"Registration is the gate, not `issue == .ok`"*. A registered
    /// `.outOfScope` row therefore gets a picker on purpose: a repository whose
    /// cards can run something must be able to say what.
    ///
    /// It reads the registration out of `model.repos` rather than off the
    /// `RepoRow`, because a row is a *reconciliation* of GitHub, the disk and
    /// the registration and carries no `methodID`. `repoID` is the join.
    @ViewBuilder
    private func methodPicker(_ row: RepoRow) -> some View {
        if let repoID = row.repoID, let repo = model.repos.first(where: { $0.id == repoID }) {
            Picker(
                "Method",
                selection: Binding(
                    get: { repo.methodID },
                    set: { value in Task { await model.setRepoMethod(repo, methodID: value) } }
                )
            ) {
                // `nil` is its own row, and it is **not** the default pack's row.
                // Collapsing the two would make a repository that never chose
                // look like one that did, and it would stop following the
                // default if the default ever moved.
                Text(Self.unsetMethodLabel()).tag(String?.none)
                ForEach(MethodCatalog.builtIn) { pack in
                    Text(pack.displayName).tag(String?.some(pack.id))
                }
                // An id this build has no pack for still has to be visible and
                // still has to be leaveable. Without a row carrying this tag the
                // menu renders blank, which reads as "no method" — exactly the
                // silent substitution `MethodResolution.unknown` exists to stop,
                // restored by the view.
                if case .unknown(let id) = repo.method {
                    Text(Self.unknownMethodLabel(id)).tag(String?.some(id))
                }
            }
            .pickerStyle(.menu)
            .controlSize(.small)
            .labelsHidden()
            .frame(maxWidth: 190)
            // A sweep in flight is two writers on one checkout; changing what it
            // runs mid-sweep is the same hazard the fix buttons refuse.
            .disabled(model.isReconciling)
            .help(Self.methodHelp(repo.method))
            .accessibilityLabel("Method for \(row.nameWithOwner ?? row.id)")
        }
    }
```

**(d) the vocabulary, in the *Status vocabulary* section at `:508`:**

```swift
    /// The menu row for a repository that has never chosen.
    ///
    /// It names the pack it falls back to *and* says it is a fallback, because
    /// those are two facts and a reader deciding whether to choose needs both.
    nonisolated static func unsetMethodLabel() -> String {
        guard case .unset(let pack) = MethodCatalog.resolve(nil) else { return "Default" }
        return "Default — \(pack.displayName)"
    }

    /// The menu row for an id this build has no pack for.
    nonisolated static func unknownMethodLabel(_ id: String) -> String {
        "\(id) — not installed"
    }

    /// What choosing this method means, in one sentence.
    ///
    /// Exhaustive with no `default:`, for the reason `icon`/`tint`/`verdict`
    /// are: a fourth `MethodResolution` case must fail to compile here so
    /// someone writes its sentence instead of inheriting one that is wrong.
    nonisolated static func methodHelp(_ resolution: MethodResolution) -> String {
        switch resolution {
        case .unset(let pack):
            "Never chosen — dragging a card here runs \(pack.displayName). \(pack.summary)"
        case .chosen(let pack):
            "Dragging a card here runs \(pack.displayName). \(pack.summary)"
        case .unknown(let id):
            "Set to \"\(id)\", which this build has no pack for. Nothing can be dragged here "
                + "until it names a method Elliot knows."
        }
    }
```

- [ ] **Step 4: Run the test to verify it passes**

```bash
cd ElliotKit
swift test --filter RepositoriesMethodTests    # PASS — 5 tests
swift test
for i in 1 2 3 4; do swift test --filter ElliotAppKitTests; done
```

A single green run cannot detect an intermittent regression; that is how a defect failing 53 % of the time reached `main` past 21 single-sample merges.

- [ ] **Step 5: The on-screen pass — the only step that verifies this task's subject**

`swift test` has now proved what the page *says* and what the model *writes*. It has proved nothing about a control appearing on a row, and this is the page whose layout has been broken three times. Do this, in order.

⛔ **Repositories is not a window.** `ElliotWindows.all` is `["board"]` (`ElliotModel/ElliotWindows.swift:27-29`) and `ElliotApp.swift` declares exactly one scene; Repositories is a **`ConsoleFace`** unfolded *inside the board window*, opened by `Button("Repositories") { model.showConsoleFace(.repositories) }` (`ElliotApp.swift:329`). So `board_screenshot window: "repositories"` is refused as **`unknownWindow(known: ["board"])`** — not `window_not_open`. Everything below photographs `board`, and the row renders inside a height-constrained console region rather than a 900×700 window, which makes the trailing column's `.frame(maxWidth: 190)` a **larger** layout risk than a separate window would have been. That is the thing to look at hardest.

**5.1 — Build the bundle and a scratch board.** `ELLIOT_HOME` must be **short**: `sun_path` is capped at 104 bytes on macOS, and a deep scratch home silently costs the MCP socket while the app runs perfectly.

```bash
./Scripts/build-app.sh
rm -rf /tmp/elliot-check /tmp/elliot-sandbox
mkdir -p /tmp/elliot-check /tmp/elliot-sandbox
git -C /tmp/elliot-sandbox init -q --initial-branch=main
open -n --env ELLIOT_HOME=/tmp/elliot-check dist/Elliot.app   # creates the store
```

**5.2 — Quit it, seed a registered repository, relaunch.** Quit from the Dock or `⌘Q`; the store must not be open while `sqlite3` writes.

⛔ `Repo.id` is a `UUID`, not free text. A literal like `'sandbox'` starts the app, paints its chrome, and sits on **"Still starting"** for ever while the status bar reads **"Ready."** — the repo observation's `catch` swallows the decode error with no banner.

```bash
RID=$(uuidgen)
sqlite3 /tmp/elliot-check/elliot.sqlite "INSERT INTO repo
  (id,path,nameWithOwner,defaultBranch,displayName,permissionMode,extraAllowedTools,isEnabled)
  VALUES ('$RID','/tmp/elliot-sandbox','phmatray/elliot-sandbox','main','elliot-sandbox','bypassPermissions','[]',1);"
sqlite3 /tmp/elliot-check/elliot.sqlite "PRAGMA wal_checkpoint(TRUNCATE);"
open -n --env ELLIOT_HOME=/tmp/elliot-check dist/Elliot.app
```

The sandbox is a throwaway `git init`, never one of Philippe's checkouts. ⚠️ **And a seeded board is only safe once its repositories have actually been swept**: `PreflightState.notChecked` deliberately does *not* block, so between launch and the first sweep every transition is live. Wait for the row to read *"Repository blocked — see Preflight"* before touching a card.

**5.3 — ⚠️ A person must open View ▸ Repositories.** That menu item calls `showConsoleFace(.repositories)`, i.e. it needs a **click**, and an agent has none on this machine — `osascript … click at {x, y}` answered `-25200` and `-1719` in two separate sessions on the same day. Plan this as needing a person rather than discovering it here.

**5.4 — Photograph the board window, aimed at *this* Elliot.** The registered `elliot` MCP helper resolves its socket through the **default** `ELLIOT_HOME`, so it would hand back a perfectly good screenshot of the everyday board. Spawn a helper bound to the scratch home instead:

```bash
printf '%s\n' \
 '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"check","version":"1"}}}' \
 '{"jsonrpc":"2.0","method":"notifications/initialized"}' \
 '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"board_screenshot","arguments":{"window":"board"}}}' \
 | ELLIOT_HOME=/tmp/elliot-check dist/Elliot.app/Contents/MacOS/elliot-mcp
```

The reply carries `png_path` under `/tmp/elliot-check/screenshots/`. It needs no TCC grant — Elliot renders its own hierarchy in-process. **Read `not_included` in the reply before concluding anything is missing**; the toolbar renders blank in these captures, but this control is in the console region, not the toolbar.

Confirm on the picture, on the `elliot-sandbox` row:
- a menu control is present, reading **`Default — <the default pack's display name>`**;
- it sits in the row's trailing column, above **Open board**, and has not pushed the path, the verdict chip or the figures out of the row, nor forced the console region to clip;
- the header sentence, the section heading and the other rows are where they were.

**5.5 — Change it, and prove the change landed rather than merely looked right.** Open the menu, pick a different method, then:

```bash
sqlite3 /tmp/elliot-check/elliot.sqlite "SELECT displayName, methodID FROM repo;"
```

Expected: the id of the pack just chosen. Then re-run 5.4 and confirm the row shows that pack's display name, and that Preflight's section for this repository has gained the method's project-requirement warnings — **`.warn`, never `.fail`** — and that the board still opens and its cards still drag.

Set it back to **Default** and re-run the query: `methodID` must be empty. A setting you can leave but not return to is a one-way door on the value that decides what runs.

**5.6 — If anything looks wrong, take the control.** Build the same bundle from `main`, launch it against a second short home, open the same console face, and photograph the board again. A text diff of the two beats a squint, and it separates "this change broke the row" from "the row was always like that".

⚠️ Two traps while doing this. `./Scripts/build-app.sh` does `rm -rf` then `codesign --force --sign -`, so any Accessibility or Screen Recording grant on the bundle is dropped by the very command above — irrelevant to `board_screenshot`, fatal to any `osascript` fallback. And **three Elliots are routinely running** (two worktrees plus the main checkout): `screencapture -R <region>` returns whichever is frontmost there and will happily hand you another Elliot's board reading *"No repository yet"*. Target by window through the helper above, never by region.

- [ ] **Step 6: Commit**

```bash
git rev-parse --abbrev-ref HEAD
git add ElliotKit/Sources/ElliotAppKit/RepositoriesView.swift \
        ElliotKit/Sources/ElliotAppKit/AppModel.swift \
        ElliotKit/Tests/ElliotAppKitTests/RepositoriesMethodTests.swift
git commit -m "feat(app): choose a repository's method on the Repositories page"
```

Record in the commit body what Step 5 actually showed — the resolved `methodID` read back out of `sqlite3`, and that the Repositories row survived. A pull request body saying *"not verified on screen"* is how #84 shipped a launch crash that sat on `main` until #85 happened to look.

---

### Task 9: The seeded card actually reaches Backlog — once per repository, twice per sweep never

**Added by spec-coverage review, not present in any drafted cluster.** The spec states *"Seeded cards carry `idempotencyKey = …`, so the hourly sweep never seeds twice"* and no task tests it. Everything before this asserts the **fix's id**; nothing drives `PreflightService.apply` and watches a card appear, and nothing at all exercises the board-wide uniqueness of `card_on_idempotencyKey` that made the key wrong in the first place. Given that the key was the most expensive correction in this plan, an assertion about the string is not the same claim as an assertion about the card.

**Files:**
- Test: `ElliotKit/Tests/ElliotEngineTests/MethodSeedCardTests.swift` (no production change — if one turns out to be needed, that is the finding)

**Interfaces:**
- Consumes: `PreflightService.apply(_:repo:board:) -> CheckFixOutcome` (`:467`), `PreflightService.projectChecks(repo:pack:satisfied:)` (Task 6), `MethodPack.idempotencyKey(for:in:)` (Task 1), `BoardService.createCard(repoID:title:story:column:idempotencyKey:)`, `BoardStore.inMemory()`, `BoardStore.cards(repoID:column:limit:)`.
- Produces: no symbol. The claim that a project-requirement gap files exactly one card per repository, and that two repositories choosing the same method each get their own.

- [ ] **Step 1: Write the failing test**

`ElliotKit/Tests/ElliotEngineTests/MethodSeedCardTests.swift`:

```swift
import ElliotModel
import ElliotProcess
import ElliotStore
import Foundation
import Testing

@testable import ElliotEngine

private actor SilentLauncher: RunLaunching {
    func launch(runID: UUID) async {}
    func cancel(runID: UUID) async {}
}

/// The seeded card, end to end: the fix a gap carries, pressed, twice, in two
/// repositories.
///
/// ⛔ This is the only place the **board-wide** uniqueness of
/// `card_on_idempotencyKey` is exercised. `Migrations.swift:34-42` makes the
/// index unique on the key alone and says why; `BoardStore.card(idempotencyKey:)`
/// filters on the key alone; `BoardService.createCard`'s own doc says *"A key
/// that names a card in another repository still returns that card."* So a
/// repo-free key — which is what the spec wrote — makes the **second**
/// repository to choose a method find the first one's card and be seeded
/// nothing, while `CheckFixOutcome` reports `succeeded: true` and
/// *"Added a card to Backlog."* That is a success that did not happen, and it is
/// invisible to every assertion about the key *string*.
@Suite("A project requirement seeds one card per repository")
struct MethodSeedCardTests {

    private func board(_ store: BoardStore) -> BoardService {
        BoardService(store: store, launcher: SilentLauncher())
    }

    private func service() -> PreflightService {
        PreflightService(
            environment: LoginShellEnvironment(variables: [:], capturedVia: "test"),
            config: ToolConfig(
                claudePath: "/usr/bin/false", ghPath: "/usr/bin/false", gitPath: "/usr/bin/git",
                environment: ["PATH": "/usr/bin:/bin"]
            )
        )
    }

    private func pack() throws -> MethodPack {
        try #require(MethodCatalog.builtIn.first { !$0.projectRequirements.isEmpty })
    }

    /// The gap's own fix, taken from `projectChecks` rather than rebuilt here —
    /// a test that constructed its own `CheckFix` would be testing itself.
    private func seedFix(_ pack: MethodPack, _ repo: Repo) throws -> CheckFix {
        let satisfied: [MethodPack.Evidence: Bool] = [:]   // nothing on disk
        let checks = PreflightService.projectChecks(repo: repo, pack: pack, satisfied: satisfied)
        return try #require(checks.first?.fixes.first, "a gap must offer a card")
    }

    private func repository(_ name: String) -> Repo {
        Repo(path: "/tmp/\(name)", nameWithOwner: "phmatray/\(name)", displayName: name)
    }

    @Test("Pressing the fix files one card, and pressing it again files no second one")
    func seedsOnceForOneRepository() async throws {
        let store = try BoardStore.inMemory()
        let board = board(store)
        let pack = try pack()
        var repo = repository("alpha")
        repo.methodID = pack.id
        try await store.saveRepo(repo)

        let fix = try seedFix(pack, repo)
        let first = await service().apply(fix, repo: repo, board: board)
        #expect(first.succeeded)

        let afterFirst = try await store.cards(repoID: repo.id, column: .backlog)
        #expect(afterFirst.count == 1)
        #expect(afterFirst.first?.idempotencyKey == fix.id)
        // Backlog, where nothing runs: a fix that filed into `.todo` would start
        // an unattended agent the instant the button was pressed.
        #expect(afterFirst.first?.column == .backlog)

        // The button does not disappear after a press — the artefact is still
        // missing, so the same row is rebuilt with the same fix, and nothing
        // disables it during the await.
        let second = await service().apply(fix, repo: repo, board: board)
        #expect(second.succeeded)
        #expect(try await store.cards(repoID: repo.id, column: .backlog).count == 1)
    }

    /// ⛔ The test the key correction exists for. Delete the repository from
    /// `MethodPack.idempotencyKey(for:in:)` and this one goes red while every
    /// other assertion in the plan stays green.
    @Test("Two repositories choosing the same method each get their own card")
    func twoRepositoriesEachGetTheirOwnCard() async throws {
        let store = try BoardStore.inMemory()
        let board = board(store)
        let pack = try pack()

        var alpha = repository("alpha"); alpha.methodID = pack.id
        var beta = repository("beta"); beta.methodID = pack.id
        try await store.saveRepo(alpha)
        try await store.saveRepo(beta)

        let alphaFix = try seedFix(pack, alpha)
        let betaFix = try seedFix(pack, beta)
        #expect(alphaFix.id != betaFix.id, "the two repositories share one key")

        #expect(await service().apply(alphaFix, repo: alpha, board: board).succeeded)
        #expect(await service().apply(betaFix, repo: beta, board: board).succeeded)

        let inAlpha = try await store.cards(repoID: alpha.id, column: .backlog)
        let inBeta = try await store.cards(repoID: beta.id, column: .backlog)
        #expect(inAlpha.count == 1, "alpha was seeded \(inAlpha.count) cards")
        #expect(inBeta.count == 1, "beta was seeded \(inBeta.count) cards — the key lost the repo")
        #expect(inAlpha.first?.id != inBeta.first?.id)
    }

    @Test("The seeded card is a complete story, so it can be dragged the moment it lands")
    func theSeededCardIsDraggable() async throws {
        // `evaluateMove` refuses an incomplete story with `MoveBlock.incompleteStory`.
        // A card Preflight created and the board will not move is worse than no
        // card: the reader has to discover it by trying.
        let store = try BoardStore.inMemory()
        let board = board(store)
        let pack = try pack()
        var repo = repository("gamma"); repo.methodID = pack.id
        try await store.saveRepo(repo)

        _ = await service().apply(try seedFix(pack, repo), repo: repo, board: board)
        let card = try #require(try await store.cards(repoID: repo.id, column: .backlog).first)
        #expect(card.story?.isComplete == true)
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd ElliotKit && swift test --filter MethodSeedCardTests`

Expected on a tree where Task 6 landed **with the corrected key**: PASS immediately. That is the honest outcome for a coverage task, and it is not a reason to skip Steps 3–4.

⛔ **Prove the test can fail before trusting it.** Temporarily drop `\(repoID):` from `MethodPack.idempotencyKey(for:in:)`, re-run, and confirm `twoRepositoriesEachGetTheirOwnCard` goes red with *"beta was seeded 0 cards — the key lost the repo"*. Then restore the function. A coverage test that has never been seen to fail is a coverage test that measures nothing — the `CaretAnchorTests` lesson, one screen over.

- [ ] **Step 3: Write the minimal implementation**

None expected. If a real change *is* needed — `apply` reporting `succeeded: true` for a card it did not create, `createCard` answering another repository's row — that is a finding from this task and belongs in this commit with its own comment, not folded silently into Task 6.

- [ ] **Step 4: Run the test to verify it passes**

```bash
cd ElliotKit
swift test --filter MethodSeedCardTests   # PASS — 3 tests
swift test
for i in 1 2 3 4 5; do swift test >/dev/null || echo "sample $i failed"; done
```

- [ ] **Step 5: Commit**

```bash
git rev-parse --abbrev-ref HEAD
git add ElliotKit/Tests/ElliotEngineTests/MethodSeedCardTests.swift
git commit -m "test(engine): a project requirement seeds one card per repository"
```

---

## Spec coverage

Every wave-1 row of the spec's wave table and every entry of its Testing section, against the task that carries it.

| Spec item | Task |
|---|---|
| `MethodPack` type + built-in catalogue | 1, 2 |
| Per-repository choice (`Repo.methodID`) | 3 (field + migration), 8 (the picker that writes it) |
| `Evidence` + file-backed proof | 1 (`MethodPack.Evidence`, `projectGaps`), 5 (`ArtifactProbe`) |
| Project requirements → Preflight → `seedCard` | 6, and **9** for the card itself |
| Per-method slash names and argument forms | 4 (builder + `ArgumentForm`), 7 (the repository's own pack reaches it) |
| *Deleted in wave 1*: `SkillKind.slashName` | 4 |
| *Deleted in wave 1*: the two `"ai-migration-kit"` literals in `PreflightService` | 6 (the plugin check becomes a loop over packs; the profile hint becomes `profileHint(_:)`) |
| Path escapes refused **at catalogue validation**, as a test for wave 1 | 2 (`pathsStayInsideTheCheckout`); 5 adds the runtime second lock |
| `GoldenPromptTests` — byte-for-byte identity | 4 |
| `SlashCommandBuilderTests`, generalised to every `.number` pack | 4 (`everyNumberFormPutsTheNumberFirst`) |
| `MethodCatalogTests` | 2 |
| `ArtifactProbeTests` | 5 |
| `MethodPackTests` | 1 |
| `PreflightMethodTests` | 6 |
| The on-screen pass for the picker | 8, Step 5 |
| *"Seeded cards carry `idempotencyKey`, so the hourly sweep never seeds twice"* | **9 — the gap this review found** |

**The one gap, stated plainly.** Every drafted cluster asserted the *shape of the key string*; none pressed the button and looked for the card, and none put two repositories on one board. That is exactly the blind spot in which the spec's own key formula was wrong — the formula reads fine, and only a second repository reveals it. Task 9 closes it and, per Step 2, must be seen to fail before it is believed.

---

## What a human must decide — the plan cannot settle these

1. **`pluginName: nil` means two different things, and wave 1 ships both.** Spec Kit's `nil` is *"this method is not a plugin"* (measured). GSD's and BMAD's are *"nobody established whether it has one"*. Preflight skips both identically, so a genuinely required plugin check is silently absent for two of four packs. The canonical contract fixes the field as `String?`, so the plan records the distinction (`MethodCatalogTests.unmeasuredPluginsAreNamed`) instead of modelling it. **Decide**: measure GSD's and BMAD's plugins and fill the field in, or make the field three-valued in wave 2.
2. **Whether GSD's `/gsd-plan-phase` should be bound to Backlog → To Do at all.** Its documented argument is a *phase number* selected from `ROADMAP.md`; Elliot holds free text there and no number. The plan binds `.ideaThenLabels` because it is the only form that carries free text, and emits a `--label` tail GSD does not parse when a card names labels. That is a guess about a real command that starts an unattended agent.
3. **Whether BMAD should ship in wave 1 at all.** It carries zero steps by design, so every drag in a BMAD repository is refused by `BoardError.methodHasNoStep`. That is honest and it is also a method a reader can choose and then not use.
4. **`repo.profile` still `.fail`s — and therefore freezes the board — for any method whose steps name plugin skills.** The plan narrows the rule from "always" to "only skill-dispatching methods", which spares GSD, Spec Kit and plan mode. A future plugin-based method that does not read a profile would still be frozen. The real fix is making the profile a `ProjectRequirement` of the ai-migration-kit pack; that is wave-2 work.
5. **The picker appears on every *registered* row, including forks and out-of-scope ones.** The plan argues this from `boardAction`'s own rule (*registration is the gate*), deliberately not from `showsBoardFigures` (which excludes `.outOfScope`). If the product view is that an out-of-scope repository should not be able to choose a method, the gate changes.
6. **A user-visible check id moves: `plugin.aiMigrationKit` → `plugin.ai-migration-kit`.** Nothing in the tree reads it and no test asserts it, but a reader may recognise it.
7. **`[SkillKind: StepSpec]` encodes as an alternating JSON array, not an object.** Harmless in wave 1 (the catalogue is compiled in) and pinned by a test, but wave 3's `~/.elliot/methods/` loader must decide between conforming `SkillKind: CodingKeyRepresentable` and accepting a shape nobody can hand-write — and if any file is written in the current shape first, that becomes a migration.
