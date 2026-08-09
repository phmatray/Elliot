# Auto-dev PR6 — The agent that fills in — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship `SkillKind.appraiseCards` — a read-only, one-run-per-card agent that writes `effort`, `evidence` and `appraisedAt` onto unmeasured cards from an artifact or not at all — together with the guard no transition provides for it.

**Architecture:** A new `SkillKind` case carries a `cardID`, which satisfies the `skillRun` XOR check without a migration and buys card ownership through `activeRun(cardID:)`. `SkillKind.isReadOnly` replaces five hand-written `kind == .analyzeRepo` comparisons in `RunScheduler` so the appraisal gets the analysis lane; `RunScheduler.finish` stops routing on a boolean and switches exhaustively on `run.kind` into three completions. The Preflight refusal that lived on a SwiftUI property moves down into a pure `ElliotModel` rule with three callers, because an appraisal run passes through no `evaluateMove`, no `allowsSideEffects` and no `repoPreflight`.

**Tech Stack:** Swift 6.3.1, SwiftPM, swift-testing, GRDB 7, SQLite, `claude -p --output-format stream-json`, `Scripts/fake-claude.sh`.

## Global Constraints

- Swift tools-version **6.3.1** — the patch is load-bearing, never `6.3` (SwiftPM resolves a bare `6.3` as `6.3.0`). `swiftLanguageModes: [.v6]`, deployment target macOS 15.
- Strict concurrency is on: every type crossing an isolation boundary must be `Sendable`.
- Build: `cd ElliotKit && swift build` · Tests: `cd ElliotKit && swift test`.
- One suite: `cd ElliotKit && swift test --filter <TypeName>` — the filter matches the **type** name, not the `@Suite` display name.
- ⚠ A filter matching nothing prints `warning: No matching test cases were run` and **exits 0** — indistinguishable from success. Never conclude from exit 0 alone; read the `Test run with N tests passed` line.
- Test framework is **swift-testing** (`@Suite`, `@Test`, `#expect`, `#require`), never XCTest.
- ⛔ Never run `swift format` over the tree. The code is hand-formatted, 4 spaces, 110 columns. Format the lines you write by hand, to match their neighbours.
- Every asynchronous wait in a test is **bounded**, through `withTimeout` from the `TestSupport` target. No assertion measures an absolute duration. No test sleeps a fixed interval.
- ⛔ Nothing in production code waits on `Process.waitUntilExit()`.
- Migrations are additive and shipped ones are frozen. The last registered is `v8_prStatus` (`ElliotKit/Sources/ElliotStore/Migrations.swift:138`). A renumbering ships its `RenamedMigration` in the same diff (`Migrations.swift:194-202`). **This plan adds no migration.**
- Commits: Conventional Commits with the layer as scope — `feat(model|store|process|engine|ipc|mcp|app): subject`.
- Branch: `feat/<issue>-<slug>` or `fix/<issue>-<slug>`. The number first, followed by a hyphen.
- ⚠ Several worktrees share this repository's `.git`. Re-read `git rev-parse --abbrev-ref HEAD` immediately **before** every commit and immediately **after** every push.
- A stale `.build` produces impossible failures (wrong enum values, link errors, SIGBUS). After any checkout that crosses commits: `rm -rf ElliotKit/.build` before believing a failure.
- One green run does not clear a suite. Sample five times after a clean build — it costs about eight seconds.

---

## Prerequisites — symbols this plan consumes from PR1 and PR2

This plan is written to land **after PR2** (`docs/superpowers/specs/2026-08-08-auto-dev-design.md`, delivery order §2). Verify these exist before Task 1; if any is missing, PR2 has not landed and Tasks 6, 8, 9 and 14 will not compile.

```bash
cd /Users/phmatray/Repositories/phmatray/private/Elliot/.claude/worktrees/precious-beaming-wand
grep -n "case unstated" ElliotKit/Sources/ElliotModel/StoryProposal.swift
grep -n "var effort: Effort?\|var evidence: \[Evidence\]?\|var appraisedAt: Date?" \
    ElliotKit/Sources/ElliotModel/Card.swift
```

Expected:

| symbol | file | shape |
|---|---|---|
| `Effort.unstated` | `ElliotModel/StoryProposal.swift` | a case of `public enum Effort: String, Codable, CaseIterable, Sendable, Hashable`; `Effort.parse(_:)` returns it for anything unrecognised, including `""` |
| `Card.effort` | `ElliotModel/Card.swift` | `public var effort: Effort?` |
| `Card.evidence` | `ElliotModel/Card.swift` | `public var evidence: [Evidence]?` |
| `Card.appraisedAt` | `ElliotModel/Card.swift` | `public var appraisedAt: Date?` |

**The joint constraint, stated as the spec requires it (spec §PR2, "Effort gains unstated"):** adding `.unstated` in PR2 without imposing it on this decoder changes nothing, and imposing it here without PR2 does not compile. Task 6 pins it with an executable assertion — `#expect(Effort.parse("") == .unstated)` — so the dependency fails loudly at `swift test` rather than quietly reintroducing the `.medium` fallback this feature exists to remove.

**Out of scope, deliberately.** This PR ships no wire case, no MCP tool and no control on screen; the spec's delivery order (§4) names that cost. Until PR4 or PR5 arrives, `AppraisalService` is reached from tests only.

**`CardFieldWritersTests` needs no widening here, and that is a measurement rather than an omission.** The spec (§PR2) says "PR2 and PR6 widen the protected set at the exact moment an unattended agent becomes a writer", and that test reads `RunScheduler.swift`, `Reconciler.swift` and `PRWatcher.swift` for `issueNumber|issueURL|prNumber|prURL|branch|lastError|effort|evidence` followed by ` = `. PR6 adds no card-field write to any of those three: the new writer is `BoardStore.applyAppraisal` (Task 8), it is named in its own doc comment as the fourth, and it can write nothing but the three columns. Task 3 *removes* a write from `Reconciler` rather than adding one. If PR2 shipped that suite, run it after Task 3 and after Task 10 — `cd ElliotKit && swift test --filter CardFieldWritersTests` — and expect PASS, unchanged.

---

## File Structure

### Created

| File | Responsibility |
|---|---|
| `ElliotKit/Sources/ElliotModel/AppraisalPromptBuilder.swift` | The prompt an appraisal run is given. Pure; announces exactly one artifact path through `AnalysisPromptBuilder.outputMarker`. |
| `ElliotKit/Sources/ElliotModel/AppraisalDecoder.swift` | Turns an artifact into an `Appraisal` or into nothing, never throwing and never dropping silently. |
| `ElliotKit/Sources/ElliotModel/UnattendedStartRefusal.swift` | The one rule saying whether an unattended agent may start against a repository. Pure; three callers. |
| `ElliotKit/Sources/ElliotEngine/EvidenceResolver.swift` | Resolves cited paths against a repository root, with the containment check. Extracted from `ProposalHarvester` so the appraisal cannot re-derive it wrong. |
| `ElliotKit/Sources/ElliotEngine/AppraisalHarvester.swift` | Reads the artifact **or nothing**, and writes the three card fields through the store's one-transaction method. |
| `ElliotKit/Sources/ElliotEngine/RepoGate.swift` | `RepoGating` protocol, `PreflightGate` (the real one), `OpenGate` (refuses nothing). |
| `ElliotKit/Sources/ElliotEngine/AppraisalService.swift` | Starts one appraisal run for one card: gate, claim, prompt, launch. |
| `ElliotKit/Tests/ElliotModelTests/SkillKindReadOnlyTests.swift` | Every `SkillKind` is classified read-only or not, by `allCases`. |
| `ElliotKit/Tests/ElliotModelTests/AppraisalPromptBuilderTests.swift` | One marker, absolute path, marker sanitised out of card text. |
| `ElliotKit/Tests/ElliotModelTests/AppraisalDecoderTests.swift` | Empty, malformed, partial and good artifacts; the `Effort.unstated` pin. |
| `ElliotKit/Tests/ElliotModelTests/UnattendedStartRefusalTests.swift` | The rule's three answers and its ordering. |
| `ElliotKit/Tests/ElliotModelTests/AppraisalPermissionModeTests.swift` | `PermissionMode.appraisal(repo:)` for all six modes. |
| `ElliotKit/Tests/ElliotEngineTests/SchedulerReadOnlyLaneTests.swift` | **The witness `SchedulerLimitsAdmissionTests` lacks**: an appraisal starts against a full writer cap, and is held by the analysis cap. |
| `ElliotKit/Tests/ElliotEngineTests/EvidenceResolverTests.swift` | Inside, missing, and the sibling-directory escape. |
| `ElliotKit/Tests/ElliotEngineTests/AppraisalHarvesterTests.swift` | Absent, empty, malformed and good artifacts; never `resultText`. Task 10 appends a **second** suite to this same file, `SchedulerFinishRoutingTests`, which reads `RunScheduler.swift` as text. |
| `ElliotKit/Tests/ElliotEngineTests/ReadOnlyOrphanTests.swift` | An orphaned appraisal is not verified against `gh`. |
| `ElliotKit/Tests/ElliotEngineTests/AppraisalInvocationTests.swift` | The argv an appraisal is spawned with: tighter mode, artifact directory. |
| `ElliotKit/Tests/ElliotEngineTests/AppraisalServiceTests.swift` | The gate, the claim, and the card write window **in both directions**. |
| `ElliotKit/Tests/ElliotEngineTests/AppraisalEndToEndTests.swift` | The whole path against `Scripts/fake-claude.sh`. |
| `ElliotKit/Tests/ElliotStoreTests/AppraisalStoreTests.swift` | `applyAppraisal` in one transaction; `claimCardForRun` as a compare-and-set. |
| `Fixtures/appraisal/e2e-small.json` | The artifact the fake `claude` drops for the end-to-end test. |
| `Fixtures/appraisal/not-an-object.json` | Valid JSON that is not an object. Named for what it *is*, and the name Task 15 writes and reads — a second spelling of it here would be a fixture the end-to-end test looks for and never finds. |

### Modified

| File | Change |
|---|---|
| `ElliotKit/Sources/ElliotModel/SlashCommandBuilder.swift:14-53` | `SkillKind.appraiseCards`; `skillName`; `slashName`; new `isReadOnly`. |
| `ElliotKit/Sources/ElliotModel/Repo.swift:52-59` | `PermissionMode.appraisal(repo:)` in an extension below the enum. |
| `ElliotKit/Sources/ElliotModel/Card.swift` | Nothing. Listed to be explicit: PR2 owns the three columns. |
| `ElliotKit/Sources/ElliotAppKit/Consequence.swift:91-101` | `reason(.repoDisabled)` reads `UnattendedStartRefusal.repoDisabled.sentence`. |
| `ElliotKit/Sources/ElliotAppKit/AppModel.swift:546-548,1929-1938` | Passes a `PreflightGate`; `analysisRefusal` reads the pure rule back. |
| `ElliotKit/Sources/ElliotProcess/ClaudeRunner.swift:5-71` | `ClaudeInvocation.extraDirectories`, emitted as repeated `--add-dir`. |
| `ElliotKit/Sources/ElliotEngine/Verifier.swift:19-30` | `.appraiseCards` joins the unreachable-by-construction branch. |
| `ElliotKit/Sources/ElliotEngine/RunScheduler.swift:180,219-241,333-357,417-506` | `isReadOnly` at five sites; `invocation(for:repo:perRunUSD:)`; `finish` switches on kind; `treeBaselines` erased above the routing; one shared sentinel. |
| `ElliotKit/Sources/ElliotEngine/Reconciler.swift:57-65` | An orphaned **read-only** run is reported, never verified against `gh`. |
| `ElliotKit/Sources/ElliotEngine/ProposalHarvester.swift:56,114-138` | `resolve` becomes a call into `EvidenceResolver`. |
| `ElliotKit/Sources/ElliotEngine/AnalysisService.swift:6-22,29-59` | `AnalysisError.repoRefused`; `.repoDisabled` removed; `gate` stored; `start` consults the rule. |
| `ElliotKit/Sources/ElliotEngine/MCPRequestHandler.swift:130-154` | `.repoRefused` mapped to `analysisRefused`. |
| `ElliotKit/Sources/ElliotStore/BoardStore.swift:429-433,741-754` | `applyAppraisal(cardID:effort:evidence:at:)`, `claimCardForRun(_:)`. |
| `ElliotKit/Tests/ElliotEngineTests/AnalysisSchedulingTests.swift:36-42` | `.appraiseCards` added to the admission argument list. |
| `ElliotKit/Tests/ElliotEngineTests/{OfflineParityTests,AnalysisEndToEndTests,AnalysisServiceTests,MCPRequestHandlerTests,ScreenshotHandlerTests}.swift` | Each `AnalysisService(…)` states its gate. |
| `ElliotKit/Tests/ElliotAppKitTests/AppModelTests.swift:1028-1036` | Same. |
| `ElliotKit/Tests/ElliotModelTests/NextStepTests.swift:55-59` | `appraise-cards` joins the skill-name assertions. |

⚠ **Every line number in this plan is read against `main` as it stands before Task 1, and four tasks edit `RunScheduler.swift` in sequence — 1, 2, 10, 11.** Task 2 grows `refusal(for:overBudget:)` by a few lines and Task 11 inserts a whole function above `start`, so by the time Task 10 runs, its "line 352" and "lines 434-446" have moved, and Task 11's "line 333" has moved twice. Each step also names the construct it means — `finish`'s routing block, the stored property beside `harvester`, the invocation literal in `start`. **Locate by the name; treat the number as a hint at where to start looking.** The same caution applies to `AppModel.swift` (Tasks 12 and 13) and `AnalysisService.swift` (Task 13 alone, so its numbers hold).

---

### Task 1: `SkillKind.appraiseCards` and `SkillKind.isReadOnly`

**Files:**
- Modify: `ElliotKit/Sources/ElliotModel/SlashCommandBuilder.swift:14-53`
- Modify: `ElliotKit/Sources/ElliotEngine/Verifier.swift:19-30`
- Modify: `ElliotKit/Sources/ElliotEngine/RunScheduler.swift:231-241`
- Modify: `ElliotKit/Tests/ElliotModelTests/NextStepTests.swift:55-59`
- Test: `ElliotKit/Tests/ElliotModelTests/SkillKindReadOnlyTests.swift`

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces:
  - `SkillKind.appraiseCards` — a case of `public enum SkillKind: String, Codable, CaseIterable, Sendable, Hashable`. Raw value `"appraiseCards"` (persisted in `skillRun.kind`).
  - `SkillKind.skillName -> String` returns `"appraise-cards"` for it; `SkillKind.slashName -> String?` returns `nil`.
  - `public var isReadOnly: Bool` on `SkillKind` — `true` for `.analyzeRepo` and `.appraiseCards`, `false` for the three writers.

- [ ] **Step 1: Write the failing test**

Create `ElliotKit/Tests/ElliotModelTests/SkillKindReadOnlyTests.swift`:

```swift
import Testing

@testable import ElliotModel

/// `isReadOnly` decides the scheduling lane and whether the working-tree
/// sentinel is armed, and one of its five readers in `RunScheduler` is a
/// **negation** the compiler cannot check. So every case is named here, and the
/// two sets are required to partition `allCases`: a sixth kind that nobody
/// classifies fails this suite instead of silently joining the writers.
@Suite("Skill kinds — which ones only read")
struct SkillKindReadOnlyTests {

    @Test("The three plugin skills write")
    func writersWrite() {
        #expect(SkillKind.createIssue.isReadOnly == false)
        #expect(SkillKind.implementIssue.isReadOnly == false)
        #expect(SkillKind.mergePR.isReadOnly == false)
    }

    @Test("An analysis and an appraisal only read")
    func readersRead() {
        #expect(SkillKind.analyzeRepo.isReadOnly)
        #expect(SkillKind.appraiseCards.isReadOnly)
    }

    @Test("Every kind is classified, and the two sets cover allCases")
    func theSetsPartitionAllCases() {
        let readers = SkillKind.allCases.filter(\.isReadOnly)
        let writers = SkillKind.allCases.filter { !$0.isReadOnly }
        #expect(readers.count + writers.count == SkillKind.allCases.count)
        #expect(Set(readers) == [.analyzeRepo, .appraiseCards])
        #expect(Set(writers) == [.createIssue, .implementIssue, .mergePR])
    }

    @Test("An appraisal is Elliot's own prompt, not a plugin skill")
    func appraisalHasNoSlashCommand() {
        #expect(SkillKind.appraiseCards.skillName == "appraise-cards")
        #expect(SkillKind.appraiseCards.slashName == nil)
    }

    @Test("The raw value is what lands in skillRun.kind, and it is stable")
    func rawValueIsPersisted() {
        // Named here because it is a **storage** decision: this string is
        // written into every appraisal run's row, and changing it later would
        // orphan them all with no migration to notice.
        #expect(SkillKind.appraiseCards.rawValue == "appraiseCards")
        #expect(SkillKind(rawValue: "appraiseCards") == .appraiseCards)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd ElliotKit && swift test --filter SkillKindReadOnlyTests`

Expected: FAIL to compile, with
`error: type 'SkillKind' has no member 'appraiseCards'`
and
`error: value of type 'SkillKind' has no member 'isReadOnly'`.

- [ ] **Step 3: Write minimal implementation**

In `ElliotKit/Sources/ElliotModel/SlashCommandBuilder.swift`, add the case after `.analyzeRepo` (line 19):

```swift
    /// Reading one card, and the repository around it, to fill in the signals a
    /// hand-written card never carried. Read-only, and not a plugin skill —
    /// Elliot owns this prompt, the same way it owns the analysis one.
    case appraiseCards
```

Add to `skillName` (after `case .analyzeRepo: "analyze-repo"`):

```swift
        case .appraiseCards: "appraise-cards"
```

Add to `slashName` (after `case .analyzeRepo: nil`):

```swift
        case .appraiseCards: nil
```

Add, after the `slashName` property and before the closing brace of the enum:

```swift
    /// Whether this kind may only read.
    ///
    /// It decides two things at once: which scheduling lane a run is admitted
    /// into, and whether the working-tree sentinel is armed before it spawns.
    /// Both were written five times over as `kind == .analyzeRepo` in
    /// `RunScheduler`, which was exactly true until an appraisal became the
    /// second read-only kind — and one of those five is a negation
    /// (`filter { !$0.kind.isReadOnly }`) that no compiler checks, which is why
    /// it ships with its own witness in `SchedulerReadOnlyLaneTests`.
    ///
    /// A `switch` and not a set membership: a sixth kind is a compile error
    /// here rather than a silent default into the writer lane, where it would
    /// consume the cap that exists to keep two builds out of one `.build/`.
    ///
    /// `public`, and not by habit: `RunScheduler` and `Reconciler` live in
    /// `ElliotEngine` and read this across a module boundary, where an
    /// internal member is invisible. The two neighbours here — `skillName`
    /// and `slashName` — are `public` for the same reason.
    public var isReadOnly: Bool {
        switch self {
        case .createIssue, .implementIssue, .mergePR: false
        case .analyzeRepo, .appraiseCards: true
        }
    }
```

In `ElliotKit/Sources/ElliotEngine/Verifier.swift`, replace lines 26-29 with:

```swift
            case .analyzeRepo, .appraiseCards:
                // Unreachable: read-only runs are completed by their own
                // harvesters, and there is nothing on GitHub to check an
                // opinion or an estimate against. `RunScheduler.finish`
                // switches on `run.kind` so this branch cannot be reached by a
                // routing mistake — it exists so the switch stays total.
                return .unverified(reason: "A read-only run has no GitHub outcome to verify.")
```

In `ElliotKit/Sources/ElliotEngine/RunScheduler.swift`, replace line 238 with:

```swift
        case .implementIssue, .analyzeRepo, .appraiseCards:
```

In `ElliotKit/Tests/ElliotModelTests/NextStepTests.swift`, after line 58, add:

```swift
        #expect(SkillKind.appraiseCards.skillName == "appraise-cards")
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd ElliotKit && swift test --filter SkillKindReadOnlyTests`

Expected: PASS — `Test run with 5 tests passed`.

Then confirm nothing else broke: `cd ElliotKit && swift build`. Expected: no errors.

- [ ] **Step 5: Commit**

```bash
git rev-parse --abbrev-ref HEAD
git add ElliotKit/Sources/ElliotModel/SlashCommandBuilder.swift \
        ElliotKit/Sources/ElliotEngine/Verifier.swift \
        ElliotKit/Sources/ElliotEngine/RunScheduler.swift \
        ElliotKit/Tests/ElliotModelTests/SkillKindReadOnlyTests.swift \
        ElliotKit/Tests/ElliotModelTests/NextStepTests.swift
git commit -m "feat(model): a read-only skill kind for appraising cards"
```

---

### Task 2: The read-only lane in the scheduler

**Files:**
- Modify: `ElliotKit/Sources/ElliotEngine/RunScheduler.swift:179-241`
- Modify: `ElliotKit/Tests/ElliotEngineTests/AnalysisSchedulingTests.swift:36-42`
- Test: `ElliotKit/Tests/ElliotEngineTests/SchedulerReadOnlyLaneTests.swift`

**Interfaces:**
- Consumes: `SkillKind.appraiseCards`, `SkillKind.isReadOnly` (Task 1).
- Produces:
  - `RunScheduler.occupancy: (writers: Int, analyses: Int)` now counts every read-only kind as an "analysis".
  - `RunScheduler.refusal(for:overBudget:) -> QueueRefusal?` admits `.appraiseCards` into the analysis lane, returning `.analysisCapReached(inFlight:cap:)` when that lane is full.
  - No signature change; the behaviour change is what later tasks rely on.

- [ ] **Step 1: Write the failing test**

Create `ElliotKit/Tests/ElliotEngineTests/SchedulerReadOnlyLaneTests.swift`:

```swift
import ElliotModel
import ElliotProcess
import ElliotStore
import Foundation
import Testing

@testable import ElliotEngine

/// The witness `SchedulerLimitsAdmissionTests` does not have.
///
/// `refusal(for:)` counts the writer lane with `filter { !$0.kind.isReadOnly }`
/// — a **negation**, which the compiler does not check. Inverted, every
/// appraisal would consume the writer cap that exists to keep two builds out of
/// one `.build/`, and every writer would be admitted without one. Both halves
/// are asserted here, so the inversion cannot ship green.
///
/// Nothing spawns: `testOnlyMarkInFlight` seeds the in-flight set and
/// `refusal(for:overBudget:)` is asked directly, which is what `pump()` does.
@Suite("Scheduler — the read-only lane")
struct SchedulerReadOnlyLaneTests {

    private func scheduler(_ limits: SchedulerLimits) throws -> RunScheduler {
        let store = try BoardStore.inMemory()
        let config = ToolConfig(
            claudePath: "/usr/bin/true", ghPath: "/usr/bin/true",
            gitPath: "/usr/bin/true", environment: [:]
        )
        return RunScheduler(
            store: store, toolConfig: config,
            verifier: Verifier(gh: .init(config: config)), limits: limits
        )
    }

    /// Distinct repositories by default, so the same-repo merge rule never
    /// decides a case this suite means to be about the caps.
    private func run(_ kind: SkillKind, repo: UUID = UUID()) -> SkillRun {
        SkillRun(
            cardID: kind == .analyzeRepo ? nil : UUID(),
            repoID: repo,
            analysisID: kind == .analyzeRepo ? UUID() : nil,
            kind: kind, prompt: "x", cwd: "/tmp",
            logPath: "/tmp/a", stderrPath: "/tmp/b", createdAt: Date()
        )
    }

    @Test("An appraisal starts even when the writer cap is full")
    func appraisalIgnoresTheWriterCap() async throws {
        let scheduler = try scheduler(SchedulerLimits(maxConcurrent: 2, maxConcurrentAnalyses: 3))
        await scheduler.testOnlyMarkInFlight(run(.implementIssue))
        await scheduler.testOnlyMarkInFlight(run(.createIssue))
        // The writer lane is full — proved, not assumed.
        #expect(
            await scheduler.refusal(for: run(.implementIssue), overBudget: false)
                == .writerCapReached(inFlight: 2, cap: 2)
        )
        // And the appraisal is admitted anyway, because it is not a writer.
        #expect(await scheduler.refusal(for: run(.appraiseCards), overBudget: false) == nil)
    }

    @Test("An appraisal is held by the analysis cap, and says which cap")
    func appraisalCountsAgainstTheAnalysisCap() async throws {
        let scheduler = try scheduler(SchedulerLimits(maxConcurrent: 4, maxConcurrentAnalyses: 2))
        await scheduler.testOnlyMarkInFlight(run(.analyzeRepo))
        await scheduler.testOnlyMarkInFlight(run(.appraiseCards))
        #expect(
            await scheduler.refusal(for: run(.appraiseCards), overBudget: false)
                == .analysisCapReached(inFlight: 2, cap: 2)
        )
        // Naming the right cap matters: "writer cap reached" here would send the
        // reader to raise a limit that is not the block.
        #expect(await scheduler.refusal(for: run(.implementIssue), overBudget: false) == nil)
    }

    @Test("Two appraisals in flight do not make a writer look capped")
    func appraisalsDoNotConsumeTheWriterCap() async throws {
        let scheduler = try scheduler(SchedulerLimits(maxConcurrent: 1, maxConcurrentAnalyses: 3))
        await scheduler.testOnlyMarkInFlight(run(.appraiseCards))
        await scheduler.testOnlyMarkInFlight(run(.appraiseCards))
        #expect(await scheduler.refusal(for: run(.implementIssue), overBudget: false) == nil)
    }

    @Test("Occupancy counts an appraisal on the reading side")
    func occupancySeparatesReadersFromWriters() async throws {
        let scheduler = try scheduler(.default)
        await scheduler.testOnlyMarkInFlight(run(.implementIssue))
        await scheduler.testOnlyMarkInFlight(run(.analyzeRepo))
        await scheduler.testOnlyMarkInFlight(run(.appraiseCards))
        let occupancy = await scheduler.occupancy
        #expect(occupancy.writers == 1)
        #expect(occupancy.analyses == 2)
    }

    @Test("A merge still waits for an appraisal in the same repository")
    func mergeWaitsForAnAppraisal() async throws {
        // `.mergePR` waits for the repository to be idle, and an appraisal reads
        // the working tree — the same reason an analysis makes it wait.
        let scheduler = try scheduler(SchedulerLimits(maxConcurrent: 8, maxConcurrentAnalyses: 8))
        let repo = UUID()
        await scheduler.testOnlyMarkInFlight(run(.appraiseCards, repo: repo))
        #expect(
            await scheduler.refusal(for: run(.mergePR, repo: repo), overBudget: false)
                == .mergeWaitsForRepoToBeIdle
        )
    }

    @Test("An appraisal waits for a merge in the same repository")
    func appraisalWaitsForAMerge() async throws {
        let scheduler = try scheduler(SchedulerLimits(maxConcurrent: 8, maxConcurrentAnalyses: 8))
        let repo = UUID()
        await scheduler.testOnlyMarkInFlight(run(.mergePR, repo: repo))
        #expect(
            await scheduler.refusal(for: run(.appraiseCards, repo: repo), overBudget: false)
                == .mergeInFlightInRepo
        )
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd ElliotKit && swift test --filter SchedulerReadOnlyLaneTests`

Expected: FAIL, with `appraisalIgnoresTheWriterCap` reporting
`Expectation failed: (await scheduler.refusal(for: run(.appraiseCards), overBudget: false) → .writerCapReached(inFlight: 2, cap: 2)) == nil`
— because `.appraiseCards` is still counted as a writer.

- [ ] **Step 3: Write minimal implementation**

In `ElliotKit/Sources/ElliotEngine/RunScheduler.swift`, replace line 180:

```swift
        let analyses = inFlight.values.filter(\.kind.isReadOnly).count
```

Replace lines 219-229 with:

```swift
        if run.kind.isReadOnly {
            let readersInFlight = inFlight.values.filter(\.kind.isReadOnly).count
            guard readersInFlight >= limits.maxConcurrentAnalyses else { return nil }
            return .analysisCapReached(
                inFlight: readersInFlight, cap: limits.maxConcurrentAnalyses)
        }

        // ⚠ A negation, and the compiler does not check it. Inverted, every
        // appraisal consumes the writer cap and every writer skips it.
        // `SchedulerReadOnlyLaneTests` is the witness.
        let writersInFlight = inFlight.values.filter { !$0.kind.isReadOnly }.count
        guard writersInFlight < limits.maxConcurrent else {
            return .writerCapReached(inFlight: writersInFlight, cap: limits.maxConcurrent)
        }
```

Widen the doc comment above `canStart` (lines 193-197) by replacing the sentence beginning "An analysis only reads":

```swift
    /// A read-only run — an analysis, or an appraisal of one card — only reads,
    /// but it reads the working tree, so it must not overlap a merge in the same
    /// repo: it would see a moving target, and the git sentinel would fire on
    /// someone else's work. Read-only runs get their own lane because the cap
    /// below exists to keep two *builds* out of one `.build/`, and neither of
    /// them builds anything.
```

In `ElliotKit/Tests/ElliotEngineTests/AnalysisSchedulingTests.swift`, replace line 37's argument list:

```swift
          arguments: [
            (SkillKind.mergePR, false), (.implementIssue, true), (.createIssue, true),
            (.analyzeRepo, true), (.appraiseCards, true),
          ])
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd ElliotKit && swift test --filter SchedulerReadOnlyLaneTests`

Expected: PASS — `Test run with 6 tests passed`.

Then the neighbours, which must be unchanged:
`cd ElliotKit && swift test --filter SchedulerLimitsAdmissionTests` — PASS.
`cd ElliotKit && swift test --filter AnalysisSchedulingTests` — PASS.

- [ ] **Step 5: Commit**

```bash
git rev-parse --abbrev-ref HEAD
git add ElliotKit/Sources/ElliotEngine/RunScheduler.swift \
        ElliotKit/Tests/ElliotEngineTests/SchedulerReadOnlyLaneTests.swift \
        ElliotKit/Tests/ElliotEngineTests/AnalysisSchedulingTests.swift
git commit -m "feat(engine): admit every read-only run into the reading lane"
```

---

### Task 3: An orphaned read-only run is reported, never verified against `gh`

**Files:**
- Modify: `ElliotKit/Sources/ElliotEngine/Reconciler.swift:57-65`
- Test: `ElliotKit/Tests/ElliotEngineTests/ReadOnlyOrphanTests.swift`

**Interfaces:**
- Consumes: `SkillKind.isReadOnly` (Task 1).
- Produces: `Reconciler.sweep()` unchanged in signature; an orphaned `.appraiseCards` run now takes the report branch instead of the verify branch, so it never writes `card.lastError`.

**Why this is a task and not a footnote.** `Reconciler.swift:57` reads `if run.isAnalysis`, which is `kind == .analyzeRepo`. An appraisal run carries a `cardID`, so an orphan would fall into the `else if let cardID` branch at `:65`, be handed to `Verifier.verify`, come back `.unverified(reason:)`, and `CardOutcome.applied` writes that reason into `card.lastError` (`ElliotModel/CardOutcome.swift:109-110`). A Backlog card that has never had an issue would come back from a crash wearing an error banner about a pull request it does not have.

- [ ] **Step 1: Write the failing test**

Create `ElliotKit/Tests/ElliotEngineTests/ReadOnlyOrphanTests.swift`:

```swift
import ElliotModel
import ElliotProcess
import ElliotStore
import Foundation
import Testing

@testable import ElliotEngine

/// The launch sweep, on a run that carries a card but has nothing on GitHub.
///
/// `Reconciler` split orphans on `run.isAnalysis`, which is
/// `kind == .analyzeRepo`. An appraisal carries a `cardID`, so it took the
/// other branch: verified against `gh`, answered `.unverified`, and
/// `CardOutcome.applied` writes that sentence into `card.lastError`. A Backlog
/// card that has never been filed would come back from a crash wearing an error
/// banner about a pull request it does not have.
@Suite("Reconciler — a read-only orphan")
struct ReadOnlyOrphanTests {

    /// A mover that records rather than acts, so a move the sweep should not
    /// make is visible instead of silently applied.
    private final class MoveSpy: SystemMoving, @unchecked Sendable {
        private let lock = NSLock()
        private var _moves: [(UUID, ElliotModel.Column)] = []
        var moves: [(UUID, ElliotModel.Column)] { lock.withLock { _moves } }
        func applySystemMove(
            cardID: UUID, to: ElliotModel.Column, reason: MoveOrigin.SystemReason
        ) async {
            lock.withLock { _moves.append((cardID, to)) }
        }
    }

    private final class InertLauncher: RunLaunching, @unchecked Sendable {
        func launch(runID: UUID) async {}
        func cancel(runID: UUID) async {}
    }

    @Test("An appraisal killed by a crash reports itself instead of asking gh")
    func appraisalOrphanIsReportedNotVerified() async throws {
        let store = try BoardStore.inMemory()
        let config = ToolConfig(
            claudePath: "/usr/bin/false", ghPath: "/usr/bin/false",
            gitPath: "/usr/bin/false", environment: [:]
        )
        let repo = Repo(path: "/tmp/r", nameWithOwner: "phmatray/Elliot", displayName: "Elliot")
        try await store.saveRepo(repo)
        let now = Date()
        let card = Card(
            repoID: repo.id, title: "Unfiled story",
            columnEnteredAt: now, createdAt: now, updatedAt: now
        )
        try await store.saveCard(card)

        var run = SkillRun.card(
            cardID: card.id, repoID: repo.id, kind: .appraiseCards, prompt: "…",
            cwd: repo.path, logPath: "/tmp/a.ndjson", stderrPath: "/tmp/a.log",
            createdAt: now
        )
        run.state = .running
        try await store.saveRun(run)

        let mover = MoveSpy()
        let summary = await Reconciler(
            store: store, verifier: Verifier(gh: .init(config: config)),
            mover: mover, launcher: InertLauncher()
        ).sweep()

        #expect(summary.orphanedRuns == 1)
        // Reported, not corrected: nothing about this run says anything about
        // the card.
        #expect(summary.cardsCorrected == 0)

        let swept = try #require(try await store.run(id: run.id))
        #expect(swept.state == .failed)
        // Its own report, and no verdict: there was never anything on GitHub to
        // check an estimate against.
        #expect(swept.verifiedOutcome == nil)

        // The card is untouched. Asserted **before** the `#require` below, on
        // purpose: a `#require` that fails throws and ends the test, so putting
        // the consequence after the report would hide it behind an absent
        // `analysisReport` in exactly the run this suite is about.
        let after = try #require(try await store.card(id: card.id))
        #expect(after.lastError == nil)
        #expect(after.column == .backlog)
        #expect(mover.moves.isEmpty)

        let report = try #require(swept.analysisReport)
        #expect(report.harvestSource == .none)
        #expect(report.dropped.contains { $0.contains("harvested") })
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd ElliotKit && swift test --filter ReadOnlyOrphanTests`

Expected: FAIL, four expectations, in this order — the appraisal is still taking the `gh` branch, so it gets a verdict, that verdict is written onto the card, and no report is ever written:

```
Expectation failed: (summary.cardsCorrected → 1) == 0
Expectation failed: (swept.verifiedOutcome → Optional(.unverified(reason: "A read-only run has no GitHub outcome to verify."))) == nil
Expectation failed: (after.lastError → Optional("A read-only run has no GitHub outcome to verify.")) == nil
Expectation failed: try #require(swept.analysisReport) → nil
```

The last one throws, which ends the test — that is why the card assertions sit above it.

- [ ] **Step 3: Write minimal implementation**

In `ElliotKit/Sources/ElliotEngine/Reconciler.swift`, replace lines **57-65** — that is, from `if run.isAnalysis {` through the `} else if let cardID = run.cardID,` line, which the replacement below re-emits. (Stopping at 64 would leave the old `} else if` in place and the new one below it.)

```swift
                if run.kind.isReadOnly {
                    // The artifact may well have been written before the app
                    // died, but the sentinel baseline died with it — say so
                    // rather than claim the tree was clean.
                    //
                    // `kind.isReadOnly` and not `isAnalysis`: an appraisal run
                    // carries a `cardID`, so the boolean sent it down the other
                    // branch, where `Verifier` answered `.unverified` and
                    // `CardOutcome.applied` wrote that sentence into
                    // `card.lastError` — an error banner about a pull request
                    // the card has never had.
                    orphan.analysisReport = AnalysisRunReport(
                        harvestSource: .none,
                        dropped: ["Elliot stopped before this run was harvested."]
                    )
                } else if let cardID = run.cardID,
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd ElliotKit && swift test --filter ReadOnlyOrphanTests`

Expected: PASS — `Test run with 1 test passed`.

Then, because the sentence in the analysis branch changed:
`cd ElliotKit && swift test --filter EndToEndSuites` — PASS.

- [ ] **Step 5: Commit**

```bash
git rev-parse --abbrev-ref HEAD
git add ElliotKit/Sources/ElliotEngine/Reconciler.swift \
        ElliotKit/Tests/ElliotEngineTests/ReadOnlyOrphanTests.swift
git commit -m "fix(engine): a read-only orphan reports itself instead of asking gh"
```

---

### Task 4: `StoreLocation.appraisalArtifactURL(runID:)`

**Files:**
- Modify: `ElliotKit/Sources/ElliotStore/StoreLocation.swift:54-70`
- Test: `ElliotKit/Tests/ElliotStoreTests/StoreLocationTests.swift`

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces:
  - `public static func appraisalRunDirectory(runID: UUID) -> URL`
  - `public static func appraisalArtifactURL(runID: UUID) -> URL` — the file, named `appraisal.json`.
  Both on `public enum StoreLocation` in `ElliotStore`.

- [ ] **Step 1: Write the failing test**

Append to `ElliotKit/Tests/ElliotStoreTests/StoreLocationTests.swift`, inside the `StoreLocationTests` suite (before its closing brace):

```swift
    /// An appraisal has no analysis to key on — that is the whole point of the
    /// `cardID` decision — so its artifact is keyed on the run alone.
    @Test("An appraisal artifact is keyed on its run, under the same owner-only tree")
    func appraisalArtifactIsKeyedOnTheRun() {
        _ = home
        let runID = UUID()
        let url = StoreLocation.appraisalArtifactURL(runID: runID)

        #expect(url.lastPathComponent == "appraisal.json")
        #expect(url.deletingLastPathComponent().lastPathComponent == runID.uuidString)
        // Under `analysesDirectory`, which `ensureDirectories` already creates
        // with 0o700 — one tree holds everything a read-only run writes.
        #expect(url.path.hasPrefix(StoreLocation.analysesDirectory.path + "/"))
        #expect(url.path.hasPrefix(StoreLocation.home.path))
    }

    @Test("Two appraisal runs never share a directory")
    func appraisalDirectoriesAreDistinct() {
        _ = home
        #expect(
            StoreLocation.appraisalRunDirectory(runID: UUID())
                != StoreLocation.appraisalRunDirectory(runID: UUID())
        )
        // The artifact sits inside the directory, so creating that directory is
        // enough for `--add-dir` to point at something that exists.
        let appraisals = StoreLocation.analysesDirectory
            .appendingPathComponent("appraisals", isDirectory: true)
        #expect(
            StoreLocation.appraisalArtifactURL(runID: UUID())
                .deletingLastPathComponent().path
                .hasPrefix(appraisals.path)
        )
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd ElliotKit && swift test --filter StoreLocationTests`

Expected: FAIL to compile, with
`error: type 'StoreLocation' has no member 'appraisalArtifactURL'`.

- [ ] **Step 3: Write minimal implementation**

In `ElliotKit/Sources/ElliotStore/StoreLocation.swift`, after `analysisArtifactURL` (line 70):

```swift
    /// One directory per appraisal run, holding the `appraisal.json` the run was
    /// told to write.
    ///
    /// Keyed on the run alone, where an analysis is keyed on `(analysisID,
    /// runID)`: an appraisal belongs to a **card**, not to an analysis, which is
    /// what lets it satisfy `skillRun`'s XOR check without a migration. There is
    /// therefore no analysis id to nest under — and the card's id is deliberately
    /// not used either, since an artifact keyed on the card would be overwritten
    /// by the next appraisal of that card, leaving an older run's report pointing
    /// at somebody else's file.
    ///
    /// Under `analysesDirectory` all the same, so `ensureDirectories` already
    /// creates the parent 0o700 and one owner-only tree holds everything a
    /// read-only run writes.
    public static func appraisalRunDirectory(runID: UUID) -> URL {
        analysesDirectory
            .appendingPathComponent("appraisals", isDirectory: true)
            .appendingPathComponent(runID.uuidString, isDirectory: true)
    }

    public static func appraisalArtifactURL(runID: UUID) -> URL {
        appraisalRunDirectory(runID: runID).appendingPathComponent("appraisal.json")
    }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd ElliotKit && swift test --filter StoreLocationTests`

Expected: PASS — `Test run with 6 tests passed`.

- [ ] **Step 5: Commit**

```bash
git rev-parse --abbrev-ref HEAD
git add ElliotKit/Sources/ElliotStore/StoreLocation.swift \
        ElliotKit/Tests/ElliotStoreTests/StoreLocationTests.swift
git commit -m "feat(store): a per-run home for an appraisal's artifact"
```

---

### Task 5: `AppraisalPromptBuilder`

**Files:**
- Create: `ElliotKit/Sources/ElliotModel/AppraisalPromptBuilder.swift`
- Test: `ElliotKit/Tests/ElliotModelTests/AppraisalPromptBuilderTests.swift`

**Interfaces:**
- Consumes: `AnalysisPromptBuilder.outputMarker` (`public static let outputMarker = "ELLIOT_OUTPUT="`, `ElliotModel/AnalysisPromptBuilder.swift:12`) and `AnalysisPromptBuilder.outputPath(in:) -> String?` (`:122`).
- Produces:
  ```swift
  public enum AppraisalPromptBuilder {
      public static var outputMarker: String       // AnalysisPromptBuilder's, not a second one
      public static let maxEvidence: Int           // 5
      public static func prompt(
          cardTitle: String,
          cardText: String,
          repoNameWithOwner: String,
          outputPath: String,
          maxEvidence: Int = AppraisalPromptBuilder.maxEvidence
      ) -> String
  }
  ```
  The announced path is recoverable with `AnalysisPromptBuilder.outputPath(in:)` — the same marker `Scripts/fake-claude.sh` greps for in shell.

- [ ] **Step 1: Write the failing test**

Create `ElliotKit/Tests/ElliotModelTests/AppraisalPromptBuilderTests.swift`:

```swift
import Testing

@testable import ElliotModel

/// The appraisal prompt, held to the one invariant its harvest cannot survive
/// being wrong about — exactly one announced artifact path — plus the two things
/// this prompt must say that the analysis one does not: that "unstated" is an
/// allowed answer, and that the run must not rank anything.
@Suite("Appraisal prompt")
struct AppraisalPromptBuilderTests {

    private func build(
        title: String = "Cache the login shell environment",
        text: String = "As a user, I want Elliot to start faster.",
        maxEvidence: Int = 5
    ) -> String {
        AppraisalPromptBuilder.prompt(
            cardTitle: title,
            cardText: text,
            repoNameWithOwner: "phmatray/Elliot",
            outputPath: "/tmp/elliot/analyses/appraisals/R/appraisal.json",
            maxEvidence: maxEvidence
        )
    }

    @Test("The prompt announces exactly one output path, and it is absolute")
    func exactlyOneAbsoluteOutputPath() throws {
        let prompt = build()
        let occurrences = prompt.components(separatedBy: AnalysisPromptBuilder.outputMarker).count - 1
        #expect(occurrences == 1)

        let path = try #require(AnalysisPromptBuilder.outputPath(in: prompt))
        #expect(path == "/tmp/elliot/analyses/appraisals/R/appraisal.json")
        #expect(path.hasPrefix("/"))
    }

    @Test("The marker is the analysis one, so one parser and one fake tool serve both")
    func theMarkerIsShared() {
        // Not a second marker string. `Scripts/fake-claude.sh` greps for
        // `ELLIOT_OUTPUT=`, and a prompt with its own marker would be invisible
        // to the harness that makes this whole path testable.
        #expect(AppraisalPromptBuilder.outputMarker == AnalysisPromptBuilder.outputMarker)
        #expect(build().contains(AnalysisPromptBuilder.outputMarker))
    }

    @Test("A path with spaces — the shape of the real home — is recovered whole")
    func pathsWithSpacesSurvive() {
        let path = "/Users/philippe/Library/Application  Support/Elliot/appraisals/R/appraisal.json"
        let prompt = AppraisalPromptBuilder.prompt(
            cardTitle: "t", cardText: "b",
            repoNameWithOwner: "phmatray/Elliot", outputPath: path
        )
        #expect(AnalysisPromptBuilder.outputPath(in: prompt) == path)
    }

    @Test("The card's own words reach the prompt, and the repository is named")
    func promptCarriesItsSubject() {
        let prompt = build(title: "Widen the queue band", text: "As a maintainer, I want more room.")
        #expect(prompt.contains("Widen the queue band"))
        #expect(prompt.contains("As a maintainer, I want more room."))
        #expect(prompt.contains("phmatray/Elliot"))
        #expect(prompt.lowercased().contains("do not modify"))
    }

