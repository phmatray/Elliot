# Auto-dev PR2 — The Value Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give a Backlog card the signals an unattended loop needs to choose it — effort, evidence and the moment they were read — and one pure function that turns those signals into a value that refuses to rank what nobody has measured.

**Architecture:** Three columns land on `card` (not a side table), because the criterion written above migration v8 says a datum produced *inside the funnel*, by a run that owns the card, is provenance and belongs on the row. `ElliotModel` gains `Grounding` and `CardValue` — pure, no clock, no I/O — with the angle/effort/grounding weights as data in the shape of `AnalysisAngle.briefing`. `AnalysisService.accept` stops dropping the signals the analysis already established, and a source-reading test freezes the rule that only `VerifiedOutcome.applied(to:)` decides a card field.

**Tech Stack:** Swift 6.3.1 · SwiftPM · swift-testing (`@Suite`/`@Test`/`#expect`/`#require`) · GRDB (SQLite) · macOS 15.

## Global Constraints

- Swift tools-version **6.3.1** — the patch is load-bearing, never `6.3`; `swiftLanguageModes: [.v6]`; deployment target macOS 15; strict concurrency, so every type crossing an isolation boundary is `Sendable`.
- Build: `cd ElliotKit && swift build` · Tests: `cd ElliotKit && swift test`.
- One suite: `cd ElliotKit && swift test --filter <TypeName>` — the filter matches the **type** name, never the `@Suite` display name.
- ⚠ A filter that matches nothing prints `warning: No matching test cases were run` and **exits 0**. Never conclude success from an exit code alone; read the line that says how many tests ran.
- Test framework is **swift-testing**, not XCTest.
- ⛔ Never run `swift format` over the tree. This code is formatted by hand: 4 spaces, 110 columns. Format the lines you write by hand so they match their neighbours.
- Every asynchronous wait in a test is **bounded**, through `withTimeout` in the `TestSupport` target. No assertion measures an absolute duration. No test sleeps a fixed interval.
- ⛔ Nothing in production code waits on `Process.waitUntilExit()`.
- Migrations are additive and shipped ones are frozen. The last registered is `v8_prStatus` (`ElliotKit/Sources/ElliotStore/Migrations.swift:138`). A renumbering ships its `RenamedMigration` **in the same diff** (`ElliotKit/Sources/ElliotStore/Migrations.swift:195-202`).
- Commits: Conventional Commits with the layer as scope — `feat(model|store|process|engine|ipc|mcp|app): subject`.
- Branch: `feat/<issue>-auto-dev-value`, where `<issue>` is the number of the GitHub issue this plan was filed under. The number comes first and is followed by `-`.
- ⚠ Several agent worktrees share this repository's `.git`. Re-read `git rev-parse --abbrev-ref HEAD` immediately **before** every commit and immediately **after** every push.
- A stale `.build` produces impossible failures (wrong enum values, link errors, SIGBUS). After any checkout that crosses commits: `rm -rf ElliotKit/.build` before believing a failure.
- One green run does not clear a suite. After a clean build, sample five times — it costs about eight seconds.

### Ordering prerequisite

PR1 lands before this plan starts, and never in parallel: the design's delivery order says so, and both PRs edit `ElliotKit/Sources/ElliotModel/` files that are **not** in the union-merge list (that list is `Package.swift`, `AppModel.swift`, `Migrations.swift`, `README.md` and test files). Nothing in Tasks 1–9 touches `RuleEngine.swift`. Task 10 is the one place this plan and PR1 can collide, and it opens by measuring whether PR1 already did the work.

### What this plan does not do

- **No wire change.** `Card` does not travel over IPC — `CardDTO(card:repoName:activeRunID:prStatus:)` (`ElliotKit/Sources/ElliotIPC/Protocol.swift:560`) is built *from* a `Card` and gains no field here. `elliotProtocolVersion` stays 6.
- **No screen work.** `EffortChip` (`ElliotKit/Sources/ElliotAppKit/AnalysisPanelView.swift:902-905`) renders `effort.rawValue` and will therefore print `unstated` for a story that never stated one. That is truthful; presentation belongs to PR5.
- **No prompt change.** `AnalysisPromptBuilder` still asks the model for `small | medium | large` (`ElliotKit/Sources/ElliotModel/AnalysisPromptBuilder.swift:84`). `.unstated` is what Elliot *records* when the model does not comply, never what it asks for.
- **No card-write-window test, in either direction — and that is a deferral, not an omission.** The design lists one under PR2: *"an appraisal written between a poller's read and its `saveCard` must not lose the column; a move committed between the appraisal's read and write must not lose the appraisal."* Both halves need a writer of `effort`/`evidence` to race against, and PR2 ships none: `AnalysisService.accept` writes the three fields **as it creates the card**, before any poller or move can be holding it, so there is no window to open. The writer arrives with the appraisal run in PR6, together with the ownership (`activeRun(cardID:)`) that is supposed to close the window — which is where the race becomes both real and testable. Task 9 makes the same call one field over, and says so: `appraisedAt` is deliberately outside the gate's protected set until PR6 widens it. **Carry this sentence into the pull request body**, or the next reader compares the design's test list against this branch and reads a gap.

---

## File Structure

**Created**

| File | Responsible for |
|---|---|
| `ElliotKit/Sources/ElliotModel/Grounding.swift` | The `Grounding` enum (three cases, a wire `code`, a one-sentence `summary`), its `of(evidence:)` constructor and its `valueWeight`. |
| `ElliotKit/Sources/ElliotModel/CardValue.swift` | `Signal`, `CardValue`, `CardValue.of(_:)`, `CardValue.rankable`, `CardValue.summary`, and `CardRanking.rank(_:)` — the only place a board is put in value order. |
| `ElliotKit/Tests/ElliotModelTests/GroundingTests.swift` | That the three groundings are distinguished on content, and that `StoryProposal.isGrounded` is a reader of `Grounding` rather than a second definition. |
| `ElliotKit/Tests/ElliotModelTests/CardValueTests.swift` | The three verdicts, the weights being data, and that neither `.ungradeable` nor `.neverAppraised` can enter a comparator. |
| `ElliotKit/Tests/ElliotEngineTests/CardValueFromProposalTests.swift` | The measured counterexample, end to end: an artifact citing `"   "` survives `isUsable`, is emptied by the harvester, and the accepted card falls to `.ungradeable`. |
| `ElliotKit/Tests/ElliotEngineTests/CardFieldWritersTests.swift` | The source-reading gate: no card field is assigned in `RunScheduler.swift`, `Reconciler.swift` or `PRWatcher.swift`. |

**Modified**

| File | Change |
|---|---|
| `ElliotKit/Sources/ElliotModel/StoryProposal.swift:29`, `:62` | The two decode defaults stop saying `"medium"`. |
| `ElliotKit/Sources/ElliotModel/StoryProposal.swift:93-101` | `Effort` gains `unstated`; `parse` folds the unrecognised onto it; `Effort.valueWeight` is added beside the enum. |
| `ElliotKit/Sources/ElliotModel/StoryProposal.swift:210-214` | `isGrounded` becomes a call into `Grounding`. |
| `ElliotKit/Sources/ElliotModel/Card.swift:60-98` | `Card` gains `effort: Effort?`, `evidence: [Evidence]?`, `appraisedAt: Date?`. |
| `ElliotKit/Sources/ElliotModel/AnalysisAngle.swift:124` | `AnalysisAngle.valueWeight`, `unlensedWeight`, `unlensedCode` — data, beside `briefing`. |
| `ElliotKit/Sources/ElliotStore/Migrations.swift:153-155` | Migration `v9_cardAppraisal`, additive, with its backfill. |
| `ElliotKit/Sources/ElliotStore/Migrations.swift:263` | `backfillCardAppraisalsSQL`, named so migration and test run the identical statement. |
| `ElliotKit/Sources/ElliotStore/BoardStore.swift:447` | `backfillCardAppraisals()`, the idempotent re-run. |
| `ElliotKit/Sources/ElliotEngine/BoardService.swift:200-238` | `createCard` gains `effort`, `evidence`, `appraisedAt`, all defaulted to `nil`. |
| `ElliotKit/Sources/ElliotEngine/AnalysisService.swift:207-217` | `accept` passes the proposal's effort, evidence and `createdAt`. |
| `ElliotKit/Tests/ElliotStoreTests/SchemaUpgradeTests.swift:73-102` | `rewindToV1` undoes v9 too: three `DROP COLUMN`, `'v9_cardAppraisal'` in the `IN` clause, `precondition(db.changesCount == 5)`. |
| `ElliotKit/Tests/ElliotStoreTests/SchemaUpgradeTests.swift` (new tests) | The migration over existing rows, and the optionality measurement. |
| `ElliotKit/Tests/ElliotModelTests/AnalysisModelTests.swift:24-30` | `effortParsing` expects `.unstated` where it expected `.medium`, plus the decode-default test. |
| `ElliotKit/Tests/ElliotModelTests/ProposalDecoderTests.swift:40` | `"enormous"` now parses to `.unstated`. |
| `ElliotKit/Tests/ElliotEngineTests/AnalysisServiceTests.swift:209` | A new test that acceptance carries the appraisal onto the row. |
| `ElliotKit/Sources/ElliotModel/PRStatus.swift:88`, `:323-324` — **Task 10 only** | `CIState.passing` carries `[String]`. |
| `ElliotKit/Sources/ElliotAppKit/PRStatusBlock.swift:111` — **Task 10 only** | Reads the names' count instead of an `Int`. |
| `ElliotKit/Tests/ElliotModelTests/PRStatusTests.swift`, `PRStatusPresentationTests.swift:67`, `PRStatusWireTests.swift:108` — **Task 10 only** | Eight assertions move from a count to the names. |

---

### Task 1: `Effort.unstated`, and a `parse` that stops inventing

**Files:**
- Modify: `ElliotKit/Sources/ElliotModel/StoryProposal.swift:29`
- Modify: `ElliotKit/Sources/ElliotModel/StoryProposal.swift:62`
- Modify: `ElliotKit/Sources/ElliotModel/StoryProposal.swift:93-101`
- Test: `ElliotKit/Tests/ElliotModelTests/AnalysisModelTests.swift`
- Test: `ElliotKit/Tests/ElliotModelTests/ProposalDecoderTests.swift:40`

**Interfaces:**
- Consumes: nothing from an earlier task.
- Produces:
  - `public enum Effort: String, Codable, CaseIterable, Sendable, Hashable { case small, medium, large, unstated }`
  - `public static func Effort.parse(_ raw: String) -> Effort` — returns `.unstated` for anything unrecognised, including `""`.
  - `ProposedStory.effort` is `String` and defaults to `""` in both the memberwise `init` and `init(from:)`.
  - **Unchanged, and measured rather than overlooked**: `StoryProposal.init`'s own `effort: Effort = .medium` (`ElliotKit/Sources/ElliotModel/StoryProposal.swift:188`) stays. It is a third route to an invented medium in principle, but `grep -rn "StoryProposal(" Sources` returns exactly one production construction — `ElliotKit/Sources/ElliotEngine/ProposalHarvester.swift:48`, which passes `effort: Effort.parse(story.effort)` at `:57` — so no live path reaches it. The design names "the two decode defaults", and those two are `ProposedStory`'s. Do not widen this task to a third.

- [ ] **Step 1: Write the failing test**

In `ElliotKit/Tests/ElliotModelTests/AnalysisModelTests.swift`, replace the existing `effortParsing` test (lines 24-30) with the two tests below.

```swift
    /// An unrecognised size is now recorded as unstated rather than folded onto
    /// `.medium`. For a display badge the fold was a kindness; as an input to an
    /// unattended ranking it is an invention, and the ranking cannot tell an
    /// invented medium from a stated one.
    @Test("An unstated effort is recorded as unstated, never invented", arguments: [
        ("small", Effort.small), ("MEDIUM", .medium), (" large ", .large),
        ("XL", .unstated), ("", .unstated), ("trivial", .unstated),
        // The case round-trips through its own raw value, so a stored
        // `.unstated` reads back as itself rather than as an unrecognised word.
        ("unstated", .unstated),
    ])
    func effortParsing(raw: String, expected: Effort) {
        #expect(Effort.parse(raw) == expected)
    }

    /// The two decode defaults had to move with `parse`, and leaving either
    /// behind would keep inventing the answer by a second route: an artifact
    /// with no `effort` key would decode to `"medium"`, parse cleanly, and
    /// nothing would ever be marked unstated.
    @Test("A story that never mentions effort decodes as unstated")
    func absentEffortIsUnstated() throws {
        let raw = Data(
            #"{"title":"T","role":"dev","want":"w","benefit":"b","evidence":["A.swift:1"]}"#.utf8
        )
        let decoded = try JSONDecoder().decode(ProposedStory.self, from: raw)
        #expect(decoded.effort == "")
        #expect(Effort.parse(decoded.effort) == .unstated)
        #expect(ProposedStory(title: "T", role: "dev", want: "w", benefit: "b").effort == "")
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd ElliotKit && swift test --filter AnalysisModelTests`

