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
- Swift 6.1 tools-version, `swiftLanguageModes: [.v6]`, macOS 15+. Strict concurrency is on: every new
  type crossing an isolation boundary must be `Sendable`.
- **There is no CI.** No `.github/workflows/`, no branch protection. A pull request here is judged by a
  local `swift test` only — "wait for green CI" is not a thing that can happen in this repo.
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

**`ElliotMCPKit` imports neither `ElliotEngine` nor `ElliotProcess`** — deliberate, commented in
`Package.swift`. The helper holds no copy of the rules, so it cannot diverge from them.

**A system-originated move never triggers a skill.** `MoveContext.allowSideEffects == false` →
`.noAction`, checked before every other guard. The state a system move reacts to (a PR going ready, a
crash reconciled) was *produced* by a skill.

**`gh` is the fact; the agent's prose is a hint.** Nothing written back to a card is parsed out of a
run's closing summary. Issue and PR numbers come from `gh … --json` through `GHClient`/`Verifier`.
`PRMatcher` scores branches rather than looking one up, anchoring on `^<issue>-` *with* the trailing
hyphen so issue 4 cannot match `feat/47-…`.

**The app is the sole writer.** SQLite does not notify other processes of writes, so `elliot-mcp` opens
the store read-only and routes every mutation back over the unix socket. A read may fall back to
`source: offline-db`; a **write never falls back** — writing a column change straight to the database
would move a card without firing its rule.

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

**A secondary window is verifiable too — it opens off-screen, it does not fail to open.** Every PR
from #75 to #89 carried some version of *"opening a `Window` scene needs the app frontmost, which the
automation driver refuses"*, and it was never true. A background `openWindow` does open the window; it
just lands off-screen because the app is not frontmost. The trap is the enumeration, not the window:
**list all of a pid's windows, never only the ones reporting `is_on_screen`.** Measured on a running
build, six `Window` scenes declared in `ElliotApp.swift`, two of them open:

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

⚠️ **An empty accessibility tree is not an empty window.** Reading the tree needs the automation driver
to hold macOS Accessibility permission; without it every window of every app returns zero elements and
a `degraded` flag, which reads exactly like "the window has nothing in it" — the same false negative,
one layer down. Before believing a blank tree, snapshot a known-good app (Finder will do) as a control.
If that is blank too, the finding is about your permissions, not about the change under review.

### Board transitions

| From → To | What happens |
|---|---|
| Backlog → To Do | `/ai-migration-kit:create-issue <story>` — fills in the issue number |
| To Do → In Progress | `/ai-migration-kit:implement-issue <n>` — fills in the PR number and branch |
| In Progress → In Review | *no skill* — a system move, when `PRWatcher` sees the PR go ready |
| In Review → Done | `/ai-migration-kit:merge-pr <pr>` (+ repeatable `--follow-up`) |
| anything else | nothing |

The backlog holds **user stories** (`role` / `want` / `benefit` + acceptance criteria as separate
fields), not loose prose. A card is editable up to the moment it carries an issue number; after that
`updateCard` refuses rather than letting card and issue drift.

### The detail panel

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

Inside, the GitHub issue body is parsed by `IssueMarkdownParser` (`ElliotModel`, no dependencies,
total — it never drops a line) into blocks that each get their own view, and a run's log is folded by
`RunLog.rows` back into the tree it was flattened from: a `tool_result` attaches to its `tool_use`
**by id, never by arrival order**. The verdict block is the app's central invariant made visible —
what the agent *said* in demoted italic (`Type.hearsay`), what `gh` *established* in the fact face,
never the same tier.

### Run lifecycle

`is_error` is not enough: a run only counts as clean when `permission_denials` is empty too — a run can
end `subtype: "success"` having been refused a tool and quietly worked around the gap.

There is no wall-clock kill (`merge-pr` waiting hours on CI is legitimate). What is actionable is
**silence**: 20 minutes without output marks the run stalled and asks. Cancellation is a plain SIGTERM —
Claude Code handles it, aborts the turn, kills its Bash process tree, runs SessionEnd hooks, exits 143.

Runs default to `--permission-mode bypassPermissions`; `permissionMode` is a per-repo column if you want
to tighten one.

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

The end-to-end suite drives the real stack — rule engine, scheduler, actual process spawn, stream parsing,
log writing, cancellation, launch sweep — against `Scripts/fake-claude.sh`, driven by
`FAKE_CLAUDE_FIXTURE`, `_DELAY_MS`, `_MODE=hang|trap|crash`, `_ARGV_OUT`, `_STDERR`, `_READY`. Fixtures
live at `Fixtures/` (repository root, not a resource bundle) so the same files are usable by hand from a
terminal when reproducing a run.

Two invariants carry most of the weight:
- the first digit run of an `implement-issue` prompt is the issue number, because the skill resolves its
  argument with `grep -oE '[0-9]+' | head -1`;
- a system-originated move never triggers a skill.

## Things that bite

- **A `ScrollView` that can scroll swallows taps a disabled one passes through.** The board's
  deselect-on-background-click fired by bubbling out of a column's empty space, and that only worked
  while five columns fit the window and scrolling was off. The detail panel widens the row past the
  viewport by design, so scrolling is now always on with it open — and clicking to deselect stopped
  working, in every column, with `swift build` clean and the whole suite green. The gesture lives on
  `ColumnView` now. Putting it on the row's background instead only moved the bug: that background
  also lies under the panel, so a click on the panel being read closed it. **An ancestor's tap fires
  for taps on its descendants, so any deselect above the panel is a deselect through it.**
- **`onChange` runs inside the update that changed the value, so it sees the layout as it was.**
  `BoardView.frame(...)` computed a scroll offset for the row that was *about to* include the panel
  and applied it to the row that still did not, where it clamped to zero — the board simply never
  moved. Deferred by one turn of the main actor. It was invisible in four of five columns, because
  those are the ones where the pair already fits: **when a layout change has a "last column" case,
  that is the case to check.**
- **Migrations are additive and shipped ones are frozen.** `ElliotStore/Migrations.swift` — append,
  renumber so versions stay ordered, never edit a migration that has run. `Column`'s raw values are
  persisted, so renaming a case needs a migration.
- **Bump `elliotProtocolVersion` when the wire format changes** (`ElliotIPC/Protocol.swift`). An old
  helper in an old bundle meeting a newer app must fail loudly at `hello`, not halfway through a move.
- **`ElliotBuild.marketingVersion` is the single source of the version.** `Scripts/build-app.sh` `sed`s
  that line to stamp `CFBundleShortVersionString`; a plist naming a version the source does not is the
  one thing a field bug report is trusted on.
- **PATH is captured, never inherited.** Launched from the Finder the app sees only
  `/usr/bin:/bin:/usr/sbin:/sbin`. `LoginShellEnvironment.capture()` gets the real environment and
  `ToolLocator` finds `claude`/`gh`/`git`; anything spawning a tool must go through `ToolConfig`. Testing
  preflight means launching from the Finder, not from a terminal or Xcode.
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
