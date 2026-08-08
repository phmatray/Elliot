# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A native macOS Kanban board where **moving a card is the act of execution**. Dragging a card from
Backlog to To Do genuinely spawns `claude -p /ai-migration-kit:create-issue <story>` in a registered
repository. The board is a remote control, not a mirror of GitHub.

Two binaries ship in one bundle: the SwiftUI app (`ElliotApp`) and an MCP helper (`elliot-mcp`) that
Claude Code spawns over stdio. Both reach the same rule engine, so an agent's `board_move_card` and a
human's drag are the same act.

`README.md` carries the design rationale; this file carries what you need to work in the code.

## Commands

```bash
cd ElliotKit && swift build                      # library + both executables
cd ElliotKit && swift test                       # whole suite; no Xcode, no tokens, no GitHub
cd ElliotKit && swift test --filter BoardServiceTests   # one suite

./Scripts/build-app.sh                           # assembles dist/Elliot.app (SwiftPM emits no bundle)
open dist/Elliot.app                             # launch from Finder, not a terminal — see PATH below
claude mcp add elliot -s user -- "$PWD/dist/Elliot.app/Contents/MacOS/elliot-mcp"
```

- `swift test --filter` matches the **type** name, not the `@Suite` display name: `ClaudeRunnerTests`,
  not `"Claude runner"`. A filter matching nothing prints `warning: No matching test cases were run`
  and **exits 0** — indistinguishable from success.