    @Test("The prompt offers \"unstated\" and forbids a guess")
    func unstatedIsAnAllowedAnswer() {
        // The whole reason `Effort.unstated` exists. A prompt listing only
        // small/medium/large asks for an invention and gets one.
        let prompt = build()
        #expect(prompt.contains("unstated"))
        #expect(prompt.contains("do not guess"))
    }

    @Test("The prompt forbids ranking rather than asking for one")
    func itNeverAsksForARank() {
        let prompt = build().lowercased()
        // The word "rank" *is* in the prompt — in the sentence that forbids it.
        // Asserting its absence would be asserting that the prohibition is
        // missing, which is the opposite of what this test is for. What must be
        // absent is a *request*: no priority, no score, no ordering.
        #expect(prompt.contains("do not rank this card"))
        #expect(!prompt.contains("priorit"))
        #expect(!prompt.contains("score"))
        #expect(!prompt.contains("most important"))
    }

    @Test("The evidence cap is stated in the words the caller passed")
    func evidenceCapIsCarried() {
        #expect(build(maxEvidence: 3).contains("at most 3"))
    }

    @Test("Card text containing the marker is sanitized, so the invariant holds")
    func markerInCardTextIsSanitized() {
        // A card title is user text and can hold anything, including a line
        // copied out of an earlier run's prompt. Two markers would make
        // `outputPath(in:)` answer with the first one it finds, which is not
        // the file the harvester will read.
        let prompt = build(
            title: "Crash when \(AnalysisPromptBuilder.outputMarker)/tmp/evil",
            text: "See \(AnalysisPromptBuilder.outputMarker)/tmp/evil too."
        )
        let occurrences = prompt.components(separatedBy: AnalysisPromptBuilder.outputMarker).count - 1
        #expect(occurrences == 1)
        #expect(AnalysisPromptBuilder.outputPath(in: prompt)
            == "/tmp/elliot/analyses/appraisals/R/appraisal.json")
        #expect(prompt.contains("Crash when /tmp/evil"))
    }

    @Test("An empty card still produces a prompt with its one path, and says it is empty")
    func anEmptyCardIsStillAskable() throws {
        let prompt = AppraisalPromptBuilder.prompt(
            cardTitle: "", cardText: "",
            repoNameWithOwner: "phmatray/Elliot", outputPath: "/tmp/a.json"
        )
        #expect(try #require(AnalysisPromptBuilder.outputPath(in: prompt)) == "/tmp/a.json")
        #expect(prompt.contains("carries no words"))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd ElliotKit && swift test --filter AppraisalPromptBuilderTests`

Expected: FAIL to compile, with
`error: cannot find 'AppraisalPromptBuilder' in scope`.

- [ ] **Step 3: Write minimal implementation**

Create `ElliotKit/Sources/ElliotModel/AppraisalPromptBuilder.swift`:

```swift
import Foundation

/// The prompt Elliot sends to appraise one card.
///
/// Like the analysis prompt and unlike the three lifecycle skills, this is
/// **not** a slash command: there is no `appraise-cards` skill in any plugin.
/// Elliot owns this text and versions it, which is why it lives here — pure, and
/// covered by tests for the one thing the harvest cannot survive being wrong
/// about.
///
/// It asks for two signals and nothing else. It never asks the run to rank, to
/// compare cards, or to say what should be worked on: that judgement is a pure
/// function over the fields this fills in, and a model ranking here would rank
/// on what it happened to read rather than on what the board knows.
public enum AppraisalPromptBuilder {
    /// Deliberately `AnalysisPromptBuilder`'s marker rather than a second one.
    ///
    /// `AnalysisPromptBuilder.outputPath(in:)` is the parser, and
    /// `Scripts/fake-claude.sh` greps for the same string in shell. A private
    /// marker here would need a second parser, a second grep, and would still
    /// have to hold the same invariant.
    public static var outputMarker: String { AnalysisPromptBuilder.outputMarker }

    /// Enough places to judge the size; few enough that the list reads as
    /// evidence rather than as a directory listing.
    public static let maxEvidence = 5

    /// Builds the prompt for one card.
    ///
    /// - Parameters:
    ///   - cardTitle: What the board shows. May be empty.
    ///   - cardText: The card's own words — `Card.ideaText`, which is the story
    ///     plus its acceptance criteria, or the note for a card that is not a
    ///     story. Assembled by the caller, so this builder holds no second copy
    ///     of that fallback.
    ///   - repoNameWithOwner: Repository identifier, e.g. "phmatray/Elliot".
    ///   - outputPath: Absolute path the artifact is written to; the prompt
    ///     announces this. May contain spaces.
    ///   - maxEvidence: The most citations to ask for.
    public static func prompt(
        cardTitle: String,
        cardText: String,
        repoNameWithOwner: String,
        outputPath: String,
        maxEvidence: Int = AppraisalPromptBuilder.maxEvidence
    ) -> String {
        var sections: [String] = []

        sections.append("""
            You are appraising one card on Elliot's board, for the repository \
            \(repoNameWithOwner).

            Read the code. Do not modify it: make no edits, no commits, no \
            branches, no formatting runs. The single file below is the only one \
            you may write.
            """)

        let title = sanitized(cardTitle)
        let text = sanitized(cardText)
        var card = "The card:"
        if !title.isEmpty { card += "\n\n\(title)" }
        if !text.isEmpty { card += "\n\n\(text)" }
        if title.isEmpty, text.isEmpty {
            // Said out loud rather than left as an empty heading. A run asked to
            // appraise a blank card should answer "unstated", and it can only do
            // that if it knows the blankness is the input rather than a mistake.
            card += "\n\nThis card carries no words. Appraise what you can, and "
                + "say so by answering \"unstated\"."
        }
        sections.append(card)

        sections.append("""
            Answer two questions about it, and nothing else:

            - how much work it is, and
            - which files in this repository that work would touch.

            Write your answer as JSON to this exact path, and print nothing else \
            in your reply:

            \(outputMarker)\(outputPath)

            The file must contain a single JSON object:

            {
              "effort": "small",
              "evidence": [
                "ElliotKit/Sources/ElliotEngine/RunScheduler.swift:212",
                "ElliotKit/Tests/ElliotEngineTests/SchedulerLimitsAdmissionTests.swift"
              ]
            }

            Rules:
            - `effort` is one of small, medium, large, or unstated. Write \
            "unstated" when you cannot tell — do not guess a size. A guess is \
            worse than a gap here: once it is written down, nothing downstream \
            can tell the two apart.
            - `evidence` cites at most \(maxEvidence) real files, as paths \
            relative to the repository root, optionally with a line number after \
            a colon. Cite only files you have opened. An empty list is a valid \
            answer and means you found nothing to point at.
            - Do not rank this card, compare it with anything, or say whether it \
            should be done. You are filling in two facts, not deciding.
            """)

        return sections.joined(separator: "\n\n")
    }

    /// Strips the marker out of anything the reader wrote.
    ///
    /// A card title is user text and can hold anything, including a line copied
    /// out of an earlier prompt. Two markers would make `outputPath(in:)` answer
    /// with the first one it finds, which is not the file the harvester reads.
    private static func sanitized(_ text: String) -> String {
        text.replacingOccurrences(of: outputMarker, with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd ElliotKit && swift test --filter AppraisalPromptBuilderTests`

Expected: PASS — `Test run with 9 tests passed`.

- [ ] **Step 5: Commit**

```bash
git rev-parse --abbrev-ref HEAD
git add ElliotKit/Sources/ElliotModel/AppraisalPromptBuilder.swift \
        ElliotKit/Tests/ElliotModelTests/AppraisalPromptBuilderTests.swift
git commit -m "feat(model): the prompt that fills a card in without ranking it"
```

---

### Task 6: `AppraisalDecoder`, and the `Effort.unstated` pin

**Files:**
- Create: `ElliotKit/Sources/ElliotModel/AppraisalDecoder.swift`
- Test: `ElliotKit/Tests/ElliotModelTests/AppraisalDecoderTests.swift`

**Interfaces:**
- Consumes: `Effort` and `Effort.parse(_:) -> Effort` (`ElliotModel/StoryProposal.swift:93-101`), which **must** return `.unstated` for anything unrecognised — see Prerequisites.
- Produces:
  ```swift
  public enum AppraisalDecoder {
      public struct Appraisal: Sendable, Hashable {
          public var effort: Effort
          public var evidence: [String]
          public init(effort: Effort, evidence: [String])
      }
      public struct Reading: Sendable, Hashable {
          public var appraisal: Appraisal?   // nil = nothing usable was in the artifact
          public var dropped: [String]
          public init(appraisal: Appraisal? = nil, dropped: [String] = [])
      }
      public static func decode(artifact data: Data) -> Reading
  }
  ```

**⚠ Cross-PR dependency, written here because this is where it bites.** PR2 adds `Effort.unstated` and stops `Effort.parse` folding "the model said nothing" onto `.medium`. This decoder is the *imposition* half of that joint constraint: it calls `Effort.parse` and does **not** wrap it in a `?? .medium`. If PR2 has not landed, `unstatedIsNotMedium` below fails reporting `.medium`, which is the correct loud failure. Do not repair it by adding a fallback.

- [ ] **Step 1: Write the failing test**

Create `ElliotKit/Tests/ElliotModelTests/AppraisalDecoderTests.swift`:

```swift
import Foundation
import Testing

@testable import ElliotModel

/// The decoder's contract is `ProposalDecoder`'s: **never throws, never drops
/// silently.** What differs is what "nothing usable" is allowed to become. A
/// proposal that cannot be read costs one story out of twelve; an appraisal that
/// cannot be read costs the card its measurement, so the absence has to stay
/// expressible — `appraisal == nil` — rather than degrade into a value some
/// ranking will later sort on.
@Suite("Appraisal decoder")
struct AppraisalDecoderTests {

    private func decode(_ json: String) -> AppraisalDecoder.Reading {
        AppraisalDecoder.decode(artifact: Data(json.utf8))
    }

    @Test("A good artifact yields both signals")
    func goodArtifact() throws {
        let reading = decode("""
            {"effort":"small","evidence":["Sources/A.swift:12","Sources/B.swift"]}
            """)
        let appraisal = try #require(reading.appraisal)
        #expect(appraisal.effort == .small)
        #expect(appraisal.evidence == ["Sources/A.swift:12", "Sources/B.swift"])
        #expect(reading.dropped.isEmpty)
    }

    @Test("An empty artifact is nothing, and says so")
    func emptyArtifact() {
        let reading = AppraisalDecoder.decode(artifact: Data())
        #expect(reading.appraisal == nil)
        #expect(reading.dropped == ["The artifact was empty."])
    }

    @Test("An artifact that is not JSON is nothing, and says so")
    func notJSON() {
        let reading = decode("I had a look and I think this is medium.")
        #expect(reading.appraisal == nil)
        #expect(reading.dropped.contains { $0.contains("not valid JSON") })
    }

    @Test("Valid JSON of the wrong shape is nothing, and says so")
    func wrongShape() {
        let reading = decode("[\"small\"]")
        #expect(reading.appraisal == nil)
        #expect(reading.dropped.contains { $0.contains("not a JSON object") })
    }

    @Test("An object with neither field is nothing, and says so")
    func emptyObject() {
        let reading = decode("{\"notes\":\"could not tell\"}")
        #expect(reading.appraisal == nil)
        #expect(reading.dropped.contains { $0.contains("neither an effort nor") })
    }

    @Test("\"unstated\" is a real answer, and it is not medium")
    func unstatedIsNotMedium() {
        // The joint constraint with PR2, made executable. If this reports
        // `.medium`, `Effort.parse` still folds silence onto a size and an
        // unattended ranking would be sorting on an invention.
        #expect(Effort.parse("") == .unstated)
        let reading = decode("{\"effort\":\"unstated\",\"evidence\":[]}")
        #expect(reading.appraisal?.effort == .unstated)
        #expect(reading.appraisal?.evidence.isEmpty == true)
    }

    @Test("An unrecognised effort degrades to unstated, never to a size")
    func unrecognisedEffortIsUnstated() {
        #expect(decode("{\"effort\":\"XL\",\"evidence\":[\"a.swift\"]}").appraisal?.effort == .unstated)
        #expect(decode("{\"evidence\":[\"a.swift\"]}").appraisal?.effort == .unstated)
    }

    @Test("Evidence alone is enough; effort alone is enough")
    func eitherFieldIsEnough() {
        #expect(decode("{\"evidence\":[\"a.swift\"]}").appraisal != nil)
        #expect(decode("{\"effort\":\"large\"}").appraisal?.evidence.isEmpty == true)
    }

    @Test("Blank and non-string citations are dropped with their reasons")
    func junkCitationsAreNamedNotSwallowed() throws {
        let reading = decode("""
            {"effort":"medium","evidence":["a.swift","   ",7,"b.swift"]}
            """)
        let appraisal = try #require(reading.appraisal)
        #expect(appraisal.evidence == ["a.swift", "b.swift"])
        #expect(reading.dropped.count == 2)
        #expect(reading.dropped.contains { $0.contains("2") })
        #expect(reading.dropped.contains { $0.contains("3") })
    }

    @Test("Evidence of the wrong type is dropped, and the effort survives")
    func evidenceOfTheWrongTypeDoesNotCostTheEffort() {
        let reading = decode("{\"effort\":\"large\",\"evidence\":\"Sources/A.swift\"}")
        #expect(reading.appraisal?.effort == .large)
        #expect(reading.appraisal?.evidence.isEmpty == true)
        #expect(reading.dropped.contains { $0.contains("was not a list") })
    }

    @Test("There is no closing-message fallback, by construction")
    func thereIsNoResultTextEntryPoint() {
        // `ProposalDecoder` has `decode(resultText:)`. This one deliberately
        // does not, so no caller can reach for it: an appraisal salvaged from
        // prose would be prose persisted into a card field. The witness is that
        // a fenced block reaching the only entry point decodes to nothing.
        let reading = AppraisalDecoder.decode(
            artifact: Data("```json\n{\"effort\":\"small\"}\n```".utf8))
        #expect(reading.appraisal == nil)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd ElliotKit && swift test --filter AppraisalDecoderTests`

Expected: FAIL to compile, with
`error: cannot find 'AppraisalDecoder' in scope`.

- [ ] **Step 3: Write minimal implementation**

Create `ElliotKit/Sources/ElliotModel/AppraisalDecoder.swift`:

```swift
import Foundation

/// Turns whatever an appraisal run wrote into two signals, or into nothing.
///
/// The contract is `ProposalDecoder`'s: **never throws, never drops silently.**
/// What differs is the shape of failure. A proposal that cannot be read costs
/// one story out of twelve, and `ProposalDecoder` falls back to a fenced block
/// in the closing message to save the rest. There is deliberately **no such
/// entry point here**: an appraisal lands in a card field an unattended ranking
/// later sorts on, so prose salvaged from a chat message would become a
/// measurement. Leaving the card unappraised and saying so is the better
/// answer, and it is the only one this type can give.
public enum AppraisalDecoder {

    /// What the run said about one card.
    public struct Appraisal: Sendable, Hashable {
        public var effort: Effort
        /// Raw citations, exactly as written. Resolving them against the
        /// repository — including the containment check — is
        /// `EvidenceResolver`'s job, because that needs a file system and this
        /// stays pure.
        public var evidence: [String]

        public init(effort: Effort, evidence: [String]) {
            self.effort = effort
            self.evidence = evidence
        }
    }

    /// The whole of what an artifact yielded.
    ///
    /// `appraisal` is optional and `Effort` is not: "the run said nothing
    /// usable" and "the run said it could not tell" are different facts, and
    /// collapsing them is the mistake `AnalysisRunReport.workingTreeChanged`
    /// exists one type away to prevent. `.unstated` is the second; `nil` here is
    /// the first.
    public struct Reading: Sendable, Hashable {
        public var appraisal: Appraisal?
        /// Why each discarded thing was discarded. Shown, never swallowed.
        public var dropped: [String]

        public init(appraisal: Appraisal? = nil, dropped: [String] = []) {
            self.appraisal = appraisal
            self.dropped = dropped
        }
    }

    public static func decode(artifact data: Data) -> Reading {
        guard !data.isEmpty else {
            return Reading(dropped: ["The artifact was empty."])
        }
        guard let raw = try? JSONSerialization.jsonObject(with: data) else {
            return Reading(dropped: ["The artifact was not valid JSON."])
        }
        guard let object = raw as? [String: Any] else {
            return Reading(dropped: ["The artifact was not a JSON object."])
        }

        let rawEffort = object["effort"]
        let rawEvidence = object["evidence"]
        guard rawEffort != nil || rawEvidence != nil else {
            return Reading(
                dropped: ["The artifact carried neither an effort nor any evidence."]
            )
        }

        var dropped: [String] = []

        // `Effort.parse`, with no `?? .medium` anywhere near it. Folding silence
        // onto a size is a kindness for a display badge and an invention for an
        // input to an unattended ranking — the joint constraint this file
        // carries, pinned by `AppraisalDecoderTests.unstatedIsNotMedium`.
        let effort = Effort.parse((rawEffort as? String) ?? "")

        var evidence: [String] = []
        switch rawEvidence {
        case nil:
            break
        case let list as [Any]:
            for (index, element) in list.enumerated() {
                guard let citation = element as? String else {
                    dropped.append("Citation \(index + 1) was not a string.")
                    continue
                }
                let trimmed = citation.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else {
                    dropped.append("Citation \(index + 1) was blank.")
                    continue
                }
                evidence.append(trimmed)
            }
        default:
            // The effort survives: one malformed field must not cost the other.
            dropped.append("The evidence was not a list, so it was discarded.")
        }

        return Reading(
            appraisal: Appraisal(effort: effort, evidence: evidence),
            dropped: dropped
        )
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd ElliotKit && swift test --filter AppraisalDecoderTests`

Expected: PASS — `Test run with 11 tests passed`.

- [ ] **Step 5: Commit**

```bash
git rev-parse --abbrev-ref HEAD
git add ElliotKit/Sources/ElliotModel/AppraisalDecoder.swift \
        ElliotKit/Tests/ElliotModelTests/AppraisalDecoderTests.swift
git commit -m "feat(model): read an appraisal artifact, or read nothing"
```

---

### Task 7: `EvidenceResolver`, extracted so the appraisal cannot re-derive it wrong

**Files:**
- Create: `ElliotKit/Sources/ElliotEngine/EvidenceResolver.swift`
- Modify: `ElliotKit/Sources/ElliotEngine/ProposalHarvester.swift:56,114-138`
- Test: `ElliotKit/Tests/ElliotEngineTests/EvidenceResolverTests.swift`

**Interfaces:**
- Consumes: `Evidence` and `Evidence.parse(_:) -> (path: String, line: Int?)?` (`ElliotModel/StoryProposal.swift:107-133`).
- Produces:
  ```swift
  public enum EvidenceResolver {
      public static func resolve(_ raw: [String], repoPath: String) -> [Evidence]
  }
  ```
  in `ElliotEngine`. `ProposalHarvester` calls it; `AppraisalHarvester` (Task 9) calls it.

**Why extract rather than copy.** `ProposalHarvester.resolve` carries a containment check whose failure mode is measured and already has a test:
`ProposalHarvesterTests.evidenceContainmentRejectsSiblingEscape` proves a `/repo-evil` sibling is not accepted for a root of `/repo`. A second, hand-written copy in the appraisal harvester is exactly the shape this repository calls "the invariant has been copied because its explanation was" — and the appraisal is the caller with an unattended agent choosing the citations.

- [ ] **Step 1: Write the failing test**

Create `ElliotKit/Tests/ElliotEngineTests/EvidenceResolverTests.swift`:

```swift
import ElliotModel
import Foundation
import Testing

@testable import ElliotEngine

/// One resolver, two harvesters. The containment check is the reason this is
/// extracted rather than copied: a citation must stay inside the repository, and
/// the boundary has to land on a **path component** — a bare string prefix
/// admits a sibling directory like `/repo-evil` for a root of `/repo`.
@Suite("Evidence resolution")
struct EvidenceResolverTests {

    private struct Fixture {
        var root: URL
        var sibling: URL
        func cleanUp() {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: sibling)
        }
    }

    /// A repository with one real file, and a sibling directory whose path
    /// shares the root's as a string prefix without being underneath it.
    private func makeFixture() throws -> Fixture {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("elliot-evidence-\(UUID().uuidString)", isDirectory: true)
        let sources = root.appendingPathComponent("Sources", isDirectory: true)
        try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
        try "// real".write(
            to: sources.appendingPathComponent("Real.swift"), atomically: true, encoding: .utf8)

        let sibling = root.deletingLastPathComponent()
            .appendingPathComponent("\(root.lastPathComponent)-evil", isDirectory: true)
        try FileManager.default.createDirectory(at: sibling, withIntermediateDirectories: true)
        try "// secret".write(
            to: sibling.appendingPathComponent("secret.swift"), atomically: true, encoding: .utf8)

        return Fixture(root: root, sibling: sibling)
    }

    @Test("A citation inside the repository that exists is marked found")
    func insideAndPresent() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }

        let resolved = EvidenceResolver.resolve(
            ["Sources/Real.swift:3"], repoPath: fixture.root.path)
        #expect(resolved.count == 1)
        #expect(resolved[0].path == "Sources/Real.swift")
        #expect(resolved[0].line == 3)
        #expect(resolved[0].exists)
    }

    @Test("A citation inside the repository that does not exist is marked, not dropped")
    func insideAndAbsent() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }

        let resolved = EvidenceResolver.resolve(
            ["Sources/Nowhere.swift:9"], repoPath: fixture.root.path)
        // Marked rather than removed: a missing file is the fastest signal that
        // a citation was invented, and dropping it would hide that.
        #expect(resolved.count == 1)
        #expect(resolved[0].exists == false)
    }

    @Test("A citation escaping through a sibling directory is not inside the repository")
    func siblingEscapeIsRejected() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }

        let escaped = "../\(fixture.root.lastPathComponent)-evil/secret.swift:1"
        let resolved = EvidenceResolver.resolve([escaped], repoPath: fixture.root.path)

        // The escaped file genuinely exists — proving the containment check, and
        // not a missing-file coincidence, is what marked this not-found.
        #expect(FileManager.default.fileExists(
            atPath: fixture.sibling.appendingPathComponent("secret.swift").path))
        #expect(resolved.count == 1)
        #expect(resolved[0].exists == false)
    }

    @Test("An unparseable citation is dropped rather than turned into a blank path")
    func unparseableIsDropped() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        #expect(EvidenceResolver.resolve(["", "   ", ":12"], repoPath: fixture.root.path).isEmpty)
    }

    @Test("The repository root itself resolves as inside")
    func theRootIsInside() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        // `resolved.path == root.path` is a separate branch from the
        // `hasPrefix(root.path + "/")` one, and only this reaches it.
        let resolved = EvidenceResolver.resolve(["."], repoPath: fixture.root.path)
        #expect(resolved.count == 1)
        #expect(resolved[0].exists)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd ElliotKit && swift test --filter EvidenceResolverTests`

