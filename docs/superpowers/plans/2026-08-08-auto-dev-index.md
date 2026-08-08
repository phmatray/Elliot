# Auto-dev — plan index and delivery order

> **For agentic workers:** this file is a map, not a plan. Each pull request has its own
> plan document with checkbox steps. Start from the order below, not from the numbers.

**Spec:** [`docs/superpowers/specs/2026-08-08-auto-dev-design.md`](../specs/2026-08-08-auto-dev-design.md)

Auto-dev is a session that takes N cards from Backlog and advances each one to merged or
blocked with no human gesture. It ships as six pull requests, each independently mergeable,
each with its own plan.

## The plans

| # | Plan | Delivers |
|---|---|---|
| PR1 | [`…-pr1-rules.md`](2026-08-08-auto-dev-pr1-rules.md) | `MoveOrigin.autoDev`, `MoveContext.requiresVerifiedGreen` + `prVerdict`, two new `MoveBlock` cases, the two changed branches of `evaluateMove`, `isMergeableUnattended` |
| PR2 | [`…-pr2-value.md`](2026-08-08-auto-dev-pr2-value.md) | `effort` / `evidence` / `appraisedAt` on `Card`, `Effort.unstated`, `Grounding`, `CardValue`, `CardFieldWritersTests` |
| PR3 | [`…-pr3-resume.md`](2026-08-08-auto-dev-pr3-resume.md) | `ClaudeInvocation.resumeFrom`, `SkillRun.resumedFrom`, `ResumeVerdict`, and the `verifyCreateIssue` window fix |
| PR4 | [`…-pr4-loop.md`](2026-08-08-auto-dev-pr4-loop.md) | `AutoDevSession`, `AutoDevPolicy`, `AutoDevService`, the admission-time green guard, the `PRWatcher` hook and backoff fix |
| PR5 | [`…-pr5-screen.md`](2026-08-08-auto-dev-pr5-screen.md) | The Operations band, the status-bar door, the card mark, the stop control, the on-screen pass |
| PR6 | [`…-pr6-appraisal.md`](2026-08-08-auto-dev-pr6-appraisal.md) | `SkillKind.appraiseCards`, `isReadOnly`, the three-way `finish` routing, the Preflight guard moved into `ElliotEngine` |

## Order — and it is not 1 → 6

The numbers name the pull requests; this list names the order. Three of the steps below
reverse the numbering, and each reversal has a measured reason recorded in the spec.

### Hard prerequisites, outside this design

- **PR 0·2** — `MoveContext.repoPreflight` and `MoveBlock.repoBlocked`. Auto-dev *consumes*
  these and cannot supply them. Without it, a session fires `claude -p
  --permission-mode bypassPermissions` N times into a repository Preflight refused.
