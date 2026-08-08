# Auto-dev PR4 — The loop Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship `AutoDevService` — an `ElliotEngine` actor that advances a fixed set of Backlog cards to merged or blocked without a human, merging only on a verified green that is still current at the moment the run is admitted.

**Architecture:** The loop decides nothing of its own. It re-evaluates its unsettled cards on every event by calling `BoardService.proposeMove(…, requiresVerifiedGreen: true)`, turns the resulting `MoveOutcome` into a `Disposition` through the pure `AutoDevPolicy`, and commits. The green guard exists twice — at the decision (PR1) and again at admission, where `RunScheduler.refusal(for:)` refuses a merge whose reading has aged past `PRStatus.maximumAge`. Session and per-card state are persisted in two v9 tables written in one transaction.

**Tech Stack:** Swift 6.3.1, `swiftLanguageModes: [.v6]`, macOS 15, GRDB, swift-testing, `Scripts/fake-claude.sh` + `Scripts/fake-gh.sh`.

## Global Constraints

- Swift tools-version **6.3.1** — the patch is load-bearing, never `6.3`; `swiftLanguageModes: [.v6]`; deployment target macOS 15; strict concurrency, so every type crossing an isolation boundary is `Sendable`.
- Build: `cd ElliotKit && swift build` · Tests: `cd ElliotKit && swift test` · One suite: `cd ElliotKit && swift test --filter <TypeName>`.
- `--filter` matches the **type** name, not the `@Suite` display name. A filter matching nothing prints `warning: No matching test cases were run` and **exits 0** — never conclude success from exit 0 alone; read the line that says how many tests ran.
- Test framework is **swift-testing** (`@Suite`, `@Test`, `#expect`, `#require`), never XCTest.
- ⛔ Never run `swift format` over the tree. This code is formatted by hand: 4 spaces, 110 columns. Format the lines you write, by hand, to match their neighbours.
- Every async wait in a test is **bounded**, through `withTimeout` from the `TestSupport` target. No assertion measures an absolute duration. No test sleeps a fixed interval waiting for a child — it waits on a condition inside a deadline loop.
- ⛔ Nothing in production code waits on `Process.waitUntilExit()`.
- Migrations are additive and shipped ones are frozen. The last registered is `v8_prStatus` (`ElliotKit/Sources/ElliotStore/Migrations.swift:138`). A renumbering ships its `RenamedMigration` **in the same diff** (`Migrations.swift:195-202`).
- Commits: Conventional Commits with the layer as scope — `feat(model|store|process|engine|ipc|mcp|app): subject`.
- Branch: `feat/<issue>-<slug>` or `fix/<issue>-<slug>`. The number comes first and is followed by `-`.
- ⚠️ Several agent worktrees share this repository's `.git`. Re-read `git rev-parse --abbrev-ref HEAD` **immediately before every commit** and **immediately after every push**.
- A stale `.build` produces impossible failures (wrong enum values, link errors, SIGBUS). After any checkout that crosses commits: `rm -rf ElliotKit/.build` before believing a failure.
- One green run does not clear a suite. After a clean build, sample five times — it costs about eight seconds.

---

## Prerequisites — read this before Task 1

**Nothing from PR1, PR2 or PR3 is in the tree today.** Verified on `main` at `60c035e`: `grep -rn "notVerifiedGreen\|requiresVerifiedGreen\|autoDev\|isMergeableUnattended\|AutoDev\|resumedFrom\|systemOwnedTransition" ElliotKit/Sources ElliotKit/Tests` returns nothing. PR4 is the **last** engine PR by design; it consumes what these ship and cannot supply them.

PR4 requires, and Task 1 proves by compiling:

| From | Symbol | Exact shape PR4 calls |
|---|---|---|
| PR 0·2 | `MoveBlock.repoBlocked` | a case, `code == "repo_blocked"` |
| PR1 | `MoveOrigin.autoDev(sessionID: UUID)` | `allowsSideEffects == true` |
| PR1 | `MoveContext.requiresVerifiedGreen: Bool` | no default value |
| PR1 | `MoveContext.prVerdict: ResolvedPRStatus?` | no default value |
| PR1 | `MoveBlock.notVerifiedGreen(sign: PRSign?)` | `code == "not_verified_green"` |
| PR1 | `MoveBlock.systemOwnedTransition` | `code == "system_owned_transition"` |
| PR1 | `ResolvedPRStatus.isMergeableUnattended: Bool` | at least option B: `!isStale && sign == nil && merge == .clean` |
| PR1 | `BoardService.proposeMove(cardID:to:origin:followUps:orderIndex:requiresVerifiedGreen:)` | `requiresVerifiedGreen` last, **`= false`** — corrected against PR1's plan, which ships the default deliberately so every headless construction keeps compiling. The "no default" rule PR1 applies is to `MoveContext`'s two fields, not to this parameter, and PR4 needs only that the label exists in that position |
| PR1 | `BoardService.move(cardID:to:origin:followUps:orderIndex:requiresVerifiedGreen:)` | the same parameter, in the same position, also `= false`. `move` is `proposeMove` + `commitMove` (`BoardService.swift:153-165`); PR1 has it **take** the parameter and forward it, which is what Task 6's third test relies on |

PR2 (`CardValue`, `effort`, `evidence`) and PR3 (`resumeFrom`, `ResumeVerdict`) are **not** required: the engaged card ids are supplied by the caller, and PR3's fork-refusal spin is cut by the same patience window that bounds every other wait (Task 4).

> ⚠️ **Cross-plan: "the engaged card ids are supplied by the caller" is true of this plan and false
> of the set.** The only caller is PR5's `AutoDevDriving.start(repoID:cardLimit:)`, which passes a
> **count**, not ids, and whose own documentation says "engages at most `cardLimit` Backlog cards"
> without saying which. PR2 ships `CardRanking.rank(_:) -> (ranked:refused:)` and `CardValue`
> precisely to answer that, with the rule that an unappraised card is **refused rather than ranked
> low** — and **no plan in the set calls it.** So the design's "optional automatic selection of the
> highest-value cards" is delivered by nobody. If the arbitration puts the selection in this actor's
> `AutoDevDriving` conformance, PR2 becomes a hard prerequisite of PR4 and this paragraph is wrong;
> if it puts it in `AppModel`, PR2 becomes a prerequisite of PR5 instead. Either way it has an owner
> and today it does not.

