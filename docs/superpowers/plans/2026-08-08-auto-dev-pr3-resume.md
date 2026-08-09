# Auto-dev PR3 — The Resume Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give Elliot the ability to fork a previous Claude Code session, and a verdict about whether that fork found anything — without letting a resumed run file a second GitHub issue for work its first attempt already did.

**Architecture:** Four pure additions in `ElliotModel` and `ElliotProcess` (`ClaudeInvocation.resumeFrom`, `SkillRun.resumedFrom` + migration v9, `ResumeVerdict`, `ResumeChain`), consumed by three sites in `ElliotEngine`: `RunScheduler.start` builds the invocation from the run's own `cwd` and predecessor, `RunScheduler.finish` computes the verdict where the terminal result lives, and `Verifier.verifyCreateIssue` anchors its `gh` window on the **first** attempt of a resume chain rather than on the resume's own start. PR3 renders a verdict and relaunches nothing; the relaunch policy is PR4's.

**Tech Stack:** Swift 6.3.1, SwiftPM, swift-testing (`@Suite`/`@Test`/`#expect`/`#require`), GRDB (SQLite), the repository's own `Scripts/fake-claude.sh` and `Scripts/fake-gh.sh` harnesses.

## Global Constraints

- Swift tools-version **6.3.1** — the patch is load-bearing, never `6.3`. `swiftLanguageModes: [.v6]`, deployment target macOS 15, strict concurrency: any type crossing an isolation boundary is `Sendable`.
- Build: `cd ElliotKit && swift build` · Tests: `cd ElliotKit && swift test` · One suite: `cd ElliotKit && swift test --filter <TypeName>`.
- `--filter` matches the **type** name, not the `@Suite` display name. ⚠ A filter that matches nothing prints `warning: No matching test cases were run` and **exits 0** — indistinguishable from success. Never conclude from an exit code alone; read the printed test count.
- Test framework is **swift-testing**, never XCTest.
- ⛔ **Never run `swift format` over the tree.** This code is hand-formatted, 4 spaces. Format the lines you write by hand, to match their neighbours.
- Every asynchronous wait in a test is **bounded**, through `withTimeout` from the `TestSupport` target. No assertion measures an absolute duration. No test sleeps a fixed interval waiting for a child — it waits on a file the fake touches.
- ⛔ Nothing in production code waits on `Process.waitUntilExit()`.
- Migrations are additive; shipped ones are frozen. The last registered is `v8_prStatus` (`ElliotKit/Sources/ElliotStore/Migrations.swift:138`). A renumbering ships its `RenamedMigration` in the **same diff** (`Migrations.swift:195-202`).
- Commits: Conventional Commits with the layer as scope — `feat(model|store|process|engine|ipc|mcp|app): subject`.
- Branch: `feat/<issue>-<slug>` — the issue number first, followed by a hyphen (`PRMatcher.branchMatches` anchors on it). This plan's branch is `feat/<n>-auto-dev-resume`, where `<n>` is the number of the GitHub issue carrying PR3. **No task in this plan creates, switches or pushes a branch**; every Step 5 commits onto the branch already checked out.
- ⚠ Several worktrees share this repository's `.git`. Re-read `git rev-parse --abbrev-ref HEAD` **immediately before** every commit — each Step 5 below does this in the same shell block.
- A stale `.build` produces impossible failures (wrong enum values, link errors, SIGBUS). After any checkout that crosses commits: `rm -rf ElliotKit/.build` **before** believing a failure.
- One green run does not clear a suite. Sampling five times after a clean build costs about eight seconds; Task 7 ends with that sampling.
- **No protocol bump.** `resumedFrom` is not on the IPC wire and no DTO carries it. `elliotProtocolVersion` stays 6 (`ElliotKit/Sources/ElliotIPC/Protocol.swift`).

---

## File Structure

**Created**

| File | Responsibility |
|---|---|
| `ElliotKit/Sources/ElliotModel/ResumeVerdict.swift` | `enum ResumeVerdict { case sessionGone, ran }` and the pure five-conjunct predicate `of(resumedFrom:result:)`. No I/O, no clock. |
| `ElliotKit/Sources/ElliotModel/ResumeChain.swift` | `enum ResumeChain` with `firstAttemptStart(of:among:)` — walks `SkillRun.resumedFrom` backwards, cycle-guarded, and answers the moment the chain's first attempt began. |
| `ElliotKit/Tests/ElliotModelTests/ResumeVerdictTests.swift` | Every conjunct of the predicate, one dropped at a time. |
| `ElliotKit/Tests/ElliotModelTests/ResumeChainTests.swift` | Fresh run, never-started run, three-link chain, truncated page, cycle. |
| `ElliotKit/Tests/ElliotEngineTests/ResumeVerificationTests.swift` | `Verifier.verifyCreateIssue`'s window against a real `fake-gh.sh` subprocess: the issue the first attempt filed is found; without the chain it is missed; a `.sessionGone` run does not borrow the agent's prose. |
| `Fixtures/stream-json/resume-session-gone.ndjson` | One terminal `result` line: `is_error: true`, `num_turns: 0`, `subtype: "error_during_execution"`, `errors: ["No conversation found…"]`. |

**Modified**

| File | Change |
|---|---|
| `ElliotKit/Sources/ElliotProcess/ClaudeRunner.swift` | `ClaudeInvocation.resumeFrom: UUID?`, and the three tokens emitted in one `if let` right after `"--add-dir", cwd`. |
| `ElliotKit/Sources/ElliotModel/SkillRun.swift` | `SkillRun.resumedFrom: UUID?`, documented word for word, threaded through the memberwise init and the `card` factory. |
| `ElliotKit/Sources/ElliotStore/Migrations.swift` | `v9_runResumedFrom`: one additive `ALTER TABLE "skillRun" ADD COLUMN "resumedFrom"`. |
| `ElliotKit/Sources/ElliotEngine/Verifier.swift` | `verify` gains `cardRuns:` and `resume:` with **no defaults**; `verifyCreateIssue`'s `since` becomes the chain's first attempt; `noIssueReason` keeps a turn-less run's prose out of `.noIssueCreated`. |
| `ElliotKit/Sources/ElliotEngine/RunScheduler.swift` | `start` builds the invocation from `run.cwd` and `run.resumedFrom`; `finish` computes the verdict; `completeCardRun` takes it and passes it on with the card's runs. |
| `ElliotKit/Sources/ElliotEngine/Reconciler.swift` | Passes the card's runs and an asked-for (never asserted) verdict. |
| `ElliotKit/Tests/ElliotProcessTests/ClaudeRunnerTests.swift` | Two tests in `ClaudeInvocationTests`: the exact resumed argv, and the inseparability of the three tokens. |
| `ElliotKit/Tests/ElliotStoreTests/MigrationsTests.swift` | A pre-v9 database read by a helper one version behind, then upgraded, then written. |
| `ElliotKit/Tests/ElliotEngineTests/EndToEndTests.swift` | Two tests through the real stack: the fork tokens and the first attempt's cwd reach argv; a lost session is not recorded as a duplicate skip. |

---

### Task 1: `ClaudeInvocation.resumeFrom` and the inseparable token block

**Files:**
- Modify: `ElliotKit/Sources/ElliotProcess/ClaudeRunner.swift:5-70`
- Test: `ElliotKit/Tests/ElliotProcessTests/ClaudeRunnerTests.swift:42-125`

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces:
  - `public var ClaudeInvocation.resumeFrom: UUID?` — settable after construction (`var invocation = …; invocation.resumeFrom = id`).
  - `ClaudeInvocation.init(runID: UUID, prompt: String, cwd: String, permissionMode: PermissionMode = .bypassPermissions, extraAllowedTools: [String] = [], includePartialMessages: Bool = false, maxBudgetUSD: Double? = nil, resumeFrom: UUID? = nil)` — `resumeFrom` is **appended last**, so every existing call site compiles unchanged.
  - `arguments() -> [String]` emits, when `resumeFrom` is non-nil and immediately after `"--add-dir", cwd`: `"--resume", resumeFrom.uuidString.lowercased(), "--fork-session"`.

> ⚠️ **Cross-plan: PR6 inserts at the same point in `arguments()`, and the order between them is
> arbitrated here.** PR6's Task 11 adds `ClaudeInvocation.extraDirectories: [String]`, emitted as
> one `"--add-dir", <path>` pair per entry "immediately after the `cwd` pair" — the same seam this
> task claims. **The arbitrated order is: the extra `--add-dir` pairs first, then the resume
> tokens.** Both plans' assertions hold under it — this task's whole-list `#expect` sets no extra
> directories, and PR6's sets no `resumeFrom` — so neither has to change, but a build that reversed
> the order would put `--add-dir` between `--resume` and `--fork-session` and the two tests would
> still pass, which is why the order is written down rather than left to whoever edits second.
> Whichever of PR3 and PR6 ships second is the one that has to put its `if let` **below** the
> other's, and to say in its pull request body that it did.

- [ ] **Step 1: Write the failing test**

Insert both tests into `ClaudeInvocationTests` in `ElliotKit/Tests/ElliotProcessTests/ClaudeRunnerTests.swift`, immediately after `argumentList()` (which ends at line 61) and before `sessionIDIsLowercased()`:

```swift
    @Test("A resumed run carries --resume, its session and --fork-session, in that order")
    func resumedArgumentList() {
        let runID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        let previous = UUID(uuidString: "DDDDDDDD-CCCC-BBBB-AAAA-999999999999")!
        var invocation = ClaudeInvocation(
            runID: runID,
            prompt: "/ai-migration-kit:implement-issue 47",
            cwd: "/Users/philippe/repo/gh-phmatray/Elliot"
        )
        invocation.resumeFrom = previous

        // The whole list, not a `contains`: where the block sits is part of the
        // contract. `--session-id` above stays authoritative because the fork
        // makes the CLI report back the id we passed, so `runID == sessionID`
        // survives and the run stays one row with one log.
        #expect(invocation.arguments() == [
            "-p", "/ai-migration-kit:implement-issue 47",
            "--output-format", "stream-json",
            "--verbose",
            "--permission-mode", "bypassPermissions",
            "--session-id", "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee",
            "--add-dir", "/Users/philippe/repo/gh-phmatray/Elliot",
            "--resume", "dddddddd-cccc-bbbb-aaaa-999999999999",
            "--fork-session",
        ])
    }

    /// The pairing is a property of the shape rather than of a caller
    /// remembering it. The CLI refuses `--session-id` alongside `--resume`
    /// unless `--fork-session` is there too — *"--session-id can only be used
    /// with --continue or --resume if --fork-session is also specified"* — and
    /// one `if let` makes that refusal one we can never meet.
    @Test("--resume is never expressible without --fork-session")
    func resumeTokensAreInseparable() throws {
        var invocation = ClaudeInvocation(runID: UUID(), prompt: "x", cwd: "/tmp")
        #expect(!invocation.arguments().contains("--resume"))
        #expect(!invocation.arguments().contains("--fork-session"))

        let previous = UUID()
        invocation.resumeFrom = previous
        let args = invocation.arguments()
        let index = try #require(args.firstIndex(of: "--resume"))
        // A bounded slice rather than two indexed reads: an implementation that
        // emitted `--resume` *without* `--fork-session` — the one thing this
        // test exists to forbid — would make `args[index + 2]` trap with
        // `Fatal error: Index out of range` and take the whole test process down
        // instead of failing here. `prefix(3)` returns what is actually there.
        #expect(Array(args.dropFirst(index).prefix(3)) == [
            "--resume", previous.uuidString.lowercased(), "--fork-session",
        ])
        #expect(args.filter { $0 == "--fork-session" }.count == 1)
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd ElliotKit && swift test --filter ClaudeInvocationTests`

Expected: FAIL to **compile**, with `error: value of type 'ClaudeInvocation' has no member 'resumeFrom'` at both new tests. A compile failure is the expected shape here: the property does not exist yet.

- [ ] **Step 3: Write minimal implementation**

In `ElliotKit/Sources/ElliotProcess/ClaudeRunner.swift`, add the stored property after `maxBudgetUSD` (line 15):

```swift
    /// `nil` means no ceiling — the behaviour before #57, and the default.
    public var maxBudgetUSD: Double?
    /// The session to fork from. `nil` is a fresh conversation.
    ///
    /// Last in the initialiser rather than beside `cwd`, so every existing call
    /// site keeps compiling: the two are read together — Claude Code keeps a
    /// transcript under a slug of the directory the session ran in — but the
    /// argument order is a compatibility question, not a semantic one.
    public var resumeFrom: UUID?
```

Append the parameter to the initialiser (after `maxBudgetUSD: Double? = nil` at line 24) and assign it (after line 32):

```swift
        maxBudgetUSD: Double? = nil,
        resumeFrom: UUID? = nil
    ) {
```

```swift
        self.maxBudgetUSD = maxBudgetUSD
        self.resumeFrom = resumeFrom
    }
```

In `arguments()`, insert the block immediately after the `var args = [ … ]` literal — its last element is `"--add-dir", cwd,` on line 54 and it closes with `]` on line 55 — and **before** the `extraAllowedTools` block that starts on line 56:

```swift
        // One `if let`, and that is the guarantee rather than a test: a bare
        // `--resume` without `--fork-session` is not expressible here, so the
        // CLI's refusal — "--session-id can only be used with --continue or
        // --resume if --fork-session is also specified" — is one we never meet.
        //
        // The fork is also what keeps `--session-id` above authoritative:
        // measured on 2026-08-08 with these flags, the forked run's `result`
        // reports the id we passed, so `runID == sessionID` survives,
        // `StoreLocation.runLogURL(runID:)` is unchanged and the run stays one
        // row.
        if let resumeFrom {
            args += ["--resume", resumeFrom.uuidString.lowercased(), "--fork-session"]
        }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd ElliotKit && swift test --filter ClaudeInvocationTests`

Expected: PASS — 9 tests, 0 failures (the 7 that existed plus the 2 added).

- [ ] **Step 5: Commit**

```bash
git rev-parse --abbrev-ref HEAD
git add ElliotKit/Sources/ElliotProcess/ClaudeRunner.swift \
        ElliotKit/Tests/ElliotProcessTests/ClaudeRunnerTests.swift
git commit -m "feat(process): fork a session with --resume, --fork-session and nothing in between"
```

---

### Task 2: `ResumeVerdict`, the pure five-conjunct predicate

**Files:**
- Create: `ElliotKit/Sources/ElliotModel/ResumeVerdict.swift`
- Test: `ElliotKit/Tests/ElliotModelTests/ResumeVerdictTests.swift`

**Interfaces:**
- Consumes: `RunResult` (`ElliotKit/Sources/ElliotModel/StreamEvent.swift:61-112`), which already decodes `subtype`, `isError`, `numTurns`, `sessionID` and `errors` (`StreamEvent.swift:186-206`). PR3 is the first consumer of `errors`.
- Produces:
  - `public enum ResumeVerdict: Sendable, Hashable { case sessionGone, ran }`
  - `public static func ResumeVerdict.of(resumedFrom: UUID?, result: RunResult?) -> ResumeVerdict`
  - `public static let ResumeVerdict.sessionGoneSubtype = "error_during_execution"`
  - `public static let ResumeVerdict.sessionGonePrefix = "No conversation found"`

- [ ] **Step 1: Write the failing test**

Create `ElliotKit/Tests/ElliotModelTests/ResumeVerdictTests.swift`:

```swift
import Foundation
import Testing

@testable import ElliotModel

private let lostSession = "5f1b2c3d-4e5f-6789-abcd-ef0123456789"

/// The terminal event a Claude Code run reports when the transcript it was
/// asked to fork is not there: it errors before the first turn.
private func sessionGoneResult(
    subtype: String = ResumeVerdict.sessionGoneSubtype,
    isError: Bool = true,
    numTurns: Int? = 0,
    errors: [String] = ["No conversation found with session ID: \(lostSession)"]
) -> RunResult {
    RunResult(
        subtype: subtype,
        isError: isError,
        text: "No conversation found with session ID: \(lostSession)",
        numTurns: numTurns,
        sessionID: lostSession,
        errors: errors
    )
}

@Suite("The resume verdict")
struct ResumeVerdictTests {

    /// Every conjunct is load-bearing, so every conjunct is dropped once. A
    /// predicate written on `numTurns` alone would call a credit failure, a
    /// max-turns stop and a local slash command "the session is gone" — and in
    /// PR4 each of those would spend a fresh relaunch on a run that will fail
    /// again for the same reason.
    @Test("Drop any one conjunct and the run counts as having run")
    func theFullPredicate() {
        let previous = UUID()
        #expect(ResumeVerdict.of(resumedFrom: previous, result: sessionGoneResult()) == .sessionGone)

        // A run that was never a resume cannot have lost a session.
        #expect(ResumeVerdict.of(resumedFrom: nil, result: sessionGoneResult()) == .ran)
        // No terminal result at all — an orphan, a crash — establishes nothing.
        #expect(ResumeVerdict.of(resumedFrom: previous, result: nil) == .ran)
        // Errored after doing work: a failure, not a missing transcript.
        #expect(ResumeVerdict.of(
            resumedFrom: previous, result: sessionGoneResult(numTurns: 3)) == .ran)
        // `num_turns` absent is not `num_turns: 0`.
        #expect(ResumeVerdict.of(
            resumedFrom: previous, result: sessionGoneResult(numTurns: nil)) == .ran)
        // Zero turns and no error is a local slash command, not a lost session.
        #expect(ResumeVerdict.of(
            resumedFrom: previous, result: sessionGoneResult(isError: false)) == .ran)
        // The same shape under another subtype is a different failure.
        #expect(ResumeVerdict.of(
            resumedFrom: previous, result: sessionGoneResult(subtype: "error_max_turns")) == .ran)
        // Zero turns, error, right subtype — and the CLI complaining about
        // something else entirely.
        #expect(ResumeVerdict.of(
            resumedFrom: previous,
            result: sessionGoneResult(errors: ["Credit balance is too low"])) == .ran)
        // Nothing said at all.
        #expect(ResumeVerdict.of(
            resumedFrom: previous, result: sessionGoneResult(errors: [])) == .ran)
    }

    @Test("The wording is matched by prefix, so the session id may follow it")
    func matchedByPrefix() {
        let previous = UUID()
        #expect(ResumeVerdict.of(
            resumedFrom: previous,
            result: sessionGoneResult(errors: ["No conversation found"])) == .sessionGone)
        // A prefix and not a substring: a sentence that merely quotes the CLI
        // is not the CLI refusing.
        #expect(ResumeVerdict.of(
            resumedFrom: previous,
            result: sessionGoneResult(errors: ["I saw: No conversation found"])) == .ran)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd ElliotKit && swift test --filter ResumeVerdictTests`