Expected: FAIL **to compile** — `error: type 'Effort' has no member 'unstated'`, once for every `.unstated` in the two tests above. `.unstated` is the case Step 3 adds, so it cannot exist when the test is written, and the compiler's refusal *is* this task's failing signal.

⚠️ Nothing runs, so there is no `Expectation failed:` line and no test count. That output is distinct from both a green run and `No matching test cases were run` — read which of the three you got before deciding anything. Once Step 3 lands, the same command runs the assertions for real.

- [ ] **Step 3: Write minimal implementation**

In `ElliotKit/Sources/ElliotModel/StoryProposal.swift`, line 18, the doc comment on `ProposedStory.effort` states the behaviour this task retires — replace it:

```swift
    /// `small` | `medium` | `large`; anything else is recorded as unstated.
```

Leaving it would be the shape of defect this repository has already paid for twice: a comment that keeps asserting a retired premise, and is then quoted back as a fact.

Line 29, change the memberwise init default:

```swift
        effort: String = ""
```

Line 62, change the decode default:

```swift
        effort = try container.decodeIfPresent(String.self, forKey: .effort) ?? ""
```

Replace the whole `Effort` enum (lines 93-101) with:

```swift
public enum Effort: String, Codable, CaseIterable, Sendable, Hashable {
    case small, medium, large
    /// The model said nothing an effort could be read out of.
    ///
    /// Its own case rather than a fold onto `.medium`: "somebody sized this as
    /// medium" and "nobody sized this" are different facts, and only the first
    /// one may feed a queue that engages cards with nobody watching. `.medium`
    /// survives as a size a model can state, never as one Elliot invents.
    case unstated

    /// Anything unrecognised becomes `.unstated`. A wrong size is a nuisance; a
    /// size nobody chose, presented as one somebody did, is worse than either.
    public static func parse(_ raw: String) -> Effort {
        Effort(rawValue: raw.trimmed().lowercased()) ?? .unstated
    }
}
```

In `ElliotKit/Tests/ElliotModelTests/ProposalDecoderTests.swift`, line 40, the messy fixture's `"effort": "enormous"` now parses to unstated:

```swift
        #expect(Effort.parse(harvest.stories[0].effort) == .unstated)
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd ElliotKit && swift test --filter AnalysisModelTests`
Expected: PASS

Then the two suites that read effort out of a real harvest:

Run: `cd ElliotKit && swift test --filter ProposalDecoderTests`
Expected: PASS

Run: `cd ElliotKit && swift test --filter ProposalHarvesterTests`
Expected: PASS — its fixtures state `"small"` and `"large"` explicitly, so nothing moves.

- [ ] **Step 5: Commit**

```bash
git rev-parse --abbrev-ref HEAD
git add ElliotKit/Sources/ElliotModel/StoryProposal.swift \
        ElliotKit/Tests/ElliotModelTests/AnalysisModelTests.swift \
        ElliotKit/Tests/ElliotModelTests/ProposalDecoderTests.swift
git commit -m "feat(model): record an unstated effort instead of inventing a medium one"
```

---

### Task 2: `Grounding`, and `isGrounded` as one reader of it

**Files:**
- Create: `ElliotKit/Sources/ElliotModel/Grounding.swift`
- Modify: `ElliotKit/Sources/ElliotModel/StoryProposal.swift:210-214`
- Test: `ElliotKit/Tests/ElliotModelTests/GroundingTests.swift`

**Interfaces:**
- Consumes: `public struct Evidence: Codable, Sendable, Hashable { public var path: String; public var line: Int?; public var exists: Bool }` — already in `ElliotKit/Sources/ElliotModel/StoryProposal.swift:107-138`.
- Produces:
  - `public enum Grounding: Sendable, Hashable { case notCited; case grounded; case missing(count: Int) }`
  - `public static func Grounding.of(evidence: [Evidence]) -> Grounding`
  - `public var Grounding.code: String` — `"not_cited"`, `"grounded"`, `"files_missing"`
  - `public var Grounding.summary: String` — one sentence
  - `public var StoryProposal.grounding: Grounding`
  - `public var StoryProposal.isGrounded: Bool` — unchanged signature, now `grounding == .grounded`

- [ ] **Step 1: Write the failing test**

Create `ElliotKit/Tests/ElliotModelTests/GroundingTests.swift`:

```swift
import Foundation
import Testing

@testable import ElliotModel

private let then = Date(timeIntervalSince1970: 1_700_000_000)

private func cited(_ path: String, exists: Bool) -> Evidence {
    Evidence(path: path, line: 1, exists: exists)
}

@Suite("Grounding")
struct GroundingTests {

    /// The whole reason this is not a `Bool`. "Nobody ever cited a file" is a
    /// silence; "files were cited and are not there" is an admission. A boolean
    /// answers `false` to both and a reader cannot tell them apart.
    @Test("A silence and an admission are different answers")
    func silenceIsNotAnAdmission() {
        #expect(Grounding.of(evidence: []) == .notCited)
        #expect(Grounding.of(evidence: [cited("A.swift", exists: false)]) == .missing(count: 1))
        #expect(Grounding.of(evidence: [cited("A.swift", exists: true)]) == .grounded)
    }

    @Test("Missing counts only the citations that are not there")
    func missingCountsTheAbsentOnes() {
        let mixed = [
            cited("A.swift", exists: true),
            cited("B.swift", exists: false),
            cited("C.swift", exists: false),
        ]
        #expect(Grounding.of(evidence: mixed) == .missing(count: 2))
    }

    /// The codes travel to agents, so they are written out rather than derived
    /// from the case names — the rule `PRSign.code` and `CIState.code` already
    /// keep, and the reason `files_missing` is not `missing`.
    @Test("Every grounding has a stable code and a sentence")
    func codesAndSummaries() {
        #expect(Grounding.notCited.code == "not_cited")
        #expect(Grounding.grounded.code == "grounded")
        #expect(Grounding.missing(count: 3).code == "files_missing")

        #expect(Grounding.missing(count: 1).summary.contains("One"))
        #expect(Grounding.missing(count: 3).summary.contains("3"))
        for grounding: Grounding in [.notCited, .grounded, .missing(count: 1)] {
            #expect(grounding.summary.hasSuffix("."))
            #expect(grounding.summary.count > 20)
        }
    }

    /// One definition, two readers. `isGrounded` is read by the panel's seal
    /// and by the wire's `grounded` flag; if it kept its own `allSatisfy` the
    /// two would be free to drift apart the first time either is corrected.
    @Test("A proposal's grounding and its boolean say the same thing")
    func proposalAgreesWithItsGrounding() {
        func proposal(_ evidence: [Evidence]) -> StoryProposal {
            StoryProposal(
                analysisID: UUID(), runID: UUID(), repoID: UUID(),
                angle: .bugs, title: "Bound the await",
                story: UserStory(role: "maintainer", want: "a bounded wait", benefit: "no hangs"),
                evidence: evidence, createdAt: then
            )
        }

        #expect(proposal([cited("A.swift", exists: true)]).grounding == .grounded)
        #expect(proposal([cited("A.swift", exists: true)]).isGrounded)
        #expect(!proposal([]).isGrounded)
        #expect(!proposal([cited("A.swift", exists: false)]).isGrounded)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd ElliotKit && swift test --filter GroundingTests`

Expected: FAIL to compile — `error: cannot find 'Grounding' in scope`, repeated at every use.

- [ ] **Step 3: Write minimal implementation**

Create `ElliotKit/Sources/ElliotModel/Grounding.swift`:

```swift
import Foundation

/// What the citations attached to a piece of work turned out to be worth.
///
/// Three cases and not a `Bool`, shaped like `PRSign` for the same reason: a
/// boolean answers `false` both to "nobody ever cited a file" and to "files were
/// cited and are not there", and those are opposite facts. The first is a
/// silence — nothing was checkable. The second is an admission — something was
/// checkable and did not check out.
public enum Grounding: Sendable, Hashable {
    /// Nobody ever cited a file.
    case notCited
    /// Every cited file was found.
    case grounded
    /// Files were cited and `count` of them are not there.
    case missing(count: Int)

    /// Stable identifier surfaced to MCP callers, like `PRSign.code`.
    ///
    /// Deliberately not the enum's own name: these travel over the wire, and a
    /// case renamed for readability must not silently change what an agent
    /// matches on.
    public var code: String {
        switch self {
        case .notCited: "not_cited"
        case .grounded: "grounded"
        case .missing: "files_missing"
        }
    }

    /// One sentence, for the panel's tooltip and the card's refusal note.
    ///
    /// Here rather than in a view for the usual reason: a sentence written in a
    /// SwiftUI body is a claim nothing can test.
    public var summary: String {
        switch self {
        case .notCited:
            "Nothing cited a file, so nothing here was checkable."
        case .grounded:
            "Every cited file was found in the repository."
        case .missing(let count):
            count == 1
                ? "One cited file is not there."
                : "\(count) cited files are not there."
        }
    }

    /// Resolved citations in, one answer out. `Evidence.exists` was settled
    /// once, at harvest, against the repository root — this reads that fact and
    /// never touches the file system itself.
    public static func of(evidence: [Evidence]) -> Grounding {
        guard !evidence.isEmpty else { return .notCited }
        let missing = evidence.count { !$0.exists }
        return missing == 0 ? .grounded : .missing(count: missing)
    }
}
```

In `ElliotKit/Sources/ElliotModel/StoryProposal.swift`, replace `isGrounded` (lines 210-214) with:

```swift
    /// What this proposal's citations turned out to be worth.
    public var grounding: Grounding {
        Grounding.of(evidence: evidence)
    }

    /// True when every cited file was found. The fastest signal that a story
    /// was found rather than invented.
    ///
    /// A reader of `grounding`, not a second definition of it: the panel's seal
    /// and the wire's `grounded` flag both come through here, and a copy of the
    /// `allSatisfy` would be free to drift the first time either is corrected.
    public var isGrounded: Bool {
        grounding == .grounded
    }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd ElliotKit && swift test --filter GroundingTests`
Expected: PASS

Run: `cd ElliotKit && swift test --filter ProposalHarvesterTests`
Expected: PASS — its two `isGrounded` assertions (`ElliotKit/Tests/ElliotEngineTests/ProposalHarvesterTests.swift:92`, `:99`) are unchanged and must stay green, which is the proof that the replacement is behaviour-preserving.

- [ ] **Step 5: Commit**

```bash
git rev-parse --abbrev-ref HEAD
git add ElliotKit/Sources/ElliotModel/Grounding.swift \
        ElliotKit/Sources/ElliotModel/StoryProposal.swift \
        ElliotKit/Tests/ElliotModelTests/GroundingTests.swift
git commit -m "feat(model): tell a silence from an admission with Grounding"
```

---

### Task 3: The three appraisal columns on `card`, and the v9 migration that backfills them

**Files:**
- Modify: `ElliotKit/Sources/ElliotModel/Card.swift:60-98`
- Modify: `ElliotKit/Sources/ElliotStore/Migrations.swift:153-155`
- Modify: `ElliotKit/Sources/ElliotStore/Migrations.swift:263`
- Modify: `ElliotKit/Sources/ElliotStore/BoardStore.swift:447`
- Test: `ElliotKit/Tests/ElliotStoreTests/SchemaUpgradeTests.swift`

**Interfaces:**
- Consumes: `Effort` (Task 1) and `Evidence` (`ElliotKit/Sources/ElliotModel/StoryProposal.swift:107`).
- Produces:
  - `public var Card.effort: Effort?`
  - `public var Card.evidence: [Evidence]?`
  - `public var Card.appraisedAt: Date?`
  - The three are the **last** three parameters of `Card.init`, all defaulted to `nil`, declared after `idempotencyKey:`.
  - `Migrations.backfillCardAppraisalsSQL: String` (internal to `ElliotStore`)
  - `public func BoardStore.backfillCardAppraisals() async throws`
  - Migration identifier `"v9_cardAppraisal"`.

⚠ **The migration number is a resource shared by four PRs.** If `git log origin/main -- ElliotKit/Sources/ElliotStore/Migrations.swift` shows a `v9_` already registered by the time this branch rebases, rename this one to `v10_cardAppraisal` **and, in the same commit**, append to `Migrations.renamedMigrations` (`ElliotKit/Sources/ElliotStore/Migrations.swift:195-202`):