Expected: FAIL to compile, with
`error: cannot find 'EvidenceResolver' in scope`.

- [ ] **Step 3: Write minimal implementation**

Create `ElliotKit/Sources/ElliotEngine/EvidenceResolver.swift`:

```swift
import ElliotModel
import Foundation

/// Resolves cited paths against a repository root.
///
/// Extracted from `ProposalHarvester` when a second harvester needed it. The
/// containment check below is the reason it is one function rather than two
/// copies: its failure mode is measured — a sibling directory `/repo-evil`
/// shares `/repo` as a string prefix without being underneath it — and the
/// second caller is an unattended agent choosing the citations.
///
/// In `ElliotEngine` rather than `ElliotModel` because it touches the file
/// system, and `ElliotModel` is a pure island by rule.
public enum EvidenceResolver {

    /// A missing file does not disqualify a citation — it marks it, and the
    /// window strikes it through. It is the fastest signal that something was
    /// invented rather than found, so it must survive to be shown.
    public static func resolve(_ raw: [String], repoPath: String) -> [Evidence] {
        let root = URL(fileURLWithPath: repoPath).standardizedFileURL
        return raw.compactMap { citation in
            guard let parsed = Evidence.parse(citation) else { return nil }
            let resolved = root.appendingPathComponent(parsed.path).standardizedFileURL
            // A citation must stay inside the repository: "../../etc/passwd" is
            // not evidence about this codebase. The boundary check must land on
            // a path component, not a bare string prefix — otherwise a sibling
            // directory like "/repo-evil" would be accepted for a root of
            // "/repo".
            let inside = resolved.path == root.path || resolved.path.hasPrefix(root.path + "/")
            return Evidence(
                path: parsed.path,
                line: parsed.line,
                exists: inside && FileManager.default.fileExists(atPath: resolved.path)
            )
        }
    }
}
```

In `ElliotKit/Sources/ElliotEngine/ProposalHarvester.swift`, replace line 56:

```swift
                evidence: EvidenceResolver.resolve(story.evidence, repoPath: repo.path),
```

and delete the whole `// MARK: - Evidence` section, lines 114-138 (the doc comment and the `private func resolve`), leaving `// MARK: - Duplicates` as the next section.

- [ ] **Step 4: Run test to verify it passes**

Run: `cd ElliotKit && swift test --filter EvidenceResolverTests`

Expected: PASS — `Test run with 5 tests passed`.

Then the caller, unchanged in behaviour:
`cd ElliotKit && swift test --filter ProposalHarvesterTests` — PASS, `Test run with 7 tests passed`, including `evidenceContainmentRejectsSiblingEscape`.

- [ ] **Step 5: Commit**

```bash
git rev-parse --abbrev-ref HEAD
git add ElliotKit/Sources/ElliotEngine/EvidenceResolver.swift \
        ElliotKit/Sources/ElliotEngine/ProposalHarvester.swift \
        ElliotKit/Tests/ElliotEngineTests/EvidenceResolverTests.swift
git commit -m "refactor(engine): one resolver for cited paths, two harvesters"
```

---

### Task 8: The store's two narrow writes — `applyAppraisal` and `claimCardForRun`

**Files:**
- Modify: `ElliotKit/Sources/ElliotStore/BoardStore.swift:429-433,741-754`
- Test: `ElliotKit/Tests/ElliotStoreTests/AppraisalStoreTests.swift`

**Interfaces:**
- Consumes: `Card.effort`, `Card.evidence`, `Card.appraisedAt` (Prerequisites); `Effort`, `Evidence` from `ElliotModel`.
- Produces, on `public final class BoardStore`:
  ```swift
  @discardableResult
  public func applyAppraisal(
      cardID: UUID, effort: Effort, evidence: [Evidence], at: Date
  ) async throws -> Card?

  public func claimCardForRun(_ run: SkillRun) async throws -> Bool
  ```

**Why these two and not `saveCard`.** `saveCard(_:)` writes a whole `Card` value the caller read some `await`s earlier, and so does `commitMove` (`BoardStore.swift:1104-1112`, `try updated.update(db)`). The window is symmetric: an appraisal saved that way carries a stale `column` back over a move committed in between, and a move committed the other way round carries a stale appraisal back over the three fields. `applyAppraisal` reads and writes **inside one transaction**, so there is no window at all; `claimCardForRun` is the compare-and-set — the same idiom as `claimProposal` (`BoardStore.swift:924-934`) — that makes the ownership real rather than best-effort.

- [ ] **Step 1: Write the failing test**

Create `ElliotKit/Tests/ElliotStoreTests/AppraisalStoreTests.swift`:

```swift
import ElliotModel
import ElliotStore
import Foundation
import Testing

/// The two narrow writes an appraisal needs, and the reason neither is
/// `saveCard`.
@Suite("Appraisal writes")
struct AppraisalStoreTests {

    private struct Seeded {
        var store: BoardStore
        var repo: Repo
        var card: Card
    }

    private func seed() async throws -> Seeded {
        let store = try BoardStore.inMemory()
        let repo = Repo(path: "/tmp/r", nameWithOwner: "phmatray/Elliot", displayName: "Elliot")
        try await store.saveRepo(repo)
        let now = Date(timeIntervalSince1970: 1_770_000_000)
        let card = Card(
            repoID: repo.id, title: "A story", columnEnteredAt: now,
            createdAt: now, updatedAt: now
        )
        try await store.saveCard(card)
        return Seeded(store: store, repo: repo, card: card)
    }

    private func run(_ seeded: Seeded, kind: SkillKind, state: RunState) -> SkillRun {
        var run = SkillRun.card(
            cardID: seeded.card.id, repoID: seeded.repo.id, kind: kind, prompt: "x",
            cwd: seeded.repo.path, logPath: "/tmp/a.ndjson", stderrPath: "/tmp/a.log",
            createdAt: Date()
        )
        run.state = state
        return run
    }

    @Test("An appraisal writes exactly three fields")
    func appraisalWritesThreeFields() async throws {
        let seeded = try await seed()
        let at = Date(timeIntervalSince1970: 1_770_000_500)

        let written = try #require(
            try await seeded.store.applyAppraisal(
                cardID: seeded.card.id, effort: .large,
                evidence: [Evidence(path: "a.swift", line: 3, exists: true)], at: at
            )
        )
        #expect(written.effort == .large)
        #expect(written.evidence?.count == 1)
        #expect(written.appraisedAt == at)
        // And nothing else moved.
        #expect(written.column == seeded.card.column)
        #expect(written.title == seeded.card.title)
        #expect(written.issueNumber == nil)
    }

    /// The write window, in the direction that loses the **column**.
    @Test("A move committed before the appraisal is not overwritten by it")
    func appraisalDoesNotCarryAStaleColumnBack() async throws {
        let seeded = try await seed()

        // The harvester's read happens here, in the real ordering: the card is
        // read, the run finishes, and the write comes later.
        let readEarly = try #require(try await seeded.store.card(id: seeded.card.id))
        #expect(readEarly.column == .backlog)

        // A move lands in between, writing the whole row from its own snapshot.
        try await seeded.store.commitMove(
            card: readEarly, to: .todo, orderIndex: 2048,
            origin: .userDrag, run: nil
        )

        // The appraisal is written by id, not by handing back `readEarly`.
        try await seeded.store.applyAppraisal(
            cardID: seeded.card.id, effort: .small, evidence: [], at: Date()
        )

        let after = try #require(try await seeded.store.card(id: seeded.card.id))
        #expect(after.column == .todo)        // the move survived
        #expect(after.effort == .small)       // and so did the appraisal
        #expect(after.appraisedAt != nil)
    }

    /// The write window, in the direction that loses the **appraisal**.
    @Test("An appraisal written before a move is not overwritten by it")
    func aMoveDoesNotCarryAStaleAppraisalBack() async throws {
        let seeded = try await seed()

        // A poller's read, taken before the appraisal lands.
        let stale = try #require(try await seeded.store.card(id: seeded.card.id))
        #expect(stale.effort == nil)

        try await seeded.store.applyAppraisal(
            cardID: seeded.card.id, effort: .medium, evidence: [], at: Date()
        )

        // ⚠ This is the *unprotected* half, and it is asserted as it really
        // behaves rather than as one would like: `commitMove` writes every
        // column from `stale`, so the appraisal is lost here. What stops it in
        // production is ownership — `claimCardForRun` below holds the card, and
        // `proposeMove` refuses while it does — not this method. Pinning the
        // real behaviour is what keeps the ownership argument honest: change
        // `commitMove` to a narrow write and this expectation changes with it.
        try await seeded.store.commitMove(
            card: stale, to: .todo, orderIndex: 2048, origin: .userDrag, run: nil
        )
        let after = try #require(try await seeded.store.card(id: seeded.card.id))
        #expect(after.effort == nil)
    }

    @Test("Appraising a card that has been deleted answers nil rather than throwing")
    func deletedCardIsNotAnError() async throws {
        let seeded = try await seed()
        try await seeded.store.deleteCard(id: seeded.card.id)
        #expect(
            try await seeded.store.applyAppraisal(
                cardID: seeded.card.id, effort: .small, evidence: [], at: Date()
            ) == nil
        )
    }

    @Test("The first claim on a free card wins, and it is then the active run")
    func firstClaimWins() async throws {
        let seeded = try await seed()
        let first = run(seeded, kind: .appraiseCards, state: .queued)
        #expect(try await seeded.store.claimCardForRun(first))
        #expect(try await seeded.store.activeRun(cardID: seeded.card.id)?.id == first.id)
    }

    @Test("A second claim on a held card is refused, and inserts nothing")
    func secondClaimIsRefused() async throws {
        let seeded = try await seed()
        let first = run(seeded, kind: .appraiseCards, state: .running)
        #expect(try await seeded.store.claimCardForRun(first))

        let second = run(seeded, kind: .appraiseCards, state: .queued)
        #expect(try await seeded.store.claimCardForRun(second) == false)
        #expect(try await seeded.store.run(id: second.id) == nil)
        #expect(try await seeded.store.runs(cardID: seeded.card.id).count == 1)
    }

    @Test("Any active run holds the card, not only another appraisal")
    func anyActiveRunHoldsTheCard() async throws {
        let seeded = try await seed()
        let writer = run(seeded, kind: .implementIssue, state: .running)
        try await seeded.store.saveRun(writer)
        #expect(try await seeded.store.claimCardForRun(
            run(seeded, kind: .appraiseCards, state: .queued)) == false)
    }

    @Test("A finished run does not hold the card")
    func aTerminalRunReleasesTheCard() async throws {
        let seeded = try await seed()
        var done = run(seeded, kind: .appraiseCards, state: .succeeded)
        done.endedAt = Date()
        try await seeded.store.saveRun(done)
        #expect(try await seeded.store.claimCardForRun(
            run(seeded, kind: .appraiseCards, state: .queued)))
    }

    @Test("A run with no card cannot claim one")
    func aCardlessRunIsRefused() async throws {
        let seeded = try await seed()
        let analysis = Analysis(repoID: seeded.repo.id, angles: [.bugs], createdAt: Date())
        try await seeded.store.saveAnalysis(analysis)
        let run = SkillRun.analysis(
            repoID: seeded.repo.id, analysisID: analysis.id, analysisAngle: .bugs,
            prompt: "x", cwd: seeded.repo.path, logPath: "/tmp/a", stderrPath: "/tmp/b",
            createdAt: Date()
        )
        #expect(try await seeded.store.claimCardForRun(run) == false)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd ElliotKit && swift test --filter AppraisalStoreTests`

Expected: FAIL to compile, with
`error: value of type 'BoardStore' has no member 'applyAppraisal'`
and
`error: value of type 'BoardStore' has no member 'claimCardForRun'`.

- [ ] **Step 3: Write minimal implementation**

In `ElliotKit/Sources/ElliotStore/BoardStore.swift`, after `saveCard` (line 433):

```swift
    /// Writes an appraisal onto a card, reading and writing in **one
    /// transaction**.
    ///
    /// Deliberately not `saveCard(_:)`. That takes a whole `Card` the caller read
    /// some `await`s earlier and writes every column of it — which is how a move
    /// committed in between loses its column, and how an appraisal written the
    /// other way round loses its three fields. Here the read and the write are
    /// the same transaction, so there is no window to lose anything in.
    ///
    /// Three fields and no more, for the reason the v8 migration records: what
    /// writes a card field is supposed to be enumerable. This is the fourth
    /// writer, it is named, and it can write nothing else.
    ///
    /// Answers with the card as it now stands, or `nil` if it has been deleted —
    /// which is not an error. A card can be forgotten while a run that mentions
    /// it is still finishing.
    @discardableResult
    public func applyAppraisal(
        cardID: UUID, effort: Effort, evidence: [Evidence], at: Date
    ) async throws -> Card? {
        // `db -> Card? in` spelled out: the closure's only `nil` is a bare
        // `return nil`, and leaving the optionality to inference is the classic
        // way to end up with `T == Card` and an error on that line.
        try await requireWriter().write { db -> Card? in
            guard var card = try Card.fetchOne(db, key: cardID.databaseKey) else { return nil }
            card.effort = effort
            card.evidence = evidence
            card.appraisedAt = at
            card.updatedAt = Date()
            try card.update(db)
            return card
        }
    }
```

After `saveRun` (line 743):

```swift
    /// Inserts a run **only if** no active run already holds its card.
    ///
    /// The same compare-and-set `claimProposal` is, and for the same reason: a
    /// "fetch, check, insert" written out by the caller reads a snapshot and
    /// writes across an `await`, so two starts for one card can both pass the
    /// check before either writes. Here the check and the insert are one
    /// transaction.
    ///
    /// `false` is a refusal, not an error: somebody else holds the card, which
    /// is exactly what the caller wanted to know.
    ///
    /// The card **is** the claim. `activeRun(cardID:)` answers with this run for
    /// its whole life, so `BoardService.proposeMove` — which reads that same
    /// query — returns `.blocked(.runAlreadyInFlight)` while it goes. That is
    /// what closes the card's write window in both directions, and it is why an
    /// appraisal run carries a `cardID` rather than a synthetic analysis.
    ///
    /// A run with no card cannot claim one: an analysis run is refused here
    /// rather than inserted unguarded, because "no card to hold" is not "the
    /// card is free".
    public func claimCardForRun(_ run: SkillRun) async throws -> Bool {
        guard let cardID = run.cardID else { return false }
        return try await requireWriter().write { db in
            let held = try SkillRun
                .filter(SkillRun.Columns.cardID == cardID.databaseKey)
                .filter(Self.activeStates.contains(SkillRun.Columns.state))
                .fetchCount(db)
            guard held == 0 else { return false }
            try run.insert(db)
            return true
        }
    }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd ElliotKit && swift test --filter AppraisalStoreTests`

Expected: PASS — `Test run with 9 tests passed`.

- [ ] **Step 5: Commit**

```bash
git rev-parse --abbrev-ref HEAD
git add ElliotKit/Sources/ElliotStore/BoardStore.swift \
        ElliotKit/Tests/ElliotStoreTests/AppraisalStoreTests.swift
git commit -m "feat(store): write an appraisal in one transaction, and claim its card"
```

---

### Task 9: `AppraisalHarvester` — the artifact or nothing

**Files:**
- Create: `ElliotKit/Sources/ElliotEngine/AppraisalHarvester.swift`
- Test: `ElliotKit/Tests/ElliotEngineTests/AppraisalHarvesterTests.swift`

**Interfaces:**
- Consumes: `AppraisalDecoder.decode(artifact:) -> AppraisalDecoder.Reading` (Task 6); `EvidenceResolver.resolve(_:repoPath:) -> [Evidence]` (Task 7); `BoardStore.applyAppraisal(cardID:effort:evidence:at:) -> Card?` (Task 8); `AnalysisRunReport` (`ElliotModel/Analysis.swift:49-89`).
- Produces:
  ```swift
  public struct AppraisalHarvester: Sendable {
      public init(store: BoardStore)
      public func harvest(run: SkillRun, repo: Repo, artifactURL: URL) async -> AnalysisRunReport
  }
  ```
  The report is carried on `SkillRun.analysisReport`, whose JSON column already exists.

**Two decisions written down here, because a reader will ask.**

1. **The report reuses `AnalysisRunReport`.** It is the right shape — `harvestSource`, `kept`, `dropped`, and the tri-state `workingTreeChanged` the git sentinel writes for *both* read-only kinds — and it costs no migration. Renaming the property `SkillRun.analysisReport` would be a **column** rename (`SkillRun` is persisted through its synthesised `Codable`, see `ElliotStore/Records.swift:43-57`), and this PR takes no migration. Its doc comment is widened instead.
2. **`harvestSource` can be `.artifact` or `.none` and never `.resultText`.** There is no code path to it, which is the point; the test asserts the absence rather than trusting the comment.

- [ ] **Step 1: Write the failing test**

Create `ElliotKit/Tests/ElliotEngineTests/AppraisalHarvesterTests.swift`:

```swift
import ElliotModel
import ElliotProcess
import ElliotStore
import Foundation
import Testing

@testable import ElliotEngine

/// The harvester reads the **artifact or nothing**.
///
/// `ProposalHarvester` falls back to a fenced JSON block in the closing message,
/// and that is right for it: a proposal lands in a review queue a person reads.
/// An appraisal lands in a card field an unattended ranking sorts on, so prose
/// salvaged from a chat message would become a measurement. Leaving the card
/// unappraised and saying so is the better answer — the three failure tests
/// below are what says so.
@Suite("Appraisal harvester")
struct AppraisalHarvesterTests {

    private struct Fixture {
        var store: BoardStore
        var repo: Repo
        var card: Card
        var run: SkillRun
        var artifactURL: URL
        var root: URL

        func cleanUp() { try? FileManager.default.removeItem(at: root) }
    }

    /// A throwaway repository with one real file, so evidence resolution has
    /// something true and something false to tell apart.
    private func makeFixture() async throws -> Fixture {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("elliot-appraise-\(UUID().uuidString)", isDirectory: true)
        let sources = root.appendingPathComponent("Sources", isDirectory: true)
        try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
        try "// real".write(
            to: sources.appendingPathComponent("Real.swift"), atomically: true, encoding: .utf8)

        let store = try BoardStore.inMemory()
        let repo = Repo(path: root.path, nameWithOwner: "phmatray/Elliot", displayName: "Elliot")
        try await store.saveRepo(repo)

        let now = Date()
        let card = Card(
            repoID: repo.id, title: "A story", columnEnteredAt: now,
            createdAt: now, updatedAt: now
        )
        try await store.saveCard(card)

        let run = SkillRun.card(
            cardID: card.id, repoID: repo.id, kind: .appraiseCards, prompt: "…",
            cwd: repo.path,
            logPath: root.appendingPathComponent("run.ndjson").path,
            stderrPath: root.appendingPathComponent("run.log").path,
            createdAt: now
        )
        try await store.saveRun(run)

        return Fixture(
            store: store, repo: repo, card: card, run: run,
            artifactURL: root.appendingPathComponent("appraisal.json"),
            root: root
        )
    }

    @Test("A good artifact lands on the card, with evidence resolved")
    func harvestsFromArtifact() async throws {
        let fixture = try await makeFixture()
        defer { fixture.cleanUp() }

        try """
        {"effort":"small","evidence":["Sources/Real.swift:3","Sources/Nowhere.swift"]}
        """.write(to: fixture.artifactURL, atomically: true, encoding: .utf8)

        let report = await AppraisalHarvester(store: fixture.store).harvest(
            run: fixture.run, repo: fixture.repo, artifactURL: fixture.artifactURL
        )
        #expect(report.harvestSource == .artifact)
        #expect(report.kept == 1)
        #expect(report.dropped.isEmpty)

        let card = try #require(try await fixture.store.card(id: fixture.card.id))
        #expect(card.effort == .small)
        #expect(card.appraisedAt != nil)
        let evidence = try #require(card.evidence)
        #expect(evidence.count == 2)
        #expect(evidence[0].exists)
        #expect(evidence[1].exists == false)
    }

    @Test("No artifact leaves the card unappraised, and the report names the path")
    func noArtifact() async throws {
        let fixture = try await makeFixture()
        defer { fixture.cleanUp() }

        let report = await AppraisalHarvester(store: fixture.store).harvest(
            run: fixture.run, repo: fixture.repo, artifactURL: fixture.artifactURL
        )
        #expect(report.harvestSource == .none)
        #expect(report.kept == 0)
        #expect(report.dropped.contains { $0.contains(fixture.artifactURL.path) })

        let card = try #require(try await fixture.store.card(id: fixture.card.id))
        #expect(card.appraisedAt == nil)
        #expect(card.effort == nil)
        #expect(card.evidence == nil)
    }

    @Test("An empty artifact leaves the card unappraised, and says it was empty")
    func emptyArtifact() async throws {
        let fixture = try await makeFixture()
        defer { fixture.cleanUp() }
        try Data().write(to: fixture.artifactURL)

        let report = await AppraisalHarvester(store: fixture.store).harvest(
            run: fixture.run, repo: fixture.repo, artifactURL: fixture.artifactURL
        )
        #expect(report.harvestSource == .none)
        #expect(report.dropped.contains { $0.contains("empty") })
        #expect(try await fixture.store.card(id: fixture.card.id)?.appraisedAt == nil)
    }

    @Test("A malformed artifact leaves the card unappraised, and says what was wrong")
    func malformedArtifact() async throws {
        let fixture = try await makeFixture()
        defer { fixture.cleanUp() }
        try "this is not json".write(
            to: fixture.artifactURL, atomically: true, encoding: .utf8)

        let report = await AppraisalHarvester(store: fixture.store).harvest(
            run: fixture.run, repo: fixture.repo, artifactURL: fixture.artifactURL
        )
        #expect(report.harvestSource == .none)
        #expect(report.dropped.contains { $0.contains("not valid JSON") })
        #expect(try await fixture.store.card(id: fixture.card.id)?.appraisedAt == nil)
    }

    @Test("The closing message is never read, even when it holds a perfect answer")
    func neverFallsBackToResultText() async throws {
        let fixture = try await makeFixture()
        defer { fixture.cleanUp() }

        var run = fixture.run
        run.resultText = """
            I had a look. Here is the appraisal:

            ```json
            {"effort":"large","evidence":["Sources/Real.swift:1"]}
            ```
            """
        try await fixture.store.saveRun(run)

        let report = await AppraisalHarvester(store: fixture.store).harvest(
            run: run, repo: fixture.repo, artifactURL: fixture.artifactURL
        )
        // The one difference from `ProposalHarvester`, asserted rather than
        // commented: a card left unappraised beats prose in a card field.
        #expect(report.harvestSource == .none)
        #expect(report.kept == 0)
        #expect(try await fixture.store.card(id: fixture.card.id)?.effort == nil)
    }

    @Test("\"appraised and found nothing\" is written, because it is a third state")
    func anEmptyAnswerIsStillAnAnswer() async throws {
        let fixture = try await makeFixture()
        defer { fixture.cleanUp() }

        try """
        {"effort":"unstated","evidence":[]}
        """.write(to: fixture.artifactURL, atomically: true, encoding: .utf8)

        let report = await AppraisalHarvester(store: fixture.store).harvest(
            run: fixture.run, repo: fixture.repo, artifactURL: fixture.artifactURL
        )
        #expect(report.harvestSource == .artifact)
        #expect(report.kept == 1)

        let card = try #require(try await fixture.store.card(id: fixture.card.id))
        // `appraisedAt` is the third state. Without it, "nobody has appraised
        // this card" and "this card was appraised and carries no signal" are the
        // same value, and PR2's `CardValue` cannot tell `.neverAppraised` from
        // `.ungradeable`.
        #expect(card.appraisedAt != nil)
        #expect(card.effort == .unstated)
        #expect(card.evidence == [])
    }

    @Test("Decoder complaints reach the report rather than being swallowed")
    func droppedReasonsSurvive() async throws {
        let fixture = try await makeFixture()
        defer { fixture.cleanUp() }
        try """
        {"effort":"small","evidence":["Sources/Real.swift",7]}
        """.write(to: fixture.artifactURL, atomically: true, encoding: .utf8)

        let report = await AppraisalHarvester(store: fixture.store).harvest(
            run: fixture.run, repo: fixture.repo, artifactURL: fixture.artifactURL
        )
        #expect(report.kept == 1)
        #expect(report.dropped.contains { $0.contains("Citation 2") })
    }

    @Test("A run with no card is reported, not crashed on")
    func aCardlessRunIsReported() async throws {
        let fixture = try await makeFixture()
        defer { fixture.cleanUp() }
        try """
        {"effort":"small","evidence":[]}
        """.write(to: fixture.artifactURL, atomically: true, encoding: .utf8)

        var run = fixture.run
        run.cardID = nil
        let report = await AppraisalHarvester(store: fixture.store).harvest(
            run: run, repo: fixture.repo, artifactURL: fixture.artifactURL
        )
        #expect(report.harvestSource == .none)
        #expect(report.dropped.contains { $0.contains("no card") })
    }

    @Test("A card deleted mid-run is reported, not crashed on")
    func aDeletedCardIsReported() async throws {
        let fixture = try await makeFixture()
        defer { fixture.cleanUp() }
        try """
        {"effort":"small","evidence":[]}
        """.write(to: fixture.artifactURL, atomically: true, encoding: .utf8)
        try await fixture.store.deleteCard(id: fixture.card.id)

        let report = await AppraisalHarvester(store: fixture.store).harvest(
            run: fixture.run, repo: fixture.repo, artifactURL: fixture.artifactURL
        )
        #expect(report.harvestSource == .none)
        #expect(report.dropped.contains { $0.contains("could not be found") })
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd ElliotKit && swift test --filter AppraisalHarvesterTests`