Expected: FAIL to compile, with `error: cannot find 'ResumeVerdict' in scope`.

- [ ] **Step 3: Write minimal implementation**

Create `ElliotKit/Sources/ElliotModel/ResumeVerdict.swift`:

```swift
import Foundation

/// What a forked run's terminal event says about the session it tried to
/// resume.
///
/// Two cases, and only two, because this answers one question: did the fork
/// find a conversation? **It decides nothing about what happens next.** Who
/// relaunches, how many times and under what bound belongs to `AutoDevPolicy`;
/// a refused fork costs nothing and returns instantly, so "relaunch, without
/// spending an attempt" written here would be an unbounded spin.
public enum ResumeVerdict: Sendable, Hashable {
    /// The transcript this run was pointed at is not there. Nothing was
    /// attempted, so the run's closing prose is about the CLI, not about the
    /// work.
    case sessionGone
    /// Everything else, including "we do not know". The safe answer: it costs
    /// a verification that would have happened anyway.
    case ran

    /// The CLI's own subtype for a run that failed before its first turn.
    public static let sessionGoneSubtype = "error_during_execution"
    /// The CLI's own wording. Matched as a prefix because the session id
    /// follows it.
    public static let sessionGonePrefix = "No conversation found"

    /// The full predicate, and deliberately not `numTurns` alone.
    ///
    /// Zero turns is the *shape* of several different failures — a credit
    /// balance, a max-turns ceiling, a local slash command that bypassed the
    /// model loop. Only the conjunction of all five names the one failure a
    /// relaunch can fix.
    public static func of(resumedFrom: UUID?, result: RunResult?) -> ResumeVerdict {
        guard resumedFrom != nil, let result else { return .ran }
        guard result.isError,
              result.numTurns == 0,
              result.subtype == Self.sessionGoneSubtype,
              result.errors.contains(where: { $0.hasPrefix(Self.sessionGonePrefix) })
        else { return .ran }
        return .sessionGone
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd ElliotKit && swift test --filter ResumeVerdictTests`

Expected: PASS — 2 tests, 0 failures.

- [ ] **Step 5: Commit**

```bash
git rev-parse --abbrev-ref HEAD
git add ElliotKit/Sources/ElliotModel/ResumeVerdict.swift \
        ElliotKit/Tests/ElliotModelTests/ResumeVerdictTests.swift
git commit -m "feat(model): say whether a fork found its session, on the whole predicate"
```

---

### Task 3: `SkillRun.resumedFrom` and migration v9

**Files:**
- Modify: `ElliotKit/Sources/ElliotModel/SkillRun.swift:47-133` (struct and memberwise init) and `:143-172` (the `card` factory)
- Modify: `ElliotKit/Sources/ElliotStore/Migrations.swift:138-155`
- Test: `ElliotKit/Tests/ElliotStoreTests/MigrationsTests.swift`

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces:
  - `public var SkillRun.resumedFrom: UUID?` — placed after `cwd` in the struct, in the memberwise init and in the `SkillRun.card(…)` factory, defaulted to `nil` in both initialisers. Call sites therefore read `…, cwd: "/tmp/repo", resumedFrom: previous.id, state: .queued, …`.
  - Migration identifier `"v9_runResumedFrom"`, adding TEXT column `resumedFrom` to table `skillRun`.
  - `SkillRun` is persisted through GRDB with `databaseUUIDEncodingStrategy(for:) -> .uppercaseString` (`ElliotKit/Sources/ElliotStore/Records.swift:43-57`), so the new column stores uppercase UUID text like every other id column. No change to `Records.swift` is needed.

⚠ **`SkillRun.analysis(…)` (`SkillRun.swift:177-206`) is deliberately left alone.** An analysis run has no predecessor; its body calls the memberwise init with labels and simply skips the new defaulted parameter.

⚠ **The migration number is a resource shared with PR2 and PR4**, which both also want v9. Whichever lands second renumbers and ships its `RenamedMigration` in the same diff (`Migrations.swift:195-202`) — GRDB identifies a migration by its **name**, so a machine that ran the losing branch replays it against a column that already exists.

> **Cross-plan, and this is what the arbitrated order actually implies.** The delivery order is
> PR1 → **PR2** → PR3/PR6 → PR5 → PR4, so PR2 registers `v9_cardAppraisal` **before** this branch
> lands. Expect to renumber, and expect it as the normal case rather than the exception:
>
> ```bash
> grep -n 'registerMigration("v' ElliotKit/Sources/ElliotStore/Migrations.swift | tail -3
> ```
>
> - last line is `v8_prStatus` → PR2 has not landed; `v9_runResumedFrom` stands as written below.
> - last line is `v9_cardAppraisal` → rename this migration to **`v10_runResumedFrom`** everywhere
>   in this task, and in the **same commit** append to `Migrations.renamedMigrations`
>   (`Migrations.swift:195-202`):
>
>   ```swift
>           RenamedMigration(legacy: "v9_runResumedFrom", current: "v10_runResumedFrom") { db in
>               db.columns(in: "skillRun").contains { $0.name == "resumedFrom" }
>           }
>   ```
>
> The third claimant, PR4 (`v9_autoDev` → **`v11_autoDev`** once both of these have landed), ships
> last and carries the same guidance in its own Task 5.

⚠ **PR3 and PR6 are totally ordered, and the order has to be stated in whichever ships second.** PR6 needs its appraisal run to carry a `cardID`, and the option it must *not* take is rebuilding `skillRun` to relax the `("cardID" IS NULL) <> ("analysisID" IS NULL)` CHECK: that rebuild is a hand-written `INSERT … SELECT` naming 22 columns one by one (`Migrations.swift:394-445`), and a 23rd column added here after that list was written is dropped from every existing row **silently** — the copy succeeds, the schema looks right, and only the values are gone. If PR3 lands first, PR6's body says in writing that it does not rebuild the table. If PR6 lands first having rebuilt it, this task's `ALTER TABLE` is renumbered above that migration and the rebuild's column list is left untouched. The witness the design asks for — a run seeded with `resumedFrom` non-nil *before* a rebuild, read back *after* — belongs to whichever pull request performs the rebuild, because there is none in this one. What PR3 owes is the half in Step 1 below: the column survives an upgrade over a row that predates it, and is writable afterwards.

- [ ] **Step 1: Write the failing test**

Append this test to `struct MigrationsTests` in `ElliotKit/Tests/ElliotStoreTests/MigrationsTests.swift` (after `v2LeavesV1DataIntact()`), and add `import TestSupport` to that file's imports:

```swift
    /// v9 adds a column to `skillRun`, and the two things that can go wrong
    /// with an added column are both checked here.
    ///
    /// The read-only half is the one worth having. `openReadOnly` deliberately
    /// accepts a database **older** than the build — `applied.isSubset(of:
    /// known)` — so the board is not blanked between upgrading the bundle and
    /// the next launch of the app. That tolerance holds for added *columns*,
    /// which read as absent, and not for added *tables*, which is exactly what
    /// `OlderDatabaseTests` records about v8. If the read-only assertion below
    /// ever throws `no such column`, that is a real finding about the window
    /// and belongs in the pull request body — it is not a reason to delete it.
    ///
    /// The read-only store is opened and released **before** the read-write
    /// one: two connections to the same file, one of which is about to migrate
    /// it, is a hazard this test has no reason to take.
    @Test("A run written before v9 reads back with no predecessor, in both open modes")
    func v9LeavesEarlierRunsIntact() async throws {
        // `StoreLocation` is process-global and `BoardStore.open` resolves it;
        // `TestHome` is the only thing in the test process allowed to set it.
        _ = TestHome.root

        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("elliot-v8-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }

        let repoID = UUID()
        let cardID = UUID()
        let runID = UUID()

        // Only as far as the release before this feature, then seed through raw
        // SQL — the record type knows about a column this file must not have.
        do {
            let queue = try DatabaseQueue(path: url.path)
            try Migrations.migrator.migrate(queue, upTo: "v8_prStatus")
            try queue.write { db in
                try db.execute(
                    sql: """
                        INSERT INTO "repo" ("id", "path", "nameWithOwner", "defaultBranch",
                            "displayName", "permissionMode", "extraAllowedTools", "isEnabled")
                        VALUES (?, '/tmp/v8', 'phmatray/Elliot', 'main', 'Elliot',
                            'bypassPermissions', '[]', 1)
                        """,
                    arguments: [repoID.uuidString.uppercased()])
                try db.execute(
                    sql: """
                        INSERT INTO "card" ("id", "repoID", "title", "body", "column",
                            "orderIndex", "columnEnteredAt", "createdAt", "updatedAt")
                        VALUES (?, ?, 'Written before v9', '', 'todo', 1024,
                            '2026-08-07 10:00:00.000', '2026-08-07 10:00:00.000',
                            '2026-08-07 10:00:00.000')
                        """,
                    arguments: [cardID.uuidString.uppercased(), repoID.uuidString.uppercased()])
                try db.execute(
                    sql: """
                        INSERT INTO "skillRun" ("id", "cardID", "repoID", "kind", "prompt",
                            "argv", "cwd", "state", "logPath", "stderrPath",
                            "permissionDenials", "createdAt")
                        VALUES (?, ?, ?, 'createIssue', '/create-issue', '[]', '/tmp/v8',
                            'succeeded', '/tmp/run.ndjson', '/tmp/run.log', '[]',
                            '2026-08-07 10:00:00.000')
                        """,
                    arguments: [
                        runID.uuidString.uppercased(),
                        cardID.uuidString.uppercased(),
                        repoID.uuidString.uppercased(),
                    ])
            }
            try queue.close()
        }

        // The column is genuinely absent, or this upgrades a database that was
        // already current and measures nothing.
        do {
            let check = try DatabaseQueue(path: url.path)
            let columns = try check.read { db in try db.columns(in: "skillRun").map(\.name) }
            #expect(
                !columns.contains("resumedFrom"),
                "the fixture is not actually a pre-v9 database")
            try check.close()
        }

        // A helper one version behind the app, reading the same file.
        do {
            let older = try BoardStore.openReadOnly(at: url)
            #expect(try await older.run(id: runID)?.resumedFrom == nil)
        }

        // The upgrade itself, over a row that was already there.
        let upgraded = try BoardStore.open(at: url)
        let migrated = try #require(try await upgraded.run(id: runID))
        #expect(
            migrated.resumedFrom == nil,
            "the added column reads as absent, not as a default")

        // And the column is live afterwards, not merely created.
        var resumed = migrated
        resumed.id = UUID()
        resumed.resumedFrom = runID
        try await upgraded.saveRun(resumed)
        #expect(try await upgraded.run(id: resumed.id)?.resumedFrom == runID)
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd ElliotKit && swift test --filter MigrationsTests`

Expected: FAIL to compile, with `error: value of type 'SkillRun' has no member 'resumedFrom'` — **four** sites in the new test: `older.run(id: runID)?.resumedFrom`, `migrated.resumedFrom`, `resumed.resumedFrom = runID`, and `upgraded.run(id: resumed.id)?.resumedFrom`.

- [ ] **Step 3: Write minimal implementation**

In `ElliotKit/Sources/ElliotModel/SkillRun.swift`, add the property after `cwd` (line 66):

```swift
    public var cwd: String
    /// The last attempt that actually created a session.
    ///
    /// Unchanged when the predecessor was refused, advanced when it ran.
    /// Anything vaguer makes the chain unreadable after two failures: if a
    /// refused fork moved this pointer, the second failure would name a session
    /// that never existed and the window a resumed run is verified over would
    /// have no first attempt to anchor on.
    ///
    /// Next to `cwd` because the two are read together — Claude Code keeps a
    /// session's transcript under a slug of the directory it ran in, so a fork
    /// launched from anywhere else finds nothing.
    public var resumedFrom: UUID?
    public var state: RunState
```

Add the initialiser parameter between `cwd: String` (line 95) and `state: RunState = .queued` (line 96), and the assignment between `self.cwd = cwd` and `self.state = state`:

```swift
        cwd: String,
        resumedFrom: UUID? = nil,
        state: RunState = .queued,
```

```swift
        self.cwd = cwd
        self.resumedFrom = resumedFrom
        self.state = state
```

Do the same in the `card` factory (`:143-172`): add `resumedFrom: UUID? = nil,` between its `cwd: String,` and `state: RunState = .queued,` parameters, and forward it in the body's call — the forwarded call becomes:

```swift
        SkillRun(
            id: id, cardID: cardID, repoID: repoID, analysisID: nil, analysisAngle: nil,
            kind: kind, prompt: prompt, argv: argv, cwd: cwd, resumedFrom: resumedFrom,
            state: state,
            startedAt: startedAt, endedAt: endedAt, exitCode: exitCode,
            logPath: logPath, stderrPath: stderrPath, resultText: resultText,
            totalCostUSD: totalCostUSD, numTurns: numTurns, permissionDenials: permissionDenials,
            verifiedOutcome: verifiedOutcome, analysisReport: nil, createdAt: createdAt
        )
```

In `ElliotKit/Sources/ElliotStore/Migrations.swift`, register v9 immediately after the `v8_prStatus` block (which closes at line 153) and before `return migrator` (line 155):

```swift
        // v9, additive: which attempt this run forked its session from.
        //
        // A column and not a table, so a helper one version behind still reads
        // the row — `openReadOnly` accepts a database older than the build, and
        // an absent column decodes as nil where an absent table throws.
        //
        // ⚠ v9 is a number three pull requests want at once: PR2 (columns on
        // `card`), this one, and PR4 (the session tables). Whichever lands
        // second renumbers **and ships its `RenamedMigration` in the same
        // diff** — GRDB identifies a migration by its name, so a machine that
        // ran the losing branch replays it over a column that already exists.
        // Auto-dev is developed by running unmerged branches on the owner's
        // machine, so that escape is the normal case here, not the exception.
        //
        // No backfill: nothing before this build ever forked a session, so nil
        // is the truth rather than a default.
        migrator.registerMigration("v9_runResumedFrom") { db in
            try db.alter(table: "skillRun") { t in
                t.add(column: "resumedFrom", .text)
            }
        }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd ElliotKit && swift test --filter MigrationsTests`

Expected: PASS — 2 tests, 0 failures.

Then confirm nothing else broke on the schema: `cd ElliotKit && swift test --filter SchemaUpgradeTests` — PASS, **12 tests** on `main` today (counted in the tree: twelve `@Test` inside `struct SchemaUpgradeTests`, `SchemaUpgradeTests.swift:159-515`; the three in `BoardPagingTests` below it are a different type and this filter does not name them). ⚠ PR2 adds two `@Test`s to that same suite, so read the count you get rather than this one, and never the exit code — a filter that matches nothing also exits 0. In particular `renamesPointAtRegisteredMigrations` must stay green, and **`rewindToV1` must not be touched by this task at all**: this migration alters `skillRun`, not `card`, and v4, v6 and v8 are absent from that `IN` clause for the same reason.

⚠️ **Cross-plan: do not read `rewindToV1`'s `precondition` as a constant.** It is
`precondition(db.changesCount == 4)` (`SchemaUpgradeTests.swift:97-100`) on `main`, and **PR2's
Task 3 raises it to 5** when it teaches `rewindToV1` to drop the three `card` columns. So after PR2
— which the delivery order puts before this branch — the correct reading is *"whatever number is
there, leave it alone"*, not *"it says 4"*. A branch that "restores" it to 4 breaks every upgrade
test in the file.

- [ ] **Step 5: Commit**

```bash
git rev-parse --abbrev-ref HEAD
git add ElliotKit/Sources/ElliotModel/SkillRun.swift \
        ElliotKit/Sources/ElliotStore/Migrations.swift \
        ElliotKit/Tests/ElliotStoreTests/MigrationsTests.swift
git commit -m "feat(model,store): record the attempt a run forked its session from"
```

---

### Task 4: `ResumeChain.firstAttemptStart`

**Files:**
- Create: `ElliotKit/Sources/ElliotModel/ResumeChain.swift`
- Test: `ElliotKit/Tests/ElliotModelTests/ResumeChainTests.swift`

**Interfaces:**
- Consumes: `SkillRun.resumedFrom`, `SkillRun.startedAt`, `SkillRun.createdAt` and the `SkillRun.card(…)` factory from Task 3.
- Produces: `public static func ResumeChain.firstAttemptStart(of run: SkillRun, among runs: [SkillRun]) -> Date` — pure, total, cycle-guarded. `runs` is any collection that may contain the chain; a predecessor missing from it stops the walk there.

- [ ] **Step 1: Write the failing test**

Create `ElliotKit/Tests/ElliotModelTests/ResumeChainTests.swift`:

```swift
import Foundation
import Testing

@testable import ElliotModel

private let then = Date(timeIntervalSince1970: 1_700_000_000)
private let aCard = UUID()
private let aRepo = UUID()

private func attempt(
    startedAt: Date?, createdAt: Date, resumedFrom: UUID? = nil
) -> SkillRun {
    SkillRun.card(
        cardID: aCard, repoID: aRepo, kind: .createIssue,
        prompt: "/ai-migration-kit:create-issue x", cwd: "/tmp/repo",
        resumedFrom: resumedFrom,
        startedAt: startedAt,
        logPath: "/tmp/log.ndjson", stderrPath: "/tmp/log.stderr.log",
        createdAt: createdAt
    )
}

@Suite("The start of a resume chain")
struct ResumeChainTests {

    @Test("A run that resumed nothing answers its own start")
    func aFreshRun() {
        let run = attempt(startedAt: then, createdAt: then.addingTimeInterval(-5))
        #expect(ResumeChain.firstAttemptStart(of: run, among: [run]) == then)
    }

    @Test("A run that never started falls back to when it was created")
    func neverStarted() {
        let run = attempt(startedAt: nil, createdAt: then)
        #expect(ResumeChain.firstAttemptStart(of: run, among: [run]) == then)
    }

    @Test("A chain of three answers the first attempt, not the last")
    func theWholeChain() {
        let first = attempt(startedAt: then, createdAt: then)
        let second = attempt(
            startedAt: then.addingTimeInterval(600),
            createdAt: then.addingTimeInterval(600),
            resumedFrom: first.id)
        let third = attempt(
            startedAt: then.addingTimeInterval(1_200),
            createdAt: then.addingTimeInterval(1_200),
            resumedFrom: second.id)
        #expect(ResumeChain.firstAttemptStart(of: third, among: [third, second, first]) == then)
    }

    /// The store answers a page, so a chain longer than the page loses its
    /// oldest rows. The walk stops at the oldest attempt it can see, which makes
    /// the window *later* than the truth — and later is the direction that files
    /// a second issue, so this is a case to know about rather than to hide.
    @Test("A predecessor that is not in the page stops the walk there")
    func aTruncatedPage() {
        let first = attempt(startedAt: then, createdAt: then)
        let second = attempt(
            startedAt: then.addingTimeInterval(600),
            createdAt: then.addingTimeInterval(600),
            resumedFrom: first.id)
        #expect(
            ResumeChain.firstAttemptStart(of: second, among: [second])
                == then.addingTimeInterval(600))
    }

    /// `resumedFrom` is persisted, so it can be anything a restore or a hand
    /// edit leaves behind. A cycle must terminate rather than spin the verifier.
    @Test("A cycle terminates instead of spinning")
    func aCycle() {
        var newer = attempt(
            startedAt: then.addingTimeInterval(600), createdAt: then.addingTimeInterval(600))
        var older = attempt(startedAt: then, createdAt: then)
        newer.resumedFrom = older.id
        older.resumedFrom = newer.id
        #expect(ResumeChain.firstAttemptStart(of: newer, among: [newer, older]) == then)

        var selfReferential = attempt(startedAt: then, createdAt: then)
        selfReferential.resumedFrom = selfReferential.id
        #expect(
            ResumeChain.firstAttemptStart(of: selfReferential, among: [selfReferential]) == then)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd ElliotKit && swift test --filter ResumeChainTests`

Expected: FAIL to compile, with `error: cannot find 'ResumeChain' in scope`.

- [ ] **Step 3: Write minimal implementation**

Create `ElliotKit/Sources/ElliotModel/ResumeChain.swift`:

```swift
import Foundation

/// Walking a run back to the attempt its chain started with.
///
/// Pure: no store, no clock, no I/O. The caller supplies whatever rows it has
/// and this reads `resumedFrom` backwards through them.
public enum ResumeChain {

    /// When the first attempt of `run`'s chain began.
    ///
    /// This is the window every `gh` question about a resumed run has to be
    /// asked over. A resumed run's own `startedAt` is when the *resume* began,
    /// so anything the first attempt did falls outside it — and for
    /// `create-issue` that means the verifier reports nothing created and an
    /// unattended loop files a second issue on github.com. The principle is
    /// already written three files away: *"recency must never be a filter"*
    /// (`PRMatcher.swift:26`).
    ///
    /// `run` is passed separately from `runs` on purpose: the caller usually
    /// holds a fresher copy than the store does, and the walk must start from
    /// the copy that carries this attempt's `resumedFrom`.
    ///
    /// Total. A predecessor absent from `runs` — a page shorter than the chain
    /// — stops the walk, and a cycle is refused by `seen` rather than followed.
    public static func firstAttemptStart(of run: SkillRun, among runs: [SkillRun]) -> Date {
        let byID = Dictionary(runs.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var oldest = run
        var seen: Set<UUID> = [run.id]
        while let previousID = oldest.resumedFrom,
              !seen.contains(previousID),
              let previous = byID[previousID] {
            seen.insert(previousID)
            oldest = previous
        }
        return oldest.startedAt ?? oldest.createdAt
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd ElliotKit && swift test --filter ResumeChainTests`

Expected: PASS — 5 tests, 0 failures.

- [ ] **Step 5: Commit**

```bash
git rev-parse --abbrev-ref HEAD
git add ElliotKit/Sources/ElliotModel/ResumeChain.swift \
        ElliotKit/Tests/ElliotModelTests/ResumeChainTests.swift
git commit -m "feat(model): anchor a resumed run's window on its first attempt"
```

---

### Task 5: The blocking fix — `verifyCreateIssue`'s window, and the verdict reaching it

**Files:**
- Modify: `ElliotKit/Sources/ElliotEngine/Verifier.swift:17-34` (the `verify` entry), `:38-71` (`verifyCreateIssue`)
- Modify: `ElliotKit/Sources/ElliotEngine/RunScheduler.swift:417-453` (`finish`), `:456-468` (`completeCardRun`)
- Modify: `ElliotKit/Sources/ElliotEngine/Reconciler.swift:65-71`
- Test: `ElliotKit/Tests/ElliotEngineTests/ResumeVerificationTests.swift`

**Interfaces:**
- Consumes: `ResumeVerdict.of(resumedFrom:result:)` (Task 2), `ResumeChain.firstAttemptStart(of:among:)` (Task 4), `SkillRun.resumedFrom` and the `SkillRun.card(…)` factory's `resumedFrom:` parameter (Task 3).
- Produces:
  - `public func Verifier.verify(run: SkillRun, card: Card, repo: Repo, cardRuns: [SkillRun], resume: ResumeVerdict) async -> VerifiedOutcome` — **no default values on the two new parameters**. The template is `MoveContext.providedFollowUps`: a default would let a call site inherit the old, wrong window in silence, which is the exact defect being fixed.
  - `static func Verifier.noIssueReason(run: SkillRun, resume: ResumeVerdict) -> String` (internal, reachable from `@testable import ElliotEngine`), returning `"The conversation this run tried to resume no longer exists, so nothing ran."` for `.sessionGone`.
  - `RunScheduler.completeCardRun(_ run: inout SkillRun, resume: ResumeVerdict) async -> VerifiedOutcome?` (private).

⚠ **The verdict is passed to the verification, never used to skip it.** A run that could not resume may still have left an issue or a pull request behind on an earlier attempt, and the only thing that knows is `gh`.

- [ ] **Step 1: Write the failing test**

Create `ElliotKit/Tests/ElliotEngineTests/ResumeVerificationTests.swift`:

```swift
import ElliotModel
import ElliotProcess
import Foundation
import Testing

@testable import ElliotEngine

/// Duplicated rather than shared with the two end-to-end files: a private enum
/// in one test file is not visible from another, and one small repetition beats
/// a shared helper target for one constant.
private enum TestPaths {
    static let repoRoot: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // ElliotEngineTests
        .deletingLastPathComponent()   // Tests
        .deletingLastPathComponent()   // ElliotKit
        .deletingLastPathComponent()   // repo root

    static let fakeGH = repoRoot.appendingPathComponent("Scripts/fake-gh.sh").path
}

private let elliot = Repo(
    path: "/tmp/elliot-resume-window", nameWithOwner: "phmatray/Elliot", displayName: "Elliot"
)

/// A `gh issue list` payload with one issue, created `ago` seconds before now.
///
/// Written per test rather than checked in: the window under test is measured
/// against the clock, so a frozen date would make the result depend on the
/// calendar instead of on the code.
private func issuesFixture(
    title: String, number: Int, ago: TimeInterval, at directory: URL
) throws -> String {
    let created = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-ago))
    let json = """
        [
          {
            "number": \(number),
            "title": "\(title)",
            "url": "https://github.com/phmatray/Elliot/issues/\(number)",
            "state": "OPEN",
            "createdAt": "\(created)",
            "body": "Filed by the first attempt."
          }
        ]
        """
    let path = directory.appendingPathComponent("issues.json")
    try json.write(to: path, atomically: true, encoding: .utf8)
    return path.path
}

/// A real `Verifier` over a real subprocess. An empty `issues` path makes the
/// fake print `[]`, which is what `gh` returns for a repository with nothing
/// matching.
private func verifier(issues: String) -> Verifier {
    Verifier(gh: GHClient(config: ToolConfig(
        claudePath: "/usr/bin/false",
        ghPath: TestPaths.fakeGH,
        gitPath: "/usr/bin/false",
        environment: [
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "FAKE_GH_ISSUES": issues,
        ]
    )))
}

/// One card and a two-link chain: a first attempt that started 40 minutes ago
/// and failed, and the resume that started now.
///
/// The resumed run's `logPath` names no file on purpose. `verifyCreateIssue`
/// reads issue URLs out of the log first and confirms each with `gh issue
/// view`; with no log there are no candidates, and the title sweep — the path
/// the window actually guards — is the one under test.
private func chain(
    title: String, scratch: URL, resumedResultText: String? = nil
) -> (card: Card, first: SkillRun, resumed: SkillRun) {
    let now = Date()
    let card = Card(
        repoID: elliot.id, title: title,
        columnEnteredAt: now, createdAt: now, updatedAt: now
    )
    let first = SkillRun.card(
        cardID: card.id, repoID: elliot.id, kind: .createIssue,
        prompt: "/ai-migration-kit:create-issue \(title)", cwd: elliot.path,
        state: .failed,
        startedAt: now.addingTimeInterval(-2_400),
        endedAt: now.addingTimeInterval(-2_300),
        logPath: scratch.appendingPathComponent("first.ndjson").path,
        stderrPath: scratch.appendingPathComponent("first.log").path,
        createdAt: now.addingTimeInterval(-2_400)
    )
    let resumed = SkillRun.card(
        cardID: card.id, repoID: elliot.id, kind: .createIssue,
        prompt: "/ai-migration-kit:create-issue \(title)", cwd: elliot.path,
        resumedFrom: first.id,
        state: .failed,
        startedAt: now,
        logPath: scratch.appendingPathComponent("no-such-log.ndjson").path,
        stderrPath: scratch.appendingPathComponent("no-such-log.log").path,
        resultText: resumedResultText,
        createdAt: now
    )
    return (card, first, resumed)
}

private func makeScratch() throws -> URL {
    let url = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("elliot-resume-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

@Suite("The create-issue window of a resumed run")
struct ResumeVerificationTests {

    /// The defect PR3 must not ship without fixing, stated as its consequence:
    /// a resumed run whose first attempt already filed the issue has to come
    /// back `.issueCreated`, because `.noIssueCreated` is precisely what makes
    /// an unattended loop file a second one on github.com.
    @Test("An issue filed by the first attempt is still found after a resume")
    func firstAttemptsIssueIsInsideTheWindow() async throws {
        let scratch = try makeScratch()
        defer { try? FileManager.default.removeItem(at: scratch) }

        let title = "Stream the run log inside the card"
        let issues = try issuesFixture(title: title, number: 4242, ago: 1_800, at: scratch)
        let (card, first, resumed) = chain(title: title, scratch: scratch)

        let outcome = await verifier(issues: issues).verify(
            run: resumed, card: card, repo: elliot,
            cardRuns: [resumed, first], resume: .ran
        )
        #expect(outcome == .issueCreated(
            number: 4242, url: "https://github.com/phmatray/Elliot/issues/4242"))
    }

    /// The control that makes the test above mean something: the same run and
    /// the same issue, with the chain unavailable, falls outside the window and
    /// reports nothing created. That is what every resumed run did before this
    /// change, and it is what files the second issue.
    @Test("Without the chain, the very same issue falls outside the window")
    func withoutTheChainTheIssueIsMissed() async throws {
        let scratch = try makeScratch()
        defer { try? FileManager.default.removeItem(at: scratch) }

        let title = "Stream the run log inside the card"
        let issues = try issuesFixture(title: title, number: 4242, ago: 1_800, at: scratch)
        let (card, _, resumed) = chain(title: title, scratch: scratch)

        let outcome = await verifier(issues: issues).verify(
            run: resumed, card: card, repo: elliot, cardRuns: [], resume: .ran
        )
        #expect(outcome == .noIssueCreated(
            reason: "No issue was created. It may already be covered by an existing one."))
    }

    /// A run that could not resume never had a turn, so its closing prose is the
    /// CLI complaining about a missing transcript — not a report about the idea.
    /// Put that prose in `.noIssueCreated(reason:)` and the card says the idea
    /// was already covered, which is the one sentence an unattended loop reads
    /// as "nothing to do here".
    @Test("A run that could not resume does not say the idea was already covered")
    func sessionGoneDoesNotBorrowTheAgentsProse() async throws {
        let scratch = try makeScratch()
        defer { try? FileManager.default.removeItem(at: scratch) }

        let title = "Stream the run log inside the card"
        let (card, first, resumed) = chain(
            title: title, scratch: scratch,
            resumedResultText: "No conversation found with session ID: 5f1b2c3d-4e5f"
        )

        // No fixture, so `gh` answers `[]` and the sweep finds nothing: the
        // reason is all that is left to say.
        let outcome = await verifier(issues: "").verify(
            run: resumed, card: card, repo: elliot,
            cardRuns: [resumed, first], resume: .sessionGone
        )
        #expect(outcome == .noIssueCreated(
            reason: "The conversation this run tried to resume no longer exists, so nothing ran."))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd ElliotKit && swift test --filter ResumeVerificationTests`

Expected: FAIL to compile, with `error: extra arguments at positions #4, #5 in call` on each `verify(…)` call.

