# Auto-dev PR1 — The rules Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Teach the pure rule engine what an unattended mover is, so that a caller which is not a human can be refused a merge on anything short of a verified green — and so that every screen, notification and MCP reply the compiler touches on the way says something true about it.

**Architecture:** All the judgement lands in `ElliotModel`, which has no dependencies and no I/O: `MoveOrigin` gains an `.autoDev` case, `MoveContext` gains `requiresVerifiedGreen` and `prVerdict`, `MoveBlock` gains two refusals, and `evaluateMove` grows two branches. `ElliotAppKit`, `ElliotIPC` and `ElliotEngine` then supply the sentences and the one reader that turns a stored `PRStatus` into the verdict the rule consumes. Nothing spawns a process, nothing changes the wire, and no migration is written.

**Tech Stack:** Swift 6.3.1 · SwiftPM (`ElliotKit`) · swift-testing (`@Suite` / `@Test` / `#expect` / `#require`) · GRDB (untouched here) · `Scripts/fake-gh.sh` + `Fixtures/gh/*.json` for the one task that spawns a subprocess.

## Global Constraints

- Swift tools-version **6.3.1** — the patch is load-bearing, never `6.3`; `swiftLanguageModes: [.v6]`; deployment target macOS 15; strict concurrency, so every type crossing an isolation boundary is `Sendable`.
- Build: `cd ElliotKit && swift build` · Tests: `cd ElliotKit && swift test`.
- One suite: `cd ElliotKit && swift test --filter <TypeName>` — the filter matches the **type** name, not the `@Suite` display name.
- ⚠ A filter that matches nothing prints `warning: No matching test cases were run` and **exits 0** — indistinguishable from success. Never conclude from an exit code alone; read the `Test Suite ... passed` line and the test count.
- Test framework is **swift-testing** (`@Suite`, `@Test`, `#expect`, `#require`) — never XCTest.
- ⛔ Never run `swift format` over the tree. The code is hand-formatted, 4 spaces, 110 columns. Format the lines you write by hand so they match their neighbours.
- Every asynchronous wait in a test is **bounded**, through `withTimeout` from the `TestSupport` target. No assertion measures an absolute duration. No test sleeps a fixed interval.
- ⛔ Nothing in production code waits on `Process.waitUntilExit()`.
- Migrations are additive and shipped ones are frozen. The last registered is `v8_prStatus` (`ElliotKit/Sources/ElliotStore/Migrations.swift:138`). A renumbering ships its `RenamedMigration` in the same diff (`Migrations.swift:195-202`). **This plan adds no migration.**
- Commits are Conventional Commits with the layer as scope: `feat(model|store|process|engine|ipc|mcp|app): subject`.
- Branch naming: `feat/<issue>-<slug>` or `fix/<issue>-<slug>` — the number first, followed by a hyphen.
- ⚠ Several worktrees share this repository's `.git`. Re-read `git rev-parse --abbrev-ref HEAD` immediately before every commit and immediately after every push.
- A stale `.build` produces impossible failures (wrong enum values, link errors, SIGBUS). After any `git checkout` that crosses commits: `rm -rf ElliotKit/.build` before believing a failure.
- One green run does not clear a suite. After a clean build, sample five times — it costs about eight seconds.

---

⚠ **Every line number in this plan is read against `main` as it stands before Task 1, and
several tasks edit the same file in sequence.** Each step also names the construct it means —
an enum case, a method, a doc comment's first line. **Locate by the name; treat the number as a
hint at where to start looking.** This matters more here than usual: PR 0·2 is a declared hard
prerequisite and edits `RuleEngine.swift`, `Consequence.swift` and `NextRendering.swift` — the
three files this plan edits most — so every number below has already moved by the time you read
it if 0·2 landed first.

## File Structure

### Created

| File | Responsibility |
|---|---|
| `ElliotKit/Sources/ElliotModel/NonBuildChecks.swift` | The **data** list of check names that are published by something other than a build (analysers, reporters, Renovate statuses), plus `CIState.hasBuildVerdict`. Seeded verbatim from `repo-audit/board/non_build_checks.json`. |
| `ElliotKit/Sources/ElliotModel/MergeableUnattended.swift` | `ResolvedPRStatus.isMergeableUnattended` — the single predicate that decides what an unattended mover may merge. |
| `ElliotKit/Sources/ElliotEngine/PRVerdictReader.swift` | The one reader of a stored `PRStatus`, resolved against the clock and — under `.establish` — against the pull request's real head read from `gh pr list`. Called by `BoardService` and by `MCPRequestHandler.prStatusDTO`. |
| `ElliotKit/Tests/ElliotModelTests/MergeableUnattendedTests.swift` | Exhaustive tests for `hasBuildVerdict` and `isMergeableUnattended`. |
| `ElliotKit/Tests/ElliotModelTests/MoveOriginTests.swift` | `allowsSideEffects` for all seven origin values (`.userDrag`, `.mcp`, `.autoDev`, and `.system` with each of its four reasons) — the property that decides whether an unattended agent starts, and which no test measured. |
| `ElliotKit/Tests/ElliotAppKitTests/MoveBlockCases.swift` | A `CaseIterable` shadow of `MoveBlock`, so the two literal block lists in this target become compiler-checked. |
| `ElliotKit/Tests/ElliotAppKitTests/RefusalWordingTests.swift` | `Consequence.reason` and `MoveBlockText.explain` are two hand-written phrasings of every `MoveBlock` in two targets; this links them in the non-identity direction. |
| `ElliotKit/Tests/ElliotEngineTests/PRVerdictReaderTests.swift` | The reader against `Scripts/fake-gh.sh`: the two head policies, fail-closed when `gh` cannot be reached, and the `listingTTL` window measured through the fake's argv dump rather than a clock. |
| `Fixtures/gh/prs-head-oid.json` | A `gh pr list` payload that carries `headRefOid`, which `prs-basic.json` does not. |

### Modified

| File | Change |
|---|---|
| `ElliotKit/Sources/ElliotModel/PRStatus.swift` | `case passing(Int)` → `case passing([String])`; `ciState` maps the labels instead of counting them. |
| `ElliotKit/Sources/ElliotModel/SkillRun.swift` | `MoveOrigin.autoDev(sessionID: UUID)`; `allowsSideEffects` becomes an exhaustive `switch`. |
| `ElliotKit/Sources/ElliotModel/RuleEngine.swift` | `MoveBlock.notVerifiedGreen(sign:)` + `.systemOwnedTransition` and their codes; `MoveContext.requiresVerifiedGreen` + `.prVerdict`, **without defaults**; two new `evaluateMove` branches; `nextCandidates` states its answer. |
| `ElliotKit/Sources/ElliotModel/NotificationPolicy.swift` | `systemMoveNotification` becomes an exhaustive switch over `MoveOrigin` and posts for `.autoDev`. |
| `ElliotKit/Sources/ElliotAppKit/Consequence.swift` | `arrivalNote` and `historyLabel` learn `.autoDev`; `reason` learns the two new blocks. |
| `ElliotKit/Sources/ElliotAppKit/PRStatusBlock.swift` | `ciText` / `ciTint` read `.passing`'s array. |
| `ElliotKit/Sources/ElliotAppKit/AppModel.swift` | `preview`'s `MoveContext` states its answer; `BoardService` and `MCPRequestHandler` are handed one shared `PRVerdictReader`. |
| `ElliotKit/Sources/ElliotIPC/NextRendering.swift` | `MoveBlockText.explain` and `.hint` learn the two new blocks. |
| `ElliotKit/Sources/ElliotEngine/BoardService.swift` | Holds a `PRVerdictReader`; `proposeMove` / `move` gain `requiresVerifiedGreen`; the `MoveContext` is filled from the reader. |
| `ElliotKit/Sources/ElliotEngine/MCPRequestHandler.swift` | Holds the same reader; `prStatusDTO` stops hand-writing `resolved(now:currentHeadOid: nil)`. |
| `ElliotKit/Tests/ElliotModelTests/PRStatusTests.swift` | Six `.passing(N)` assertions become `.passing([names])`; one new test names them. |
| `ElliotKit/Tests/ElliotModelTests/RuleEngineTests.swift` | A local `watched(...)` context helper; the PRSign matrix; the property test over the 25 transitions. |
| `ElliotKit/Tests/ElliotModelTests/NextStepTests.swift` | The one `MoveContext` states its answer; a test whose **name** carries why `nextCandidates` keeps `requiresVerifiedGreen: false`. |
| `ElliotKit/Tests/ElliotModelTests/NotificationPolicyTests.swift` | An auto-dev move posts, and says which column it reached. |
| `ElliotKit/Tests/ElliotAppKitTests/AppModelTests.swift` | The literal block list becomes `MoveBlockCase.allBlocks`; the `MoveContext` states its answer. |
| `ElliotKit/Tests/ElliotAppKitTests/RunsPaneEmptyStateTests.swift` | The literal block list becomes `MoveBlockCase`-driven. |
| `ElliotKit/Tests/ElliotAppKitTests/MoveHistoryTests.swift` | `allOrigins` gains `.autoDev`; the arrival-note test stops saying "system only". |
| `ElliotKit/Tests/ElliotAppKitTests/PRStatusPresentationTests.swift` | One `.passing(1)` assertion. |
| `ElliotKit/Tests/ElliotIPCTests/NextRenderingTests.swift` | A local `CaseIterable` shadow replaces the literal block list. |
| `ElliotKit/Tests/ElliotIPCTests/PRStatusWireTests.swift` | One `CIState.passing(3)` assertion. |
| `ElliotKit/Tests/ElliotEngineTests/BoardServiceTests.swift` | A merge asked for under `requiresVerifiedGreen: true` with no verdict is refused. |

---

## Task 1: `CIState.passing` carries the names

> ⛔ **This task exists only to make Option A expressible, and it is deliberately the one task whose deletion downgrades the design to Option B.**
> The open decision in `docs/superpowers/specs/2026-08-08-auto-dev-design.md` ("Open decision — what counts as green") offers three predicates. This plan takes **A**, the recommendation: `!isStale && sign == nil && merge == .clean && ci.hasBuildVerdict`. `hasBuildVerdict` needs the passing checks' **names**, and `CIState.passing` carries an `Int` today, so the names are discarded one line after they exist (`ElliotKit/Sources/ElliotModel/PRStatus.swift:323-324`).
> **To downgrade to Option B** (`!isStale && sign == nil && merge == .clean`): delete this task's whole diff, and delete the `&& ci.hasBuildVerdict` conjunct written in Task 2. Nothing else in this plan depends on either.
> ⚠ This does **not** reopen the arbitration recorded at `PRStatusTests.inertChecksStillCountAsPassing` (`ElliotKit/Tests/ElliotModelTests/PRStatusTests.swift:138-146`). That test says the *display* facet must not discount a check by name, and it stays true: `ci` still reports `.passing` with every non-verdict-free check counted, and `sign` is still `nil`. The name list added in this task is read by **`isMergeableUnattended` alone**.

**Files:**
- Modify: `ElliotKit/Sources/ElliotModel/PRStatus.swift:88` (the `CIState` case) and `:313-325` (`ciState`)
- Create: `ElliotKit/Sources/ElliotModel/NonBuildChecks.swift`
- Modify: `ElliotKit/Sources/ElliotAppKit/PRStatusBlock.swift:107-125` (`ciText` and `ciTint`; only line 111 changes)
- Test: `ElliotKit/Tests/ElliotModelTests/PRStatusTests.swift` (six assertions + one new test)
- Test: `ElliotKit/Tests/ElliotAppKitTests/PRStatusPresentationTests.swift:67`
- Test: `ElliotKit/Tests/ElliotIPCTests/PRStatusWireTests.swift:108`

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces:
  - `public enum CIState { case noChecks; case running; case passing([String]); case failing([String]); case unknown }` — `Sendable, Hashable`, `var code: String` unchanged (`"passing"`).
  - `public enum NonBuildChecks { public static let exactNames: Set<String>; public static let prefixes: [String]; public static func isInert(_ name: String) -> Bool }` in `ElliotModel`.
  - `public extension CIState { var hasBuildVerdict: Bool }` — `true` only when at least one passing check's name is not inert.

- [ ] **Step 1: Write the failing test**

Add to `ElliotKit/Tests/ElliotModelTests/PRStatusTests.swift`, immediately after `passingCountsTheChecks` (which ends at line 75):

```swift
    @Test("A passing rollup carries the names, not just how many there were")
    func passingNamesTheChecks() {
        // The names exist at this exact point and were thrown away one line
        // later. `isMergeableUnattended` is the reader that needs them: an
        // unattended merge has to be able to ask whether anything that
        // *builds* went green, and a count cannot answer that.
        let resolved = status(checks: [run("build", "SUCCESS"), run("test", "SUCCESS")]).fresh
        #expect(resolved.ci == .passing(["build", "test"]))
    }

    @Test("A non-verdict conclusion is left out of the names as well as the count")
    func passingNamesExcludeNonVerdicts() {
        let resolved = status(checks: [run("build", "SUCCESS"), run("deploy", "SKIPPED")]).fresh
        #expect(resolved.ci == .passing(["build"]))
    }

    @Test("An analyser is a passing check and is not a build verdict")
    func analysersAreNotBuildVerdicts() {
        // Both halves matter, and they are deliberately different answers about
        // the same rollup: `ci` still says two checks passed — that is the #174
        // arbitration, and it is untouched — while `hasBuildVerdict` says
        // nothing here built anything.
        let analysersOnly = status(checks: [
            run("CodeQL", "SUCCESS"), run("renovate/stability-days", "SUCCESS"),
        ]).fresh
        #expect(analysersOnly.ci == .passing(["CodeQL", "renovate/stability-days"]))
        #expect(!analysersOnly.ci.hasBuildVerdict)

        let withABuild = status(checks: [
            run("CodeQL", "SUCCESS"), run("build-and-test", "SUCCESS"),
        ]).fresh
        #expect(withABuild.ci.hasBuildVerdict)
    }

    @Test("Every state that is not a pass has no build verdict")
    func onlyPassingCanCarryABuildVerdict() {
        #expect(!CIState.noChecks.hasBuildVerdict)
        #expect(!CIState.running.hasBuildVerdict)
        #expect(!CIState.failing(["build"]).hasBuildVerdict)
        #expect(!CIState.unknown.hasBuildVerdict)
        #expect(!CIState.passing([]).hasBuildVerdict)
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd ElliotKit && swift test --filter PRStatusTests`
Expected: FAIL — the test target does not compile. The first diagnostic is
`error: cannot convert value of type '[String]' to expected argument type 'Int'`
on `.passing(["build", "test"])`, followed by
`error: value of type 'CIState' has no member 'hasBuildVerdict'`.

- [ ] **Step 3: Write minimal implementation**

3a. In `ElliotKit/Sources/ElliotModel/PRStatus.swift`, replace line 88 — the case sits between `case running` (87) and `case failing([String])` (89):

```swift
    case passing(Int)
```

with:

```swift
    /// The checks that reached a verdict and passed, by name.
    ///
    /// Symmetric with `failing([String])`, which has always carried its labels.
    /// The names exist at `ciState` and were discarded one line later, which
    /// made the one question an unattended merge has to ask — *did anything
    /// that builds go green?* — unanswerable from this type. `ResolvedPRStatus`
    /// carries only the `CIState`, so a count could never have reached
    /// `isMergeableUnattended`.
    case passing([String])
```