- **PR 0·3** (#179) — the concurrent `pump()` race. `pump()` checks
  `run.state == .queued` (`RunScheduler.swift:255`) but that check precedes an `await`, and
  `start` persists `.running` only after the spawn, so two concurrent drains both cross it.
  Auto-dev multiplies drains by construction: every `commitMove` triggers one, every
  `finish` triggers one, every resume attempt triggers one.

### Then

0. **PR6's write decision** — *not the whole pull request*. Only the answer to
   "who writes `effort`/`evidence`, and when". The spec settles it (one appraisal run per
   card, carrying a `cardID`), and PR2's schema depends on that answer against the criterion
   written at `Migrations.swift:118-127`. Getting it wrong costs a second migration.
1. **PR1**
2. **PR2** — never in parallel with PR1. Both edit `RuleEngine.swift`, which is **not** in
   the union-merge list (that list is `Package.swift`, `AppModel.swift`, `Migrations.swift`,
   `README.md`, test files). PR 0·2 touches the same four switches.
3. **PR3** and **PR6**, totally ordered with respect to each other, with the chosen order
   written into the body of whichever ships second.
4. **PR6 before PR5.** As split, PR6 ships a `SkillKind` nothing can start — no wire case, no
   control on screen, no call from the loop. That is dead code at delivery.
5. **PR5**
6. **PR4 last** among the engine pull requests, and not before the admission-time verdict
   re-read has an owner. Shipping PR4 on PR1 alone ships a loop that merges on stale readings
   in exactly the configuration the design imposes.

## Open before executing anything: four cross-plan items

Each plan was written and verified in isolation, so none of its readers could see these. Two are
**decisions**, not edits; all four are recorded in full inside the plans they touch.

| # | What | Where the detail is | Owner |
|---|---|---|---|
| 1 | 🔴 **`ElliotModel/AutoDev.swift` is created twice.** PR5 ships `AutoDevEngagement` + `AutoDevDisposition {engaged, merged, blocked}` + `AutoDevTally`; PR4 ships `AutoDevCardState` + `DispositionCode {retry, wait, held, settled, aborted}` in the same file. Two per-card row types, one rendered and one persisted, nothing joining them | header of PR4 Task 3; PR5 Prerequisites | **human** |
| 2 | 🔴 **`AutoDevDriving` has no conformer, and `AppModel.autoDev` is declared twice with two types.** PR5 declares the protocol and says PR4 conforms; PR4 never names it and exposes a different surface | PR5 Prerequisites; PR4 Task 14 | **human** |
| 3 | ⚠️ **Nobody selects the cards.** PR2 builds `CardValue` / `CardRanking.rank`; no plan calls either. PR5 passes a `cardLimit`, PR4 receives ids already chosen | PR5 Task 4; PR4 Prerequisites | **human** |
| 4 | ⚠️ **PR4 hand-writes a fourth copy of the unattended-start rule** PR6 unified into `UnattendedStartRefusal` one PR earlier | PR4 Task 11 | mechanical, once 1–3 are settled |

Three smaller ones are already corrected in place and need no decision: PR1's two `MoveBlock`
shadows had to learn PR 0·2's `repoBlocked`; the `--add-dir` seam PR3 and PR6 both claim in
`ClaudeInvocation.arguments()` now has a stated order (extra directories first, then the resume
tokens); and PR6's `finish` routing has to keep PR3's `resume:` argument on `completeCardRun`.

## The shared resource: migration numbers

**PR2, PR3 and PR4 each add a migration, and all three want v9.** The last registered is
`v8_prStatus` (`Migrations.swift:138`).

Under the arbitrated order the outcome is not a race, it is a queue — **PR2 = `v9_cardAppraisal`,
PR3 = `v10_runResumedFrom`, PR4 = `v11_autoDev`** — so two of the three renumber as a matter of
course. Each plan now says so at its own migration task. And **PR2 raises
`rewindToV1`'s `precondition(db.changesCount == 4)` to 5**, so PR3's and PR4's instruction is *leave
whatever is there alone*, never *restore it to 4*.

Every renumbering ships its `RenamedMigration` (`Migrations.swift:194-202`) **in the same
diff**. GRDB identifies a migration by name, so a machine that ran the losing branch replays
it against tables that already exist — a real incident, recorded at
`Migrations.swift:180-184`. Auto-dev is developed by running unmerged branches on this
machine, so that escape is the normal case here, not the exception.

A v9 that only *creates* a table needs no change to `SchemaUpgradeTests.rewindToV1` — v4, v6
and v8 are not in its `IN` clause either. A v9 that **alters `card`** does need its
`DROP COLUMN` there, or the backfill test runs against an already-current database and
measures nothing.

## The one decision still open

**What counts as green** for an unattended merge — the spec's closing section. These plans
are written against **option A**: `!isStale && sign == nil && merge == .clean &&
ci.hasBuildVerdict`, where `hasBuildVerdict` requires a passing check whose name is not in a
data list of analysers.

Option A carries one prior change — `CIState.passing([String])` instead of `passing(Int)`,
because the passing checks' names never reach the predicate today. **That change is isolated
in its own task in PR1**, so downgrading to option B (`!isStale && sign == nil &&
merge == .clean`) is a task deletion rather than a rewrite.

⚠️ **Three plans carry that same task, and only PR1's should ever run.** PR1's Tasks 1 and 2 own it;
PR2's Task 10 and PR4's Task 2 each carry a redundant copy, so that Option A could not be adopted
and then silently lost between two documents. Both copies now open with a `grep` on
`ElliotKit/Sources/ElliotModel/PRStatus.swift` and **stop** on `case passing([String])`. The copies
are not identical — PR4's declares `NonBuildChecks.names: [String]` where PR1 ships
`exactNames: Set<String>` + `prefixes: [String]` — so PR4's must not be pasted over PR1's. They
agree on every check name either plan asserts; they differ only in the members, and nothing outside
`hasBuildVerdict` reads the list.

## Before believing any failure

A stale `.build` produces failures that cannot happen — wrong enum values, link errors,
SIGBUS, confident bisects onto innocent commits. **Any `git checkout` that crosses commits
can cause it.**

```bash
rm -rf ElliotKit/.build
```

Then look at your change. And `swift test --filter` matching nothing prints a warning and
**exits 0**, which is indistinguishable from success — never read an exit code alone.