- [ ] **Step 3: Write minimal implementation**

**`ElliotKit/Sources/ElliotEngine/Verifier.swift`** — replace the `verify` entry point (lines 17-34) with:

```swift
    /// `cardRuns` and `resume` carry **no default values**, deliberately.
    ///
    /// The memberwise convenience of a default is exactly what would let the
    /// next call site inherit the old window in silence — and the old window is
    /// the defect this signature exists to close. Without defaults, every caller
    /// has to state what it knows, and a new one cannot be written by accident.
    ///
    /// - Parameters:
    ///   - cardRuns: every run of this card, so the create-issue window can be
    ///     anchored on the first attempt of a resume chain. Order is irrelevant.
    ///   - resume: what the run's terminal event said about the session it tried
    ///     to fork. Passed *to* the verification, never used to skip it.
    public func verify(
        run: SkillRun,
        card: Card,
        repo: Repo,
        cardRuns: [SkillRun],
        resume: ResumeVerdict
    ) async -> VerifiedOutcome {
        do {
            switch run.kind {
            case .createIssue:
                return try await verifyCreateIssue(
                    run: run, card: card, repo: repo, cardRuns: cardRuns, resume: resume)
            case .implementIssue:
                return try await verifyImplementIssue(run: run, card: card, repo: repo)
            case .mergePR:
                return try await verifyMergePR(run: run, card: card, repo: repo)
            case .analyzeRepo:
                // Unreachable: analysis runs are completed by ProposalHarvester,
                // and there is nothing on GitHub to check an opinion against.
                return .unverified(reason: "An analysis has no GitHub outcome to verify.")
            }
        } catch {
            return .unverified(reason: error.localizedDescription)
        }
    }
```