```swift
        RenamedMigration(legacy: "v9_cardAppraisal", current: "v10_cardAppraisal") { db in
            // The schema is the evidence, the name is only the symptom: all
            // three columns, because the migration adds them in one `alter`.
            let columns = Set(try db.columns(in: "card").map(\.name))
            return columns.isSuperset(of: ["effort", "evidence", "appraisedAt"])
        }
```

and change `'v9_cardAppraisal'` to `'v10_cardAppraisal'` in `rewindToV1`'s `IN` clause below. `renamesPointAtRegisteredMigrations` (`ElliotKit/Tests/ElliotStoreTests/SchemaUpgradeTests.swift:507-514`) already checks that the pair is honoured.

- [ ] **Step 1: Write the failing test**

First, teach `rewindToV1` to undo v9. In `ElliotKit/Tests/ElliotStoreTests/SchemaUpgradeTests.swift`, after line 83 (`DROP COLUMN "angle"`), insert:

```swift
        try db.execute(sql: #"ALTER TABLE "card" DROP COLUMN "effort""#)
        try db.execute(sql: #"ALTER TABLE "card" DROP COLUMN "evidence""#)
        try db.execute(sql: #"ALTER TABLE "card" DROP COLUMN "appraisedAt""#)
```

then change the `DELETE` and its precondition (lines 88-100) to:

```swift
        try db.execute(
            sql: """
                DELETE FROM "grdb_migrations"
                WHERE "identifier" IN (
                    'v2_repositoryLayout', 'v3_cardIdempotencyKey', 'v5_githubImport',
                    'v7_cardAngle', 'v9_cardAppraisal'
                )
                """
        )
        precondition(
            db.changesCount == 5,
            "rewindToV1 removed \(db.changesCount) migration rows, expected 5"
        )
```

⚠ The count and the `IN` clause move together, always. Adding an identifier without raising the count leaves the precondition passing on a rewind that silently did less than it claims, and every upgrade test in this file then runs against a database that was already current.

Then add the migration test to the `SchemaUpgradeTests` suite, after `backfillDoesNotOverwriteAnExistingAngle` (which ends at line 430):

```swift
    /// The v9 migration, over rows that were already there — and its backfill,
    /// which is v7's precedent exactly. `storyProposal` has carried the effort,
    /// the resolved citations and the moment they were resolved since v4, next
    /// to the id of the card it produced, so this reads a fact rather than
    /// inferring one. Without it every existing board would read as never
    /// appraised, and the feature would look like a feature that does not work.
    @Test("A board upgraded to v9 gets its accepted cards' appraisal back")
    func migrationBackfillsAppraisalOverExistingRows() async throws {
        let scratch = try Scratch()
        let repository = repo()
        let accepted = card(repoID: repository.id, title: "Bound the await")
        let orphan = card(repoID: repository.id, title: "Written by hand")

        do {
            let old = try BoardStore.open(at: scratch.database)
            try await old.saveRepo(repository)
            let analysis = Analysis(repoID: repository.id, angles: [.techDebt], createdAt: then)
            try await old.saveAnalysis(analysis)
            try await old.saveCard(accepted)
            try await old.saveCard(orphan)
            try await old.saveProposal(
                StoryProposal(
                    analysisID: analysis.id, runID: UUID(), repoID: repository.id,
                    angle: .techDebt, title: "Bound the await",
                    story: UserStory(
                        role: "maintainer", want: "a bounded wait", benefit: "no hangs"
                    ),
                    evidence: [Evidence(path: "Sources/A.swift", line: 7, exists: true)],
                    effort: .large,
                    status: .accepted, acceptedCardID: accepted.id, createdAt: then
                )
            )
        }
        try rewindToV1(scratch.database)
        // The rewind has to have actually happened, or this upgrades a database
        // that already had the columns and proves nothing — the same guard the
        // idempotency-key and lens tests above use, for the same reason.
        #expect(!(try columnNames(of: "card", at: scratch.database).contains("appraisedAt")))

        let upgraded = try BoardStore.open(at: scratch.database)

        let back = try await upgraded.cards(repoID: repository.id)
        let filled = try #require(back.first { $0.id == accepted.id })
        #expect(filled.effort == .large)
        #expect(filled.evidence?.count == 1)
        #expect(filled.evidence?.first?.path == "Sources/A.swift")
        #expect(filled.evidence?.first?.line == 7)
        #expect(filled.evidence?.first?.exists == true)
        // The moment the citations were resolved, not the moment of the upgrade:
        // dating the reading to the migration would make every old board look
        // freshly measured.
        #expect(filled.appraisedAt == then)

        // Absent rather than defaulted, and all three together: nothing ever
        // read this card, which is the third state the columns exist to carry.
        let untouched = try #require(back.first { $0.id == orphan.id })
        #expect(untouched.effort == nil)
        #expect(untouched.evidence == nil)
        #expect(untouched.appraisedAt == nil)
    }

    /// The backfill must not overwrite an appraisal the card already carries.
    ///
    /// `backfillCardAppraisals` is public and idempotent by design, and the same
    /// statement runs again on every upgrade path that replays migrations. A
    /// card re-appraised since would otherwise be silently reset to whatever its
    /// original proposal said — the identical trade `WHERE "angle" IS NULL`
    /// makes one migration up.
    @Test("Re-running the appraisal backfill leaves an appraisal that is already set alone")
    func appraisalBackfillDoesNotOverwrite() async throws {
        let scratch = try Scratch()
        let store = try BoardStore.open(at: scratch.database)
        let repository = repo()
        try await store.saveRepo(repository)

        let analysis = Analysis(repoID: repository.id, angles: [.techDebt], createdAt: then)
        try await store.saveAnalysis(analysis)

        var accepted = card(repoID: repository.id, title: "Bound the await")
        accepted.effort = .small
        accepted.evidence = []
        accepted.appraisedAt = then.addingTimeInterval(60)
        try await store.saveCard(accepted)

        try await store.saveProposal(
            StoryProposal(
                analysisID: analysis.id, runID: UUID(), repoID: repository.id,
                angle: .techDebt, title: "Bound the await",
                story: UserStory(role: "maintainer", want: "a bounded wait", benefit: "no hangs"),
                evidence: [Evidence(path: "Sources/A.swift", line: 7, exists: true)],
                effort: .large,
                status: .accepted, acceptedCardID: accepted.id, createdAt: then
            )
        )

        try await store.backfillCardAppraisals()
        try await store.backfillCardAppraisals()

        let back = try await store.cards(repoID: repository.id)
        #expect(back.first { $0.id == accepted.id }?.effort == .small)
        #expect(back.first { $0.id == accepted.id }?.appraisedAt == then.addingTimeInterval(60))
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd ElliotKit && swift test --filter SchemaUpgradeTests`

Expected: FAIL to compile — `error: value of type 'Card' has no member 'effort'` at the first `filled.effort`, and the same for `evidence` and `appraisedAt`.

- [ ] **Step 3: Write minimal implementation**

In `ElliotKit/Sources/ElliotModel/Card.swift`, add the three stored properties after `idempotencyKey` (line 58):

```swift
    /// What an appraisal established about this card, and when.
    ///
    /// Columns on the card rather than a table of their own, and the criterion
    /// is the one written above migration v8: a datum produced *inside* the
    /// funnel, by a run that owns this card for its whole life, is provenance
    /// and belongs on the row; an observation written by a poller about an
    /// object outside the card belongs in its own table.
    ///
    /// `evidence` is optional rather than `[]`, and `appraisedAt` is the third
    /// state that makes the optionality mean something: without it, "nobody has
    /// ever read this card" and "this card was read and there was nothing to
    /// find" are the same value. An older file has no column at all, and GRDB
    /// decodes an absent optional as `nil` — which is the truth, since nothing
    /// could have written a value the column did not exist to hold.
    public var effort: Effort?
    public var evidence: [Evidence]?
    public var appraisedAt: Date?
```

Add the three parameters at the end of the initialiser, after `idempotencyKey: String? = nil` (line 78):

```swift
        idempotencyKey: String? = nil,
        effort: Effort? = nil,
        evidence: [Evidence]? = nil,
        appraisedAt: Date? = nil
    ) {
```

and their assignments after `self.idempotencyKey = idempotencyKey` (line 97):

```swift
        self.effort = effort
        self.evidence = evidence
        self.appraisedAt = appraisedAt
```

In `ElliotKit/Sources/ElliotStore/Migrations.swift`, insert the migration between the closing brace of `v8_prStatus` (line 153) and `return migrator` (line 155):

```swift
        // v9, additive: what an appraisal established about a card's value.
        //
        // Columns on `card` rather than a table of its own, and the criterion is
        // the one written above v8. A pull request's status is an observation
        // about an object outside the card, written by a poller, so it got a
        // table. This is the opposite family: the appraisal run carries a
        // `cardID`, so `activeRun(cardID:)` holds the card for the run's whole
        // life and no poller can be half-way through the same row. That makes it
        // provenance, and v7's columns the right precedent.
        //
        // The counterpart is measured and favourable: `observeCards()` already
        // tracks the whole card row and de-duplicates, so a column write is
        // observable for free — a separate table would cost a second
        // `ValueObservation`.
        //
        // The backfill is not a guess. `storyProposal` has carried the effort,
        // the resolved citations and the moment they were resolved since v4,
        // next to the id of the card it produced, so every accepted card already
        // carries the answer one join away. Without this the feature would ship
        // empty on every existing board and look like a feature that does not
        // work — v7's stated reason, unchanged.
        migrator.registerMigration("v9_cardAppraisal") { db in
            try db.alter(table: "card") { t in
                t.add(column: "effort", .text)
                t.add(column: "evidence", .text)        // JSON array
                t.add(column: "appraisedAt", .datetime)
            }
            try db.execute(sql: Migrations.backfillCardAppraisalsSQL)
        }
```

Add the statement after `backfillCardAnglesSQL` (which ends at line 263):

```swift
    /// The v9 backfill, named for the same reason `backfillCardAnglesSQL` is:
    /// the migration and the test that proves what it does run the identical
    /// statement.
    ///
    /// Three correlated subqueries rather than one row-value assignment, so it
    /// reads the way v7's does and depends on nothing beyond what v7 already
    /// relies on. `LIMIT 1` is belt, for v7's reason: acceptance creates one
    /// card per proposal, so at most one row can match — but a subquery that
    /// would return two rows is an error rather than a choice, and a migration
    /// is a bad place to learn that.
    ///
    /// `appraisedAt` takes the proposal's `createdAt` and not the moment of the
    /// migration: that is when the harvest resolved the citations, and dating
    /// the reading to the upgrade would make every old board look freshly
    /// measured.
    ///
    /// `WHERE "appraisedAt" IS NULL` is not belt. This statement is also
    /// reachable through `BoardStore.backfillCardAppraisals()`, which is
    /// deliberately idempotent, so without the guard a re-run would overwrite an
    /// appraisal that had since been redone with whatever the original proposal
    /// said.
    static let backfillCardAppraisalsSQL = """
        UPDATE "card" SET
            "effort" = (
                SELECT "p"."effort" FROM "storyProposal" "p"
                WHERE "p"."acceptedCardID" = "card"."id" LIMIT 1
            ),
            "evidence" = (
                SELECT "p"."evidence" FROM "storyProposal" "p"
                WHERE "p"."acceptedCardID" = "card"."id" LIMIT 1
            ),
            "appraisedAt" = (
                SELECT "p"."createdAt" FROM "storyProposal" "p"
                WHERE "p"."acceptedCardID" = "card"."id" LIMIT 1
            )
        WHERE "appraisedAt" IS NULL
        """
```

In `ElliotKit/Sources/ElliotStore/BoardStore.swift`, add after `backfillCardAngles()` (which ends at line 447):

```swift
    /// Runs the v9 backfill again. Idempotent — it only writes rows whose
    /// `appraisedAt` is still NULL — and exists so a test can assert what the
    /// migration does without reaching into `grdb_migrations`.
    public func backfillCardAppraisals() async throws {
        try await requireWriter().write { db in
            try db.execute(sql: Migrations.backfillCardAppraisalsSQL)
        }
    }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd ElliotKit && swift test --filter SchemaUpgradeTests`
Expected: PASS — including the five pre-existing upgrade tests, which now run through a `rewindToV1` that undoes one more migration.

Run: `cd ElliotKit && swift test --filter MigrationsTests`
Expected: PASS

Run: `cd ElliotKit && swift test`
Expected: PASS — the whole suite, because `Card` is constructed in many tests and the three new parameters are defaulted.

- [ ] **Step 5: Commit**