Expected: FAIL to compile, with
`error: cannot find 'AppraisalHarvester' in scope`.

- [ ] **Step 3: Write minimal implementation**

Create `ElliotKit/Sources/ElliotEngine/AppraisalHarvester.swift`:

```swift
import ElliotModel
import ElliotStore
import Foundation

/// Turns a finished appraisal run into three fields on its card.
///
/// The appraisal counterpart of `Verifier`, and the sibling of
/// `ProposalHarvester` — it answers the same question in a place where `gh`
/// cannot: what did this run actually produce? There is no external authority on
/// how much work a card is, so the artifact is the fact: a file the run was told
/// to write, read from disk.
///
/// ⛔ **The artifact or nothing.** `ProposalHarvester` falls back to a fenced
/// JSON block in the closing message, and that is right for it — a proposal
/// lands in a review queue a person reads. An appraisal lands in a card field an
/// unattended ranking later sorts on, so prose recovered from a chat message
/// would become a measurement with no way to tell it from one. Leaving the card
/// unappraised and saying so in the report is the better answer, and this type
/// has no code path to any other.
public struct AppraisalHarvester: Sendable {
    private let store: BoardStore

    public init(store: BoardStore) {
        self.store = store
    }

    /// Reads the artifact, resolves its citations, and writes the three fields.
    ///
    /// The report is an `AnalysisRunReport` because that is the shape of "what a
    /// read-only run has to say about itself" — where it harvested from, what it
    /// dropped, and the tri-state answer of the git sentinel, which the
    /// scheduler folds in afterwards. Renaming the type or the column would be a
    /// migration; widening what it means is free and true.
    public func harvest(run: SkillRun, repo: Repo, artifactURL: URL) async -> AnalysisRunReport {
        guard let cardID = run.cardID else {
            return AnalysisRunReport(
                harvestSource: .none,
                dropped: ["This appraisal run carries no card, so there is nothing to write to."]
            )
        }

        guard let data = try? Data(contentsOf: artifactURL) else {
            return AnalysisRunReport(
                harvestSource: .none,
                dropped: ["No artifact was written at \(artifactURL.path)."]
            )
        }

        let reading = AppraisalDecoder.decode(artifact: data)
        guard let appraisal = reading.appraisal else {
            return AnalysisRunReport(
                harvestSource: .none, kept: 0, dropped: reading.dropped
            )
        }

        let evidence = EvidenceResolver.resolve(appraisal.evidence, repoPath: repo.path)

        do {
            // Written even when the run said `.unstated` and cited nothing.
            // `appraisedAt` is the third state: without it, "nobody has read
            // this card" and "this card was read and carries no signal" are the
            // same value, and the ranking one PR over cannot tell the two apart.
            let written = try await store.applyAppraisal(
                cardID: cardID, effort: appraisal.effort, evidence: evidence, at: Date()
            )
            guard written != nil else {
                return AnalysisRunReport(
                    harvestSource: .none, kept: 0,
                    dropped: reading.dropped
                        + ["The card this appraisal belonged to could not be found."]
                )
            }
        } catch {
            return AnalysisRunReport(
                harvestSource: .none, kept: 0,
                dropped: reading.dropped
                    + ["The appraisal could not be saved: \(error.localizedDescription)"]
            )
        }

        return AnalysisRunReport(
            harvestSource: .artifact, kept: 1, dropped: reading.dropped
        )
    }
}
```

Widen the doc comment of `SkillRun.analysisReport` in `ElliotKit/Sources/ElliotModel/SkillRun.swift:80-83`:

```swift
    /// What a **read-only** run had to say about itself: where its answer was
    /// harvested from, what was dropped, and whether the working tree moved.
    /// `nil` for a run that writes.
    ///
    /// Named `analysisReport` because renaming it renames a column, and an
    /// appraisal is not worth a migration. An analysis fills it through
    /// `ProposalHarvester`, an appraisal through `AppraisalHarvester`; the
    /// fields mean the same thing in both.
    public var analysisReport: AnalysisRunReport?
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd ElliotKit && swift test --filter AppraisalHarvesterTests`

Expected: PASS — `Test run with 9 tests passed`.

- [ ] **Step 5: Commit**

```bash
git rev-parse --abbrev-ref HEAD
git add ElliotKit/Sources/ElliotEngine/AppraisalHarvester.swift \
        ElliotKit/Sources/ElliotModel/SkillRun.swift \
        ElliotKit/Tests/ElliotEngineTests/AppraisalHarvesterTests.swift
git commit -m "feat(engine): harvest an appraisal from its artifact, or from nothing"
```

---

### Task 10: `finish` routes on the kind, and the sentinel is written once

**Files:**
- Modify: `ElliotKit/Sources/ElliotEngine/RunScheduler.swift:53-58,69-87,352-357,417-506`
- Test: `ElliotKit/Tests/ElliotEngineTests/AppraisalHarvesterTests.swift` (a second suite in the same file: `SchedulerFinishRoutingTests`)

**Interfaces:**
- Consumes: `SkillKind.isReadOnly` (Task 1); `AppraisalHarvester` (Task 9); `StoreLocation.appraisalArtifactURL(runID:)` (Task 4).
- Produces:
  - `RunScheduler.init(store:toolConfig:verifier:harvester:appraiser:limits:ceiling:)` — one new parameter, `appraiser: AppraisalHarvester? = nil`, defaulted from `store` exactly as `harvester` is.
  - `RunScheduler.finish` switches exhaustively on `run.kind`; a sixth kind is a compile error there.
  - `treeBaselines` is erased in `finish` **above** the routing.

- [ ] **Step 1: Write the failing test**

Append to `ElliotKit/Tests/ElliotEngineTests/AppraisalHarvesterTests.swift`, after the `AppraisalHarvesterTests` suite:

```swift
/// The routing in `RunScheduler.finish`, read out of the source.
///
/// In the idiom of `DrainDuplicationTests`: what is under test is a **shape**
/// no behavioural test can pin, because a boolean that happened to route
/// correctly today would pass every one of them. The shape is what stops the
/// next kind from silently joining a branch — `if updated.isAnalysis` sent an
/// appraisal into `completeCardRun`, which asks `gh` about an issue and a pull
/// request the card does not have.
@Suite("Scheduler finish — routing")
struct SchedulerFinishRoutingTests {

    /// Three deletions, not two: this file is
    /// `ElliotKit/Tests/ElliotEngineTests/AppraisalHarvesterTests.swift`, and
    /// `Sources/` is a sibling of `Tests/` under `ElliotKit`. The same climb
    /// `DrainDuplicationTests` makes, and it fails by `String(contentsOf:)`
    /// throwing rather than by reporting a wrong shape — which is why the count
    /// is written down rather than eyeballed.
    private var source: String {
        get throws {
            let url = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()   // ElliotEngineTests
                .deletingLastPathComponent()   // Tests
                .deletingLastPathComponent()   // ElliotKit
                .appendingPathComponent("Sources/ElliotEngine/RunScheduler.swift")
            return try String(contentsOf: url, encoding: .utf8)
        }
    }

    @Test("finish routes on the kind, not on a boolean")
    func routingIsASwitch() throws {
        let text = try source
        #expect(text.contains("switch updated.kind {"))
        // The boolean is gone from the routing. It survives as
        // `SkillRun.isAnalysis` for readers that genuinely mean "an analysis",
        // but nothing in this file may route on it.
        #expect(!text.contains("if updated.isAnalysis"))
    }

    @Test("Every kind is named in the routing, so a sixth is a compile error")
    func routingNamesEveryKind() throws {
        let text = try source
        #expect(text.contains("case .analyzeRepo:"))
        #expect(text.contains("case .appraiseCards:"))
        #expect(text.contains("case .createIssue, .implementIssue, .mergePR:"))
        // No `default:` anywhere in the file — that is what makes the compiler
        // the guard rather than this test.
        #expect(!text.contains("default:"))
    }

    @Test("The tree baseline is erased once, above the routing")
    func baselineIsErasedOnce() throws {
        let text = try source
        // Exactly three sites, and the third is `finish`'s own erasure — a
        // fourth path that returned without erasing would leak one entry per
        // run, for the lifetime of the process.
        let writes = text.components(separatedBy: "treeBaselines[run.id]").count - 1
        let removals = text.components(separatedBy: "treeBaselines.removeValue").count - 1
        #expect(writes == 2)
        #expect(removals == 1)
        // And it is not inside `completeAnalysisRun` any more: that method now
        // takes the baseline as a parameter.
        #expect(text.contains("baseline: String?"))
    }

    @Test("The git sentinel is written once and read by both read-only completions")
    func theSentinelIsNotCopied() throws {
        let text = try source
        // The eight lines that fold the sentinel onto a report exist once. Two
        // copies is the shape #146 caught in `ChildProcess`: when the
        // *explanation* of an invariant has been copied, the invariant has been.
        let folds = text.components(separatedBy: "report.workingTreeChanged = changed").count - 1
        #expect(folds == 1)
        #expect(text.contains("private func sealSentinel("))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd ElliotKit && swift test --filter SchedulerFinishRoutingTests`

Expected: FAIL, four expectations, the first reporting
`Expectation failed: text.contains("switch updated.kind {")`.

- [ ] **Step 3: Write minimal implementation**

In `ElliotKit/Sources/ElliotEngine/RunScheduler.swift`:

Add the stored property beside `harvester` (line 53):

```swift
    private let appraiser: AppraisalHarvester
```

In `init` (lines 69-87), add the parameter after `harvester` and assign it:

```swift
        harvester: ProposalHarvester? = nil,
        appraiser: AppraisalHarvester? = nil,
```

```swift
        self.appraiser = appraiser ?? AppraisalHarvester(store: store)
```

Replace line 352:

```swift
        if updated.kind.isReadOnly {
```

Replace `finish`'s routing block — **lines 434-446**, the four-line `// One split, in one place` comment included, since the replacement re-writes that comment. (Starting at 437 leaves its first three lines stranded above the new one.)

Replace it with:

```swift
        // The baseline is erased for **every** run, above the routing rather
        // than inside a branch of it. The dictionary has exactly three sites —
        // the two in `start` and this one — and a fourth path returning without
        // an erasure leaks one entry per run for the lifetime of the process.
        let treeBaseline = treeBaselines.removeValue(forKey: run.id)

        // One split, in one place. A `switch` and not the `if updated.isAnalysis`
        // this was: the boolean routed an appraisal — which carries a `cardID` —
        // into `completeCardRun`, where `gh` is asked about an issue and a pull
        // request the card does not have. A sixth kind is now a compile error
        // here instead of a silent third meaning for an existing branch.
        //
        // `var verified` outside, because `inout` arguments are not allowed in a
        // ternary and the three branches do not all produce one.
        var verified: VerifiedOutcome?
        switch updated.kind {
        case .analyzeRepo:
            await completeAnalysisRun(&updated, baseline: treeBaseline)
        case .appraiseCards:
            await completeAppraisalRun(&updated, baseline: treeBaseline)
        case .createIssue, .implementIssue, .mergePR:
            verified = await completeCardRun(&updated)
        }
```

> ⚠️ **Cross-plan: if PR3 has landed, that last call takes an argument.** PR3's Task 5 changes the
> signature to `completeCardRun(_ run: inout SkillRun, resume: ResumeVerdict)` — **no default**, on
> purpose — and inserts `let resume = ResumeVerdict.of(resumedFrom: run.resumedFrom, result: …)`
> into `finish` just above this block. Measure before pasting:
>
> ```bash
> grep -n 'func completeCardRun' ElliotKit/Sources/ElliotEngine/RunScheduler.swift
> ```
>
> - one parameter → paste as written above.
> - two parameters → keep PR3's `let resume = …` line above the `switch`, and write the arm as
>   `verified = await completeCardRun(&updated, resume: resume)`.
>
> The replacement range in this step (`lines 434-446`) is read against `main`; PR3 edits that exact
> region, so **locate `finish`'s routing block by the `// One split, in one place` comment** rather
> than by the numbers. PR3 leaves that comment in place, so it is still the anchor.

Replace `completeAnalysisRun` (lines 470-506) with the version that takes the baseline and delegates the sentinel, and add the appraisal twin and the shared sentinel below it:

```swift
    /// Harvest the artifact, then answer the sentinel's question.
    private func completeAnalysisRun(_ run: inout SkillRun, baseline: String?) async {
        guard let analysisID = run.analysisID,
              let analysis = try? await store.analysis(id: analysisID),
              let repo = try? await store.repo(id: run.repoID)
        else {
            run.analysisReport = AnalysisRunReport(
                harvestSource: .none,
                dropped: ["The analysis this run belonged to could not be found."]
            )
            return
        }

        var report = await harvester.harvest(
            run: run,
            analysis: analysis,
            repo: repo,
            artifactURL: StoreLocation.analysisArtifactURL(analysisID: analysisID, runID: run.id)
        )
        await sealSentinel(&report, baseline: baseline, repoPath: repo.path)
        run.analysisReport = report
    }

    /// The same two steps for an appraisal: harvest the artifact, then answer
    /// the sentinel.
    ///
    /// It has no analysis to look up — that is the whole of the `cardID`
    /// decision — so the artifact is keyed on the run alone.
    private func completeAppraisalRun(_ run: inout SkillRun, baseline: String?) async {
        guard let repo = try? await store.repo(id: run.repoID) else {
            run.analysisReport = AnalysisRunReport(
                harvestSource: .none,
                dropped: ["The repository this appraisal ran in could not be found."]
            )
            return
        }

        var report = await appraiser.harvest(
            run: run,
            repo: repo,
            artifactURL: StoreLocation.appraisalArtifactURL(runID: run.id)
        )
        await sealSentinel(&report, baseline: baseline, repoPath: repo.path)
        run.analysisReport = report
    }

    /// Folds the git sentinel's answer onto a read-only run's report.
    ///
    /// One implementation for both read-only kinds. Two copies of these lines
    /// would be two copies of the argument in them, which is the shape #146
    /// caught in `ChildProcess`: when the *explanation* of an invariant has been
    /// copied word for word, the invariant has been copied too.
    ///
    /// Explicit even when unchanged: a checked-and-clean tree (`false`) must not
    /// read the same as a tree the sentinel never got to look at (`nil`) — that
    /// collapse is exactly what let an orphaned run masquerade as verified-clean.
    private func sealSentinel(
        _ report: inout AnalysisRunReport, baseline: String?, repoPath: String
    ) async {
        guard let baseline else { return }
        let after = await git.porcelainStatus(cwd: repoPath)
        let changed = after != baseline
        report.workingTreeChanged = changed
        if changed {
            report.workingTreeDiff = after
        }
    }
```

⚠ While editing, check the file for any remaining `default:` — `SchedulerFinishRoutingTests.routingNamesEveryKind` asserts there is none, and that assertion is what makes the compiler the guard.

- [ ] **Step 4: Run test to verify it passes**

Run: `cd ElliotKit && swift test --filter SchedulerFinishRoutingTests`

Expected: PASS — `Test run with 4 tests passed`.

Then the behaviour either side of the change:
`cd ElliotKit && swift test --filter AppraisalHarvesterTests` — PASS.
`cd ElliotKit && swift test --filter EndToEndSuites` — PASS, including `theSentinelFires`, which is the only test that proves `sealSentinel` still reports a tree that moved.

- [ ] **Step 5: Commit**

```bash
git rev-parse --abbrev-ref HEAD
git add ElliotKit/Sources/ElliotEngine/RunScheduler.swift \
        ElliotKit/Tests/ElliotEngineTests/AppraisalHarvesterTests.swift
git commit -m "feat(engine): finish routes on the run's kind, with one sentinel"
```

---

### Task 11: An appraisal is spawned tighter, and allowed to write its artifact

**Files:**
- Modify: `ElliotKit/Sources/ElliotProcess/ClaudeRunner.swift:5-71`
- Modify: `ElliotKit/Sources/ElliotModel/Repo.swift:52-59` (a new extension below `PermissionMode`, whose six cases end at line 59)
- Modify: `ElliotKit/Sources/ElliotEngine/RunScheduler.swift:333-348`
- Test: `ElliotKit/Tests/ElliotModelTests/AppraisalPermissionModeTests.swift`
- Test: `ElliotKit/Tests/ElliotEngineTests/AppraisalInvocationTests.swift`
- Test: `ElliotKit/Tests/ElliotProcessTests/ClaudeRunnerTests.swift:72-80` (a new `@Test` beside `allowedTools`, which lives in the **`ClaudeInvocationTests`** suite at `:43` — that file holds two suites, and `--filter ClaudeRunnerTests` would run the other one, report no failures, and tell you nothing)

**Interfaces:**
- Consumes: `SkillKind.appraiseCards` (Task 1); `StoreLocation.appraisalRunDirectory(runID:)` (Task 4).
- Produces:
  - `ClaudeInvocation.extraDirectories: [String]` — a stored property, defaulted to `[]` in the memberwise `init`, emitted as one `--add-dir <path>` pair per entry immediately after the `cwd` pair.
  - `PermissionMode.appraisal(repo:) -> PermissionMode` — `static`, in `ElliotModel`.
  - `RunScheduler.invocation(for:repo:perRunUSD:) -> ClaudeInvocation` — `static`, `internal`, so it is testable without spawning.

> ⚠️ **Cross-plan: PR3 inserts at the same point in `arguments()`, and the order is arbitrated.**
> PR3's Task 1 adds `ClaudeInvocation.resumeFrom` and emits `"--resume", <id>, "--fork-session"`
> "immediately after `--add-dir`, cwd" — the seam this task also claims. **The arbitrated order is:
> the extra `--add-dir` pairs first, then the resume tokens.** Both plans' assertions hold under it
> (PR3's whole-list `#expect` sets no extra directories; this task's sets no `resumeFrom`), so a
> reversed order would go unmeasured while putting `--add-dir` *between* `--resume` and
> `--fork-session`. Whichever of PR3 and PR6 ships second puts its `if let` **below** the other's
> and says so in its pull request body.
>
> ⚠️ **`RunScheduler.invocation(for:repo:perRunUSD:)` is the same function PR3's Task 6 rewrites.**
> PR3 makes `start` build the invocation from `run.cwd` (not `repo.path`) and set
> `invocation.resumeFrom = run.resumedFrom`. If PR3 has landed, this task's extraction must
> **carry both of those forward** into the extracted `static func` — dropping the `run.cwd` half
> silently reintroduces the `No conversation found` spin PR3 exists to close, and dropping
> `resumeFrom` disables the fork entirely. Read the body you are extracting; do not paste this
> plan's version over a `start` that has already been corrected.

**Why a tighter mode.** Runs default to `--permission-mode bypassPermissions`. An appraisal inherits the operator's MCP config, so it can see the `elliot` server and call `board_move_card` — under `bypassPermissions` that is granted silently and the run ends "success" having driven the board. Under the cap the attempt is **refused**, the tool name lands in `permissionDenials`, and `RunScheduler.state(for:)` ends the run `.completedWithDenials` (`RunScheduler.swift:511-515`). The loop becomes measurable instead of invisible. The price is that the artifact write must be allowed explicitly, which is what `extraDirectories` buys — the directory is under `ELLIOT_HOME`, outside the checkout `--add-dir cwd` already covers.

- [ ] **Step 1: Write the failing test**

Create `ElliotKit/Tests/ElliotModelTests/AppraisalPermissionModeTests.swift`:

```swift
import Testing

@testable import ElliotModel

/// The mode an appraisal runs under, for every mode a repository can be in.
///
/// An allow-list and not a ranking. The CLI has added modes before (`auto`,
/// `dontAsk`), and an ordering of names nobody here has measured is a guess —
/// this repository's whole discipline is that a guess written down becomes a
/// fact. So the two modes that are certainly at least as tight are named, and
/// everything else is capped.
@Suite("Appraisal permission mode")
struct AppraisalPermissionModeTests {

    @Test("The default is capped at acceptEdits")
    func bypassIsCapped() {
        #expect(PermissionMode.appraisal(repo: .bypassPermissions) == .acceptEdits)
    }

    @Test("Modes whose reach is not measured here are capped too", arguments: [
        PermissionMode.auto, .dontAsk,
    ])
    func unmeasuredModesAreCapped(mode: PermissionMode) {
        #expect(PermissionMode.appraisal(repo: mode) == .acceptEdits)
    }

    @Test("A repository already at or below the cap keeps its own choice", arguments: [
        PermissionMode.plan, .manual, .acceptEdits,
    ])
    func tighterChoicesAreKept(mode: PermissionMode) {
        // `.plan` is kept even though a run under it cannot write the artifact
        // at all. That is the honest outcome — the harvester reports "no
        // artifact" — and it beats silently widening a mode the operator chose.
        #expect(PermissionMode.appraisal(repo: mode) == mode)
    }

    @Test("Every mode has an answer, so a seventh is a compile error not a default")
    func everyModeIsAnswered() {
        for mode in PermissionMode.allCases {
            let capped = PermissionMode.appraisal(repo: mode)
            #expect(capped == mode || capped == .acceptEdits)
        }
    }

    @Test("It is never wider than bypassPermissions, whatever the repository says")
    func itNeverWidens() {
        #expect(PermissionMode.allCases.allSatisfy {
            PermissionMode.appraisal(repo: $0) != .bypassPermissions
        })
    }
}
```

Create `ElliotKit/Tests/ElliotEngineTests/AppraisalInvocationTests.swift`:

```swift
import ElliotModel
import ElliotProcess
import ElliotStore
import Foundation
import TestSupport
import Testing

@testable import ElliotEngine

/// The argv a run is spawned with, decided in one pure function so it can be
/// asserted without spawning anything.
///
/// Two facts differ for an appraisal — a tighter permission mode, and the one
/// directory outside the checkout it must be allowed to write — and they travel
/// together here rather than as two `if`s inside a spawn routine, where only one
/// of them would be remembered next time.
@Suite("Appraisal invocation")
struct AppraisalInvocationTests {

    private func repo(_ mode: PermissionMode = .bypassPermissions) -> Repo {
        Repo(
            path: "/tmp/checkout", nameWithOwner: "phmatray/Elliot",
            displayName: "Elliot", permissionMode: mode
        )
    }

    private func run(_ kind: SkillKind, repoID: UUID) -> SkillRun {
        SkillRun(
            cardID: kind == .analyzeRepo ? nil : UUID(),
            repoID: repoID,
            analysisID: kind == .analyzeRepo ? UUID() : nil,
            kind: kind, prompt: "x", cwd: "/tmp/checkout",
            logPath: "/tmp/a", stderrPath: "/tmp/b", createdAt: Date()
        )
    }

    @Test("A writer is spawned exactly as it was: the repository's mode, one add-dir")
    func writersAreUnchanged() {
        let repo = repo()
        let invocation = RunScheduler.invocation(
            for: run(.implementIssue, repoID: repo.id), repo: repo, perRunUSD: nil)
        #expect(invocation.permissionMode == .bypassPermissions)
        #expect(invocation.extraDirectories.isEmpty)
        #expect(invocation.arguments().filter { $0 == "--add-dir" }.count == 1)
    }

    @Test("An appraisal is spawned tighter than its repository")
    func appraisalIsTightened() {
        let repo = repo()
        let invocation = RunScheduler.invocation(
            for: run(.appraiseCards, repoID: repo.id), repo: repo, perRunUSD: nil)
        // Not `bypassPermissions`: a denied tool is the whole point. Under the
        // default the MCP self-call is granted in silence and the run ends
        // "success" having driven the board.
        #expect(invocation.permissionMode == .acceptEdits)
    }

    @Test("An appraisal may write its artifact directory, and only that")
    func appraisalCarriesItsArtifactDirectory() throws {
        _ = TestHome.root
        let repo = repo()
        let subject = run(.appraiseCards, repoID: repo.id)
        let invocation = RunScheduler.invocation(for: subject, repo: repo, perRunUSD: nil)

        let expected = StoreLocation.appraisalRunDirectory(runID: subject.id).path
        #expect(invocation.extraDirectories == [expected])

        // Two `--add-dir` pairs, each a single argv element — the artifact lives
        // under `ELLIOT_HOME`, whose real shape carries spaces.
        let args = invocation.arguments()
        let directories = args.enumerated()
            .filter { $0.element == "--add-dir" }
            .map { args[$0.offset + 1] }
        #expect(directories == [repo.path, expected])
    }

    @Test("An analysis is not tightened by this change")
    func analysesAreUntouched() {
        // Deliberate, and out of scope: an analysis writes its artifact today
        // because it runs under `bypassPermissions`. Widening or tightening it
        // is a separate change with its own measurement.
        let repo = repo()
        let invocation = RunScheduler.invocation(
            for: run(.analyzeRepo, repoID: repo.id), repo: repo, perRunUSD: nil)
        #expect(invocation.permissionMode == .bypassPermissions)
        #expect(invocation.extraDirectories.isEmpty)
    }

    @Test("A repository already tighter than the cap keeps its own mode")
    func aTighterRepositoryIsRespected() {
        let repo = repo(.plan)
        let invocation = RunScheduler.invocation(
            for: run(.appraiseCards, repoID: repo.id), repo: repo, perRunUSD: nil)
        #expect(invocation.permissionMode == .plan)
    }

    @Test("The per-run ceiling still reaches the argv")
    func theBudgetSurvives() {
        let repo = repo()
        let invocation = RunScheduler.invocation(
            for: run(.appraiseCards, repoID: repo.id), repo: repo, perRunUSD: 0.5)
        #expect(invocation.arguments().contains("--max-budget-usd"))
    }
}
```