Replace `verifyCreateIssue`'s signature and its `since` line (lines 38-39) with:

```swift
    private func verifyCreateIssue(
        run: SkillRun, card: Card, repo: Repo, cardRuns: [SkillRun], resume: ResumeVerdict
    ) async throws -> VerifiedOutcome {
        // The window opens at the **first** attempt of this run's resume chain,
        // not at this attempt's own start. A resumed run's `startedAt` is when
        // the resume began, so an issue the first attempt filed falls outside a
        // window anchored on it: the verifier reports nothing created, and with
        // nobody watching the loop files a second issue on github.com. The
        // principle is already written three files away — *"recency must never
        // be a filter"* (`PRMatcher.swift:26`).
        let since = ResumeChain.firstAttemptStart(of: run, among: cardRuns)
```

Replace the closing `return` (lines 66-70) with:

```swift
        // Nothing new. With a zero exit this is the duplicate-skip path, which
        // is a real success: the idea was already covered by an open issue.
        return .noIssueCreated(reason: Self.noIssueReason(run: run, resume: resume))
    }

    /// Why no issue was created, in terms the reader can act on.
    ///
    /// `.sessionGone` is the case this exists for. Such a run never had a turn,
    /// so `resultText` is the CLI's complaint about a missing transcript;
    /// putting it here would tell the reader — and an unattended loop — that the
    /// idea was already covered. Two different facts must not share a sentence.
    static func noIssueReason(run: SkillRun, resume: ResumeVerdict) -> String {
        switch resume {
        case .sessionGone:
            return "The conversation this run tried to resume no longer exists, so nothing ran."
        case .ran:
            guard let text = run.resultText, !text.isEmpty else {
                return "No issue was created. It may already be covered by an existing one."
            }
            return String(text.prefix(400))
        }
    }
```

**`ElliotKit/Sources/ElliotEngine/RunScheduler.swift`** — in `finish`, insert after `updated.state = Self.state(for: outcome)` (line 432) and before the `var verified: VerifiedOutcome?` block:

```swift
        // Computed here because this is the only place the terminal result
        // exists: `numTurns` and `errors` live on `outcome.result`, and by the
        // time anything downstream sees the row they are gone.
        //
        // Passed **to** `completeCardRun` rather than used to skip it. A run
        // that could not resume may still have left an issue or a pull request
        // behind on an earlier attempt, and the only thing that knows is `gh`.
        let resume = ResumeVerdict.of(resumedFrom: updated.resumedFrom, result: outcome?.result)
```

and change the one call:

```swift
            verified = await completeCardRun(&updated, resume: resume)
```

Replace `completeCardRun` **together with the doc comment above it** — lines 455-468, where 455 is `/// Verify against `gh`, then write what it said onto the card.` — with:

```swift
    /// Verify against `gh`, then write what it said onto the card.
    private func completeCardRun(
        _ run: inout SkillRun, resume: ResumeVerdict
    ) async -> VerifiedOutcome? {
        guard let cardID = run.cardID,
              let card = try? await store.card(id: cardID),
              let repo = try? await store.repo(id: run.repoID)
        else { return nil }

        // Every run of this card, so the verifier can walk `resumedFrom` back to
        // the attempt the chain started with. This is a page — newest first,
        // capped at the store's default — which bounds the walk: a chain longer
        // than the page stops at the oldest row it can see.
        let cardRuns = (try? await store.runs(cardID: cardID)) ?? []

        // Verify even a cancelled run: implement-issue may well have opened the
        // pull request before it was stopped, and both skills are resume-safe.
        let verified = await verifier.verify(
            run: run, card: card, repo: repo, cardRuns: cardRuns, resume: resume)
        run.verifiedOutcome = verified
        await apply(verified, to: card)
        return verified
    }
```