```bash
git rev-parse --abbrev-ref HEAD
git add ElliotKit/Sources/ElliotModel/Card.swift \
        ElliotKit/Sources/ElliotStore/Migrations.swift \
        ElliotKit/Sources/ElliotStore/BoardStore.swift \
        ElliotKit/Tests/ElliotStoreTests/SchemaUpgradeTests.swift
git commit -m "feat(model,store): carry a card's appraisal on the card row"
```

---

### Task 4: The measurement — an older file read by a build that knows the columns

This task writes no production code. It exists because the reasoning behind `evidence: [Evidence]?` rather than `[]` — *an older file has no column, and GRDB decodes an absent optional as nil* — is currently a sentence in `ElliotKit/Sources/ElliotStore/BoardStore.swift:41-47` and in Task 3's own comment. **This repository does not let a sentence reach a pull request body as a fact before it has been measured.** Do not write that claim into the PR body until this test is green.

**Files:**
- Test: `ElliotKit/Tests/ElliotStoreTests/SchemaUpgradeTests.swift`

**Interfaces:**
- Consumes:
  - `Card.effort: Effort?`, `Card.evidence: [Evidence]?`, `Card.appraisedAt: Date?` (Task 3)
  - `rewindToV1(_ url: URL) throws` — the file-private helper at `ElliotKit/Tests/ElliotStoreTests/SchemaUpgradeTests.swift:73`, which after Task 3 also drops the three v9 columns
  - `public static func BoardStore.openReadOnly(at url: URL?) throws -> BoardStore`
  - `public func BoardStore.cards(repoID: UUID?, column: Column?, limit: Int?) async throws -> [Card]`
- Produces: nothing. It is a witness.

- [ ] **Step 1: Write the failing test**

Add to the `SchemaUpgradeTests` suite in `ElliotKit/Tests/ElliotStoreTests/SchemaUpgradeTests.swift`, immediately after `appraisalBackfillDoesNotOverwrite`:

```swift
    /// The measurement the schema decision rests on, taken rather than assumed.
    ///
    /// `evidence` is `[Evidence]?` and not `[]` because a file written before v9
    /// has no column at all, and GRDB decodes an absent optional as `nil` — the
    /// reasoning written at `BoardStore.openReadOnly`. That reasoning is not
    /// allowed into a pull request body until this has run: rewind a store below
    /// v9, open it with **this** build through `openReadOnly` — which never
    /// migrates, so the columns really are absent at read time — and read the
    /// cards back.
    ///
    /// `openReadOnly` and not `open` is the whole configuration: `open` would
    /// migrate the file and add the columns before anything read them, which is
    /// exactly the measurement that proves nothing.
    @Test("A build that knows the appraisal columns reads a file that has none")
    func appraisalColumnsAreAbsentRatherThanFatal() async throws {
        let scratch = try Scratch()
        let repository = repo()
        let kept = card(repoID: repository.id, title: "Written before the appraisal")

        do {
            let old = try BoardStore.open(at: scratch.database)
            try await old.saveRepo(repository)
            try await old.saveCard(kept)
        }
        try rewindToV1(scratch.database)
        let columns = try columnNames(of: "card", at: scratch.database)
        #expect(!columns.contains("effort"))
        #expect(!columns.contains("evidence"))
        #expect(!columns.contains("appraisedAt"))

        let helper = try BoardStore.openReadOnly(at: scratch.database)
        let back = try await helper.cards(repoID: repository.id)

        #expect(back.count == 1)
        #expect(back[0].title == "Written before the appraisal")
        // Absent, not defaulted, and not fatal. Nothing could have written a
        // value the column did not exist to hold, so `nil` is the truth.
        #expect(back[0].effort == nil)
        #expect(back[0].evidence == nil)
        #expect(back[0].appraisedAt == nil)
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd ElliotKit && swift test --filter SchemaUpgradeTests`

Expected: this is a measurement, so both outcomes are results and neither is a defeat.

- **PASS** confirms the claim, and Task 3's `evidence: [Evidence]?` comment may be quoted in the PR body as measured. Go to Step 4.
- **FAIL** — a thrown `DatabaseError` out of `cards(repoID:)` naming a missing column — falsifies it. Then the optionality is not what protects the read, and the honest fix is to say so: change Task 3's comment to name the real protection, and record in the PR body that the read-only path refuses an older file rather than reading it as absent.

- [ ] **Step 3: Write minimal implementation**

None. This task adds no production code, on purpose: it is the witness for a sentence, and a witness that also changes the thing it measures is not one.

If Step 2 came back FAIL, the implementation is the *documentation* correction described there, in `ElliotKit/Sources/ElliotModel/Card.swift` — and this plan's Task 3 comment is then wrong and must be rewritten rather than kept. **The test itself also changes**, or this task ships red: replace the last four expectations with the refusal that was actually measured —

```swift
        let helper = try BoardStore.openReadOnly(at: scratch.database)
        // Measured, not assumed: this build refuses an older file rather than
        // reading its absent appraisal columns as nil. `evidence: [Evidence]?`
        // is therefore not what protects the read, and `Card.swift` says so.
        await #expect(throws: (any Error).self) {
            _ = try await helper.cards(repoID: repository.id)
        }
```

— and rename the test to `appraisalColumnsAreRefusedOnAnOlderFile`, so its name states what was found rather than what was hoped.

- [ ] **Step 4: Run test to verify it passes**

Run: `cd ElliotKit && swift test --filter SchemaUpgradeTests`
Expected: PASS — in **either** branch of Step 2. Step 3 leaves whichever of the two claims the measurement supported, and green here means the suite now records a measured fact, not that the first guess was right.

Sample it, because one green run does not clear a suite:

```bash
cd ElliotKit && for i in 1 2 3 4 5; do swift test --filter SchemaUpgradeTests 2>&1 | tail -3; done
```

Expected: five runs, each reporting the same number of tests passed, and **none** reporting `No matching test cases were run`.

- [ ] **Step 5: Commit**

```bash
git rev-parse --abbrev-ref HEAD
git add ElliotKit/Tests/ElliotStoreTests/SchemaUpgradeTests.swift
git commit -m "test(store): measure that an older file reads its absent appraisal columns as nil"
```

---

### Task 5: The three weights, as data beside their own types

**Files:**
- Modify: `ElliotKit/Sources/ElliotModel/AnalysisAngle.swift:124`
- Modify: `ElliotKit/Sources/ElliotModel/StoryProposal.swift` (after the `Effort` enum)
- Modify: `ElliotKit/Sources/ElliotModel/Grounding.swift` (after the enum)
- Test: `ElliotKit/Tests/ElliotModelTests/CardValueTests.swift`

**Interfaces:**
- Consumes: `Effort` (Task 1), `Grounding` (Task 2).
- Produces:
  - `public var AnalysisAngle.valueWeight: Double`
  - `public static let AnalysisAngle.unlensedWeight: Double` = `0.6`
  - `public static let AnalysisAngle.unlensedCode: String` = `"no_lens"`
  - `public var Effort.valueWeight: Double`
  - `public var Grounding.valueWeight: Double`

- [ ] **Step 1: Write the failing test**

Create `ElliotKit/Tests/ElliotModelTests/CardValueTests.swift` with just the weights suite for now (Task 6 adds to this file):

```swift
import Foundation
import Testing

@testable import ElliotModel

@Suite("Value weights")
struct ValueWeightsTests {

    /// The weights are data, in the shape of `AnalysisAngle.briefing`: adding a
    /// lens stays a case and a number, and nothing else in the package branches
    /// on which lens a card came through. A lens with no weight would compile
    /// only if somebody wrote a `default`, which is the thing this shape exists
    /// to make impossible.
    @Test("Every lens carries a weight, and the range is real", arguments: AnalysisAngle.allCases)
    func everyAngleIsWeighted(angle: AnalysisAngle) {
        #expect(angle.valueWeight > 0)
        #expect(angle.valueWeight <= 1)
    }

    @Test("The lenses are not all worth the same, or the weight says nothing")
    func anglesAreDistinguished() {
        let weights = AnalysisAngle.allCases.map(\.valueWeight)
        #expect(Set(weights).count > 1)
    }

    /// A card written by hand carries no lens, and burying it under every
    /// machine-found card is the failure `CardValue.neverAppraised` exists to
    /// prevent, arriving one field over. So the unlensed weight sits strictly
    /// inside the range rather than at the bottom of it.
    @Test("A card that came through no lens is neither promoted nor buried")
    func unlensedSitsInsideTheRange() throws {
        let weights = AnalysisAngle.allCases.map(\.valueWeight)
        let lowest = try #require(weights.min())
        let highest = try #require(weights.max())
        #expect(AnalysisAngle.unlensedWeight > lowest)
        #expect(AnalysisAngle.unlensedWeight < highest)
        #expect(!AnalysisAngle.unlensedCode.isEmpty)
    }

    /// Cheaper is worth more, and that ordering is the only thing the numbers
    /// themselves have to guarantee.
    @Test("A smaller effort outranks a larger one")
    func effortIsOrdered() {
        #expect(Effort.small.valueWeight > Effort.medium.valueWeight)
        #expect(Effort.medium.valueWeight > Effort.large.valueWeight)
        // Unreachable from `CardValue.of` — an unstated effort is refused, not
        // scored — and zero so that a future caller that scores it anyway gets
        // an obviously wrong answer rather than a plausible one.
        #expect(Effort.unstated.valueWeight == 0)
    }

    @Test("A grounded citation outranks a missing one, and an absent one scores nothing")
    func groundingIsOrdered() {
        #expect(Grounding.grounded.valueWeight > Grounding.missing(count: 1).valueWeight)
        #expect(Grounding.missing(count: 1).valueWeight > 0)
        #expect(Grounding.notCited.valueWeight == 0)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd ElliotKit && swift test --filter ValueWeightsTests`

Expected: FAIL to compile — `error: value of type 'AnalysisAngle' has no member 'valueWeight'`, plus the same for `Effort` and `Grounding`.

- [ ] **Step 3: Write minimal implementation**

Append to `ElliotKit/Sources/ElliotModel/AnalysisAngle.swift`, after the closing brace of the enum (line 124):

```swift
public extension AnalysisAngle {
    /// What a card found through this lens is worth to a queue nobody is
    /// watching.
    ///
    /// Data, exactly like `briefing`: adding a lens stays a case and a number,
    /// and no code path anywhere branches on which lens a card came through. A
    /// weight buried in a comparator would be the opposite — a rule you have to
    /// go and find, in a file about sorting rather than about lenses.
    var valueWeight: Double {
        switch self {
        case .bugs: 1.0
        case .quickWins: 0.9
        case .tests: 0.7
        case .features: 0.6
        case .uxAndUI: 0.6
        case .techDebt: 0.5
        case .docsAndDX: 0.4
        case .bestPractices: 0.3
        }
    }

    /// What a card that came through no lens is worth.
    ///
    /// Strictly inside the range rather than at the bottom of it: a card written
    /// by hand or imported from GitHub was chosen by a person, and putting every
    /// one of those below every machine-found card is the same failure
    /// `CardValue.neverAppraised` exists to prevent, arriving one field over.
    static let unlensedWeight: Double = 0.6

    /// The name a `Signal` carries for a card with no lens. Not a lens name, and
    /// not empty: an unnamed signal reads as a missing one.
    static let unlensedCode = "no_lens"
}
```

Append to `ElliotKit/Sources/ElliotModel/StoryProposal.swift`, immediately after the `Effort` enum's closing brace:

```swift
public extension Effort {
    /// What this size is worth: cheaper is worth more, because the queue is
    /// spending a whole unattended agent per card either way.
    ///
    /// Data, like `AnalysisAngle.valueWeight`, and beside its own type so a new
    /// size cannot reach the score without somebody choosing a number for it.
    var valueWeight: Double {
        switch self {
        case .small: 1.0
        case .medium: 0.6
        case .large: 0.3
        // Unreachable from `CardValue.of`, which refuses an unstated effort
        // rather than scoring it. Zero rather than a plausible middle so that a
        // caller that scores it anyway gets an obviously wrong answer.
        case .unstated: 0.0
        }
    }
}
```

Append to `ElliotKit/Sources/ElliotModel/Grounding.swift`:

```swift
public extension Grounding {
    /// What the citations are worth. Data, like the other two weights.
    var valueWeight: Double {
        switch self {
        // Unreachable from `CardValue.of`, which refuses an uncited card rather
        // than scoring it — the same trade `Effort.unstated` makes.
        case .notCited: 0.0
        // A story whose citations do not check out may still be right, but it
        // was not checkable, and an unattended queue is the last place to spend
        // an agent on that.
        case .missing: 0.3
        case .grounded: 1.0
        }
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd ElliotKit && swift test --filter ValueWeightsTests`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git rev-parse --abbrev-ref HEAD
git add ElliotKit/Sources/ElliotModel/AnalysisAngle.swift \
        ElliotKit/Sources/ElliotModel/StoryProposal.swift \
        ElliotKit/Sources/ElliotModel/Grounding.swift \
        ElliotKit/Tests/ElliotModelTests/CardValueTests.swift
git commit -m "feat(model): put the lens, effort and grounding weights in data"
```

---

### Task 6: `CardValue`, and the refusal that is never a low rank

⚠️ **The design contradicts itself here, and this task follows the operative half — say so in the pull request body rather than letting a reviewer find it.** Its PR2 section states the rule as *"`.ungradeable` when `evidence?.isEmpty != false || effort == .unstated`"*, under which a card that cited files which are **not there** is still `.ranked`, merely lower. Its Testing section then abbreviates the same rule as *"`.ungradeable` for cited-and-missing files"*, which the formula does not say. The formula wins: it is the one written as code, it is the one `Grounding` was shaped for — `.missing` carries a *count*, which a refusal would never need — and refusing a card outright because its files moved would make a rename indistinguishable from an invention. `missingFilesAreRankedLower` below is that decision, pinned.

**Files:**
- Create: `ElliotKit/Sources/ElliotModel/CardValue.swift`
- Test: `ElliotKit/Tests/ElliotModelTests/CardValueTests.swift`

**Interfaces:**
- Consumes:
  - `Card.effort: Effort?`, `Card.evidence: [Evidence]?`, `Card.appraisedAt: Date?`, `Card.angle: AnalysisAngle?` (Task 3 and existing)
  - `Grounding.of(evidence:)`, `Grounding.code`, `Grounding.valueWeight` (Tasks 2 and 5)
  - `Effort.unstated`, `Effort.valueWeight` (Tasks 1 and 5)
  - `AnalysisAngle.valueWeight`, `AnalysisAngle.unlensedWeight`, `AnalysisAngle.unlensedCode` (Task 5)
- Produces:
  - `public struct Signal: Sendable, Hashable { public var name: String; public var weight: Double }` with `public init(name: String, weight: Double)`
  - `public enum CardValue: Sendable, Hashable { case ranked(score: Double, because: [Signal]); case ungradeable(because: Grounding); case neverAppraised }`
  - `public static func CardValue.of(_ card: Card) -> CardValue`
  - `public var CardValue.rankable: Double?`
  - `public var CardValue.summary: String`
  - `public enum CardRanking` with `public struct Appraised { public var card: Card; public var value: CardValue }`, `public struct Ranking { public var ranked: [Appraised]; public var refused: [Appraised] }` and `public static func rank(_ cards: [Card]) -> Ranking`

- [ ] **Step 1: Write the failing test**

Append to `ElliotKit/Tests/ElliotModelTests/CardValueTests.swift`:

```swift
private let then = Date(timeIntervalSince1970: 1_700_000_000)

private func appraised(
    title: String = "Bound the await",
    angle: AnalysisAngle? = .bugs,
    effort: Effort? = .small,
    evidence: [Evidence]? = [Evidence(path: "Sources/A.swift", line: 1, exists: true)],
    appraisedAt: Date? = then,
    createdAt: Date = then
) -> Card {
    Card(
        repoID: UUID(), title: title, angle: angle,
        columnEnteredAt: createdAt, createdAt: createdAt, updatedAt: createdAt,
        effort: effort, evidence: evidence, appraisedAt: appraisedAt
    )
}

@Suite("Card value")
struct CardValueTests {

    /// The third state, and the reason `appraisedAt` is a column of its own.
    /// Without it, "nobody has ever appraised this card" and "this card was
    /// appraised and had no signal" are the same value.
    @Test("A card nothing has read is never appraised, not a zero")
    func nothingReadIsNeverAppraised() {
        #expect(CardValue.of(appraised(appraisedAt: nil, createdAt: then)) == .neverAppraised)
        // Even when the other two happen to be filled: the timestamp is the one
        // that says a reading happened, and content alone cannot say it.
        let odd = appraised(effort: .small, evidence: [], appraisedAt: nil)
        #expect(CardValue.of(odd) == .neverAppraised)
    }

    /// The verdict is decided on content, never on the column: a card that was
    /// read and cited nothing is refused, and it is refused for the reason it
    /// actually has.
    @Test("A card that cites nothing is ungradeable, not badly ranked")
    func uncitedIsUngradeable() {
        #expect(CardValue.of(appraised(evidence: [])) == .ungradeable(because: .notCited))
        #expect(CardValue.of(appraised(evidence: nil)) == .ungradeable(because: .notCited))
    }

    /// The other trigger. A `.grounded` payload on an `.ungradeable` can only
    /// mean the effort was the problem, because the grounding was checked first
    /// and was fine — which is what lets one sentence say the truth about two
    /// different causes.
    @Test("A card whose effort was never stated is ungradeable, and says so")
    func unstatedEffortIsUngradeable() {
        let card = appraised(effort: .unstated)
        #expect(CardValue.of(card) == .ungradeable(because: .grounded))
        #expect(CardValue.of(card).summary.contains("effort"))
        #expect(CardValue.of(appraised(effort: nil)) == .ungradeable(because: .grounded))

        let uncited = appraised(evidence: [])
        #expect(CardValue.of(uncited).summary.contains("cited"))
    }

    /// Citations that do not check out lower the score; they do not disqualify.
    /// A story whose files moved may still be right, and refusing it outright
    /// would make a rename look like an invention.
    @Test("Missing files are ranked lower, not refused")
    func missingFilesAreRankedLower() throws {
        let grounded = appraised()
        let broken = appraised(
            evidence: [Evidence(path: "Sources/Nowhere.swift", line: 9, exists: false)]
        )

        let high = try #require(CardValue.of(grounded).rankable)
        let low = try #require(CardValue.of(broken).rankable)
        #expect(high > low)
    }

    /// The score *is* the sum of what is listed, so the number and its reason
    /// cannot drift: a weight that is not in `because` is not in the score.
    @Test("A ranked card explains its own number")
    func scoreIsTheSumOfItsSignals() throws {
        guard case .ranked(let score, let because) = CardValue.of(appraised()) else {
            Issue.record("a fully appraised card must rank")
            return
        }
        #expect(because.count == 3)
        #expect(abs(score - because.reduce(0) { $0 + $1.weight }) < 0.000_001)
        #expect(because.map(\.name).contains("bugs"))
        #expect(because.map(\.name).contains("small"))
        #expect(because.map(\.name).contains("grounded"))
        #expect(because.allSatisfy { !$0.name.isEmpty })
    }

    @Test("A card with no lens still ranks, under a name of its own")
    func unlensedCardStillRanks() throws {
        guard case .ranked(_, let because) = CardValue.of(appraised(angle: nil)) else {
            Issue.record("a hand-written card that was appraised must still rank")
            return
        }
        #expect(because.map(\.name).contains(AnalysisAngle.unlensedCode))
    }

    // MARK: - What may never enter a comparator

    /// The claim this whole type exists for. A sort has to put an absence
    /// *somewhere*, and both places are wrong: at the bottom, auto-dev never
    /// engages a hand-written card; at the top, it engages first what nobody has
    /// measured. So an absence is refused by name and never given a position.
    @Test("Neither ungradeable nor never-appraised carries a number a sort could use")
    func absenceHasNoNumber() {
        #expect(CardValue.neverAppraised.rankable == nil)
        #expect(CardValue.ungradeable(because: .notCited).rankable == nil)
        #expect(CardValue.ungradeable(because: .grounded).rankable == nil)
        #expect(CardValue.ungradeable(because: .missing(count: 2)).rankable == nil)
    }

    @Test("Ranking keeps the refusals out of the order entirely")
    func refusalsNeverJoinTheOrder() {
        let cheap = appraised(title: "Cheap and grounded", effort: .small)
        let dear = appraised(title: "Large and grounded", effort: .large)
        let silent = appraised(title: "Cited nothing", evidence: [])
        let unread = appraised(title: "Never read", appraisedAt: nil)

        let ranking = CardRanking.rank([silent, dear, unread, cheap])

        #expect(ranking.ranked.map(\.card.title) == ["Cheap and grounded", "Large and grounded"])
        #expect(ranking.ranked.allSatisfy { $0.value.rankable != nil })
        #expect(ranking.refused.map(\.card.title) == ["Cited nothing", "Never read"])
        #expect(ranking.refused.allSatisfy { $0.value.rankable == nil })
    }