In `ElliotKit/Tests/ElliotProcessTests/ClaudeRunnerTests.swift`, after `allowedTools` (line 80's closing brace), add:

```swift
    @Test("Extra directories are one --add-dir each, after the working directory")
    func extraDirectories() {
        var invocation = ClaudeInvocation(runID: UUID(), prompt: "x", cwd: "/tmp/checkout")
        #expect(invocation.arguments().filter { $0 == "--add-dir" }.count == 1)

        // Two spaces, the shape of the real home. One flag per directory keeps
        // each path a single argv element; a variadic `--add-dir a b` would put
        // the burden of quoting somewhere nobody is looking.
        invocation.extraDirectories = ["/Users/p/Library/Application  Support/Elliot/analyses"]
        let args = invocation.arguments()
        let directories = args.enumerated()
            .filter { $0.element == "--add-dir" }
            .map { args[$0.offset + 1] }
        #expect(directories == [
            "/tmp/checkout", "/Users/p/Library/Application  Support/Elliot/analyses",
        ])
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd ElliotKit && swift test --filter AppraisalPermissionModeTests`

Expected: FAIL to compile, with
`error: type 'PermissionMode' has no member 'appraisal'`.

Run: `cd ElliotKit && swift test --filter AppraisalInvocationTests`

Expected: FAIL to compile, with
`error: type 'RunScheduler' has no member 'invocation'`.

- [ ] **Step 3: Write minimal implementation**

In `ElliotKit/Sources/ElliotProcess/ClaudeRunner.swift`, add the stored property after `extraAllowedTools` (line 12):

```swift
    /// Directories the run may reach besides `cwd`.
    ///
    /// Empty for every run that only touches its checkout. An appraisal's
    /// artifact lives under `ELLIOT_HOME`, outside the checkout, and an
    /// appraisal is spawned under a mode tighter than `bypassPermissions` — so
    /// without this the one write it was asked to make is the one it is refused.
    public var extraDirectories: [String]
```

Add the parameter to `init` after `extraAllowedTools` (line 22) and assign it:

```swift
        extraDirectories: [String] = [],
```

```swift
        self.extraDirectories = extraDirectories
```

In `arguments()`, immediately after the array literal that ends with `"--add-dir", cwd,` (line 55):

```swift
        // One flag per directory rather than one variadic `--add-dir a b`: each
        // path then stays a single argv element, and Elliot's own home is
        // `~/Library/Application Support/Elliot`, which has a space in it.
        for directory in extraDirectories {
            args += ["--add-dir", directory]
        }
```

In `ElliotKit/Sources/ElliotModel/Repo.swift`, after the `PermissionMode` enum's closing brace:

```swift
public extension PermissionMode {
    /// The mode an appraisal runs under: never wider than `.acceptEdits`, and
    /// never wider than the repository's own choice.
    ///
    /// Tighter than `repo.permissionMode` on purpose. An appraisal inherits the
    /// operator's MCP configuration, so its agent can see the `elliot` server
    /// and call `board_move_card`. Under `bypassPermissions` that is granted in
    /// silence and the run ends "success" having driven the board; under this
    /// cap it is **refused**, the tool name lands in `permissionDenials`, and
    /// `RunScheduler.state(for:)` ends the run `.completedWithDenials`. The loop
    /// worth worrying about becomes measurable rather than invisible.
    ///
    /// An allow-list and not a ranking: the CLI has added modes before (`auto`,
    /// `dontAsk`) and an ordering of names nobody has measured is a guess. The
    /// two modes that are certainly no wider keep their own value; everything
    /// else is capped. A seventh mode is a compile error here.
    ///
    /// A repository pinned to `.plan` keeps `.plan`, and a run under it cannot
    /// write its artifact at all — which the harvester reports as "no artifact",
    /// honestly, rather than being silently widened here.
    static func appraisal(repo: PermissionMode) -> PermissionMode {
        switch repo {
        case .plan, .manual, .acceptEdits: repo
        case .auto, .dontAsk, .bypassPermissions: .acceptEdits
        }
    }
}
```

In `ElliotKit/Sources/ElliotEngine/RunScheduler.swift`, add above `private func start(_:)` (line 333):

```swift
    /// How a run is spawned.
    ///
    /// `static` and `internal` so it can be asserted without spawning anything:
    /// what a run is allowed to do is a rule, and a rule inside a spawn routine
    /// is a rule nothing can test. The two facts that differ for an appraisal —
    /// a tighter permission mode and the one directory outside the checkout it
    /// must be allowed to write — travel together here rather than as two `if`s
    /// in `start`, where only one of them would be remembered next time.
    static func invocation(for run: SkillRun, repo: Repo, perRunUSD: Double?) -> ClaudeInvocation {
        let isAppraisal = run.kind == .appraiseCards
        return ClaudeInvocation(
            runID: run.id,
            prompt: run.prompt,
            cwd: repo.path,
            permissionMode: isAppraisal
                ? PermissionMode.appraisal(repo: repo.permissionMode)
                : repo.permissionMode,
            extraAllowedTools: repo.extraAllowedTools,
            extraDirectories: isAppraisal
                ? [StoreLocation.appraisalRunDirectory(runID: run.id).path]
                : [],
            maxBudgetUSD: perRunUSD
        )
    }
```

Replace the invocation literal in `start` (lines 340-347) with:

```swift
        let invocation = Self.invocation(for: run, repo: repo, perRunUSD: ceiling.perRunUSD)
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd ElliotKit && swift test --filter AppraisalPermissionModeTests`

Expected: PASS, **0 failures**, over five `@Test` functions — three plain, plus `unmeasuredModesAreCapped` (two arguments) and `tighterChoicesAreKept` (three). Read the `0 failures` and the five test names, not the headline total: whether the runner tallies a parameterised test as one or as its cases is not something this plan has measured, and a number nobody has run is exactly the kind of claim this repository does not make.

Run: `cd ElliotKit && swift test --filter AppraisalInvocationTests`

Expected: PASS — `Test run with 6 tests passed`.

Run: `cd ElliotKit && swift test --filter ClaudeInvocationTests`

Expected: PASS — including `argumentList`, whose exact argv is unchanged because `extraDirectories` defaults to empty.

- [ ] **Step 5: Commit**

```bash
git rev-parse --abbrev-ref HEAD
git add ElliotKit/Sources/ElliotProcess/ClaudeRunner.swift \
        ElliotKit/Sources/ElliotModel/Repo.swift \
        ElliotKit/Sources/ElliotEngine/RunScheduler.swift \
        ElliotKit/Tests/ElliotModelTests/AppraisalPermissionModeTests.swift \
        ElliotKit/Tests/ElliotEngineTests/AppraisalInvocationTests.swift \
        ElliotKit/Tests/ElliotProcessTests/ClaudeRunnerTests.swift
git commit -m "feat(process): spawn an appraisal tighter, and let it write its artifact"
```

---

### Task 12: `UnattendedStartRefusal` — the rule moves out of the view

**Files:**
- Create: `ElliotKit/Sources/ElliotModel/UnattendedStartRefusal.swift`
- Modify: `ElliotKit/Sources/ElliotAppKit/Consequence.swift:91-101`
- Modify: `ElliotKit/Sources/ElliotAppKit/AppModel.swift:1918-1938`
- Test: `ElliotKit/Tests/ElliotModelTests/UnattendedStartRefusalTests.swift`

**Interfaces:**
- Consumes: `Repo` (`ElliotModel/Repo.swift:7`), specifically `isEnabled`.
- Produces:
  ```swift
  public enum UnattendedStartRefusal: Sendable, Hashable {
      case noRepositoryChosen
      case repoDisabled
      case preflightBlocked
      public var sentence: String
      public static func refusal(repo: Repo, preflightBlocks: Bool) -> UnattendedStartRefusal?
  }
  ```
  `AppModel.analysisRefusal: String?` keeps its type and its sentences; `Consequence.reason(.repoDisabled)` now reads `UnattendedStartRefusal.repoDisabled.sentence`.

**Why it moves.** The only preflight gate on the analysis path is a computed property on a SwiftUI model — `AppModel.analysisRefusal` (`AppModel.swift:1929-1938`), whose own comment records that #151 nearly deleted it along with a `.disabled(…)`. `AnalysisService.start` checks `isEnabled` and the in-flight dedupe and nothing else (`AnalysisService.swift:59`). An appraisal makes that worse rather than better: it passes through **no** transition, so `evaluateMove`, `allowsSideEffects` and `repoPreflight` never see it, and there is no point of application for the abort rule. One rule, one implementation, three callers — this task builds the rule and rewires the reader; Task 13 wires the first service; Task 14 the second.

- [ ] **Step 1: Write the failing test**

Create `ElliotKit/Tests/ElliotModelTests/UnattendedStartRefusalTests.swift`:

```swift
import Foundation
import Testing

@testable import ElliotModel

/// The one rule that says whether an unattended agent may start against a
/// repository. Pure, so all three callers can consult the same answer: the
/// analysis service, the appraisal service, and the view that renders it.
@Suite("Unattended start — the refusal")
struct UnattendedStartRefusalTests {

    private func repo(enabled: Bool = true) -> Repo {
        Repo(
            path: "/tmp/r", nameWithOwner: "phmatray/Elliot",
            displayName: "Elliot", isEnabled: enabled
        )
    }

    @Test("A healthy, enabled repository is not refused")
    func healthyIsAllowed() {
        #expect(UnattendedStartRefusal.refusal(repo: repo(), preflightBlocks: false) == nil)
    }

    @Test("A disabled repository is refused, whatever Preflight says")
    func disabledIsRefused() {
        #expect(
            UnattendedStartRefusal.refusal(repo: repo(enabled: false), preflightBlocks: false)
                == .repoDisabled
        )
        #expect(
            UnattendedStartRefusal.refusal(repo: repo(enabled: false), preflightBlocks: true)
                == .repoDisabled
        )
    }

    @Test("A repository Preflight is failing is refused")
    func blockedIsRefused() {
        #expect(
            UnattendedStartRefusal.refusal(repo: repo(), preflightBlocks: true)
                == .preflightBlocked
        )
    }

    @Test("Disabled outranks blocked, so the sentence names the switch not the check")
    func orderingIsPartOfTheRule() {
        // A repository that is both switched off and failing a check is switched
        // off: telling the reader to fix a check they cannot reach from a
        // disabled repository sends them to the wrong screen.
        #expect(
            UnattendedStartRefusal.refusal(repo: repo(enabled: false), preflightBlocks: true)
                != .preflightBlocked
        )
    }

    @Test("Every case has a sentence, and each names a different place to go")
    func everyCaseSpeaks() {
        let sentences = [
            UnattendedStartRefusal.noRepositoryChosen.sentence,
            UnattendedStartRefusal.repoDisabled.sentence,
            UnattendedStartRefusal.preflightBlocked.sentence,
        ]
        #expect(sentences.allSatisfy { !$0.isEmpty })
        #expect(Set(sentences).count == 3)
        #expect(UnattendedStartRefusal.preflightBlocked.sentence.contains("Preflight"))
        #expect(UnattendedStartRefusal.repoDisabled.sentence.contains("Preflight"))
    }

    @Test("preflightBlocks: false means checked-and-clear, never not-asked")
    func falseIsAnAnswerNotAnAbsence() {
        // Written down because the caller pays for it: `PreflightService.repoChecks`
        // is roughly six subprocesses and a networked `gh label list`, and the
        // temptation is to pass `false` when nobody has asked. A caller that has
        // not asked has not established anything, and must ask.
        #expect(UnattendedStartRefusal.refusal(repo: repo(), preflightBlocks: false) == nil)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd ElliotKit && swift test --filter UnattendedStartRefusalTests`

Expected: FAIL to compile, with
`error: cannot find 'UnattendedStartRefusal' in scope`.

- [ ] **Step 3: Write minimal implementation**

Create `ElliotKit/Sources/ElliotModel/UnattendedStartRefusal.swift`:

```swift
import Foundation

/// Why an unattended agent may not be started against a repository right now.
///
/// One rule, three callers: `AnalysisService.start`, `AppraisalService.appraise`,
/// and `AppModel.analysisRefusal`, which renders it for the toolbar's tooltip
/// and the analysis panel's footer.
///
/// It is here, pure, because the only gate that existed was a computed property
/// on a SwiftUI model — and #151 removed the `.disabled(…)` it fed, correctly,
/// very nearly taking the gate with it. An appraisal makes that worse rather
/// than better: it passes through no transition at all, so `evaluateMove`,
/// `allowsSideEffects` and `repoPreflight` never see it. It is the only
/// unattended agent in Elliot that starts outside "moving a card is the act of
/// execution", and this is its point of application.
public enum UnattendedStartRefusal: Sendable, Hashable {
    /// Nothing is selected, or more than one thing is.
    ///
    /// Produced by a caller that has a picker, never by ``refusal(repo:preflightBlocks:)``:
    /// a service is handed a repository or it has nothing to run against, so
    /// "which one" is a selection question rather than a fact about a repository.
    case noRepositoryChosen
    case repoDisabled
    case preflightBlocked

    /// The whole sentence, ready to show.
    ///
    /// Each one names the place to go rather than the rule that fired — "fix it
    /// in Preflight" tells you what to do; "refused" does not.
    public var sentence: String {
        switch self {
        case .noRepositoryChosen:
            "Pick a single repository to analyse."
        case .repoDisabled:
            "This repository is switched off in Preflight."
        case .preflightBlocked:
            "A Preflight check is failing for this repository — fix it there first."
        }
    }

    /// `nil` when an unattended run may start.
    ///
    /// `preflightBlocks` is a parameter rather than something computed here: the
    /// facts come from `PreflightService`, which spawns roughly six subprocesses
    /// and makes a network call, and this stays pure. ⚠ `false` means **checked,
    /// and nothing is failing** — never "nobody asked". A caller that has not
    /// asked has established nothing and must ask; passing `false` for
    /// convenience is how a gate becomes a decoration.
    ///
    /// The ordering is part of the rule. A repository that is both switched off
    /// and failing a check is *switched off*: sending the reader to a check they
    /// cannot reach from a disabled repository is sending them to the wrong
    /// screen.
    public static func refusal(repo: Repo, preflightBlocks: Bool) -> UnattendedStartRefusal? {
        if !repo.isEnabled { return .repoDisabled }
        if preflightBlocks { return .preflightBlocked }
        return nil
    }
}
```

In `ElliotKit/Sources/ElliotAppKit/Consequence.swift`, replace line 98:

```swift
        case .repoDisabled: UnattendedStartRefusal.repoDisabled.sentence
```

and add above `static func reason` (line 91), after its existing doc comment:

```swift
    /// `.repoDisabled` reads its sentence from `UnattendedStartRefusal` rather
    /// than holding a second copy of it. The two enums are different questions —
    /// one is a refused *move*, the other a refused *start* — but on this case
    /// they are the same fact, and `AnalysisSessionTests` has asserted the two
    /// strings equal since before either could diverge.
```

In `ElliotKit/Sources/ElliotAppKit/AppModel.swift`, replace the body of `analysisRefusal` (lines 1929-1938):

```swift
    public var analysisRefusal: String? {
        guard let id = selectedRepoID, let repo = repos.first(where: { $0.id == id }) else {
            return UnattendedStartRefusal.noRepositoryChosen.sentence
        }
        // The **display** of the rule. The rule itself is in `ElliotModel` and
        // is enforced by the services that actually start something — this
        // property fed a `.disabled(…)` until #151 removed it, and the gate must
        // not depend on a view being on screen.
        //
        // `isBlocked` reads `repoChecks`, the cache the Preflight sweep filled.
        // That is right here and wrong in a service: a tooltip may show a
        // reading from a minute ago, an unattended start may not.
        return UnattendedStartRefusal.refusal(
            repo: repo, preflightBlocks: isBlocked(repo)
        )?.sentence
    }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd ElliotKit && swift test --filter UnattendedStartRefusalTests`

Expected: PASS — `Test run with 6 tests passed`.

Then the two readers, whose sentences must be unchanged:
`cd ElliotKit && swift test --filter AnalysisSessionTests` — PASS, including `analysisIsGatedOnPreflight`, which asserts `model.analysisRefusal == Consequence.reason(.repoDisabled)`.
`cd ElliotKit && swift test --filter MoveHistoryTests` — PASS.

- [ ] **Step 5: Commit**

```bash
git rev-parse --abbrev-ref HEAD
git add ElliotKit/Sources/ElliotModel/UnattendedStartRefusal.swift \
        ElliotKit/Sources/ElliotAppKit/Consequence.swift \
        ElliotKit/Sources/ElliotAppKit/AppModel.swift \
        ElliotKit/Tests/ElliotModelTests/UnattendedStartRefusalTests.swift
git commit -m "refactor(model): one rule for whether an unattended agent may start"
```

---

### Task 13: `RepoGating`, and the analysis path becomes the rule's second caller

**Files:**
- Create: `ElliotKit/Sources/ElliotEngine/RepoGate.swift`
- Modify: `ElliotKit/Sources/ElliotEngine/AnalysisService.swift:6-22,29-59`
- Modify: `ElliotKit/Sources/ElliotEngine/MCPRequestHandler.swift:130-154`
- Modify: `ElliotKit/Sources/ElliotAppKit/AppModel.swift:546-548`
- Modify (one line each, to state a gate): `ElliotKit/Tests/ElliotEngineTests/OfflineParityTests.swift:345-347`, `ElliotKit/Tests/ElliotEngineTests/AnalysisEndToEndTests.swift:110-112`, `ElliotKit/Tests/ElliotEngineTests/AnalysisServiceTests.swift:43-45`, `ElliotKit/Tests/ElliotEngineTests/MCPRequestHandlerTests.swift:59-61`, `ElliotKit/Tests/ElliotEngineTests/ScreenshotHandlerTests.swift:72-74`, `ElliotKit/Tests/ElliotEngineTests/ScreenshotHandlerTests.swift:199-201`, `ElliotKit/Tests/ElliotAppKitTests/AppModelTests.swift:1028-1036`
- Test: `ElliotKit/Tests/ElliotEngineTests/AnalysisServiceTests.swift` (two new `@Test`s)

**Interfaces:**
- Consumes: `UnattendedStartRefusal.refusal(repo:preflightBlocks:)` (Task 12); `PreflightService.repoChecks(_:) -> [CheckResult]` (`ElliotEngine/PreflightService.swift:274`) and `PreflightService.isBlocking(_:) -> Bool` (`:429`).
- Produces, all in `ElliotEngine`:
  ```swift
  public protocol RepoGating: Sendable {
      func blocks(_ repo: Repo) async -> Bool
  }
  public struct PreflightGate: RepoGating {
      public init(preflight: PreflightService)
  }
  public struct OpenGate: RepoGating {
      public init()
  }
  ```
  and `AnalysisService.init(store:launcher:board:gh:gate:)` — the parameter has **no default**.
  `AnalysisError.repoDisabled(String)` is **removed**; `AnalysisError.repoRefused(UnattendedStartRefusal)` replaces it.

**No default on `gate`, deliberately.** The template is `MoveContext.providedFollowUps` and PR1's argument about it: a defaulted parameter compiles everywhere and nothing catches the next construction site. The eight sites below each state their answer in one line, and a test that wants no gate says `OpenGate()` out loud rather than by omission.

- [ ] **Step 1: Write the failing test**

Add to `ElliotKit/Tests/ElliotEngineTests/AnalysisServiceTests.swift`, inside the existing suite:

```swift
    /// A gate that refuses, so the service's own check is what is under test
    /// rather than six subprocesses and a network call.
    private struct ClosedGate: RepoGating {
        func blocks(_ repo: Repo) async -> Bool { true }
    }

    /// The second caller of the one rule. `start` used to check `isEnabled` and
    /// the in-flight dedupe and nothing else, so up to eight unattended runs
    /// could begin inside a checkout Preflight had already refused — the gate
    /// lived on the analysis *panel*, and #151 nearly deleted it.
    @Test("An analysis is refused for a repository Preflight is failing")
    func analysisIsGatedOnPreflight() async throws {
        let store = try BoardStore.inMemory()
        let config = ToolConfig(
            claudePath: "/usr/bin/false", ghPath: "/usr/bin/false",
            gitPath: "/usr/bin/false", environment: [:]
        )
        let spy = LaunchSpy()
        let board = BoardService(store: store, launcher: spy)
        let service = AnalysisService(
            store: store, launcher: spy, board: board,
            gh: GHClient(config: config), gate: ClosedGate()
        )
        let repo = Repo(path: "/tmp/r", nameWithOwner: "phmatray/Elliot", displayName: "Elliot")
        try await store.saveRepo(repo)

        await #expect(throws: AnalysisError.repoRefused(.preflightBlocked)) {
            try await service.start(repoID: repo.id, angles: [.bugs], origin: .manual)
        }
        // Nothing was queued: the refusal is on the act, not on the reply.
        #expect(try await store.runs(repoID: repo.id, since: .distantPast).isEmpty)
    }

    @Test("A disabled repository is refused by the same rule, and says which")
    func disabledIsRefusedByTheRule() async throws {
        let store = try BoardStore.inMemory()
        let config = ToolConfig(
            claudePath: "/usr/bin/false", ghPath: "/usr/bin/false",
            gitPath: "/usr/bin/false", environment: [:]
        )
        let spy = LaunchSpy()
        let board = BoardService(store: store, launcher: spy)
        let service = AnalysisService(
            store: store, launcher: spy, board: board,
            gh: GHClient(config: config), gate: OpenGate()
        )
        var repo = Repo(path: "/tmp/r", nameWithOwner: "phmatray/Elliot", displayName: "Elliot")
        repo.isEnabled = false
        try await store.saveRepo(repo)

        await #expect(throws: AnalysisError.repoRefused(.repoDisabled)) {
            try await service.start(repoID: repo.id, angles: [.bugs], origin: .manual)
        }
    }
```

⚠ `LaunchSpy` is the name this suite already uses for its inert launcher — read the top of `AnalysisServiceTests.swift` and use whatever it is actually called there rather than introducing a second one.

- [ ] **Step 2: Run test to verify it fails**

Run: `cd ElliotKit && swift test --filter AnalysisServiceTests`

Expected: FAIL to compile, with
`error: cannot find type 'RepoGating' in scope`,
`error: cannot find 'OpenGate' in scope`, and
`error: type 'AnalysisError' has no member 'repoRefused'`.

- [ ] **Step 3: Write minimal implementation**

Create `ElliotKit/Sources/ElliotEngine/RepoGate.swift`:

```swift
import ElliotModel
import Foundation

/// Whether Preflight is refusing a repository, asked at the moment of the act.
///
/// A protocol rather than a `PreflightService` parameter for two reasons. A test
/// can state a verdict instead of running six subprocesses and a networked
/// `gh label list` for it; and the two services that consult it cannot each grow
/// their own idea of what "blocked" means, because there is one implementation
/// of the real answer and it is `PreflightGate`.
public protocol RepoGating: Sendable {
    /// `true` when at least one check is failing.
    ///
    /// Asked live, every time. A cached verdict is the shape of bug this exists
    /// to close: the cache belongs to a screen that may never have been opened,
    /// and an unattended agent must not start on a reading nobody took.
    func blocks(_ repo: Repo) async -> Bool
}

/// The real gate.
///
/// `PreflightService.repoChecks` judged by `PreflightService.isBlocking` — the
/// same verdict the Preflight screen shows, not a second reading of the same
/// facts.
///
/// It costs roughly six subprocesses and one network call per start. That is
/// the price of asking rather than assuming, and it is paid once per gesture
/// that can spawn up to eight unattended agents.
public struct PreflightGate: RepoGating {
    private let preflight: PreflightService

    public init(preflight: PreflightService) {
        self.preflight = preflight
    }

    public func blocks(_ repo: Repo) async -> Bool {
        PreflightService.isBlocking(await preflight.repoChecks(repo))
    }
}

/// A gate that refuses nothing.
///
/// For a caller that has already decided, and for tests — which say so out loud
/// with this type rather than by omitting an argument. `RepoGating` has no
/// default anywhere for that reason: a defaulted gate compiles at every site and
/// catches none of them.
public struct OpenGate: RepoGating {
    public init() {}

    public func blocks(_ repo: Repo) async -> Bool { false }
}
```

In `ElliotKit/Sources/ElliotEngine/AnalysisService.swift`, replace the `.repoDisabled` case (line 8) with:

```swift
    /// Preflight refuses this repository. The sentence is the rule's, not this
    /// enum's: one wording, read here and rendered by the analysis panel.
    case repoRefused(UnattendedStartRefusal)
```

and its `errorDescription` arm (line 16):

```swift
        case .repoRefused(let refusal): refusal.sentence
```

Add the stored property and the initialiser parameter (lines 30-40):

```swift
    private let gate: any RepoGating
```

```swift
    public init(
        store: BoardStore, launcher: any RunLaunching, board: BoardService,
        gh: GHClient, gate: any RepoGating
    ) {
        self.store = store
        self.launcher = launcher
        self.board = board
        self.gh = gh
        self.gate = gate
    }
```

Replace line 59:

```swift
        // The one rule, asked at the act. `start` used to check `isEnabled` here
        // and nothing else, so eight unattended runs could begin inside a
        // checkout Preflight had already refused — the only gate was on the
        // panel, and #151 removed the `.disabled(…)` that was it.
        //
        // The gate is asked even for a disabled repository, which costs a probe
        // the rule will then ignore. The alternative is for this caller to
        // re-derive the rule's ordering to save it, and a second copy of an
        // ordering is exactly what this refactor removed.
        if let refusal = UnattendedStartRefusal.refusal(
            repo: repo, preflightBlocks: await gate.blocks(repo)
        ) {
            throw AnalysisError.repoRefused(refusal)
        }
```

In `ElliotKit/Sources/ElliotEngine/MCPRequestHandler.swift`, replace the `.repoDisabled` arm (lines 142-147):

```swift
            case .repoRefused:
                return .failure(
                    code: .analysisRefused,
                    message: error.localizedDescription,
                    hint: "Open Elliot's Preflight screen and clear the failing check, or "
                        + "switch the repository back on."
                )
```

In `ElliotKit/Sources/ElliotAppKit/AppModel.swift`, replace lines 546-548:

```swift
            let analysisService = AnalysisService(
                store: store, launcher: scheduler, board: board, gh: ghClient,
                // The live verdict, not `repoChecks`: that cache belongs to a
                // screen, and a start must not depend on a screen having been
                // opened. `preflight` is already built above for the global
                // checks, so this costs no second service.
                gate: PreflightGate(preflight: preflight)
            )
```

At the seven test construction sites, add `, gate: OpenGate()` to the argument list — for example, `OfflineParityTests.swift:346`:

```swift
            store: store, launcher: launcher, board: board, gh: GHClient(config: config),
            gate: OpenGate()
```

The full list, each needing the same one-line addition:

| file | line |
|---|---|
| `ElliotKit/Tests/ElliotEngineTests/OfflineParityTests.swift` | 346 |
| `ElliotKit/Tests/ElliotEngineTests/AnalysisEndToEndTests.swift` | 111 |
| `ElliotKit/Tests/ElliotEngineTests/AnalysisServiceTests.swift` | 44 |
| `ElliotKit/Tests/ElliotEngineTests/MCPRequestHandlerTests.swift` | 60 |
| `ElliotKit/Tests/ElliotEngineTests/ScreenshotHandlerTests.swift` | 73 |
| `ElliotKit/Tests/ElliotEngineTests/ScreenshotHandlerTests.swift` | 200 |
| `ElliotKit/Tests/ElliotAppKitTests/AppModelTests.swift` | after 1035, before the `)` on 1036 |

⚠ That last one is the only site where the argument does not simply follow a one-line list: lines 1032-1035 are a nested `GHClient(config: ToolConfig(…))`, so `gate: OpenGate()` belongs after its closing `))` and before the `AnalysisService(` call's own `)` on line 1036. Putting it "on 1035" would put it inside `ToolConfig`.

`AppModelTests.swift` already carries `import ElliotEngine` (line 1), so `OpenGate` is visible with no other change.

- [ ] **Step 4: Run test to verify it passes**

Run: `cd ElliotKit && swift test --filter AnalysisServiceTests`

Expected: PASS, with `analysisIsGatedOnPreflight` and `disabledIsRefusedByTheRule` among them.

Then everything that constructs the service:
`cd ElliotKit && swift test` — PASS. Sample it five times, per the global constraints:

```bash
cd ElliotKit && for i in 1 2 3 4 5; do swift test 2>&1 | tail -3; done
```

- [ ] **Step 5: Commit**

```bash
git rev-parse --abbrev-ref HEAD
git add ElliotKit/Sources/ElliotEngine/RepoGate.swift \
        ElliotKit/Sources/ElliotEngine/AnalysisService.swift \
        ElliotKit/Sources/ElliotEngine/MCPRequestHandler.swift \
        ElliotKit/Sources/ElliotAppKit/AppModel.swift \
        ElliotKit/Tests/ElliotEngineTests/AnalysisServiceTests.swift \
        ElliotKit/Tests/ElliotEngineTests/OfflineParityTests.swift \
        ElliotKit/Tests/ElliotEngineTests/AnalysisEndToEndTests.swift \
        ElliotKit/Tests/ElliotEngineTests/MCPRequestHandlerTests.swift \
        ElliotKit/Tests/ElliotEngineTests/ScreenshotHandlerTests.swift \
        ElliotKit/Tests/ElliotAppKitTests/AppModelTests.swift
git commit -m "feat(engine): an analysis asks Preflight before it starts anything"
```

---

### Task 14: `AppraisalService`, and the card's write window in both directions

**Files:**
- Create: `ElliotKit/Sources/ElliotEngine/AppraisalService.swift`
- Test: `ElliotKit/Tests/ElliotEngineTests/AppraisalServiceTests.swift`

**Interfaces:**
- Consumes: `UnattendedStartRefusal.refusal(repo:preflightBlocks:)` (Task 12); `RepoGating` / `OpenGate` (Task 13); `AppraisalPromptBuilder.prompt(cardTitle:cardText:repoNameWithOwner:outputPath:maxEvidence:)` (Task 5); `StoreLocation.appraisalArtifactURL(runID:)` (Task 4); `BoardStore.claimCardForRun(_:) -> Bool` (Task 8); `SkillRun.card(...)` (`ElliotModel/SkillRun.swift:143`); `RunLaunching.launch(runID:)` (`ElliotEngine/RunScheduler.swift:12`).
- Produces:
  ```swift
  public enum AppraisalError: Error, LocalizedError, Equatable {
      case cardNotFound(UUID)
      case repoNotFound(UUID)
      case repoRefused(UnattendedStartRefusal)
      case cardAlreadyHeld(UUID)
  }
  public actor AppraisalService {
      public init(store: BoardStore, launcher: any RunLaunching, gate: any RepoGating)
      @discardableResult
      public func appraise(cardID: UUID) async throws -> SkillRun
  }
  ```

**One run per card, and no migration.** `skillRun`'s CHECK is a XOR — `("cardID" IS NULL) <> ("analysisID" IS NULL)` (`ElliotStore/Migrations.swift:425`) — so a run carrying a `cardID` satisfies the schema exactly as written. It also buys the ownership PR2's column decision rests on: `activeRun(cardID:)` (`ElliotStore/BoardStore.swift:746`) answers with this run for its whole life, so `BoardService.proposeMove` (`ElliotEngine/BoardService.swift:85`, which reads that query at `:97`) returns `.blocked(.runAlreadyInFlight(runID:))` while it goes, and `claimCardForRun` refuses a second appraisal. The cost is N runs for N cards; it is bounded by the read-only lane, which is where they belong.

- [ ] **Step 1: Write the failing test**

Create `ElliotKit/Tests/ElliotEngineTests/AppraisalServiceTests.swift`:

```swift
import ElliotModel
import ElliotProcess
import ElliotStore
import Foundation
import TestSupport
import Testing

@testable import ElliotEngine

/// Starting one appraisal, and the ownership everything downstream rests on.
///
/// The card's write window is symmetric: `commitMove` writes every column from a
/// `Card` read three `await`s earlier, and so do the pollers. A one-directional
/// fix leaves the other half. It is closed by **ownership** — the appraisal run
/// holds its card, so the two writers cannot be in flight at once — and both
/// directions are asserted here.
@Suite("Appraisal service")
struct AppraisalServiceTests {

    private final class LaunchRecorder: RunLaunching, @unchecked Sendable {
        private let lock = NSLock()
        private var _launched: [UUID] = []
        var launched: [UUID] { lock.withLock { _launched } }
        func launch(runID: UUID) async { lock.withLock { _launched.append(runID) } }
        func cancel(runID: UUID) async {}
    }

    private struct ClosedGate: RepoGating {
        func blocks(_ repo: Repo) async -> Bool { true }
    }

    private struct Stack {
        var store: BoardStore
        var board: BoardService
        var launcher: LaunchRecorder
        var service: AppraisalService
        var repo: Repo
        var card: Card
    }

    private func makeStack(
        gate: any RepoGating = OpenGate(), enabled: Bool = true
    ) async throws -> Stack {
        // `appraise` resolves an artifact path through `StoreLocation` and
        // creates the directory for it, so the home has to be final first.
        _ = TestHome.root
        let store = try BoardStore.inMemory()
        var repo = Repo(path: "/tmp/r", nameWithOwner: "phmatray/Elliot", displayName: "Elliot")
        repo.isEnabled = enabled
        try await store.saveRepo(repo)

        let now = Date()
        let card = Card(
            repoID: repo.id, title: "Cache the login shell environment",
            story: UserStory(
                role: "user", want: "Elliot to start without waiting on a login shell",
                benefit: "the board is usable immediately"),
            columnEnteredAt: now, createdAt: now, updatedAt: now
        )
        try await store.saveCard(card)

        let launcher = LaunchRecorder()
        return Stack(
            store: store,
            board: BoardService(store: store, launcher: launcher),
            launcher: launcher,
            service: AppraisalService(store: store, launcher: launcher, gate: gate),
            repo: repo, card: card
        )
    }

    @Test("An appraisal is one run, carrying the card and no analysis")
    func oneRunPerCard() async throws {
        let stack = try await makeStack()
        let run = try await stack.service.appraise(cardID: stack.card.id)

        #expect(run.kind == .appraiseCards)
        // The XOR the schema checks, satisfied as written: a card, no analysis.
        #expect(run.cardID == stack.card.id)
        #expect(run.analysisID == nil)
        #expect(run.analysisAngle == nil)
        #expect(run.cwd == stack.repo.path)
        #expect(run.state == .queued)
        #expect(stack.launcher.launched == [run.id])

        // It really is in the store, so the CHECK constraint really was met.
        #expect(try await stack.store.run(id: run.id)?.kind == .appraiseCards)
    }

    @Test("The prompt announces the run's own artifact path")
    func promptAnnouncesTheArtifact() async throws {
        let stack = try await makeStack()
        let run = try await stack.service.appraise(cardID: stack.card.id)
        let announced = AnalysisPromptBuilder.outputPath(in: run.prompt)
        #expect(announced == StoreLocation.appraisalArtifactURL(runID: run.id).path)
        // And the directory exists, so `--add-dir` points somewhere real.
        #expect(FileManager.default.fileExists(
            atPath: StoreLocation.appraisalRunDirectory(runID: run.id).path))
        // The card's own words reached it.
        #expect(run.prompt.contains("Cache the login shell environment"))
    }

    @Test("A repository Preflight is failing refuses the appraisal, and launches nothing")
    func gateRefuses() async throws {
        let stack = try await makeStack(gate: ClosedGate())
        await #expect(throws: AppraisalError.repoRefused(.preflightBlocked)) {
            try await stack.service.appraise(cardID: stack.card.id)
        }
        #expect(stack.launcher.launched.isEmpty)
        #expect(try await stack.store.runs(cardID: stack.card.id).isEmpty)
    }

    @Test("A disabled repository refuses the appraisal by the same rule")
    func disabledRefuses() async throws {
        let stack = try await makeStack(enabled: false)
        await #expect(throws: AppraisalError.repoRefused(.repoDisabled)) {
            try await stack.service.appraise(cardID: stack.card.id)
        }
    }

    @Test("An unknown card is named, not silently ignored")
    func unknownCard() async throws {
        let stack = try await makeStack()
        let missing = UUID()
        await #expect(throws: AppraisalError.cardNotFound(missing)) {
            try await stack.service.appraise(cardID: missing)
        }
    }

    @Test("A second appraisal of the same card cannot start")
    func deduplication() async throws {
        let stack = try await makeStack()
        let first = try await stack.service.appraise(cardID: stack.card.id)
        await #expect(throws: AppraisalError.cardAlreadyHeld(stack.card.id)) {
            try await stack.service.appraise(cardID: stack.card.id)
        }
        #expect(stack.launcher.launched == [first.id])
        #expect(try await stack.store.runs(cardID: stack.card.id).count == 1)
    }

    @Test("A card already held by a skill cannot be appraised")
    func aHeldCardIsRefused() async throws {
        let stack = try await makeStack()
        var writer = SkillRun.card(
            cardID: stack.card.id, repoID: stack.repo.id, kind: .implementIssue,
            prompt: "x", cwd: stack.repo.path, logPath: "/tmp/a", stderrPath: "/tmp/b",
            createdAt: Date()
        )
        writer.state = .running
        try await stack.store.saveRun(writer)

        await #expect(throws: AppraisalError.cardAlreadyHeld(stack.card.id)) {
            try await stack.service.appraise(cardID: stack.card.id)
        }
    }

    /// The write window, direction one: **a move cannot land while an appraisal
    /// holds the card**, so no `commitMove` can carry a stale appraisal back.
    @Test("A move is refused while an appraisal holds the card")
    func anAppraisalHoldsTheCardAgainstAMove() async throws {
        let stack = try await makeStack()
        let run = try await stack.service.appraise(cardID: stack.card.id)
        #expect(run.state == .queued)   // queued is active: it holds the card

        let result = try await stack.board.move(
            cardID: stack.card.id, to: .todo, origin: .userDrag)
        // The case carries its run — `case runAlreadyInFlight(runID: UUID)`
        // (`ElliotModel/RuleEngine.swift:23`) — so the assertion names *which*
        // run holds the card, and would fail if some other one did.
        #expect(result == .blocked(.runAlreadyInFlight(runID: run.id)))
        #expect(try await stack.store.card(id: stack.card.id)?.column == .backlog)
    }

    /// The write window, direction two: **an appraisal cannot start while a move
    /// is in flight**, so no appraisal write can carry a stale column back.
    @Test("An appraisal is refused while a move's run holds the card")
    func aMoveHoldsTheCardAgainstAnAppraisal() async throws {
        let stack = try await makeStack()
        // A real move through the funnel, which commits the card and its run in
        // one transaction — the exact state the appraisal must not step into.
        let result = try await stack.board.move(
            cardID: stack.card.id, to: .todo, origin: .userDrag)
        guard case .moved(let runID?) = result else {
            Issue.record("expected the move to start a run, got \(result)")
            return
        }
        #expect(try await stack.store.run(id: runID)?.kind == .createIssue)

        await #expect(throws: AppraisalError.cardAlreadyHeld(stack.card.id)) {
            try await stack.service.appraise(cardID: stack.card.id)
        }
        // And the card kept the move: nothing wrote over it.
        #expect(try await stack.store.card(id: stack.card.id)?.column == .todo)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd ElliotKit && swift test --filter AppraisalServiceTests`

Expected: FAIL to compile, with
`error: cannot find 'AppraisalService' in scope`.

- [ ] **Step 3: Write minimal implementation**

Create `ElliotKit/Sources/ElliotEngine/AppraisalService.swift`:

```swift
import ElliotModel
import ElliotProcess
import ElliotStore
import Foundation

public enum AppraisalError: Error, LocalizedError, Equatable {
    case cardNotFound(UUID)
    case repoNotFound(UUID)
    /// Preflight, or the repository's own switch, refuses this start.
    case repoRefused(UnattendedStartRefusal)
    /// Something already holds this card — another skill, or an earlier
    /// appraisal. Refused rather than queued: two appraisals of one card would
    /// each write the other's fields over.
    case cardAlreadyHeld(UUID)

    public var errorDescription: String? {
        switch self {
        case .cardNotFound(let id): "No card with id \(id)."
        case .repoNotFound(let id): "No repository with id \(id)."
        case .repoRefused(let refusal): refusal.sentence
        case .cardAlreadyHeld:
            "A run is already working on this card; its appraisal has to wait for it."
        }
    }
}

/// Starts the read-only run that fills a card in.
///
/// It fills in; it never ranks. What the two signals are *worth* is a pure
/// function over them, one PR away, and a service that both produced and
/// weighed them would be a service whose ranking could not be re-derived.
///
/// ⛔ **This is the only unattended agent in Elliot that starts outside the
/// funnel.** An appraisal run passes through no move: no `evaluateMove`, no
/// `MoveOrigin.allowsSideEffects`, no repository preflight on the transition. So
/// the guard is built here, explicitly, out of the same
/// `UnattendedStartRefusal` the analysis path and the board's own tooltip read.
///
/// Shaped on `AnalysisService` deliberately, down to the order of its steps:
/// resolve, refuse, create the artifact directory, build the prompt, claim,
/// launch. Two services that start unattended agents should not do it two
/// different ways.
public actor AppraisalService {
    private let store: BoardStore
    private let launcher: any RunLaunching
    private let gate: any RepoGating

    public init(store: BoardStore, launcher: any RunLaunching, gate: any RepoGating) {
        self.store = store
        self.launcher = launcher
        self.gate = gate
    }

    /// Starts one appraisal for one card.
    ///
    /// **One run per card**, which is the design and not a convenience.
    /// `skillRun`'s CHECK is a XOR — `("cardID" IS NULL) <> ("analysisID" IS
    /// NULL)` — so a run carrying a card satisfies the schema exactly as written
    /// and needs no migration. It also buys the ownership the card's new columns
    /// rest on: `activeRun(cardID:)` answers with this run for its whole life,
    /// so `BoardService.proposeMove` refuses a move while it goes, and
    /// `claimCardForRun` refuses a second appraisal. The claim **is** the
    /// deduplication; there is no separate in-flight set to drift from it.
    ///
    /// The cost is N runs for N cards rather than one. It is bounded by the
    /// read-only lane, which is where they belong anyway.
    @discardableResult
    public func appraise(cardID: UUID) async throws -> SkillRun {
        guard let card = try await store.card(id: cardID) else {
            throw AppraisalError.cardNotFound(cardID)
        }
        guard let repo = try await store.repo(id: card.repoID) else {
            throw AppraisalError.repoNotFound(card.repoID)
        }

        // The guard no transition provides. Asked live, before anything is
        // written: a run committed and then refused would leave a queued row for
        // the launch sweep to revive.
        if let refusal = UnattendedStartRefusal.refusal(
            repo: repo, preflightBlocks: await gate.blocks(repo)
        ) {
            throw AppraisalError.repoRefused(refusal)
        }

        let runID = UUID()
        let artifact = StoreLocation.appraisalArtifactURL(runID: runID)
        // Created up front so the agent has somewhere to write, and so
        // `--add-dir` points at a directory that exists — the same reason
        // `AnalysisService.start` creates its own.
        try? FileManager.default.createDirectory(
            at: artifact.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )

        let run = SkillRun.card(
            id: runID,
            cardID: card.id,
            repoID: repo.id,
            kind: .appraiseCards,
            prompt: AppraisalPromptBuilder.prompt(
                cardTitle: card.displayTitle,
                // `Card.ideaText` and not the story: the fallback from story to
                // note to title already exists there, and a second copy of it
                // would be a second answer to "what does this card say".
                cardText: card.ideaText,
                repoNameWithOwner: repo.nameWithOwner,
                outputPath: artifact.path
            ),
            cwd: repo.path,
            logPath: StoreLocation.runLogURL(runID: runID).path,
            stderrPath: StoreLocation.runStderrURL(runID: runID).path,
            createdAt: Date()
        )

        // The compare-and-set, not a check followed by an insert. This actor is
        // reentrant, so a check that spanned the `await`s above could be passed
        // by two calls before either wrote.
        guard try await store.claimCardForRun(run) else {
            throw AppraisalError.cardAlreadyHeld(cardID)
        }
        await launcher.launch(runID: run.id)
        return run
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd ElliotKit && swift test --filter AppraisalServiceTests`

Expected: PASS — `Test run with 9 tests passed`.

- [ ] **Step 5: Commit**

```bash
git rev-parse --abbrev-ref HEAD
git add ElliotKit/Sources/ElliotEngine/AppraisalService.swift \
        ElliotKit/Tests/ElliotEngineTests/AppraisalServiceTests.swift
git commit -m "feat(engine): start one appraisal per card, behind its own guard"
```

---

### Task 15: The whole path, against `fake-claude.sh`

**Files:**
- Create: `Fixtures/appraisal/e2e-small.json`
- Create: `Fixtures/appraisal/not-an-object.json`
- Test: `ElliotKit/Tests/ElliotEngineTests/AppraisalEndToEndTests.swift`

**Interfaces:**
- Consumes: everything above — `AppraisalService.appraise(cardID:)` (Task 14), `RunScheduler` with its read-only lane and third completion (Tasks 2, 10), `AppraisalHarvester` (Task 9), `StoreLocation.appraisalArtifactURL(runID:)` (Task 4).
- Produces: nothing new. This is the measurement that the parts agree — the prompt's announced path, the fake tool's `sed`, and the harvester's read are one path, and the argv the scheduler really spawns carries the tighter mode.

**Why it reuses `FAKE_CLAUDE_STORIES`.** The variable is named for the analysis, but what it does is *copy a file to whatever path the prompt announced after `ELLIOT_OUTPUT=`* — which is exactly the appraisal's contract too, because Task 5 deliberately reuses the same marker. A second variable would be a second `sed` in the same script for the same job.

- [ ] **Step 1: Write the failing test**

Create `Fixtures/appraisal/e2e-small.json`:

```json
{
  "effort": "small",
  "evidence": [
    "Sources/ElliotProcess/ClaudeRunner.swift:159",
    "Sources/ElliotProcess/Nowhere.swift"
  ]
}
```

Create `Fixtures/appraisal/not-an-object.json`:

```json
["small", "Sources/ElliotProcess/ClaudeRunner.swift"]
```

Create `ElliotKit/Tests/ElliotEngineTests/AppraisalEndToEndTests.swift`:

```swift
import ElliotModel
import ElliotProcess
import ElliotStore
import Foundation
import TestSupport
import Testing

@testable import ElliotEngine

/// Duplicated rather than shared with the other end-to-end suites: a private
/// enum in one test file is not visible from another, and one small repetition
/// beats a shared helper target for three constants.
private enum TestPaths {
    static let repoRoot: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    static let fakeClaude = repoRoot.appendingPathComponent("Scripts/fake-claude.sh").path

    static func streamFixture(_ name: String) -> String {
        repoRoot.appendingPathComponent("Fixtures/stream-json/\(name)").path
    }

    static func appraisalFixture(_ name: String) -> String {
        repoRoot.appendingPathComponent("Fixtures/appraisal/\(name)").path
    }
}

extension EndToEndSuites {

/// The appraisal from end to end: a card, a real spawn of the fake `claude`, the
/// artifact it drops at the path the prompt announced, and the three fields that
/// land on the card.
///
/// `.serialized` under `EndToEndSuites` for the reason the others are: they share
/// a process-global `ELLIOT_HOME` and must not run at the same time.
@Suite("Appraisal end to end", .serialized)
struct AppraisalEndToEndTests {

    private struct Stack {
        var store: BoardStore
        var board: BoardService
        var scheduler: RunScheduler
        var service: AppraisalService
        var repo: Repo
        var card: Card
        var home: URL

        /// Removes this test's own directory only. The shared `ELLIOT_HOME`
        /// above it stays: another suite may still be writing into it.
        func cleanUp() { try? FileManager.default.removeItem(at: home) }

        /// Bounded, and it waits on a **fact** — the run reaching a terminal
        /// state — rather than on a duration.
        func awaitRun(id: UUID, timeout: Duration = .seconds(30)) async throws -> SkillRun {
            let deadline = ContinuousClock.now.advanced(by: timeout)
            while ContinuousClock.now < deadline {
                if let run = try await store.run(id: id), run.state.isTerminal { return run }
                try await Task.sleep(for: .milliseconds(50))
            }
            throw StackError.timedOut
        }

        enum StackError: Error { case timedOut }
    }

    private func makeStack(
        artifact: String? = TestPaths.appraisalFixture("e2e-small.json"),
        extraEnv: [String: String] = [:]
    ) async throws -> Stack {
        let home = TestHome.scratch("appraisal-e2e")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try StoreLocation.ensureDirectories()

        // A throwaway checkout with one real file, so evidence resolution has
        // something true and something false to tell apart.
        let repoRoot = home.appendingPathComponent("repo", isDirectory: true)
        let sources = repoRoot.appendingPathComponent("Sources/ElliotProcess", isDirectory: true)
        try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
        try "// real".write(
            to: sources.appendingPathComponent("ClaudeRunner.swift"),
            atomically: true, encoding: .utf8
        )

        let store = try BoardStore.open(at: home.appendingPathComponent("elliot.sqlite"))
        var environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
        environment["FAKE_CLAUDE_FIXTURE"] = TestPaths.streamFixture("analyze-success.ndjson")
        if let artifact {
            // Named for the analysis, but what it does is copy a file to the
            // path the prompt announced after `ELLIOT_OUTPUT=` — which is the
            // appraisal's contract too, because the marker is shared.
            environment["FAKE_CLAUDE_STORIES"] = artifact
        }
        environment.merge(extraEnv) { _, new in new }

        let config = ToolConfig(
            claudePath: TestPaths.fakeClaude,
            ghPath: "/usr/bin/false",
            gitPath: "/usr/bin/false",
            environment: environment
        )
        let scheduler = RunScheduler(
            store: store, toolConfig: config, verifier: Verifier(gh: .init(config: config))
        )
        let board = BoardService(store: store, launcher: scheduler)
        await scheduler.setSystemMover(board)

        let repo = Repo(
            path: repoRoot.path, nameWithOwner: "phmatray/Elliot", displayName: "Elliot"
        )
        try await store.saveRepo(repo)

        let now = Date()
        let card = Card(
            repoID: repo.id, title: "The idle watchdog outlives a cancelled run",
            story: UserStory(
                role: "developer", want: "the idle task cancelled on every exit path",
                benefit: "a cancelled run stops waking the machine every 30 seconds"),
            columnEnteredAt: now, createdAt: now, updatedAt: now
        )
        try await store.saveCard(card)

        return Stack(
            store: store, board: board, scheduler: scheduler,
            service: AppraisalService(store: store, launcher: scheduler, gate: OpenGate()),
            repo: repo, card: card, home: home
        )
    }

    @Test("An appraisal fills the card in, from the artifact it was told to write")
    func theWholePath() async throws {
        let stack = try await makeStack()
        defer { stack.cleanUp() }

        let started = try await stack.service.appraise(cardID: stack.card.id)
        let run = try await withTimeout(.seconds(40)) {
            try await stack.awaitRun(id: started.id)
        }

        #expect(run.state == .succeeded)
        #expect(run.exitCode == 0)
        #expect(run.kind == .appraiseCards)

        // Harvested from the artifact, not from prose. The whole point.
        let report = try #require(run.analysisReport)
        #expect(report.harvestSource == .artifact)
        #expect(report.kept == 1)
        #expect(report.dropped.isEmpty)

        // The artifact really is where the prompt said it would be.
        #expect(FileManager.default.fileExists(
            atPath: StoreLocation.appraisalArtifactURL(runID: run.id).path))

        let card = try #require(try await stack.store.card(id: stack.card.id))
        #expect(card.effort == .small)
        #expect(card.appraisedAt != nil)
        let evidence = try #require(card.evidence)
        #expect(evidence.count == 2)
        #expect(evidence[0].path == "Sources/ElliotProcess/ClaudeRunner.swift")
        #expect(evidence[0].line == 159)
        #expect(evidence[0].exists)
        // The cited file that is not there is marked, not dropped: it is the
        // fastest signal that a citation was invented.
        #expect(evidence[1].exists == false)

        // And the card did not move. An appraisal is not a transition.
        #expect(card.column == .backlog)
        #expect(card.issueNumber == nil)
        #expect(card.lastError == nil)
    }

    @Test("The card is free again once the run has finished")
    func theCardIsReleased() async throws {
        let stack = try await makeStack()
        defer { stack.cleanUp() }

        let started = try await stack.service.appraise(cardID: stack.card.id)
        _ = try await withTimeout(.seconds(40)) { try await stack.awaitRun(id: started.id) }

        #expect(try await stack.store.activeRun(cardID: stack.card.id) == nil)
        // The ownership is a hold, not a lock: once the run is terminal the card
        // moves like any other, through the same funnel.
        let result = try await stack.board.move(
            cardID: stack.card.id, to: .todo, origin: .userDrag)
        guard case .moved(let runID?) = result else {
            Issue.record("expected a run, got \(result)")
            return
        }
        #expect(try await stack.store.run(id: runID)?.kind == .createIssue)
        // And the appraisal survived the move, which writes the whole card row.
        let card = try #require(try await stack.store.card(id: stack.card.id))
        #expect(card.effort == .small)
        #expect(card.appraisedAt != nil)
    }

    @Test("The spawn really carries the tighter mode and the artifact directory")
    func theArgvIsTightened() async throws {
        let argvOut = TestHome.scratch("appraisal-argv").path
        let stack = try await makeStack(extraEnv: ["FAKE_CLAUDE_ARGV_OUT": argvOut])
        defer { stack.cleanUp() }

        let started = try await stack.service.appraise(cardID: stack.card.id)
        _ = try await withTimeout(.seconds(40)) { try await stack.awaitRun(id: started.id) }

        let argv = try String(contentsOfFile: argvOut, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)

        // Asserted against what the process was actually given, not against
        // `ClaudeInvocation` — the unit test already pins that, and this is the
        // only thing that proves the scheduler passes it through.
        let modeIndex = try #require(argv.firstIndex(of: "--permission-mode"))
        #expect(argv[modeIndex + 1] == "acceptEdits")
        #expect(!argv.contains("bypassPermissions"))

        let directories = argv.enumerated()
            .filter { $0.element == "--add-dir" }
            .map { argv[$0.offset + 1] }
        #expect(directories == [
            stack.repo.path,
            StoreLocation.appraisalRunDirectory(runID: started.id).path,
        ])
    }

    @Test("A run that writes no artifact leaves the card unappraised, and says so")
    func noArtifactLeavesTheCardAlone() async throws {
        // No `FAKE_CLAUDE_STORIES`, so the fake tool replays its stream and
        // drops nothing — the shape of a run that talked and wrote nothing.
        let stack = try await makeStack(artifact: nil)
        defer { stack.cleanUp() }

        let started = try await stack.service.appraise(cardID: stack.card.id)
        let run = try await withTimeout(.seconds(40)) {
            try await stack.awaitRun(id: started.id)
        }

        #expect(run.state == .succeeded)
        let report = try #require(run.analysisReport)
        #expect(report.harvestSource == .none)
        #expect(report.kept == 0)
        #expect(report.dropped.contains { $0.contains("No artifact was written") })

        let card = try #require(try await stack.store.card(id: stack.card.id))
        #expect(card.appraisedAt == nil)
        #expect(card.effort == nil)
        #expect(card.evidence == nil)
    }

    @Test("A malformed artifact leaves the card unappraised, and says what was wrong")
    func malformedArtifactLeavesTheCardAlone() async throws {
        let stack = try await makeStack(
            artifact: TestPaths.appraisalFixture("not-an-object.json"))
        defer { stack.cleanUp() }

        let started = try await stack.service.appraise(cardID: stack.card.id)
        let run = try await withTimeout(.seconds(40)) {
            try await stack.awaitRun(id: started.id)
        }

        let report = try #require(run.analysisReport)
        #expect(report.harvestSource == .none)
        #expect(report.dropped.contains { $0.contains("not a JSON object") })
        #expect(try await stack.store.card(id: stack.card.id)?.appraisedAt == nil)
    }

    @Test("An appraisal starts against a full writer lane, in a real drain")
    func theLaneIsRealAndNotOnlyAdmission() async throws {
        // `SchedulerReadOnlyLaneTests` asks `refusal(for:)` directly. This asks
        // `pump()` — the caller — with the writer cap at one and a writer really
        // in flight, because a lane that is right in `refusal` and wrong in the
        // drain is a lane that does not exist.
        //
        // The writer is seeded rather than dragged. One `ToolConfig` serves the
        // whole stack, so `FAKE_CLAUDE_MODE=hang` would hang the appraisal too
        // and the test would prove the opposite of its name;
        // `testOnlyMarkInFlight` puts a writer in the set `refusal` reads
        // without spawning anything, which is exactly the state under test.
        let stack = try await makeStack()
        defer { stack.cleanUp() }
        await stack.scheduler.setLimits(
            SchedulerLimits(maxConcurrent: 1, maxConcurrentAnalyses: 2))

        let now = Date()
        let busy = Card(
            repoID: stack.repo.id, title: "Something else",
            story: UserStory(role: "dev", want: "w", benefit: "b"),
            columnEnteredAt: now, createdAt: now, updatedAt: now
        )
        try await stack.store.saveCard(busy)

        var writer = SkillRun.card(
            cardID: busy.id, repoID: stack.repo.id, kind: .implementIssue, prompt: "x",
            cwd: stack.repo.path, logPath: "/tmp/w.ndjson", stderrPath: "/tmp/w.log",
            createdAt: now
        )
        writer.state = .running
        await stack.scheduler.testOnlyMarkInFlight(writer)

        // The writer lane is full — proved, not assumed. Without this the rest
        // of the test would pass against an empty scheduler and measure nothing.
        var second = SkillRun.card(
            cardID: UUID(), repoID: stack.repo.id, kind: .implementIssue, prompt: "x",
            cwd: stack.repo.path, logPath: "/tmp/s.ndjson", stderrPath: "/tmp/s.log",
            createdAt: now
        )
        second.state = .queued
        #expect(
            await stack.scheduler.refusal(for: second, overBudget: false)
                == .writerCapReached(inFlight: 1, cap: 1)
        )

        // And the appraisal goes through the real drain anyway.
        let started = try await stack.service.appraise(cardID: stack.card.id)
        let run = try await withTimeout(.seconds(40)) {
            try await stack.awaitRun(id: started.id)
        }
        #expect(run.state == .succeeded)
        #expect(try await stack.store.card(id: stack.card.id)?.effort == .small)
    }
}

}  // extension EndToEndSuites
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd ElliotKit && swift test --filter AppraisalEndToEndTests`

Expected: FAIL — before the fixtures exist, `theWholePath` reports
`Expectation failed: (report.harvestSource → AnalysisRunReport.HarvestSource.none) == AnalysisRunReport.HarvestSource.artifact`.
If the whole suite instead fails to compile with `error: cannot find 'EndToEndSuites' in scope`, the extension is being read before `AnalysisEndToEndTests.swift` declares it — that file declares `@Suite("End to end", .serialized) struct EndToEndSuites {}` at line 33 and it must stay.

- [ ] **Step 3: Write minimal implementation**

Nothing to write: every part exists after Tasks 1–14. Create the two fixture files exactly as in Step 1, then re-run.

If `theArgvIsTightened` fails with `bypassPermissions`, `RunScheduler.start` is still building its own `ClaudeInvocation` literal rather than calling `Self.invocation(for:repo:perRunUSD:)` — finish Task 11's last edit.

If `theWholePath` fails with `report.harvestSource == .none` while the fixture is in place, print the announced path and the file the fake tool wrote:

```bash
cd /Users/phmatray/Repositories/phmatray/private/Elliot/.claude/worktrees/precious-beaming-wand
grep -c 'ELLIOT_OUTPUT=' Fixtures/appraisal/e2e-small.json   # must be 0 — the fixture is data
```

and check that `AppraisalPromptBuilder` emits the marker at the **start of a line**, which is what `Scripts/fake-claude.sh`'s `sed -n 's/^.*ELLIOT_OUTPUT=\(.*\)$/\1/p'` needs to capture to end of line.

- [ ] **Step 4: Run test to verify it passes**

Run: `cd ElliotKit && swift test --filter AppraisalEndToEndTests`

Expected: PASS — `Test run with 6 tests passed`.

Then the whole suite, sampled, because this task spawns real processes and one green run does not clear it:

```bash
cd ElliotKit && rm -rf .build && swift build
cd ElliotKit && for i in 1 2 3 4 5; do swift test 2>&1 | tail -3; done
```

Expected: five runs, each reporting the same total and `0 failures`.

- [ ] **Step 5: Commit**

```bash
git rev-parse --abbrev-ref HEAD
git add Fixtures/appraisal/e2e-small.json \
        Fixtures/appraisal/not-an-object.json \
        ElliotKit/Tests/ElliotEngineTests/AppraisalEndToEndTests.swift
git commit -m "test(engine): the appraisal path end to end, against the fake claude"
```

---

## After the last task

- [ ] **Re-read the branch, then push.**

```bash
git rev-parse --abbrev-ref HEAD
git push -u origin "$(git rev-parse --abbrev-ref HEAD)"
git rev-parse --abbrev-ref HEAD
git rev-parse HEAD "origin/$(git rev-parse --abbrev-ref HEAD)"
```

The two `rev-parse HEAD` values must match. Several worktrees share this repository's `.git`, and a `git push -u` that succeeds does not prove the right content left.

- [ ] **Say in the pull request body what this PR does not have.** It ships a `SkillKind` nothing on screen and nothing on the wire can start; `AppraisalService` is reached from tests only until PR4 or PR5. The spec's delivery order (§4) names that cost and accepts it. Do not let a reviewer discover it.

- [ ] **State the order taken with respect to PR3.** The spec requires PR3 and PR6 to be totally ordered and the chosen order written in the second one's body (§3). If PR3 has already landed, say so; if it has not, say that this PR takes no `skillRun` column and therefore leaves PR3's `resumedFrom` migration number free.