**`ElliotKit/Sources/ElliotEngine/Reconciler.swift`** — replace lines 65-71 with:

```swift
                } else if let cardID = run.cardID,
                          let card = try? await store.card(id: cardID),
                          let repo = try? await store.repo(id: run.repoID) {
                    let cardRuns = (try? await store.runs(cardID: cardID)) ?? []
                    let outcome = await verifier.verify(
                        run: orphan, card: card, repo: repo, cardRuns: cardRuns,
                        // An orphan has no terminal result at all — the app died
                        // before one arrived — so nothing establishes that its
                        // session was gone. Asked rather than asserted, so this
                        // stays right if the verdict ever gains a case.
                        resume: ResumeVerdict.of(resumedFrom: orphan.resumedFrom, result: nil)
                    )
                    orphan.verifiedOutcome = outcome
                    if await apply(outcome, to: card) { summary.cardsCorrected += 1 }
                }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd ElliotKit && swift test --filter ResumeVerificationTests`

Expected: PASS — 3 tests, 0 failures.

Then the two suites that exercise the changed call sites:
`cd ElliotKit && swift test --filter EndToEndTests` — PASS, and
`cd ElliotKit && swift test --filter BoardServiceTests` — PASS.

- [ ] **Step 5: Commit**

```bash
git rev-parse --abbrev-ref HEAD
git add ElliotKit/Sources/ElliotEngine/Verifier.swift \
        ElliotKit/Sources/ElliotEngine/RunScheduler.swift \
        ElliotKit/Sources/ElliotEngine/Reconciler.swift \
        ElliotKit/Tests/ElliotEngineTests/ResumeVerificationTests.swift
git commit -m "fix(engine): verify a resumed run over its first attempt's window"
```

---

### Task 6: `RunScheduler.start` spawns from the run's own cwd, and forks its predecessor

**Files:**
- Modify: `ElliotKit/Sources/ElliotEngine/RunScheduler.swift:333-347`
- Test: `ElliotKit/Tests/ElliotEngineTests/EndToEndTests.swift` (a `@Test` inside `struct EndToEndTests`)

**Interfaces:**
- Consumes: `ClaudeInvocation.init(…, resumeFrom:)` (Task 1), `SkillRun.resumedFrom` and the `card` factory's `resumedFrom:` parameter (Task 3).
- Produces: nothing new in the public API. The behavioural contract is that `SkillRun.argv` — which `start` persists as `[toolConfig.claudePath] + invocation.arguments()` (`RunScheduler.swift:348`) — now reads `… "--add-dir", run.cwd, "--resume", <predecessor id lowercased>, "--fork-session" …` for a run that carries `resumedFrom`.

⚠ `run.cwd` and `repo.path` are the **same value for every run created today** (`BoardService.swift:178`, `AnalysisService.swift:111`), so this change is behaviour-preserving right now. It is load-bearing for a resumed run: Claude Code keeps a session's transcript under a slug of the cwd of the first attempt, and two sources for one fact make the fork fail with `No conversation found` — silently, and looking exactly like an expired session.

⚠ `treeBaselines[run.id] = await git.porcelainStatus(cwd: repo.path)` (`RunScheduler.swift:356`) and `completeAnalysisRun`'s matching read (`:493`) keep `repo.path` and must **not** be changed: the git sentinel watches the registered repository, not the run's directory.

- [ ] **Step 1: Write the failing test**

Insert this `@Test` into `struct EndToEndTests` in `ElliotKit/Tests/ElliotEngineTests/EndToEndTests.swift`, immediately after `inertMoveSpawnsNothing()` (which ends at line 331) and before `reconcilerAdmitsOrphans()`:

```swift
    /// The two facts a resume depends on, in one assertion: the fork tokens are
    /// there, and the child runs in the cwd of the **first** attempt.
    ///
    /// The cwd matters as much as the flags. Claude Code keeps a session's
    /// transcript under a slug of the directory it ran in, so a fork launched
    /// from anywhere else finds nothing — and fails by saying "No conversation
    /// found", which reads as a lost session rather than a wrong directory.
    @Test("A resumed run forks the session it names, from where the first attempt ran")
    func resumedRunCarriesTheForkTokensAndTheFirstAttemptsCwd() async throws {
        let stack = try await Stack.make(fixture: "create-issue-success.ndjson")
        defer { stack.cleanUp() }

        // A directory of the first attempt's own, deliberately not `repo.path`:
        // while `start` built its invocation from `repo.path`, this test could
        // not tell the two apart.
        let firstCwd = stack.home.appendingPathComponent("first-attempt", isDirectory: true)
        try FileManager.default.createDirectory(at: firstCwd, withIntermediateDirectories: true)

        let card = try await stack.board.createCard(
            repoID: stack.repo.id, title: "Resume me").card
        let now = Date()

        let first = SkillRun.card(
            cardID: card.id, repoID: stack.repo.id, kind: .createIssue,
            prompt: "/ai-migration-kit:create-issue Resume me", cwd: firstCwd.path,
            state: .failed,
            startedAt: now.addingTimeInterval(-1_800),
            endedAt: now.addingTimeInterval(-1_700),
            logPath: stack.home.appendingPathComponent("runs/first.ndjson").path,
            stderrPath: stack.home.appendingPathComponent("runs/first.log").path,
            createdAt: now.addingTimeInterval(-1_800)
        )
        try await stack.store.saveRun(first)

        // `.queued`, so `pump()` admits it; seeded straight into the store
        // because no transition creates a resumed run — that is PR4's.
        let resumed = SkillRun.card(
            cardID: card.id, repoID: stack.repo.id, kind: .createIssue,
            prompt: "/ai-migration-kit:create-issue Resume me", cwd: firstCwd.path,
            resumedFrom: first.id,
            logPath: stack.home.appendingPathComponent("runs/resumed.ndjson").path,
            stderrPath: stack.home.appendingPathComponent("runs/resumed.log").path,
            createdAt: now
        )
        try await stack.store.saveRun(resumed)
        await stack.scheduler.launch(runID: resumed.id)

        let run = try await stack.awaitRun(cardID: card.id)
        #expect(run.id == resumed.id)

        // Adjacency, not membership: where the block sits is the contract, and
        // `--add-dir` naming the first attempt's directory is half of it.
        //
        // Read as a bounded slice, never by index. Before the fix below ships,
        // `--add-dir <cwd>` is the *last* pair argv has: `Stack` builds its
        // scheduler with `ceiling: .off`, so no `--max-budget-usd` follows, and
        // the repository's `extraAllowedTools` is empty, so no `--allowedTools`
        // does either. `argv[addDir + 2]` would therefore trap with
        // `Fatal error: Index out of range` — killing the whole test process
        // instead of failing this expectation, and looking exactly like the
        // intermittent signal abort CLAUDE.md warns about. `prefix(5)` is total:
        // it returns what is there and this reports the difference.
        let argv = run.argv
        let addDir = try #require(argv.firstIndex(of: "--add-dir"))
        #expect(Array(argv.dropFirst(addDir).prefix(5)) == [
            "--add-dir", firstCwd.path,
            "--resume", first.id.uuidString.lowercased(),
            "--fork-session",
        ])
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd ElliotKit && swift test --filter EndToEndTests`

Expected: FAIL — `resumedRunCarriesTheForkTokensAndTheFirstAttemptsCwd` reports **one** expectation failure, whose left-hand side is the two tokens argv actually ends with and whose right-hand side is the five above:

```
Expectation failed: (Array(argv.dropFirst(addDir).prefix(5)) → ["--add-dir", "<stack.home path>"])
  == (["--add-dir", "<stack.home path>/first-attempt", "--resume", "<first id>", "--fork-session"])
```

because `start` still builds the invocation from `repo.path` and passes no `resumeFrom`, so neither the directory nor the fork tokens are there.

- [ ] **Step 3: Write minimal implementation**

In `ElliotKit/Sources/ElliotEngine/RunScheduler.swift`, replace the invocation built in `start` (lines 340-347) with:

```swift
        let invocation = ClaudeInvocation(
            runID: run.id,
            prompt: run.prompt,
            // The **run's** cwd, not the repository's. They are the same value
            // for every run created today, and that is the point: a resumed run
            // has to spawn where its first attempt spawned, because Claude Code
            // keeps the transcript under a slug of that directory. Two sources
            // for one fact make the fork fail with "No conversation found",
            // which reads as an expired session rather than a wrong directory.
            cwd: run.cwd,
            permissionMode: repo.permissionMode,
            extraAllowedTools: repo.extraAllowedTools,
            maxBudgetUSD: ceiling.perRunUSD,
            resumeFrom: run.resumedFrom
        )
```

Leave `treeBaselines[run.id] = await git.porcelainStatus(cwd: repo.path)` (line 356) exactly as it is.

- [ ] **Step 4: Run test to verify it passes**

Run: `cd ElliotKit && swift test --filter EndToEndTests`

Expected: PASS — every test in the suite, including the new one.

- [ ] **Step 5: Commit**

```bash
git rev-parse --abbrev-ref HEAD
git add ElliotKit/Sources/ElliotEngine/RunScheduler.swift \
        ElliotKit/Tests/ElliotEngineTests/EndToEndTests.swift
git commit -m "fix(engine): spawn a resumed run where its first attempt ran"
```