3b. In the same file, replace lines 323-324 (the tail of `ciState`):

```swift
        let passed = checks.count { !$0.isNonVerdict }
        return passed == 0 ? .noChecks : .passing(passed)
```

with:

```swift
        let passed = checks.filter { !$0.isNonVerdict }.map(\.label)
        return passed.isEmpty ? .noChecks : .passing(passed)
```

3c. Create `ElliotKit/Sources/ElliotModel/NonBuildChecks.swift`:

```swift
import Foundation

/// Check names that are published by something other than a build.
///
/// **Data, not logic.** Adding a name is one line and nothing else changes,
/// which is the shape of `repo-audit`'s `board/non_build_checks.json` — the
/// file this list is seeded from, verbatim, on 2026-08-08. That file exists
/// because this exact family of false greens was implemented twice and got it
/// wrong twice: a board reading GitHub's *aggregate* rollup announced 43
/// mergeable pull requests where 2 were mergeable, because a status published
/// by Renovate and a green from a hosted analyser both count as successes there.
///
/// ⚠️ This is **not** the judgement `GHMergeStatus.StatusCheck.isNonVerdict`
/// declines to make, and it does not overturn it. `isNonVerdict` reads GitHub's
/// own `conclusion` vocabulary — `SKIPPED`, `NEUTRAL`, `STALE` — needs no list
/// and drifts with nothing, and it still governs `CIState` and `PRSign`: a
/// CodeQL run that genuinely succeeded is still a pass on the card and in the
/// panel. This list is read by `ResolvedPRStatus.isMergeableUnattended` and by
/// nothing else, because that is the one caller allowed to merge to a default
/// branch on github.com with nobody watching.
///
/// ⚠️ The failure mode is one-sided and worth naming: a name **missing** from
/// this list counts as a build, so a short list produces a false green. A name
/// wrongly **in** it only refuses a merge, which a human can always make
/// themselves. Do not add a name without having seen the pull request it
/// appeared on — the portfolio's rule, `pr_verdict.py --census`, never intuition.
public enum NonBuildChecks {

    /// Matched exactly, case-sensitively — these are the strings GitHub renders.
    public static let exactNames: Set<String> = [
        "CodeQL",
        "Codacy Static Code Analysis",
        "lint-pr-title",
        "changes",
    ]

    /// Matched as a prefix, because these families name themselves per update
    /// or per language and cannot be enumerated.
    public static let prefixes: [String] = [
        "renovate/",
        "dependabot/",
        "Analyze (",
    ]

    /// Whether a check of this name proves nothing about whether the code builds.
    public static func isInert(_ name: String) -> Bool {
        if exactNames.contains(name) { return true }
        return prefixes.contains { name.hasPrefix($0) }
    }
}

public extension CIState {
    /// At least one check that both reached a verdict and is not an analyser.
    ///
    /// Deliberately false for every state that is not `.passing`: `.noChecks`
    /// is an absence of measurement, `.running` is a measurement that has not
    /// finished, `.failing` is a verdict against, and `.unknown` is a refusal to
    /// answer. None of the four is a build that went green.
    var hasBuildVerdict: Bool {
        guard case .passing(let names) = self else { return false }
        return names.contains { !NonBuildChecks.isInert($0) }
    }
}
```

3d. In `ElliotKit/Sources/ElliotAppKit/PRStatusBlock.swift`, replace line 111:

```swift
        case .passing(let count): count == 1 ? "1 check passed" : "\(count) checks passed"
```

with:

```swift
        case .passing(let names): names.count == 1 ? "1 check passed" : "\(names.count) checks passed"
```