    /// And the refusals keep the order they were given rather than acquiring one
    /// — which is the difference between "these cannot be ranked" and "these
    /// ranked last".
    @Test("The refused list is the caller's order, never a value order")
    func refusalsAreNotSorted() {
        let silent = appraised(title: "Cited nothing", evidence: [])
        let unread = appraised(title: "Never read", appraisedAt: nil)

        #expect(CardRanking.rank([silent, unread]).refused.map(\.card.title)
            == ["Cited nothing", "Never read"])
        #expect(CardRanking.rank([unread, silent]).refused.map(\.card.title)
            == ["Never read", "Cited nothing"])
    }

    /// Two cards that score the same must come back in the same order every
    /// time. An unstable sort here reshuffles the queue between two reads of an
    /// unchanged board, which reads as the board changing its mind.
    @Test("Equal scores are broken by age, then by id — the order is total")
    func tiesAreBrokenDeterministically() {
        let older = appraised(title: "Older", createdAt: then)
        let newer = appraised(title: "Newer", createdAt: then.addingTimeInterval(60))

        #expect(CardRanking.rank([newer, older]).ranked.map(\.card.title) == ["Older", "Newer"])
        #expect(CardRanking.rank([older, newer]).ranked.map(\.card.title) == ["Older", "Newer"])
    }

    @Test("Every verdict says one sentence")
    func everyVerdictSpeaks() {
        let sentences = [
            CardValue.of(appraised()).summary,
            CardValue.of(appraised(evidence: [])).summary,
            CardValue.of(appraised(effort: .unstated)).summary,
            CardValue.neverAppraised.summary,
        ]
        #expect(sentences.allSatisfy { $0.hasSuffix(".") })
        #expect(Set(sentences).count == 4)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd ElliotKit && swift test --filter CardValueTests`

Expected: FAIL to compile — `error: cannot find 'CardValue' in scope` and `error: cannot find 'CardRanking' in scope`.

- [ ] **Step 3: Write minimal implementation**

Create `ElliotKit/Sources/ElliotModel/CardValue.swift`:

```swift
import Foundation

/// One thing that was read about a card, and what it contributed.
///
/// A score with no signals behind it is a number nobody can argue with, which is
/// the wrong property for something that decides where an unattended agent goes
/// next. `CardValue.ranked` carries these so the number can always be taken
/// apart.
public struct Signal: Sendable, Hashable {
    /// Stable, not prose: `"bugs"`, `"small"`, `"grounded"`. These are the same
    /// identifiers the wire already uses, so a sentence built from them does not
    /// have to be translated back.
    public var name: String
    public var weight: Double

    public init(name: String, weight: Double) {
        self.name = name
        self.weight = weight
    }
}

/// What a card is worth to a queue that runs with nobody watching.
///
/// **Not a `Double?`.** An optional invites `?? 0`, and "absence becomes the
/// lowest score" is precisely the failure `CIState.noChecks` exists to prevent
/// one type away. Here it would mean every hand-written and every imported card
/// silently sinking to the bottom of an unattended queue.
///
/// A card that is not `.ranked` is **refused, never ranked low**. A sort has to
/// put an absence somewhere, and both ends are wrong: at the bottom, auto-dev
/// never engages a card a person wrote; at the top, it engages first what
/// nothing has measured.
public enum CardValue: Sendable, Hashable {
    case ranked(score: Double, because: [Signal])
    case ungradeable(because: Grounding)
    case neverAppraised
}

public extension CardValue {
    /// What this card is worth, decided on its own signals and never on its
    /// column.
    ///
    /// The order of the two refusals is load-bearing.
    ///
    /// `appraisedAt == nil` is asked first because it is the *third state*:
    /// nothing has ever read this card, which is a different answer from "it was
    /// read and there was nothing to find". Collapsing them is exactly what the
    /// column exists to prevent.
    ///
    /// The grounding is asked before the effort, and that is what lets
    /// `.ungradeable`'s single payload tell the truth about two different
    /// causes: a `.grounded` payload can only be reached when the citations were
    /// fine, so it can only mean the effort was the problem. `summary` reads it
    /// that way, and `CardValueTests` pins it.
    static func of(_ card: Card) -> CardValue {
        guard card.appraisedAt != nil else { return .neverAppraised }

        let grounding = Grounding.of(evidence: card.evidence ?? [])
        guard grounding != .notCited else { return .ungradeable(because: grounding) }

        let effort = card.effort ?? .unstated
        guard effort != .unstated else { return .ungradeable(because: grounding) }

        let signals = [
            Signal(
                name: card.angle?.rawValue ?? AnalysisAngle.unlensedCode,
                weight: card.angle?.valueWeight ?? AnalysisAngle.unlensedWeight
            ),
            Signal(name: effort.rawValue, weight: effort.valueWeight),
            Signal(name: grounding.code, weight: grounding.valueWeight),
        ]
        // The score *is* the sum of what is listed. A weight that is not in
        // `because` is not in the score either, so the number and its reason
        // cannot drift apart.
        return .ranked(score: signals.reduce(0) { $0 + $1.weight }, because: signals)
    }

    /// The number a sort may use, and `nil` for every answer that is not a rank.
    ///
    /// The only way out of the enum on purpose: a caller that wants to order the
    /// board has to say out loud what it does with an absence, and the answer
    /// this package gives is `CardRanking`.
    var rankable: Double? {
        if case .ranked(let score, _) = self { return score }
        return nil
    }

    /// One sentence, in the vocabulary the board already speaks.
    ///
    /// Here rather than in a view for the usual reason: a sentence written in a
    /// SwiftUI body is a claim nothing can test.
    var summary: String {
        switch self {
        case .ranked(let score, let because):
            return "Ranked \(String(format: "%.2f", score)) on "
                + "\(because.map(\.name).joined(separator: ", "))."
        case .ungradeable(let grounding):
            // See `of(_:)`: the grounding is checked first, so `.grounded` here
            // can only mean the effort was the missing signal.
            switch grounding {
            case .notCited:
                return "Nothing cited a file, so there is no signal to rank this card by."
            case .grounded:
                return "The effort was never stated, so there is no signal to rank this card by."
            case .missing(let count):
                let files = count == 1 ? "one cited file is" : "\(count) cited files are"
                return "The effort was never stated, and \(files) not there."
            }
        case .neverAppraised:
            return "Nothing has measured this card."
        }
    }
}

/// Putting a board in value order — and keeping out of it everything that has no
/// place in one.
///
/// The whole point is the second list. Elsewhere a refusal would be swallowed by
/// a comparator and come back as a position, and a position is an answer this
/// package does not have.
public enum CardRanking {

    /// A card and what value has to say about it, kept together so a caller
    /// cannot sort one and report the other.
    public struct Appraised: Sendable, Hashable {
        public var card: Card
        public var value: CardValue

        public init(card: Card, value: CardValue) {
            self.card = card
            self.value = value
        }
    }

    public struct Ranking: Sendable, Hashable {
        /// Best first. Every element is `.ranked`.
        public var ranked: [Appraised]
        /// In the order they were given, **never** in value order: an absence
        /// has no place in a ranking, at either end.
        public var refused: [Appraised]

        public init(ranked: [Appraised], refused: [Appraised]) {
            self.ranked = ranked
            self.refused = refused
        }
    }

    public static func rank(_ cards: [Card]) -> Ranking {
        var scored: [(score: Double, appraised: Appraised)] = []
        var refused: [Appraised] = []

        for card in cards {
            let value = CardValue.of(card)
            let appraised = Appraised(card: card, value: value)
            // Pattern-matched rather than read through `rankable`, and that is
            // what keeps `?? 0` — "absence is the lowest score" — from ever
            // being written here.
            if case .ranked(let score, _) = value {
                scored.append((score, appraised))
            } else {
                refused.append(appraised)
            }
        }

        // Ties are broken by age and then by id, so the order is total. An
        // unstable sort over equal scores reshuffles the queue between two reads
        // of an unchanged board, which reads as the board changing its mind.
        scored.sort { left, right in
            if left.score != right.score { return left.score > right.score }
            if left.appraised.card.createdAt != right.appraised.card.createdAt {
                return left.appraised.card.createdAt < right.appraised.card.createdAt
            }
            return left.appraised.card.id.uuidString < right.appraised.card.id.uuidString
        }

        return Ranking(ranked: scored.map(\.appraised), refused: refused)
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd ElliotKit && swift test --filter CardValueTests`
Expected: PASS

Run: `cd ElliotKit && swift test --filter ValueWeightsTests`
Expected: PASS — the same file, and the weights must still stand on their own.

- [ ] **Step 5: Commit**

```bash
git rev-parse --abbrev-ref HEAD
git add ElliotKit/Sources/ElliotModel/CardValue.swift \
        ElliotKit/Tests/ElliotModelTests/CardValueTests.swift
git commit -m "feat(model): refuse a card nothing measured instead of ranking it low"
```

---

### Task 7: `AnalysisService.accept` carries effort, evidence and the moment they were resolved

**Files:**
- Modify: `ElliotKit/Sources/ElliotEngine/BoardService.swift:200-238`
- Modify: `ElliotKit/Sources/ElliotEngine/AnalysisService.swift:207-217`
- Test: `ElliotKit/Tests/ElliotEngineTests/AnalysisServiceTests.swift`

**Interfaces:**
- Consumes:
  - `Card.effort`, `Card.evidence`, `Card.appraisedAt` (Task 3)
  - `public var StoryProposal.evidence: [Evidence]`, `public var StoryProposal.effort: Effort`, `public var StoryProposal.createdAt: Date` (existing, `ElliotKit/Sources/ElliotModel/StoryProposal.swift:171-176`)
- Produces:
  - `BoardService.createCard(repoID:title:body:story:column:angle:effort:evidence:appraisedAt:idempotencyKey:)` — the three new parameters are declared **between** `angle:` and `idempotencyKey:`, each defaulted to `nil`, and the whole signature is:

```swift
    public func createCard(
        repoID: UUID,
        title: String,
        body: String = "",
        story: UserStory? = nil,
        column: ElliotModel.Column = .backlog,
        angle: AnalysisAngle? = nil,
        effort: Effort? = nil,
        evidence: [Evidence]? = nil,
        appraisedAt: Date? = nil,
        idempotencyKey: String? = nil
    ) async throws -> CreatedCard
```

- [ ] **Step 1: Write the failing test**

Add to `ElliotKit/Tests/ElliotEngineTests/AnalysisServiceTests.swift`, after `acceptCarriesTheAngle` (which ends at line 209):

```swift
    /// The other half of the same loss. The analysis established an effort and
    /// resolved every citation against the repository root, and both died at
    /// `accept` — so the Backlog carried almost nothing to rank by.
    ///
    /// `appraisedAt` is the proposal's own moment, not `now`: that is when the
    /// harvest resolved the citations, and dating the reading to whenever
    /// somebody clicked Accept would make an old proposal look freshly measured.
    @Test("Accepting a proposal puts its effort, evidence and reading time on the card")
    func acceptCarriesTheAppraisal() async throws {
        let fixture = try await makeFixture()
        let started = try await fixture.service.start(
            repoID: fixture.repo.id, angles: [.bugs], origin: .manual
        )
        let read = Date(timeIntervalSince1970: 1_700_000_000)

        let proposal = StoryProposal(
            analysisID: started.analysis.id, runID: started.runs[0].id,
            repoID: fixture.repo.id, angle: .bugs, title: "Bound the await",
            story: UserStory(role: "maintainer", want: "a bounded wait", benefit: "no hangs"),
            evidence: [
                Evidence(path: "Sources/ElliotProcess/ChildProcess.swift", line: 142, exists: true),
                Evidence(path: "Sources/Nowhere.swift", line: 9, exists: false),
            ],
            effort: .large,
            createdAt: read
        )
        try await fixture.store.saveProposals([proposal])

        let cards = try await fixture.service.accept(proposalIDs: [proposal.id])

        #expect(cards.count == 1)
        #expect(cards[0].effort == .large)
        #expect(cards[0].evidence?.count == 2)
        #expect(cards[0].appraisedAt == read)

        // And it is on the row, not only on the value handed back — the card is
        // read from the store on every launch, and an appraisal that never
        // reached SQLite would vanish at the next one.
        let stored = try #require(try await fixture.store.card(id: cards[0].id))
        #expect(stored.effort == .large)
        #expect(stored.evidence?.first?.path == "Sources/ElliotProcess/ChildProcess.swift")
        #expect(stored.evidence?.first?.line == 142)
        #expect(stored.evidence?.first?.exists == true)
        // The resolution survives the round trip, which is the only reason
        // `Grounding` can be computed from the card at all.
        #expect(stored.evidence?.last?.exists == false)
        #expect(stored.appraisedAt == read)
        #expect(CardValue.of(stored) == .ranked(
            score: AnalysisAngle.bugs.valueWeight
                + Effort.large.valueWeight
                + Grounding.missing(count: 1).valueWeight,
            because: [
                Signal(name: "bugs", weight: AnalysisAngle.bugs.valueWeight),
                Signal(name: "large", weight: Effort.large.valueWeight),
                Signal(name: "files_missing", weight: Grounding.missing(count: 1).valueWeight),
            ]
        ))
    }

    /// A card the board makes for itself still carries no appraisal, because
    /// nothing read it. `nil` here is the third state, not a zero.
    @Test("A card created directly has never been appraised")
    func directCreateHasNoAppraisal() async throws {
        let fixture = try await makeFixture()
        let created = try await fixture.board.createCard(
            repoID: fixture.repo.id, title: "Written by hand"
        )
        #expect(created.card.effort == nil)
        #expect(created.card.evidence == nil)
        #expect(created.card.appraisedAt == nil)
        #expect(CardValue.of(created.card) == .neverAppraised)
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd ElliotKit && swift test --filter AnalysisServiceTests`

Expected: FAIL. `acceptCarriesTheAppraisal` fails at `#expect(cards[0].effort == .large)` with `(cards[0].effort → nil) == (.large → Optional(ElliotModel.Effort.large))`, because `accept` still drops both fields.

- [ ] **Step 3: Write minimal implementation**

In `ElliotKit/Sources/ElliotEngine/BoardService.swift`, add the three parameters to `createCard` after `angle:` (line 210) and before `idempotencyKey:` (line 211):

```swift
        angle: AnalysisAngle? = nil,
        /// What an appraisal established about this card's value, when one
        /// already had. Defaulted for the same reason `angle` is: every caller
        /// that makes a card the board asked for — the New-story sheet,
        /// `board_create_card`, the GitHub import — says nothing about value,
        /// and `nil` here is the third state (nobody has read this) rather than
        /// a zero.
        effort: Effort? = nil,
        evidence: [Evidence]? = nil,
        appraisedAt: Date? = nil,
        idempotencyKey: String? = nil
```

and add them to the `Card` construction (lines 226-238), after `idempotencyKey: key`:

```swift
            idempotencyKey: key,
            effort: effort,
            evidence: evidence,
            appraisedAt: appraisedAt
        )
```

In `ElliotKit/Sources/ElliotEngine/AnalysisService.swift`, extend the `createCard` call (lines 207-217):

```swift
                card = try await board.createCard(
                    repoID: proposal.repoID,
                    title: proposal.title,
                    body: proposal.rationale,
                    story: proposal.story,
                    column: .backlog,
                    // The one line this whole issue is about: the lens was
                    // chosen before the run and recorded on the proposal, and
                    // until now it stopped existing here.
                    angle: proposal.angle,
                    // And the two signals that die the same way. The analysis
                    // sized the work and resolved every citation against the
                    // repository root; without these the Backlog carries almost
                    // nothing to rank by, and every accepted card reads as
                    // never appraised.
                    effort: proposal.effort,
                    evidence: proposal.evidence,
                    // The proposal's own moment, not `now`: that is when the
                    // harvest resolved the citations. Dating the reading to
                    // whenever somebody clicked Accept would make a week-old
                    // proposal look freshly measured.
                    appraisedAt: proposal.createdAt
                ).card
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd ElliotKit && swift test --filter AnalysisServiceTests`
Expected: PASS

Run: `cd ElliotKit && swift test`
Expected: PASS — the whole suite, because `createCard` is reached from the MCP handler, the New-story sheet and the GitHub import, and all three keep their defaults.

- [ ] **Step 5: Commit**

```bash
git rev-parse --abbrev-ref HEAD
git add ElliotKit/Sources/ElliotEngine/BoardService.swift \
        ElliotKit/Sources/ElliotEngine/AnalysisService.swift \
        ElliotKit/Tests/ElliotEngineTests/AnalysisServiceTests.swift
git commit -m "feat(engine): let a proposal's effort and evidence reach the card it becomes"
```

---

### Task 8: The measured counterexample, end to end

The design names one concrete way a card ends up with `evidence == []` while every other field looks complete, and it is not hypothetical: `ProposedStory(evidence: ["   "])` passes `isUsable` (`ElliotKit/Sources/ElliotModel/StoryProposal.swift:79-81`, which only checks that the array is non-empty) and reaches `ProposalDecoder` (`ElliotKit/Sources/ElliotModel/ProposalDecoder.swift:76`), and then `ProposalHarvester.resolve` (`ElliotKit/Sources/ElliotEngine/ProposalHarvester.swift:121-138`) drops it, because `Evidence.parse` returns `nil` for a blank string. The accepted card carries `[]`, and it must fall to `.ungradeable` rather than to a low score.

**Files:**
- Create: `ElliotKit/Tests/ElliotEngineTests/CardValueFromProposalTests.swift`

**Interfaces:**
- Consumes:
  - `ProposalHarvester(store:gh:)` and `harvest(run:analysis:repo:artifactURL:) async -> AnalysisRunReport` (`ElliotKit/Sources/ElliotEngine/ProposalHarvester.swift:13-76`)
  - `AnalysisService(store:launcher:board:gh:)` and `accept(proposalIDs:) async throws -> [Card]`
  - `BoardService(store:launcher:)`
  - `CardValue.of(_:)` and `Grounding` (Tasks 2 and 6)
  - `AnalysisService.accept` carrying evidence (Task 7)
- Produces: nothing. It is a witness for the design's counterexample.

- [ ] **Step 1: Write the failing test**

Create `ElliotKit/Tests/ElliotEngineTests/CardValueFromProposalTests.swift`:

```swift
import ElliotModel
import ElliotProcess
import ElliotStore
import Foundation
import Testing

@testable import ElliotEngine

/// Records what would have been launched, without spawning anything.
private actor LaunchSpy: RunLaunching {
    func launch(runID: UUID) async {}
    func cancel(runID: UUID) async {}
}

/// The counterexample the design measures, driven end to end.
///
/// `ProposedStory.isUsable` only checks that the citation array is non-empty, so
/// a story citing `"   "` survives the decoder. `Evidence.parse` then returns
/// `nil` for a blank string and `ProposalHarvester.resolve` `compactMap`s it
/// away — so the proposal reaches the board with `evidence == []` while every
/// other field looks complete.
///
/// That card must fall to `.ungradeable`, not to a low score. Ranking it low
/// would put a card nothing could check *above* the cards nothing has read yet,
/// which is precisely the ordering `CardValue` refuses to invent.
@Suite("Card value from a real proposal")
struct CardValueFromProposalTests {

    private struct Fixture {
        var store: BoardStore
        var service: AnalysisService
        var harvester: ProposalHarvester
        var repo: Repo
        var analysis: Analysis
        var run: SkillRun
        var artifactURL: URL
        var root: URL

        func cleanUp() { try? FileManager.default.removeItem(at: root) }
    }

    /// A throwaway repository with one real file, so a citation that *should*
    /// resolve has something true to resolve against.
    private func makeFixture() async throws -> Fixture {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("elliot-value-\(UUID().uuidString)", isDirectory: true)
        let sources = root.appendingPathComponent("Sources", isDirectory: true)
        try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
        try "// real".write(
            to: sources.appendingPathComponent("Real.swift"), atomically: true, encoding: .utf8
        )

        let store = try BoardStore.inMemory()
        let repo = Repo(path: root.path, nameWithOwner: "phmatray/Elliot", displayName: "Elliot")
        try await store.saveRepo(repo)

        let analysis = Analysis(
            repoID: repo.id, angles: [.bugs], maxStoriesPerAngle: 8, createdAt: Date()
        )
        try await store.saveAnalysis(analysis)

        let run = SkillRun(
            cardID: nil, repoID: repo.id, analysisID: analysis.id, analysisAngle: .bugs,
            kind: .analyzeRepo, prompt: "…", cwd: repo.path,
            logPath: root.appendingPathComponent("run.ndjson").path,
            stderrPath: root.appendingPathComponent("run.log").path,
            createdAt: Date()
        )
        try await store.saveRun(run)

        // `gh` unreachable, so duplicate hints come from the board alone — which
        // is also the honest default here.
        let config = ToolConfig(
            claudePath: "/usr/bin/false", ghPath: "/usr/bin/false",
            gitPath: "/usr/bin/false", environment: [:]
        )
        let gh = GHClient(config: config)
        let spy = LaunchSpy()
        let board = BoardService(store: store, launcher: spy)

        return Fixture(
            store: store,
            service: AnalysisService(store: store, launcher: spy, board: board, gh: gh),
            harvester: ProposalHarvester(store: store, gh: gh),
            repo: repo, analysis: analysis, run: run,
            artifactURL: root.appendingPathComponent("stories.json"),
            root: root
        )
    }

    @Test("A story citing only whitespace becomes a card that cannot be ranked")
    func blankCitationEndsUpUngradeable() async throws {
        let fixture = try await makeFixture()
        defer { fixture.cleanUp() }

        try """
        [
          {"title":"Cited only whitespace","role":"dev","want":"w","benefit":"b",
           "evidence":["   "],"effort":"small"},
          {"title":"Cited a real file","role":"dev","want":"w","benefit":"b",
           "evidence":["Sources/Real.swift:3"],"effort":"small"}
        ]
        """.write(to: fixture.artifactURL, atomically: true, encoding: .utf8)

        let report = await fixture.harvester.harvest(
            run: fixture.run, analysis: fixture.analysis,
            repo: fixture.repo, artifactURL: fixture.artifactURL
        )
        // Both were kept: `isUsable` looks at the array, not at what is in it.
        #expect(report.kept == 2)

        let proposals = try await fixture.store.proposals(analysisID: fixture.analysis.id)
        let blank = try #require(proposals.first { $0.title == "Cited only whitespace" })
        let real = try #require(proposals.first { $0.title == "Cited a real file" })
        // The measured step: the citation survived the decoder and was emptied
        // by the harvester.
        #expect(blank.evidence.isEmpty)
        #expect(blank.grounding == .notCited)
        #expect(real.grounding == .grounded)

        let cards = try await fixture.service.accept(proposalIDs: [blank.id, real.id])
        #expect(cards.count == 2)

        let blankCard = try #require(cards.first { $0.title == "Cited only whitespace" })
        let realCard = try #require(cards.first { $0.title == "Cited a real file" })

        // Refused, and refused for the reason it actually has — not ranked low.
        #expect(CardValue.of(blankCard) == .ungradeable(because: .notCited))
        #expect(CardValue.of(blankCard).rankable == nil)
        #expect(CardValue.of(realCard).rankable != nil)

        // And a ranking keeps it out of the order entirely rather than putting
        // it last, which is the whole claim.
        let ranking = CardRanking.rank([blankCard, realCard])
        #expect(ranking.ranked.map(\.card.title) == ["Cited a real file"])
        #expect(ranking.refused.map(\.card.title) == ["Cited only whitespace"])
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd ElliotKit && swift test --filter CardValueFromProposalTests`

Expected: this test is written against Tasks 1–7 and should be **PASS** on the first run. That is not a free pass: run it once with the Task 7 change taken back out of the working tree, to confirm it can fail.

⛔ `git stash push Sources/ElliotEngine/AnalysisService.swift` does **not** do that. Task 7 committed the file, so there is nothing to stash: `git stash push` answers `No local changes to save`, the test then runs against the change it was meant to remove and passes, and `git stash pop` fails with `No stash entries found`. Three commands, no error that reads like one, and a witness that never witnessed anything.

Put the file back to its parent commit instead — run these from the **repository root**, not from `ElliotKit`:

```bash
git rev-parse --abbrev-ref HEAD
BEFORE="$(git log -1 --format=%H -- ElliotKit/Sources/ElliotEngine/AnalysisService.swift)^"
git checkout "$BEFORE" -- ElliotKit/Sources/ElliotEngine/AnalysisService.swift
git diff --stat ElliotKit/Sources/ElliotEngine/AnalysisService.swift    # must NOT be empty
(cd ElliotKit && swift test --filter CardValueFromProposalTests)
git checkout HEAD -- ElliotKit/Sources/ElliotEngine/AnalysisService.swift
git diff --stat ElliotKit/Sources/ElliotEngine/AnalysisService.swift    # must be empty again
```

The two `git diff --stat` lines are the point: the first proves the revert landed, the second proves it was undone. Without them this is the stash trap again, one command over.

Expected while the file is reverted: FAIL, with **four** expectations failing rather than one. Without Task 7 no card carries an appraisal, so both cards come back `.neverAppraised`, and everything before `accept` still passes:

- `#expect(CardValue.of(blankCard) == .ungradeable(because: .notCited))` — the first to go, `(… → .neverAppraised) == (… → .ungradeable(because: .notCited))`;
- `#expect(CardValue.of(realCard).rankable != nil)` — `(… → nil) != nil`;
- `#expect(ranking.ranked.map(\.card.title) == ["Cited a real file"])` — nothing ranks, so the left side is `[]`;
- `#expect(ranking.refused.map(\.card.title) == ["Cited only whitespace"])` — **both** cards are refused, so the left side is `["Cited only whitespace", "Cited a real file"]`.

The one that keeps passing is `#expect(CardValue.of(blankCard).rankable == nil)`, and it is worth noticing why: `.neverAppraised` has no number either, so that single assertion cannot tell the two refusals apart. It is the *pair* of it and the first bullet that does. `#expect` does not stop the test, so all four report. A test that cannot fail is not a witness.

- [ ] **Step 3: Write minimal implementation**

None. Everything this test needs was built in Tasks 1–7; the task is the measurement itself.

- [ ] **Step 4: Run test to verify it passes**

Run: `cd ElliotKit && swift test --filter CardValueFromProposalTests`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git rev-parse --abbrev-ref HEAD
git add ElliotKit/Tests/ElliotEngineTests/CardValueFromProposalTests.swift
git commit -m "test(engine): pin that a whitespace citation ends ungradeable, not badly ranked"
```

---

### Task 9: `CardFieldWritersTests` — the grep made a test

CLAUDE.md states the invariant as *"`RunScheduler.apply`, `Reconciler.apply` and `PRWatcher.reconcile` save and move; **they do not judge**, and none of them writes a card field of its own"*, and says it is "enforced by grep". It is not: nothing runs that grep. It holds today — measured, and the measurement is the grep in Step 3, which returns nothing. Loosening it to the bare field names finds eight lines in those three files and **not one of them is an assignment**: five reads in `ElliotKit/Sources/ElliotEngine/PRWatcher.swift` (`:112`, `:114`, `:147`, `:149`, `:159` — the last is `prNumber: number`, an argument label, which is exactly the kind of near-miss a hand-run grep gets wrong) and three doc comments in `RunScheduler.swift` (`:190`, `:205`, `:525`). PR2 is the moment to make it mechanical, because `effort` and `evidence` join the protected set at exactly the point an unattended agent becomes a writer of card fields.

**Files:**
- Create: `ElliotKit/Tests/ElliotEngineTests/CardFieldWritersTests.swift`
- Temporarily modify (Step 2 only, reverted in Step 2): `ElliotKit/Sources/ElliotEngine/PRWatcher.swift`

**Interfaces:**
- Consumes: nothing at compile time. It reads `ElliotKit/Sources/ElliotEngine/*.swift` as text, in the idiom of `ElliotKit/Tests/ElliotProcessTests/DrainDuplicationTests.swift:34-57`.
- Produces: nothing other than the gate.

- [ ] **Step 1: Write the failing test**

Create `ElliotKit/Tests/ElliotEngineTests/CardFieldWritersTests.swift`:

```swift
import Foundation
import Testing

/// The three files that react to a verified outcome. Named rather than globbed:
/// the claim is about these three, and a new file in the target is not
/// automatically one of them. At file scope so `@Test(arguments:)` can reach it.
private let watchedFiles = ["RunScheduler.swift", "Reconciler.swift", "PRWatcher.swift"]

/// Guards that a card's fields are decided in exactly one place.
///
/// `VerifiedOutcome.applied(to:attribution:)` says what a verified outcome does
/// to a card — the fields, the `lastError`, and the move it implies — and returns
/// all three in one `CardOutcome`. `RunScheduler.apply`, `Reconciler.apply` and
/// `PRWatcher.reconcile` save and move; they do not judge.
///
/// This reads source text rather than behaviour, which is unusual and is the
/// point — the idiom is `DrainDuplicationTests`, and the reason is the same. The
/// defect it guards against is not a wrong answer, it is a *second writer* of a
/// right one, and a second writer agrees with the first right up until one of
/// them is corrected. That already happened here: three hand-written switches
/// drifted until #135, and the same run produced a clean card through
/// `RunScheduler` and a card still showing a failed run's banner through
/// `Reconciler`.
///
/// Until now the rule was held by a sentence in CLAUDE.md that calls itself
/// "enforced by grep", and nothing ran the grep. PR2 is the right moment to fix
/// that: `effort` and `evidence` join the protected set at exactly the point an
/// unattended agent becomes a writer of card fields.
@Suite("Card field writers")
struct CardFieldWritersTests {

    private static let sources: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // ElliotEngineTests
        .deletingLastPathComponent()   // Tests
        .deletingLastPathComponent()   // ElliotKit
        .appendingPathComponent("Sources/ElliotEngine")

    /// Exactly the set the design names. `appraisedAt` is deliberately not here
    /// yet: PR6 widens the set when the appraisal harvester becomes its writer,
    /// and widening it early would make this gate assert something no code in
    /// the package is trying to do.
    private static let fields = [
        "issueNumber", "issueURL", "prNumber", "prURL", "branch", "lastError",
        "effort", "evidence",
    ]

    private static func read(_ name: String) throws -> [String] {
        try String(contentsOf: sources.appendingPathComponent(name), encoding: .utf8)
            .components(separatedBy: "\n")
    }

    /// A line with its comment forms stripped, so a gate about code cannot be
    /// tripped — or satisfied — by prose describing it. `RunScheduler.swift`
    /// mentions `branch` and `lastError` in three doc comments today.
    private static func isCode(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return !trimmed.hasPrefix("//") && !trimmed.isEmpty
    }

    @Test("No poller writes a card field of its own")
    func cardFieldsAreDecidedInOnePlace() throws {
        var offenders: [String] = []

        for file in watchedFiles {
            for (index, line) in try Self.read(file).enumerated() where Self.isCode(line) {
                for field in Self.fields where line.contains("\(field) = ") {
                    offenders.append("\(file):\(index + 1) assigns `\(field)`")
                }
            }
        }

        #expect(
            offenders.isEmpty,
            """
            A card field is written outside `VerifiedOutcome.applied(to:)`, which is the \
            only thing allowed to decide one:
            \(offenders.joined(separator: "\n"))
            If this is a local variable that merely shares a name with a card field, rename \
            the local rather than deleting the gate.
            """
        )
    }

    /// The gate is worth nothing if the files it names are not the files that
    /// exist: a rename would turn it into a test that reads nothing and passes,
    /// which is the failure mode every source-reading gate has.
    @Test("Each watched file is there to be read", arguments: watchedFiles)
    func watchedFilesExist(name: String) throws {
        let lines = try Self.read(name)
        #expect(!lines.isEmpty)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

A gate passes on the day it is written, so it has to be shown failing. Append this to the end of `ElliotKit/Sources/ElliotEngine/PRWatcher.swift`:

```swift
private struct GateWitness {
    var lastError: String?
    mutating func drift() { lastError = "written by a poller" }
}
```

Run: `cd ElliotKit && swift test --filter CardFieldWritersTests`

Expected: FAIL — `A card field is written outside 'VerifiedOutcome.applied(to:)' … PRWatcher.swift:<n> assigns 'lastError'`, naming the field and the line.

Then remove those four lines from `ElliotKit/Sources/ElliotEngine/PRWatcher.swift` and confirm the file is clean:

```bash
cd ElliotKit && git diff --stat Sources/ElliotEngine/PRWatcher.swift
```

Expected: no output — the witness is gone.

- [ ] **Step 3: Write minimal implementation**

None. The invariant already holds in production code; this task adds the gate that keeps it holding. Verify by hand that the claim is true before trusting the green:

```bash
cd ElliotKit/Sources/ElliotEngine && \
  grep -nE "(issueNumber|issueURL|prNumber|prURL|branch|lastError|effort|evidence) = " \
  RunScheduler.swift Reconciler.swift PRWatcher.swift
```

Expected: no output, exit status 1.

- [ ] **Step 4: Run test to verify it passes**

Run: `cd ElliotKit && swift test --filter CardFieldWritersTests`
Expected: PASS — four tests (one gate plus three parameterised existence checks), and **not** `No matching test cases were run`.

- [ ] **Step 5: Commit**

```bash
git rev-parse --abbrev-ref HEAD
git add ElliotKit/Tests/ElliotEngineTests/CardFieldWritersTests.swift
git commit -m "test(engine): make the card-field grep a test that names the field"
```

---

### Task 10 (isolated, removable): `CIState.passing` carries the names, not a count

⚠️ **Delete this task and the plan downgrades from Option A to Option B.** That is the whole reason it is a task of its own and the last one. The design leaves *what counts as green* open with three answers; this plan assumes **Option A** — `!isStale && sign == nil && merge == .clean && ci.hasBuildVerdict`, where `hasBuildVerdict` requires at least one passing check whose **name** is not in a data list of analysers and reporters. Option A is not expressible while `CIState.passing` carries an `Int` (`ElliotKit/Sources/ElliotModel/PRStatus.swift:88`): the labels exist at `ElliotKit/Sources/ElliotModel/PRStatus.swift:323` and are discarded one line later, so the passing checks' names never reach the predicate. This task carries them through, and nothing else. Options B (`!isStale && sign == nil && merge == .clean`) and C (`sign == nil`) need none of it, so **removing this task is a complete, coherent downgrade to Option B** — it does not leave a dangling reference anywhere in Tasks 1–9, which never mention `CIState`.

⚠️ The design places this change in **PR1**, not PR2. It is here so that Option A cannot be adopted and then silently lost between two plans. Before doing anything else, measure whether PR1 already shipped it.

**Files:**
- Modify: `ElliotKit/Sources/ElliotModel/PRStatus.swift:88`
- Modify: `ElliotKit/Sources/ElliotModel/PRStatus.swift:323-324`
- Modify: `ElliotKit/Sources/ElliotAppKit/PRStatusBlock.swift:111`
- Test: `ElliotKit/Tests/ElliotModelTests/PRStatusTests.swift`
- Test: `ElliotKit/Tests/ElliotAppKitTests/PRStatusPresentationTests.swift:67`
- Test: `ElliotKit/Tests/ElliotIPCTests/PRStatusWireTests.swift:108`

**Interfaces:**
- Consumes: `public var GHMergeStatus.StatusCheck.label: String` — `name ?? context ?? "check"` (`ElliotKit/Sources/ElliotModel/GHPayloads.swift:160`), and `isNonVerdict` (`:182-184`).
- Produces: `case passing([String])` on `CIState`, carrying the labels of the checks that reached a passing verdict — symmetric with `case failing([String])`, which already carries its labels. `CIState.passing(…).code` stays `"passing"`.

- [ ] **Step 0: Measure whether PR1 already did this**

```bash
grep -n "case passing" ElliotKit/Sources/ElliotModel/PRStatus.swift
```

- Prints `case passing([String])` → PR1 shipped it. **Stop here**: tick every box in this task and make no commit; there is nothing to do.
- Prints `case passing(Int)` → continue with Step 1.

- [ ] **Step 1: Write the failing test**

Add to the `PRStatusTests` suite in `ElliotKit/Tests/ElliotModelTests/PRStatusTests.swift`, after `passingCountsTheChecks` (which ends at line 75):

```swift
    /// Option A's prior change, and the reason it is a change to the *type*.
    ///
    /// A merge predicate that must ask "did anything that is not an analyser
    /// pass?" needs the names, and the names exist at `PRStatus.ciState` for
    /// exactly one line before a count throws them away. Carrying them makes
    /// `.passing` symmetric with `.failing`, which has carried its labels all
    /// along.
    @Test("A passing rollup carries the names of what passed")
    func passingCarriesItsLabels() {
        let resolved = status(
            checks: [run("build-and-test", "SUCCESS"), run("CodeQL", "SUCCESS")]
        ).fresh
        #expect(resolved.ci == .passing(["build-and-test", "CodeQL"]))

        // A non-verdict is still not a pass, and now it is visibly absent from
        // the list rather than merely missing from a total.
        let gated = status(checks: [run("build", "SUCCESS"), run("deploy", "SKIPPED")]).fresh
        #expect(gated.ci == .passing(["build"]))
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd ElliotKit && swift test --filter PRStatusTests`

Expected: FAIL to compile — `error: cannot convert value of type '[String]' to expected argument type 'Int'` at both `.passing([...])`.

- [ ] **Step 3: Write minimal implementation**

In `ElliotKit/Sources/ElliotModel/PRStatus.swift`, line 88:

```swift
    /// The labels of the checks that reached a passing verdict.
    ///
    /// Names and not a count, symmetric with `failing`: a merge predicate has to
    /// be able to ask whether anything that is not an analyser or a reporter
    /// actually built this pull request, and a count cannot answer that. The
    /// labels exist at `ciState` and used to be discarded one line later.
    case passing([String])
```

Lines 323-324, inside `ciState`:

```swift
        let passed = checks.filter { !$0.isNonVerdict }.map(\.label)
        return passed.isEmpty ? .noChecks : .passing(passed)
```

In `ElliotKit/Sources/ElliotAppKit/PRStatusBlock.swift`, line 111:

```swift
        case .passing(let names): names.count == 1 ? "1 check passed" : "\(names.count) checks passed"
```

Then the eight existing assertions that spelled a count — six here and one each in the two files below. In `ElliotKit/Tests/ElliotModelTests/PRStatusTests.swift`, and note that the expected array is in **declaration order**, because `ciState` now `map`s the filtered array rather than counting it:

| line | was | becomes |
|---|---|---|
| 71 | `.passing(2)` | `.passing(["build", "test"])` |
| 99 | `.passing(1)` | `.passing(["ci/travis"])` |
| 118 | `.passing(1)` | `.passing(["build"])` |
| 134 | `.passing(1)` | `.passing(["CodeQL"])` |
| 144 | `.passing(2)` | `.passing(["CodeQL", "renovate/stability-days"])` |
| 248 | `.passing(1)` | `.passing(["build"])` |

In `ElliotKit/Tests/ElliotAppKitTests/PRStatusPresentationTests.swift`, line 67 — the seeded fixture's one check is named `build` (`:25`, inside the `checks:` default at `:24-26`):

```swift
        #expect(resolved.ci == .passing(["build"]))
```

In `ElliotKit/Tests/ElliotIPCTests/PRStatusWireTests.swift`, line 108 — the code must not move, which is the point of that test:

```swift
        #expect(CIState.passing(["build", "test", "lint"]).code == "passing")
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd ElliotKit && swift test --filter PRStatusTests`
Expected: PASS

Run: `cd ElliotKit && swift test --filter PRStatusPresentationTests`
Expected: PASS

Run: `cd ElliotKit && swift test --filter PRStatusWireTests`
Expected: PASS

Run: `cd ElliotKit && swift test`
Expected: PASS — the whole suite. `.passing` is matched or built in four source places across two targets (`ElliotKit/Sources/ElliotModel/PRStatus.swift:101`, `:324`; `ElliotKit/Sources/ElliotAppKit/PRStatusBlock.swift:111`, `:121` — the last binds nothing and needs no edit), and asserted in three test targets.

- [ ] **Step 5: Commit**

```bash
git rev-parse --abbrev-ref HEAD
git add ElliotKit/Sources/ElliotModel/PRStatus.swift \
        ElliotKit/Sources/ElliotAppKit/PRStatusBlock.swift \
        ElliotKit/Tests/ElliotModelTests/PRStatusTests.swift \
        ElliotKit/Tests/ElliotAppKitTests/PRStatusPresentationTests.swift \
        ElliotKit/Tests/ElliotIPCTests/PRStatusWireTests.swift
git commit -m "feat(model,app): carry the passing checks' names so a merge rule can read them"
```

---

## Closing the branch

- [ ] **Run the whole suite on a clean build, five times**

```bash
cd ElliotKit && rm -rf .build && swift build
for i in 1 2 3 4 5; do swift test 2>&1 | tail -3; done
```

Expected: five runs reporting the same test count, all passing. A single sample cannot detect an intermittent regression; that is how a defect failing 53 % of the time once reached `main` past 21 single-sample merges.

- [ ] **Confirm the branch, then push**

```bash
git rev-parse --abbrev-ref HEAD
git push -u origin "$(git rev-parse --abbrev-ref HEAD)"
git rev-parse --abbrev-ref HEAD
git rev-parse HEAD "origin/$(git rev-parse --abbrev-ref HEAD)"
```

Expected: the two SHAs printed by the last command are identical. A `git push -u` that succeeds does not prove the right content left; several agent worktrees share this repository's `.git`, and the branch under your feet can change between two commands.