---

### Task 7: The lost-session fixture, end to end

**Files:**
- Create: `Fixtures/stream-json/resume-session-gone.ndjson`
- Test: `ElliotKit/Tests/ElliotEngineTests/EndToEndTests.swift` (a `@Test` inside `struct EndToEndTests`)

**Interfaces:**
- Consumes: `ResumeVerdict.of(resumedFrom:result:)` (Task 2), `SkillRun.resumedFrom` (Task 3), the verdict wiring in `RunScheduler.finish` and `Verifier.noIssueReason` (Task 5), the `resumeFrom` invocation wiring (Task 6).
- Produces: nothing consumed by a later task. This is the witness that the whole chain — a real `claude` spawn, a real stream decode, `finish`, `completeCardRun`, `Verifier` — turns a turn-less run into an honest sentence on the card.

**Does one fixture suffice, with no new `fake-claude.sh` mode? — Yes.** `Scripts/fake-claude.sh` defaults to `FAKE_CLAUDE_MODE=replay` (line 84), replays `FAKE_CLAUDE_FIXTURE` line by line (lines 126-131) and exits `FAKE_CLAUDE_EXIT`, default 0 (line 133). Nothing about the *contents* of a fixture needs a mode: an error result is just another line to print. `RunScheduler.state(for:)` (`RunScheduler.swift:508-518`) reads `result.isError` and records `.failed` regardless of the zero exit, which is the honest outcome here.

- [ ] **Step 1: Write the failing test**

Create `Fixtures/stream-json/resume-session-gone.ndjson` — exactly one line, terminated by a newline:

```
{"type":"result","subtype":"error_during_execution","duration_ms":214,"duration_api_ms":0,"is_error":true,"num_turns":0,"result":"No conversation found with session ID: 5f1b2c3d-4e5f-6789-abcd-ef0123456789","stop_reason":null,"total_cost_usd":0,"terminal_reason":"error","permission_denials":[],"errors":["No conversation found with session ID: 5f1b2c3d-4e5f-6789-abcd-ef0123456789"],"session_id":"5f1b2c3d-4e5f-6789-abcd-ef0123456789"}
```

Then insert this `@Test` into `struct EndToEndTests` in `ElliotKit/Tests/ElliotEngineTests/EndToEndTests.swift`, immediately after the test added in Task 6:

```swift
    /// A resume that finds no conversation never had a turn, so its closing
    /// prose is the CLI complaining about a missing transcript. Copy that into
    /// `.noIssueCreated(reason:)` and the card says the idea was already covered
    /// — which is exactly the sentence an unattended loop reads as "nothing to
    /// do here", on a card for which nothing whatsoever was attempted.
    @Test("A resume that finds no conversation is not recorded as a duplicate skip")
    func sessionGoneIsNotADuplicateSkip() async throws {
        let stack = try await Stack.make(
            fixture: "resume-session-gone.ndjson",
            // `gh` has to answer, so the title sweep reaches the sentence: with
            // no FAKE_GH_ISSUES the fake prints `[]`, which is what `gh` returns
            // for a repository with nothing matching.
            ghPath: TestPaths.fakeGH
        )
        defer { stack.cleanUp() }

        let card = try await stack.board.createCard(
            repoID: stack.repo.id, title: "Stream the run log inside the card").card
        let now = Date()

        let first = SkillRun.card(
            cardID: card.id, repoID: stack.repo.id, kind: .createIssue,
            prompt: "/ai-migration-kit:create-issue Stream the run log inside the card",
            cwd: stack.repo.path,
            state: .failed,
            startedAt: now.addingTimeInterval(-1_800),
            endedAt: now.addingTimeInterval(-1_700),
            logPath: stack.home.appendingPathComponent("runs/gone-first.ndjson").path,
            stderrPath: stack.home.appendingPathComponent("runs/gone-first.log").path,
            createdAt: now.addingTimeInterval(-1_800)
        )
        try await stack.store.saveRun(first)

        let resumed = SkillRun.card(
            cardID: card.id, repoID: stack.repo.id, kind: .createIssue,
            prompt: "/ai-migration-kit:create-issue Stream the run log inside the card",
            cwd: stack.repo.path,
            resumedFrom: first.id,
            logPath: stack.home.appendingPathComponent("runs/gone-resumed.ndjson").path,
            stderrPath: stack.home.appendingPathComponent("runs/gone-resumed.log").path,
            createdAt: now
        )
        try await stack.store.saveRun(resumed)
        await stack.scheduler.launch(runID: resumed.id)

        let run = try await stack.awaitRun(cardID: card.id)
        #expect(run.id == resumed.id)
        // `is_error`, so the run failed; `num_turns: 0`, so it never started.
        // Exit code zero throughout — the state comes from the result, not the
        // shell.
        #expect(run.state == .failed)
        #expect(run.exitCode == 0)
        #expect(run.numTurns == 0)
        // The prose exists, and is exactly what must NOT become the reason.
        #expect(run.resultText?.hasPrefix("No conversation found") == true)

        #expect(run.verifiedOutcome == .noIssueCreated(
            reason: "The conversation this run tried to resume no longer exists, so nothing ran."))
    }
```

- [ ] **Step 2: Run test to verify it fails**

First confirm the whole plan is on a clean build, because a stale `.build` after this many source edits produces failures that are not about the code:

Every command in this step starts from the repository root and stays there — the `cd` is inside a subshell, because the blocks below alternate between `swift test` under `ElliotKit/` and a `git checkout` whose path is root-relative:

```bash
rm -rf ElliotKit/.build
(cd ElliotKit && swift test --filter EndToEndTests)
```

Expected, **if Task 5 were absent**: FAIL with
`Expectation failed: (run.verifiedOutcome → Optional(.noIssueCreated(reason: "No conversation found with session ID: 5f1b2c3d-4e5f-6789-abcd-ef0123456789"))) == …`.

Since Task 5 has already shipped the reason, this test may pass on the first run. **That is not a reason to skip Step 2** — the discriminating check is that it fails when `Verifier.noIssueReason`'s `.sessionGone` branch is removed. Do that once, by hand, before continuing.

First, in `ElliotKit/Sources/ElliotEngine/Verifier.swift`, replace the whole body of `noIssueReason` with the `.ran` half alone — the state of the world before Task 5 — keeping the signature so everything still compiles:

```swift
    static func noIssueReason(run: SkillRun, resume: ResumeVerdict) -> String {
        _ = resume
        guard let text = run.resultText, !text.isEmpty else {
            return "No issue was created. It may already be covered by an existing one."
        }
        return String(text.prefix(400))
    }
```

Then run it and restore:

```bash
(cd ElliotKit && swift test --filter EndToEndTests)
```

Expected while collapsed: FAIL — `sessionGoneIsNotADuplicateSkip` reports
`Expectation failed: (run.verifiedOutcome → Optional(.noIssueCreated(reason: "No conversation found with session ID: 5f1b2c3d-4e5f-6789-abcd-ef0123456789"))) == …`, which is the defect this test exists to hold shut: the CLI's complaint about a missing transcript wearing the sentence that means "the idea was already covered".

```bash
git checkout -- ElliotKit/Sources/ElliotEngine/Verifier.swift
```

- [ ] **Step 3: Write minimal implementation**

Nothing to implement: Tasks 1-6 carry the behaviour, and this task supplies the fixture and the end-to-end witness. If Step 2 showed the test passing only because of an unrelated path (for example the sweep matching an issue), re-read the assertion against `Scripts/fake-gh.sh:119-132` — `issue list` with no `FAKE_GH_ISSUES` prints `[]` — before adjusting anything.

- [ ] **Step 4: Run test to verify it passes**

Run: `cd ElliotKit && swift test --filter EndToEndTests`

Expected: PASS — every test in the suite.

- [ ] **Step 5: Commit**

```bash
git rev-parse --abbrev-ref HEAD
git add Fixtures/stream-json/resume-session-gone.ndjson \
        ElliotKit/Tests/ElliotEngineTests/EndToEndTests.swift
git commit -m "test(engine): pin that a lost session is not a duplicate skip"
```

- [ ] **Step 6: Sample the whole suite five times after a clean build**

One green run does not clear a suite: a defect failing half the time has reached `main` here past twenty-one single-sample merges. The clean build costs 21-45 s and each execution 1.5-2.9 s, so five samples cost about eight seconds after the build.

⚠ The `cd` happens **once**, before the loop, and the loop body does not repeat it. Written as `for i in …; do cd ElliotKit && swift test; done`, the second iteration looks for `ElliotKit/ElliotKit`, `cd` fails, `&&` short-circuits, `swift test` never runs — and the loop prints nothing and **exits 0**. That is the same "measured nothing, looks like success" shape as a `--filter` matching no type.

```bash
rm -rf ElliotKit/.build
cd ElliotKit
swift build
for i in 1 2 3 4 5; do swift test 2>&1 | tail -3; done
```

Expected: five identical runs, each reporting the same non-zero test count and `0 failures`. ⚠ A run reporting `warning: No matching test cases were run` has measured nothing regardless of its exit code. If one of the five differs, do not commit on top of it — re-read *Things that bite* in `CLAUDE.md` on stale `.build` and on the intermittent signal-10 abort, wipe, and re-sample before concluding anything about the code.