- **Swift 6.3.1 tools-version** — Xcode 26.4 or newer, no lower option — `swiftLanguageModes: [.v6]`,
  deployment target macOS 15. Strict concurrency is on: every new type crossing an isolation boundary
  must be `Sendable`.
  - This line said **6.1** until #116, and no machine had ever built the package on a 6.1 toolchain —
    the first CI run this repository ever had failed on one
    ([31118743562](https://github.com/phmatray/Elliot/actions/runs/31118743562)) in under two
    minutes. The floor did not start wrong; it **rotted**, silently, because nothing exercised it.
  - The replacement is measured — 21 builds over 8 Apple toolchains, runs
    [31167517846](https://github.com/phmatray/Elliot/actions/runs/31167517846),
    [31167931727](https://github.com/phmatray/Elliot/actions/runs/31167931727) and
    [31170356694](https://github.com/phmatray/Elliot/actions/runs/31170356694) — and it found **two
    floors, four releases apart**:

    | | lowest toolchain measured green |
    |---|---|
    | `swift build` (library + executables) | **6.2** — Xcode 26.0 |
    | `swift build --build-tests` / `swift test` | **6.3.1** — Xcode 26.4 |

    6.1.2 fails two sites in `ElliotAppKit`; every 6.2.x fails one expression in
    `ElliotProcessTests/StreamingProcessDrainTests.swift:138`, where the compiler gives up
    type-checking a `#expect` in reasonable time. `Package.swift` declares **6.3.1**, the higher one,
    and says at length why: `swift test` is this repo's only gate, so the failure a 6.2 contributor
    would actually meet is the test one, and a tools-version refusal at manifest parse is the whole
    point — a named refusal instead of a mystery. Read that comment before changing this.
  - ⛔ **The patch is load-bearing: `6.3.1`, never `6.3`.** SwiftPM resolves a bare `6.3` as **6.3.0**
    and *does* enforce a declared patch (verified: a `6.3.9` manifest is refused by a 6.3.3 toolchain,
    by name). swift.org's `swift-6.3-RELEASE` reports exactly `6.3`, so rounding this down readmits a
    toolchain that parses, builds, and then hits the `#expect` timeout — the mystery this floor exists
    to prevent, restored by three characters. It shipped as `6.3` for one commit; code review caught it.
  - ⚠️ **`swift build` being green is not the floor being green** — that is how the 6.1 claim survived.
    The test targets are substantial and `swift build` never compiles them.
  - Measured while establishing this: the `macos-15` runner image tops out at Xcode 26.3 (Swift
    6.2.4), so **the test targets cannot be compiled on that image at all**. Whether macOS 15 can
    *host* Xcode 26.4 is unmeasured — an image's contents are not Apple's requirements, and inferring
    one from the other is the mistake #116 is about.
- **CI here is two workflows, and they answer different questions.**
  `.github/workflows/swift-floor.yml` (#116) asserts the runner's toolchain against the floor
  `Package.swift` declares, and asserts that `ci.yml` runs on that same image;
  `.github/workflows/ci.yml` (#21) runs `swift build` then `swift test`. ⚠️ **`swift build
  --build-tests` is not `swift test`** — `--build-tests` compiles the eight test targets and executes
  no `@Test`, so "compiles on the floor" and "the suite passed" are two claims. That distinction is
  #116's whole subject and it does not depend on how the jobs are arranged.
  - **Since #187 the floor job compiles nothing, and the two claims are established one each.** It
    ran `swift build` *and* `swift build --build-tests` until 2026-08-08, which meant every pull
    request compiled the **whole package twice on two `macos-26` runners** — not just the test
    targets, which is what the issue title said and what its own comments understated. Measured
    before and after: **60–70 → 40–50 billed macOS minutes** per pull request, floor
    2m21–3m58 → **8–9s**, ⚠️ and the figure to quote is the **saving** — 20–30 billed minutes,
    entirely this job's own 3–4 → 1 — because `build-and-test` is untouched and its cold compile
    still crosses a billed-minute boundary run to run (2m38, then 3m03),
    with `1418 tests in 158 suites` unchanged either side. The arithmetic, the run ids and the
    argument are in `swift-floor.yml`'s header, which is the durable copy — GitHub drops the logs at
    90 days.
  - ⛔ **So `ci.yml`'s `swift test` now carries the floor guarantee too.** Delete it, filter it, or
    move `ci.yml` to another image and #116's claim quietly stops being exercised. Four ways for that
    to happen are enforced by `swift-floor.yml`'s second step, which fails by name: the two
    `runs-on:` labels parting, `swift test` disappearing from `ci.yml`, `ci.yml` selecting its own
    toolchain (`setup-xcode`, `DEVELOPER_DIR`), and `ci.yml` filtering itself out with `paths:`.
    What is **not** covered is a label that means two different images across a GitHub rollout, and a
    job-level `if:` that grep cannot tell from a step-level one. Those are gaps, not impossibilities
    — an earlier draft of this bullet said the `swift test` half "cannot be" enforced, which was
    wrong the moment it was written (the grep that now enforces it is three lines) and is exactly the
    kind of sentence that stops the next person closing a hole.
  - **Branch protection is still off**, so both checks are advisory: `gh api
    repos/phmatray/Elliot/branches/main/protection` returns 404 `Branch not protected`, and a red check
    does not block a merge. "Wait for green CI" now returns a real verdict; it still does not stop
    anything.
  - ⚠️ **A conflicted pull request fires no `pull_request` workflow at all — and it fails by silence,
    not by saying so.** Measured in #140: after `main` moved, GitHub created **zero** runs for the
    head SHA for 25 minutes, `check-runs` returned `total_count: 0`, a close/reopen produced nothing,
    and the Actions status page read *All Systems Operational*. The workflow file GitHub held at that
    SHA was byte-identical to the local one and parsed. I diagnosed it as the trigger throttle that
    had genuinely blocked this issue for 33 hours the day before — **and wrote that wrong diagnosis
    into the PR body as a fact.** The actual cause was `mergeStateStatus: DIRTY`; merging `main`
    produced a run within seconds. **Read `gh pr view --json mergeable,mergeStateStatus` before
    concluding anything about a missing run** — an absent run and a throttled run are indistinguishable
    from the outside, and only one of them is yours to fix.
- Re-run `claude mcp add` after moving the app: the registration records an absolute path.

### ⛔ Do not run `swift format` over the tree

**This code is formatted by hand.** `swift-format`'s pretty-printer cannot reproduce it, and running
it across the package rewrites the package.

These two commands were documented here until #71 and both were harmful:

```bash
swift format --in-place --recursive ElliotKit/Sources ElliotKit/Tests   # ⛔ rewrites ~84 files
swift format lint --strict --recursive ElliotKit/Sources ElliotKit/Tests # ⛔ 22 463 violations
```

Measured on a clean checkout at commit `8c021e8`: with no configuration the formatter reindented
**140 files from 4 spaces to 2** — the whole package — and `lint --strict` reported **22 463
violations**, 21 145 of them `Indentation`. Neither could be used to judge anything, and the
reformat looked like a formatting pass rather than a mistake, so it would ride along inside whatever
pull request happened to be open.

`.swift-format` now pins 4 spaces and 110 columns, which bounds an accidental run to a reflow
instead of a reindentation of everything. It does **not** make the formatter safe: the disagreement
is the printer's layout, not its width. Measured at 100, 110 and 160 columns the churn was 108, 89
and 84 files — width changes almost nothing, because what the printer wants is different, e.g.

```swift
-        return candidates          // written by hand
+        return                     // what swift-format produces, at every width tried
+            candidates
             .enumerated()
```

So: **format the lines you wrote, by hand, to match their neighbours.** If you want to check one
file you just touched, `swift format lint <file>` is readable; the tree-wide form is not.

Adopting the formatter wholesale is a live option and a one-way door: it costs a single ~1 600-line
reformat commit and buys a real guard forever. It has not been taken, and it is not a decision to
make inside a feature branch.

## Architecture

The dependency graph *is* the layer order (`ElliotKit/Package.swift`). Touch them in this order:

```
ElliotModel     no dependencies    value types, rule engine, prompt builder, stream-json decoder,
                                   PRMatcher, reconciler — pure: no I/O, no clock, no randomness
ElliotStore     GRDB               schema, migrations, the one atomic move
ElliotProcess   —                  tool discovery, login-shell env capture, spawning, line splitting,
                                   gh/git clients
ElliotIPC       —                  wire protocol, unix socket server and client
ElliotEngine    all of the above   BoardService, RunScheduler, Verifier, PRWatcher, Reconciler,
                                   MCPRequestHandler (the wire's live half), preflight
ElliotMCPKit    Model+IPC+Store    the MCP tools (one file per tool under Tools/)
ElliotAppKit    SwiftUI            every view, and AppModel — a library, so it is testable
ElliotApp       ElliotAppKit       @main and the Scene graph, and nothing else
elliot-mcp      stdio              the helper Claude Code spawns
```

### The load-bearing invariants

These span several files each; breaking one is invisible locally.

**One funnel.** `BoardService` (`ElliotEngine/BoardService.swift`) is the only thing that changes a
card's `column`. A drag and `board_move_card` both reach `proposeMove`/`commitMove`. Never add a second
write path for `column`.

**One rule engine.** `evaluateMove` in `ElliotModel/RuleEngine.swift` is pure and decides the whole
transition matrix. `rankNextSteps` (what `board_next` answers) decides by *calling* `evaluateMove`, so
the board predicts its own behaviour instead of holding a second copy of the rules.

**One spawn.** `ChildProcess` (`ElliotProcess/ChildProcess.swift`) is the only thing that starts a
child, drains its pipes and publishes its exit. `ProcessRunner` and `StreamingProcess` are wrappers
over it that differ *only* in what they do with the bytes, expressed as a `ChildOutputSink` — and the
sink's methods are called **while the drain lock is held**, because under the lock is the whole
invariant. A sink handed a chunk to deal with later can append to a result already returned or yield
into a stream already finished, which is the tail-dropping bug restored.

This was the mechanism written twice until #146, and the copy was not incidental: **eight comment
lines were byte-identical between the two files**, and they were the four load-bearing arguments
themselves. When the *explanation* of an invariant has been copied word for word, the invariant has
been copied too. It had already cost three defects, each fixed in one file — `22bb230` (dropped run
tails), `3b1c226`/#18 (`waitUntilExit` parking a cooperative thread), `36b6da6`/#105 (SIGKILL
escalation `ProcessRunner` never got) — and #26 opened a fourth investigation aimed at one file.
`DrainDuplicationTests` keeps the measurement runnable: it re-derives that comment count and fails
naming the invariant that is written twice, because **a gate that is not a test is a gate nobody
re-runs**. Since #21 that argument is stronger rather than weaker — `ci.yml` executes `swift test` on
every pull request, so a guard shaped as a test is enforced on every change rather than only when
someone remembers to run it. (The wording here has been corrected twice: flatly "no CI" until #116 added
`swift-floor.yml`, then "no build-and-test CI" until #21 added `ci.yml`. A stale claim in this file is
what #116 was about, and the shape of it recurs. #186 is the third, and the first to land in *source*
rather than here: #102 fixed this file and the profile, but #21's constraints barred it from
`Package.swift` and every source file, so four comments — including `DrainDuplicationTests`' own
header — went on reasoning from the retired premise in the interval. ⚠️ Before anyone automates the
check: within #186's four scoped paths a `no CI` grep already returns two innocent hits, `PRStatus`'s
"no CI *state*" and `ci.yml`'s hypothetical about a repository that merely *looks* like it has none;
unscoped it also returns `Fixtures/issues/issue-79.md` and two `Fixtures/gh/*.json`, which are frozen
copies of what those issues really said and must **not** be corrected. A string gate over prose can
tell neither a claim from a mention nor a live claim from a quoted one, which is why the fix here is a
habit rather than a matcher.)

The single behavioural delta is recorded at both ends: `ProcessRunner` gave up its
`state.withLock { !$0.exited } &&` conjunct in the SIGKILL backstop, since a sink may hold that lock
across a write to the run's log. It loses nothing — the flag was set inside the termination handler,
which runs only once Foundation has reaped the child, so `isRunning` had gone false strictly earlier.

**`ElliotMCPKit` imports neither `ElliotEngine` nor `ElliotProcess`** — deliberate, commented in
`Package.swift`. The helper holds no copy of the rules, so it cannot diverge from them.

**A system-originated move never triggers a skill.** `MoveContext.allowSideEffects == false` →
`.noAction`, checked before every other guard. The state a system move reacts to (a PR going ready, a
crash reconciled) was *produced* by a skill.

**`gh` is the fact; the agent's prose is a hint.** Nothing written back to a card is parsed out of a
run's closing summary. Issue and PR numbers come from `gh … --json` through `GHClient`/`Verifier`.
`PRMatcher` scores branches rather than looking one up, anchoring on `^<issue>-` *with* the trailing
hyphen so issue 4 cannot match `feat/47-…`.

**What a verified outcome *does* to a card is decided once too, in `ElliotModel`.** `Verifier` says
what happened; `VerifiedOutcome.applied(to:attribution:)` (`ElliotModel/CardOutcome.swift`) says what
that means for the card — the fields, the `lastError`, and the move it implies — and returns all three
in one `CardOutcome`. `RunScheduler.apply`, `Reconciler.apply` and `PRWatcher.reconcile` save and
move; **they do not judge**, and none of them writes a card field of its own. Enforced by grep: none
of `issueNumber|issueURL|prNumber|prURL|branch|lastError =` appears in those three files.

This was three hand-written switches until #135, and they had already drifted — the same run,
verified by the same `Verifier`, produced a clean card through `RunScheduler` and a card still
showing the failed run's banner through `Reconciler`. The card and the move travel in one value on
purpose: a caller that could save the fields and forget the move is the bug the type prevents.
`GHPullRequest.verifiedOutcome` exists so `PRWatcher` states its conclusions in the same vocabulary
instead of re-deriving them, which is why it was the site that drifted without looking like a copy.

The one difference that is *real* stays a parameter: `Attribution.live` records `.prBecameReady` /
`.prMergedExternally`, `.launchSweep` records `.reconciliation`. That is the board watching the world
move versus the board catching up after not running — it is persisted in `MoveAudit` and rendered
from there, so collapsing the two would rewrite history rather than simplify code.

**A read is answered once, as an `ElliotResponse`, and a tool only renders it.** `BridgeOutcome` has
two cases and both carry a response: `.live` is what the app sent back, `.offline(response, reason)`
is what `OfflineResponder` (`ElliotMCPKit/OfflineResponder.swift`) answered from the read-only
snapshot. A tool never sees a `BoardStore`. `CallTool.Result.render(_ outcome:_ body:)` attaches
`source` and the snapshot note — **prepending** it to whatever note the body wrote, since
`board_list_cards` and `board_list_runs` attach a page note too — and the body contributes only the
fields that are its own.

`.offline` carried a `BoardStore` until #141, and the six sites that unpacked it each held a second
implementation of the app's query: the clamp, the repo filter, the DTO assembly, the refusals. The
drift is not hypothetical — it is recorded in the comments of the code that fixed it, four times, one
tool at a time. `ListRunsTool` had to be taught that an unknown card is a refusal and not an empty
page (*"which is finding 3 again, one tool over"*); `ListCardsTool` and then `ListProposalsTool` that
an unknown repository is not "no filter" (*"collapsing them is what made a typo return the whole
board as a success"*); `GetCardTool` that a snapshot leaving `activeRunID` nil *"would report every
held card as movable"*. Each was found separately and the next tool started from zero, because
nothing in the reply tells an agent which branch served it. `respond(to:)` switches **exhaustively
over `ElliotRequest` with no `default`**, so a read case added to the wire has to be answered from
the snapshot before the helper builds; `OfflineParityTests` (in `ElliotEngineTests`, which is the
only target that can import both) drives one seeded board through `MCPRequestHandler.handle` and
`OfflineResponder.respond` and compares the encoded bytes.

What the two cannot do is share code: `MCPRequestHandler` lives in `ElliotEngine`, and the invariant
above forbids importing it here. They share a **vocabulary**, which is what makes the parity test
possible — the honest limit of the fix, and the reason the test exists rather than a comment asking
for care.

**The app is the sole writer.** SQLite does not notify other processes of writes, so `elliot-mcp` opens
the store read-only and routes every mutation back over the unix socket. A read may fall back to
`source: offline-db`; a **write never falls back** — writing a column change straight to the database
would move a card without firing its rule. `OfflineResponder` holds the same line one layer down: its
write cases return `read_only`, spelled out one line each rather than swept into a `default`, because
a `default` is exactly what would silently answer a *read* case nobody had implemented.

**A diagnostic that can be fixed carries the fix, and the fix's kind decides who runs it.** Since #170
a `CheckResult` may carry `fixes: [CheckFix]`, the way a `RepoRow` has carried `RepoFix` since #12 —
before that, Preflight could only *describe* a remedy in `fixHint` prose while the Repositories page
could perform one, which was two screens answering the same question and only one of them working.

⛔ **The choice of mechanism is not stylistic.** `createLabels` is deterministic — `gh label create`,
one right answer, nothing committed — so it runs `gh` directly and **no agent**: an unattended
`claude -p`, which Elliot launches at `bypassPermissions` inside a real checkout, is a slower and
far wider-reaching way to run a `for` loop. `seedCard` is for work that *is* a judgement and edits a
committed file, so it goes on the board and through a pull request. Reaching the agent through a card
rather than through a button is what keeps *moving a card is the act of execution* true: a second
place that starts an unattended agent, outside the board, would quietly make that claim false.

**Rules belong in `ElliotModel`.** Views render and dispatch; they do not judge. This is still the
rule, but since #72 it is a preference with a reason rather than a workaround: `AppModel` and the
views live in `ElliotAppKit`, a library, so `ElliotAppKitTests` can reach them. Put a rule in
`ElliotModel` because it is a rule — pure, no clock, shared with the MCP helper — not because the
app target is a black box. It no longer is.

**What `swift test` still cannot see is layout.** A view's *structure* is now assertable; where
things sit on screen is not, and that gap has cost this project three merges: `.inspector()` shipped
in #47 unverified, crashed in #50, destroyed the window layout in #52, and was reverted in #53 —
each one green on `swift build` and `swift test`. **A change that moves anything on screen is not
finished until someone has looked at it.** The cheap way, which needs no Xcode:

```bash
./Scripts/build-app.sh
open -n --env ELLIOT_HOME=/tmp/elliot-check dist/Elliot.app   # an isolated store, not yours
```

and then read the window's accessibility tree — the column captions, the toolbar and the status bar
all carry labels, so "did the board survive" is a text diff rather than a squint. When in doubt,
build the same check from `main` and compare.

⚠️ **Do not make a tool fail by prepending a shim to `PATH` before `open`: the injection arrives and
still loses, silently.** `LoginShellEnvironment.capture()` runs `/bin/zsh -lic` and keeps *that*
shell's environment — the whole point, since a Finder launch sees only `/usr/bin:/bin:/usr/sbin:/sbin`.
The injected directory is **not stripped**; it survives the capture and loses on *order*, which is what
makes this false negative convincing. Measured 2026-08-08 (#188), `--env PATH=/tmp/shim:$PATH` on the
command above with a `/tmp/shim/gh` that logs its argv and exits 1: `ps eww` showed the app really did
carry `/tmp/shim` **first**, so the injection arrived; the captured `PATH` still held it, at **index 26
of 47**; `ToolLocator.locate("gh")` returned `/opt/homebrew/bin/gh` (`foundVia: PATH (/bin/zsh -lic)`,
index 9); the shim's log stayed **empty**; the board read `Ready.`, no banner. A login shell runs its
own rc files, and any that re-prepend their own bin directory push every inherited entry below them.
**The margin is this machine's, not a constant** — #183 measured the same trap at 12 entries, not 17 —
and where nothing re-prepends, the shim stays at index 0 and wins. It is the sixth member of the
family *Things that bite* catalogues below, and like the other five it never says *no*.

**What does say so is Preflight**, which is the screen to read before trusting a pass: its `gh` row
prints the resolved path (`/opt/homebrew/bin/gh — gh version …`, never `/tmp/shim/gh`) and *Login shell
environment* prints `Captured via /bin/zsh -lic — 47 PATH entries` — or `.warn`s *"Could not read the
login shell"*, which is the one case where the shim really is stripped, because both `-lic` and `-lc`
failed and `capture()` fell back to a built-in `PATH`. **Instead:** from a test, point
`ToolConfig.ghPath` at `Scripts/fake-gh.sh` — the seam *Testing discipline* describes below, no
production change; from a launched app, cause a *genuine* failure, e.g. an owner handle that does not
exist (`gh repo list phmatray-does-not-exist-9f3a` → *"the owner handle … was not recognized as either
a GitHub user or an organization"*, exit 1), which is what #183 did and is stronger evidence than a
simulated one.

**Since #155 the *agent* can look too: `board_screenshot`.** Elliot renders its own window with
`NSView.cacheDisplay` and hands back a PNG as an MCP image block, so no permission is involved and
nothing has to be frontmost — measured, on a window with `isVisible == false` in an app that was not
active, rendering at full designed size. That is the case this file records as misread nine times.
The alternatives were both dead ends and are written down so nobody re-explores them:
ScreenCaptureKit needs the Screen Recording grant this machine does not hold, and
`CGWindowListCreateImage` is **obsoleted in the macOS 15 SDK** — a compile error on our own floor,
not merely a deprecation.

⚠️ **It draws Elliot's hierarchy, so three things are absent — and one of them will bite you.**
Sheets and popovers live in their own windows, and **the toolbar's controls render blank**: measured
against an independent whole-screen capture, the board's seven toolbar items came back as two empty
white capsules, because SwiftUI hosts `.toolbar` in titlebar accessory views the frame-view render
never reaches. The toolbar is a named conflict hot-spot in this repo, so that blind spot sits exactly
where changes land. `not_included` names all of it in every reply — **read it before concluding that
something failed to appear**, and use the accessibility tree above for anything in the toolbar.

⛔ **It photographs an open window; it cannot open one — so on a fresh launch an agent can look at
the board and at nothing else.** `AppKitWindowCapture.isOpen` is `isVisible || isMiniaturized`, and
that is deliberate (a closed scene stays in `NSApp.windows` and photographing its stale hierarchy is
the defect the check exists to stop). But every other scene — Archive, Preflight, Repositories,
Operations, Up next, New story — opens only from the View menu or a button, i.e. from a **click**,
and the measurements below say an agent has no click. Measured 2026-08-08 (#162) against a freshly
launched, seeded scratch instance:

| call | reply |
|---|---|
| `board_screenshot window=archive` | `window_not_open` · *"The window "archive" exists but is not open."* · hint: **"Open right now: board."** |
| `board_screenshot window=board` | `is_visible: true`, `source: live`, 1510×925 |

So "since #155 the agent can look too" is true of the **board**, and of any other window only once a
human has opened it. Plan an on-screen pass for a secondary window as *needing a person*, rather than
discovering it after building the bundle and seeding a store. The refusal is at least honest — it
names the two cases apart and lists what is open — which is the one thing this file's false-negative
family never does.

⚠️ **A long `ELLIOT_HOME` silently costs you the MCP socket.** `sun_path` is capped at 104 bytes on
macOS, so a scratch home under a deep path makes `startIPC` fail; the app runs fine, and Preflight
says so under *MCP socket*. Keep the check store short — `/tmp/elliot-check` is short on purpose.

**Since #168 the helper names that instead of blaming the app.** It used to decide everything from
`IPCClient.isAppRunning()` — *does something answer at this path* — so a socket that was never bound
was indistinguishable from an app that was never launched, and the reply read as "Elliot is not
running" while it was plainly on screen. `AppBridge` now measures the path against
`UnixSocket.pathFits` **before** it asks whether the app is up, and both `read` and `write` consult
that one guard. Measured on the fix's own branch, same machine, same home, within a minute of each
other, with that Elliot's 1599×937 board captured on screen at the time:

| | reply to `board_next` |
|---|---|
| the helper on `main` | `isError: false`, `source: offline-db`, *"Elliot is not running; this is a snapshot of its database."* |
| the helper after #168 | `app_unavailable` — *"the path ELLIOT_HOME leads to is 112 bytes, and a unix socket path must be under 104"* |

The old answer is the worse of the two and it is the one that looks fine: correct rows under a false
explanation, `isError: false`, no reason to doubt it. That is why a read here **refuses** rather than
falling back to the snapshot. ⚠️ It covers the **length** cause only — a socket directory that cannot
be created or written still reads as an absent app.

**A secondary window is verifiable too — it opens off-screen, it does not fail to open.** Every PR
from #75 to #89 carried some version of *"opening a `Window` scene needs the app frontmost, which the
automation driver refuses"*, and it was never true. A background `openWindow` does open the window; it
just lands off-screen because the app is not frontmost. The trap is the enumeration, not the window:
**list all of a pid's windows, never only the ones reporting `is_on_screen`.** Measured on a running
build, when `ElliotApp.swift` declared six `Window` scenes (**seven today** — counted 2026-08-08 in
#162: board, Repositories, Operations, Up next, Preflight, Archive, New story), two of them open:

```
id=2737  on_screen=False  820x720 @ (454,215)  title='Preflight'
id=2730  on_screen=False  900x700 @ (459,220)  title='Repositories'
id=2727  on_screen=True   143x164 @ (15,803)   title='Elliot'
```

Both secondary windows are **at their full designed size** and both say `is_on_screen: False`. Filter
on that flag and they are simply gone — which is exactly how "it didn't open" got written down nine
times. The cost was real: #83 and #84 merged with *"not verified on screen"* in their bodies, and #84
shipped a launch crash (`Fatal error: No Observable object of type AppModel found`) that sat on `main`
until #85 happened to look. Reading the Operations window this way is what found the duplicate rows
fixed in `ac6e460`, on the one screen that had been held back as unverifiable.

**The 143×164 board window in that listing is the same thing, and it is the Stage Manager strip — not
`minWidth` being ignored.** #74 reported a 143×144 restored board and called for its own issue; #75's
body corrected it and CLAUDE.md never caught up. The listing settles it: the same process, in the same
launch, is showing a 900×700 window, so nothing is clamping the app's widths. Only the board is parked
in the strip, because the app is not frontmost. Nothing to fix.

⚠️ **An empty accessibility tree is not an empty window.** Reading the tree needs macOS Accessibility,
held by whichever process is *responsible* for the reader (see the next section — it is not always the
tool you typed); without it every window of every app returns zero elements and a `degraded` flag,
which reads exactly like "the window has nothing in it" — the same false negative, one layer down.
Before believing a blank tree, snapshot a known-good app (Finder will do) as a control. If that is
blank too, the finding is about your permissions, not about the change under review.

**Looking and touching are two different grants, and neither belongs to a *tool*.** macOS attributes
Accessibility and Screen Recording to a **responsible process** — the app answerable for whatever is
asking. So the `cua-driver` daemon, a shell you opened in your terminal, and a shell an agent run
inherited from Elliot are three different subjects that can hold three different answers, and none of
them is "this machine". `cua-driver` says as much in its own reply, which is the tell that this is
the documented model rather than a quirk of one tool:

```bash
cua-driver permissions status --json
# {"accessibility": false, "screen_recording": false,
#  "source": {"bundle_id": "com.trycua.driver", "responsible_ppid": 1,
#             "note": "These booleans reflect the CuaDriver daemon's own TCC identity …"}}
```

- **Screen Recording** buys *observation*: window **titles**, and a real screenshot of a window or the display.
- **Accessibility** buys *actuation* — and also the AX tree. Synthetic clicks and key presses are posted to another process's event queue, which macOS gates behind this grant.

⛔ **So "can this machine observe the UI" is not a question with an answer.** Ask it of an identity —
and ask it with the two calls that answer directly. Both are instant, neither prompts, and neither
touches another app:

```bash
cat > /tmp/grants.swift <<'EOF'
import ApplicationServices
import CoreGraphics
print("accessibility   ->", AXIsProcessTrusted())
print("screenRecording ->", CGPreflightScreenCaptureAccess())
EOF
swift /tmp/grants.swift        # -> false, false  (2026-08-07, from an Elliot-spawned agent shell)
```

⚠️ **As of today the driver holds neither grant** — `accessibility: false` *and*
`screen_recording: false`, read against the daemon's own TCC identity `com.trycua.driver`, which is
the identity that matters because the daemon is its own responsible process. So observation is off
too, and the window listing above is not currently reproducible through it. ⛔ **This paragraph used to
offer `/usr/sbin/screencapture -l` as a shell fallback that "still enumerates windows"; it does
neither.** `-l<windowid>` *captures* one window rather than listing any, and from an agent's shell it
answers `could not create image from window` — the same missing grant, measured 2026-08-08 (#132). The
caveat it carried was true and beside the point: a non-frontmost window parks in the Stage Manager
strip at ~143×160 with nothing in it readable as text. See the probe table further down for what an
agent can and cannot do, and reach for `board_screenshot` instead.

⛔ **Probe with those, not by firing a click at the board.** A synthetic click that lands on a card in
a registered repository *is the act of execution* — it can start an unattended `claude -p` at
`bypassPermissions` — so "just try it and see" is the one probe that can do real work by accident.
The table below records what each channel *answered*; it is a reference, not a script to run top to
bottom against your everyday board.

Then, if you want to know *whose* grants those are, walk your ancestry — the last entry is the app
they are read against:

```bash
P=$PPID; while [ -n "$P" ] && [ "$P" -gt 1 ] 2>/dev/null; do ps -o pid=,comm= -p "$P" || break; P=$(ps -o ppid= -p "$P" | tr -d ' '); done
```

⚠️ **An empty walk is an answer, not a failure**: a process started by launchd has no ancestor to
name and is its own responsible process — which is exactly what `cua-driver` reports about itself
above (`"responsible_ppid": 1`). The walk names an inherited identity; it cannot name a self-owned one.

Measured 2026-08-07 from a Claude Code session whose walk came back
`zsh ← claude ← Elliot.app/Contents/MacOS/Elliot` — an agent run **Elliot itself spawned**, so
Elliot's grants are the ones in force, and Elliot holds neither:

| What you want | Command | Answer under that identity |
|---|---|---|
| activate an app | `set frontmost of (first process whose unix id is <pid>) to true` | **works** — exit 0, and a readback confirms it really activated |
| name a process | `get name of first process whose unix id is <pid>` | **works** — and is **no evidence at all** about Accessibility |
| read a UI element | `get {position, size} of window 1` | ⛔ `-1719` *not allowed assistive access* |
| enumerate menus | `get name of every menu bar item of menu bar 1` | ⛔ `-1719` *not allowed assistive access* |
| synthetic click | `click at {x, y}` | ⛔ `-25211` *not allowed assistive access* |
| synthetic key press | `keystroke "a"` · `key code 53` | ⛔ `1002` *not allowed to send keystrokes* |
| a **real** mouse click | `swift Scripts/realclick.swift <x> <y>` | **exit 0, in silence — and it did not arrive** |
| window geometry | `CGWindowListCopyWindowInfo` | geometry **yes**; every `title` comes back **empty** |
| capture a window | `screencapture -o -l<id>` | ⛔ `could not create image from window`, exit 1 |
| capture the display | `screencapture -x` | ⛔ `could not create image from display`, exit 1 |
| photograph Elliot | `board_screenshot` over MCP | **works** — 1510×925, `source: live`, no grant involved |

⚠️ **Two rows of that table are the trap, and one of them nearly wrote itself into this file.**
`get name of … process` answered `Elliot` cleanly, which reads exactly like Accessibility being on;
process enumeration simply is not gated, and every *UI* read one line later returned `-1719`. Likewise
`set frontmost` succeeds, so the committed recipe below **starts working and then fails**. A channel
that answers is evidence about that channel and nothing else — probe the capability you actually need.

⚠️ **A key press that does not arrive means "could not act", never "the app ignored it".** Ungranted
it at least says so — `1002`, its own error code, distinct from the `-1719`/`-25211` pair, so a
keyboard failure is diagnosable rather than mysterious. That is the exception, and `realclick.swift`
was the rule until #161: it posted a `CGEvent` and exited **0 having delivered nothing**, because
`CGEventPost` returns no receipt. It now refuses by name (`AXIsProcessTrusted`, exit 77). The blank
`title` fields are the same silence one layer over — geometry arrives, names are withheld.

⛔ **And the grant is not the end of it: keys have been measured to go missing from a shell that
*held* both grants.** #161's pass, same machine, same day, from a different identity: synthetic
**clicks** landed and each had its effect, while ⌘F-then-type left a search field on its placeholder
and Escape did not deselect — with the app frontmost by pid. So clicks working is **no evidence** that
keys do. This matters for `Scripts/probe-deselect.sh`, whose set-up drives `key code 125/124` to pick
a card: if that returns `exit 3 nothing selected after ↓`, suspect the keystroke before you suspect
the board. **Establish delivery on the channel you are about to rely on** — a claim about a gesture
built on an event that never arrived is a claim about your permissions.

✅ **What still works with neither grant is `board_screenshot` (#155)**, because Elliot renders its own
hierarchy in-process and TCC is never consulted. In the same minute that `screencapture -o -l5600`
refused, `board_screenshot` returned that very window — id `5600`, 1510×925 both times — at full size,
`source: live`. Reach for it first and treat the shell recipes as the fallback. Read its
`not_included` before concluding something is missing — and note its own aiming hazard, recorded at
length below: the helper resolves its socket through `ELLIOT_HOME`, so one registered against the
default home photographs **your everyday board** while you review a worktree branch, and the picture
looks perfectly correct. Free of TCC is not free of targeting.

**Window ids and geometry survive without Screen Recording too — only the names are withheld**, which
is a second grant-independent way to look. `Scripts/list-windows.swift` is that enumeration,
committed rather than retyped, with the three corrections below in its own header:

```bash
ps -eo pid,command | grep 'MacOS/Elliot$' | grep -v grep   # the pid you want
swift Scripts/list-windows.swift <pid>                     # omit <pid> for every app's windows
```

⛔ **Use that `ps` line, not `pgrep -f` — and the reason is this section's own thesis.** Measured
2026-08-07 from an Elliot-spawned shell, `pgrep -f 'Elliot.app/Contents/MacOS/Elliot'` returns
**nothing** while `pgrep -a -f …` returns `45434`. It is *not* that GUI apps are invisible —
`pgrep -f 'Arc.app/Contents/MacOS/Arc'` finds Arc from the same shell. `man pgrep`: `-a` "Include
process ancestors in the match list. By default, the current pgrep or pkill process and all of its
ancestors are excluded." **Elliot is excluded because Elliot is your ancestor** — the same fact that
decides your grants also hides the app from your process search, and it answers with the wrong pids
rather than failing. (An earlier draft of this very paragraph blamed LaunchServices; that was wrong,
and code review caught it.)

⛔ **Do not filter on `is_on_screen`** — that is the trap recorded above, and it is why "the window
didn't open" got written down nine times. ⚠️ **And do not read an empty `title` as an unnamed
window**: without Screen Recording every name is blank while the geometry is perfect — a list that
looks complete and is wrong in one column. The script says so itself rather than letting you misread
it. **Disambiguate by size**, since the designed sizes are distinct: board ~1510×925, Preflight
820×720, Repositories 900×700, and a 1728×33 row is a titlebar shim rather than a window.

⚠️ **A window id is not yet a readable picture.** If you do hold Screen Recording and feed one of
these ids to `screencapture -l`, a window whose app is not frontmost is parked in the Stage Manager
strip at ~143×160 and **nothing in it can be read as text** — which renders as "the board came back
143×164", the #74 misreading the paragraph above exists to correct. Activate the pid first, or use
`board_screenshot`, which draws the window at its designed size regardless.

⚠️ **The same commands answered differently earlier the same day, and why is UNMEASURED.** #161 found
menu enumeration, window capture and clicks all working; hours later, every one of them refused. Two
explanations fit and neither has been tested: a different responsible process (that pass recorded no
ancestry walk — the walk is what #161 added), or **the grant being destroyed by a rebuild**, since
`Scripts/build-app.sh` does `rm -rf "$APP"` then `codesign --force --sign -`, and an ad-hoc signature
over a deleted-and-recreated bundle is a new TCC subject. Do not repeat either as the cause: writing
an inferred mechanism down as a measured one is the mistake this whole section is about, and it has
already cost this file one wrong `pgrep` explanation and one wrong #140 diagnosis. **Re-run the two
preflights rather than trusting this table**; what is durable is the method, not the booleans.

**To get a grant, grant it to the identity the walk named** — `cua-driver permissions grant` only ever
settles the daemon, so it does nothing for an agent shell whose ancestor is Elliot; that one needs
*Elliot.app* ticked under System Settings ▸ Privacy & Security ▸ Accessibility (and Screen Recording
for capture). Two things make that less simple than it sounds:

- ⛔ **It grants far more than a verification pass.** Elliot spawns unattended `claude -p` runs at `bypassPermissions`, and each inherits Elliot as its responsible process — so ticking that box lets **every** future run post synthetic clicks and keystrokes into any application and read any app's accessibility tree. That is a standing capability bought for one afternoon of looking; decide it deliberately, and prefer `board_screenshot` when it will do.
- ⚠️ **It expires the next time you build.** `build-app.sh` deletes and re-ad-hoc-signs the bundle, so the grant you just ticked is dropped by the very command this file tells you to run before a look-at-the-app pass — silently, back to `-1719`. And *three* Elliots are routinely on disk at different worktree paths; each is its own TCC subject, so tick the bundle you are actually going to launch.

Until then, anything needing a click, a key or a `screencapture` is **not verifiable from here** —
a reason to reach for `board_screenshot` and the structural tests, not a reason to assert the change
works.

Recognise the shape rather than the tool, because it keeps recurring in this project: **a permission
that silently changes behaviour instead of erroring.** A blank accessibility tree that reads as an
empty window; a `cua-driver` click reporting `unverifiable` rather than failing (#48: `press_key`
returns `"escalation": {"reason": "delivery_failed"}` and the screenshot afterwards is byte-for-byte
the same board); a screen-recording grant that is simply absent while the commands still return;
`gh secret list` omitting organisation secrets; an accessibility press wearing the name `click`; and
now `CGEventPost` exiting 0 on an event nobody received, next to window titles blanked in a list that
otherwise looks complete. Not one of them says *no*. The count is a floor, not a tally — do not spend
a merge reconciling it.

**Seeding the scratch store: the ids are `UUID`s, and a wrong one wedges the board silently.**
`Repo.id` and `Card.id` are `UUID`, not free text. Insert `'sandbox'` as a repo id and the app starts,
paints its chrome, and sits on **"Still starting"** for ever while the status bar underneath reads
**"Ready."** — because the repo observation's `catch` swallows the decode error without a banner
(`ElliotAppKit/AppModel.swift`, the `hasLoadedRepos` observation). Same store, same build, id swapped
for `uuidgen` output: the five columns render immediately. So:

```bash
RID=$(uuidgen)   # and a fresh uuidgen for every card id too
sqlite3 "$ELLIOT_HOME/elliot.sqlite" "INSERT INTO repo (id,path,…) VALUES ('$RID','/tmp/sandbox',…);"
sqlite3 "$ELLIOT_HOME/elliot.sqlite" "PRAGMA wal_checkpoint(TRUNCATE);"
```

Point the seeded repo at a throwaway `git init` directory, not one of Philippe's checkouts: the cards
then render "Repository blocked — see Preflight", which is the state you want for a look-only pass
because no transition can spawn an agent from it. Leave **To Do** and **In Progress** empty if you
want to exercise the "arrows skip empty columns" rule.

### Board transitions

| From → To | What happens |
|---|---|
| Backlog → To Do | `/ai-migration-kit:create-issue <story>` (+ repeatable `--label`) — fills in the issue number |
| To Do → In Progress | `/ai-migration-kit:implement-issue <n>` — fills in the PR number and branch |
| In Progress → In Review | *no skill* — a system move, when `PRWatcher` sees the PR go ready |
| In Review → Done | `/ai-migration-kit:merge-pr <pr>` (+ repeatable `--follow-up`) |
| anything else | nothing |

The backlog holds **user stories** (`role` / `want` / `benefit` + acceptance criteria as separate
fields), not loose prose. A card is editable up to the moment it carries an issue number; after that
`updateCard` refuses rather than letting card and issue drift.

**A card also names the GitHub labels its issue should carry** (#171), chosen from the repository's
own list through `gh label list`, pre-filled from the analysis lens for the three that honestly imply
one (`bugs → bug`, `features → enhancement`, `docsAndDX → documentation`; the other five suggest
nothing rather than guessing). Empty is the common path and emits no flag at all — pinned byte for
byte, because the whole of `create-issue`'s existing behaviour rides on it.

⛔ **`--label` is an instruction to a reader, not a flag to a parser — do not describe it as one.**
Measured against ai-migration-kit 1.9.0 while landing #171: `merge-pr`'s SKILL.md carries an
*Arguments* section naming `--follow-up "<idea>"` as optional and repeatable, and **`create-issue`
carries no such section at all** — it says only *"pull the idea(s) from the user's request"* and then
**chooses labels itself**, reading the live set and picking one per axis from the profile's taxonomy.
Every `--label` inside that skill is its own `gh issue create` call, not an input it parses. So an
agent will very likely honour the suffix and nothing obliges it to, which is exactly why the card is
the record of the *intent* and `gh` remains the record of the *outcome*. The durable fix is an
*Arguments* section in `create-issue`, in another repository; a second channel invented here would
just be a second way for the two to disagree.

⚠️ **A non-optional field added to `Card` breaks `openReadOnly`'s whole reason for existing, and the
compiler will not say so.** Swift's synthesised decoder **ignores a property's default value** — it
emits `decode(_:forKey:)`, not `decodeIfPresent` — so `public var labels: [String] = []` throws
`keyNotFound` on every card in a database that predates the column. `BoardStore.openReadOnly`
*deliberately* accepts a database older than the code reading it, so the MCP helper keeps answering
between a new bundle landing and the app next launching, and that tolerance is written for added
columns *which are supposed to read as absent*. `OlderDatabaseTests` caught it on the first full run;
the fix is `@DefaultsToEmpty` (`ElliotModel/DefaultsToEmpty.swift`), a wrapper whose one job is to
turn the synthesised call into `decodeIfPresent`. **A new non-optional field on a persisted model
needs it, or an `Optional`.**

### The two panels

The board's row is `PanelLayout.boardOrder(selected:analysisOpen:)`: five columns, plus up to two
panels. `.analysis` is pinned **first**, before Backlog, because that is where what it produces
lands; `.panel` sits beside the selected card's column. Both are measured in board columns by the
same `PanelLayout.panelWidth`, both snap between two and three spans through the same
`PanelLayout.snappedSpans`, and both are grabbed by the one `PanelResizeHandle` — a second copy of
that strip would be a second copy of the four fixes written into it.

`PanelLayout.slotWidth` exists because a two-way `slot == .panel ? panelWidth : columnWidth` ternary
stays type-correct when a third slot kind appears and silently measures the new one as a column.

**Hiding the analysis panel is not closing the analysis.** `showingAnalysisPanel` is view state;
`closeAnalysis()` drops the `AnalysisSession`, and `ObservationHandle.deinit` cancels the live
proposal observation with it — so a toggle that called it would stop proposals landing while eight
lenses were still reading. Only *Finish* ends a session. The detail panel has no such distinction,
which is why the analysis needed its own rule rather than a copy of `showingInspector`.

⚠️ **Hiding also destroys the view, so nothing the reader has typed may be `@State` in it.** Hiding
removes `.analysis` from `boardOrder`, which tears `AnalysisPanelView` down. The lens set, the extra
instructions, the story limit and the staged proposal selection therefore live on `AppModel`
(`analysisAngles`, `analysisInstructions`, `analysisMaxStories`, `analysisSelection`) — as `@State`
they made the hide lossy in exactly the way this feature's own prose says it is not, and the test
that "proved" the hide was safe only ever looked at `analysis`, the half that already lived on the
model.

⚠️ **An analysis must not start in a repository Preflight refused, and `AnalysisService` will not
stop it.** `start` checks `isEnabled` and the in-flight dedupe and nothing else, so the gate lives in
`AppModel.analysisRefusal` — one sentence read by both the toolbar tooltip and the panel's footer,
and the value the Start button is disabled by. It used to be a `.disabled(…)` on the toolbar button;
#151 removed that (a toggle you cannot switch off is worse than one that opens onto an explanation)
and very nearly removed the gate with it.

⛔ **The analysis panel's *Start* button carries no `.keyboardShortcut(.defaultAction)`.** It did as a
`Window` scene, where Return was scoped to it. As a sibling in the board window it would share Return
with `DetailPanelView`'s Save, with nothing in the code deciding between them — and the claimant here
spawns up to eight unattended runs.

⚠️ **This said "the analysis *panel* carries no `.defaultAction`" until #247, and that was false** —
`ProposalEditor`'s Save has one, and always did. The error mattered in the direction it pointed: it
made the Return problem read as already solved, while two claimants that **co-reside by design** sat
on the same card. `PanelLayout.headerRegions` returns `[.mergeConfirmation]` and only *then* runs
`guard !isEditing else { return regions }`, so on a card imported from a pull request that closes no
issue — `issueNumber == nil` shows "Edit story", `prNumber != nil` arms a merge — Return resolved
between saving an edit and **merging to a default branch on github.com**. `swift test` cannot press a
key, so nothing failed and nothing could have.

Since #247 the rule lives in code with a gate: **`.keyboardShortcut(.defaultAction)` may be claimed
only by a control that commits text the reader has typed.** `DefaultAction` (`ElliotAppKit`) lists the
three sanctioned claimants and the two deliberately denied; `DefaultActionTests` reads the source,
attributes every claim to its button's label, and fails naming the file when one is unsanctioned,
miscounted, in the wrong file, or unattributable. `Merge PR` lost its claim outright rather than being
scoped better — the one act that cannot be taken back must be reached by pressing it. Verified by
reintroducing the defect and watching all four checks go red.

Opening the analysis panel scrolls the board to its leading edge
(`BoardFraming.offsetX(from:boardWidth:)`), because a panel the reader just asked for that lands
off-screen reads as a panel that did not open — the same false negative that got written down nine
times about the window scenes.

#### The detail panel

Selecting a card opens `DetailPanelView` **between the columns**, inserted immediately after the
card's own column — or before it for the last column, which has no right — two or three column-widths
wide, tethered to the card by a 2pt rail ending in a caret notched out of the panel's edge. It is a
plain sibling in the board's `HStack`, never `.inspector()`; that API shipped three times here and
wrecked the window three times (#47, #50, #52, #53).

The arithmetic is pure and pinned by `PanelLayoutTests`: `PanelLayout` decides the widths, which slot
the panel takes, which column opens left, where the caret sits and when it detaches. Nothing about
the layout is decided in a view, because `swift test` cannot see a view. The caret's *position* is
the exception and is measured, not computed — a card's Y inside a `LazyVStack` is not knowable ahead
of layout — so it comes from `.anchorPreference(.bounds)` resolved in a single overlay, which puts
card, list and panel in one coordinate space by construction.

**Every writer of `CaretAnchorKey` must be a *sibling* of the others — #159.** `reduce` merges
sibling subtrees and is the whole defence for the three-anchor design; it is **no defence one level
up**, because `.anchorPreference` applied to a view that is an *ancestor* of another writer
**replaces** that writer's value outright and `reduce` is never called for the pair. `ColumnView.list`
was that ancestor: it wrote `list` on the `ScrollView` holding the cards, so the selected card's
rectangle was discarded one level below the overlay. It reports through a `.background` now — a
separate subtree, so the card's contribution is never in a position to be replaced.

What that cost is the lesson worth keeping, and it is not "test the arithmetic": **the arithmetic
was pure, extracted, and tested, and the decoration still never appeared.** With `card` nil,
`isDetached` returns true on its first `guard`, so the tether drew at opacity 0 and the caret at 0.35
against `panel.midY` — a *truthful* rendering of a false input. Nothing was wrong with any function
`PanelLayoutTests` pins; they were being fed `nil`. The step between the three writers and the one
reader had no test and no measurement, which is precisely the gap `PanelLayout`'s own extraction
created and then hid: everything either side of it was green, so intuition had nothing to push
against.

`CaretAnchorTests` closes it, and its shape is the transferable part. Five tests drive a
board-shaped hierarchy through a real layout pass (`ImageRenderer` — no window, no store, no running
app) and assert the anchors arrive; a sixth **reads `BoardView.swift`** the way
`DrainDuplicationTests` reads its sources. That last one is not belt-and-braces: reverting the fix
leaves all five behavioural tests green, because they build a *miniature* and so prove the rule
rather than the board. Verified by actually reverting it. **When a test builds its own model of the
code, ask what it would say if the code changed underneath it** — and if the honest answer is
"nothing", the shape needs pinning where the shape lives.

Inside, the GitHub issue body is parsed by `IssueMarkdownParser` (`ElliotModel`, no dependencies,
total — it never drops a line) into blocks that each get their own view, and a run's log is folded by
`RunLog.rows` back into the tree it was flattened from: a `tool_result` attaches to its `tool_use`
**by id, never by arrival order**. The verdict block is the app's central invariant made visible —
what the agent *said* in demoted italic (`Type.hearsay`), what `gh` *established* in the fact face,
never the same tier.

##### Watching the caret's anchors arrive

When the caret or the tether is wrong, the question is almost never the arithmetic — that is
`PanelLayout`'s and it is pinned by `PanelLayoutTests`. It is which of the three anchors reached the
overlay. Make that observable by writing the three flags from inside the `.overlayPreferenceValue`
closure in `BoardView.board`:

```swift
.overlayPreferenceValue(CaretAnchorKey.self) { anchors in
    let _ = {
        let line = "card:\(anchors.card != nil) list:\(anchors.list != nil) panel:\(anchors.panel != nil)\n"
        let url = URL(fileURLWithPath: "/tmp/caret-probe.log")
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
        } else {
            try? Data(line.utf8).write(to: url)
        }
    }()
    CaretRail(anchors: anchors, flipped: isPanelFlipped)
}
```

Inside the `ViewBuilder`, not in `.onAppear` — the latter fires once, and what you want is a reading
per re-evaluation. **To a file, not to `Logger`**: `.debug` is not persisted at all, and on
2026-08-07 nothing from `subsystem == "dev.phmatray.elliot"` reached `log show` at *any* level, so a
diagnosis planned around that command silently produces no output rather than an error.

Then drive it against a scratch store (see the seeding recipe above) and read the file after
selecting a card in Backlog, in Done, and with the analysis panel open.

**Prefer `board_screenshot` (#155) when it is pointed at the right app** — it renders a named window
from Elliot's own hierarchy, so none of the aiming problems below arise. The catch is which Elliot
answers: the MCP helper finds its socket through `ELLIOT_HOME`, so a helper registered against the
default home talks to *your everyday board*, not the scratch instance you just launched. For a
look-at-my-branch pass that is the wrong target, and it fails by returning a perfectly good
screenshot of the wrong app. Either register a helper for the scratch home or capture by pid, below.

⚠️ **Three Elliots are routinely running** — this worktree's, another worktree's, and the main
checkout's. `screencapture -R <region>` captures a *screen region*, so it returns whichever window is
frontmost there: it can hand you a different Elliot's board, showing "No repository yet", while your
seeded one renders perfectly. **A region is not a window** — the "target by `unix id`, never by name"
rule applies to screenshots too. Activate the pid first, then capture:

```bash
MINE=$(ps -eo pid,command | grep '<your-worktree>/dist/Elliot.app/Contents/MacOS/Elliot' | grep -v grep | awk '{print $1}')
osascript -e "tell application \"System Events\" to set frontmost of (first process whose unix id is $MINE) to true"
osascript -e "tell application \"System Events\" to tell (first process whose unix id is $MINE) to get {position, size} of window 1"
/usr/sbin/screencapture -x -R <x>,<y>,<w>,<h> /tmp/board.png
```

⛔ **"The shell holds Accessibility even when the `cua-driver` daemon does not" — that is what this
paragraph said, and it is not true of an agent's shell.** Measured 2026-08-08 from a `claude -p` run
(#132), which is how most verification passes in this repository are actually driven:

| probe | answer |
|---|---|
| `cua-driver permissions status --json` | `accessibility: false`, `screen_recording: false` |
| `osascript … to keystroke "q" using command down` | `execution error: osascript is not allowed to send keystrokes. (1002)` |
| `osascript … to get {position, size} of window 1` | `execution error: osascript is not allowed assistive access. (-1719)` |
| `osascript … to count of UI elements of window 1` | same, `-1719` |
| `/usr/sbin/screencapture -x` | `could not create image from display`, exit 1, no file |

So **every command in the recipe above fails for an agent**, and with it the whole chain: no keystroke,
no AX read, no window position — and without a window position there is no coordinate to aim
`Scripts/realclick.swift` at, so the real-`CGEvent` path is out too even though it needs only
Accessibility. An interactive Terminal that has been granted the box is a different TCC identity from
the one a spawned agent runs under; the claim was probably true where it was written and does not
transfer. **The grant belongs to whoever is asking — measure it in the session you are in, not from
this file.**

Re-measured in a separate session on the same day (#162): all five answers identical, plus
`osascript … to click at {x, y}` → `-25200`. Two sessions is not a guarantee about the next one — the
sentence above still stands — but it does mean an agent should *plan* for no grant rather than
discover it, which is what #162 did after building a bundle and seeding a store.

The one thing that still works with no grant at all is **`board_screenshot`** (#155), because Elliot
renders its own hierarchy in-process. Aiming it at a scratch instance rather than the everyday board
does not need a second registered helper either — spawn `elliot-mcp` yourself with the home set and
speak JSON-RPC at its stdin (`initialize` → `notifications/initialized` → `tools/call`):
`ELLIOT_HOME=/tmp/elliot-check dist/Elliot.app/Contents/MacOS/elliot-mcp`. The reply carries
`png_path` at full resolution, inside that home's `screenshots/`. What it cannot do is *act*, so a
check that needs a card selected still needs a person or a grant.

⚠️ `screencapture` **erroring** rather than handing back a black frame is worth noting on its own: it
is the one member of this file's false-negative family that actually says no — `-x` gives
`could not create image from display` and `-l<windowid>` gives `could not create image from window`.
Both are the missing grant, so capture-by-window-id is **not** a fallback either.

⛔ **Do not read `screencapture`'s short usage line as its option list.** `usage: screencapture
[-icMPmwsWxSCUtoa] [files]` omits `-l`, and a bare `-l` answers `illegal option -- l` because it wants
an argument — between them those two outputs read exactly like "this macOS has no such flag", which is
what got written here for one commit and what code review caught. `screencapture --help` lists
`-l<windowid> capture this windowsid` plainly. **An option that needs an argument reports its absence
the same way an unknown option does**; check `--help` before concluding a flag does not exist.

⚠️ **The recipe's *first* line works either way, which is what makes the rest look like an app
problem.** `set frontmost` is not gated, so it succeeds under any identity while the two lines after
it fail — measured 2026-08-07 from an Elliot-spawned agent shell, where both were refused. Check
`AXIsProcessTrusted()` / `CGPreflightScreenCaptureAccess()` before reading a failure here as a fact
about the app.

⛔ **And the two channels fail separately, so a landed click is no evidence a keystroke will arrive.**
In the one pass measured from a shell holding **both** grants, clicks landed and keystrokes did not
arrive at all — ⌘F-then-type left the field on its placeholder, and Escape did not deselect, with the
app frontmost by pid. So do not assume `key code 53` is Escape just because the click worked: verify
the channel you actually depend on. (And read the ⛔ above on `click at {x, y}` being an accessibility
**press** rather than a mouse click — that is a third way this recipe misleads.)

One more false negative to know: `entire contents` of the window can return **empty** while
`count of UI elements` returns 6. An empty AX dump is not an empty window.

### Run lifecycle

`is_error` is not enough: a run only counts as clean when `permission_denials` is empty too — a run can
end `subtype: "success"` having been refused a tool and quietly worked around the gap.

There is no wall-clock kill (`merge-pr` waiting hours on CI is legitimate). What is actionable is
**silence**: 20 minutes without output marks the run stalled and asks. Cancellation is a plain SIGTERM —
Claude Code handles it, aborts the turn, kills its Bash process tree, runs SessionEnd hooks, exits 143.

Runs default to `--permission-mode bypassPermissions`; `permissionMode` is a per-repo column if you want
to tighten one.

### Artefact retention

`runs/`, `screenshots/` and `analyses/` are bounded since #167, by one pure rule applied once per
launch. **Keep everything younger than 14 days; past that keep newest-first until 512 MB per
directory and delete the rest** (`ArtifactRetention`, `ElliotModel`). The ceiling budgets the
*remainder past the horizon*, not the directory total — young files are kept unconditionally and are
not counted against it, so the honest bound is "a fortnight of writing, plus 512 MB".

`ArtifactSweeper` (`ElliotEngine`, an `actor`) lists, asks and unlinks; it decides nothing.
`AppModel.start()` runs it in a detached `Task` after the reconciler's sweep — the runs that sweep
just marked failed are exactly the ones whose logs stop being protected, so reading the table ahead
of it reads it one state behind.

⛔ **The result is recorded on `artifactSweep`, never written into `status`, and the status bar
renders a figure from there.** Appending to `status` was the first attempt and it is unfixable by
placement: the task shares the main actor with `start()`, so it resumes at the next suspension —
which is `importIfNeeded`'s `await importer.importRepo(repo)`, whose very next statement assigns
`status`. The sentence was destroyed within milliseconds on every launch that had one, and nothing
else read the report, so it left no trace. `status` is a single narration owned by whoever spoke
last; a fact that has to survive needs a field of its own. Code review caught this after the
placement comment had already claimed to prevent it — **a comment asserting a race is closed is not
a measurement that it is.**

⛔ **Protection is a string comparison between two paths built by different code, so both sides go
through `StoreLocation.canonicalPath`.** `FileManager`'s enumerator returns **symlink-resolved** URLs
and `runLogURL` does not; on macOS `/tmp` is a symlink to `/private/tmp`, and `/tmp/elliot-check` is
the scratch home this very file recommends. Measured while writing #167: `/var/folders/…` in, `/private/var/folders/…`
out. Compare raw and the membership test silently stops matching, and the sweep deletes the log of a
run still in flight — **failing open**, with nothing on screen. Same family as the false negatives
this file already collects: nothing says *no*.

⛔ **No protected set, no sweep.** The tempting `?? []` on a failed read of the runs table turns "I
could not find out which runs are live" into "no run is live". A failure to read the board is a
reason not to touch the disk.

Verified on the shipped build, not inferred: a copy of the real `runs/` (754 files, 73 MB, all
written within three days) went in and **754 came out** — the intended answer, since a retention rule
whose first run deletes something gets reverted. Then, on the same binary with **no constant
patched**, eight aged copies stacked past the ceiling: 6 032 files in, **872 removed**, leaving
536,375,870 bytes against the 536,870,912 ceiling, and the status bar read `872 pruned`. A clean home
in the same build shows no such figure at all — both directions of the conditional looked at, because
a new element in that strip is a layout change and `swift test` cannot see one.

⚠️ Driving the horizon to zero is *not* what proved it deletes; ageing real copies past the shipped
horizon and ceiling did, which is the stronger claim — a patched binary proves things about a binary
nobody ships. Note also that the numbers move between runs because the source directory is live: the
same experiment an hour earlier removed 523 files, because `runs/` had grown from 73.1 to 78.3 MB in
between. **The invariant to check is remaining ≤ ceiling, never the file count.**

The cut lands mid-copy because the rule cuts at the **file** that would overflow, and the files
inside one copy share an mtime — which is the path tie-break earning its place on real data rather
than in a unit test.

## Testing discipline

`swift test` must be **deterministic and always-terminating**. Three rules keep it that way; breaking any
reintroduces the bug where a wedged child held the SwiftPM build lock for a quarter of an hour and
presented as a broken toolchain rather than a stuck test.

- **Every async wait is bounded**, through `withTimeout` in the test-only `TestSupport` target. An
  unbounded `for await …` is how one hung child stopped `swift test` from ever exiting.
- **`Scripts/fake-claude.sh` traps in every mode**, installing the trap before anything else, so no child
  outlives its parent holding the runner's stdout pipe open. It touches `FAKE_CLAUDE_READY` once
  trap-protected.
- **No assertion measures an absolute duration**, and no test sleeps a fixed interval waiting for a child
  — it waits on that file. Wall-clock assertions fail under load while the code behaved perfectly.

The matching rule in production code: **nothing waits on `Process.waitUntilExit()`**. Both spawners
publish the exit from `terminationHandler` under one lock (`StreamingProcess.waitForExit`,
`ProcessRunner.run`); `waitUntilExit()` spins a run loop waiting for a notification a concurrently-spawned
sibling can consume first.

**One green run does not clear a suite — sample it, because sampling is nearly free.** The clean build
costs ~21–45 s, the test execution ~1.5–2.9 s, so five samples after one build cost about eight
seconds. A single sample cannot detect an intermittent regression, and that is how a defect failing
53 % of the time reached `main` past **21 single-sample merges**. Repetition alone is not the whole
answer either: one flake was 1-in-13 idle and 6-in-10 under load, so sample under load where you can.

**`ClaudeRun.updates` is deliberately lossy — never assert an exact count on it.** It is
`AsyncStream(bufferingPolicy: .bufferingNewest(512))` (`ClaudeRunner.swift:136`), and the streaming
commit says so at the seam: *the UI stream is bounded and may drop, this never does*. **The log file
is the lossless sink** — raw bytes reach it before parsing — so a count is asserted against the log.
Measured over 10 full-suite runs: the exact-count assertion on the stream failed **9/10**, the same
assertion on the log **0/10** (#128). ⛔ The tempting repair is `.unbounded`, which turns the test
green and reintroduces unbounded memory growth on a long run — precisely what the file sink exists to
prevent.

The end-to-end suite drives the real stack — rule engine, scheduler, actual process spawn, stream parsing,
log writing, cancellation, launch sweep — against `Scripts/fake-claude.sh`, driven by
`FAKE_CLAUDE_FIXTURE`, `_DELAY_MS`, `_MODE=hang|trap|crash`, `_ARGV_OUT`, `_STDERR`, `_READY`. Fixtures
live at `Fixtures/` (repository root, not a resource bundle) so the same files are usable by hand from a
terminal when reproducing a run.

**`gh` is fakeable the same way, and cheaper.** `Scripts/fake-gh.sh` answers `issue list` and `pr list`
from `Fixtures/gh/*.json`, driven by `FAKE_GH_ISSUES`, `FAKE_GH_PRS`, `FAKE_GH_MODE=ok|fail`,
`FAKE_GH_FAIL_REPO`, `FAKE_GH_EXIT`, `FAKE_GH_ARGV_OUT`. `GHClient` spawns `ToolConfig.ghPath`, so pointing that at the
script is the entire seam — no protocol, no production change, and the **real** subprocess and the
**real** ISO-8601 decode stay under test. Anything other than those two subcommands exits 64 on
purpose: an unexpected call must fail loudly, because returning an empty list would look exactly like a
repository with no open work.

`FAKE_GH_FAIL_REPO` fails for one `--repo` value and answers normally for the rest. That exists because
`importAll` shares one `GHClient` across a pass, so a blanket `FAKE_GH_MODE=fail` can only show that
*everything* failed — and the claim worth testing is that an unreachable repository does not cost a
healthy one its refresh.

> Do not conclude that a `gh`-backed path is untestable and relegate it to a manual pass — that is what
> #40 did, and it left three of #17's acceptance criteria unproven until #41. There is no ready-file
> and no delay in this fake, and that is not an oversight: it prints and exits, so a test has nothing
> to wait for.

Two invariants carry most of the weight:
- the first digit run of an `implement-issue` prompt is the issue number, because the skill resolves its
  argument with `grep -oE '[0-9]+' | head -1`;
- a system-originated move never triggers a skill.

## Things that bite

- **`UNUserNotificationCenter.current()` raises without a bundle identifier — it does not return
  nil.** So the guard is in `makeNotificationDelivery()`, *before* the centre is touched, and
  `swift run ElliotApp` / `swift test` get `NoDelivery`. Testing notifications means launching
  `dist/Elliot.app` from the Finder, exactly like preflight.
- **A notification API that is refused does not say `denied`.** Measured on a probe bundle signed the
  way `build-app.sh` signs Elliot: from `/private/tmp`, `requestAuthorization` and `add` both failed
  with `UNErrorDomain` Code 1 *"Notifications are not allowed for this application"*, nothing was
  delivered, and `authorizationStatus` stayed **`notDetermined`** — not `denied`. From
  `~/Applications` and from the repo's own `dist/`, the same binary was granted and delivered. **Ad-hoc
  signing is not the blocker; location is.** Anything reporting authorization must therefore report the
  *outcome of the last call*, not just the status, or it promises a question that will never be asked
  again while every notification fails silently. Same family as `gh secret list` omitting org secrets.

- **A stale `.build` fails in ways that look like real breakage — wipe it before believing the
  failure.** Merging `main` is one trigger, not the only one: **any `git checkout` that moves a
  worktree across commits** can leave new sources against stale objects, and agent branches do both
  all day. A run made in that state is not a measurement. Measured four times, on branches that could
  not have caused any of them:
  - **Wrong values.** Three `RepoRegistryServiceSyncTests` failed *deterministically* while the identical commit passed in a fresh checkout. The tell was swift-testing printing the literal `.dirty` as `.unlisted` — an enum ordinal from before the merge. If a source literal reports as a different case, nothing is wrong with the code.
  - **A link error.** `ld: symbol(s) not found` for `ProcessRunner.run(…timeout:)`, referenced from test objects compiled against the pre-merge signature.
  - **A SIGBUS**, signal 10, charged to an innocent pull request.
  - **Three test failures that did not exist**, and a confident bisect on top of them that convicted an innocent commit.

  All four cleared instantly with `rm -rf ElliotKit/.build`. **The tell is an assertion that could not
  have failed** — `(x → nil) == nil` cannot fail for a single optional. When the reported failure is
  impossible, you are reading a stale binary, not a defect, and anything built on top of it (a bisect
  above all) is reading it too.

  The intermittent signal 10/11 abort is a *different* thing and also real: it aborts the run
  reporting **no failing test**, and a re-run clears it. But since staleness can present as a signal
  too, a signal after a checkout is ambiguous — wipe first, and only call it the intermittent abort
  once it survives a clean build. Named failing tests after a checkout: same order. Wipe, then look at
  your change.

  ⚠️ **A `git checkout` is not the only trigger — #171 hit it twice in a row with no checkout at
  all.** Adding an associated value to an existing enum case (`TriggerAction.createIssue` gaining
  `labels`) produced two consecutive signal 11s with no failing test named, in a worktree whose
  `.build` had never seen another commit. `rm -rf ElliotKit/.build` cleared it and four samples ran
  clean. So the rule is about **the shape of a type changing under objects that were not recompiled**,
  which a checkout is merely the commonest cause of; a same-branch edit to an enum's payload, a
  struct's stored properties, or a function's signature can do it on its own. The tell is unchanged —
  a failure that could not have happened — and so is the remedy.
- **A `ScrollView` that can scroll swallows taps a disabled one passes through.** The board's
  deselect-on-background-click fired by bubbling out of a column's empty space, and that only worked
  while five columns fit the window and scrolling was off. The detail panel widens the row past the
  viewport by design, so scrolling is now always on with it open — and clicking to deselect stopped
  working, in every column, with `swift build` clean and the whole suite green. The gesture lives on
  `ColumnView` now. Putting it on the row's background instead only moved the bug: that background
  also lies under the panel, so a click on the panel being read closed it. **An ancestor's tap fires
  for taps on its descendants, so any deselect above the panel is a deselect through it.**

  ⛔ **It was reported dead a fourth time in #158 — one nesting level further in, the column's own
  list swallowing what `ColumnView` never heard — and that report was an artefact of the tool.**
  `osascript -e 'tell application "System Events" to click at {x, y}'` is **not a mouse click**: it
  resolves the accessibility element at that point and *presses* it. So a view carrying
  `.accessibilityAction` answers while its `.onTapGesture` never runs — which is why clicking a
  **card** appeared to work, `CardView` having both — and a view carrying neither returns a
  thoroughly plausible descriptor and does nothing. The descriptor #158 quotes as the culprit,
  `scroll area 1 of scroll area 1 of group 1 of window Elliot`, is not a list eating a click; it is
  the nearest AX element to a press no view had an action for. Re-driven with a real `CGEvent`
  through `Scripts/realclick.swift`, the deselect cleared the selection in **every one of seven
  runs** against unmodified `main` — short column, scrollable column (content 894pt against a 748pt
  viewport, scroll bar and all), both panels open, both shut, the 6pt gap between two cards, the
  padding strip beside them, and the last column where the panel flips left. Five of those seven
  were instrumented, and all five named the `ColumnView` gesture; the other two ran against a
  pristine bundle carrying no instrumentation at all and agreed. **`Scripts/probe-deselect.sh` is
  that measurement, committed**, and it refuses a click that lands outside the window rather than
  reporting it, because a column scrolled out of view still publishes an off-screen frame.

  The general shape is the one catalogued under *Looking and touching are two different grants*
  above — **a mechanism that silently substitutes different behaviour instead of erroring** — and an
  accessibility press wearing the name `click` is a member of it. (The list lives there; this one
  used to keep a parallel tally of its own, and the two disagreed.) ⚠️ So before concluding that a
  **pointer** gesture is broken, check what your driver
  actually posts: `.onTapGesture` is invisible to AX, and the two paths into this app genuinely
  differ (that is the whole point of `CardView`'s `.accessibilityAction`, which exists because the
  tap gesture is unreachable from assistive technology).
- **`onChange` runs inside the update that changed the value, so it sees the layout as it was.**
  `BoardView.frame(...)` computed a scroll offset for the row that was *about to* include the panel
  and applied it to the row that still did not, where it clamped to zero — the board simply never
  moved. Deferred by one turn of the main actor. It was invisible in four of five columns, because
  those are the ones where the pair already fits: **when a layout change has a "last column" case,
  that is the case to check.**
- **Migrations are additive and shipped ones are frozen.** `ElliotStore/Migrations.swift` — append,
  renumber so versions stay ordered, never edit a migration that has run. `Column`'s raw values are
  persisted, so renaming a case needs a migration. A migration's **name** is its identity in
  `grdb_migrations`, so when two unmerged branches claim the same number, **the unshipped one moves**
  — whichever name reached `main` first keeps it, because renaming it would run a second, different
  migration on every database in the field. That happened twice in one day: a v6 and a v7 each had to
  shift after a differently-named v6 landed ahead of them. Each site in `Migrations.swift` records
  which trade it made.
- **Bump `elliotProtocolVersion` when the wire format changes** (`ElliotIPC/Protocol.swift`). An old
  helper in an old bundle meeting a newer app must fail loudly at `hello`, not halfway through a move.
- **`ElliotBuild.marketingVersion` is the single source of the version.** `Scripts/build-app.sh` `sed`s
  that line to stamp `CFBundleShortVersionString`; a plist naming a version the source does not is the
  one thing a field bug report is trusted on.
- **PATH is captured, never inherited.** Launched from the Finder the app sees only
  `/usr/bin:/bin:/usr/sbin:/sbin`. `LoginShellEnvironment.capture()` gets the real environment and
  `ToolLocator` finds `claude`/`gh`/`git`; anything spawning a tool must go through `ToolConfig`. Testing
  preflight means launching from the Finder, not from a terminal or Xcode. The consequence, measured in
  #188 and written up beside the launch recipe above: prepending a shim to `PATH` before `open` does not
  make that shim win.
- **A registered repo path must be the main checkout, never a linked worktree** — `merge-pr` tears down
  the PR's worktree and cannot do so from inside it. `GitClient.isMainCheckout` enforces this in Preflight.
- **The app is not sandboxed** (Hardened Runtime on, ad-hoc signed, not notarised). Child processes
  inherit the sandbox and security-scoped access does not extend to them, so a sandboxed `claude` could
  not write to `~/.claude` or reach your repositories.
- **`ELLIOT_HOME` overrides every path** (`StoreLocation`) — that is how tests and the fake-tool harness
  get an isolated store, socket and runs directory.
- **Several agent worktrees share this repo's `.git`.** Re-read `git rev-parse --abbrev-ref HEAD`
  immediately before committing and after pushing.

## Conventions

- Conventional Commits with the layer as scope: `feat(model|store|process|engine|ipc|mcp|app): subject`.
  Squash merge appends the PR number — `feat(app): … (#5) (#6)`. `main` is linear.
- Branches: `feat/<issue>-<slug>` · `fix/<issue>-<slug>`. The number must come first and be followed by
  `-` or `_` (`PRMatcher.branchMatches` anchors on it).
- Issues follow a de-facto template — `## User story` → `## Acceptance criteria` → `## Problem` →
  `## Proposed solution` → `## Area` (naming the SwiftPM targets) → collapsible `🧠 Brainstorm` /
  `📋 Spec` → visible `## 🛠️ Implementation plan`. There are no `priority:`/`effort:`/area labels; only
  GitHub's defaults exist.
- `.claude/skills/repo-profile.md` is the committed config the `create-issue` / `implement-issue` /
  `merge-pr` skills read (build commands, labels, conflict hot-spots). Refresh it when the toolchain,
  labels or CI change.
- Conflict hot-spots: `Package.swift`, `AppModel.swift`, `Migrations.swift`, `README.md` and test files
  are **union** merges; `Package.resolved` is **regenerated** (`swift package resolve`), never hand-merged.