PR 0·3 (#179, the concurrent `pump()` race) is strongly recommended: auto-dev multiplies drains by construction — every `commitMove` triggers one, every `finish` triggers one. It is not a compile-time dependency.

**The migration number is a resource shared by four PRs.** PR2, PR3 and PR4 all want v9. This plan writes `v9_autoDev`. If `v9_` is taken when you rebase, Task 5 Step 5 carries the exact renumbering + `RenamedMigration` code.

> ⚠️ **Cross-plan, and under the arbitrated order the renumbering is not a contingency — it is the
> expected outcome, twice over.** The order is PR1 → PR2 → PR3/PR6 → PR5 → **PR4 last**, and PR2
> registers `v9_cardAppraisal` while PR3 registers `v10_runResumedFrom`. So the number this plan
> should expect to write is **`v11_autoDev`**, not `v10_autoDev` as Task 5 Step 5 says. Measure and
> take the next free integer:
>
> ```bash
> grep -n 'registerMigration("v' ElliotKit/Sources/ElliotStore/Migrations.swift | tail -3
> ```
>
> Whatever number you land on, the `RenamedMigration(legacy: "v9_autoDev", current: "<yours>")`
> pair ships **in the same commit** — that is the invariant, and the integer is not.

---

⚠ **Every line number in this plan is read against `main` as it stands today, and this plan
lands last** — after PR1, PR2, PR3, PR6 and PR5 have each edited `RunScheduler.swift`,
`RuleEngine.swift`, `Migrations.swift` and `AppModel.swift`. By the time you execute a step
here, **every number below has moved**, several of them more than once. Each step also names
the construct it means — a method, a stored property, a switch arm. **Locate by the name;
treat the number as a hint at where to start looking.**

## File Structure

### Created

| File | Responsibility |
|---|---|
| `ElliotKit/Sources/ElliotModel/NonBuildChecks.swift` | The data list of check names whose green judges no code, and `CIState.hasBuildVerdict`. ⚠️ **PR1 creates this file; under the arbitrated order it already exists here.** See Task 2 Step 0 — this row survives only for the case where PR4 is executed without PR1, which is itself a stop condition. |
| `ElliotKit/Sources/ElliotModel/AutoDev.swift` | `AutoDevSession`, `AutoDevSession.State`, `AutoDevCardState`, `Disposition`, `DispositionCode`, `PRReading` — pure values, no policy. ⚠️ **PR5 creates this same file first, with an overlapping and partly differently-named set of types.** Read the reconciliation block at the head of Task 3 before writing a line of it. |
| `ElliotKit/Sources/ElliotModel/AutoDevPolicy.swift` | `AutoDevPolicy.disposition(…)` and `AutoDevPolicy.held(…)`. Pure, clock injected. |
| `ElliotKit/Sources/ElliotEngine/RunQueueReading.swift` | The two-method protocol that lets auto-dev read *why* the scheduler is holding a run. |
| `ElliotKit/Sources/ElliotEngine/RoundTriggering.swift` | The one-method protocol `RunScheduler` and `PRWatcher` call to say "something moved". |
| `ElliotKit/Sources/ElliotEngine/AutoDevService.swift` | The actor: start, resume, one round, termination, cancellation. |
| `ElliotKit/Tests/ElliotModelTests/AutoDevPreconditionTests.swift` | Names every PR1/PR 0·2 symbol PR4 consumes, so an absent prerequisite is a named compile error. |
| `ElliotKit/Tests/ElliotModelTests/NonBuildChecksTests.swift` | Option A's own suite. |
| `ElliotKit/Tests/ElliotModelTests/AutoDevPolicyTests.swift` | Every `MoveBlock` × reading × attempts × injected clock. |
| `ElliotKit/Tests/ElliotStoreTests/AutoDevStoreTests.swift` | The v9 tables, the one transaction, the `skillRun` column. |
| `ElliotKit/Tests/ElliotEngineTests/MergeAdmissionTests.swift` | **The admission test** — the most important of the set. |
| `ElliotKit/Tests/ElliotEngineTests/AutoDevServiceTests.swift` | Start refusals, one round, serialised merges, termination, resume order. |
| `ElliotKit/Tests/ElliotEngineTests/AutoDevEndToEndTests.swift` | A whole session against `fake-claude.sh` and `fake-gh.sh`. |

### Modified

| File | Change |
|---|---|
| `ElliotKit/Sources/ElliotModel/PRStatus.swift:88` | `case passing(Int)` → `case passing([String])`; `:324` passes the labels. |
| `ElliotKit/Sources/ElliotModel/QueuedRun.swift:13-64` | `QueueRefusal.mergeVerdictNotEstablished`, its `code` and its `sentence`. |
| `ElliotKit/Sources/ElliotModel/SkillRun.swift:47-207` | `requiresVerifiedGreen: Bool?` + `demandsVerifiedGreen`, threaded through the memberwise init and `SkillRun.card`. |
| `ElliotKit/Sources/ElliotAppKit/PRStatusBlock.swift:111` | reads the label array instead of a count. |
| `ElliotKit/Sources/ElliotStore/Migrations.swift:153` | `v9_autoDev` registered after `v8_prStatus`. |
| `ElliotKit/Sources/ElliotStore/Records.swift` | `AutoDevSession` and `AutoDevCardState` conformance — both halves. |
| `ElliotKit/Sources/ElliotStore/BoardStore.swift` | six auto-dev accessors, one of them a transaction. |
| `ElliotKit/Sources/ElliotEngine/BoardService.swift:5-12,85-116,136-148,167-183` | `MoveProposal` carries `requiresVerifiedGreen` and `prVerdict`; `commitMove`'s `.action` branch passes the flag down; `makeRun` writes it onto the run. |
| `ElliotKit/Sources/ElliotEngine/RunScheduler.swift:32,140,198-241,249-270,274-302,449-452` | `MergeAdmission`, the third refusal branch, the per-drain pre-pass, `RunQueueReading`, the round hook, `testOnlyClearInFlight`. |
| `ElliotKit/Sources/ElliotEngine/PRWatcher.swift:12-30,48-98,144-161` | the round hook, the pure interval function, and statuses refreshed for a card with a pending merge. |
| `ElliotKit/Sources/ElliotIPC/Protocol.swift:179-209` | `ElliotErrorCode.autoDevRefused`. |
| `ElliotKit/Sources/ElliotAppKit/AppModel.swift:432,516-560` | builds the service, registers both hooks, resumes **after** `reconciler.sweep()`. |
| `ElliotKit/Tests/ElliotEngineTests/SchedulerLimitsAdmissionTests.swift:145-217` | **nine** `refusal(for:overBudget:)` call sites gain the new argument — 145, 156, 167, 177, 181, 190, 194, 203, 215, counted with `grep -n "refusal(for"`. |
| `ElliotKit/Tests/ElliotModelTests/PRStatusTests.swift:71,99,118,134,144,248` · `ElliotKit/Tests/ElliotAppKitTests/PRStatusPresentationTests.swift:67` · `ElliotKit/Tests/ElliotIPCTests/PRStatusWireTests.swift:108` | `.passing(n)` → `.passing([names])`. |

---

## Two design points the spec left to this plan

**`RunScheduler.updates` cannot be shared, so auto-dev does not read it.** It is `AsyncStream(bufferingPolicy: .bufferingNewest(1024))` (`RunScheduler.swift:66,85`), and an `AsyncStream` is **not multicast**: two concurrent `for await` loops draw from one buffer, so each element is delivered to exactly one of them. Exactly one consumer exists today — `AppModel.consumeSchedulerUpdates` (`AppModel.swift:815-822`), and `RunsPaneLiveTests.swift:158` in the tests. A second loop in auto-dev would silently split the events: roughly half the finished runs would never reach the board's UI and half would never reach the loop, non-deterministically. Task 9 therefore adds an explicitly-registered sink shaped like the `systemMover` the scheduler already holds (`RunScheduler.swift:64,89-91`), notified beside the `.runFinished` yield.

**Reentrancy between two actors that call each other.** `AutoDevService` (actor) → `BoardService.commitMove` (actor) → `RunScheduler.launch` → `pump` → `finish` → `RoundTriggering.triggerRound()` → back into `AutoDevService`. Swift actors are reentrant and never block, so this cannot deadlock; what it can do is interleave two rounds at every `await`. Three things contain it, all in Task 12: the round is **coalesced** (a second trigger while one is running sets a flag and returns, and the runner loops until the flag is clear), every round **re-reads** its state from the store rather than carrying it across an `await`, and the hook is notified **after** `finish` has persisted the run and drained the queue, so a round never observes a half-written run. The weak reference matches `PRWatcher.mover` and `RunScheduler.systemMover`, which are already weak for the same cycle-breaking reason.

---

### Task 1: Precondition witness

**Files:**
- Create: `ElliotKit/Tests/ElliotModelTests/AutoDevPreconditionTests.swift`

**Interfaces:**
- Consumes: PR 0·2 and PR1, exactly as tabulated in **Prerequisites** above.
- Produces: nothing PR4 imports. Its whole product is a **named refusal**: if a prerequisite is missing, `swift test` fails to compile pointing at the missing member, instead of the mystery of a later task failing for reasons that look like its own.

- [ ] **Step 1: Write the failing test**

```swift
import Foundation
import Testing

@testable import ElliotModel

/// Every symbol PR4 borrows from PR 0·2 and PR1, named once, in one file.
///
/// Its job is to fail **by name**. PR4 is the last engine PR of the auto-dev
/// design and consumes four things it cannot supply; without this file the
/// first sign of an absent prerequisite is a compile error inside
/// `AutoDevService`, where it reads as a defect in the new code rather than as
/// a missing dependency. The same discipline `swift-floor.yml` applies to the
/// toolchain: a tools-version refusal at manifest parse beats a mystery.
@Suite("Auto-dev preconditions")
struct AutoDevPreconditionTests {

    private func card(column: Column, prNumber: Int? = nil) -> Card {
        let now = Date(timeIntervalSince1970: 1_000_000)
        return Card(
            repoID: UUID(), title: "Anything", column: column,
            prNumber: prNumber, columnEnteredAt: now, createdAt: now, updatedAt: now
        )
    }

    /// A reading built through `PRStatus.resolved(now:currentHeadOid:)` rather
    /// than by hand, and that is load-bearing **here in particular**.
    ///
    /// `CIState.passing` carries an `Int` under Option B and a `[String]` under
    /// Option A (Task 2), so a literal `.passing(…)` in this file would fail to
    /// compile under one of the two — and a compile error that is *not* a
    /// missing prerequisite is exactly the mystery this suite exists to
    /// prevent. A rollup expressed as the checks `gh` actually renders reads the
    /// same under both.
    private func reading(
        checks: [GHMergeStatus.StatusCheck] = [
            GHMergeStatus.StatusCheck(
                name: "build-and-test", conclusion: "SUCCESS", status: "COMPLETED")
        ],
        mergeStateStatus: String = "CLEAN",
        mergeable: String = "MERGEABLE",
        secondsOld: TimeInterval = 0
    ) -> ResolvedPRStatus {
        let checkedAt = Date(timeIntervalSince1970: 1_000_000)
        let status = PRStatus(
            repoID: UUID(), prNumber: 52, headRefOid: "a1b2c3", checkedAt: checkedAt,
            rawMergeStateStatus: mergeStateStatus, rawMergeable: mergeable,
            rawReviewDecision: "", checks: checks
        )
        return status.resolved(
            now: checkedAt.addingTimeInterval(secondsOld), currentHeadOid: "a1b2c3")
    }

    @Test("The origin auto-dev moves under exists, and is allowed to fire skills")
    func originExists() {
        let origin = MoveOrigin.autoDev(sessionID: UUID())
        #expect(origin.allowsSideEffects)
    }

    @Test("The two refusals PR4's policy switches over exist, with their wire codes")
    func blocksExist() {
        #expect(MoveBlock.notVerifiedGreen(sign: .noBuild).code == "not_verified_green")
        #expect(MoveBlock.systemOwnedTransition.code == "system_owned_transition")
        #expect(MoveBlock.repoBlocked.code == "repo_blocked")
    }

    @Test("A move that demands a verified green is blocked on anything short of one")
    func contextCarriesTheRule() {
        let context = MoveContext(
            repoIsEnabled: true, activeRunID: nil, allowSideEffects: true,
            providedFollowUps: [],
            requiresVerifiedGreen: true,
            prVerdict: reading(checks: [
                GHMergeStatus.StatusCheck(
                    name: "build-and-test", conclusion: "FAILURE", status: "COMPLETED")
            ])
        )
        let outcome = evaluateMove(
            from: .inReview, to: .done, card: card(column: .inReview, prNumber: 52),
            context: context
        )
        #expect(outcome == .blocked(.notVerifiedGreen(sign: .checksFailing(count: 1))))
    }

    @Test("A clean, fresh, unsigned reading is mergeable unattended; a stale one is not")
    func predicateExists() {
        #expect(reading().isMergeableUnattended)
        #expect(reading(secondsOld: PRStatus.maximumAge + 1).isMergeableUnattended == false)
        // `UNSTABLE` is the case `sign == nil` alone lets through: nothing is
        // signed, and GitHub still will not call the pull request clean.
        #expect(reading(mergeStateStatus: "UNSTABLE").isMergeableUnattended == false)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd ElliotKit && swift test --filter AutoDevPreconditionTests`

Expected: FAIL — a compile error naming the first missing prerequisite, e.g.
`error: type 'MoveOrigin' has no member 'autoDev'` or
`error: extra arguments at positions #5, #6 in call` (on `MoveContext`).
If it fails this way, **stop**: PR 0·2 and PR1 have not landed and this plan cannot proceed.

- [ ] **Step 3: Write minimal implementation**

There is none to write here — the implementation is PR 0·2 and PR1. This step is the gate: confirm each row of the Prerequisites table exists by grepping, and fix nothing in this task.

```bash
cd /Users/phmatray/Repositories/phmatray/private/Elliot/.claude/worktrees/precious-beaming-wand
grep -n "case autoDev" ElliotKit/Sources/ElliotModel/SkillRun.swift
grep -n "requiresVerifiedGreen\|prVerdict" ElliotKit/Sources/ElliotModel/RuleEngine.swift
grep -n "notVerifiedGreen\|systemOwnedTransition\|repoBlocked" ElliotKit/Sources/ElliotModel/RuleEngine.swift
grep -n "isMergeableUnattended" ElliotKit/Sources/ElliotModel/PRStatus.swift
grep -n "requiresVerifiedGreen" ElliotKit/Sources/ElliotEngine/BoardService.swift
```

Every one of the five must print at least one line. If any prints nothing, the prerequisite is missing.

- [ ] **Step 4: Run test to verify it passes**

Run: `cd ElliotKit && swift test --filter AutoDevPreconditionTests`

Expected: PASS — 4 tests, 0 failures. Read the count: a filter that matched nothing also exits 0.

- [ ] **Step 5: Commit**

```bash
cd /Users/phmatray/Repositories/phmatray/private/Elliot/.claude/worktrees/precious-beaming-wand
git rev-parse --abbrev-ref HEAD
git add ElliotKit/Tests/ElliotModelTests/AutoDevPreconditionTests.swift
git commit -m "test(model): name every prerequisite auto-dev's loop borrows"
```

---

### Task 2: Option A — a passing check carries its name

> ⚠️ **This task is deliberately separable. Deleting it downgrades the design to Option B.**
> The open decision in the spec ("what counts as green") is settled here as **Option A**: a
> reading is mergeable unattended only when at least one *passing* check actually built or
> tested the code. Option A is not expressible while `CIState.passing` carries an `Int`, because
> the names never reach the predicate. This task, and only this task, carries that change plus
> the names list and the extra conjunct on `isMergeableUnattended`. Revert this one commit and
> `isMergeableUnattended` returns to `!isStale && sign == nil && merge == .clean` — Option B —
> and every other task in this plan still compiles and still passes. Nothing else in PR4 reads
> `hasBuildVerdict`.
>
> ⚠️ That promise is only true because **no other task writes a `.passing(…)` literal**: Task 1
> builds its reading through `PRStatus.resolved(…)` from real checks, and Tasks 3 and 4 use
> `.noChecks`. If you add one somewhere, the revert stops compiling and this note stops being
> true — which is worse than not having made the promise.
>
> If PR1 already shipped `case passing([String])` and `hasBuildVerdict`, the Step 2 test passes
> immediately. That is the signal to skip this task entirely.

- [ ] **Step 0: Measure whether PR1 already did this — and expect that it did**

⚠️ **Cross-plan: PR1's plan owns this change, and PR1 lands first.** PR1's Task 1 creates
`NonBuildChecks.swift` and moves `CIState.passing` to `[String]`; its Task 2 writes
`isMergeableUnattended` **with `&& ci.hasBuildVerdict` already in it**. So on the arbitrated order
this whole task is dead, and the Step 3 edit that "adds" the conjunct would add it a second time.

```bash
grep -n "case passing" ElliotKit/Sources/ElliotModel/PRStatus.swift
ls ElliotKit/Sources/ElliotModel/NonBuildChecks.swift
```

- `case passing([String])` **and** the file exists → PR1 shipped it. **Skip Steps 1–5 entirely**:
  tick the boxes, make no commit, and delete nothing. Then confirm the behaviour PR4 depends on is
  already there, with PR1's own suite: `cd ElliotKit && swift test --filter MergeableUnattendedTests`
  (7 tests) and `--filter PRStatusTests`. ⚠️ Do **not** also create
  `ElliotKit/Tests/ElliotModelTests/NonBuildChecksTests.swift` from Step 1 — it asserts
  `NonBuildChecks.isInert(…)` for six names, all of which PR1's implementation answers correctly
  (`"CodeQL"` and `"Codacy Static Code Analysis"` by exact name, `"Analyze ("` and `"renovate/"` by
  prefix), but its **`Produces` block below is wrong against PR1**: PR1 exposes
  `exactNames: Set<String>` **and** `prefixes: [String]`, never a single `names: [String]`. A test
  file naming `NonBuildChecks.names` does not compile.
- `case passing(Int)` and no such file → PR1 has not landed, and PR4 is being executed out of
  order. The whole **Prerequisites** table above is then unmet, not just this row. Stop and land PR1.

**Files:**
- Create: `ElliotKit/Sources/ElliotModel/NonBuildChecks.swift`
- Create: `ElliotKit/Tests/ElliotModelTests/NonBuildChecksTests.swift`
- Modify: `ElliotKit/Sources/ElliotModel/PRStatus.swift:88` and `:313-325`
- Modify: `ElliotKit/Sources/ElliotModel/GHPayloads.swift:176-181` (the comment this task makes false)
- Modify: `ElliotKit/Sources/ElliotAppKit/PRStatusBlock.swift:111`
- Modify: `ElliotKit/Tests/ElliotModelTests/PRStatusTests.swift:71,99,118,134,144,248`
- Modify: `ElliotKit/Tests/ElliotAppKitTests/PRStatusPresentationTests.swift:67`
- Modify: `ElliotKit/Tests/ElliotIPCTests/PRStatusWireTests.swift:108`

**Interfaces:**
- Consumes: `ResolvedPRStatus.isMergeableUnattended` from PR1 (Option B form) — **only if PR1 shipped
  Option B. It ships Option A, so Step 0 above normally skips this task.**
- Produces (only when Step 0 says PR1 did not ship it):
  - `public enum NonBuildChecks { public static let names: [String]; public static func isInert(_ name: String) -> Bool }`
    ⚠️ **This is not PR1's API.** PR1 ships `exactNames: Set<String>` + `prefixes: [String]` +
    `isInert(_:)`, matching exactly and case-**sensitively** on the first and by prefix on the
    second. The two agree on every name any test in either plan asserts; they differ only in the
    members. `isInert(_:)` is the whole contract PR4 relies on — nothing in PR4 reads the list.
  - `public extension CIState { var hasBuildVerdict: Bool }`
  - `CIState.passing([String])` — the labels of the checks that reached a verdict, in rollup order.
  - `isMergeableUnattended` gains `&& ci.hasBuildVerdict`.

- [ ] **Step 1: Write the failing test**

```swift
import Foundation
import Testing

@testable import ElliotModel

/// The names list is **data**, and this is the suite that keeps it honest.
///
/// It exists because a display dot and a merge authority are not the same
/// judgement. `StatusCheck.isNonVerdict` filters `SKIPPED|NEUTRAL|STALE` and
/// says in its own comment that a CodeQL run which genuinely succeeded still
/// counts as a pass — defensible for a dot on a card, and the portfolio's
/// `renovate/stability-days` lesson if it becomes the thing that merges to a
/// default branch.
@Suite("Non-build checks")
struct NonBuildChecksTests {

    @Test("An analyser's green is not a build verdict")
    func analysersAreInert() {
        #expect(NonBuildChecks.isInert("CodeQL"))
        #expect(NonBuildChecks.isInert("Analyze (swift)"))
        #expect(NonBuildChecks.isInert("renovate/stability-days"))
        #expect(NonBuildChecks.isInert("Codacy Static Code Analysis"))
    }

    @Test("A build's green is a build verdict")
    func buildsAreNot() {
        #expect(NonBuildChecks.isInert("build-and-test") == false)
        #expect(NonBuildChecks.isInert("floor") == false)
        #expect(NonBuildChecks.isInert("ci/travis") == false)
    }

    @Test("Passing carries the names, so the predicate can read them")
    func passingCarriesNames() {
        #expect(CIState.passing(["build", "test"]).hasBuildVerdict)
        #expect(CIState.passing(["CodeQL"]).hasBuildVerdict == false)
        #expect(CIState.passing(["CodeQL", "build"]).hasBuildVerdict)
    }

    @Test("Every state that is not passing has no build verdict at all")
    func otherStatesHaveNone() {
        #expect(CIState.noChecks.hasBuildVerdict == false)
        #expect(CIState.running.hasBuildVerdict == false)
        #expect(CIState.failing(["build"]).hasBuildVerdict == false)
        #expect(CIState.unknown.hasBuildVerdict == false)
    }

    @Test("A pull request whose only green is an analyser is not mergeable unattended")
    func analyserOnlyGreenIsNotMergeable() {
        let analyserOnly = ResolvedPRStatus(
            ci: .passing(["CodeQL"]), merge: .clean, review: .none,
            checkedAt: Date(timeIntervalSince1970: 1_000_000),
            headRefOid: "a1b2c3", isStale: false, sign: nil
        )
        #expect(analyserOnly.isMergeableUnattended == false)

        var built = analyserOnly
        built.ci = .passing(["CodeQL", "build-and-test"])
        #expect(built.isMergeableUnattended)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd ElliotKit && swift test --filter NonBuildChecksTests`

Expected: FAIL — `error: cannot find 'NonBuildChecks' in scope`, and
`error: cannot convert value of type '[String]' to expected argument type 'Int'` on `.passing(["build", "test"])`.

- [ ] **Step 3: Write minimal implementation**

Create `ElliotKit/Sources/ElliotModel/NonBuildChecks.swift`:

```swift
import Foundation

/// Check names whose green says nothing about whether the code builds.
///
/// **Data, not code.** The shape of `board/non_build_checks.json` in the
/// portfolio, which exists because this exact family of false greens once had a
/// dashboard report 43 mergeable pull requests where 2 were mergeable. Adding a
/// reporter is a line in this array and nothing else.
///
/// Deliberately *not* what `StatusCheck.isNonVerdict` does. That one reads
/// GitHub's own `conclusion` vocabulary — `SKIPPED`, `NEUTRAL`, `STALE` — and
/// needs no list. This one is the name-based discounting that was declined for
/// the display dot and is required for merge authority, and its cost is exactly
/// the maintenance the dot did not want to pay.
public enum NonBuildChecks {
    /// Matched case-insensitively against the whole name and against the part
    /// before the first `/` or `(` — GitHub renders a matrix job as
    /// `Analyze (swift)` and a bot status as `renovate/stability-days`.
    public static let names: [String] = [
        "codeql",
        "analyze",
        "codacy",
        "codacy static code analysis",
        "renovate",
        "license/cla",
        "semantic-pull-request",
    ]

    public static func isInert(_ name: String) -> Bool {
        let lowered = name.lowercased()
        if names.contains(lowered) { return true }
        let head = lowered
            .split(whereSeparator: { $0 == "/" || $0 == "(" })
            .first
            .map { $0.trimmingCharacters(in: .whitespaces) } ?? lowered
        return names.contains(head)
    }
}

public extension CIState {
    /// Whether at least one check that actually builds or tests the code passed.
    ///
    /// `.passing` carries the names for exactly this question. A rollup whose
    /// only green is an analyser has judged the code as much as an empty one
    /// has, and `.noChecks` already exists to say so for the empty case.
    var hasBuildVerdict: Bool {
        guard case .passing(let names) = self else { return false }
        return names.contains { !NonBuildChecks.isInert($0) }
    }
}
```

Edit `ElliotKit/Sources/ElliotModel/PRStatus.swift:88`:

```swift
    /// The labels of the checks that reached a verdict, in rollup order.
    ///
    /// Names rather than a count, symmetric with `failing` which already
    /// carries its labels — and load-bearing: `hasBuildVerdict` cannot be
    /// asked of a number. The labels exist at `ciState` and used to be
    /// discarded one line later.
    case passing([String])
```

Edit `ElliotKit/Sources/ElliotModel/PRStatus.swift:313-325`, replacing the last two lines of `ciState`:

```swift
        let passed = checks.filter { !$0.isNonVerdict }.map(\.label)
        return passed.isEmpty ? .noChecks : .passing(passed)
```

Edit `ElliotKit/Sources/ElliotModel/PRStatus.swift`, `isMergeableUnattended` (PR1's property):

```swift
    /// Stricter than `sign == nil`, deliberately.
    ///
    /// `sign` blocks only `.blocked` and `.behind`, so `MergeState.unstable`
    /// reaches `nil` — a pull request the panel itself paints in
    /// `Palette.attention` and calls *mergeable, not every check is green*.
    /// And a rollup whose only green is an analyser has judged nothing.
    var isMergeableUnattended: Bool {
        !isStale && sign == nil && merge == .clean && ci.hasBuildVerdict
    }
```

Edit `ElliotKit/Sources/ElliotAppKit/PRStatusBlock.swift:111`:

```swift
        case .passing(let names): names.count == 1 ? "1 check passed" : "\(names.count) checks passed"
```

Then the eight test assertions. ⚠️ **Not mechanically — `.passing` now carries the *labels of the
checks that fixture seeded*, and the assertion is an equality.** Substituting a plausible name
turns a passing test red for a reason that looks like the code. Each site, with the fixture it is
asserted against:

| site | fixture in that test | becomes |
|---|---|---|
| `PRStatusTests.swift:71` | `run("build", …), run("test", …)` | `.passing(["build", "test"])` |
| `PRStatusTests.swift:99` | `legacy("ci/travis", "SUCCESS")` | `.passing(["ci/travis"])` — `label` falls back to `context` |
| `PRStatusTests.swift:118` | `run("build", "SUCCESS"), run("deploy", <non-verdict>)` | `.passing(["build"])` |
| `PRStatusTests.swift:134` | `run("CodeQL", "SUCCESS")` | `.passing(["CodeQL"])` |
| `PRStatusTests.swift:144` | `run("CodeQL", …), run("renovate/stability-days", …)` | `.passing(["CodeQL", "renovate/stability-days"])` |
| `PRStatusTests.swift:248` | `run("build", "SUCCESS")` | `.passing(["build"])` |
| `PRStatusPresentationTests.swift:67` | the seed's default `name: "build"` | `.passing(["build"])` |
| `PRStatusWireTests.swift:108` | asserts `.code` only | `CIState.passing(["a", "b", "c"])` |

**Then three comments that this task makes false, in the repository whose #186 is about exactly
that.** None of the assertions change — `CIState` still counts an analyser's green as a pass, and
the discounting happens one layer up in `isMergeableUnattended` — but the prose says the judgement
was declined outright, and after this task it is made:

- `ElliotKit/Sources/ElliotModel/GHPayloads.swift:176-181`, `isNonVerdict`'s ⚠️ paragraph: keep the
  distinction it draws (this reads GitHub's `conclusion` vocabulary and needs no list) and replace
  *"that was deliberately declined for this feature"* with a pointer — the name-based list now
  lives in `NonBuildChecks` and is read only by `CIState.hasBuildVerdict`, which decides what an
  unattended session may merge, never what a card draws.
- `PRStatusTests.swift`, `nonVerdictIsNotNameBasedDiscounting`'s comment: same correction, same
  sentence.
- `PRStatusTests.swift`, `inertChecksStillCountAsPassing` — its comment says *"encoding a non-build
  list in Swift would be a third implementation of a rule whose data lives in repo-audit"*. The
  test's claim is still true and worth keeping; its reason is now that **the model does not guess
  for the display**, and the merge predicate is the one caller that asks.

- [ ] **Step 4: Run test to verify it passes**

Run: `cd ElliotKit && swift test --filter NonBuildChecksTests`

Expected: PASS — 5 tests. Then `cd ElliotKit && swift test --filter PRStatusTests` and
`cd ElliotKit && swift test --filter PRStatusWireTests`, both PASS.

- [ ] **Step 5: Commit**

```bash
cd /Users/phmatray/Repositories/phmatray/private/Elliot/.claude/worktrees/precious-beaming-wand
git rev-parse --abbrev-ref HEAD
git add ElliotKit/Sources/ElliotModel/NonBuildChecks.swift \
        ElliotKit/Sources/ElliotModel/PRStatus.swift \
        ElliotKit/Sources/ElliotModel/GHPayloads.swift \
        ElliotKit/Sources/ElliotAppKit/PRStatusBlock.swift \
        ElliotKit/Tests/ElliotModelTests/NonBuildChecksTests.swift \
        ElliotKit/Tests/ElliotModelTests/PRStatusTests.swift \
        ElliotKit/Tests/ElliotAppKitTests/PRStatusPresentationTests.swift \
        ElliotKit/Tests/ElliotIPCTests/PRStatusWireTests.swift
git commit -m "feat(model,app): a passing check carries its name, so a green can be judged"
```

---

### Task 3: The auto-dev value types

> 🔴 **STOP — cross-plan collision. `ElliotKit/Sources/ElliotModel/AutoDev.swift` is created by PR5,
> which ships BEFORE this pull request, and the two declare overlapping types under different
> names.** This was invisible to either plan's own reviewer; it is the one item in the auto-dev set
> that cannot be resolved by reading a single plan.
>
> What PR5 leaves in that file (its Task 1):
>
> | | PR5 (already in the tree) | PR4 (this task, as written) |
> |---|---|---|
> | the session | `AutoDevSession` — `init(id: UUID = UUID(), repoID:engagedCardIDs:maxAttemptsPerCard:patience:startedAt:endedAt: Date? = nil, state: State = .running)` | `AutoDevSession` — same stored properties, no defaults stated |
> | its state | `AutoDevSession.State { running, paused, finished }` | identical |
> | the per-card row | **`AutoDevEngagement`** — `init(sessionID:cardID:attempts:disposition: AutoDevDisposition, reason:updatedAt:)`, `var id: UUID { cardID }` | **`AutoDevCardState`** — same fields, `disposition: DispositionCode`, plus `var isSettled: Bool` |
> | the row's verdict | **`AutoDevDisposition { engaged, merged, blocked }`** | **`DispositionCode { retry, wait, held, settled, aborted }`** |
> | the counts | `AutoDevTally` + `AutoDevTally.of(_ engagements:)` — read by the band **and** the status-bar figure | not declared |
> | the policy verdict | not declared | `Disposition { retry, wait(reason:), held(QueueRefusal), settle(reason:), abortSession(reason:) }` — transient, never persisted |
> | the reading | not declared | `PRReading { noReading, read(ResolvedPRStatus) }` |
>
> PR5 asserts, in its own Prerequisites, that *"the value types this plan declares in `ElliotModel`
> are the ones PR4 persists — PR4 adds the `Records.swift` conformance and the migration; it
> changes nothing in Task 1's file."* **That sentence is false against this task as written**, and
> the failure mode is not a merge conflict — it is two per-card row types, one rendered and one
> persisted, with nothing joining them.
>
> **Recommended resolution, and it needs a human decision before either PR is executed.** Keep
> PR5's names, because they are already read by `AutoDevBand`, `AppModel.autoDevEngagements`,
> `AppModel.autoDevTally`, the status-bar figure and the card mark, and because `AutoDevTally` has
> no counterpart here:
>
> - persist **`AutoDevEngagement`** (PR5's) and delete `AutoDevCardState` from this task, moving its
>   `var isSettled: Bool` onto `AutoDevEngagement` as an extension;
> - persist **`AutoDevDisposition`** (PR5's `engaged | merged | blocked`) in the row, and keep
>   `Disposition` here as the **transient** policy verdict it is, adding one total mapping —
>   `var engagement: AutoDevDisposition` — so `.retry`/`.wait`/`.held` map to `.engaged`,
>   `.settle` maps to `.merged` or `.blocked` on its own reason, and `.abortSession` maps to
>   `.blocked`. ⚠️ `Disposition.settle` currently carries only a `reason: String`; splitting merged
>   from blocked on a **string** is the shape this repository refuses everywhere else, so the
>   mapping needs `settle` to carry the outcome, not to be pattern-matched on prose;
> - `DispositionCode` then either disappears or survives as the *diagnostic* column beside the
>   disposition — the reason `AutoDevPolicy` gave, which the report band wants and the tally does
>   not. **That is the arbitration to make: one persisted enum or two.** Task 5's schema, Task 11's
>   `saveAutoDevSession(_:cards:)` and Task 12's per-card write all follow from the answer.
>
> Nothing below is executable until that is settled. Tasks 3, 5, 11, 12 and 13 all name
> `AutoDevCardState` / `DispositionCode`.

**Files:**
- Create: `ElliotKit/Sources/ElliotModel/AutoDev.swift`
- Test: `ElliotKit/Tests/ElliotModelTests/AutoDevPolicyTests.swift` (the value half; the policy half arrives in Task 4)

**Interfaces:**
- Consumes: `QueueRefusal` (`ElliotModel/QueuedRun.swift:13`), `ResolvedPRStatus` (`ElliotModel/PRStatus.swift:213`).
- Produces:
  - `public struct AutoDevSession: Identifiable, Codable, Sendable, Hashable` with `id, repoID, engagedCardIDs: [UUID], maxAttemptsPerCard: Int, patience: TimeInterval, startedAt: Date, endedAt: Date?, state: AutoDevSession.State`
  - `public enum AutoDevSession.State: String, Codable, CaseIterable, Sendable, Hashable { case running, paused, finished }`
  - `public struct AutoDevCardState: Identifiable, Codable, Sendable, Hashable` with `sessionID, cardID, attempts: Int, disposition: DispositionCode, reason: String, updatedAt: Date`, and `var isSettled: Bool`
  - `public enum DispositionCode: String, Codable, CaseIterable, Sendable, Hashable { case retry, wait, held, settled, aborted }`
  - `public enum Disposition: Sendable, Hashable { case retry; case wait(reason: String); case held(QueueRefusal); case settle(reason: String); case abortSession(reason: String) }` with `var code: DispositionCode`, `var reason: String`, `var isSettled: Bool`
  - `public enum PRReading: Sendable, Hashable { case noReading; case read(ResolvedPRStatus) }`

- [ ] **Step 1: Write the failing test**

```swift
import Foundation
import Testing

@testable import ElliotModel

@Suite("Auto-dev values")
struct AutoDevValueTests {

    private let epoch = Date(timeIntervalSince1970: 1_770_000_000)

    @Test("A session's engaged list is what it was built with")
    func sessionCarriesItsEngagedList() {
        let cards = [UUID(), UUID(), UUID()]
        let session = AutoDevSession(
            repoID: UUID(), engagedCardIDs: cards, maxAttemptsPerCard: 2,
            patience: 900, startedAt: epoch
        )
        #expect(session.engagedCardIDs == cards)
        #expect(session.state == .running)
        #expect(session.endedAt == nil)
    }

    @Test("A disposition's code and sentence are written once, on the disposition")
    func dispositionRenders() {
        #expect(Disposition.retry.code == .retry)
        #expect(Disposition.wait(reason: "Waiting on CI.").code == .wait)
        #expect(Disposition.wait(reason: "Waiting on CI.").reason == "Waiting on CI.")
        #expect(Disposition.held(.mergeWaitsForRepoToBeIdle).code == .held)
        #expect(Disposition.held(.paused).reason == QueueRefusal.paused.sentence)
        #expect(Disposition.settle(reason: "Merged.").code == .settled)
        #expect(Disposition.abortSession(reason: "Blocked.").code == .aborted)
    }

    @Test("Only settling and aborting settle a card")
    func settledIsTwoCases() {
        #expect(Disposition.settle(reason: "x").isSettled)
        #expect(Disposition.abortSession(reason: "x").isSettled)
        #expect(Disposition.retry.isSettled == false)
        #expect(Disposition.wait(reason: "x").isSettled == false)
        #expect(Disposition.held(.paused).isSettled == false)
    }

    @Test("A card's row agrees with its disposition about being settled")
    func rowAgrees() {
        let row = AutoDevCardState(
            sessionID: UUID(), cardID: UUID(), attempts: 1,
            disposition: .settled, reason: "Merged.", updatedAt: epoch
        )
        #expect(row.isSettled)
        var waiting = row
        waiting.disposition = .wait
        #expect(waiting.isSettled == false)
    }

    @Test("A reading that does not exist is a case, never a nil to be tested for")
    func readingIsNotAnOptional() {
        // `.noChecks` and not `.passing(…)`: `passing`'s payload is an `Int`
        // under Option B and a `[String]` under Option A, and nothing in this
        // file is about the rollup. Keeping the literal Option-independent is
        // what makes Task 2's "delete this one commit" promise true.
        let resolved = ResolvedPRStatus(
            ci: .noChecks, merge: .clean, review: .none,
            checkedAt: epoch, headRefOid: "a1b2c3", isStale: false, sign: nil
        )
        #expect(PRReading.read(resolved) != .noReading)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd ElliotKit && swift test --filter AutoDevValueTests`

Expected: FAIL — `error: cannot find 'AutoDevSession' in scope`.

- [ ] **Step 3: Write minimal implementation**

Create `ElliotKit/Sources/ElliotModel/AutoDev.swift`:

```swift
import Foundation

/// One unattended pass over a fixed set of cards in one repository.
///
/// **The engaged list is closed at start.** Every card auto-dev may touch is
/// decided in one write, at one moment, by a person; a card dragged into
/// Backlog mid-session is invisible to it. That is what makes "N cards" a
/// promise rather than a rate.
public struct AutoDevSession: Identifiable, Codable, Sendable, Hashable {
    public enum State: String, Codable, CaseIterable, Sendable, Hashable {
        case running
        case paused
        case finished
    }

    public var id: UUID
    public var repoID: UUID
    /// Fixed at start, never grows.
    public var engagedCardIDs: [UUID]
    public var maxAttemptsPerCard: Int
    /// How long a card may sit on one unchanged reason before it settles.
    ///
    /// On the session rather than a constant: a repository whose CI takes an
    /// hour and one that takes ninety seconds do not want the same answer.
    public var patience: TimeInterval
    public var startedAt: Date
    public var endedAt: Date?
    public var state: State

    public init(
        id: UUID = UUID(),
        repoID: UUID,
        engagedCardIDs: [UUID],
        maxAttemptsPerCard: Int,
        patience: TimeInterval,
        startedAt: Date,
        endedAt: Date? = nil,
        state: State = .running
    ) {
        self.id = id
        self.repoID = repoID
        self.engagedCardIDs = engagedCardIDs
        self.maxAttemptsPerCard = maxAttemptsPerCard
        self.patience = patience
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.state = state
    }
}

/// What a disposition is called, without its payload.
///
/// Persisted, and therefore its own type: a `Disposition` carries associated
/// values that no column can hold, and the payload is already a sentence in
/// `reason`. The same split `MoveBlock.code` makes, for the same reason — a
/// case renamed for readability must not change what a stored row says.
public enum DispositionCode: String, Codable, CaseIterable, Sendable, Hashable {
    case retry
    case wait
    case held
    case settled
    case aborted
}

/// What the loop decided to do about one card, this round.
///
/// `.held` is distinct from `.wait` on purpose: `.paused`,
/// `.dailyCeilingReached` and `.mergeWaitsForRepoToBeIdle` are the *scheduler*
/// holding a run, not the board waiting on the world, and a report that
/// confused them would send the reader to fix the wrong thing.
///
/// `.wait` and `.abortSession` carry a sentence where the design's sketch
/// carried none: the report renders one line per card, and a bare case renders
/// nothing at all.
public enum Disposition: Sendable, Hashable {
    case retry
    case wait(reason: String)
    case held(QueueRefusal)
    case settle(reason: String)
    case abortSession(reason: String)

    public var code: DispositionCode {
        switch self {
        case .retry: .retry
        case .wait: .wait
        case .held: .held
        case .settle: .settled
        case .abortSession: .aborted
        }
    }

    /// One sentence, for the report and for the card's row.
    public var reason: String {
        switch self {
        case .retry: "Moving this card now."
        case .wait(let reason): reason
        case .held(let refusal): refusal.sentence
        case .settle(let reason): reason
        case .abortSession(let reason): reason
        }
    }

    /// Whether this card is finished with, one way or the other.
    public var isSettled: Bool {
        switch self {
        case .settle, .abortSession: true
        case .retry, .wait, .held: false
        }
    }
}

/// One engaged card's state inside a session.
///
/// A row rather than a field of a JSON blob on the session, because this is
/// what the report renders and a blob does not join.
public struct AutoDevCardState: Identifiable, Codable, Sendable, Hashable {
    public var sessionID: UUID
    public var cardID: UUID
    public var attempts: Int
    public var disposition: DispositionCode
    public var reason: String
    /// When this **reason** first appeared — not when the card was last looked
    /// at.
    ///
    /// Load-bearing, and the one field of this type that is easy to get wrong:
    /// the patience window is measured from here, so a value refreshed on every
    /// round would make the window infinite and every stuck card immortal.
    public var updatedAt: Date

    /// Composite key, so a row is addressable in SwiftUI without inventing an
    /// id column the database does not have.
    public var id: String { "\(sessionID.uuidString):\(cardID.uuidString)" }

    public var isSettled: Bool {
        disposition == .settled || disposition == .aborted
    }

    public init(
        sessionID: UUID,
        cardID: UUID,
        attempts: Int,
        disposition: DispositionCode,
        reason: String,
        updatedAt: Date
    ) {
        self.sessionID = sessionID
        self.cardID = cardID
        self.attempts = attempts
        self.disposition = disposition
        self.reason = reason
        self.updatedAt = updatedAt
    }
}

/// What is known about a pull request, as an answer rather than as an optional.
///
/// Not `ResolvedPRStatus?`. The predicate a caller reaches for on an optional is
/// `resolved?.sign == nil`, which returns **true for no row at all** — the
/// absence of a reading rendering as "nothing is wrong". Naming the absence is
/// what makes that unwritable, the same way `CIState.noChecks` names it one
/// layer down.
public enum PRReading: Sendable, Hashable {
    case noReading
    case read(ResolvedPRStatus)
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd ElliotKit && swift test --filter AutoDevValueTests`

Expected: PASS — 5 tests.

- [ ] **Step 5: Commit**

```bash
cd /Users/phmatray/Repositories/phmatray/private/Elliot/.claude/worktrees/precious-beaming-wand
git rev-parse --abbrev-ref HEAD
git add ElliotKit/Sources/ElliotModel/AutoDev.swift \
        ElliotKit/Tests/ElliotModelTests/AutoDevPolicyTests.swift
git commit -m "feat(model): the values an unattended session is made of"
```

---

### Task 4: `AutoDevPolicy` — pure, with the clock injected

**Files:**
- Create: `ElliotKit/Sources/ElliotModel/AutoDevPolicy.swift`
- Test: `ElliotKit/Tests/ElliotModelTests/AutoDevPolicyTests.swift` (append to the file Task 3 created)

**Interfaces:**
- Consumes: `MoveOutcome`, `MoveBlock` (`ElliotModel/RuleEngine.swift:14-54`), `PRSign` (`PRStatus.swift:155`), `QueueRefusal`, `Disposition`, `PRReading`.
- Produces:
  - `public enum AutoDevPolicy`
  - `public static func disposition(outcome: MoveOutcome, reading: PRReading, attempts: Int, maxAttempts: Int, unchangedSince: Date, patience: TimeInterval, now: Date) -> Disposition`
  - `public static func held(_ refusal: QueueRefusal, unchangedSince: Date, patience: TimeInterval, now: Date) -> Disposition`

> **Why the signature takes a `MoveOutcome` and not a `MoveBlock`.** The design
> sketches `disposition(block:attempts:unchangedSince:now:)`, and that signature
> cannot produce `.retry`: no refusal means "go ahead", so a `MoveBlock`-only
> input leaves one of the five cases unreachable. Taking the whole outcome is
> the smallest change that makes the enum honest, and it keeps `rankNextSteps`'
> discipline — decide by calling `evaluateMove`, then interpret what it said.
> `maxAttempts` and `patience` are parameters rather than constants for the
> reason they are fields on the session: two repositories do not want the same
> answer.

- [ ] **Step 1: Write the failing test**

```swift
// Appended to ElliotKit/Tests/ElliotModelTests/AutoDevPolicyTests.swift

/// Every `MoveBlock`, every sign, and the clock driven by hand.
///
/// Pure and exhaustive: no store, no scheduler, no real time. The two things
/// this suite is actually protecting are a loop that spins for ever and a loop
/// that gives up on work that was going to land.
@Suite("Auto-dev policy")
struct AutoDevPolicyTests {

    private let epoch = Date(timeIntervalSince1970: 1_770_000_000)
    private let patience: TimeInterval = 600

    private func decide(
        _ outcome: MoveOutcome,
        reading: PRReading = .noReading,
        attempts: Int = 0,
        maxAttempts: Int = 3,
        secondsUnchanged: TimeInterval = 0
    ) -> Disposition {
        AutoDevPolicy.disposition(
            outcome: outcome,
            reading: reading,
            attempts: attempts,
            maxAttempts: maxAttempts,
            unchangedSince: epoch,
            patience: patience,
            now: epoch.addingTimeInterval(secondsUnchanged)
        )
    }

    /// `ci` is `.noChecks` and not `.passing(…)` because nothing this suite
    /// asserts reads it — `AutoDevPolicy` looks at `isStale` and at the sign,
    /// and at nothing else. It also keeps the literal Option-independent:
    /// `passing`'s payload is an `Int` under Option B and a `[String]` under
    /// Option A, and Task 2 promises that deleting it leaves this file
    /// compiling.
    private func resolved(sign: PRSign?, isStale: Bool = false) -> ResolvedPRStatus {
        ResolvedPRStatus(
            ci: .noChecks, merge: .clean, review: .none,
            checkedAt: epoch, headRefOid: "a1b2c3", isStale: isStale, sign: sign
        )
    }

    @Test("An available move is taken, until the attempts run out")
    func actionRetriesThenSettles() {
        #expect(decide(.action(.implementIssue(issueNumber: 47)), attempts: 0) == .retry)
        #expect(decide(.action(.implementIssue(issueNumber: 47)), attempts: 2) == .retry)
        #expect(decide(.action(.implementIssue(issueNumber: 47)), attempts: 3).code == .settled)
    }

    @Test("A move that fires nothing is still a move, and costs no attempt")
    func noActionAdvances() {
        #expect(decide(.noAction) == .retry)
    }

    @Test("A move that asks a human settles, because no human is watching")
    func needsInputSettles() {
        #expect(decide(.needsInput(.followUps(prNumber: 279))).code == .settled)
    }

    @Test("A half-written story is never completed by repetition")
    func storyRefusalsSettle() {
        #expect(decide(.blocked(.emptyIdea)).code == .settled)
        #expect(decide(.blocked(.incompleteStory)).code == .settled)
    }

    @Test("A missing number means the step before has not landed yet")
    func missingNumbersWait() {
        #expect(decide(.blocked(.missingIssueNumber)).code == .wait)
        #expect(decide(.blocked(.missingPRNumber)).code == .wait)
        #expect(decide(.blocked(.runAlreadyInFlight(runID: UUID()))).code == .wait)
    }

    @Test("A blocked repository ends the session, not one card")
    func repoRefusalsAbort() {
        #expect(decide(.blocked(.repoDisabled)).code == .aborted)
        #expect(decide(.blocked(.repoBlocked)).code == .aborted)
    }

    @Test("A transition the loop does not own settles — waiting cannot fix a category error")
    func systemOwnedSettles() {
        #expect(decide(.blocked(.systemOwnedTransition)).code == .settled)
        #expect(decide(.blocked(.sameColumn)).code == .settled)
    }

    @Test("Checks still running are worth waiting for; a verdict against is not")
    func signsSplitWaitFromSettle() {
        #expect(decide(.blocked(.notVerifiedGreen(sign: .checksRunning))).code == .wait)
        #expect(decide(.blocked(.notVerifiedGreen(sign: .unknown))).code == .wait)

        for sign: PRSign in [
            .noBuild, .conflict, .changesRequested, .reviewRequired, .mergeBlocked,
            .checksFailing(count: 2),
        ] {
            #expect(decide(.blocked(.notVerifiedGreen(sign: sign))).code == .settled)
        }
    }

    @Test("No sign and no reading is a wait; no sign and a current reading is not")
    func absenceAndCurrentAreDifferentAnswers() {
        // The whole reason `reading` is passed non-optional. `sign == nil`
        // alone cannot tell "nobody has read this pull request" from "it was
        // read, it is fine, and it still cannot merge unattended".
        #expect(decide(.blocked(.notVerifiedGreen(sign: nil)), reading: .noReading).code == .wait)
        #expect(
            decide(
                .blocked(.notVerifiedGreen(sign: nil)),
                reading: .read(resolved(sign: nil, isStale: true))
            ).code == .wait
        )
        #expect(
            decide(
                .blocked(.notVerifiedGreen(sign: nil)),
                reading: .read(resolved(sign: nil))
            ).code == .settled
        )
    }

    @Test("Patience bounds every wait, so one stuck CI cannot hold a session open for ever")
    func patienceSettlesAWait() {
        #expect(decide(.blocked(.missingPRNumber), secondsUnchanged: 599).code == .wait)
        #expect(decide(.blocked(.missingPRNumber), secondsUnchanged: 600).code == .settled)
        #expect(
            decide(.blocked(.notVerifiedGreen(sign: .checksRunning)), secondsUnchanged: 601).code
                == .settled
        )
    }

    @Test("Patience bounds a held run too — `mergeWaitsForRepoToBeIdle` is the case it exists for")
    func patienceSettlesAHold() {
        let held = AutoDevPolicy.held(
            .mergeWaitsForRepoToBeIdle, unchangedSince: epoch, patience: patience,
            now: epoch.addingTimeInterval(10)
        )
        #expect(held.code == .held)

        let expired = AutoDevPolicy.held(
            .mergeWaitsForRepoToBeIdle, unchangedSince: epoch, patience: patience,
            now: epoch.addingTimeInterval(patience)
        )
        #expect(expired.code == .settled)
        #expect(expired.reason.contains("merge waits"))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd ElliotKit && swift test --filter AutoDevPolicyTests`

Expected: FAIL — `error: cannot find 'AutoDevPolicy' in scope`.

- [ ] **Step 3: Write minimal implementation**

Create `ElliotKit/Sources/ElliotModel/AutoDevPolicy.swift`:

```swift
import Foundation

/// What an unattended session does about one card, this round.
///
/// Pure: no I/O, no clock, no randomness. The clock is a parameter, the idiom
/// of `PRStatus.resolved(now:currentHeadOid:)` — "the clock, passed in so this
/// stays pure" — which is what lets the whole table be driven by hand.
///
/// It decides by reading a `MoveOutcome` that `evaluateMove` produced, never by
/// re-deriving one. The board predicts its own behaviour; this interprets the
/// prediction.
public enum AutoDevPolicy {

    public static func disposition(
        outcome: MoveOutcome,
        reading: PRReading,
        attempts: Int,
        maxAttempts: Int,
        unchangedSince: Date,
        patience: TimeInterval,
        now: Date
    ) -> Disposition {
        switch outcome {
        case .action, .noAction:
            // `.noAction` is a real advance — a card already filed moving from
            // Backlog to To Do, for one — and it spawns nothing, so it costs no
            // attempt. `attempts` counts runs started, not rounds taken.
            guard attempts < maxAttempts else {
                return .settle(
                    reason: "Tried \(attempts) time\(attempts == 1 ? "" : "s") without landing "
                        + "this card.")
            }
            return .retry

        case .needsInput:
            // `NeedsInput` is documented as information "only a human (or an
            // explicit tool argument) can supply". A loop with nobody watching
            // can only read that as "blocked, I will try again" — which is a
            // spin. PR1 makes this unreachable under `requiresVerifiedGreen`;
            // this is the belt, and it settles rather than waits.
            return .settle(
                reason: "This move asked for something only a person can supply.")

        case .blocked(let block):
            return decide(
                block: block, reading: reading, unchangedSince: unchangedSince,
                patience: patience, now: now)
        }
    }

    /// A run the scheduler is holding, bounded by the same window as a wait.
    ///
    /// The design bounds `.wait`; `.held` needs the same bound for the same
    /// reason, and for one case in particular: `.mergeWaitsForRepoToBeIdle` is
    /// exactly the refusal a session that keeps its own repository busy can
    /// leave standing for ever.
    public static func held(
        _ refusal: QueueRefusal,
        unchangedSince: Date,
        patience: TimeInterval,
        now: Date
    ) -> Disposition {
        guard now.timeIntervalSince(unchangedSince) < patience else {
            return .settle(reason: expired(refusal.sentence, patience: patience))
        }
        return .held(refusal)
    }

    // MARK: - The table

    private static func decide(
        block: MoveBlock,
        reading: PRReading,
        unchangedSince: Date,
        patience: TimeInterval,
        now: Date
    ) -> Disposition {
        switch block {
        case .repoDisabled:
            return .abortSession(
                reason: "The repository is disabled in Elliot, so nothing in this session can run.")
        case .repoBlocked:
            return .abortSession(
                reason: "A Preflight check is failing for this repository, so nothing in this "
                    + "session can run.")

        case .emptyIdea:
            return .settle(reason: "There is nothing on this card to file.")
        case .incompleteStory:
            return .settle(
                reason: "The story is missing one of role, want or benefit, and no amount of "
                    + "repetition completes it.")

        case .sameColumn:
            // Unreachable through `naturalNext`, which never proposes the
            // column a card is already in — and a `.wait` here would spin.
            return .settle(reason: "This card has nowhere further to go.")

        case .systemOwnedTransition:
            return .settle(
                reason: "This step belongs to Elliot's pull-request watcher, not to the session. "
                    + "Waiting cannot fix a category error.")

        case .missingIssueNumber:
            return waiting("The issue has not been filed yet.", unchangedSince, patience, now)
        case .missingPRNumber:
            return waiting("The pull request has not been opened yet.", unchangedSince, patience, now)
        case .runAlreadyInFlight:
            return waiting("A run is already working on this card.", unchangedSince, patience, now)

        case .notVerifiedGreen(let sign):
            return notGreen(sign, reading, unchangedSince, patience, now)
        }
    }

    private static func notGreen(
        _ sign: PRSign?,
        _ reading: PRReading,
        _ unchangedSince: Date,
        _ patience: TimeInterval,
        _ now: Date
    ) -> Disposition {
        guard let sign else {
            // Nothing is *wrong* and it still is not mergeable unattended. Only
            // the reading itself separates "nobody has looked" from "we looked,
            // and no build has judged this pull request" — which is why the
            // reading is passed in as a case rather than as an optional.
            switch reading {
            case .noReading:
                return waiting(
                    "No reading of the pull request yet.", unchangedSince, patience, now)
            case .read(let resolved) where resolved.isStale:
                return waiting(
                    "The reading of the pull request has aged out.", unchangedSince, patience, now)
            case .read:
                return .settle(
                    reason: "Everything known about this pull request is fine and it still cannot "
                        + "be merged unattended — nothing that builds the code has passed on it, "
                        + "or GitHub will not call it clean.")
            }
        }

        switch sign {
        case .checksRunning, .unknown:
            return waiting(sign.summary, unchangedSince, patience, now)
        case .noBuild, .conflict, .changesRequested, .reviewRequired, .mergeBlocked, .checksFailing:
            return .settle(reason: sign.summary)
        }
    }

    private static func waiting(
        _ reason: String, _ unchangedSince: Date, _ patience: TimeInterval, _ now: Date
    ) -> Disposition {
        guard now.timeIntervalSince(unchangedSince) < patience else {
            return .settle(reason: expired(reason, patience: patience))
        }
        return .wait(reason: reason)
    }

    /// Seconds, not minutes: a patience of 30 rendered as `0 minutes` is a
    /// sentence that reads as a bug in the sentence.
    private static func expired(_ reason: String, patience: TimeInterval) -> String {
        "\(reason) Nothing changed for \(Int(patience)) seconds, so the session gave up on it."
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd ElliotKit && swift test --filter AutoDevPolicyTests`

Expected: PASS — 11 tests.

- [ ] **Step 5: Commit**

```bash
cd /Users/phmatray/Repositories/phmatray/private/Elliot/.claude/worktrees/precious-beaming-wand
git rev-parse --abbrev-ref HEAD
git add ElliotKit/Sources/ElliotModel/AutoDevPolicy.swift \
        ElliotKit/Tests/ElliotModelTests/AutoDevPolicyTests.swift
git commit -m "feat(model): what an unattended session does about one card"
```

---

### Task 5: v9 — the two tables, and the flag a run carries

**Files:**
- Modify: `ElliotKit/Sources/ElliotModel/SkillRun.swift:47-207`
- Modify: `ElliotKit/Sources/ElliotStore/Migrations.swift:153`
- Modify: `ElliotKit/Sources/ElliotStore/Records.swift:129-134` (between the `PRStatus` extension and the `SQLColumn` typealias)
- Modify: `ElliotKit/Sources/ElliotStore/BoardStore.swift:894-896` (a new `// MARK: - Auto-dev` section between the analyses one and `// MARK: - Proposals`)
- Test: `ElliotKit/Tests/ElliotStoreTests/AutoDevStoreTests.swift`

**Interfaces:**
- Consumes: `AutoDevSession`, `AutoDevCardState`, `DispositionCode` (Task 3).
- Produces:
  - `SkillRun.requiresVerifiedGreen: Bool?` and `SkillRun.demandsVerifiedGreen: Bool`
  - `SkillRun.card(…, requiresVerifiedGreen: Bool? = nil, createdAt:)`
  - `BoardStore.saveAutoDevSession(_ session: AutoDevSession, cards: [AutoDevCardState]) async throws`
  - `BoardStore.saveAutoDevSession(_ session: AutoDevSession) async throws`
  - `BoardStore.autoDevSession(id: UUID) async throws -> AutoDevSession?`
  - `BoardStore.runningAutoDevSessions() async throws -> [AutoDevSession]`
  - `BoardStore.autoDevCards(sessionID: UUID) async throws -> [AutoDevCardState]`
  - `BoardStore.saveAutoDevCard(_ state: AutoDevCardState) async throws`

> **Why the flag is `Bool?` and not `Bool`.** `BoardStore.openReadOnly` deliberately tolerates a
> helper newer than the file it opens, and the reason it can is that GRDB decodes an absent column
> as `nil` — which only works for an **optional** property. A non-optional `Bool` would throw on
> every `skillRun` read for the whole window between shipping a helper and the next launch of the
> app. `nil` and `false` are never distinguished by any decision here; `demandsVerifiedGreen` exists
> so no site has to write `== true` twice and reason about the nil case again.

- [ ] **Step 1: Write the failing test**

```swift
import ElliotModel
import Foundation
import Testing

@testable import ElliotStore

@Suite("Auto-dev store")
struct AutoDevStoreTests {

    private let epoch = Date(timeIntervalSince1970: 1_770_000_000)

    private func seeded() async throws -> (BoardStore, Repo, [Card]) {
        let store = try BoardStore.inMemory()
        let repo = Repo(
            path: "/tmp/repo-\(UUID().uuidString)", nameWithOwner: "phmatray/Elliot",
            displayName: "Elliot"
        )
        try await store.saveRepo(repo)
        var cards: [Card] = []
        for index in 0..<3 {
            let card = Card(
                repoID: repo.id, title: "Card \(index)",
                columnEnteredAt: epoch, createdAt: epoch, updatedAt: epoch
            )
            try await store.saveCard(card)
            cards.append(card)
        }
        return (store, repo, cards)
    }

    @Test("A session and its rows land in one transaction, and read back whole")
    func sessionAndRowsRoundTrip() async throws {
        let (store, repo, cards) = try await seeded()
        let session = AutoDevSession(
            repoID: repo.id, engagedCardIDs: cards.map(\.id), maxAttemptsPerCard: 2,
            patience: 900, startedAt: epoch
        )
        let rows = cards.map {
            AutoDevCardState(
                sessionID: session.id, cardID: $0.id, attempts: 0,
                disposition: .wait, reason: "Not started.", updatedAt: epoch)
        }
        try await store.saveAutoDevSession(session, cards: rows)

        let readBack = try #require(try await store.autoDevSession(id: session.id))
        #expect(readBack.engagedCardIDs == cards.map(\.id))
        #expect(readBack.patience == 900)
        #expect(readBack.state == .running)

        let readRows = try await store.autoDevCards(sessionID: session.id)
        #expect(readRows.count == 3)
        // The closed list and the mutable rows describe the same set. They are
        // two representations on purpose — the array is the promise, the rows
        // are the state — so this is the assertion that keeps them agreed.
        #expect(Set(readRows.map(\.cardID)) == Set(readBack.engagedCardIDs))
    }

    @Test("A session whose rows cannot be written writes nothing at all")
    func theTransactionIsOne() async throws {
        let (store, repo, cards) = try await seeded()
        let session = AutoDevSession(
            repoID: repo.id, engagedCardIDs: cards.map(\.id), maxAttemptsPerCard: 2,
            patience: 900, startedAt: epoch
        )
        // A row naming a card that does not exist: the foreign key fails, and
        // the session must not survive it. Otherwise a crash between two writes
        // leaves a session with fewer cards than it was started with, and
        // nothing walks the one against the other to notice.
        let rows = [
            AutoDevCardState(
                sessionID: session.id, cardID: cards[0].id, attempts: 0,
                disposition: .wait, reason: "", updatedAt: epoch),
            AutoDevCardState(
                sessionID: session.id, cardID: UUID(), attempts: 0,
                disposition: .wait, reason: "", updatedAt: epoch),
        ]
        await #expect(throws: (any Error).self) {
            try await store.saveAutoDevSession(session, cards: rows)
        }
        #expect(try await store.autoDevSession(id: session.id) == nil)
    }

    @Test("Only running sessions are resumed")
    func runningSessionsAreFiltered() async throws {
        let (store, repo, cards) = try await seeded()
        let live = AutoDevSession(
            repoID: repo.id, engagedCardIDs: [cards[0].id], maxAttemptsPerCard: 1,
            patience: 60, startedAt: epoch)
        var done = AutoDevSession(
            repoID: repo.id, engagedCardIDs: [cards[1].id], maxAttemptsPerCard: 1,
            patience: 60, startedAt: epoch)
        done.state = .finished
        done.endedAt = epoch
        try await store.saveAutoDevSession(live, cards: [])
        try await store.saveAutoDevSession(done, cards: [])

        let running = try await store.runningAutoDevSessions()
        #expect(running.map(\.id) == [live.id])
    }

    @Test("A run remembers the rule the move that made it demanded")
    func runCarriesTheFlag() async throws {
        let (store, repo, cards) = try await seeded()
        var run = SkillRun.card(
            cardID: cards[0].id, repoID: repo.id, kind: .mergePR, prompt: "x",
            cwd: repo.path, logPath: "/tmp/a", stderrPath: "/tmp/b", createdAt: epoch
        )
        run.requiresVerifiedGreen = true
        try await store.saveRun(run)

        let readBack = try #require(try await store.run(id: run.id))
        #expect(readBack.demandsVerifiedGreen)

        // And the absent value is the answer for every run that predates the rule.
        let plain = SkillRun.card(
            cardID: cards[1].id, repoID: repo.id, kind: .mergePR, prompt: "x",
            cwd: repo.path, logPath: "/tmp/a", stderrPath: "/tmp/b", createdAt: epoch
        )
        try await store.saveRun(plain)
        #expect(try await store.run(id: plain.id)?.demandsVerifiedGreen == false)
    }

    @Test("Updating one card's row leaves the others alone")
    func rowsAreIndependent() async throws {
        let (store, repo, cards) = try await seeded()
        let session = AutoDevSession(
            repoID: repo.id, engagedCardIDs: cards.map(\.id), maxAttemptsPerCard: 2,
            patience: 900, startedAt: epoch)
        let rows = cards.map {
            AutoDevCardState(
                sessionID: session.id, cardID: $0.id, attempts: 0,
                disposition: .wait, reason: "Not started.", updatedAt: epoch)
        }
        try await store.saveAutoDevSession(session, cards: rows)

        var first = rows[0]
        first.attempts = 2
        first.disposition = .settled
        first.reason = "Merged."
        first.updatedAt = epoch.addingTimeInterval(60)
        try await store.saveAutoDevCard(first)

        let readRows = try await store.autoDevCards(sessionID: session.id)
        let settled = readRows.filter(\.isSettled)
        #expect(settled.count == 1)
        #expect(settled.first?.attempts == 2)
        #expect(readRows.count == 3)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd ElliotKit && swift test --filter AutoDevStoreTests`

Expected: FAIL — `error: value of type 'BoardStore' has no member 'saveAutoDevSession'` and
`error: value of type 'SkillRun' has no member 'requiresVerifiedGreen'`.

- [ ] **Step 3: Write minimal implementation**

**(a)** `ElliotKit/Sources/ElliotModel/SkillRun.swift` — add the property after `analysisReport`
(line 83), a parameter to the memberwise `init` immediately before `createdAt`, the assignment, and
the same three in `SkillRun.card`:

```swift
    /// Whether the move that created this run demanded a verified green.
    ///
    /// Written by `BoardService` from the move's own context, so admission can
    /// apply the same rule the decision applied — the guard exists twice, and
    /// this is what carries it from one to the other across a crash, where
    /// nothing held in memory survives.
    ///
    /// Optional, and not as a third state: `BoardStore.openReadOnly` deliberately
    /// lets a helper read a file whose migrations it is ahead of, and that
    /// tolerance *is* GRDB decoding an absent column as `nil`, which only works
    /// for an optional. `nil` and `false` are the same answer to every question
    /// asked of it — ask `demandsVerifiedGreen`, never this field.
    public var requiresVerifiedGreen: Bool?
```

```swift
public extension SkillRun {
    /// The one reading of `requiresVerifiedGreen`, so no site writes `== true`
    /// twice and reasons about the nil case again.
    var demandsVerifiedGreen: Bool { requiresVerifiedGreen == true }
}
```

In the memberwise `init` add `requiresVerifiedGreen: Bool? = nil,` immediately before
`createdAt: Date` and `self.requiresVerifiedGreen = requiresVerifiedGreen` beside the other
assignments. In `SkillRun.card` add the same parameter in the same position and pass it through;
`SkillRun.analysis` passes `requiresVerifiedGreen: nil` explicitly — an analysis merges nothing.

**(b)** `ElliotKit/Sources/ElliotStore/Migrations.swift` — register after `v8_prStatus` closes at
line 153, before `return migrator`:

```swift
        // v9, additive: an unattended session, its engaged cards, and the flag
        // that carries a move's green requirement onto the run it made.
        //
        // Two tables and not one JSON blob on the session: the per-card row is
        // what the report renders, and a blob does not join. The session keeps
        // `engagedCardIDs` all the same — that array is the *promise* (closed at
        // start, never grown), where the rows are the *state*.
        //
        // `requiresVerifiedGreen` is nullable with no default, deliberately.
        // `BoardStore.openReadOnly` lets a helper read a file it is ahead of,
        // and that tolerance is exactly GRDB decoding an absent column as nil.
        //
        // `ON DELETE CASCADE` from `card`: deleting a card takes its row with
        // it, so a card a user deleted mid-session leaves the session rather
        // than holding it open for ever.
        migrator.registerMigration("v9_autoDev") { db in
            try db.create(table: "autoDevSession") { t in
                t.primaryKey("id", .text)
                t.column("repoID", .text).notNull()
                    .references("repo", onDelete: .cascade)
                t.column("engagedCardIDs", .text).notNull()      // JSON array
                t.column("maxAttemptsPerCard", .integer).notNull()
                t.column("patience", .double).notNull()
                t.column("startedAt", .datetime).notNull()
                t.column("endedAt", .datetime)
                t.column("state", .text).notNull()
            }
            // The launch path asks exactly one thing: which sessions were still
            // running when the app stopped.
            try db.create(
                index: "autoDevSession_on_state", on: "autoDevSession", columns: ["state"])

            try db.create(table: "autoDevCard") { t in
                t.column("sessionID", .text).notNull()
                    .references("autoDevSession", onDelete: .cascade)
                t.column("cardID", .text).notNull()
                    .references("card", onDelete: .cascade)
                t.column("attempts", .integer).notNull()
                t.column("disposition", .text).notNull()
                t.column("reason", .text).notNull()
                t.column("updatedAt", .datetime).notNull()
                t.primaryKey(["sessionID", "cardID"])
            }

            try db.alter(table: "skillRun") { t in
                t.add(column: "requiresVerifiedGreen", .boolean)
            }
        }
```

**(c)** `ElliotKit/Sources/ElliotStore/Records.swift` — append before the `SQLColumn` typealias
(line 134), copying the shape of the extensions above it. **Both halves**: the table name, and the
UUID strategy as a **`func`** — as a `static var` it compiles and is silently ignored, which stores
blobs while every lookup asks for text.

```swift
extension AutoDevSession: FetchableRecord, PersistableRecord {
    public static let databaseTableName = "autoDevSession"
    public static func databaseUUIDEncodingStrategy(for column: String) -> DatabaseUUIDEncodingStrategy {
        .uppercaseString
    }

    public enum Columns {
        public static let repoID = GRDB.Column("repoID")
        public static let state = GRDB.Column("state")
        public static let startedAt = GRDB.Column("startedAt")
    }
}

/// A composite primary key, so the columns are named here rather than leaning on
/// `id` — `AutoDevCardState.id` is a computed `String` for SwiftUI, not a column,
/// and a synthesised `Codable` does not encode a computed property.
extension AutoDevCardState: FetchableRecord, PersistableRecord {
    public static let databaseTableName = "autoDevCard"
    public static func databaseUUIDEncodingStrategy(for column: String) -> DatabaseUUIDEncodingStrategy {
        .uppercaseString
    }

    public enum Columns {
        public static let sessionID = GRDB.Column("sessionID")
        public static let cardID = GRDB.Column("cardID")
        public static let updatedAt = GRDB.Column("updatedAt")
    }
}
```

**(d)** `ElliotKit/Sources/ElliotStore/BoardStore.swift` — a `// MARK: - Auto-dev` section after the
analyses one, which closes at line 894, immediately before `// MARK: - Proposals` at line 896:

```swift
    // MARK: - Auto-dev

    /// A session and its engaged cards in one transaction — the shape and the
    /// reason of `saveAnalysis(_:runs:)`. Either every row lands or none does: a
    /// session with fewer cards than it was started with is a promise that
    /// quietly shrank, and nothing walks the array against the rows to notice.
    public func saveAutoDevSession(
        _ session: AutoDevSession, cards: [AutoDevCardState]
    ) async throws {
        try await requireWriter().write { db in
            try session.save(db)
            for card in cards { try card.insert(db) }
        }
    }

    public func saveAutoDevSession(_ session: AutoDevSession) async throws {
        try await requireWriter().write { db in try session.save(db) }
    }

    public func autoDevSession(id: UUID) async throws -> AutoDevSession? {
        try await reader.read { db in try AutoDevSession.fetchOne(db, key: id.databaseKey) }
    }

    /// The sessions that were still going when Elliot stopped, oldest first.
    public func runningAutoDevSessions() async throws -> [AutoDevSession] {
        try await reader.read { db in
            try AutoDevSession
                .filter(AutoDevSession.Columns.state == AutoDevSession.State.running.rawValue)
                .order(AutoDevSession.Columns.startedAt)
                .fetchAll(db)
        }
    }

    /// One session's cards. A card the user deleted is gone from here, which is
    /// what leaving a session means.
    public func autoDevCards(sessionID: UUID) async throws -> [AutoDevCardState] {
        try await reader.read { db in
            try AutoDevCardState
                .filter(AutoDevCardState.Columns.sessionID == sessionID.databaseKey)
                .order(AutoDevCardState.Columns.updatedAt)
                .fetchAll(db)
        }
    }

    public func saveAutoDevCard(_ state: AutoDevCardState) async throws {
        try await requireWriter().write { db in try state.save(db) }
    }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd ElliotKit && swift test --filter AutoDevStoreTests`

Expected: PASS — 5 tests. Then `cd ElliotKit && swift test --filter SchemaUpgradeTests`, PASS
unchanged: on `main` today `rewindToV1` undoes only `v2_repositoryLayout`, `v3_cardIdempotencyKey`,
`v5_githubImport` and `v7_cardAngle` — all on `card`, `repo`, `setting` and `dismissedExternal`.
This migration creates two tables and adds a `skillRun` column, so nothing it does belongs in that
`IN` clause and **`rewindToV1` is not touched by this task**.

⚠️ **Cross-plan: do not restore that `precondition` to a number.** It reads
`precondition(db.changesCount == 4)` on `main`, and **PR2's Task 3 raises it to 5** when it teaches
`rewindToV1` to drop the three `card` columns it adds — and PR2 lands well before this branch. The
correct instruction is *leave whatever is there alone*, not *it says 4*. A branch that "corrects"
it back to 4 reddens every upgrade test in that file for a reason that looks like this migration.

- [ ] **Step 5: Commit**

```bash
cd /Users/phmatray/Repositories/phmatray/private/Elliot/.claude/worktrees/precious-beaming-wand
git rev-parse --abbrev-ref HEAD
git add ElliotKit/Sources/ElliotModel/SkillRun.swift ElliotKit/Sources/ElliotStore/Migrations.swift ElliotKit/Sources/ElliotStore/Records.swift ElliotKit/Sources/ElliotStore/BoardStore.swift ElliotKit/Tests/ElliotStoreTests/AutoDevStoreTests.swift
git commit -m "feat(model,store): v9 — a session, its engaged cards, and the rule a run was made under"
```

> **If `v9_` is already taken when you rebase.** GRDB identifies a migration by its **name**, so a
> machine that ran this branch before it landed holds v9's schema under v9's name. Renumbering
> without adopting the old name replays the migration over tables that already exist — a real
> incident, recorded at `Migrations.swift:180-184`. Rename **and** ship the adoption in the same
> commit. ⚠️ **Under the arbitrated delivery order the number is `v11_autoDev`, not `v10_`** — PR2
> takes v9 and PR3 takes v10, and both land before this branch; `v10_` below is written out only
> because it is the shape of the fix. Measure with
> `grep -n 'registerMigration("v' ElliotKit/Sources/ElliotStore/Migrations.swift | tail -3` and take
> the next free integer, substituting it for `v10_autoDev` in both places below:
>
> ```swift
>         RenamedMigration(legacy: "v9_autoDev", current: "v10_autoDev") { db in
>             // Every half of the migration, not just the table it fails on: it
>             // creates two tables and alters a third.
>             try db.tableExists("autoDevSession")
>                 && db.tableExists("autoDevCard")
>                 && db.columns(in: "skillRun").contains { $0.name == "requiresVerifiedGreen" }
>         },
> ```

---

### Task 6: `MoveProposal` carries the two facts the decision used

**Files:**
- Modify: `ElliotKit/Sources/ElliotEngine/BoardService.swift:5-12` (the struct), `:85-116`
  (`proposeMove`), `:136-148` (`commitMove`), `:167-183` (`makeRun`)
- Test: `ElliotKit/Tests/ElliotEngineTests/AutoDevServiceTests.swift` (created here, grown by
  Tasks 8–14)

**Interfaces:**
- Consumes: `SkillRun.card(…, requiresVerifiedGreen:…)` and `SkillRun.demandsVerifiedGreen` (Task 5);
  `MoveContext.requiresVerifiedGreen` / `.prVerdict`,
  `BoardService.proposeMove(cardID:to:origin:followUps:orderIndex:requiresVerifiedGreen:)` **and**
  `BoardService.move(cardID:to:origin:followUps:orderIndex:requiresVerifiedGreen:)` (PR1 — the
  third test below is the only thing in PR4 that names `move`, and it names it deliberately: a
  drag's merge must keep demanding nothing).
- Produces:
  - `MoveProposal.requiresVerifiedGreen: Bool`
  - `MoveProposal.prVerdict: ResolvedPRStatus?` — **the reading the decision was actually made on**
  - a `.mergePR` run committed from a proposal that demanded a green has `demandsVerifiedGreen == true`
  - the file-private `FakeLauncher` actor that Tasks 8–14 reuse

> **Why the proposal carries the verdict rather than the caller re-reading it.** Auto-dev needs the
> reading to turn `.blocked(.notVerifiedGreen(sign: nil))` into a disposition, and a second read
> would be a second answer to a question already answered — the defect `lastRefusals` exists to
> avoid one file over ("the snapshot describes the decision that was actually made, not a fresh
> guess against a board that has since moved"). Carrying it also means PR4 never names PR1's
> internal resolver: the two PRs share a value instead of a symbol.

- [ ] **Step 1: Write the failing test**

```swift
import ElliotModel
import ElliotProcess
import ElliotStore
import Foundation
import TestSupport
import Testing

@testable import ElliotEngine

/// Records what the board asked for without spawning anything — the shape
/// `BoardServiceTests` already uses.
private actor FakeLauncher: RunLaunching {
    private(set) var launched: [UUID] = []
    private(set) var cancelled: [UUID] = []

    func launch(runID: UUID) async { launched.append(runID) }
    func cancel(runID: UUID) async { cancelled.append(runID) }
    func launchedRuns() -> [UUID] { launched }
    func cancelledRuns() -> [UUID] { cancelled }
}

@Suite("Auto-dev — the run carries the rule")
struct AutoDevProposalTests {

    /// A card in In Review with a green, current reading behind it.
    private func fixture() async throws -> (BoardStore, BoardService, Repo, Card) {
        // `TestHome` is the only thing in this process allowed to set
        // `ELLIOT_HOME`; its own comment requires any test that resolves a
        // `StoreLocation` path to touch `root` first, and `commitMove` resolves
        // a run's log and stderr paths through `makeRun`.
        _ = TestHome.root
        let store = try BoardStore.inMemory()
        let board = BoardService(store: store, launcher: FakeLauncher())
        let repo = Repo(
            path: "/tmp/repo-\(UUID().uuidString)", nameWithOwner: "phmatray/Elliot",
            displayName: "Elliot")
        try await store.saveRepo(repo)

        var card = try await board.createCard(repoID: repo.id, title: "Landing").card
        card.column = .inReview
        card.issueNumber = 47
        card.prNumber = 52
        try await store.saveCard(card)

        try await store.savePRStatus(
            PRStatus(
                repoID: repo.id, prNumber: 52, headRefOid: "a1b2c3", checkedAt: Date(),
                rawMergeStateStatus: "CLEAN", rawMergeable: "MERGEABLE", rawReviewDecision: "",
                checks: [GHMergeStatus.StatusCheck(
                    name: "build-and-test", conclusion: "SUCCESS", status: "COMPLETED")]
            ))
        return (store, board, repo, card)
    }

    @Test("A proposal says which rule it was decided under, and on what reading")
    func proposalCarriesBoth() async throws {
        let (_, board, _, card) = try await fixture()
        let proposal = try await board.proposeMove(
            cardID: card.id, to: .done, origin: .autoDev(sessionID: UUID()),
            followUps: [], requiresVerifiedGreen: true)

        #expect(proposal.requiresVerifiedGreen)
        let verdict = try #require(proposal.prVerdict)
        #expect(verdict.isMergeableUnattended)
        #expect(proposal.outcome == .action(.mergePR(prNumber: 52, followUps: [])))
    }

    @Test("The merge run remembers the rule, so admission can apply it again")
    func runCarriesTheRule() async throws {
        let (store, board, _, card) = try await fixture()
        let proposal = try await board.proposeMove(
            cardID: card.id, to: .done, origin: .autoDev(sessionID: UUID()),
            followUps: [], requiresVerifiedGreen: true)
        guard case .moved(let runID?) = try await board.commitMove(proposal) else {
            Issue.record("expected a run")
            return
        }
        #expect(try await store.run(id: runID)?.demandsVerifiedGreen == true)
    }

    @Test("A drag's merge run demands nothing, so nothing about a drag changes")
    func aDragIsUnchanged() async throws {
        let (store, board, _, card) = try await fixture()
        guard case .moved(let runID?) = try await board.move(
            cardID: card.id, to: .done, origin: .userDrag, followUps: [],
            requiresVerifiedGreen: false
        ) else {
            Issue.record("expected a run")
            return
        }
        #expect(try await store.run(id: runID)?.demandsVerifiedGreen == false)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd ElliotKit && swift test --filter AutoDevProposalTests`

Expected: FAIL — `error: value of type 'MoveProposal' has no member 'requiresVerifiedGreen'`.

- [ ] **Step 3: Write minimal implementation**

`ElliotKit/Sources/ElliotEngine/BoardService.swift`, the struct at `:5-12`:

```swift
public struct MoveProposal: Sendable {
    public var card: Card
    public var from: ElliotModel.Column
    public var to: ElliotModel.Column
    public var orderIndex: Double
    public var outcome: MoveOutcome
    public var origin: MoveOrigin
    /// The rule this proposal was decided under, carried so `commitMove` can
    /// write it onto the run and admission can apply it a second time.
    public var requiresVerifiedGreen: Bool
    /// The reading the decision was actually made on — not a fresh one.
    ///
    /// Carried rather than re-read by the caller, for the reason `lastRefusals`
    /// records its refusals instead of recomputing them: a second read is a
    /// second answer, taken against a board that has since moved.
    public var prVerdict: ResolvedPRStatus?
}
```

In `proposeMove`, extend the returned value at `:112-115` — `context` is already filled by PR1:

```swift
        return MoveProposal(
            card: card, from: card.column, to: column,
            orderIndex: index, outcome: outcome, origin: origin,
            requiresVerifiedGreen: context.requiresVerifiedGreen,
            prVerdict: context.prVerdict
        )
```

In `commitMove`'s `.action` branch (`:136-137`), pass the flag down:

```swift
        case .action(let action):
            let run = try await makeRun(
                for: action, card: proposal.card,
                requiresVerifiedGreen: proposal.requiresVerifiedGreen)
```

and in `makeRun` (`:167-183`), take it and set it — through `SkillRun.card`, which already refuses
to let `analysisID` and `analysisAngle` come apart:

```swift
    private func makeRun(
        for action: TriggerAction, card: Card, requiresVerifiedGreen: Bool
    ) async throws -> SkillRun {
        guard let repo = try await store.repo(id: card.repoID) else {
            throw BoardError.repoNotFound(card.repoID)
        }
        let runID = UUID()
        return SkillRun.card(
            id: runID,
            cardID: card.id,
            repoID: card.repoID,
            kind: action.kind,
            prompt: SlashCommandBuilder.prompt(for: action),
            cwd: repo.path,
            logPath: StoreLocation.runLogURL(runID: runID).path,
            stderrPath: StoreLocation.runStderrURL(runID: runID).path,
            // The run remembers the rule the move demanded, so admission can
            // apply it again — including across a crash, where nothing held in
            // memory survives.
            requiresVerifiedGreen: requiresVerifiedGreen,
            createdAt: Date()
        )
    }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd ElliotKit && swift test --filter AutoDevProposalTests`

Expected: PASS — 3 tests. Then `cd ElliotKit && swift test --filter BoardServiceTests`, PASS.

- [ ] **Step 5: Commit**

```bash
cd /Users/phmatray/Repositories/phmatray/private/Elliot/.claude/worktrees/precious-beaming-wand
git rev-parse --abbrev-ref HEAD
git add ElliotKit/Sources/ElliotEngine/BoardService.swift ElliotKit/Tests/ElliotEngineTests/AutoDevServiceTests.swift
git commit -m "feat(engine): a proposal carries the rule and the reading it was decided on"
```

---

### Task 7: The second green guard, at admission — **the most important task of the set**

**Files:**
- Modify: `ElliotKit/Sources/ElliotModel/QueuedRun.swift:13-64`
- Modify: `ElliotKit/Sources/ElliotEngine/RunScheduler.swift:184-241` (`refusal`), `:249-270`
  (`pump`), `:294-296` (`queueSnapshot`), `:561-565` (the test seams)
- Modify: `ElliotKit/Tests/ElliotEngineTests/SchedulerLimitsAdmissionTests.swift:145-217`
- Test: `ElliotKit/Tests/ElliotEngineTests/MergeAdmissionTests.swift`

**Interfaces:**
- Consumes: `SkillRun.demandsVerifiedGreen` (Task 5); `PRStatus.maximumAge`
  (`ElliotModel/PRStatus.swift:60`); `PRStatus.resolved(now:currentHeadOid:)` (`:251`);
  `MoveProposal.requiresVerifiedGreen` (Task 6).
- Produces:
  - `QueueRefusal.mergeVerdictNotEstablished`, `code == "merge_verdict_not_established"`
  - `RunScheduler.MergeAdmission` — `.notDemanded` · `.current` · `.notEstablished`
  - `RunScheduler.refusal(for:overBudget:mergeVerdict:)` — **no default on the new parameter**
  - `RunScheduler.testOnlyClearInFlight(_ runID: UUID)` and `RunScheduler.testOnlyDrain()`

> **Why this exists at all.** `evaluateMove` decides at `proposeMove` time, but `commitMove` writes
> the card and inserts the run in one transaction (`BoardService.swift:137-147`), and `pump()` may
> then hold that run: `refusal(for:)` returns `.mergeWaitsForRepoToBeIdle` while *any* run is going
> in the repository (`RunScheduler.swift:234`), the refused run returns to `pending` with no ageing
> (`:256-267`), and `start(_:)` re-reads only the repository (`:333-334`). `PRStatus.maximumAge` is
> 600 s. Under a session that keeps one repository busy, the merge is **structurally** the
> most-delayed run in the system — so without this branch, auto-dev merges to a default branch on a
> reading the system itself calls stale, PR1 is green, PR4 is green, and nothing says so.
>
> **Why the guard is narrow.** It applies only to runs whose move demanded a green. A human dragging
> In Review → Done has looked at the card; refusing their merge because a background poller's row
> aged out would hold a hand-made gesture for ever on a repository `gh` cannot reach. Narrowing it
> is also what lets *absence* refuse — for a run that asked for a green, anything short of a fresh
> green is a refusal — instead of the perverse rule where holding no information is less strict than
> holding old information.

- [ ] **Step 1: Write the failing test**

```swift
import ElliotModel
import ElliotProcess
import ElliotStore
import Foundation
import TestSupport
import Testing

@testable import ElliotEngine

/// **The admission test.**
///
/// Without it, PR1 is green, PR4 is green, and merging on a stale reading is
/// invisible: the decision passed on a fresh reading, and the run started ten
/// minutes later on the strength of it.
@Suite("Merge admission — the second green guard")
struct MergeAdmissionTests {

    /// `/usr/bin/true` and not a fake: if the merge is wrongly admitted the
    /// child exits at once and the run row leaves `.queued`, which is the
    /// witness. Nothing here should ever spawn.
    private func toolConfig() -> ToolConfig {
        ToolConfig(
            claudePath: "/usr/bin/true", ghPath: "/usr/bin/false",
            gitPath: "/usr/bin/false", environment: [:])
    }

    private func scheduler(_ store: BoardStore) -> RunScheduler {
        let config = toolConfig()
        return RunScheduler(
            store: store, toolConfig: config, verifier: Verifier(gh: .init(config: config)))
    }

    private func greenStatus(repoID: UUID, checkedAt: Date) -> PRStatus {
        PRStatus(
            repoID: repoID, prNumber: 52, headRefOid: "a1b2c3", checkedAt: checkedAt,
            rawMergeStateStatus: "CLEAN", rawMergeable: "MERGEABLE", rawReviewDecision: "",
            checks: [GHMergeStatus.StatusCheck(
                name: "build-and-test", conclusion: "SUCCESS", status: "COMPLETED")]
        )
    }

    private func mergeRun(cardID: UUID, repoID: UUID, demanding: Bool) -> SkillRun {
        SkillRun.card(
            cardID: cardID, repoID: repoID, kind: .mergePR, prompt: "x", cwd: "/tmp",
            logPath: "/tmp/a", stderrPath: "/tmp/b",
            requiresVerifiedGreen: demanding ? true : nil, createdAt: Date())
    }

    @Test("A merge whose reading aged out while it waited does not start")
    func staleVerdictIsRefusedAtAdmission() async throws {
        // `TestHome` is the only thing in this process allowed to set
        // `ELLIOT_HOME`, and its own comment makes the rule: any test that
        // resolves a `StoreLocation` path touches `root` first, so the home is
        // already final when the path is computed. `commitMove` below resolves
        // two through `makeRun`.
        _ = TestHome.root
        let store = try BoardStore.inMemory()
        let scheduler = scheduler(store)
        let board = BoardService(store: store, launcher: scheduler)
        await scheduler.setSystemMover(board)

        let repo = Repo(
            path: "/tmp/repo-\(UUID().uuidString)", nameWithOwner: "phmatray/Elliot",
            displayName: "Elliot")
        try await store.saveRepo(repo)

        var card = try await board.createCard(repoID: repo.id, title: "Landing").card
        card.column = .inReview
        card.issueNumber = 47
        card.prNumber = 52
        try await store.saveCard(card)

        // A green reading, taken now. The decision below passes on it.
        try await store.savePRStatus(greenStatus(repoID: repo.id, checkedAt: Date()))

        // A sibling run in the same repository, so the merge is held by
        // `.mergeWaitsForRepoToBeIdle` exactly as a session would hold it.
        let sibling = SkillRun.card(
            cardID: card.id, repoID: repo.id, kind: .implementIssue, prompt: "x",
            cwd: repo.path, logPath: "/tmp/a", stderrPath: "/tmp/b", createdAt: Date())
        await scheduler.testOnlyMarkInFlight(sibling)

        let proposal = try await board.proposeMove(
            cardID: card.id, to: .done, origin: .autoDev(sessionID: UUID()),
            followUps: [], requiresVerifiedGreen: true)
        #expect(proposal.outcome == .action(.mergePR(prNumber: 52, followUps: [])))
        guard case .moved(let runID?) = try await board.commitMove(proposal) else {
            Issue.record("expected a queued merge")
            return
        }
        #expect(try await store.run(id: runID)?.state == .queued)

        // The clock advances past `maximumAge` — expressed by re-dating the row
        // rather than by sleeping, because no assertion here may measure an
        // absolute duration and no test may sleep a fixed interval.
        try await store.savePRStatus(
            greenStatus(
                repoID: repo.id,
                checkedAt: Date().addingTimeInterval(-(PRStatus.maximumAge + 60))))

        // The sibling finishes: the repository is idle and the merge is next.
        await scheduler.testOnlyClearInFlight(sibling.id)
        await scheduler.testOnlyDrain()

        // The whole point.
        #expect(try await store.run(id: runID)?.state == .queued)
        let queue = await scheduler.queueSnapshot()
        #expect(queue.first?.runID == runID)
        #expect(queue.first?.refusal == .mergeVerdictNotEstablished)
    }

    @Test("A merge with a current reading is admitted once the repository is idle")
    func currentVerdictIsAdmitted() async throws {
        let store = try BoardStore.inMemory()
        let scheduler = scheduler(store)
        #expect(
            await scheduler.refusal(
                for: mergeRun(cardID: UUID(), repoID: UUID(), demanding: true),
                overBudget: false, mergeVerdict: .current) == nil)
    }

    @Test("A merge nobody has read is refused, because absence is not a green")
    func absentReadingIsRefused() async throws {
        let store = try BoardStore.inMemory()
        let scheduler = scheduler(store)
        #expect(
            await scheduler.refusal(
                for: mergeRun(cardID: UUID(), repoID: UUID(), demanding: true),
                overBudget: false, mergeVerdict: .notEstablished)
                == .mergeVerdictNotEstablished)
    }

    @Test("A drag's merge is admitted exactly as it always was")
    func aDragIsUnaffected() async throws {
        let store = try BoardStore.inMemory()
        let scheduler = scheduler(store)
        #expect(
            await scheduler.refusal(
                for: mergeRun(cardID: UUID(), repoID: UUID(), demanding: false),
                overBudget: false, mergeVerdict: .notDemanded) == nil)
    }

    @Test("The pause and the ceiling both outrank the verdict")
    func orderingIsStated() async throws {
        let store = try BoardStore.inMemory()
        let scheduler = scheduler(store)
        let run = mergeRun(cardID: UUID(), repoID: UUID(), demanding: true)
        #expect(
            await scheduler.refusal(for: run, overBudget: true, mergeVerdict: .notEstablished)
                == .dailyCeilingReached)
        await scheduler.pause()
        #expect(
            await scheduler.refusal(for: run, overBudget: false, mergeVerdict: .notEstablished)
                == .paused)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd ElliotKit && swift test --filter MergeAdmissionTests`

Expected: FAIL — `error: extra argument 'mergeVerdict' in call` and
`error: type 'QueueRefusal' has no member 'mergeVerdictNotEstablished'`.

- [ ] **Step 3: Write minimal implementation**

`ElliotKit/Sources/ElliotModel/QueuedRun.swift` — a case, its code and its sentence, in the three
places the enum keeps them:

```swift
    /// A merge that must not land on anything short of a verified green, and
    /// the reading behind it is missing or older than `PRStatus.maximumAge`.
    case mergeVerdictNotEstablished
```

```swift
        case .mergeVerdictNotEstablished: "merge_verdict_not_established"
```

```swift
        case .mergeVerdictNotEstablished:
            "This merge was queued by a session that only merges on a verified green, and the reading of the pull request is missing or older than \(Int(PRStatus.maximumAge / 60)) minutes. Elliot re-reads it while the merge waits; the merge starts as soon as a current reading says the pull request is green."
```

`ElliotKit/Sources/ElliotEngine/RunScheduler.swift` — the value, the branch, the pre-pass, the seams.
Above `canStart`:

```swift
    /// What admission knows about a merge run's reading, as of this drain.
    ///
    /// Passed into `refusal(for:)` rather than read there, for exactly the
    /// reason `overBudget` is: the reading lives behind an `await` and that
    /// method is deliberately synchronous, because it is consulted once per
    /// pending run per drain.
    enum MergeAdmission: Sendable, Hashable {
        /// Not a merge, or the move that queued it demanded no verified green.
        /// Admission is exactly what it always was.
        case notDemanded
        /// It demanded a green, and the reading behind it is still current.
        case current
        /// It demanded a green, and the reading is missing or has aged past
        /// `PRStatus.maximumAge`. For a run that asked for a green, those two
        /// are the same answer.
        case notEstablished
    }
```

`canStart` (`:198-200`):

```swift
    func canStart(_ run: SkillRun) -> Bool {
        refusal(for: run, overBudget: false, mergeVerdict: .notDemanded) == nil
    }
```

`refusal` (`:212-241`) takes the parameter — **no default**, so every call site states its answer the
way `overBudget` already makes them — and gains one branch after the ceiling:

```swift
    func refusal(
        for run: SkillRun, overBudget: Bool, mergeVerdict: MergeAdmission
    ) -> QueueRefusal? {
        if isPaused { return .paused }
        if overBudget { return .dailyCeilingReached }
        // Third, and above the repository rules on purpose: no other rule can
        // release this one, so naming a cap here would send the reader to raise
        // a limit that is not the block.
        if mergeVerdict == .notEstablished { return .mergeVerdictNotEstablished }

        let sameRepo = inFlight.values.filter { $0.repoID == run.repoID }
        // … unchanged from here down …
```

`pump` (`:249-270`) reads the admissions **once per drain**, above the loop, exactly where
`overBudget` is read:

```swift
    private func pump() async {
        // Read once per drain, not once per run. `canStart` is consulted for
        // every pending run and is deliberately synchronous; a SQL aggregate in
        // there would turn draining a queue of twenty into twenty queries.
        let overBudget = await isOverDailyCeiling()
        let admissions = await mergeAdmissions(now: Date())
        var stillPending: [UUID] = []
        var refusals: [UUID: QueueRefusal] = [:]
        for runID in pending {
            guard let run = try? await store.run(id: runID), run.state == .queued else { continue }
            // The ceiling holds runs rather than cancelling them: tomorrow, or a
            // raised ceiling, releases the same queue untouched.
            if let why = refusal(
                for: run, overBudget: overBudget,
                mergeVerdict: admissions[runID] ?? .notDemanded
            ) {
                stillPending.append(runID)
                refusals[runID] = why
            } else {
                await start(run)
            }
        }
        pending = stillPending
        lastRefusals = refusals
        await publishQueue()
    }

    /// What is known about each pending merge that demanded a verified green.
    ///
    /// `currentHeadOid: nil` deliberately. Establishing the head right now would
    /// be a network call inside a drain, and `PRWatcher` already re-reads the
    /// moment the head moves. What that leaves in force is the **age** rule,
    /// which is the one this guard exists for: by the time `pump()` admits a
    /// held merge, the reading that decided the move is structurally the most
    /// delayed one in the system.
    ///
    /// `?? nil` flattens the `T??` a `try?` around an optional-returning throwing
    /// call produces — the idiom `PRWatcher.refreshStatuses` already uses.
    private func mergeAdmissions(now: Date) async -> [UUID: MergeAdmission] {
        var admissions: [UUID: MergeAdmission] = [:]
        for runID in pending {
            guard let run = try? await store.run(id: runID),
                run.kind == .mergePR,
                run.demandsVerifiedGreen,
                let cardID = run.cardID
            else { continue }
            guard let card = (try? await store.card(id: cardID)) ?? nil,
                let number = card.prNumber,
                let status = (try? await store.prStatus(repoID: run.repoID, prNumber: number)) ?? nil
            else {
                admissions[runID] = .notEstablished
                continue
            }
            admissions[runID] = status.resolved(now: now, currentHeadOid: nil).isStale
                ? .notEstablished : .current
        }
        return admissions
    }
```

`queueSnapshot` (`:294-296`) — the fallback for a run queued since the last drain:

```swift
                    refusal: lastRefusals[runID]
                        // `.notDemanded` here is not a claim about the run: this
                        // branch is only reached for a run queued *since* the
                        // last drain, whose reading has not been taken yet. The
                        // next drain records the real reason.
                        ?? refusal(for: run, overBudget: false, mergeVerdict: .notDemanded)
                        ?? .writerCapReached(inFlight: 0, cap: limits.maxConcurrent),
```

The two seams, beside `testOnlyMarkInFlight` (`:561-565`):

```swift
    /// Releases a seeded in-flight run, so a test can express "the sibling
    /// finished" without spawning one.
    func testOnlyClearInFlight(_ runID: UUID) {
        inFlight[runID] = nil
    }

    /// Drains the queue the way a finished run does, without a finished run.
    func testOnlyDrain() async {
        await pump()
    }
```

Finally, the existing call sites in
`ElliotKit/Tests/ElliotEngineTests/SchedulerLimitsAdmissionTests.swift` — lines 145, 156, 167, 177,
181, 190, 194, 203, 215 — each gain `, mergeVerdict: .notDemanded`. They are all about caps and
repositories, none about a verdict.

- [ ] **Step 4: Run test to verify it passes**

Run: `cd ElliotKit && swift test --filter MergeAdmissionTests`

Expected: PASS — 5 tests. Then `cd ElliotKit && swift test --filter QueueRefusalAdmissionTests`,
`cd ElliotKit && swift test --filter SchedulerLimitsAdmissionTests` and
`cd ElliotKit && swift test --filter QueueRefusalTests`, all PASS.

Then sample the whole suite five times after one clean build, because this task changes admission
for every run on the board:

```bash
cd ElliotKit && swift build --build-tests
swift test
swift test
swift test
swift test
swift test
```

- [ ] **Step 5: Commit**

```bash
cd /Users/phmatray/Repositories/phmatray/private/Elliot/.claude/worktrees/precious-beaming-wand
git rev-parse --abbrev-ref HEAD
git add ElliotKit/Sources/ElliotModel/QueuedRun.swift ElliotKit/Sources/ElliotEngine/RunScheduler.swift ElliotKit/Tests/ElliotEngineTests/MergeAdmissionTests.swift ElliotKit/Tests/ElliotEngineTests/SchedulerLimitsAdmissionTests.swift
git commit -m "feat(engine): refuse a merge whose green has aged out while it waited"
```

---

### Task 8: `RunQueueReading` — reading *why* a run is held

**Files:**
- Create: `ElliotKit/Sources/ElliotEngine/RunQueueReading.swift`
- Modify: `ElliotKit/Sources/ElliotEngine/RunScheduler.swift:32` (the conformance), `:140`
- Test: `ElliotKit/Tests/ElliotEngineTests/AutoDevServiceTests.swift` (append)

**Interfaces:**
- Consumes: `QueuedRun` (`ElliotModel/QueuedRun.swift:71`), `RunScheduler.queueSnapshot()`
  (`RunScheduler.swift:274`), `RunScheduler.paused` (`:140`).
- Produces:
  - `public protocol RunQueueReading: Sendable { func queueIsPaused() async -> Bool; func queueSnapshot() async -> [QueuedRun] }`
  - `RunScheduler: RunLaunching, RunQueueReading`
  - `RunScheduler.queueIsPaused() async -> Bool`

> **Why a second protocol rather than widening `RunLaunching`.** `RunLaunching` declares
> `launch`/`cancel` and nothing else (`RunScheduler.swift:11-14`), and it exists so `BoardService`
> does not depend on the scheduler concretely. Auto-dev needs strictly more: it has to tell a run
> the *board* is waiting on from a run the *scheduler* is holding, because `.paused`,
> `.dailyCeilingReached` and `.mergeWaitsForRepoToBeIdle` send the reader somewhere else entirely.
> Widening `RunLaunching` would grow two methods on every fake launcher that never calls them.
>
> **Why methods and not properties.** `queueSnapshot()` already has exactly this shape on the actor,
> so it witnesses the requirement unchanged; an `async` *property* requirement witnessed by an
> actor-isolated property is a corner of the language this package nowhere else relies on, and a
> plan is a bad place to discover it.

- [ ] **Step 1: Write the failing test**

```swift
// Appended to ElliotKit/Tests/ElliotEngineTests/AutoDevServiceTests.swift

@Suite("Run queue reading")
struct RunQueueReadingTests {

    private func scheduler() throws -> RunScheduler {
        let store = try BoardStore.inMemory()
        let config = ToolConfig(
            claudePath: "/usr/bin/true", ghPath: "/usr/bin/true",
            gitPath: "/usr/bin/true", environment: [:])
        return RunScheduler(
            store: store, toolConfig: config, verifier: Verifier(gh: .init(config: config)))
    }

    @Test("The scheduler answers the protocol auto-dev reads it through")
    func schedulerConforms() async throws {
        let scheduler = try scheduler()
        let queue: any RunQueueReading = scheduler
        #expect(await queue.queueIsPaused() == false)
        #expect(await queue.queueSnapshot().isEmpty)

        await scheduler.pause()
        #expect(await queue.queueIsPaused())
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd ElliotKit && swift test --filter RunQueueReadingTests`

Expected: FAIL — `error: cannot find type 'RunQueueReading' in scope`.

- [ ] **Step 3: Write minimal implementation**

Create `ElliotKit/Sources/ElliotEngine/RunQueueReading.swift`:

```swift
import ElliotModel
import Foundation

/// The queue as a reader sees it: whether it is stopped, and what is holding
/// each thing in it.
///
/// A second protocol beside `RunLaunching`, which declares only `launch` and
/// `cancel`. An unattended session has to tell a run the *board* is waiting on
/// from a run the *scheduler* is holding — `.paused`, `.dailyCeilingReached` and
/// `.mergeWaitsForRepoToBeIdle` are a hand on the brake, not the world moving —
/// and a report that confused them would send the reader to fix the wrong thing.
///
/// Methods rather than `async` properties: `queueSnapshot()` already has exactly
/// this shape on the actor, so it witnesses this unchanged.
public protocol RunQueueReading: Sendable {
    /// Whether every pending run is being held by the user's own stop.
    func queueIsPaused() async -> Bool
    /// The pending queue, in the order `pump()` will consider it, each entry
    /// carrying the rule that is holding it.
    func queueSnapshot() async -> [QueuedRun]
}
```

`ElliotKit/Sources/ElliotEngine/RunScheduler.swift:32`:

```swift
public actor RunScheduler: RunLaunching, RunQueueReading {
```

and beside `paused` (`:140`):

```swift
    public var paused: Bool { isPaused }

    /// `paused` as `RunQueueReading` asks for it. Two spellings of one value,
    /// and deliberately not a rename: `AppModel.swift:1289` reads `paused`
    /// directly, and a protocol requirement is a different thing from a property
    /// the app happens to read.
    public func queueIsPaused() async -> Bool { isPaused }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd ElliotKit && swift test --filter RunQueueReadingTests`

Expected: PASS — 1 test.

- [ ] **Step 5: Commit**

```bash
cd /Users/phmatray/Repositories/phmatray/private/Elliot/.claude/worktrees/precious-beaming-wand
git rev-parse --abbrev-ref HEAD
git add ElliotKit/Sources/ElliotEngine/RunQueueReading.swift ElliotKit/Sources/ElliotEngine/RunScheduler.swift ElliotKit/Tests/ElliotEngineTests/AutoDevServiceTests.swift
git commit -m "feat(engine): read the queue's held reasons through a protocol, not the stream"
```

---

### Task 9: `RoundTriggering` — the scheduler's second sink

**Files:**
- Create: `ElliotKit/Sources/ElliotEngine/RoundTriggering.swift`
- Modify: `ElliotKit/Sources/ElliotEngine/RunScheduler.swift:64` (the reference), `:89-91` (the
  setter), `:448-453` (the notification)
- Test: `ElliotKit/Tests/ElliotEngineTests/AutoDevServiceTests.swift` (append)

**Interfaces:**
- Consumes: `RunScheduler.testOnlyDrain()` (Task 7).
- Produces:
  - `public protocol RoundTriggering: AnyObject, Sendable { func triggerRound() async }`
  - `RunScheduler.setRoundTrigger(_ trigger: any RoundTriggering)`
  - a `triggerRound()` call after every `.runFinished`, **after** the run is persisted and the queue
    has drained.

> ⚠️ **`RunScheduler.updates` is an `AsyncStream`, and an `AsyncStream` does not multiplex.** Two
> concurrent `for await` loops draw from one 1024-element buffer, so each element is delivered to
> exactly one of them. There is exactly one consumer today — `AppModel.consumeSchedulerUpdates`
> (`AppModel.swift:815-822`), plus `RunsPaneLiveTests.swift:158` in the tests. A loop in auto-dev
> would silently split the events: roughly half the finished runs would never reach the board's UI
> and half would never reach the session, non-deterministically, with `swift build` clean and the
> whole suite green. That is why the hook is an explicitly-registered sink shaped like the
> `systemMover` the scheduler already holds — weak, for the same cycle-breaking reason.
>
> **Where it is called, and why there.** After `await pump()` at the very end of `finish`. By then
> the run row is saved (`:448`), the in-flight set is clear (`:419`), and the queue has been drained
> under the new occupancy — so a round triggered from here can never observe a half-written run or a
> queue that has not yet reconsidered itself.

- [ ] **Step 1: Write the failing test**

```swift
// Appended to ElliotKit/Tests/ElliotEngineTests/AutoDevServiceTests.swift

/// Counts triggers without being an actor's worth of machinery.
private final class CountingTrigger: RoundTriggering, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func triggerRound() async {
        lock.lock()
        count += 1
        lock.unlock()
    }

    var triggers: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
}

@Suite("Round triggering")
struct RoundTriggeringTests {

    @Test("A finished run tells the registered round trigger, without touching the stream")
    func finishedRunTriggersARound() async throws {
        // The one test in this plan that really spawns a child and really
        // **writes** a run log. Without this the log lands in the operator's own
        // `~/Library/Application Support/Elliot/runs` — the case `TestHome`'s
        // doc comment names outright.
        _ = TestHome.root
        let store = try BoardStore.inMemory()
        let config = ToolConfig(
            claudePath: "/usr/bin/true", ghPath: "/usr/bin/false",
            gitPath: "/usr/bin/false", environment: [:])
        let scheduler = RunScheduler(
            store: store, toolConfig: config, verifier: Verifier(gh: .init(config: config)))
        let trigger = CountingTrigger()
        await scheduler.setRoundTrigger(trigger)

        let repo = Repo(
            path: "/tmp/repo-\(UUID().uuidString)", nameWithOwner: "phmatray/Elliot",
            displayName: "Elliot")
        try await store.saveRepo(repo)
        let card = Card(
            repoID: repo.id, title: "Anything",
            columnEnteredAt: Date(), createdAt: Date(), updatedAt: Date())
        try await store.saveCard(card)
        let runID = UUID()
        let run = SkillRun.card(
            id: runID, cardID: card.id, repoID: repo.id, kind: .createIssue, prompt: "x",
            cwd: repo.path,
            logPath: StoreLocation.runLogURL(runID: runID).path,
            stderrPath: StoreLocation.runStderrURL(runID: runID).path, createdAt: Date())
        try await store.saveRun(run)
        await scheduler.launch(runID: run.id)

        // Bounded, and waiting on a condition rather than on a duration: the
        // child is `/usr/bin/true`, so this is milliseconds in practice.
        try await withTimeout(.seconds(20)) {
            while trigger.triggers == 0 { try await Task.sleep(for: .milliseconds(20)) }
        }
        #expect(trigger.triggers >= 1)
        #expect(try await store.run(id: run.id)?.state.isTerminal == true)
    }

    @Test("No trigger registered is not an error — the scheduler is unchanged without one")
    func noTriggerIsFine() async throws {
        let store = try BoardStore.inMemory()
        let config = ToolConfig(
            claudePath: "/usr/bin/true", ghPath: "/usr/bin/true",
            gitPath: "/usr/bin/true", environment: [:])
        let scheduler = RunScheduler(
            store: store, toolConfig: config, verifier: Verifier(gh: .init(config: config)))
        await scheduler.testOnlyDrain()
        #expect(await scheduler.queueSnapshot().isEmpty)
    }
}
```

`AutoDevServiceTests.swift` already imports `TestSupport` (Task 6), which is where `withTimeout`
lives.

- [ ] **Step 2: Run test to verify it fails**

Run: `cd ElliotKit && swift test --filter RoundTriggeringTests`

Expected: FAIL — `error: cannot find type 'RoundTriggering' in scope`.

- [ ] **Step 3: Write minimal implementation**

Create `ElliotKit/Sources/ElliotEngine/RoundTriggering.swift`:

```swift
import Foundation

/// Something that wants to re-evaluate whenever Elliot's own machinery moves.
///
/// Registered explicitly and held weakly, in the shape of the `SystemMoving` the
/// scheduler and the watcher already hold — for the same cycle-breaking reason,
/// and for one more.
///
/// ⚠️ `RunScheduler.updates` is an `AsyncStream`, and an `AsyncStream` does not
/// multiplex: two `for await` loops draw from one buffer, so each event reaches
/// exactly one of them. `AppModel` owns the only iteration. A second consumer
/// would split the events between the board's UI and this, silently and
/// non-deterministically, with everything green.
///
/// An implementation must be **idempotent and cheap to call twice**: several
/// events arrive per finished run, and nothing here promises a call per event.
public protocol RoundTriggering: AnyObject, Sendable {
    func triggerRound() async
}
```

`ElliotKit/Sources/ElliotEngine/RunScheduler.swift`, beside `systemMover` (`:64`):

```swift
    public weak var systemMover: (any SystemMoving)?
    /// Told after every finished run, once the row is written and the queue has
    /// drained. Weak, like `systemMover`: the holder owns the scheduler.
    public weak var roundTrigger: (any RoundTriggering)?
```

beside `setSystemMover` (`:89-91`):

```swift
    public func setRoundTrigger(_ trigger: any RoundTriggering) {
        roundTrigger = trigger
    }
```

and at the end of `finish` (`:448-453`):

```swift
        try? await store.saveRun(updated)
        continuation.yield(.runFinished(
            runID: run.id, cardID: updated.cardID, state: updated.state, outcome: verified
        ))
        await pump()
        // Last, deliberately. By here the row is written, the in-flight set is
        // clear and the queue has been reconsidered under the new occupancy, so
        // a round triggered from this call can never read a half-finished run or
        // a queue that has not yet had its say.
        await roundTrigger?.triggerRound()
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd ElliotKit && swift test --filter RoundTriggeringTests`

Expected: PASS — 2 tests.

- [ ] **Step 5: Commit**

```bash
cd /Users/phmatray/Repositories/phmatray/private/Elliot/.claude/worktrees/precious-beaming-wand
git rev-parse --abbrev-ref HEAD
git add ElliotKit/Sources/ElliotEngine/RoundTriggering.swift ElliotKit/Sources/ElliotEngine/RunScheduler.swift ElliotKit/Tests/ElliotEngineTests/AutoDevServiceTests.swift
git commit -m "feat(engine): a second sink for finished runs, because a stream does not multiplex"
```

---

### Task 10: `PRWatcher` — the hook, the backoff, and the reading a queued merge needs

**Files:**
- Modify: `ElliotKit/Sources/ElliotEngine/PRWatcher.swift:12-30` (the two hooks), `:48-98`
  (`tick`), `:144-161` (`refreshStatuses`)
- Test: `ElliotKit/Tests/ElliotEngineTests/AutoDevServiceTests.swift` (append)

**Interfaces:**
- Consumes: `RoundTriggering` (Task 9); `BoardStore.activeRuns(cardIDs:)`
  (`BoardStore.swift:762`); `SkillRun.kind`.
- Produces:
  - `PRWatcher.setRoundTrigger(_ trigger: any RoundTriggering)`
  - `PRWatcher.setSessionProbe(_ probe: @escaping @Sendable () async -> Bool)`
  - `PRWatcher.interval(sawChange:anyRunning:sessionRunning:quietRounds:) -> Duration` — `static`,
    pure, jitter applied by the caller
  - statuses refreshed for a card whose merge run is queued or running, not only for In Review

> **Three changes, and each has to earn its place.**
>
> 1. **The hook.** A card waiting on CI has no run to finish and no move to make, so nothing else
>    would ever wake its session. A round is a handful of local reads and is idempotent by contract,
>    so the tick calls it unconditionally.
> 2. **The backoff.** `tick()` widens the sleep to 300 s once nothing has moved for thirty rounds
>    (`:91-97`). Under a session that is waiting on CI, "nothing moved" is the normal state, so the
>    loop would put itself to sleep for five minutes exactly when it is working. A running session
>    caps the window at `idleInterval`; **the jitter is untouched** — it still wraps whatever the
>    rule returns, so several repositories still cannot fall into lockstep.
> 3. **The reading.** `commitMove` puts a card in Done *before* its merge run, and `refreshStatuses`
>    reads In Review only — so the instant a merge is queued its reading stops being refreshed, and
>    Task 7's admission guard starts demanding a current one. Without this the refusal would be
>    permanent and no busy repository would ever merge unattended. `.inReview`'s own reason
>    ("a card in In Progress has a draft pull request that `implement-issue` is still writing") is
>    unaffected: this adds a second, narrower set, it does not widen the first.
>
> ⛔ The **reconcile** loop is deliberately *not* widened to those cards. `VerifiedOutcome.applied`
> clears `lastError` on `.prOpen`, so reconciling a Done card whose merge failed would wipe the
> banner explaining why — the one surface a failed session has.

- [ ] **Step 1: Write the failing test**

```swift
// Appended to ElliotKit/Tests/ElliotEngineTests/AutoDevServiceTests.swift

@Suite("PR watcher — what a session needs from it")
struct PRWatcherForSessionsTests {

    @Test("A running session stops the quiet backoff widening past the idle window")
    func sessionCapsTheBackoff() {
        // Sixty quiet rounds is well past the widening threshold of thirty.
        let widened = PRWatcher.interval(
            sawChange: false, anyRunning: false, sessionRunning: false, quietRounds: 60)
        let capped = PRWatcher.interval(
            sawChange: false, anyRunning: false, sessionRunning: true, quietRounds: 60)
        #expect(widened > capped)
        #expect(capped == .seconds(60))
    }

    @Test("Everything else about the interval is exactly what it was")
    func theRestIsUnchanged() {
        #expect(
            PRWatcher.interval(
                sawChange: false, anyRunning: true, sessionRunning: false, quietRounds: 0)
                == .seconds(15))
        #expect(
            PRWatcher.interval(
                sawChange: true, anyRunning: false, sessionRunning: false, quietRounds: 0)
                == .seconds(60))
        #expect(
            PRWatcher.interval(
                sawChange: false, anyRunning: false, sessionRunning: false, quietRounds: 1)
                == .seconds(60))
        // The widening: << 1 at 30 quiet rounds, << 3 and then the 300 s ceiling.
        #expect(
            PRWatcher.interval(
                sawChange: false, anyRunning: false, sessionRunning: false, quietRounds: 30)
                == .seconds(120))
        #expect(
            PRWatcher.interval(
                sawChange: false, anyRunning: false, sessionRunning: false, quietRounds: 120)
                == .seconds(300))
    }

    @Test("A tick tells the round trigger, so a card waiting on CI is re-evaluated")
    func tickTriggersARound() async throws {
        let store = try BoardStore.inMemory()
        let config = ToolConfig(
            claudePath: "/usr/bin/true", ghPath: "/usr/bin/false",
            gitPath: "/usr/bin/false", environment: [:])
        let board = BoardService(store: store, launcher: FakeLauncher())
        let watcher = PRWatcher(store: store, gh: .init(config: config), mover: board)
        let trigger = CountingTrigger()
        await watcher.setRoundTrigger(trigger)

        await watcher.tick()
        #expect(trigger.triggers == 1)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd ElliotKit && swift test --filter PRWatcherForSessionsTests`

Expected: FAIL — `error: type 'PRWatcher' has no member 'interval'`.

- [ ] **Step 3: Write minimal implementation**

`ElliotKit/Sources/ElliotEngine/PRWatcher.swift` — the three private constants at `:22-24` become
`static let`, and two hooks join `mover`:

```swift
    /// Fast while something is running — the card should reach In Review the
    /// moment implement-issue flips its PR ready.
    static let busyInterval: Duration = .seconds(15)
    static let idleInterval: Duration = .seconds(60)
    static let maxInterval: Duration = .seconds(300)

    /// Told once per sweep. A card waiting on CI has no run to finish and no
    /// move to make, so without this nothing would ever wake its session.
    private weak var roundTrigger: (any RoundTriggering)?
    /// Whether anything unattended is going on right now.
    ///
    /// A closure and not a protocol: it is one boolean with one caller, and a
    /// test needs `{ true }` rather than a double. Install it with a `[weak]`
    /// capture — nothing here should keep a session alive.
    private var sessionProbe: (@Sendable () async -> Bool)?

    public func setRoundTrigger(_ trigger: any RoundTriggering) {
        roundTrigger = trigger
    }

    public func setSessionProbe(_ probe: @escaping @Sendable () async -> Bool) {
        sessionProbe = probe
    }
```

Replace `tick()` (`:48-98`) with:

```swift
    /// One sweep. Returns how long to wait before the next.
    @discardableResult
    func tick() async -> Duration {
        guard let repos = try? await store.repos() else { return Self.idleInterval }
        var sawChange = false
        var anyRunning = false

        for repo in repos where repo.isEnabled {
            let all = (try? await store.cards(repoID: repo.id)) ?? []
            // A card whose merge is queued has already left In Review —
            // `commitMove` moves it to Done *before* the run — so its reading
            // would stop being refreshed at the exact moment admission starts
            // demanding a current one. One query per repository per tick.
            let mergePending = Set(
                ((try? await store.activeRuns(cardIDs: all.map(\.id))) ?? [:])
                    .filter { $0.value.kind == .mergePR }
                    .keys)
            let watched = all.filter { $0.column == .inProgress || $0.column == .inReview }
            guard !watched.isEmpty || !mergePending.isEmpty else { continue }

            if let runs = try? await store.runs(repoID: repo.id, limit: 20),
               runs.contains(where: { $0.state.isActive }) {
                anyRunning = true
            }

            guard let prs = try? await gh.pullRequests(repo: repo.nameWithOwner, limit: 100) else {
                continue
            }
            var movedHere = false
            for card in watched where await reconcile(card: card, against: prs) {
                sawChange = true
                movedHere = true
            }
            // Re-read rather than reuse the snapshot when this repository's
            // cards moved: `reconcile` above may have just promoted one. With
            // the stale snapshot a card that reached In Review this very tick
            // was skipped until the next one, and a card promoted *out* of it
            // still spent a call and wrote a row for a pull request already
            // merged.
            //
            // Local rather than the accumulating `sawChange`: that one is true
            // as soon as *any* repository moved, and would re-read every
            // repository after it for nothing.
            let settled = movedHere ? (try? await store.cards(repoID: repo.id)) ?? all : all
            await refreshStatuses(repo: repo, cards: settled, alsoRead: mergePending, prs: prs)
        }

        if sawChange || anyRunning {
            quietRounds = 0
        } else {
            quietRounds += 1
        }

        // Unconditional: a round is a handful of local reads and is idempotent
        // by contract, so a tick that changed nothing costs a no-op — and a
        // session whose only card is waiting on CI has no other event at all.
        await roundTrigger?.triggerRound()

        let sessionRunning = await sessionProbe?() ?? false
        return jittered(
            Self.interval(
                sawChange: sawChange, anyRunning: anyRunning,
                sessionRunning: sessionRunning, quietRounds: quietRounds))
    }

    /// How long to wait before the next sweep, before jitter.
    ///
    /// Pure and static so the rule is testable without a clock: `tick()`
    /// measures, this decides, and `jittered` still wraps whatever comes back —
    /// several repositories must not fall into lockstep.
    ///
    /// `sessionRunning` caps the window at `idleInterval`. Under an unattended
    /// session "nothing moved" is the *normal* state — the cards are waiting on
    /// CI — so the quiet backoff would put the watcher to sleep for five minutes
    /// exactly when it is working.
    static func interval(
        sawChange: Bool, anyRunning: Bool, sessionRunning: Bool, quietRounds: Int
    ) -> Duration {
        if sawChange || anyRunning {
            return anyRunning ? busyInterval : idleInterval
        }
        let widened = min(
            idleInterval.components.seconds << min(quietRounds / 30, 3),
            maxInterval.components.seconds
        )
        let ceiling = sessionRunning
            ? idleInterval.components.seconds : maxInterval.components.seconds
        return .seconds(min(widened, ceiling))
    }
```

And `refreshStatuses` (`:144-161`) takes the second set, and states the second half of its own rule:

```swift
    /// Reads what GitHub says about the pull requests the board is *waiting* on.
    ///
    /// **In Review, and any card whose merge is queued or running.** The first
    /// half is the original rule and its reason stands: a card in In Progress
    /// has a draft pull request that `implement-issue` is still writing, so a
    /// red check there is a transient state the run is already handling.
    ///
    /// The second half exists because `BoardService.commitMove` puts a card in
    /// Done *before* its merge run, so the instant a merge is queued this would
    /// stop refreshing it — while admission refuses a merge whose green has aged
    /// past `PRStatus.maximumAge`. Without it that refusal is permanent, and a
    /// repository an unattended session keeps busy never merges anything.
    ///
    /// What this still does **not** do is touch the card: card fields are decided
    /// in one place, `VerifiedOutcome.applied(to:)`, and a poller that wrote one
    /// would be the second write path that invariant exists to prevent.
    private func refreshStatuses(
        repo: Repo, cards: [Card], alsoRead: Set<UUID>, prs: [GHPullRequest]
    ) async {
        let now = Date()
        for card in cards where card.column == .inReview || alsoRead.contains(card.id) {
            guard let number = card.prNumber else { continue }
            let currentHead = prs.first { $0.number == number }?.headRefOid
            let stored = try? await store.prStatus(repoID: repo.id, prNumber: number)
            guard PRStatus.needsRefresh(stored: stored ?? nil, currentHeadOid: currentHead, now: now)
            else { continue }

            // A failed read writes nothing and erases nothing: the previous row
            // stands and ages out on its own, which reports "not established"
            // rather than inventing either a pass or a failure.
            guard let status = try? await gh.mergeStatus(repo: repo.nameWithOwner, number: number)
            else { continue }
            try? await store.savePRStatus(
                status.prStatus(repoID: repo.id, prNumber: number, checkedAt: now))
        }
    }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd ElliotKit && swift test --filter PRWatcherForSessionsTests`

Expected: PASS — 3 tests. Then `cd ElliotKit && swift test --filter PRWatcherStatusTests`, PASS
unchanged — its harness has no runs, so `alsoRead` is empty and every `pr view` count is what it was.

- [ ] **Step 5: Commit**

```bash
cd /Users/phmatray/Repositories/phmatray/private/Elliot/.claude/worktrees/precious-beaming-wand
git rev-parse --abbrev-ref HEAD
git add ElliotKit/Sources/ElliotEngine/PRWatcher.swift ElliotKit/Tests/ElliotEngineTests/AutoDevServiceTests.swift
git commit -m "feat(engine): keep reading a pull request while its merge waits to be admitted"
```

---

### Task 11: `AutoDevService.start` — the guards that belong to the act

**Files:**
- Create: `ElliotKit/Sources/ElliotEngine/AutoDevService.swift`
- Modify: `ElliotKit/Sources/ElliotIPC/Protocol.swift:201`
- Test: `ElliotKit/Tests/ElliotEngineTests/AutoDevServiceTests.swift` (append)

**Interfaces:**
- Consumes: `AutoDevSession`, `AutoDevCardState` (Task 3); `BoardStore.saveAutoDevSession(_:cards:)`
  and `BoardStore.spendCeiling()` (`BoardStore.swift:195`); `PreflightService.isBlocking(_:)`
  (`PreflightService.swift:429-431`); `RunQueueReading` (Task 8); `RoundTriggering` (Task 9).
- Produces:
  - `public enum AutoDevError: Error, LocalizedError, Equatable` — `repoNotFound` · `repoDisabled` ·
    `repoBlocked` · `noCards` · `foreignCard` · `noDailySpendCeiling`
  - `AutoDevError.response: (code: ElliotErrorCode, message: String, hint: String?)`
  - `ElliotErrorCode.autoDevRefused = "auto_dev_refused"`
  - `public actor AutoDevService`, with
    `init(store:board:launcher:queue:clock:)` — `clock: @escaping @Sendable () -> Date = { Date() }`
  - `AutoDevService.start(session:preflightChecks:) async throws -> AutoDevSession`
  - `AutoDevService.hasRunningSession() async -> Bool`
  - `AutoDevService.advance() async` — declared here as a no-op body, filled in by Task 12

> 🔴 **Cross-plan: PR6 already moved this exact rule into one place, and this task writes a fourth
> copy of it.** PR6's Task 12 creates `ElliotModel/UnattendedStartRefusal.swift` —
> `refusal(repo: Repo, preflightBlocks: Bool) -> UnattendedStartRefusal?`, with cases
> `noRepositoryChosen | repoDisabled | preflightBlocked` and a `sentence` — precisely because *"an
> appraisal passes through no transition, so `evaluateMove`, `allowsSideEffects` and `repoPreflight`
> never see it"*. Its Task 13 then adds the `RepoGating` / `PreflightGate` / `OpenGate` seam in
> `ElliotEngine` and gives `AnalysisService.init` a `gate:` parameter with **no default**, so that
> every construction states its answer. The spec's words are *"one rule, one implementation, three
> callers"*.
>
> **`AutoDevService.start` is the fourth unattended-start site in the system, and PR6 lands before
> this one.** The two guards below — `guard repo.isEnabled` and
> `guard !PreflightService.isBlocking(preflightChecks)` — are that rule, hand-written again, in the
> one place where getting it wrong fires `claude -p --permission-mode bypassPermissions` N times
> into a repository Preflight refused. Rewrite them as:
>
> ```swift
>         if let refusal = UnattendedStartRefusal.refusal(
>             repo: repo, preflightBlocks: PreflightService.isBlocking(preflightChecks)
>         ) {
>             throw AutoDevError.repoRefused(refusal)
>         }
> ```
>
> and collapse `AutoDevError.repoDisabled` and `.repoBlocked` into one
> `repoRefused(UnattendedStartRefusal)` — exactly what PR6's Task 13 does to
> `AnalysisError.repoDisabled`. The tests at Task 11 that name `.repoDisabled("Elliot")` and
> `.repoBlocked("Elliot")` move with it. ⚠️ Keep `preflightChecks` as a **parameter** rather than
> adopting `RepoGating` here: the reason below still stands, and PR6's `PreflightGate` reads the
> checks itself, which a caller that has already run Preflight should not pay for twice. **This is
> an arbitration, not a mechanical edit** — measure first with
> `ls ElliotKit/Sources/ElliotModel/UnattendedStartRefusal.swift`.

> **Why the Preflight gate is here and not in `AppModel`.** A `.disabled()` on a button is exactly
> the shape #151 nearly shipped, and it does not reach a session started any other way. The gate
> belongs on the **act**. `PreflightService.isBlocking` is already static and already the rule the
> Repositories page applies, so the checks are passed in as a value rather than the service
> constructing a `PreflightService` (which needs a captured login shell and would make this
> untestable in `swift test`).
>
> **Why a session refuses to start without a daily ceiling.** `SpendCeiling.swift:5-12` records what
> the brake was sized against: "a drag spawns an unattended agent under `bypassPermissions`, and
> until this existed there was no upper bound on what a gesture cost". A session removes the
> gesture. Without `perDayUSD` there is nothing at all between a loop and the meter.
>
> **On `ElliotErrorCode.autoDevRefused`.** PR4 ships no wire case and no MCP tool, so **nothing can
> put this string on the wire** and `elliotProtocolVersion` stays 6 — the same argument PR1 makes
> about `MoveOrigin`. It is added now so the mapping lives beside the error it maps rather than
> being invented in a `catch` later, the way the `AnalysisError` mapping is written out at
> `MCPRequestHandler.swift:130-155`.

- [ ] **Step 1: Write the failing test**

```swift
// Appended to ElliotKit/Tests/ElliotEngineTests/AutoDevServiceTests.swift

@Suite("Auto-dev — starting")
struct AutoDevStartTests {

    private let epoch = Date(timeIntervalSince1970: 1_770_000_000)

    private struct Fixture {
        var store: BoardStore
        var board: BoardService
        var launcher: FakeLauncher
        /// Here only as the `RunQueueReading` the service reads. It launches
        /// nothing — see the comment in `fixture()`.
        var scheduler: RunScheduler
        var service: AutoDevService
        var repo: Repo
        var cards: [Card]
    }

    private func fixture(dailyCeiling: Double? = 25) async throws -> Fixture {
        // `TestHome` first: `start` ends by calling `advance()`, and from Task 12
        // on that round commits moves, which resolve `StoreLocation` run paths.
        _ = TestHome.root
        let store = try BoardStore.inMemory()
        let config = ToolConfig(
            claudePath: "/usr/bin/true", ghPath: "/usr/bin/false",
            gitPath: "/usr/bin/false", environment: [:])
        // The board launches through a **fake**, and the real scheduler is here
        // only to answer `RunQueueReading`. This suite is about what `start`
        // refuses; once Task 12 fills in `advance()`, a real launcher would have
        // it spawning `/usr/bin/true` children as a side effect of testing a
        // guard, and admission is Task 7's subject, not this one's.
        let launcher = FakeLauncher()
        let scheduler = RunScheduler(
            store: store, toolConfig: config, verifier: Verifier(gh: .init(config: config)))
        let board = BoardService(store: store, launcher: launcher)
        if let dailyCeiling {
            try await store.saveSpendCeiling(SpendCeiling(perRunUSD: nil, perDayUSD: dailyCeiling))
        }
        let repo = Repo(
            path: "/tmp/repo-\(UUID().uuidString)", nameWithOwner: "phmatray/Elliot",
            displayName: "Elliot")
        try await store.saveRepo(repo)
        var cards: [Card] = []
        for index in 0..<2 {
            cards.append(try await board.createCard(
                repoID: repo.id, title: "Card \(index)",
                story: UserStory(
                    role: "developer", want: "thing \(index)", benefit: "a reason")).card)
        }
        let service = AutoDevService(
            store: store, board: board, launcher: launcher, queue: scheduler,
            clock: { self.epoch })
        return Fixture(
            store: store, board: board, launcher: launcher, scheduler: scheduler,
            service: service, repo: repo, cards: cards)
    }

    private func session(_ f: Fixture, cards: [UUID]? = nil) -> AutoDevSession {
        AutoDevSession(
            repoID: f.repo.id, engagedCardIDs: cards ?? f.cards.map(\.id),
            maxAttemptsPerCard: 2, patience: 900, startedAt: epoch)
    }

    private let passing = [CheckResult(id: "x", title: "x", status: .pass, detail: "")]
    private let failing = [CheckResult(id: "x", title: "x", status: .fail, detail: "")]

    @Test("A started session persists itself and a row per engaged card, in one write")
    func startPersists() async throws {
        let f = try await fixture()
        let started = try await f.service.start(
            session: session(f), preflightChecks: passing)

        #expect(started.state == .running)
        #expect(try await f.store.autoDevSession(id: started.id)?.engagedCardIDs.count == 2)
        let rows = try await f.store.autoDevCards(sessionID: started.id)
        #expect(rows.count == 2)
        #expect(Set(rows.map(\.cardID)) == Set(f.cards.map(\.id)))
        // Deliberately **not** an assertion about `attempts`. `start` ends by
        // calling `advance()`, so from Task 12 on the first round has already
        // run by the time these rows are read and both cards have spent one.
        // What `start` promises is the *set* — a row for every engaged card,
        // written with the session in one transaction — and that is what this
        // test is named for. What a round does to `attempts` is Task 12's.
    }

    @Test("A repository Preflight blocks refuses the whole session, by name")
    func preflightBlocks() async throws {
        let f = try await fixture()
        await #expect(throws: AutoDevError.repoBlocked("Elliot")) {
            try await f.service.start(session: session(f), preflightChecks: failing)
        }
        #expect(try await f.store.runningAutoDevSessions().isEmpty)
    }

    @Test("A disabled repository refuses the whole session too")
    func disabledRepoRefuses() async throws {
        let f = try await fixture()
        var repo = f.repo
        repo.isEnabled = false
        try await f.store.saveRepo(repo)
        await #expect(throws: AutoDevError.repoDisabled("Elliot")) {
            try await f.service.start(session: session(f), preflightChecks: passing)
        }
    }

    @Test("No daily ceiling, no session — the brake was sized against a human's rhythm")
    func noCeilingRefuses() async throws {
        let f = try await fixture(dailyCeiling: nil)
        await #expect(throws: AutoDevError.noDailySpendCeiling) {
            try await f.service.start(session: session(f), preflightChecks: passing)
        }
    }

    @Test("A card from another repository is refused rather than quietly dropped")
    func foreignCardRefuses() async throws {
        let f = try await fixture()
        let other = Repo(
            path: "/tmp/other-\(UUID().uuidString)", nameWithOwner: "phmatray/Other",
            displayName: "Other")
        try await f.store.saveRepo(other)
        let stranger = try await f.board.createCard(repoID: other.id, title: "Elsewhere").card

        await #expect(throws: AutoDevError.foreignCard(stranger.id)) {
            try await f.service.start(
                session: session(f, cards: f.cards.map(\.id) + [stranger.id]),
                preflightChecks: passing)
        }
    }

    @Test("An empty engagement is refused, because a session with nothing to do is a mistake")
    func emptyRefuses() async throws {
        let f = try await fixture()
        await #expect(throws: AutoDevError.noCards) {
            try await f.service.start(session: session(f, cards: []), preflightChecks: passing)
        }
    }

    @Test("The same card twice is one engagement, not two")
    func duplicatesAreOne() async throws {
        let f = try await fixture()
        let started = try await f.service.start(
            session: session(f, cards: [f.cards[0].id, f.cards[0].id]),
            preflightChecks: passing)
        #expect(started.engagedCardIDs == [f.cards[0].id])
        #expect(try await f.store.autoDevCards(sessionID: started.id).count == 1)
    }

    @Test("Every refusal has a wire code and a next action")
    func refusalsMapToTheWire() {
        for error: AutoDevError in [
            .repoNotFound(UUID()), .repoDisabled("Elliot"), .repoBlocked("Elliot"),
            .noCards, .foreignCard(UUID()), .noDailySpendCeiling,
        ] {
            let response = error.response
            #expect(response.message.isEmpty == false)
            #expect(response.hint?.isEmpty == false)
        }
        #expect(AutoDevError.repoBlocked("Elliot").response.code == .autoDevRefused)
        #expect(AutoDevError.repoNotFound(UUID()).response.code == .repoNotFound)
        #expect(ElliotErrorCode.autoDevRefused.rawValue == "auto_dev_refused")
    }
}
```

The file needs `import ElliotIPC` added to its header for `ElliotErrorCode`.

- [ ] **Step 2: Run test to verify it fails**

Run: `cd ElliotKit && swift test --filter AutoDevStartTests`

Expected: FAIL — `error: cannot find 'AutoDevService' in scope`.

- [ ] **Step 3: Write minimal implementation**

`ElliotKit/Sources/ElliotIPC/Protocol.swift`, beside `analysisRefused` (`:201`):

```swift
    /// An unattended session refused to start: the repository is blocked, or no
    /// daily spending ceiling is set. Shaped like `analysisRefused`, and for the
    /// same reason — the caller can act on it, so it is not an internal error.
    case autoDevRefused = "auto_dev_refused"
```

Create `ElliotKit/Sources/ElliotEngine/AutoDevService.swift`:

```swift
import ElliotIPC
import ElliotModel
import ElliotStore
import Foundation

public enum AutoDevError: Error, LocalizedError, Equatable {
    case repoNotFound(UUID)
    case repoDisabled(String)
    case repoBlocked(String)
    case noCards
    case foreignCard(UUID)
    case noDailySpendCeiling

    public var errorDescription: String? {
        switch self {
        case .repoNotFound(let id): "No repository with id \(id)."
        case .repoDisabled(let name): "\(name) is disabled in Elliot."
        case .repoBlocked(let name):
            "A Preflight check is failing for \(name), so nothing may run there unattended."
        case .noCards: "Pick at least one card for the session to work on."
        case .foreignCard(let id):
            "Card \(id) belongs to another repository; a session works on one repository."
        case .noDailySpendCeiling:
            "Set a daily spending ceiling before starting an unattended session."
        }
    }

    /// The wire code and the next action, shaped like the `AnalysisError`
    /// mapping written out at `MCPRequestHandler.swift:130-155`.
    ///
    /// Here rather than in a `catch` because **no request raises it yet** — PR4
    /// ships no wire case and no MCP tool — and a mapping that lives beside the
    /// error cannot drift from it while it waits for one. Nothing can put
    /// `auto_dev_refused` on the wire, so `elliotProtocolVersion` stays 6.
    public var response: (code: ElliotErrorCode, message: String, hint: String?) {
        switch self {
        case .repoNotFound:
            (.repoNotFound, errorDescription ?? "", "board_list_repos lists the repositories Elliot drives.")
        case .repoDisabled:
            (.autoDevRefused, errorDescription ?? "", "Enable the repository in Elliot's Preflight screen.")
        case .repoBlocked:
            (.autoDevRefused, errorDescription ?? "", "Fix the failing check in Preflight, then start again.")
        case .noCards:
            (.autoDevRefused, errorDescription ?? "", "Engage at least one Backlog card.")
        case .foreignCard:
            (.autoDevRefused, errorDescription ?? "", "Start one session per repository.")
        case .noDailySpendCeiling:
            (.autoDevRefused, errorDescription ?? "",
             "Set a daily ceiling in Preflight. A session removes the human rhythm the per-run brake was sized against.")
        }
    }
}

/// The board driving its own cards.
///
/// Advancing is **re-evaluation, not progression**: on every event the session
/// walks its unsettled cards and asks `BoardService` what the next move would
/// mean, exactly as a drag would. Nothing is remembered between rounds — there
/// is no cursor saying "this card is at step 3" — which is what makes resuming
/// after a crash trivial: there is no state to rebuild.
///
/// It spawns nothing. Every run it causes goes through `launcher.launch` →
/// `pump()` → `refusal(for:)`, so `SchedulerLimits`, `SpendCeiling` and the
/// repository-exclusion rules bind it exactly as they bind a drag.
///
/// ## Reentrancy
///
/// This actor calls `BoardService`, which calls `RunScheduler`, which calls back
/// here through `RoundTriggering`. Swift actors are reentrant and never block,
/// so the cycle cannot deadlock; what it can do is interleave two rounds at
/// every `await`. Three things contain that, and all three are load-bearing:
///
/// - a round is **coalesced** — a trigger arriving while one is running sets a
///   flag and returns, and the runner loops until the flag is clear, so at most
///   one round is ever in flight;
/// - a round **re-reads** its state from the store rather than carrying rows
///   across an `await`, so an interleaved write cannot be lost;
/// - the scheduler notifies **after** it has persisted the run and drained the
///   queue, so a round never observes a half-written run.
///
/// The references out are the ones that already exist in this shape:
/// `RunScheduler.systemMover` and `PRWatcher.mover` are weak for the same
/// cycle-breaking reason, and the hooks that point back here are weak too.
public actor AutoDevService: RoundTriggering {
    private let store: BoardStore
    private let board: BoardService
    private let launcher: any RunLaunching
    private let queue: any RunQueueReading
    /// The clock, injected — the idiom of `PRStatus.resolved(now:)`. Every
    /// patience window in a test is expressed by moving this, never by sleeping.
    private let clock: @Sendable () -> Date

    private var roundInFlight = false
    private var roundRequested = false

    public init(
        store: BoardStore,
        board: BoardService,
        launcher: any RunLaunching,
        queue: any RunQueueReading,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.store = store
        self.board = board
        self.launcher = launcher
        self.queue = queue
        self.clock = clock
    }

    // MARK: - Starting

    @discardableResult
    public func start(
        session: AutoDevSession, preflightChecks: [CheckResult]
    ) async throws -> AutoDevSession {
        guard let repo = try await store.repo(id: session.repoID) else {
            throw AutoDevError.repoNotFound(session.repoID)
        }
        guard repo.isEnabled else { throw AutoDevError.repoDisabled(repo.displayName) }
        // On the act, not on a button. A `.disabled()` is the shape #151 nearly
        // shipped, and it does not reach a session started any other way.
        guard !PreflightService.isBlocking(preflightChecks) else {
            throw AutoDevError.repoBlocked(repo.displayName)
        }
        // `SpendCeiling.swift:5-12` says the brake was sized against the rhythm
        // of a human dragging cards. A session removes that assumption.
        guard (try await store.spendCeiling())?.perDayUSD != nil else {
            throw AutoDevError.noDailySpendCeiling
        }

        // Ordered-unique: naming a card twice is a slip, not a request for two
        // engagements — the same reading `AnalysisService.start` gives angles.
        var engaged: [UUID] = []
        for id in session.engagedCardIDs where !engaged.contains(id) { engaged.append(id) }
        guard !engaged.isEmpty else { throw AutoDevError.noCards }
        for id in engaged {
            guard let card = try await store.card(id: id), card.repoID == session.repoID else {
                throw AutoDevError.foreignCard(id)
            }
        }

        let now = clock()
        var opened = session
        opened.engagedCardIDs = engaged
        opened.state = .running
        opened.startedAt = now
        opened.endedAt = nil

        let rows = engaged.map {
            AutoDevCardState(
                sessionID: opened.id, cardID: $0, attempts: 0,
                disposition: .wait, reason: "Not started yet.", updatedAt: now)
        }
        // One transaction, the shape and the reason of
        // `AnalysisService.saveAnalysis(_:runs:)`: a session with fewer cards
        // than it was started with is a promise that quietly shrank.
        try await store.saveAutoDevSession(opened, cards: rows)

        await advance()
        return opened
    }

    /// Whether anything unattended is going on — what `PRWatcher` asks before it
    /// widens its own backoff.
    public func hasRunningSession() async -> Bool {
        !(((try? await store.runningAutoDevSessions()) ?? []).isEmpty)
    }

    // MARK: - RoundTriggering

    public func triggerRound() async {
        await advance()
    }

    /// One coalesced pass over every running session. Filled in by the next
    /// task; a no-op here so `start` has something to call.
    public func advance() async {}
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd ElliotKit && swift test --filter AutoDevStartTests`

Expected: PASS — 8 tests.

- [ ] **Step 5: Commit**

```bash
cd /Users/phmatray/Repositories/phmatray/private/Elliot/.claude/worktrees/precious-beaming-wand
git rev-parse --abbrev-ref HEAD
git add ElliotKit/Sources/ElliotEngine/AutoDevService.swift ElliotKit/Sources/ElliotIPC/Protocol.swift ElliotKit/Tests/ElliotEngineTests/AutoDevServiceTests.swift
git commit -m "feat(engine,ipc): a session refuses to start where nothing should run unattended"
```

---

### Task 12: One round — re-evaluation, coalesced, with the merges serialised

**Files:**
- Modify: `ElliotKit/Sources/ElliotEngine/AutoDevService.swift` (replace the `advance()` stub)
- Test: `ElliotKit/Tests/ElliotEngineTests/AutoDevServiceTests.swift` (append)

**Interfaces:**
- Consumes: `AutoDevPolicy.disposition(outcome:reading:attempts:maxAttempts:unchangedSince:patience:now:)`
  and `AutoDevPolicy.held(_:unchangedSince:patience:now:)` (Task 4);
  `MoveProposal.prVerdict` (Task 6); `RunQueueReading` (Task 8);
  `BoardStore.activeRuns(cardIDs:)` (`BoardStore.swift:762`);
  `BoardStore.runs(cardID:limit:)` (`:711`, newest first).
- Produces:
  - `AutoDevService.advance() async` — the coalescer, safe to call from any actor, idempotent
  - `AutoDevService.finish(_:)` — marks a session `.finished` (Task 13 gives it the cancellations)
  - the per-card rule, and `attempts` counting **runs started**, never rounds taken

- [ ] **Step 1: Write the failing test**

```swift
// Appended to ElliotKit/Tests/ElliotEngineTests/AutoDevServiceTests.swift

/// A queue that answers without a scheduler, so a round is decided by what the
/// test says is holding a run rather than by what a real drain happened to do.
private actor FakeQueue: RunQueueReading {
    private var paused = false
    private var rows: [QueuedRun] = []

    func queueIsPaused() async -> Bool { paused }
    func queueSnapshot() async -> [QueuedRun] { rows }
    func setPaused(_ value: Bool) { paused = value }
    func setRows(_ value: [QueuedRun]) { rows = value }
}

/// A clock a test can move, and that the actor can read from any isolation.
///
/// At file scope rather than nested in one suite: Task 13 needs it too, and a
/// `private` type nested inside `AutoDevRoundTests` is not reachable from a
/// sibling suite in the same file.
private final class LockedDate: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date
    init(_ value: Date) { self.value = value }
    var date: Date {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
    func advance(by seconds: TimeInterval) {
        lock.lock()
        value = value.addingTimeInterval(seconds)
        lock.unlock()
    }
}

@Suite("Auto-dev — one round")
struct AutoDevRoundTests {

    private let epoch = Date(timeIntervalSince1970: 1_770_000_000)

    private struct Fixture {
        var store: BoardStore
        var board: BoardService
        var launcher: FakeLauncher
        var queue: FakeQueue
        var repo: Repo
        /// Moves the injected clock. A patience window is expressed by moving
        /// this, never by sleeping.
        var now: LockedDate
    }

    private func fixture() async throws -> (Fixture, AutoDevService) {
        // Every round below commits moves, which resolve `StoreLocation` run
        // paths — so the shared home has to be final before the first one.
        _ = TestHome.root
        let store = try BoardStore.inMemory()
        let launcher = FakeLauncher()
        let queue = FakeQueue()
        let board = BoardService(store: store, launcher: launcher)
        try await store.saveSpendCeiling(SpendCeiling(perRunUSD: nil, perDayUSD: 25))
        let repo = Repo(
            path: "/tmp/repo-\(UUID().uuidString)", nameWithOwner: "phmatray/Elliot",
            displayName: "Elliot")
        try await store.saveRepo(repo)
        let now = LockedDate(epoch)
        let service = AutoDevService(
            store: store, board: board, launcher: launcher, queue: queue,
            clock: { now.date })
        return (
            Fixture(
                store: store, board: board, launcher: launcher, queue: queue, repo: repo, now: now),
            service
        )
    }

    private func story(_ index: Int) -> UserStory {
        UserStory(role: "developer", want: "thing \(index)", benefit: "a reason")
    }

    private let passing = [CheckResult(id: "x", title: "x", status: .pass, detail: "")]

    @Test("A round moves a Backlog card and files its issue, and counts one attempt")
    func aRoundAdvances() async throws {
        let (f, service) = try await fixture()
        let card = try await f.board.createCard(
            repoID: f.repo.id, title: "One", story: story(1)).card
        let started = try await service.start(
            session: AutoDevSession(
                repoID: f.repo.id, engagedCardIDs: [card.id], maxAttemptsPerCard: 2,
                patience: 900, startedAt: epoch),
            preflightChecks: passing)

        #expect(try await f.store.card(id: card.id)?.column == .todo)
        let run = try #require(try await f.store.runs(cardID: card.id).first)
        #expect(run.kind == .createIssue)
        #expect(await f.launcher.launchedRuns() == [run.id])

        let row = try #require(try await f.store.autoDevCards(sessionID: started.id).first)
        #expect(row.attempts == 1)

        // The audit says who asked, and it is the session.
        let audits = try await f.store.audits(cardID: card.id)
        #expect(audits.first?.origin == .autoDev(sessionID: started.id))
    }

    @Test("A card its own run is holding waits, and spends no second attempt")
    func aHeldCardWaits() async throws {
        let (f, service) = try await fixture()
        let card = try await f.board.createCard(
            repoID: f.repo.id, title: "One", story: story(1)).card
        let started = try await service.start(
            session: AutoDevSession(
                repoID: f.repo.id, engagedCardIDs: [card.id], maxAttemptsPerCard: 2,
                patience: 900, startedAt: epoch),
            preflightChecks: passing)

        await service.advance()
        let row = try #require(try await f.store.autoDevCards(sessionID: started.id).first)
        #expect(row.attempts == 1)
        #expect(row.disposition == .wait)
        #expect(try await f.store.runs(cardID: card.id).count == 1)
    }

    @Test("Nothing else in a session starts while one of its merges is pending")
    func mergesAreSerialised() async throws {
        let (f, service) = try await fixture()
        // One card ready to merge, one ready to be implemented.
        var merging = try await f.board.createCard(repoID: f.repo.id, title: "Merging").card
        merging.column = .inReview
        merging.issueNumber = 47
        merging.prNumber = 52
        try await f.store.saveCard(merging)
        // ⚠️ `checkedAt: Date()`, **never** `epoch`. The session's clock is
        // injected and frozen at `epoch`, but the *verdict* is resolved against
        // the wall clock inside `BoardService` — `epoch` is months old, so
        // `resolved(now:)` would call the reading stale, the decision would be
        // `.notVerifiedGreen(sign: nil)`, and no merge would ever be queued.
        try await f.store.savePRStatus(
            PRStatus(
                repoID: f.repo.id, prNumber: 52, headRefOid: "a1b2c3", checkedAt: Date(),
                rawMergeStateStatus: "CLEAN", rawMergeable: "MERGEABLE", rawReviewDecision: "",
                checks: [GHMergeStatus.StatusCheck(
                    name: "build-and-test", conclusion: "SUCCESS", status: "COMPLETED")]))

        var waiting = try await f.board.createCard(repoID: f.repo.id, title: "Waiting").card
        waiting.column = .todo
        waiting.issueNumber = 48
        try await f.store.saveCard(waiting)

        let started = try await service.start(
            session: AutoDevSession(
                repoID: f.repo.id, engagedCardIDs: [merging.id, waiting.id],
                maxAttemptsPerCard: 2, patience: 900, startedAt: epoch),
            preflightChecks: passing)

        // The merge was queued; the implement-issue was not started beside it.
        // `pump()` steps over a refused run and admits the next, so anything
        // running here is one more thing `.mergeWaitsForRepoToBeIdle` waits for.
        #expect(try await f.store.runs(cardID: merging.id).first?.kind == .mergePR)
        #expect(try await f.store.runs(cardID: waiting.id).isEmpty)

        let rows = try await f.store.autoDevCards(sessionID: started.id)
        let waitingRow = try #require(rows.first { $0.cardID == waiting.id })
        #expect(waitingRow.disposition == .held)
        #expect(waitingRow.attempts == 0)
    }

    @Test("A paused queue stops the round rather than burning the patience window")
    func aPausedQueueStopsTheRound() async throws {
        let (f, service) = try await fixture()
        let card = try await f.board.createCard(
            repoID: f.repo.id, title: "One", story: story(1)).card
        await f.queue.setPaused(true)

        let started = try await service.start(
            session: AutoDevSession(
                repoID: f.repo.id, engagedCardIDs: [card.id], maxAttemptsPerCard: 2,
                patience: 900, startedAt: epoch),
            preflightChecks: passing)

        #expect(try await f.store.card(id: card.id)?.column == .backlog)
        let row = try #require(try await f.store.autoDevCards(sessionID: started.id).first)
        #expect(row.reason == "Not started yet.")
        #expect(row.updatedAt == epoch)
    }

    @Test("A reason that has not changed for the patience window settles the card")
    func patienceSettles() async throws {
        let (f, service) = try await fixture()
        var card = try await f.board.createCard(repoID: f.repo.id, title: "Stuck").card
        card.column = .todo
        try await f.store.saveCard(card)   // To Do with no issue number: blocked for ever.

        let started = try await service.start(
            session: AutoDevSession(
                repoID: f.repo.id, engagedCardIDs: [card.id], maxAttemptsPerCard: 2,
                patience: 600, startedAt: epoch),
            preflightChecks: passing)

        var row = try #require(try await f.store.autoDevCards(sessionID: started.id).first)
        #expect(row.disposition == .wait)

        f.now.advance(by: 601)
        await service.advance()
        row = try #require(try await f.store.autoDevCards(sessionID: started.id).first)
        #expect(row.disposition == .settled)
        #expect(row.reason.contains("601") == false)   // the window, not the elapsed time
        #expect(row.reason.contains("600 seconds"))
    }

    @Test("A card in Done whose merge did not land is not a success")
    func doneIsNotMerged() async throws {
        let (f, service) = try await fixture()
        var card = try await f.board.createCard(repoID: f.repo.id, title: "Fell over").card
        card.column = .done
        card.prNumber = 52
        card.lastError = "Checks are failing: build."
        try await f.store.saveCard(card)
        // The run `merge-pr` left behind: terminal, and `gh` said it did not merge.
        var run = SkillRun.card(
            cardID: card.id, repoID: f.repo.id, kind: .mergePR, prompt: "x", cwd: f.repo.path,
            logPath: "/tmp/a", stderrPath: "/tmp/b",
            requiresVerifiedGreen: true, createdAt: epoch)
        run.state = .succeeded
        run.verifiedOutcome = .notMerged(reason: "The pull request is still open.")
        try await f.store.saveRun(run)

        let started = try await service.start(
            session: AutoDevSession(
                repoID: f.repo.id, engagedCardIDs: [card.id], maxAttemptsPerCard: 2,
                patience: 900, startedAt: epoch),
            preflightChecks: passing)

        let row = try #require(try await f.store.autoDevCards(sessionID: started.id).first)
        #expect(row.disposition == .settled)
        // The column says Done for both outcomes; only the run separates them.
        #expect(row.reason == "Checks are failing: build.")
        #expect(try await f.store.card(id: card.id)?.column == .done)
    }

    @Test("A card in Done whose merge landed is a success, decided on the run")
    func mergedIsASuccess() async throws {
        let (f, service) = try await fixture()
        var card = try await f.board.createCard(repoID: f.repo.id, title: "Landed").card
        card.column = .done
        card.prNumber = 52
        try await f.store.saveCard(card)
        var run = SkillRun.card(
            cardID: card.id, repoID: f.repo.id, kind: .mergePR, prompt: "x", cwd: f.repo.path,
            logPath: "/tmp/a", stderrPath: "/tmp/b",
            requiresVerifiedGreen: true, createdAt: epoch)
        run.state = .succeeded
        run.verifiedOutcome = .merged(commitSHA: "deadbeef")
        try await f.store.saveRun(run)

        let started = try await service.start(
            session: AutoDevSession(
                repoID: f.repo.id, engagedCardIDs: [card.id], maxAttemptsPerCard: 2,
                patience: 900, startedAt: epoch),
            preflightChecks: passing)

        let row = try #require(try await f.store.autoDevCards(sessionID: started.id).first)
        #expect(row.reason == "Merged.")
        #expect(row.disposition == .settled)
    }

    @Test("A blocked repository ends the session, not one card")
    func abortSettlesEveryCard() async throws {
        let (f, service) = try await fixture()
        // Three cards in In Review with a pull request and **no reading**.
        //
        // The shape matters: `start` runs a round before this test can do
        // anything, and a card that round can *advance* comes back holding its
        // own run — after which every later round answers
        // `.runAlreadyInFlight` and never reaches `evaluateMove` at all, so
        // `.repoDisabled` could never be seen. These three settle on nothing:
        // the first round answers `.notVerifiedGreen(sign: nil)` with no
        // reading, which is a `.wait` and spawns nothing.
        var cards: [Card] = []
        for index in 0..<3 {
            var card = try await f.board.createCard(
                repoID: f.repo.id, title: "Card \(index)", story: story(index)).card
            card.column = .inReview
            card.issueNumber = 40 + index
            card.prNumber = 60 + index
            try await f.store.saveCard(card)
            cards.append(card)
        }
        let started = try await service.start(
            session: AutoDevSession(
                repoID: f.repo.id, engagedCardIDs: cards.map(\.id), maxAttemptsPerCard: 2,
                patience: 900, startedAt: epoch),
            preflightChecks: passing)

        let waiting = try await f.store.autoDevCards(sessionID: started.id)
        #expect(waiting.allSatisfy { $0.disposition == .wait })
        #expect(try await f.store.runs(cardID: cards[0].id).isEmpty)

        // The repository is turned off under the session, which is what
        // `evaluateMove` answers `.repoDisabled` to.
        var repo = f.repo
        repo.isEnabled = false
        try await f.store.saveRepo(repo)
        await service.advance()

        let rows = try await f.store.autoDevCards(sessionID: started.id)
        #expect(rows.allSatisfy { $0.disposition == .aborted })
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd ElliotKit && swift test --filter AutoDevRoundTests`

Expected: FAIL — the eight tests build and run against the `advance()` stub, so they fail on the
assertions rather than on a missing symbol. The first is
`Expectation failed: try await f.store.card(id: card.id)?.column == .todo` (the card is still
`.backlog`, because the stub does nothing). **Seven of the eight fail; read the count.**
`aPausedQueueStopsTheRound` passes against the stub, and that is not a mistake — a stub does
nothing, and doing nothing is exactly what a paused queue must produce. It is only worth its
place once the stub is gone.

- [ ] **Step 3: Write minimal implementation**

Replace the `advance()` stub in `ElliotKit/Sources/ElliotEngine/AutoDevService.swift` with:

```swift
    // MARK: - Advancing

    /// One coalesced pass over every running session.
    ///
    /// Coalesced rather than queued: a round asks the board the same question
    /// again from scratch, so two rounds back to back are one round. A trigger
    /// arriving while one is in flight sets a flag and returns at once — which
    /// is also what keeps `RunScheduler.finish` from waiting on a whole round
    /// before it returns.
    public func advance() async {
        guard !roundInFlight else {
            roundRequested = true
            return
        }
        roundInFlight = true
        defer { roundInFlight = false }
        repeat {
            roundRequested = false
            await round()
        } while roundRequested
    }

    private func round() async {
        // The user's own stop outranks everything. Recording dispositions while
        // the queue is paused would burn the patience window against a hold the
        // reader put there on purpose.
        guard await queue.queueIsPaused() == false else { return }
        for session in (try? await store.runningAutoDevSessions()) ?? [] {
            await advance(session)
        }
    }

    private func advance(_ session: AutoDevSession) async {
        let now = clock()
        var states = (try? await store.autoDevCards(sessionID: session.id)) ?? []
        guard !states.isEmpty else {
            // Every engaged card was deleted. Nothing left to settle.
            await finish(session)
            return
        }

        // Walked in the order the person engaged them, **not** in the order the
        // rows came back. `autoDevCards` orders on `updatedAt`, and at the start
        // of a session every row carries the same timestamp — so the walk order
        // would be whatever SQLite happened to return, and it decides which card
        // gets the session's one merge slot below. The engaged list is the
        // promise and it is ordered; the rows are the state.
        let engagedOrder = Dictionary(
            session.engagedCardIDs.enumerated().map { ($0.element, $0.offset) },
            uniquingKeysWith: { first, _ in first }
        )
        states.sort { (engagedOrder[$0.cardID] ?? .max) < (engagedOrder[$1.cardID] ?? .max) }

        // Three reads per session, not per card.
        var cards: [UUID: Card] = [:]
        for id in session.engagedCardIDs {
            if let card = (try? await store.card(id: id)) ?? nil { cards[id] = card }
        }
        let active = (try? await store.activeRuns(cardIDs: session.engagedCardIDs)) ?? [:]
        let held = Dictionary(
            (await queue.queueSnapshot()).compactMap { row in row.cardID.map { ($0, row.refusal) } },
            uniquingKeysWith: { first, _ in first }
        )

        // A session runs at most one merge, and **nothing beside it**.
        //
        // Stronger than "no new implement-issue", for the reason the design
        // gives: `pump()` steps over a refused run and admits the next
        // (`RunScheduler.swift:256-266`), so on a repository the session keeps
        // busy `.mergeWaitsForRepoToBeIdle` can otherwise never lift. Anything
        // started beside a pending merge is one more thing that merge waits for.
        //
        // `var`, and that is the whole of it: a merge this very round queued
        // holds everything after it exactly as one already in flight does.
        // Computed once before the loop and never updated, the round that
        // queues a merge also starts the next card's run — and the serialising
        // would be off by precisely the case it exists for.
        var mergePending = active.values.contains { $0.kind == .mergePR }

        var aborted: String?
        for index in states.indices {
            if aborted != nil { break }
            let state = states[index]
            guard !state.isSettled else { continue }

            guard let card = cards[state.cardID] else {
                states[index] = record(
                    state, .settle(reason: "This card is no longer on the board."), now: now)
                continue
            }

            // Settled the moment `gh` says the merge landed.
            if await didMerge(cardID: card.id) {
                states[index] = record(state, .settle(reason: "Merged."), now: now)
                continue
            }

            if let run = active[card.id] {
                let disposition: Disposition
                if let refusal = held[card.id] {
                    disposition = AutoDevPolicy.held(
                        refusal, unchangedSince: state.updatedAt,
                        patience: session.patience, now: now)
                } else {
                    disposition = AutoDevPolicy.disposition(
                        outcome: .blocked(.runAlreadyInFlight(runID: run.id)),
                        reading: .noReading, attempts: state.attempts,
                        maxAttempts: session.maxAttemptsPerCard,
                        unchangedSince: state.updatedAt, patience: session.patience, now: now)
                }
                states[index] = record(state, disposition, now: now)
                continue
            }

            if mergePending {
                states[index] = record(
                    state,
                    AutoDevPolicy.held(
                        .mergeWaitsForRepoToBeIdle, unchangedSince: state.updatedAt,
                        patience: session.patience, now: now),
                    now: now)
                continue
            }

            guard let to = card.column.naturalNext else {
                // Done, with no merged run behind it. `commitMove` puts a card
                // in Done *before* the run (`BoardService.swift:137-147`) and
                // `CardOutcome.applied` returns no move for `.notMerged`, so a
                // failed merge leaves it exactly here. The column separates
                // neither case; `didMerge` above already did.
                states[index] = record(
                    state, .settle(reason: card.lastError ?? "The merge did not land."), now: now)
                continue
            }

            let proposal: MoveProposal
            do {
                proposal = try await board.proposeMove(
                    cardID: card.id, to: to, origin: .autoDev(sessionID: session.id),
                    // Always `[]`: the session merges, filing nothing of its
                    // own. Follow-ups genuinely found in the pull request are
                    // filed by `merge-pr` itself.
                    followUps: [],
                    requiresVerifiedGreen: true
                )
            } catch {
                states[index] = record(state, .settle(reason: error.localizedDescription), now: now)
                continue
            }

            let disposition = AutoDevPolicy.disposition(
                outcome: proposal.outcome,
                // The reading the decision was made on, carried by the proposal
                // — never a second read taken a moment later.
                reading: proposal.prVerdict.map(PRReading.read) ?? .noReading,
                attempts: state.attempts,
                maxAttempts: session.maxAttemptsPerCard,
                unchangedSince: state.updatedAt,
                patience: session.patience,
                now: now
            )

            switch disposition {
            case .retry:
                var advanced = record(state, disposition, now: now)
                // Attempts count runs **started**, never rounds taken: a
                // `.noAction` move advances a card and spawns nothing, and
                // charging it an attempt would exhaust a session on free moves.
                if case .some(.moved(let runID)) = try? await board.commitMove(proposal),
                    runID != nil {
                    advanced.attempts += 1
                    // The merge this round just queued holds every card after
                    // it, for the same reason one already in flight does.
                    if case .action(.mergePR) = proposal.outcome { mergePending = true }
                }
                states[index] = advanced

            case .abortSession(let reason):
                aborted = reason
                states[index] = record(state, disposition, now: now)

            case .wait, .held, .settle:
                states[index] = record(state, disposition, now: now)
            }
        }

        if let aborted {
            // `repoDisabled` and `repoBlocked` end the **session**, not one
            // card: nothing else engaged here could run either.
            for index in states.indices where !states[index].isSettled {
                states[index] = record(states[index], .abortSession(reason: aborted), now: now)
            }
        }

        for state in states { try? await store.saveAutoDevCard(state) }

        if states.allSatisfy(\.isSettled) { await finish(session) }
    }

    /// Writes a disposition onto a card's row, moving `updatedAt` **only** when
    /// the reason changed.
    ///
    /// That is the whole patience mechanism. A timestamp refreshed on every
    /// round would make the window infinite and every stuck card immortal — the
    /// one line in this file that has to be read twice.
    private func record(
        _ state: AutoDevCardState, _ disposition: Disposition, now: Date
    ) -> AutoDevCardState {
        var updated = state
        updated.disposition = disposition.code
        if disposition.reason != state.reason {
            updated.reason = disposition.reason
            updated.updatedAt = now
        }
        return updated
    }

    /// Whether the card's newest terminal merge run actually merged.
    ///
    /// Read from the persisted row — `RunScheduler.completeCardRun` writes
    /// `verifiedOutcome` and `finish` saves it — and never from the column:
    /// `commitMove` puts the card in Done *before* the run, so Done means
    /// "a merge was attempted", not "a merge landed".
    ///
    /// `if case`, not a `switch`: this asks one question of `VerifiedOutcome`,
    /// and a fourth exhaustive switch over it is exactly what `CardOutcome`
    /// exists to prevent.
    private func didMerge(cardID: UUID) async -> Bool {
        let runs = (try? await store.runs(cardID: cardID, limit: 20)) ?? []
        guard let merge = runs.first(where: { $0.kind == .mergePR && $0.state.isTerminal })
        else { return false }
        if case .merged = merge.verifiedOutcome { return true }
        return false
    }

    /// Ends a session. Task 13 gives this the cancellations it also owes.
    private func finish(_ session: AutoDevSession) async {
        var ended = session
        ended.state = .finished
        ended.endedAt = clock()
        try? await store.saveAutoDevSession(ended)
    }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd ElliotKit && swift test --filter AutoDevRoundTests`

Expected: PASS — 8 tests. Then `cd ElliotKit && swift test --filter AutoDevStartTests`, PASS.

- [ ] **Step 5: Commit**

```bash
cd /Users/phmatray/Repositories/phmatray/private/Elliot/.claude/worktrees/precious-beaming-wand
git rev-parse --abbrev-ref HEAD
git add ElliotKit/Sources/ElliotEngine/AutoDevService.swift ElliotKit/Tests/ElliotEngineTests/AutoDevServiceTests.swift
git commit -m "feat(engine): one round — ask the board again, and serialise the merges"
```

---

### Task 13: Termination — and the runs a settled card is still holding

**Files:**
- Modify: `ElliotKit/Sources/ElliotEngine/AutoDevService.swift` (`finish`)
- Test: `ElliotKit/Tests/ElliotEngineTests/AutoDevServiceTests.swift` (append)

**Interfaces:**
- Consumes: `RunLaunching.cancel(runID:)` (`RunScheduler.swift:11-14`);
  `BoardStore.activeRun(cardID:)` (`BoardStore.swift:746`); `RunState.isTerminal`
  (`SkillRun.swift:17-22`).
- Produces: `finish(_:)` cancels every `.queued` or `.stalled` run still holding an engaged card,
  then marks the session `.finished` with an `endedAt`.

> **Abandoning a card and cancelling its run are not the same act, and only the second frees the
> card.** A `.stalled` run is non-terminal (`RunState.isTerminal` says so), so `activeRun(cardID:)`
> goes on answering with it for ever — the card is held by a run nobody is waiting for. A `.queued`
> run held by `.mergeVerdictNotEstablished` is the same shape one refusal over. Both are cut here.
>
> ⛔ **A `.running` run is never cancelled by termination**, and that is not an omission: a card with
> a running run is not settled, so a session cannot terminate while one exists. The only path that
> reaches a live child is the user's own stop, which is PR5's.

- [ ] **Step 1: Write the failing test**

```swift
// Appended to ElliotKit/Tests/ElliotEngineTests/AutoDevServiceTests.swift

@Suite("Auto-dev — termination")
struct AutoDevTerminationTests {

    private let epoch = Date(timeIntervalSince1970: 1_770_000_000)
    private let passing = [CheckResult(id: "x", title: "x", status: .pass, detail: "")]

    /// **A session where every card is blocked must finish.** Under `withTimeout`
    /// because the failure this guards against is not a wrong answer, it is a
    /// loop that never gives one.
    @Test("A session whose every card is blocked finishes")
    func everyCardBlockedStillFinishes() async throws {
        try await withTimeout(.seconds(20)) {
            let store = try BoardStore.inMemory()
            let launcher = FakeLauncher()
            let queue = FakeQueue()
            let board = BoardService(store: store, launcher: launcher)
            try await store.saveSpendCeiling(SpendCeiling(perRunUSD: nil, perDayUSD: 25))
            let repo = Repo(
                path: "/tmp/repo-\(UUID().uuidString)", nameWithOwner: "phmatray/Elliot",
                displayName: "Elliot")
            try await store.saveRepo(repo)

            // Three cards with nothing on them: `.backlog → .todo` is
            // `.blocked(.emptyIdea)`, which settles without repetition.
            var ids: [UUID] = []
            for _ in 0..<3 {
                let card = try await board.createCard(repoID: repo.id, title: "").card
                ids.append(card.id)
            }

            let service = AutoDevService(
                store: store, board: board, launcher: launcher, queue: queue,
                clock: { self.epoch })
            let started = try await service.start(
                session: AutoDevSession(
                    repoID: repo.id, engagedCardIDs: ids, maxAttemptsPerCard: 2,
                    patience: 600, startedAt: self.epoch),
                preflightChecks: self.passing)

            let ended = try #require(try await store.autoDevSession(id: started.id))
            #expect(ended.state == .finished)
            #expect(ended.endedAt == self.epoch)
            #expect(try await store.runningAutoDevSessions().isEmpty)
        }
    }

    @Test("Ending a session cancels the runs its settled cards are still holding")
    func stalledAndQueuedRunsAreCancelled() async throws {
        let store = try BoardStore.inMemory()
        let launcher = FakeLauncher()
        let queue = FakeQueue()
        let board = BoardService(store: store, launcher: launcher)
        try await store.saveSpendCeiling(SpendCeiling(perRunUSD: nil, perDayUSD: 25))
        let repo = Repo(
            path: "/tmp/repo-\(UUID().uuidString)", nameWithOwner: "phmatray/Elliot",
            displayName: "Elliot")
        try await store.saveRepo(repo)

        // One card in Done with a failed merge behind it — settled, and holding
        // a stalled run that nobody is waiting for.
        var card = try await board.createCard(repoID: repo.id, title: "Fell over").card
        card.column = .done
        card.prNumber = 52
        try await store.saveCard(card)
        var finished = SkillRun.card(
            cardID: card.id, repoID: repo.id, kind: .mergePR, prompt: "x", cwd: repo.path,
            logPath: "/tmp/a", stderrPath: "/tmp/b", createdAt: epoch)
        finished.state = .failed
        finished.verifiedOutcome = .notMerged(reason: "Still open.")
        try await store.saveRun(finished)

        var stalled = SkillRun.card(
            cardID: card.id, repoID: repo.id, kind: .mergePR, prompt: "x", cwd: repo.path,
            logPath: "/tmp/c", stderrPath: "/tmp/d",
            createdAt: epoch.addingTimeInterval(1))
        stalled.state = .stalled
        try await store.saveRun(stalled)

        // A clock this test moves, because the cut is reached **through** the
        // patience window and not around it: a `.stalled` run is non-terminal,
        // so `activeRun(cardID:)` keeps answering with it and every round reads
        // `.runAlreadyInFlight` — a `.wait`. Under a frozen clock that wait
        // never expires, the card never settles, `finish` is never reached and
        // nothing is ever cancelled. That is the loop this test is about, and
        // both halves of it are asserted.
        let now = LockedDate(epoch)
        let service = AutoDevService(
            store: store, board: board, launcher: launcher, queue: queue, clock: { now.date })
        let started = try await service.start(
            session: AutoDevSession(
                repoID: repo.id, engagedCardIDs: [card.id], maxAttemptsPerCard: 1,
                patience: 600, startedAt: epoch),
            preflightChecks: passing)

        // While the run still holds the card the session waits, and cancels
        // nothing: abandoning a card mid-wait would be the opposite mistake.
        #expect(await launcher.cancelledRuns().isEmpty)
        #expect(try await store.autoDevSession(id: started.id)?.state == .running)

        now.advance(by: 601)
        await service.advance()

        // The stalled run is what `activeRun(cardID:)` answers with, and only
        // cancelling it frees the card.
        #expect(await launcher.cancelledRuns() == [stalled.id])
    }

    @Test("A finished session is not resumed, and not advanced again")
    func aFinishedSessionStaysFinished() async throws {
        let store = try BoardStore.inMemory()
        let launcher = FakeLauncher()
        let queue = FakeQueue()
        let board = BoardService(store: store, launcher: launcher)
        try await store.saveSpendCeiling(SpendCeiling(perRunUSD: nil, perDayUSD: 25))
        let repo = Repo(
            path: "/tmp/repo-\(UUID().uuidString)", nameWithOwner: "phmatray/Elliot",
            displayName: "Elliot")
        try await store.saveRepo(repo)
        let card = try await board.createCard(repoID: repo.id, title: "").card

        let service = AutoDevService(
            store: store, board: board, launcher: launcher, queue: queue, clock: { self.epoch })
        let started = try await service.start(
            session: AutoDevSession(
                repoID: repo.id, engagedCardIDs: [card.id], maxAttemptsPerCard: 1,
                patience: 600, startedAt: epoch),
            preflightChecks: passing)
        #expect(try await store.autoDevSession(id: started.id)?.state == .finished)

        await service.advance()
        #expect(await launcher.launchedRuns().isEmpty)
        #expect(try await store.card(id: card.id)?.column == .backlog)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd ElliotKit && swift test --filter AutoDevTerminationTests`

Expected: FAIL on the second test —
`Expectation failed: await launcher.cancelledRuns() == [stalled.id]` (the stub `finish` cancels
nothing, so the recorded list is empty). The first and third pass already.

- [ ] **Step 3: Write minimal implementation**

Replace `finish(_:)` in `ElliotKit/Sources/ElliotEngine/AutoDevService.swift`:

```swift
    /// Ends a session, and lets go of what its cards are still holding.
    ///
    /// **Abandoning a card and cancelling its run are not the same act, and only
    /// the second frees the card.** A `.stalled` run is non-terminal, so
    /// `activeRun(cardID:)` answers with it for ever; a `.queued` merge held by
    /// `.mergeVerdictNotEstablished` is the same shape one refusal over. Both
    /// would otherwise outlive the session that made them, hold their card
    /// against every future move, and be waited on by nobody.
    ///
    /// ⛔ A `.running` run is deliberately untouched: a card with one is not
    /// settled, so a session cannot reach here while one exists. The only path
    /// that stops a live child is the user's own stop.
    private func finish(_ session: AutoDevSession) async {
        for cardID in session.engagedCardIDs {
            let run = (try? await store.activeRun(cardID: cardID)) ?? nil
            guard let run, run.state == .queued || run.state == .stalled else { continue }
            await launcher.cancel(runID: run.id)
        }

        var ended = session
        ended.state = .finished
        ended.endedAt = clock()
        try? await store.saveAutoDevSession(ended)
    }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd ElliotKit && swift test --filter AutoDevTerminationTests`

Expected: PASS — 3 tests. Then `cd ElliotKit && swift test --filter AutoDevRoundTests`, PASS.

- [ ] **Step 5: Commit**

```bash
cd /Users/phmatray/Repositories/phmatray/private/Elliot/.claude/worktrees/precious-beaming-wand
git rev-parse --abbrev-ref HEAD
git add ElliotKit/Sources/ElliotEngine/AutoDevService.swift ElliotKit/Tests/ElliotEngineTests/AutoDevServiceTests.swift
git commit -m "feat(engine): a session that ends lets go of the runs its cards were holding"
```

---

### Task 14: Resume, and the launch order

**Files:**
- Modify: `ElliotKit/Sources/ElliotAppKit/AppModel.swift:432` (the property), `:546-561` (the wiring)
- Test: `ElliotKit/Tests/ElliotEngineTests/AutoDevServiceTests.swift` (append)

**Interfaces:**
- Consumes: `AutoDevService.advance()` (Task 12); `AutoDevService.hasRunningSession()` (Task 11);
  `RunScheduler.setRoundTrigger(_:)` (Task 9); `PRWatcher.setRoundTrigger(_:)` and
  `PRWatcher.setSessionProbe(_:)` (Task 10); `Reconciler.sweep()` (`Reconciler.swift:37-78`).
- Produces: `AppModel.autoDev: AutoDevService?`, built beside `analysisService`, with its hooks
  registered **after** `reconciler.sweep()` has returned.

> 🔴 **Cross-plan: `AppModel.autoDev` is already taken, by PR5, with a different type.** PR5's Task 4
> ships a whole `// MARK: - Auto-dev` section on `AppModel` — `autoDev: AutoDevSession?`
> (`public private(set)`, the **session value** the band renders), `autoDevEngagements`,
> `autoDevEngagedCardIDs`, `autoDevTally`, `autoDevCardLimit`, `autoDevRefusal`, five commands and
> `testOnlyAttachAutoDev(_:)` — and it reaches the loop through the `AutoDevDriving` protocol, not
> through a concrete actor. `AppModel.swift` is a union-merge file, so git will keep **both**
> declarations and the compiler will reject the redeclaration; a union merge hides this until
> `swift build`.
>
> The fix follows whichever way the `AutoDevDriving` question is arbitrated (see PR5's Prerequisites
> and this plan's Task 3 header): if `AutoDevService` conforms to `AutoDevDriving`, this task adds
> **no property at all** — it builds the actor, calls `model.testOnlyAttachAutoDev(service)`'s
> production twin, and registers the two hooks. That is also the smaller diff. What it must **not**
> do is introduce a second property under the same name, and it must not quietly rename PR5's, which
> six call sites across `OperationsView`, `BoardView`, `CardView` and three test suites read.
>
> ⚠️ The line numbers above (`:432`, `:546-561`) are read against `main`; PR1's Task 8 and PR5's
> Tasks 2 and 4 both edit `AppModel.swift` before this branch. Locate `start()` and the
> `reconciler.sweep()` call by name.

> **Is the order already satisfied? Yes — and there is exactly one way to get it wrong.** Read as it
> stands, `AppModel.start()` builds the scheduler and board at `:516-521`, the analysis service at
> `:546-548`, starts IPC at `:550`, sweeps at `:554-557`, and only then builds and starts the watcher
> at `:559-561`. Nothing calls auto-dev today, so *any* placement after `:557` satisfies "Reconciler
> before auto-dev". The one way to break it is to register `scheduler.setRoundTrigger(autoDev)`
> **before** the sweep: `Reconciler.sweep()` re-launches queued runs (`Reconciler.swift:43-47`), and
> a finished run would then trigger a round in the middle of the sweep — a round that reads an orphan
> still marked `.running`, answers `runAlreadyInFlight`, waits, and waits for an event that will
> never come, because the sweep that would have produced it has not reached that run yet.
>
> So the registration itself is placed after the sweep. That makes the ordering structural rather
> than a comment: while the sweep runs there is no trigger to fire.

- [ ] **Step 1: Write the failing test**

```swift
// Appended to ElliotKit/Tests/ElliotEngineTests/AutoDevServiceTests.swift

@Suite("Auto-dev — the launch order")
struct AutoDevLaunchOrderTests {

    private let epoch = Date(timeIntervalSince1970: 1_770_000_000)
    private let passing = [CheckResult(id: "x", title: "x", status: .pass, detail: "")]

    /// The order is the subject, so both halves are measured: a round *before*
    /// the sweep must do nothing, and the same round *after* it must advance the
    /// card. A test that only checked the second half would pass with the wiring
    /// in either order.
    @Test("A round before the sweep waits on an orphan; the same round after it advances the card")
    func reconcilerRunsFirst() async throws {
        // The second round commits a move, which resolves `StoreLocation` run
        // paths — so the shared home has to be final first.
        _ = TestHome.root
        let store = try BoardStore.inMemory()
        let launcher = FakeLauncher()
        let queue = FakeQueue()
        let board = BoardService(store: store, launcher: launcher)
        let config = ToolConfig(
            claudePath: "/usr/bin/true", ghPath: "/usr/bin/false",
            gitPath: "/usr/bin/false", environment: [:])
        try await store.saveSpendCeiling(SpendCeiling(perRunUSD: nil, perDayUSD: 25))
        let repo = Repo(
            path: "/tmp/repo-\(UUID().uuidString)", nameWithOwner: "phmatray/Elliot",
            displayName: "Elliot")
        try await store.saveRepo(repo)

        var card = try await board.createCard(repoID: repo.id, title: "Interrupted").card
        card.column = .todo
        card.issueNumber = 47
        try await store.saveCard(card)

        // The run that died with the app: still `.running` in the store, holding
        // its card through `activeRun(cardID:)`.
        var orphan = SkillRun.card(
            cardID: card.id, repoID: repo.id, kind: .implementIssue,
            prompt: "/ai-migration-kit:implement-issue 47", cwd: repo.path,
            logPath: "/tmp/a", stderrPath: "/tmp/b", createdAt: epoch)
        orphan.state = .running
        try await store.saveRun(orphan)

        // A session that was running when Elliot stopped.
        let session = AutoDevSession(
            repoID: repo.id, engagedCardIDs: [card.id], maxAttemptsPerCard: 2,
            patience: 6000, startedAt: epoch)
        try await store.saveAutoDevSession(
            session,
            cards: [AutoDevCardState(
                sessionID: session.id, cardID: card.id, attempts: 0,
                disposition: .wait, reason: "Not started yet.", updatedAt: epoch)])

        let service = AutoDevService(
            store: store, board: board, launcher: launcher, queue: queue, clock: { self.epoch })

        // Before the sweep: the orphan holds the card and nothing can happen.
        await service.advance()
        #expect(try await store.card(id: card.id)?.column == .todo)
        #expect(await launcher.launchedRuns().isEmpty)

        let reconciler = Reconciler(
            store: store, verifier: Verifier(gh: .init(config: config)),
            mover: board, launcher: launcher)
        let summary = await reconciler.sweep()
        #expect(summary.orphanedRuns == 1)

        // After it: the run is terminal, the card is free, and the round moves it.
        await service.advance()
        #expect(try await store.card(id: card.id)?.column == .inProgress)
        #expect(try await store.runs(cardID: card.id).first?.kind == .implementIssue)
    }

    @Test("A running session is what the watcher asks about before widening its backoff")
    func theProbeAnswers() async throws {
        let store = try BoardStore.inMemory()
        let launcher = FakeLauncher()
        let queue = FakeQueue()
        let board = BoardService(store: store, launcher: launcher)
        let service = AutoDevService(
            store: store, board: board, launcher: launcher, queue: queue, clock: { self.epoch })
        #expect(await service.hasRunningSession() == false)

        let repo = Repo(
            path: "/tmp/repo-\(UUID().uuidString)", nameWithOwner: "phmatray/Elliot",
            displayName: "Elliot")
        try await store.saveRepo(repo)
        let session = AutoDevSession(
            repoID: repo.id, engagedCardIDs: [UUID()], maxAttemptsPerCard: 1,
            patience: 600, startedAt: epoch)
        try await store.saveAutoDevSession(session, cards: [])
        #expect(await service.hasRunningSession())
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd ElliotKit && swift test --filter AutoDevLaunchOrderTests`

Expected: PASS on both — the engine already behaves this way after Tasks 11–13. **This is the one
task whose test starts green on purpose**: it pins the ordering claim before the app wiring is
written, so Step 3's edit has something to be measured against. If it fails, the round is treating a
`.running` orphan as movable, which is a defect in Task 12, not in the wiring.

- [ ] **Step 3: Write minimal implementation**

`ElliotKit/Sources/ElliotAppKit/AppModel.swift`, beside `analysisService` (`:432`):

```swift
    private var autoDev: AutoDevService?
```

and in `start()`, immediately after the analysis service is built and stored (`:546-548`):

```swift
            // Built here, but **not yet wired**: the hooks go on after the
            // launch sweep, below.
            let autoDev = AutoDevService(
                store: store, board: board, launcher: scheduler, queue: scheduler)
            self.autoDev = autoDev
```

then, after `let summary = await reconciler.sweep()` (`:557`) and before the watcher is built
(`:559`):

```swift
            // Only now. `Reconciler.sweep()` re-derives what every run that died
            // with the app actually managed to do, and it re-launches the ones
            // that were only queued. A round that ran before it would read an
            // orphan still marked `.running`, answer `runAlreadyInFlight`, and
            // wait for an event that will never come.
            //
            // Registering the trigger *here* rather than beside the service is
            // what makes that ordering structural: while the sweep runs there is
            // no trigger to fire.
            await scheduler.setRoundTrigger(autoDev)
            await autoDev.advance()
```

and, once the watcher exists (`:559-561`), before `watcher.start()`:

```swift
            let watcher = PRWatcher(store: store, gh: ghClient, mover: board)
            await watcher.setRoundTrigger(autoDev)
            // `[weak autoDev]`: the watcher outlives nothing, and nothing here
            // should be what keeps a session alive.
            await watcher.setSessionProbe { [weak autoDev] in
                await autoDev?.hasRunningSession() ?? false
            }
            await watcher.start()
            self.watcher = watcher
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd ElliotKit && swift test --filter AutoDevLaunchOrderTests`

Expected: PASS — 2 tests. Then `cd ElliotKit && swift build` and
`cd ElliotKit && swift test --filter AppModelTests`, both clean: the app target compiles and the
model's own suite is unaffected.

⚠️ The wiring itself is not covered by `swift test` — `AppModel.start()` opens the real store and
captures a login shell. Verify it the way this repository verifies anything on screen, with an
isolated home:

```bash
./Scripts/build-app.sh
open -n --env ELLIOT_HOME=/tmp/elliot-check dist/Elliot.app
```

and read the status bar: `Ready.` with the board painted. A crash here would be the wiring; a board
that paints is the wiring holding.

- [ ] **Step 5: Commit**

```bash
cd /Users/phmatray/Repositories/phmatray/private/Elliot/.claude/worktrees/precious-beaming-wand
git rev-parse --abbrev-ref HEAD
git add ElliotKit/Sources/ElliotAppKit/AppModel.swift ElliotKit/Tests/ElliotEngineTests/AutoDevServiceTests.swift
git commit -m "feat(app): resume unattended sessions, after the launch sweep and never before"
```

---

### Task 15: A whole session, against the real fakes

**Files:**
- Create: `ElliotKit/Tests/ElliotEngineTests/AutoDevEndToEndTests.swift`

**Interfaces:**
- Consumes: everything above; `Scripts/fake-claude.sh` (`FAKE_CLAUDE_FIXTURE`),
  `Scripts/fake-gh.sh` (`FAKE_GH_PRS`, `FAKE_GH_PR_VIEW`), `TestHome.scratch(_:)`.
- Produces: nothing importable. It is the only test in this plan that spawns a real child, parses a
  real stream, and lets a real `Verifier` decide.

> **Two fixture sets, and why they are two tests rather than one.** `FAKE_GH_PR_VIEW` is one path per
> process, so one stack cannot answer `pr view` two different ways. The green pull request that must
> merge and the `noChecks` one that must settle blocked therefore get a stack each — which is also
> the honest shape, since the second never reaches a `pr view` at all: the *decision* refuses it, and
> that is the claim.
>
> Nested under `EndToEndSuites` and `.serialized`, like the two suites already there: they share one
> process-global `ELLIOT_HOME` through `TestHome.root`, so they must not run at the same time.

- [ ] **Step 1: Write the failing test**

```swift
import ElliotModel
import ElliotProcess
import ElliotStore
import Foundation
import TestSupport
import Testing

@testable import ElliotEngine

private enum AutoDevPaths {
    static let repoRoot: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // ElliotEngineTests
        .deletingLastPathComponent()   // Tests
        .deletingLastPathComponent()   // ElliotKit
        .deletingLastPathComponent()   // repo root

    static let fakeClaude = repoRoot.appendingPathComponent("Scripts/fake-claude.sh").path
    static let fakeGH = repoRoot.appendingPathComponent("Scripts/fake-gh.sh").path

    static func streamFixture(_ name: String) -> String {
        repoRoot.appendingPathComponent("Fixtures/stream-json/\(name)").path
    }

    static func ghFixture(_ name: String) -> String {
        repoRoot.appendingPathComponent("Fixtures/gh/\(name)").path
    }
}

extension EndToEndSuites {

@Suite("Auto-dev end to end", .serialized)
struct AutoDevEndToEndTests {

    private struct Stack {
        var store: BoardStore
        var board: BoardService
        var scheduler: RunScheduler
        var service: AutoDevService
        var repo: Repo
        var home: URL

        func cleanUp() { try? FileManager.default.removeItem(at: home) }

        /// Waits for the session to reach `.finished`. Bounded, and waiting on a
        /// condition rather than on a duration.
        func awaitFinished(_ sessionID: UUID, timeout: Duration = .seconds(30)) async throws
            -> AutoDevSession
        {
            let deadline = ContinuousClock.now.advanced(by: timeout)
            var lastSeen = "no session row"
            while ContinuousClock.now < deadline {
                if let session = try await store.autoDevSession(id: sessionID) {
                    if session.state == .finished { return session }
                    lastSeen = "\(session.state)"
                }
                try await Task.sleep(for: .milliseconds(50))
            }
            throw StackError.timedOut(lastSeen: lastSeen)
        }

        enum StackError: Error { case timedOut(lastSeen: String) }
    }

    private static func makeStack(prView: String?) async throws -> Stack {
        let home = TestHome.scratch("auto-dev-e2e")
        try FileManager.default.createDirectory(
            at: home.appendingPathComponent("runs"), withIntermediateDirectories: true)
        try StoreLocation.ensureDirectories()

        let store = try BoardStore.open(at: home.appendingPathComponent("elliot.sqlite"))
        var environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
        environment["FAKE_CLAUDE_FIXTURE"] =
            AutoDevPaths.streamFixture("create-issue-success.ndjson")
        environment["FAKE_GH_PRS"] = AutoDevPaths.ghFixture("prs-basic.json")
        if let prView { environment["FAKE_GH_PR_VIEW"] = AutoDevPaths.ghFixture(prView) }

        let config = ToolConfig(
            claudePath: AutoDevPaths.fakeClaude,
            ghPath: AutoDevPaths.fakeGH,
            gitPath: "/usr/bin/false",
            environment: environment)
        let scheduler = RunScheduler(
            store: store, toolConfig: config, verifier: Verifier(gh: .init(config: config)))
        let board = BoardService(store: store, launcher: scheduler)
        await scheduler.setSystemMover(board)

        // The brake a session refuses to start without.
        try await store.saveSpendCeiling(SpendCeiling(perRunUSD: nil, perDayUSD: 25))

        let repo = Repo(path: home.path, nameWithOwner: "phmatray/Elliot", displayName: "Elliot")
        try await store.saveRepo(repo)

        let service = AutoDevService(
            store: store, board: board, launcher: scheduler, queue: scheduler)
        await scheduler.setRoundTrigger(service)

        return Stack(
            store: store, board: board, scheduler: scheduler, service: service,
            repo: repo, home: home)
    }

    private static func seedStatus(
        _ stack: Stack, prNumber: Int, checks: [GHMergeStatus.StatusCheck]
    ) async throws {
        try await stack.store.savePRStatus(
            PRStatus(
                repoID: stack.repo.id, prNumber: prNumber, headRefOid: "a1b2c3",
                checkedAt: Date(), rawMergeStateStatus: "CLEAN", rawMergeable: "MERGEABLE",
                rawReviewDecision: "", checks: checks))
    }

    private static let passing = [CheckResult(id: "x", title: "x", status: .pass, detail: "")]

    @Test("A green pull request is merged, and the session finishes saying so")
    func aGreenPullRequestMerges() async throws {
        let stack = try await Self.makeStack(prView: "pr-view-merged.json")
        defer { stack.cleanUp() }

        var card = try await stack.board.createCard(repoID: stack.repo.id, title: "Landing").card
        card.column = .inReview
        card.issueNumber = 47
        card.prNumber = 52
        try await stack.store.saveCard(card)
        try await Self.seedStatus(
            stack, prNumber: 52,
            checks: [GHMergeStatus.StatusCheck(
                name: "build-and-test", conclusion: "SUCCESS", status: "COMPLETED")])

        let started = try await stack.service.start(
            session: AutoDevSession(
                repoID: stack.repo.id, engagedCardIDs: [card.id], maxAttemptsPerCard: 2,
                patience: 600, startedAt: Date()),
            preflightChecks: Self.passing)

        let ended = try await stack.awaitFinished(started.id)
        #expect(ended.state == .finished)

        // The run really spawned, really parsed a stream, and `gh` really
        // decided the outcome.
        let run = try #require(try await stack.store.runs(cardID: card.id).first)
        #expect(run.kind == .mergePR)
        #expect(run.state == .succeeded)
        #expect(run.demandsVerifiedGreen)
        if case .merged = run.verifiedOutcome {} else {
            Issue.record("expected a merged outcome, got \(String(describing: run.verifiedOutcome))")
        }

        let row = try #require(try await stack.store.autoDevCards(sessionID: started.id).first)
        #expect(row.reason == "Merged.")
        #expect(row.disposition == .settled)
    }

    @Test("A pull request nothing has judged settles blocked, and never starts a merge")
    func aNoChecksPullRequestSettlesBlocked() async throws {
        let stack = try await Self.makeStack(prView: nil)
        defer { stack.cleanUp() }

        var card = try await stack.board.createCard(repoID: stack.repo.id, title: "Unjudged").card
        card.column = .inReview
        card.issueNumber = 48
        card.prNumber = 53
        try await stack.store.saveCard(card)
        // An empty rollup: `CIState.noChecks`, `PRSign.noBuild`. Not a pass — an
        // absence of measurement, which is the false green this whole design is
        // written against.
        try await Self.seedStatus(stack, prNumber: 53, checks: [])

        let started = try await stack.service.start(
            session: AutoDevSession(
                repoID: stack.repo.id, engagedCardIDs: [card.id], maxAttemptsPerCard: 2,
                patience: 600, startedAt: Date()),
            preflightChecks: Self.passing)

        let ended = try await stack.awaitFinished(started.id)
        #expect(ended.state == .finished)

        // No merge was attempted at all: the decision refused it, so `pr view`
        // was never called — which is why this stack has no fixture for it.
        #expect(try await stack.store.runs(cardID: card.id).isEmpty)
        #expect(try await stack.store.card(id: card.id)?.column == .inReview)

        let row = try #require(try await stack.store.autoDevCards(sessionID: started.id).first)
        #expect(row.disposition == .settled)
        #expect(row.reason == PRSign.noBuild.summary)
    }
}

}  // extension EndToEndSuites
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd ElliotKit && swift test --filter AutoDevEndToEndTests`

Expected: FAIL — this is a new file against a finished engine, so the failure to look for is a real
one. If it reports `timedOut(lastSeen: "running")`, the session is not terminating; if it reports an
`expected a merged outcome`, the merge ran and `gh` disagreed. Both are findings. If it passes at the
first attempt, re-read Step 4 before believing it: a filter that matched nothing also exits 0.

- [ ] **Step 3: Write minimal implementation**

None. Every line this suite exercises was written in Tasks 5–14; the test's job is to run them
together against a real subprocess and a real `gh`. If it fails, fix the task it points at rather
than this file — and add the case it found to that task's own suite, where it will be re-run by a
filter someone actually types.

- [ ] **Step 4: Run test to verify it passes**

Run: `cd ElliotKit && swift test --filter AutoDevEndToEndTests`

Expected: PASS — 2 tests. Read the count, not the exit code.

Then the whole suite, five times after one clean build. This is the last task, so this is the sample
that clears the branch:

```bash
cd ElliotKit && rm -rf .build && swift build --build-tests
swift test
swift test
swift test
swift test
swift test
```

Expected: `1418 tests in 158 suites` plus everything this plan adds, 0 failures, five times.

- [ ] **Step 5: Commit**

```bash
cd /Users/phmatray/Repositories/phmatray/private/Elliot/.claude/worktrees/precious-beaming-wand
git rev-parse --abbrev-ref HEAD
git add ElliotKit/Tests/ElliotEngineTests/AutoDevEndToEndTests.swift
git commit -m "test(engine): a whole unattended session, against the real fakes"
```

---

## After the last task

- `git rev-parse --abbrev-ref HEAD` once more, then push and open the pull request. Re-read the
  branch name **after** the push: several agent worktrees share this `.git`, and a `git push -u`
  that succeeds does not prove the right content left — compare
  `git rev-parse HEAD origin/<branch>`.
- The pull request body must say which option the green predicate is on. If Task 2 shipped, it is
  **Option A**, and the body should name the file whose deletion downgrades it to Option B
  (`ElliotKit/Sources/ElliotModel/NonBuildChecks.swift`) and the one conjunct that goes with it.
- ⚠️ **A conflicted pull request fires no `pull_request` workflow at all, and it fails by silence.**
  Before concluding anything about a missing run, read
  `gh pr view --json mergeable,mergeStateStatus`: an absent run and a throttled run are
  indistinguishable from the outside, and only one of them is yours to fix.
- Branch protection is off, so both checks are advisory. `swift test` on `ci.yml` is what carries
  #116's floor guarantee; a red check does not block a merge and never has.