(`ciTint`'s `case .passing: Palette.verified` at line 121 needs no change — it binds nothing.)

3e. Update the eight existing assertions that name a count:

| File | Line | From | To |
|---|---|---|---|
| `ElliotKit/Tests/ElliotModelTests/PRStatusTests.swift` | 71 | `.passing(2)` | `.passing(["build", "test"])` |
| `ElliotKit/Tests/ElliotModelTests/PRStatusTests.swift` | 99 | `.passing(1)` | `.passing(["ci/travis"])` |
| `ElliotKit/Tests/ElliotModelTests/PRStatusTests.swift` | 118 | `.passing(1)` | `.passing(["build"])` |
| `ElliotKit/Tests/ElliotModelTests/PRStatusTests.swift` | 134 | `.passing(1)` | `.passing(["CodeQL"])` |
| `ElliotKit/Tests/ElliotModelTests/PRStatusTests.swift` | 144 | `.passing(2)` | `.passing(["CodeQL", "renovate/stability-days"])` |
| `ElliotKit/Tests/ElliotModelTests/PRStatusTests.swift` | 248 | `.passing(1)` | `.passing(["build"])` |
| `ElliotKit/Tests/ElliotAppKitTests/PRStatusPresentationTests.swift` | 67 | `.passing(1)` | `.passing(["build"])` |
| `ElliotKit/Tests/ElliotIPCTests/PRStatusWireTests.swift` | 108 | `CIState.passing(3).code` | `CIState.passing(["build", "test", "lint"]).code` |

Verify none is left: `cd ElliotKit && grep -rn 'passing([0-9]' Sources Tests` must print nothing.

- [ ] **Step 4: Run test to verify it passes**

Run: `cd ElliotKit && swift test --filter PRStatusTests`
Expected: PASS
Then the neighbours that were edited:
Run: `cd ElliotKit && swift test --filter PRStatusPresentationTests`
Expected: PASS
Run: `cd ElliotKit && swift test --filter PRStatusWireTests`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git rev-parse --abbrev-ref HEAD
git add ElliotKit/Sources/ElliotModel/PRStatus.swift \
        ElliotKit/Sources/ElliotModel/NonBuildChecks.swift \
        ElliotKit/Sources/ElliotAppKit/PRStatusBlock.swift \
        ElliotKit/Tests/ElliotModelTests/PRStatusTests.swift \
        ElliotKit/Tests/ElliotAppKitTests/PRStatusPresentationTests.swift \
        ElliotKit/Tests/ElliotIPCTests/PRStatusWireTests.swift
git commit -m "feat(model): a passing rollup carries its check names, and names what is not a build"
```

---

## Task 2: `isMergeableUnattended`

**Files:**
- Create: `ElliotKit/Sources/ElliotModel/MergeableUnattended.swift`
- Test: `ElliotKit/Tests/ElliotModelTests/MergeableUnattendedTests.swift`

**Interfaces:**
- Consumes: `CIState.hasBuildVerdict` and `CIState.passing([String])` from Task 1.
- Produces: `public extension ResolvedPRStatus { var isMergeableUnattended: Bool }` — the single predicate the rule engine calls in Task 7.

- [ ] **Step 1: Write the failing test**

Create `ElliotKit/Tests/ElliotModelTests/MergeableUnattendedTests.swift`:

```swift
import Foundation
import Testing

@testable import ElliotModel

private let readAt = Date(timeIntervalSince1970: 1_700_000_000)

/// A resolved reading with every facet stated.
///
/// Built directly rather than through `PRStatus.resolved`, on purpose: the
/// precedence that derives `sign` from the three facets is `PRStatus.sign`'s and
/// is tested there. What is under test here is the predicate, so its inputs are
/// given rather than computed — including combinations `sign` would never
/// produce, because a predicate that is only ever fed consistent inputs is a
/// predicate nobody has actually cornered.
private func reading(
    ci: CIState = .passing(["build-and-test"]),
    merge: MergeState = .clean,
    review: ReviewState = .approved,
    isStale: Bool = false,
    sign: PRSign? = nil
) -> ResolvedPRStatus {
    ResolvedPRStatus(
        ci: ci, merge: merge, review: review,
        checkedAt: readAt, headRefOid: "a1b2c3d4e5f6", isStale: isStale, sign: sign)
}

private func check(_ name: String) -> GHMergeStatus.StatusCheck {
    GHMergeStatus.StatusCheck(name: name, conclusion: "SUCCESS", status: "COMPLETED")
}

/// The same reading, **derived** rather than stated: a real `PRStatus` put
/// through `PRStatus.resolved(now:currentHeadOid:)`.
///
/// Both holes below are holes *in `PRStatus.sign`*, so a fixture that sets
/// `sign` by hand cannot reproduce either of them — `#expect(x.sign == nil)`
/// would only read back what the helper above was told, and would go on passing
/// on the day `sign` starts catching `unstable`. These two go through the real
/// derivation, which is what makes the `sign == nil` line a measurement instead
/// of a restatement of its own input.
private func derived(
    checks: [GHMergeStatus.StatusCheck] = [check("build-and-test")],
    mergeStateStatus: String = "CLEAN",
    mergeable: String = "MERGEABLE",
    reviewDecision: String = "APPROVED"
) -> ResolvedPRStatus {
    PRStatus(
        repoID: UUID(), prNumber: 7, headRefOid: "a1b2c3d4e5f6", checkedAt: readAt,
        rawMergeStateStatus: mergeStateStatus, rawMergeable: mergeable,
        rawReviewDecision: reviewDecision, checks: checks
    ).resolved(now: readAt, currentHeadOid: "a1b2c3d4e5f6")
}

/// What an agent with nobody behind it is allowed to merge to a default branch.
///
/// Every test here is a **refusal** except the first, and that is the shape of
/// the feature: the obvious predicate — `sign == nil` — was measured too weak in
/// two separate ways, and each of those two ways has a test below whose failure
/// would restore it.
@Suite("Mergeable unattended")
struct MergeableUnattendedTests {

    @Test("A fresh, clean, reviewed pull request with a real build is mergeable")
    func theOneGreen() {
        #expect(reading().isMergeableUnattended)
    }

    @Test("A sign of any kind refuses, whatever else is true")
    func anySignRefuses() {
        let signs: [PRSign] = [
            .conflict, .checksFailing(count: 1), .changesRequested, .reviewRequired,
            .mergeBlocked, .checksRunning, .noBuild, .unknown,
        ]
        for sign in signs {
            #expect(!reading(sign: sign).isMergeableUnattended, "\(sign.code) was accepted")
        }
    }

    @Test("A stale reading refuses even with nothing to report")
    func stalenessRefuses() {
        // `sign` is nil here on purpose. A reading that aged out or is about a
        // commit nobody is reviewing any more has nothing to report *because it
        // reports nothing at all*, and reading that as an all-clear is the
        // difference between "I know it is fine" and "I do not know".
        #expect(!reading(isStale: true).isMergeableUnattended)
    }

    @Test("UNSTABLE is not clean, and sign == nil does not catch it")
    func unstableRefuses() {
        // The first measured hole in `sign == nil`: `PRStatus.sign` blocks only
        // `.conflict` and `.behind`/`.blocked`, so `MergeState.unstable` reaches
        // `return nil`. The panel paints that same state in `Palette.attention`
        // and calls it "mergeable, not every check is green".
        //
        // `derived`, not `reading`: the hole is in `sign`'s own precedence, so a
        // hand-set `sign` would assert nothing but itself.
        let unstable = derived(mergeStateStatus: "UNSTABLE")
        #expect(unstable.merge == .unstable, "the fixture no longer reaches UNSTABLE")
        #expect(unstable.sign == nil, "the fixture no longer reproduces the hole")
        #expect(!unstable.isMergeableUnattended)
    }

    @Test("A green that is only an analyser refuses")
    func analyserOnlyGreenRefuses() {
        // The second measured hole, and the reason Task 1 exists. Nothing here
        // built anything; a hosted analyser and a Renovate status both count as
        // successes to GitHub's aggregate rollup.
        //
        // `derived` again, and for the same reason: `ci` has to be computed by
        // `ciState` from real checks, or the names under test are the ones this
        // test made up rather than the ones a rollup produces.
        let analysersOnly = derived(checks: [check("CodeQL"), check("renovate/stability-days")])
        #expect(analysersOnly.ci == .passing(["CodeQL", "renovate/stability-days"]))
        #expect(analysersOnly.sign == nil, "the fixture no longer reproduces the hole")
        #expect(!analysersOnly.isMergeableUnattended)

        // One real build alongside them is enough — the list refuses greens, it
        // does not require purity.
        #expect(derived(checks: [check("CodeQL"), check("build-and-test")]).isMergeableUnattended)
    }

    @Test("No check at all is never a green, however clean the merge is")
    func noChecksRefuses() {
        #expect(!reading(ci: .noChecks, sign: nil).isMergeableUnattended)
        #expect(!reading(ci: .running, sign: nil).isMergeableUnattended)
        #expect(!reading(ci: .unknown, sign: nil).isMergeableUnattended)
        #expect(!reading(ci: .failing(["build"]), sign: nil).isMergeableUnattended)
    }

    @Test("An unreviewed pull request on a solo repository still merges")
    func noReviewIsNotARefusal() {
        // `ReviewState.none` is every pull request on a repository with one
        // author, so refusing it would refuse the whole board. `PRSign` already
        // makes that call — this states that the predicate does not add a
        // second, stricter opinion of its own.
        #expect(reading(review: .none).isMergeableUnattended)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd ElliotKit && swift test --filter MergeableUnattendedTests`
Expected: FAIL — the target does not compile:
`error: value of type 'ResolvedPRStatus' has no member 'isMergeableUnattended'`.

- [ ] **Step 3: Write minimal implementation**

Create `ElliotKit/Sources/ElliotModel/MergeableUnattended.swift`:

```swift
import Foundation

public extension ResolvedPRStatus {
    /// Whether an agent with nobody behind it may merge this.
    ///
    /// **Stricter than `sign == nil`, deliberately.** `sign` answers "is there
    /// one thing worth drawing on a card", and it was measured too weak for
    /// merge authority in two ways:
    ///
    /// 1. `PRStatus.sign` blocks `.conflict`, `.blocked` and `.behind`, so
    ///    `MergeState.unstable` reaches `return nil` — the state
    ///    `PRStatusBlock` paints in `Palette.attention` and calls *mergeable,
    ///    not every check is green*. Hence `merge == .clean`.
    /// 2. `StatusCheck.isNonVerdict` filters `SKIPPED|NEUTRAL|STALE` and
    ///    nothing else, so a pull request whose only green is a hosted analyser
    ///    is `.passing`. Hence `ci.hasBuildVerdict`, which reads
    ///    `NonBuildChecks`.
    ///
    /// `isStale` is asked first and separately: a reading that aged out, or is
    /// about a commit that is no longer the head, resolves to `sign: .unknown`
    /// today — but that is a consequence of `resolved(now:currentHeadOid:)`
    /// rather than a fact this predicate is entitled to lean on, and a merge is
    /// the one decision where "I do not know" must not read as "nothing to
    /// report".
    ///
    /// ⚠️ To downgrade this to the design's **Option B**, delete
    /// `&& ci.hasBuildVerdict` and delete `NonBuildChecks.swift` with the
    /// `CIState.passing([String])` change it depends on. Option B closes the
    /// `unstable` hole and leaves the analyser one open, and nothing else in the
    /// board reads either.
    ///
    /// One property on one type, read from one place: `evaluateMove`'s
    /// `(.inReview, .done)` branch. Changing what counts as green is changing
    /// this expression and nothing else.
    var isMergeableUnattended: Bool {
        !isStale && sign == nil && merge == .clean && ci.hasBuildVerdict
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd ElliotKit && swift test --filter MergeableUnattendedTests`
Expected: PASS — 7 tests.

- [ ] **Step 5: Commit**

```bash
git rev-parse --abbrev-ref HEAD
git add ElliotKit/Sources/ElliotModel/MergeableUnattended.swift \
        ElliotKit/Tests/ElliotModelTests/MergeableUnattendedTests.swift
git commit -m "feat(model): one predicate decides what an unattended agent may merge"
```

---

## Task 3: `MoveOrigin.autoDev`, and an exhaustive `allowsSideEffects`

**Files:**
- Modify: `ElliotKit/Sources/ElliotModel/SkillRun.swift:209-231`
- Modify: `ElliotKit/Sources/ElliotAppKit/Consequence.swift:104-146`
- Create: `ElliotKit/Tests/ElliotModelTests/MoveOriginTests.swift`
- Test: `ElliotKit/Tests/ElliotAppKitTests/MoveHistoryTests.swift:41-47` and `:173-180`

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces:
  - `MoveOrigin.autoDev(sessionID: UUID)` — a seventh origin, `Codable, Sendable, Hashable`.
  - `MoveOrigin.allowsSideEffects` stays `Bool` and becomes an exhaustive `switch`: `true` for `.userDrag`, `.mcp`, `.autoDev`; `false` for `.system`.
  - `MoveOrigin.arrivalNote` returns a sentence for `.autoDev` (it returned `nil` for anything but `.system`).
  - `MoveOrigin.historyLabel` returns `"Auto-dev"` for `.autoDev`.

- [ ] **Step 1: Write the failing test**

1a. Create `ElliotKit/Tests/ElliotModelTests/MoveOriginTests.swift`:

```swift
import Foundation
import Testing

@testable import ElliotModel

/// The one property that decides whether an unattended agent starts.
///
/// It had no test at all, and it was written as `if case .system = self { return
/// false }; return true` — a shape in which a seventh origin inherits `true` in
/// silence. The switch below the fix is the real guard; this file is its
/// witness, and it is a witness worth having because the thing being granted is
/// a `claude -p` at `bypassPermissions` inside a real checkout.
@Suite("Move origin")
struct MoveOriginTests {

    private static let systemReasons: [MoveOrigin.SystemReason] = [
        .prBecameReady, .prMergedExternally, .reconciliation, .githubImport,
    ]

    @Test("A system move never allows a side effect, for any of its four reasons")
    func systemReasonsAllowNothing() {
        for reason in Self.systemReasons {
            #expect(
                !MoveOrigin.system(reason: reason).allowsSideEffects,
                "\(reason.rawValue) would fire a skill"
            )
        }
    }

    @Test("The three origins that are somebody's decision all allow side effects")
    func decisionsAllowSideEffects() {
        #expect(MoveOrigin.userDrag.allowsSideEffects)
        #expect(MoveOrigin.mcp(client: "claude-code").allowsSideEffects)
        // Auto-dev is the whole point of the case: a session that could not fire
        // a skill would move cards and do nothing.
        #expect(MoveOrigin.autoDev(sessionID: UUID()).allowsSideEffects)
    }

    @Test("An auto-dev origin survives a round trip through its stored JSON")
    func autoDevIsCodable() throws {
        // `moveAudit.origin` is a JSON column, so the synthesised `Codable` is
        // the on-disk contract for every move this feature makes.
        let sessionID = UUID()
        let data = try JSONEncoder().encode(MoveOrigin.autoDev(sessionID: sessionID))
        let back = try JSONDecoder().decode(MoveOrigin.self, from: data)
        #expect(back == .autoDev(sessionID: sessionID))
    }
}
```

1b. In `ElliotKit/Tests/ElliotAppKitTests/MoveHistoryTests.swift`, replace lines 45-47:

```swift
    private static var allOrigins: [MoveOrigin] {
        [.userDrag, .mcp(client: "elliot-mcp")] + systemReasons.map { .system(reason: $0) }
    }
```

with:

```swift
    private static var allOrigins: [MoveOrigin] {
        [.userDrag, .mcp(client: "elliot-mcp"), .autoDev(sessionID: autoDevSession)]
            + systemReasons.map { .system(reason: $0) }
    }

    /// Fixed rather than fresh, so a failure message names the same value twice.
    private static let autoDevSession = UUID(uuidString: "00000000-0000-0000-0000-00000000AD00")!
```

1c. In the same file, replace the whole test at lines 173-180:

```swift
    @Test("The arrival sentence still speaks only for system moves")
    func arrivalNoteRemainsSystemOnly() {
        #expect(MoveOrigin.userDrag.arrivalNote == nil)
        #expect(MoveOrigin.mcp(client: "agent-x").arrivalNote == nil)
        for reason in Self.systemReasons {
            #expect(MoveOrigin.system(reason: reason).arrivalNote != nil)
        }
    }
```

with:

```swift
    @Test("The arrival sentence speaks for every move nobody made by hand")
    func arrivalNoteSpeaksForUnmadeMoves() {
        // It was "system moves only" until auto-dev, and the boundary was never
        // the `.system` case: it is whether the reader could have been the one
        // who moved the card. A drag and a `board_move_card` are gestures
        // somebody made and watched happen; an auto-dev move is not.
        #expect(MoveOrigin.userDrag.arrivalNote == nil)
        #expect(MoveOrigin.mcp(client: "agent-x").arrivalNote == nil)
        #expect(MoveOrigin.autoDev(sessionID: UUID()).arrivalNote != nil)
        for reason in Self.systemReasons {
            #expect(MoveOrigin.system(reason: reason).arrivalNote != nil)
        }
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd ElliotKit && swift test --filter MoveOriginTests`
Expected: FAIL — the target does not compile:
`error: type 'MoveOrigin' has no member 'autoDev'`.

- [ ] **Step 3: Write minimal implementation**

3a. In `ElliotKit/Sources/ElliotModel/SkillRun.swift`, replace lines 211-231:

```swift
public enum MoveOrigin: Codable, Sendable, Hashable {
    case userDrag
    case mcp(client: String)
    case system(reason: SystemReason)

    public enum SystemReason: String, Codable, Sendable, Hashable {
        case prBecameReady
        case prMergedExternally
        case reconciliation
        /// A column set by adopting what GitHub already said. Like every system
        /// reason it maps to `.noAction`, so importing fires no skill.
        case githubImport
    }

    /// System moves react to reality rather than changing it, so they must
    /// never fire a skill.
    public var allowsSideEffects: Bool {
        if case .system = self { return false }
        return true
    }
}
```

with:

```swift
public enum MoveOrigin: Codable, Sendable, Hashable {
    case userDrag
    case mcp(client: String)
    case system(reason: SystemReason)
    /// A move an auto-dev session made on its own, with nobody watching.
    ///
    /// It carries the session so the trail can be read back per session — a
    /// board that recorded only "the board did it" could not tell one night's
    /// run from the next.
    ///
    /// **Persisted, and there is no downgrade path.** `moveAudit.origin` is a
    /// JSON column (`Migrations.swift:344`) written through the synthesised
    /// `Codable`, so this case is additive for reading rows an older build
    /// wrote, and unreadable by an older build that meets a row this one wrote.
    /// It does **not** travel the IPC wire: `ElliotRequest.moveCard` carries
    /// `(id, to, followUps)`, `MoveDTO` carries no origin, and
    /// `MCPRequestHandler.moveCard` hardcodes `.mcp(client:)` — so this change
    /// does not bump `elliotProtocolVersion`.
    case autoDev(sessionID: UUID)

    public enum SystemReason: String, Codable, Sendable, Hashable {
        case prBecameReady
        case prMergedExternally
        case reconciliation
        /// A column set by adopting what GitHub already said. Like every system
        /// reason it maps to `.noAction`, so importing fires no skill.
        case githubImport
    }

    /// System moves react to reality rather than changing it, so they must
    /// never fire a skill.
    ///
    /// **Exhaustive, with no `default:` and no `if case`.** It was
    /// `if case .system = self { return false }; return true`, and that shape
    /// hands `true` to every case added after it — silently, on the single
    /// property that decides whether an unattended `claude -p` starts at
    /// `bypassPermissions` inside a real checkout. A switch makes the next case
    /// a compile error instead of a gift.
    public var allowsSideEffects: Bool {
        switch self {
        case .userDrag, .mcp, .autoDev: true
        case .system: false
        }
    }
}
```

3b. In `ElliotKit/Sources/ElliotAppKit/Consequence.swift`, replace `arrivalNote` **and its whole doc comment** (lines 105-118 — 105 is `/// Who put the card here…`, 118 is the property's closing brace). The block below re-states the existing three doc paragraphs verbatim and adds a fourth, so the range must start at 105 or the first line is left behind twice:

```swift
    /// Who put the card here, when the answer is "not you".
    ///
    /// In Review is the only column Elliot fills by itself, and a card that
    /// appeared there explained nothing about how it arrived. Display copy, not
    /// a rule: the decision was `PRWatcher`'s and is already recorded.
    ///
    /// Exhaustive since auto-dev. The old `guard case .system` would have
    /// swallowed the new case and left a card that an unattended session moved
    /// explaining nothing at all about how it got there — which is the one
    /// column caption a reader who was not in the room actually needs.
    var arrivalNote: String? {
        switch self {
        case .userDrag, .mcp:
            return nil
        case .autoDev:
            return "Elliot moved this here — an unattended session is advancing this card."
        case .system(let reason):
            switch reason {
            case .prBecameReady: return "Elliot moved this here — the pull request went ready."
            case .prMergedExternally: return "Elliot moved this here — it was merged on GitHub."
            case .reconciliation: return "Elliot moved this here — recovered after a restart."
            case .githubImport: return "Elliot placed this here — imported from GitHub."
            }
        }
    }
```

3c. In the same file, add one arm to `historyLabel` (the switch at lines 133-145), between the `.mcp` arm and the `.system` arm:

```swift
        case .autoDev:
            // The session id is deliberately not rendered: this is one column of
            // a tabular line, and a UUID there would push the rest off the
            // panel. PR5's report band is where a session is named.
            return "Auto-dev"
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd ElliotKit && swift test --filter MoveOriginTests`
Expected: PASS — 3 tests.
Run: `cd ElliotKit && swift test --filter MoveHistoryTests`
Expected: PASS — in particular `historyLabelIsTotal` (seven origins, seven distinct labels: `Dragged`, `MCP · elliot-mcp`, `Auto-dev`, and the four `Elliot: …`) and `historyLabelNeverConvergesWithArrivalNote` (`"Auto-dev"` is not a substring of any arrival sentence, and no sentence is a substring of it).

- [ ] **Step 5: Commit**

```bash
git rev-parse --abbrev-ref HEAD
git add ElliotKit/Sources/ElliotModel/SkillRun.swift \
        ElliotKit/Sources/ElliotAppKit/Consequence.swift \
        ElliotKit/Tests/ElliotModelTests/MoveOriginTests.swift \
        ElliotKit/Tests/ElliotAppKitTests/MoveHistoryTests.swift
git commit -m "feat(model,app): a seventh move origin, and a switch that cannot hand it side effects"
```

---

## Task 4: an auto-dev move is not silent

**Files:**
- Modify: `ElliotKit/Sources/ElliotModel/NotificationPolicy.swift:139-168` (the whole of `systemMoveNotification`)
- Test: `ElliotKit/Tests/ElliotModelTests/NotificationPolicyTests.swift`

**Interfaces:**
- Consumes: `MoveOrigin.autoDev(sessionID:)` from Task 3.
- Produces: nothing new for later tasks. `notification(for:preferences:appIsActive:)` keeps its signature; only what it answers for `.autoDev` changes.

- [ ] **Step 1: Write the failing test**

Add to `ElliotKit/Tests/ElliotModelTests/NotificationPolicyTests.swift`, after `systemMovesNameThePullRequest` (which ends at line 221):

```swift
    // `throws` + `try #require`, deliberately unlike the `try!` its neighbours in
    // this file use. A failed `#require` throws; `try!` turns that into a trap,
    // which takes the whole `swift test` process down and reports a crash rather
    // than a named failing test — and these two are *written to fail first*, so
    // that difference is the whole of step 2 below.

    @Test("An auto-dev move posts, and says which column it reached")
    func autoDevMovesArePosted() throws {
        // The load-bearing positive. `systemMoveNotification` filtered on
        // `guard case .system`, so the one feature that runs with nobody
        // watching would have produced no notification at all — the worst
        // possible silence, and one that reads exactly like a session that
        // never started.
        let moved = MoveAudit(
            cardID: UUID(), from: .inReview, to: .done,
            origin: .autoDev(sessionID: UUID()), at: .distantPast
        )
        let posted = try #require(decide(.systemMove(audit: moved, card: card(pr: 57), repo: repo)))

        #expect(posted.category == .boardMovedItself)
        #expect(posted.body.contains("PR #57"))
        #expect(posted.body.contains("Done"))
        #expect(!posted.playsSound, "an unattended session running normally is not an interruption")
    }

    @Test("An auto-dev move with no pull request yet names the card instead")
    func autoDevMoveWithoutAPullRequestNamesTheCard() throws {
        // Backlog → To Do is the first move a session makes, and there is no
        // pull request at that point. A body reading "PR #nil" would be worse
        // than one reading the title.
        let filed = MoveAudit(
            cardID: UUID(), from: .backlog, to: .todo,
            origin: .autoDev(sessionID: UUID()), at: .distantPast
        )
        let posted = try #require(
            decide(.systemMove(audit: filed, card: card(title: "Stream the run log"), repo: repo))
        )
        #expect(posted.body.contains("Stream the run log"))
        #expect(posted.body.contains("To Do"))
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd ElliotKit && swift test --filter NotificationPolicyTests`
Expected: FAIL at runtime, not at compile time — `.autoDev` already exists after Task 3 and `systemMoveNotification` simply returns `nil` for it. Both new tests fail on their `#require`, each reporting
`Expectation failed: decide(.systemMove(...)) ->  nil` and
`Issue recorded: Expected non-nil value of type 'BoardNotification'`, and the run ends with **exactly 2 tests failed** rather than a crash — every other test in the suite still passes. If the process aborts instead of reporting, a `try!` was left in.

- [ ] **Step 3: Write minimal implementation**

In `ElliotKit/Sources/ElliotModel/NotificationPolicy.swift`, replace lines 139-168 (the whole of `systemMoveNotification`, from `private func systemMoveNotification(` to its closing brace) with:

```swift
private func systemMoveNotification(
    audit: MoveAudit, card: Card, repo: Repo
) -> BoardNotification? {
    // Exhaustive over `MoveOrigin`, with no `default:`. It was
    // `guard case .system … else { return nil }`, and under that shape a new
    // origin falls straight through to silence. Silence is the right answer for
    // a gesture somebody made and watched happen; it is the worst possible
    // answer for a session running with nobody in the room, which is exactly
    // the origin that arrived next.
    let body: String
    switch audit.origin {
    case .userDrag, .mcp:
        // A drag and a `board_move_card` are gestures someone made and watched.
        return nil

    case .autoDev:
        // Named by the column reached rather than by the act, because the acts
        // are already named elsewhere and the thing a reader who walked away
        // wants is how far it got.
        body = "\(prLabel(card)) — an auto-dev session moved it to \(audit.to.displayName)."

    case .system(let reason):
        switch reason {
        case .prBecameReady:
            body = "\(prLabel(card)) is ready — moved to In Review."
        case .prMergedExternally:
            body = "\(prLabel(card)) was merged — moved to Done."
        case .reconciliation, .githubImport:
            // Both happen at launch, with the window in front of you, and
            // describe what was already true rather than something that just
            // happened.
            return nil
        }
    }

    return BoardNotification(
        identifier: identifier(for: card),
        threadIdentifier: identifier(for: repo),
        category: .boardMovedItself,
        title: repo.nameWithOwner,
        body: body,
        playsSound: false,
        cardID: card.id,
        repoID: repo.id
    )
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd ElliotKit && swift test --filter NotificationPolicyTests`
Expected: PASS. `userOriginMovesPostNothing` and `launchTimeSystemReasonsPostNothing` must still pass unchanged — the two negatives are what the exhaustive switch had to preserve.

- [ ] **Step 5: Commit**

```bash
git rev-parse --abbrev-ref HEAD
git add ElliotKit/Sources/ElliotModel/NotificationPolicy.swift \
        ElliotKit/Tests/ElliotModelTests/NotificationPolicyTests.swift
git commit -m "feat(model): an unattended session's moves are not silent"
```

---

## Task 5: `MoveContext` gains two fields, without defaults

**Files:**
- Modify: `ElliotKit/Sources/ElliotModel/RuleEngine.swift:56-84` (the struct and its memberwise init) and `:209-232` (`nextCandidates`)
- Modify: `ElliotKit/Sources/ElliotEngine/BoardService.swift:98-103`
- Modify: `ElliotKit/Sources/ElliotAppKit/AppModel.swift:1038-1045`
- Test: `ElliotKit/Tests/ElliotModelTests/RuleEngineTests.swift` (19 construction sites → one local helper)
- Test: `ElliotKit/Tests/ElliotModelTests/NextStepTests.swift:30-40` and a new test
- Test: `ElliotKit/Tests/ElliotAppKitTests/AppModelTests.swift:204-207`

**Interfaces:**
- Consumes: `ResolvedPRStatus` (already in `ElliotModel`, `Sendable, Hashable`, `PRStatus.swift:213`).
- Produces:
  - `MoveContext.requiresVerifiedGreen: Bool` and `MoveContext.prVerdict: ResolvedPRStatus?`, both **without default values** in the memberwise init, whose full signature becomes
    `init(repoIsEnabled: Bool = true, activeRunID: UUID? = nil, allowSideEffects: Bool = true, providedFollowUps: [String]? = nil, requiresVerifiedGreen: Bool, prVerdict: ResolvedPRStatus?)`.
  - A test-only helper in `RuleEngineTests.swift`:
    `private func watched(repoIsEnabled: Bool = true, activeRunID: UUID? = nil, allowSideEffects: Bool = true, providedFollowUps: [String]? = nil) -> MoveContext`.
- ⚠ `evaluateMove`'s behaviour does not change in this task. The two new fields are carried and read by nobody until Task 7.

- [ ] **Step 1: Write the failing test**

Add to `ElliotKit/Tests/ElliotModelTests/NextStepTests.swift`, at the end of the suite — after `inReviewIsReadyWithEmptyFollowUps`, which is the last test, and before the suite's closing brace at line 133:

```swift
    /// The name carries the reason, because two tests already established this
    /// by accident and neither said why.
    @Test("board_next never demands a verified green, because an agent has a human behind it")
    func nextCandidatesAnswerForAHumansProxy() throws {
        // `board_next` answers *what an agent can do*, and an agent is a
        // human's proxy with a human behind it. The restraint belongs to the
        // caller that has nobody — `AutoDevService` builds its own
        // `MoveContext`; it does not borrow the board's.
        //
        // The sharper reason is that `OfflineResponder` cannot know a verdict:
        // it holds a read-only snapshot and can reach neither `gh` nor the
        // network. If `nextCandidates` demanded one, the snapshot's answer would
        // *mean* "I could not ask" while *encoding* as "the CI is not green" —
        // and `OfflineParityTests` compares encoded bytes, so it would pass
        // green on exactly that disagreement.
        let merge = card(column: .inReview, prNumber: 7)
        let repo = Repo(
            id: merge.repoID, path: "/tmp/e", nameWithOwner: "phmatray/Elliot", displayName: "Elliot"
        )
        let candidates = nextCandidates(cards: [merge], repos: [repo], activeRunIDs: [:])
        let candidate = try #require(candidates.first)

        #expect(candidate.context.requiresVerifiedGreen == false)
        #expect(candidate.context.prVerdict == nil)
        // And the consequence that matters: it still reads as ready. A verdict
        // demanded here would have reported the one move an agent can actually
        // make as blocked.
        #expect(rankNextSteps(candidates).first?.isReady == true)
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd ElliotKit && swift test --filter NextStepTests`
Expected: FAIL — the target does not compile:
`error: value of type 'MoveContext' has no member 'requiresVerifiedGreen'`.

- [ ] **Step 3: Write minimal implementation**

3a. In `ElliotKit/Sources/ElliotModel/RuleEngine.swift`, replace lines **69-83** — from the `providedFollowUps` doc comment (69) to the memberwise init's closing brace (83). ⚠ Not 84: that is `MoveContext`'s own closing brace, which the block below does not carry.

```swift
    /// `nil` means "not collected yet" and produces `.needsInput`. An explicit
    /// empty array means "no follow-ups" and lets the merge proceed.
    public var providedFollowUps: [String]?

    /// This move must not merge on anything short of a verified green.
    ///
    /// Named for the rule, not for the caller: `.mcp` and `.userDrag` set it
    /// false today, and a future caller that wants the restraint asks for it by
    /// name rather than by claiming to be unwatched. It is **set explicitly by
    /// the caller** rather than derived from `MoveOrigin`, because the word
    /// "unattended" already has a settled meaning in this package — about
    /// twenty uses in `Sources`, all naming the *child process* — under which a
    /// drag is the canonical unattended gesture.
    public var requiresVerifiedGreen: Bool

    /// What `gh` established about the pull request, already resolved against
    /// the clock and the current head. `nil` is *nothing established*, which is
    /// not a green.
    public var prVerdict: ResolvedPRStatus?

    /// ⛔ **The last two parameters have no default values, on purpose.**
    ///
    /// Every other parameter here defaults, so two defaulted ones would compile
    /// at every existing construction and nothing would catch the next one. The
    /// three production sites — `AppModel.preview`, `BoardService.proposeMove`
    /// and `nextCandidates` below — and roughly twenty test constructions each
    /// had to state an answer before this built, and so will the fourth. The
    /// template is `providedFollowUps`, whose two sites diverge deliberately.
    public init(
        repoIsEnabled: Bool = true,
        activeRunID: UUID? = nil,
        allowSideEffects: Bool = true,
        providedFollowUps: [String]? = nil,
        requiresVerifiedGreen: Bool,
        prVerdict: ResolvedPRStatus?
    ) {
        self.repoIsEnabled = repoIsEnabled
        self.activeRunID = activeRunID
        self.allowSideEffects = allowSideEffects
        self.providedFollowUps = providedFollowUps
        self.requiresVerifiedGreen = requiresVerifiedGreen
        self.prVerdict = prVerdict
    }
```

3b. In the same file, in `nextCandidates` (the `MoveContext(` at line 220), add the two arguments after `providedFollowUps: []`:

```swift
                providedFollowUps: [],
                // `board_next` answers what an *agent* can do, and an agent is
                // a human's proxy with a human behind it. The restraint belongs
                // to the caller that has nobody: `AutoDevService` builds its own
                // context rather than borrowing this one.
                //
                // And the helper could not honour it if it were true:
                // `OfflineResponder` reads a snapshot and can reach neither
                // `gh` nor the network, so its answer would *mean* "I could not
                // ask" while *encoding* as "the CI is not green" — and
                // `OfflineParityTests` compares encoded bytes, so it would hold
                // on exactly that disagreement.
                requiresVerifiedGreen: false,
                prVerdict: nil
```

3c. In `ElliotKit/Sources/ElliotEngine/BoardService.swift`, replace lines 98-103 with:

```swift
        let context = MoveContext(
            repoIsEnabled: repo.isEnabled,
            activeRunID: activeRun?.id,
            allowSideEffects: origin.allowsSideEffects,
            providedFollowUps: followUps,
            // Task 8 fills these from `PRVerdictReader`. Until then the board
            // answers what it has always answered: a drag and an MCP move are
            // watched by a human and are not held to a verdict.
            requiresVerifiedGreen: false,
            prVerdict: nil
        )
```

3d. In `ElliotKit/Sources/ElliotAppKit/AppModel.swift`, replace lines **1038-1045** — `context: MoveContext(` through its closing `)`, inside `preview`. ⚠ Not 1037, which is `card: card,` and must stay; and the range must include 1045, because the block below carries that `)` itself.

```swift
            context: MoveContext(
                repoIsEnabled: repo(for: card)?.isEnabled ?? false,
                activeRunID: activeRuns[card.id]?.id,
                allowSideEffects: true,
                // Left uncollected on purpose: the merge really does stop to
                // ask, and the caption says so.
                providedFollowUps: nil,
                // A caption is drawn for somebody who is looking at it, so it
                // previews the move *they* would make. A preview held to an
                // unattended rule would read "not a verified green" at a person
                // who is perfectly entitled to merge, and this runs inside
                // `body` — it cannot read a verdict without doing I/O in layout.
                requiresVerifiedGreen: false,
                prVerdict: nil
            )
```

3e. In `ElliotKit/Tests/ElliotModelTests/RuleEngineTests.swift`, add this helper immediately after `triggerTransitions` (which ends at line 34):

```swift
/// The context every test in this file that is *not* about the green guard
/// wants: a move somebody is watching, with no reading of a pull request.
///
/// `MoveContext` deliberately defaults nothing for the last two parameters —
/// that is the guard on production call sites, and it is doing its job here by
/// having forced this file to state an answer once. Written once rather than
/// twenty times so the suite stays about the rules.
private func watched(
    repoIsEnabled: Bool = true,
    activeRunID: UUID? = nil,
    allowSideEffects: Bool = true,
    providedFollowUps: [String]? = nil
) -> MoveContext {
    MoveContext(
        repoIsEnabled: repoIsEnabled,
        activeRunID: activeRunID,
        allowSideEffects: allowSideEffects,
        providedFollowUps: providedFollowUps,
        requiresVerifiedGreen: false,
        prVerdict: nil
    )
}
```

Then replace every `MoveContext(` in that file with `watched(` — there are exactly **19**, one each at lines 44, 59, 71, 78, 85, 93, 103, 112, 119, 127, 133, 142, 153, 162, 170, 185, 200, 213 and 239 (line numbers are the file *before* the helper above is inserted). Every argument label is unchanged: `repoIsEnabled:`, `activeRunID:`, `allowSideEffects:` and `providedFollowUps:` all exist on `watched` with the same defaults. Verify with:

```bash
cd ElliotKit && grep -c 'MoveContext(' Tests/ElliotModelTests/RuleEngineTests.swift
```

Expected: `1` — the single occurrence inside `watched` itself.

3f. In `ElliotKit/Tests/ElliotModelTests/NextStepTests.swift`, replace lines 35-39:

```swift
    NextCandidate(
        card: card,
        repoName: repoName,
        context: MoveContext(providedFollowUps: followUps)
    )
```

with:

```swift
    NextCandidate(
        card: card,
        repoName: repoName,
        context: MoveContext(
            providedFollowUps: followUps,
            // What `nextCandidates` itself answers — see
            // `nextCandidatesAnswerForAHumansProxy` below for why.
            requiresVerifiedGreen: false,
            prVerdict: nil
        )
    )
```

3g. In `ElliotKit/Tests/ElliotAppKitTests/AppModelTests.swift`, replace lines 204-207:

```swift
                context: MoveContext(
                    repoIsEnabled: true, activeRunID: nil,
                    allowSideEffects: true, providedFollowUps: nil
                )
```

with:

```swift
                context: MoveContext(
                    repoIsEnabled: true, activeRunID: nil,
                    allowSideEffects: true, providedFollowUps: nil,
                    // The same answer `AppModel.preview` gives, and this test
                    // exists to prove the two agree rather than to restate one.
                    requiresVerifiedGreen: false, prVerdict: nil
                )
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd ElliotKit && swift test --filter NextStepTests`
Expected: PASS — 9 tests (the 8 that were there, plus the one added above).
Run: `cd ElliotKit && swift test --filter RuleEngineTests`
Expected: PASS, with **no behavioural change**: `evaluateMove` does not yet read either new field, so every existing assertion must hold on the value it already held.
Run: `cd ElliotKit && swift test --filter AppModelTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git rev-parse --abbrev-ref HEAD
git add ElliotKit/Sources/ElliotModel/RuleEngine.swift \
        ElliotKit/Sources/ElliotEngine/BoardService.swift \
        ElliotKit/Sources/ElliotAppKit/AppModel.swift \
        ElliotKit/Tests/ElliotModelTests/RuleEngineTests.swift \
        ElliotKit/Tests/ElliotModelTests/NextStepTests.swift \
        ElliotKit/Tests/ElliotAppKitTests/AppModelTests.swift
git commit -m "feat(model): every move states whether it needs a verified green, and what it read"
```

---

## Task 6: two new refusals, and three test lists the compiler now holds

**Files:**
- Modify: `ElliotKit/Sources/ElliotModel/RuleEngine.swift:14-37`
- Modify: `ElliotKit/Sources/ElliotAppKit/Consequence.swift:88-101` (`Consequence.reason`)
- Modify: `ElliotKit/Sources/ElliotIPC/NextRendering.swift:12-42`
- Create: `ElliotKit/Tests/ElliotAppKitTests/MoveBlockCases.swift`
- Create: `ElliotKit/Tests/ElliotAppKitTests/RefusalWordingTests.swift`
- Test: `ElliotKit/Tests/ElliotAppKitTests/AppModelTests.swift:282-285`
- Test: `ElliotKit/Tests/ElliotAppKitTests/RunsPaneEmptyStateTests.swift:127-130`
- Test: `ElliotKit/Tests/ElliotIPCTests/NextRenderingTests.swift:114-117`

**Interfaces:**
- Consumes: `PRSign` (already in `ElliotModel`, `Sendable, Hashable`, with `var summary: String` at `PRStatus.swift:182-202`).
- Produces:
  - `MoveBlock.notVerifiedGreen(sign: PRSign?)` with `code == "not_verified_green"`.
    ⚠️ **The payload is `reason: NotGreenReason`, not `sign: PRSign?`** — arbitrated on
    2026-08-09 and explained at the head of Task 7, which is where the correction was written.
    Every `.notVerifiedGreen(sign:)` in *this* task's code blocks below carries the retired
    shape too; read them through that note.
  - `MoveBlock.systemOwnedTransition` with `code == "system_owned_transition"`.
  - `Consequence.reason(_:)` and `MoveBlockText.explain(_:)` / `.hint(_:)` answer both.
  - `MoveBlockCase` in `ElliotAppKitTests`: `enum MoveBlockCase: CaseIterable { var sample: MoveBlock; static func of(_ block: MoveBlock) -> MoveBlockCase; static var allBlocks: [MoveBlock] }`.

> ⚠️ **Cross-plan: PR 0·2 adds a tenth `MoveBlock`, and these two shadows are exhaustive.**
> The design names PR 0·2 (`MoveContext.repoPreflight`, `MoveBlock.repoBlocked`, `code ==
> "repo_blocked"`) a **hard prerequisite** of the whole auto-dev set, and PR4's own prerequisite
> table consumes it. `MoveBlockCase.of(_:)` and `WireBlockCase.of(_:)` switch over `MoveBlock`
> with **no `default:`** — which is the point of them — so once PR 0·2 has landed, a shadow that
> lists nine cases does not compile.
>
> Both code blocks below therefore carry a `case repoBlocked` arm. Measure before you paste:
>
> ```bash
> grep -n 'case repoBlocked' ElliotKit/Sources/ElliotModel/RuleEngine.swift
> ```
>
> - prints a line → PR 0·2 has landed; keep the three `repoBlocked` lines in each shadow.
> - prints nothing → PR 0·2 has **not** landed; delete the three `repoBlocked` lines from each
>   shadow, and expect `RefusalWordingTests.everyBlockIsWordedTwice` to cover nine blocks rather
>   than ten. PR 0·2 then has to add the case back to both shadows in its own diff, exactly as it
>   adds the arm to `Consequence.reason` and `MoveBlockText.explain`.

> 🔴 **Corrected 2026-08-09, after the branch was merged with `origin/main`. The block above is
> right; the branch took its wrong fork.**
>
> The grep was run — and run against **this worktree**, whose merge base is twenty-three commits
> behind. It printed nothing, so the "has **not** landed" fork was taken and the three
> `repoBlocked` lines were deleted from both shadows. PR 0·2 had in fact landed as `a29d019`
> (#250) fifty-six minutes after that merge base and eighteen hours before this branch's first
> commit.
>
> ⚠️ **The prescribed command cannot answer the question it is asked.** `RuleEngine.swift` in a
> worktree is a *rendering* of the branch, not of the portfolio; the source is `origin`. Written
> so it can only be right:
>
> ```bash
> git fetch origin && git show origin/main:ElliotKit/Sources/ElliotModel/RuleEngine.swift \
>     | grep -n 'case repoBlocked'
> ```
>
> What actually held the line was the shadows themselves: `MoveBlockCase.of` and
> `WireBlockCase.of` are exhaustive with no `default:`, so the merge named all three deleted arms
> as build failures and nothing reached a green suite unnamed. **The measured arity is `MoveBlock`
> 8 → 10** — the 7 originals plus `.repoBlocked`, then `.notVerifiedGreen` and
> `.systemOwnedTransition` — not 7 → 9, and `everyBlockIsWordedTwice` covers ten.

- [ ] **Step 1: Write the failing test**

1a. Create `ElliotKit/Tests/ElliotAppKitTests/MoveBlockCases.swift`:

```swift
import ElliotModel
import Foundation

/// Every `MoveBlock`, held to the enum by the compiler.
///
/// `MoveBlock` carries associated values, so it is not `CaseIterable` and the
/// literal lists this replaces could fall behind the enum in total silence —
/// which is what they did: adding a case broke four `switch`es in `Sources` and
/// nothing at all in three test files that claimed to cover "every block".
///
/// The loop is closed in both directions. `of(_:)` switches over `MoveBlock`
/// with **no `default:`**, so a case added to the model stops this target
/// compiling; its arms can only return a `MoveBlockCase`, so the shadow has to
/// grow too; and `allCases` then makes `allBlocks` grow by itself. A new case
/// therefore cannot reach a green suite unnamed.
enum MoveBlockCase: CaseIterable {
    case sameColumn
    case emptyIdea
    case incompleteStory
    case missingIssueNumber
    case missingPRNumber
    case repoDisabled
    /// From PR 0·2. Delete this line and its two arms below if
    /// `grep -n 'case repoBlocked' ElliotKit/Sources/ElliotModel/RuleEngine.swift`
    /// prints nothing — see the cross-plan note above.
    case repoBlocked
    case runAlreadyInFlight
    case notVerifiedGreen
    case systemOwnedTransition

    /// One value standing for this case. The associated values are arbitrary —
    /// what is under test is the wording of a case, never of a payload.
    var sample: MoveBlock {
        switch self {
        case .sameColumn: .sameColumn
        case .emptyIdea: .emptyIdea
        case .incompleteStory: .incompleteStory
        case .missingIssueNumber: .missingIssueNumber
        case .missingPRNumber: .missingPRNumber
        case .repoDisabled: .repoDisabled
        case .repoBlocked: .repoBlocked
        case .runAlreadyInFlight: .runAlreadyInFlight(runID: UUID())
        case .notVerifiedGreen: .notVerifiedGreen(sign: .checksFailing(count: 1))
        case .systemOwnedTransition: .systemOwnedTransition
        }
    }

    /// Exhaustive over `MoveBlock`, with no `default:`. This arm is the guard;
    /// everything else in this file is bookkeeping around it.
    static func of(_ block: MoveBlock) -> MoveBlockCase {
        switch block {
        case .sameColumn: .sameColumn
        case .emptyIdea: .emptyIdea
        case .incompleteStory: .incompleteStory
        case .missingIssueNumber: .missingIssueNumber
        case .missingPRNumber: .missingPRNumber
        case .repoDisabled: .repoDisabled
        case .repoBlocked: .repoBlocked
        case .runAlreadyInFlight: .runAlreadyInFlight
        case .notVerifiedGreen: .notVerifiedGreen
        case .systemOwnedTransition: .systemOwnedTransition
        }
    }

    static var allBlocks: [MoveBlock] { allCases.map(\.sample) }
}
```

1b. Create `ElliotKit/Tests/ElliotAppKitTests/RefusalWordingTests.swift`:

```swift
import ElliotIPC
import ElliotModel
import Foundation
import Testing

@testable import ElliotAppKit

/// The two hand-written phrasings of every refusal, linked.
///
/// `Consequence.reason` addresses whoever is looking at the board;
/// `MoveBlockText.explain` addresses an agent reading `board_move_card`'s
/// answer. They live in two targets, they are written by hand, and nothing held
/// them together — so "one of them says something and the other does not" was
/// invisible, and so was "someone unified them".
///
/// The direction asserted is **non-identity**, the template being
/// `MoveHistoryTests.historyLabelNeverConvergesWithArrivalNote`: two registers,
/// two audiences, and the day someone collapses them this fails. Containment is
/// checked both ways, because that is how one would end up reading as the other.
///
/// `ElliotAppKitTests` is where this can live at all: `ElliotAppKit` depends on
/// `ElliotIPC`, so this is the only test target that sees both wordings.
@Suite("Refusal wording")
struct RefusalWordingTests {

    @Test("Every block is worded in both places, and neither wording is empty")
    func everyBlockIsWordedTwice() {
        for block in MoveBlockCase.allBlocks {
            #expect(!Consequence.reason(block).isEmpty, "\(block.code) has no board wording")
            #expect(!MoveBlockText.explain(block).isEmpty, "\(block.code) has no wire wording")
        }
    }

    @Test("The board's wording and the wire's wording never converge")
    func theTwoWordingsStayApart() {
        for block in MoveBlockCase.allBlocks {
            let board = Consequence.reason(block)
            let wire = MoveBlockText.explain(block)
            #expect(board != wire, "\(block.code)")
            #expect(!board.contains(wire), "\(block.code): the wire's sentence is inside the board's")
            #expect(!wire.contains(board), "\(block.code): the board's sentence is inside the wire's")
        }
    }

    @Test("A green refusal states the reading it was refused on, in PRSign's own words")
    func notVerifiedGreenQuotesTheSign() {
        // The sentence is written once, from `PRSign.summary`, which already
        // says the right thing for all eight signs. A second table of eight
        // sentences here is what this asserts against.
        let failing = PRSign.checksFailing(count: 3)
        #expect(Consequence.reason(.notVerifiedGreen(sign: failing)).contains(failing.summary))
        #expect(MoveBlockText.explain(.notVerifiedGreen(sign: failing)).contains(failing.summary))

        // And `nil` is its own answer — nothing was read, which is not a sign.
        let unread = Consequence.reason(.notVerifiedGreen(sign: nil))
        #expect(!unread.isEmpty)
        for sign in [PRSign.conflict, .noBuild, .unknown] {
            #expect(!unread.contains(sign.summary), "an unread pull request borrowed \(sign.code)")
        }
    }

    @Test("Every case has a distinct wire code")
    func codesAreDistinct() {
        // Proves the shadow above is not standing two cases on one value: a
        // duplicate here means `allBlocks` is short of the enum.
        let codes = MoveBlockCase.allBlocks.map(\.code)
        #expect(Set(codes).count == codes.count)
        #expect(MoveBlockCase.allCases.allSatisfy { MoveBlockCase.of($0.sample) == $0 })
        #expect(codes.contains("not_verified_green"))
        #expect(codes.contains("system_owned_transition"))
    }
}
```

1c. In `ElliotKit/Tests/ElliotAppKitTests/AppModelTests.swift`, replace lines 279-288:

```swift
        // Listed rather than iterated: `MoveBlock` carries an associated value
        // so it is not `CaseIterable`, and a `default` here would let a new case
        // arrive unworded — which is the failure this test exists to catch.
        let blocks: [MoveBlock] = [
            .sameColumn, .emptyIdea, .incompleteStory, .missingIssueNumber,
            .missingPRNumber, .repoDisabled, .runAlreadyInFlight(runID: UUID()),
        ]
        // Every `code` distinct proves the list above is complete: a case added
        // to the enum and forgotten here leaves `codes` short of `blocks`.
        #expect(Set(blocks.map(\.code)).count == blocks.count)
```

with:

```swift
        // `MoveBlockCase` rather than a literal list. The literal was the
        // failure this test was written to catch, one level up: it claimed to
        // cover every block and could fall behind the enum without reddening,
        // which it duly did. The shadow's `of(_:)` is exhaustive over
        // `MoveBlock`, so a case added to the model cannot reach here unnamed.
        let blocks = MoveBlockCase.allBlocks
        #expect(Set(blocks.map(\.code)).count == blocks.count)
```

1d. In `ElliotKit/Tests/ElliotAppKitTests/RunsPaneEmptyStateTests.swift`, replace lines 127-130:

```swift
        let blocks: [MoveBlock] = [
            .emptyIdea, .incompleteStory, .missingIssueNumber,
            .missingPRNumber, .repoDisabled, .runAlreadyInFlight(runID: UUID()),
        ]
```

with:

```swift
        // Every case except `.sameColumn`, from the compiler-checked shadow.
        // `.sameColumn` is excluded because this pane only ever previews
        // `naturalNext`, so a card cannot be refused here for being where it
        // already is — an exclusion by name, not a list that can fall behind.
        let blocks = MoveBlockCase.allCases
            .filter { $0 != .sameColumn }
            .map(\.sample)
```

1e. In `ElliotKit/Tests/ElliotIPCTests/NextRenderingTests.swift`, replace lines 114-117:

```swift
        let blocks: [MoveBlock] = [
            .sameColumn, .emptyIdea, .incompleteStory, .missingIssueNumber,
            .missingPRNumber, .repoDisabled, .runAlreadyInFlight(runID: UUID()),
        ]
```

with:

```swift
        let blocks = WireBlockCase.allBlocks
```

and add at the end of the same file, after the closing brace of the suite:

```swift
/// Every `MoveBlock`, held to the enum by the compiler.
///
/// A second copy of `ElliotAppKitTests/MoveBlockCases.swift`, and deliberately
/// so: `TestSupport` is the only target the suites share, and `Package.swift`
/// records that it "depends on nothing" on purpose — giving it `ElliotModel`
/// to host this would trade a twenty-line duplicate for an edge on the one
/// target that has none. `ElliotIPCTests` does not depend on it either.
///
/// `of(_:)` is exhaustive over `MoveBlock` with no `default:`, so a case added
/// to the model stops this target compiling; `allCases` then grows `allBlocks`.
private enum WireBlockCase: CaseIterable {
    case sameColumn
    case emptyIdea
    case incompleteStory
    case missingIssueNumber
    case missingPRNumber
    case repoDisabled
    /// From PR 0·2 — same measurement, same deletion, as `MoveBlockCase` above.
    case repoBlocked
    case runAlreadyInFlight
    case notVerifiedGreen
    case systemOwnedTransition

    var sample: MoveBlock {
        switch self {
        case .sameColumn: .sameColumn
        case .emptyIdea: .emptyIdea
        case .incompleteStory: .incompleteStory
        case .missingIssueNumber: .missingIssueNumber
        case .missingPRNumber: .missingPRNumber
        case .repoDisabled: .repoDisabled
        case .repoBlocked: .repoBlocked
        case .runAlreadyInFlight: .runAlreadyInFlight(runID: UUID())
        case .notVerifiedGreen: .notVerifiedGreen(sign: .checksFailing(count: 1))
        case .systemOwnedTransition: .systemOwnedTransition
        }
    }

    static func of(_ block: MoveBlock) -> WireBlockCase {
        switch block {
        case .sameColumn: .sameColumn
        case .emptyIdea: .emptyIdea
        case .incompleteStory: .incompleteStory
        case .missingIssueNumber: .missingIssueNumber
        case .missingPRNumber: .missingPRNumber
        case .repoDisabled: .repoDisabled
        case .repoBlocked: .repoBlocked
        case .runAlreadyInFlight: .runAlreadyInFlight
        case .notVerifiedGreen: .notVerifiedGreen
        case .systemOwnedTransition: .systemOwnedTransition
        }
    }

    static var allBlocks: [MoveBlock] { allCases.map(\.sample) }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd ElliotKit && swift test --filter RefusalWordingTests`
Expected: FAIL — the target does not compile:
`error: type 'MoveBlock' has no member 'notVerifiedGreen'`.

- [ ] **Step 3: Write minimal implementation**

3a. In `ElliotKit/Sources/ElliotModel/RuleEngine.swift`, add the two cases after `case runAlreadyInFlight(runID: UUID)` (line 23):

```swift
    /// Nothing established that this pull request is green, and this caller may
    /// not merge on less.
    ///
    /// It carries the cause so the refusal can say what was actually read.
    /// `nil` is *nothing was read*, which is a different answer from any sign.
    case notVerifiedGreen(sign: PRSign?)
    /// This transition has one owner, and the caller is not it.
    ///
    /// Its own case rather than a second use of `notVerifiedGreen`, so the
    /// refusal is truthful: reusing that one for In Progress → In Review would
    /// tell the reader the CI is the problem when the real answer is that
    /// nobody but Elliot makes this move.
    case systemOwnedTransition
```

and the two codes to the `code` switch (after the `runAlreadyInFlight` arm at line 34):

```swift
        case .notVerifiedGreen: "not_verified_green"
        case .systemOwnedTransition: "system_owned_transition"
```

(snake_case, per the convention recorded at `ElliotKit/Sources/ElliotIPC/Protocol.swift:397-401`: keys are camelCase, string *values* that name a thing are snake_case — and `MoveBlock.code` is one of the three it names.)

3b. In `ElliotKit/Sources/ElliotAppKit/Consequence.swift`, add to the `reason` switch (after the `runAlreadyInFlight` arm at line 99):

```swift
        case .notVerifiedGreen(let sign):
            "Not a verified green — "
                + (sign?.summary ?? "nothing has been read about this pull request.")
        case .systemOwnedTransition:
            "Elliot fills this column itself; it is not a move to make from here."
```

3c. In `ElliotKit/Sources/ElliotIPC/NextRendering.swift`, add to `explain` (after the `runAlreadyInFlight` arm at line 21):

```swift
        case .notVerifiedGreen(let sign):
            "This move requires a verified green build. "
                + (sign?.summary ?? "No reading of the pull request.")
        case .systemOwnedTransition:
            "That transition has one owner: Elliot makes it when the pull request goes ready."
```

and to `hint` (before the `case .sameColumn, .emptyIdea: nil` arm at line 38):

```swift
        case .notVerifiedGreen:
            "Wait for the checks, or make the move yourself — a move a person makes is not "
                + "held to a verified green."
        case .systemOwnedTransition:
            "Nothing to do here. Elliot makes this move itself once the pull request is ready."
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd ElliotKit && swift test --filter RefusalWordingTests`
Expected: PASS — 4 tests.
Run: `cd ElliotKit && swift test --filter NextRenderingTests`
Expected: PASS.
Run: `cd ElliotKit && swift test --filter RunsPaneEmptyStateTests`
Expected: PASS.
Run: `cd ElliotKit && swift test --filter AppModelTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git rev-parse --abbrev-ref HEAD
git add ElliotKit/Sources/ElliotModel/RuleEngine.swift \
        ElliotKit/Sources/ElliotAppKit/Consequence.swift \
        ElliotKit/Sources/ElliotIPC/NextRendering.swift \
        ElliotKit/Tests/ElliotAppKitTests/MoveBlockCases.swift \
        ElliotKit/Tests/ElliotAppKitTests/RefusalWordingTests.swift \
        ElliotKit/Tests/ElliotAppKitTests/AppModelTests.swift \
        ElliotKit/Tests/ElliotAppKitTests/RunsPaneEmptyStateTests.swift \
        ElliotKit/Tests/ElliotIPCTests/NextRenderingTests.swift
git commit -m "feat(model,ipc,app): two refusals that name their cause, and lists the compiler holds"
```

---

## Task 7: the two `evaluateMove` branches

> 🔴 **Corrected 2026-08-09, after task 6 had already landed and passed review.** This task's
> code blocks below were written against `MoveBlock.notVerifiedGreen(sign: PRSign?)`. That shape
> was wrong and has been replaced by `notVerifiedGreen(reason: NotGreenReason)`.
>
> **Why**, because it decides what this task must build: `nil` meant *nothing was read* in
> `MoveBlock`, and *everything known is fine* in `PRSign` (`PRStatus.swift:160-162`) — the same
> optional, opposite meanings. And `isMergeableUnattended` refuses **while `sign == nil`** in
> exactly the two holes it exists to close (`merge == .unstable`, and an analyser-only green),
> where the pull request *was* read. Writing `sign: context.prVerdict?.sign` would have made the
> feature's two flagship refusals say "nothing has been read about this pull request".
>
> `NotGreenReason` as it landed in `RuleEngine.swift`:
>
> ```swift
> public enum NotGreenReason: Equatable, Sendable, Hashable {
>     case noReading
>     case sign(PRSign)
>     case notClean(MergeState)
>     case noBuildVerdict
> }
> ```
>
> **This task therefore owns one thing the plan never specified: the derivation.** Add
> `NotGreenReason.of(_ verdict: ResolvedPRStatus?) -> NotGreenReason` beside the enum, pure and
> total, and pin it with its own test. It must answer in the order the predicate refuses in, so
> that the reason a reader is given is the *first* thing actually wrong:
>
> | input | answer |
> |---|---|
> | `nil` | `.noReading` |
> | `isStale` | ~~`.noReading`~~ → **`.sign(.unknown)`**, corrected 2026-08-09 in the final review. The row exists and describes a commit no longer under review — that is somebody pushing, not nobody looking, and it is the likeliest refusal in production. `.noReading` told that reader nothing had been read about a pull request that *was* read: the same defect that turned this payload from a `PRSign?` into a reason. `resolved(now:)` already stamps a stale row `sign: .unknown`, so the accurate sentence was already written once. |
> | `sign != nil` | `.sign(sign)` |
> | `merge != .clean` | `.notClean(merge)` |
> | otherwise | `.noBuildVerdict` — the only conjunct left |
>
> ⚠️ The last row is a claim, not a default: it is reachable **only** when the reading came back,
> `!isStale`,
> `sign == nil` and `merge == .clean`, so `ci.hasBuildVerdict` is the only thing that can have
> failed. Assert that in the test rather than trusting the reading — if a fifth conjunct is ever
> added to `isMergeableUnattended`, this arm starts lying and nothing else will notice.
>
> Every `.notVerifiedGreen(sign:)` in the blocks below becomes
> `.notVerifiedGreen(reason:)` with the matching reason, including in the expected-failure text.


**Files:**
- Modify: `ElliotKit/Sources/ElliotModel/RuleEngine.swift:106-131` (the transition `switch`)
- Test: `ElliotKit/Tests/ElliotModelTests/RuleEngineTests.swift`

**Interfaces:**
- Consumes: `MoveContext.requiresVerifiedGreen` / `.prVerdict` (Task 5), `MoveBlock.notVerifiedGreen(sign:)` / `.systemOwnedTransition` (Task 6), `ResolvedPRStatus.isMergeableUnattended` (Task 2), the `watched(...)` helper (Task 5).
- Produces: `evaluateMove(from:to:card:context:)` — unchanged signature; two branches now consult the two new context fields. Nothing later in this plan depends on new symbols from here.

- [ ] **Step 1: Write the failing test**

Two edits to `ElliotKit/Tests/ElliotModelTests/RuleEngineTests.swift`. First, the **four** file-scope declarations below — `verdict(...)`, `unattended(_:)`, `struct MergeReading` and `let mergeReadings` — immediately after the `watched(...)` helper Task 5 added. Then the tests in the second block, at the **end of the suite**, before its closing brace. ⚠ That brace was line 241 before Task 5; Task 5 inserted the helper above it, so find it rather than trusting the number.

```swift
/// A resolved reading, built directly. `sign` is stated rather than derived:
/// deriving it is `PRStatus.sign`'s job and is tested in `PRStatusTests`.
private func verdict(
    ci: CIState = .passing(["build-and-test"]),
    merge: MergeState = .clean,
    review: ReviewState = .approved,
    isStale: Bool = false,
    sign: PRSign? = nil
) -> ResolvedPRStatus {
    ResolvedPRStatus(
        ci: ci, merge: merge, review: review,
        checkedAt: fixedDate, headRefOid: "a1b2c3d4e5f6", isStale: isStale, sign: sign)
}

/// The context an unattended caller builds: nobody to ask, so follow-ups are an
/// explicit "none", and the verdict is whatever `gh` established.
private func unattended(_ prVerdict: ResolvedPRStatus?) -> MoveContext {
    MoveContext(
        repoIsEnabled: true,
        activeRunID: nil,
        allowSideEffects: true,
        providedFollowUps: [],
        requiresVerifiedGreen: true,
        prVerdict: prVerdict
    )
}

/// One row of the merge matrix.
///
/// A named struct rather than a tuple: swift-testing wants `arguments:` to be a
/// `Sendable` collection of `Sendable` elements, and a struct also puts a
/// readable name in the failure message, which a positional tuple does not.
private struct MergeReading: Sendable, CustomStringConvertible {
    var name: String
    var verdict: ResolvedPRStatus?
    var merges: Bool

    var description: String { name }
}

/// Every reading a merge can be asked to act on, and what it must answer.
///
/// Eight signs, plus a green with no sign, plus a stale reading, plus no
/// reading at all — not three cases. `PRSign` is not `CaseIterable`, so this is
/// written out; `MergeableUnattendedTests` is where the predicate itself is
/// cornered, and this is where the *rule* is.
private let mergeReadings: [MergeReading] = [
    MergeReading(name: "green", verdict: verdict(), merges: true),
    MergeReading(name: "conflict", verdict: verdict(sign: .conflict), merges: false),
    MergeReading(name: "checksFailing", verdict: verdict(sign: .checksFailing(count: 2)), merges: false),
    MergeReading(name: "changesRequested", verdict: verdict(sign: .changesRequested), merges: false),
    MergeReading(name: "reviewRequired", verdict: verdict(sign: .reviewRequired), merges: false),
    MergeReading(name: "mergeBlocked", verdict: verdict(sign: .mergeBlocked), merges: false),
    MergeReading(name: "checksRunning", verdict: verdict(sign: .checksRunning), merges: false),
    MergeReading(name: "noBuild", verdict: verdict(sign: .noBuild), merges: false),
    MergeReading(name: "unknown", verdict: verdict(sign: .unknown), merges: false),
    MergeReading(name: "stale", verdict: verdict(isStale: true), merges: false),
    MergeReading(name: "nothing read", verdict: nil, merges: false),
]
```

```swift
    // MARK: - The unattended guard

    @Test("A merge that requires a verified green answers the whole PRSign matrix",
          arguments: mergeReadings)
    func mergeUnderTheGreenGuard(reading: MergeReading) {
        let card = makeCard(column: .inReview, prNumber: 279)
        let outcome = evaluateMove(
            from: .inReview, to: .done, card: card, context: unattended(reading.verdict))

        if reading.merges {
            #expect(
                outcome == .action(.mergePR(prNumber: 279, followUps: [])),
                "\(reading.name) should have merged, got \(outcome)")
        } else {
            #expect(
                outcome == .blocked(.notVerifiedGreen(sign: reading.verdict?.sign)),
                "\(reading.name) should have been refused, got \(outcome)")
        }
    }

    @Test("A watched merge is not held to a verified green, on the same readings",
          arguments: mergeReadings)
    func watchedMergeIgnoresTheVerdict(reading: MergeReading) {
        // The other half, and the reason the field is named for the rule rather
        // than for the caller: a person dragging a card onto Done has read the
        // pull request themselves and is entitled to merge a red one.
        let card = makeCard(column: .inReview, prNumber: 279)
        var context = watched(providedFollowUps: [])
        context.prVerdict = reading.verdict
        let outcome = evaluateMove(from: .inReview, to: .done, card: card, context: context)

        #expect(outcome == .action(.mergePR(prNumber: 279, followUps: [])), "\(reading.name)")
    }

    @Test("A missing pull request number outranks the green guard")
    func missingPRNumberIsStillTheFirstAnswer() {
        // Order matters: refusing "not a verified green" on a card that has no
        // pull request at all would send the reader to look at CI for something
        // that does not exist.
        let card = makeCard(column: .inReview, prNumber: nil)
        let outcome = evaluateMove(from: .inReview, to: .done, card: card, context: unattended(nil))
        #expect(outcome == .blocked(.missingPRNumber))
    }

    @Test("In Progress to In Review is refused outright for a caller that has no human")
    func inProgressToInReviewIsSystemOwned() {
        // Elliot fills this column itself, when `PRWatcher` sees the pull
        // request go ready. A caller requiring a verified green asking for it is
        // asking to skip the pull request entirely — and `arrivalNote` could not
        // explain such an arrival, since the note it would need is about a
        // reason nobody supplied.
        let card = makeCard(column: .inProgress, issueNumber: 47, prNumber: 279)
        let outcome = evaluateMove(
            from: .inProgress, to: .inReview, card: card, context: unattended(verdict()))
        #expect(outcome == .blocked(.systemOwnedTransition))

        // Unchanged for everyone else: it still moves the card and runs nothing.
        let watchedOutcome = evaluateMove(
            from: .inProgress, to: .inReview, card: card, context: watched())
        #expect(watchedOutcome == .noAction)
    }

    /// The twin of `systemMovesNeverTrigger`, and built the same way: the same
    /// 25 transitions, the same fully-populated card, one field of the context
    /// changed.
    ///
    /// `.needsInput` is information "only a human (or an explicit tool argument)
    /// can supply". A caller with no human can read it only as "blocked, I will
    /// try again", which is a loop that spins — so the answer to a caller that
    /// requires a verified green is never a question.
    ///
    /// It survives a `.needsInput` added to some *other* transition later, which
    /// one assertion inside the merge branch could not.
    @Test(
        "A move that requires a verified green is never asked for input",
        arguments: Column.allCases, Column.allCases
    )
    func unattendedMovesAreNeverAskedForInput(from: Column, to: Column) {
        let card = makeCard(column: from, issueNumber: 47, prNumber: 279)
        let outcome = evaluateMove(from: from, to: to, card: card, context: unattended(verdict()))

        if case .needsInput(let need) = outcome {
            Issue.record("\(from) → \(to) asked an unattended caller for \(need)")
        }
    }

    /// The one input under which the invariant above is *not* structural, named
    /// rather than left for someone to trip over.
    @Test("An unattended caller that collected no follow-up list is still asked for one")
    func theOneRemainingQuestion() {
        // `providedFollowUps: nil` means "not collected yet", and the green
        // guard sits before it: every refusal an unattended caller can meet is a
        // `.blocked`, but a *green* pull request with no list still produces the
        // question. `AutoDevService` therefore always passes `followUps: []` —
        // merge, filing nothing of its own — and this is the measurement that
        // says why that is a requirement on the caller and not a nicety.
        let card = makeCard(column: .inReview, prNumber: 279)
        var context = unattended(verdict())
        context.providedFollowUps = nil
        #expect(
            evaluateMove(from: .inReview, to: .done, card: card, context: context)
                == .needsInput(.followUps(prNumber: 279)))
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd ElliotKit && swift test --filter RuleEngineTests`
Expected: FAIL at runtime — the file compiles (every symbol exists after Tasks 2, 5 and 6) and the new expectations fail. The first is
`Expectation failed: outcome == .blocked(.notVerifiedGreen(sign: reading.verdict?.sign))` — "conflict should have been refused, got action(ElliotModel.TriggerAction.mergePR(prNumber: 279, followUps: []))" — and `inProgressToInReviewIsSystemOwned` fails with
`Expectation failed: outcome == .blocked(.systemOwnedTransition)` — got `noAction`.

- [ ] **Step 3: Write minimal implementation**

In `ElliotKit/Sources/ElliotModel/RuleEngine.swift`, replace the whole `switch (from, to)` block — **lines 106-131**, `switch (from, to) {` through its closing `}` — with the block below. Only two things in it are new: an explicit `(.inProgress, .inReview)` arm, which `default` used to answer, and the green guard inside `(.inReview, .done)` (was lines 121-126). The other two arms are reproduced verbatim so the whole switch can be pasted at once and read in order.

```swift
    switch (from, to) {
    case (.backlog, .todo):
        // Already filed — moving it again must not open a second issue.
        if card.issueNumber != nil { return .noAction }
        // A half-written story would file a vague issue, and `create-issue`
        // stops on "an idea too vague to even name". Catch it here instead.
        guard !card.hasIncompleteStory else { return .blocked(.incompleteStory) }
        let idea = card.ideaText
        guard !idea.isEmpty else { return .blocked(.emptyIdea) }
        return .action(.createIssue(idea: idea))

    case (.todo, .inProgress):
        guard let issue = card.issueNumber else { return .blocked(.missingIssueNumber) }
        return .action(.implementIssue(issueNumber: issue))

    case (.inProgress, .inReview):
        // Filled by `PRWatcher` alone. A caller that requires a verified green
        // asking for it is asking to skip the pull request entirely, and
        // `arrivalNote` could not explain such an arrival — it speaks for moves
        // whose reason was recorded, and this one would have none.
        //
        // Stated as its own arm rather than left to `default`, which answered
        // `.noAction` for it and would go on answering `.noAction` to a loop.
        if context.requiresVerifiedGreen { return .blocked(.systemOwnedTransition) }
        return .noAction

    case (.inReview, .done):
        guard let pr = card.prNumber else { return .blocked(.missingPRNumber) }
        // Before `providedFollowUps`, on purpose. `.needsInput` is information
        // "only a human (or an explicit tool argument) can supply"; a caller
        // with no human reads it as "blocked, I will try again", which is a loop
        // that spins. Every refusal it can meet here is therefore a `.blocked`.
        if context.requiresVerifiedGreen {
            guard let verdict = context.prVerdict, verdict.isMergeableUnattended
            else { return .blocked(.notVerifiedGreen(reason: NotGreenReason.of(context.prVerdict))) }
        }
        guard let followUps = context.providedFollowUps else {
            return .needsInput(.followUps(prNumber: pr))
        }
        return .action(.mergePR(prNumber: pr, followUps: followUps))

    default:
        return .noAction
    }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd ElliotKit && swift test --filter RuleEngineTests`
Expected: PASS. `onlyDeclaredTransitionsAct` and `systemMovesNeverTrigger` must still pass unchanged — the new `(.inProgress, .inReview)` arm answers `.noAction` for every context they build.

Sample it, because one green run does not clear a suite:

```bash
cd ElliotKit && for i in 1 2 3 4 5; do swift test --filter RuleEngineTests 2>&1 | tail -3; done
```

- [ ] **Step 5: Commit**

```bash
git rev-parse --abbrev-ref HEAD
git add ElliotKit/Sources/ElliotModel/RuleEngine.swift \
        ElliotKit/Tests/ElliotModelTests/RuleEngineTests.swift
git commit -m "feat(model): a mover with no human merges only on a verified green"
```

---

## Task 8: one reader of the verdict, with the real head

> 🔴 **Corrected 2026-08-09.** `MoveBlock.notVerifiedGreen` carries a `NotGreenReason`, not a
> `PRSign?` — see the block at the head of Task 7 for why, and for the `NotGreenReason.of(_:)`
> derivation that task adds. Every `.notVerifiedGreen(sign: …)` in this task's blocks becomes
> `.notVerifiedGreen(reason: …)`.
>
> One consequence lands squarely here: this task's reader returns `nil` when `gh` cannot be
> reached, and `evaluateMove` then sees `prVerdict == nil` and refuses with `.noReading`. Check
> that the sentence a person gets in that case is honest — **"we could not ask" and "nothing has
> judged it" are different facts**, and if `.noReading` cannot tell them apart, say so in your
> report rather than papering over it. It is the same family as everything else in this pull
> request.


**Files:**
- Create: `ElliotKit/Sources/ElliotEngine/PRVerdictReader.swift`
- Create: `Fixtures/gh/prs-head-oid.json`
- Modify: `ElliotKit/Sources/ElliotEngine/BoardService.swift:76-82`, `:84-103` and `:151-165`
- Modify: `ElliotKit/Sources/ElliotEngine/MCPRequestHandler.swift:12-34` and `:580-602`
- Modify: `ElliotKit/Sources/ElliotAppKit/AppModel.swift:520`, `:550`, `:615`, `:623-626`
- Create: `ElliotKit/Tests/ElliotEngineTests/PRVerdictReaderTests.swift`
- Test: `ElliotKit/Tests/ElliotEngineTests/BoardServiceTests.swift`
- Test: `ElliotKit/Tests/ElliotEngineTests/OfflineParityTests.swift` (replayed unchanged)

**Interfaces:**
- Consumes: `MoveContext.requiresVerifiedGreen` / `.prVerdict` (Task 5), `MoveBlock.notVerifiedGreen(sign:)` (Task 6), the `(.inReview, .done)` branch (Task 7).
- Produces:
  - `public actor PRVerdictReader` in `ElliotEngine`, with
    `public init(store: BoardStore, gh: GHClient?)`,
    `public enum HeadPolicy: Sendable { case establish, ageAlone }`,
    `public struct Reading: Sendable, Hashable { public var status: PRStatus; public var resolved: ResolvedPRStatus }`,
    `public func reading(repo: Repo, prNumber: Int, now: Date, head: HeadPolicy) async throws -> Reading?`,
    `public static let listingTTL: TimeInterval`.
    ⚠ It **throws**, and the two failure directions are different on purpose: a store that cannot be read propagates — which is what `prStatusDTO` did before this reader existed, and losing it would turn a database error into "this pull request has nothing on it" — while a `gh` that cannot be reached answers `nil`, and only under `.establish`, where refusing the merge is the safe direction.
  - `BoardService.init(store: BoardStore, launcher: any RunLaunching, verdicts: PRVerdictReader? = nil)`.
  - `BoardService.proposeMove(cardID:to:origin:followUps:orderIndex:requiresVerifiedGreen:)` and `BoardService.move(cardID:to:origin:followUps:orderIndex:requiresVerifiedGreen:)`, both with `requiresVerifiedGreen: Bool = false` last.
  - `MCPRequestHandler.init(store:board:analysis:capture:verdicts:)` with `verdicts: PRVerdictReader? = nil` last.

- [ ] **Step 1: Write the failing test**

1a. Create `Fixtures/gh/prs-head-oid.json`:

```json
[
  {
    "number": 7,
    "url": "https://github.com/phmatray/Elliot/pull/7",
    "title": "feat(model): the thing issue 4 asked for",
    "body": "Ready for review.",
    "headRefName": "feat/4-the-thing",
    "isDraft": false,
    "state": "OPEN",
    "createdAt": "2026-08-02T09:00:00Z",
    "mergedAt": null,
    "headRefOid": "b7c1f0aa5d2e4c9188ff0e6a2d3b4c5d6e7f8091"
  }
]
```

1b. Create `ElliotKit/Tests/ElliotEngineTests/PRVerdictReaderTests.swift`:

```swift
import ElliotModel
import ElliotProcess
import ElliotStore
import Foundation
import Testing

@testable import ElliotEngine

/// The one reader of a stored pull-request reading, and the one parameter that
/// is allowed to differ between its two callers.
///
/// `BoardService` may be about to merge to a default branch on github.com;
/// `MCPRequestHandler.prStatusDTO` is drawing a picture for an agent. Passing
/// `nil` for `currentHeadOid` turns the sha rule off and leaves
/// `PRStatus.maximumAge` — 600 s — as the only protection, while `PRWatcher`
/// backs off to ~300 s ± 20 %. That is enough for a picture and not enough for
/// a merge, so the difference is a parameter rather than two implementations.
@Suite("PR verdict reader")
struct PRVerdictReaderTests {

    private enum Paths {
        static let repoRoot: URL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // ElliotEngineTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // ElliotKit
            .deletingLastPathComponent()   // repo root

        static let fakeGH = repoRoot.appendingPathComponent("Scripts/fake-gh.sh").path

        static func fixture(_ name: String) -> String {
            repoRoot.appendingPathComponent("Fixtures/gh/\(name)").path
        }
    }

    /// The head `Fixtures/gh/prs-head-oid.json` reports for pull request 7.
    private static let liveHead = "b7c1f0aa5d2e4c9188ff0e6a2d3b4c5d6e7f8091"

    private func client(
        prs: String = "prs-head-oid.json", mode: String = "ok", argvOut: String? = nil
    ) -> GHClient {
        var environment = ["FAKE_GH_MODE": mode, "FAKE_GH_PRS": Paths.fixture(prs)]
        if let argvOut { environment["FAKE_GH_ARGV_OUT"] = argvOut }
        return GHClient(config: ToolConfig(
            claudePath: "", ghPath: Paths.fakeGH, gitPath: "", environment: environment))
    }

    /// How many `gh pr list` invocations reached the fake so far.
    ///
    /// The shape is `PRWatcherStatusTests.prViewCalls()`'s, one subcommand over:
    /// `FAKE_GH_ARGV_OUT` dumps one argument per line, so a `pr list` is the
    /// literal line "list" immediately after a line "pr". Adjacency, not a bare
    /// count of "list" — `--state` values and fixture paths are lines too.
    private func listCalls(in path: String) -> Int {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return 0 }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        return zip(lines, lines.dropFirst()).count { $0 == "pr" && $1 == "list" }
    }

    private func seeded(headRefOid: String) async throws -> (BoardStore, Repo) {
        let store = try BoardStore.inMemory()
        let repo = Repo(
            path: "/tmp/elliot-\(UUID().uuidString)",
            nameWithOwner: "phmatray/Elliot", displayName: "Elliot")
        try await store.saveRepo(repo)
        try await store.savePRStatus(PRStatus(
            repoID: repo.id, prNumber: 7, headRefOid: headRefOid, checkedAt: Date(),
            rawMergeStateStatus: "CLEAN", rawMergeable: "MERGEABLE", rawReviewDecision: "APPROVED",
            checks: [
                GHMergeStatus.StatusCheck(
                    name: "build-and-test", conclusion: "SUCCESS", status: "COMPLETED"),
            ]))
        return (store, repo)
    }

    @Test("A reading taken on the commit gh reports is fresh, and mergeable")
    func headAgreesAndTheReadingStands() async throws {
        let (store, repo) = try await seeded(headRefOid: Self.liveHead)
        let reader = PRVerdictReader(store: store, gh: client())

        // `try #require(try await …)` — the inner `try` written out, which is
        // this suite's neighbours' idiom for a throwing async call inside the
        // macro (`PRWatcherStatusTests:121`, `OfflineParityTests:95`).
        let reading = try #require(
            try await reader.reading(repo: repo, prNumber: 7, now: Date(), head: .establish))
        #expect(!reading.resolved.isStale)
        #expect(reading.resolved.isMergeableUnattended)
    }

    @Test("A reading about a commit that is no longer the head is stale under .establish")
    func movedHeadIsStale() async throws {
        // The whole reason `nil` is not good enough. The row is minutes old, so
        // the age rule says nothing at all; only the sha rule can catch it, and
        // only `.establish` asks the question.
        let (store, repo) = try await seeded(headRefOid: "0000000000000000000000000000000000000000")
        let reader = PRVerdictReader(store: store, gh: client())
        let now = Date()

        let establish = try #require(
            try await reader.reading(repo: repo, prNumber: 7, now: now, head: .establish))
        #expect(establish.resolved.isStale)
        #expect(!establish.resolved.isMergeableUnattended)

        let ageAlone = try #require(
            try await reader.reading(repo: repo, prNumber: 7, now: now, head: .ageAlone))
        #expect(!ageAlone.resolved.isStale, "the display policy must be unchanged")
    }

    @Test("A head that cannot be established refuses rather than falling back")
    func unreachableGHRefusesUnderEstablish() async throws {
        // Fail closed. Falling back to `currentHeadOid: nil` here would answer
        // "fresh and green" out of an inability to look, which is the shape of
        // every false green this repository has written down.
        let (store, repo) = try await seeded(headRefOid: Self.liveHead)
        let reader = PRVerdictReader(store: store, gh: client(mode: "fail"))

        // Resolved before the assertion rather than inside it: `#expect`'s
        // message autoclosure cannot carry an `await`, and a bare "nil was not
        // nil" says nothing about which policy produced it.
        let refused = try await reader.reading(
            repo: repo, prNumber: 7, now: Date(), head: .establish)
        #expect(refused == nil, "an unreachable gh authorised a merge")

        // …and the display policy still answers, because it never asked. It is
        // also the control on the throw: an unreachable `gh` must be a `nil`,
        // never an error, or this line would not be reached at all.
        let drawn = try await reader.reading(repo: repo, prNumber: 7, now: Date(), head: .ageAlone)
        #expect(drawn != nil, "the display policy went to the network")
    }

    @Test("A reader with no gh client at all refuses every establish")
    func noClientRefuses() async throws {
        // The headless construction — a handler built by a test, a board built
        // without one. It must not be able to authorise a merge.
        let (store, repo) = try await seeded(headRefOid: Self.liveHead)
        let reader = PRVerdictReader(store: store, gh: nil)

        let refused = try await reader.reading(
            repo: repo, prNumber: 7, now: Date(), head: .establish)
        #expect(refused == nil, "a reader with no gh authorised a merge")
    }

    @Test("One gh listing serves a window, and the next merge takes a fresh one")
    func theHeadListingIsCachedForItsWindow() async throws {
        // `listingTTL` sits on the merge path, so it is a number that decides
        // how old a head may be when a pull request is merged with nobody
        // watching — and without this it would be a constant nobody had ever
        // seen behave. The clock is injected, so nothing here sleeps and nothing
        // measures an elapsed duration.
        let argv = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("argv-\(UUID().uuidString).txt").path
        let (store, repo) = try await seeded(headRefOid: Self.liveHead)
        let reader = PRVerdictReader(store: store, gh: client(argvOut: argv))
        // Anchored on the seeded row's own moment rather than on an epoch
        // constant: all three reads then sit inside `PRStatus.maximumAge`, so a
        // staleness rule cannot quietly become the thing being measured.
        let start = Date()

        _ = try await reader.reading(repo: repo, prNumber: 7, now: start, head: .establish)
        _ = try await reader.reading(
            repo: repo, prNumber: 7,
            now: start.addingTimeInterval(PRVerdictReader.listingTTL - 1), head: .establish)
        #expect(listCalls(in: argv) == 1, "a read inside the window went to gh a second time")

        _ = try await reader.reading(
            repo: repo, prNumber: 7,
            now: start.addingTimeInterval(PRVerdictReader.listingTTL), head: .establish)
        #expect(listCalls(in: argv) == 2, "the window never expired")
    }

    @Test("A pull request with no stored reading answers nothing, under either policy")
    func noStoredRowAnswersNothing() async throws {
        let (store, repo) = try await seeded(headRefOid: Self.liveHead)
        let reader = PRVerdictReader(store: store, gh: client())

        let establish = try await reader.reading(
            repo: repo, prNumber: 99, now: Date(), head: .establish)
        let ageAlone = try await reader.reading(
            repo: repo, prNumber: 99, now: Date(), head: .ageAlone)
        #expect(establish == nil)
        #expect(ageAlone == nil)
    }
}
```

1c. Add to `ElliotKit/Tests/ElliotEngineTests/BoardServiceTests.swift`, at the end of the suite:

```swift
    @Test("A merge asked for under the green guard is refused when nothing was read")
    func unattendedMergeWithoutAVerdictIsRefused() async throws {
        // The board's half of the guard. `Fixture.make` builds a `BoardService`
        // with no `PRVerdictReader`, so there is nothing that could establish a
        // verdict — and the answer to that has to be a refusal, never a merge.
        let f = try await Fixture.make()
        var card = try await f.board.createCard(repoID: f.repo.id, title: "Run log").card
        card.column = .inReview
        card.prNumber = 279
        try await f.store.saveCard(card)

        let result = try await f.board.move(
            cardID: card.id, to: .done, origin: .autoDev(sessionID: UUID()),
            followUps: [], requiresVerifiedGreen: true
        )
        #expect(result == .blocked(.notVerifiedGreen(sign: nil)))
        #expect(try await f.store.card(id: card.id)?.column == .inReview)
        let launched = await f.launcher.launchedRuns()
        #expect(launched.isEmpty, "a merge ran on a verdict nobody established")
    }

    @Test("The same merge, not asked to be verified, still runs")
    func watchedMergeStillRuns() async throws {
        // The control the refusal above cannot be: without it, a board that
        // refused *every* merge would pass.
        let f = try await Fixture.make()
        var card = try await f.board.createCard(repoID: f.repo.id, title: "Run log").card
        card.column = .inReview
        card.prNumber = 279
        try await f.store.saveCard(card)

        let result = try await f.board.move(
            cardID: card.id, to: .done, origin: .userDrag, followUps: []
        )
        guard case .moved(let runID?) = result else {
            Issue.record("expected a run, got \(result)")
            return
        }
        #expect(try await f.store.run(id: runID)?.kind == .mergePR)
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd ElliotKit && swift test --filter PRVerdictReaderTests`
Expected: FAIL — the target does not compile:
`error: cannot find 'PRVerdictReader' in scope`, and in `BoardServiceTests.swift`
`error: extra argument 'requiresVerifiedGreen' in call`.

- [ ] **Step 3: Write minimal implementation**

3a. Create `ElliotKit/Sources/ElliotEngine/PRVerdictReader.swift`:

```swift
import ElliotModel
import ElliotProcess
import ElliotStore
import Foundation

/// What `gh` established about a pull request, resolved against the clock and —
/// when it matters — against the pull request's real head.
///
/// **One implementation, two callers**: `BoardService`, which may be about to
/// merge, and `MCPRequestHandler.prStatusDTO`, which is drawing a picture. Both
/// live in `ElliotEngine`, so the reason `OfflineResponder` keeps its own copy —
/// `ElliotMCPKit` imports neither this target nor `ElliotProcess`, so the helper
/// can hold no copy of the rules — does not apply *between these two*. A third
/// hand-written `resolved(now: Date(), currentHeadOid: nil)` inside one module
/// would be a rule written twice for no reason at all.
///
/// **The one difference that is real stays a parameter.** `resolved` treats a
/// `nil` head as "the sha rule is off", which leaves `PRStatus.maximumAge` — 600
/// seconds — as the only protection, while `PRWatcher` backs off to ~300 s ± 20
/// %. For a picture that is fine and cheap. For a merge it is not: the reading
/// may be about a commit nobody is reviewing any more.
public actor PRVerdictReader {

    /// What to do about the pull request's current head.
    public enum HeadPolicy: Sendable {
        /// Ask `gh`, and answer nothing at all if it cannot be asked.
        ///
        /// The policy for anything that may merge. Failing closed matters more
        /// than failing usefully here: a head we could not read cannot prove the
        /// stored reading is about the commit under review, and "I could not
        /// look" rendered as "nothing to report" is the shape of every false
        /// green this repository has written down.
        case establish
        /// Do not go to the network; let the age rule stand alone.
        ///
        /// A read that draws a card must not spend a `gh pr list` per card, and
        /// `PRWatcher` already re-reads whenever the head moves. This is exactly
        /// what `prStatusDTO` did by hand, and what `OfflineResponder` — which
        /// can reach neither `gh` nor the network — does one target over, which
        /// is what keeps `OfflineParityTests` comparing like with like.
        case ageAlone
    }

    /// The stored row and its resolution, together.
    ///
    /// Both, because `PRStatusDTO(_:resolved:)` needs both and reading the row
    /// twice for one answer is how two callers come to disagree about which
    /// row they meant.
    public struct Reading: Sendable, Hashable {
        public var status: PRStatus
        public var resolved: ResolvedPRStatus

        public init(status: PRStatus, resolved: ResolvedPRStatus) {
            self.status = status
            self.resolved = resolved
        }
    }

    private struct Listing {
        var headsByNumber: [Int: String]
        var readAt: Date
    }

    /// How long one `gh pr list` answer is reused across the cards of a
    /// repository.
    ///
    /// Strictly under `PRStatus.refreshInterval` (300 s), for the same reason
    /// that one is strictly under `maximumAge` (600 s): the cheap rule must
    /// never be the one that decides. A page of cards costs one listing;
    /// a merge taken thirty seconds later costs another.
    public static let listingTTL: TimeInterval = 30

    private let store: BoardStore
    private let gh: GHClient?
    private var listings: [UUID: Listing] = [:]

    /// `gh` is optional because a headless construction genuinely has none — the
    /// same shape, and the same reason, as `MCPRequestHandler.capture`. With
    /// none, `.establish` answers nothing, which refuses a merge rather than
    /// granting one.
    public init(store: BoardStore, gh: GHClient?) {
        self.store = store
        self.gh = gh
    }

    /// - Throws: whatever the store throws. Deliberately **not** `try?`: a
    ///   database that cannot be read is not a pull request with nothing on it,
    ///   and `prStatusDTO` propagated that difference before this reader
    ///   existed. The only failure answered with `nil` is `gh` being
    ///   unreachable, below, and only under `.establish`.
    public func reading(
        repo: Repo, prNumber: Int, now: Date, head policy: HeadPolicy
    ) async throws -> Reading? {
        guard let status = try await store.prStatus(repoID: repo.id, prNumber: prNumber)
        else { return nil }

        switch policy {
        case .ageAlone:
            return Reading(status: status, resolved: status.resolved(now: now, currentHeadOid: nil))
        case .establish:
            guard let head = await currentHead(repo: repo, prNumber: prNumber, now: now)
            else { return nil }
            return Reading(status: status, resolved: status.resolved(now: now, currentHeadOid: head))
        }
    }

    /// The head as of the `gh pr list` `PRWatcher` already performs — the same
    /// listing, the same fields, and `headRefOid` riding along on it as a cheap
    /// scalar rather than a call per pull request.
    private func currentHead(repo: Repo, prNumber: Int, now: Date) async -> String? {
        if let cached = listings[repo.id],
           now.timeIntervalSince(cached.readAt) < Self.listingTTL {
            return cached.headsByNumber[prNumber]
        }
        guard let gh, let prs = try? await gh.pullRequests(repo: repo.nameWithOwner) else {
            // Not cached: a failure must not be remembered as an answer.
            return nil
        }
        var heads: [Int: String] = [:]
        for pr in prs where pr.headRefOid != nil {
            heads[pr.number] = pr.headRefOid
        }
        listings[repo.id] = Listing(headsByNumber: heads, readAt: now)
        return heads[prNumber]
    }
}
```

3b. In `ElliotKit/Sources/ElliotEngine/BoardService.swift`, add `import ElliotProcess` to the imports at the top (line 1-3 become four imports, alphabetical: `ElliotModel`, `ElliotProcess`, `ElliotStore`, `Foundation`), then replace lines 76-82:

```swift
    private let store: BoardStore
    private let launcher: any RunLaunching

    public init(store: BoardStore, launcher: any RunLaunching) {
        self.store = store
        self.launcher = launcher
    }
```

with:

```swift
    private let store: BoardStore
    private let launcher: any RunLaunching
    /// The only thing here that can establish a verdict.
    ///
    /// Defaulted rather than required so every headless construction keeps
    /// compiling — and a board built without one refuses every merge asked for
    /// under `requiresVerifiedGreen`, which is the direction to fail in.
    private let verdicts: PRVerdictReader

    public init(
        store: BoardStore,
        launcher: any RunLaunching,
        verdicts: PRVerdictReader? = nil
    ) {
        self.store = store
        self.launcher = launcher
        self.verdicts = verdicts ?? PRVerdictReader(store: store, gh: nil)
    }
```

3c. In the same file, replace `proposeMove`'s doc comment, signature and context assembly — **lines 84-103**, from `/// Works out what a move would mean…` (84) to the `)` closing the `MoveContext` (103). ⚠ Not 85: the block below re-states that doc line. ⚠ Not 104 either: `let outcome = evaluateMove(…)` stays exactly as it is.

```swift
    /// Works out what a move would mean, without changing anything.
    ///
    /// `requiresVerifiedGreen` is the caller's own claim about itself, not
    /// something derived from `origin`: a drag is watched by the person making
    /// it, and an MCP call has a human behind the agent. Only a caller with
    /// nobody at all asks for the restraint, and it asks by name.
    public func proposeMove(
        cardID: UUID,
        to column: ElliotModel.Column,
        origin: MoveOrigin,
        followUps: [String]? = nil,
        orderIndex: Double? = nil,
        requiresVerifiedGreen: Bool = false
    ) async throws -> MoveProposal {
        guard let card = try await store.card(id: cardID) else { throw BoardError.cardNotFound(cardID) }
        guard let repo = try await store.repo(id: card.repoID) else {
            throw BoardError.repoNotFound(card.repoID)
        }

        let activeRun = try await store.activeRun(cardID: cardID)
        // Read only when the answer can change the decision: `.establish` spends
        // a `gh pr list`, and a drop that is not held to a verdict must not cost
        // one. A card with no pull request number has nothing to read, and the
        // rule refuses it on `missingPRNumber` before it looks at the verdict.
        var prVerdict: ResolvedPRStatus?
        if requiresVerifiedGreen, let prNumber = card.prNumber {
            prVerdict = try await verdicts.reading(
                repo: repo, prNumber: prNumber, now: Date(), head: .establish)?.resolved
        }
        let context = MoveContext(
            repoIsEnabled: repo.isEnabled,
            activeRunID: activeRun?.id,
            allowSideEffects: origin.allowsSideEffects,
            providedFollowUps: followUps,
            requiresVerifiedGreen: requiresVerifiedGreen,
            prVerdict: prVerdict
        )
```

3d. In the same file, replace `move`'s doc comment, signature and body — **lines 151-165**, from `/// Propose and commit in one step…` (151) to its closing brace (165). ⚠ Not 152: the block below re-states that doc line.

```swift
    /// Propose and commit in one step — what the MCP tool and simple drags use.
    @discardableResult
    public func move(
        cardID: UUID,
        to column: ElliotModel.Column,
        origin: MoveOrigin,
        followUps: [String]? = nil,
        orderIndex: Double? = nil,
        requiresVerifiedGreen: Bool = false
    ) async throws -> MoveResult {
        let proposal = try await proposeMove(
            cardID: cardID, to: column, origin: origin,
            followUps: followUps, orderIndex: orderIndex,
            requiresVerifiedGreen: requiresVerifiedGreen
        )
        return try await commitMove(proposal)
    }
```

3e. In `ElliotKit/Sources/ElliotEngine/MCPRequestHandler.swift`, add the stored property and init parameter (the struct's head, lines 12-34). After `private let capture: (any WindowCapturing)?` (line 22) add:

```swift
    /// The one reader of a pull request's stored verdict, shared with
    /// `BoardService` so a page of cards and the merge that follows it read one
    /// `gh pr list` between them rather than one each.
    private let verdicts: PRVerdictReader
```

and extend the init:

```swift
    public init(
        store: BoardStore,
        board: BoardService,
        analysis: AnalysisService,
        capture: (any WindowCapturing)? = nil,
        verdicts: PRVerdictReader? = nil
    ) {
        self.store = store
        self.board = board
        self.analysis = analysis
        self.capture = capture
        // A handler built without one gets a reader that cannot reach `gh`.
        // That is honest rather than lossy: every read here uses `.ageAlone`,
        // which never asks `gh` anything.
        self.verdicts = verdicts ?? PRVerdictReader(store: store, gh: nil)
    }
```

3f. In the same file, replace **lines 580-602** — `prStatusDTO`'s doc comment (580) through the `}` that closes `MCPRequestHandler` itself (602). The block below carries that final unindented brace, so a range stopping at 601 leaves a second one behind:

```swift
    /// The stored reading, resolved against the clock.
    ///
    /// `.ageAlone`, on purpose: establishing the pull request's head right now
    /// would mean a `gh pr list` per card inside a read, and `PRWatcher` already
    /// re-reads whenever the head moves. What remains in force is the age rule,
    /// which is the one that matters when nothing has been running — the app
    /// closed, asleep, or unable to reach `gh`.
    ///
    /// `OfflineResponder` computes the identical answer, and still cannot share
    /// this code: `ElliotMCPKit` imports neither this target nor `ElliotProcess`,
    /// so the helper holds no copy of the rules. `OfflineParityTests` is what
    /// keeps them equal, and `.ageAlone` is what keeps them *able* to be equal —
    /// a snapshot can never establish a head, so a live answer that did would
    /// diverge from it by construction.
    private func prStatusDTO(for card: Card) async throws -> PRStatusDTO? {
        // In Review only — the same gate the watcher and the board apply. A card
        // `merge-pr` has just moved to Done would otherwise serve its pre-merge
        // reading as fresh for the whole `maximumAge` window, and the app and
        // this surface would disagree about the same card.
        guard card.column == .inReview, let number = card.prNumber else { return nil }
        guard let repo = try await store.repo(id: card.repoID) else { return nil }
        guard let reading = try await verdicts.reading(
            repo: repo, prNumber: number, now: Date(), head: .ageAlone)
        else { return nil }
        return PRStatusDTO(reading.status, resolved: reading.resolved)
    }
}
```

3g. In `ElliotKit/Sources/ElliotAppKit/AppModel.swift`, build one reader and hand it to both. Replace line 520:

```swift
            let board = BoardService(store: store, launcher: scheduler)
```

with:

```swift
            // One reader, shared: the board's merge decision and the MCP
            // surface's card reads then spend one `gh pr list` between them
            // rather than one each, and there is one place where "what did `gh`
            // establish about this pull request" is answered.
            let verdicts = PRVerdictReader(store: store, gh: ghClient)
            let board = BoardService(store: store, launcher: scheduler, verdicts: verdicts)
```

Replace line 550:

```swift
            startIPC(board: board, store: store, analysis: analysisService)
```

with:

```swift
            startIPC(board: board, store: store, analysis: analysisService, verdicts: verdicts)
```

Replace the signature at line 615 and the construction at lines 623-626:

```swift
    private func startIPC(
        board: BoardService, store: BoardStore, analysis: AnalysisService,
        verdicts: PRVerdictReader
    ) {
```

```swift
            let handler = MCPRequestHandler(
                store: store, board: board, analysis: analysis,
                capture: AppKitWindowCapture(), verdicts: verdicts
            )
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd ElliotKit && swift test --filter PRVerdictReaderTests`
Expected: PASS — 6 tests.
Run: `cd ElliotKit && swift test --filter BoardServiceTests`
Expected: PASS.
Run: `cd ElliotKit && swift test --filter OfflineParityTests`
Expected: PASS, **unchanged** — the parity harness builds its handler without a reader and its `ToolConfig` points `ghPath` at `/usr/bin/false`, and `.ageAlone` never asks `gh` anything, so `readsAgree` and `prStatusReachesBothAnswers` compare exactly what they compared before.

Then the whole package, five times after one clean build:

```bash
cd ElliotKit && swift build && for i in 1 2 3 4 5; do swift test 2>&1 | tail -3; done
```

Expected: `1418`-plus tests, 0 failures, five times.

- [ ] **Step 5: Commit**

```bash
git rev-parse --abbrev-ref HEAD
git add ElliotKit/Sources/ElliotEngine/PRVerdictReader.swift \
        ElliotKit/Sources/ElliotEngine/BoardService.swift \
        ElliotKit/Sources/ElliotEngine/MCPRequestHandler.swift \
        ElliotKit/Sources/ElliotAppKit/AppModel.swift \
        ElliotKit/Tests/ElliotEngineTests/PRVerdictReaderTests.swift \
        ElliotKit/Tests/ElliotEngineTests/BoardServiceTests.swift \
        Fixtures/gh/prs-head-oid.json
git commit -m "feat(engine): one reader of the verdict, and it asks for the real head"
```
