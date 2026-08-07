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
naming the invariant that is written twice, because this repository has no CI and a gate that is not
a test is a gate nobody re-runs.

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

⚠️ **A long `ELLIOT_HOME` silently costs you the MCP socket.** `sun_path` is capped at 104 bytes on
macOS, so a scratch home under a deep path makes `startIPC` fail; the app runs fine, the helper
answers `app_unavailable`, and the reply reads as "Elliot is not running" while it is plainly on
screen. Keep the check store short — `/tmp/elliot-check` is short on purpose.

**A secondary window is verifiable too — it opens off-screen, it does not fail to open.** Every PR
from #75 to #89 carried some version of *"opening a `Window` scene needs the app frontmost, which the
automation driver refuses"*, and it was never true. A background `openWindow` does open the window; it
just lands off-screen because the app is not frontmost. The trap is the enumeration, not the window:
**list all of a pid's windows, never only the ones reporting `is_on_screen`.** Measured on a running
build, when `ElliotApp.swift` declared six `Window` scenes (it declares five since #151 retired the
Analysis one), two of them open:

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

**Looking and touching are two different grants, and only one of them is usually on.** Check before
planning a verification pass, because the answer decides what the pass can even ask:

```bash
cua-driver permissions status --json    # {"accessibility": false, "screen_recording": false} today
```

- **Screen Recording** buys *observation*: `list_windows` (titles, sizes, `is_on_screen`) and a real screenshot of any window. That alone settles "did it open", "how big", "does it render", "is there exactly one".
- **Accessibility** buys *actuation* — and also the AX tree. Synthetic clicks and key presses are posted to another process's event queue, which macOS gates behind this grant.

⛔ **Without Accessibility, a click or a keystroke fails silently and looks like a working no-op.**
Measured on #48: `press_key` returns `"effect": "unverifiable"` with
`"escalation": {"reason": "delivery_failed"}`, `click` returns `"effect": "unverifiable"` — and the
screenshot afterwards is byte-for-byte the same board. Nothing errors. Read that as "the driver could
not act", never as "the app ignored the input" — the third member of the same false-negative family as
the two above. Anything needing a click or a key is **not verifiable** until someone runs
`cua-driver permissions grant` and ticks the box.

⚠️ **As of today the driver holds neither grant** — `accessibility: false` *and*
`screen_recording: false`, read against the daemon's own TCC identity `com.trycua.driver`, which is
the identity that matters because the daemon is its own responsible process. So observation is off
too, and the window listing above is not currently reproducible through it. `/usr/sbin/screencapture
-l` from a shell still enumerates windows and is what produced today's listings, but it is **not** a
substitute: a non-frontmost window parks in the Stage Manager strip at ~143×160, and nothing in it
can be read as text.

Recognise the shape rather than the tool, because it has now bitten this project four times: **a
permission that silently changes behaviour instead of erroring.** A blank accessibility tree that
reads as an empty window; a click that reports `unverifiable` rather than failing; a screen-recording
grant that is simply absent while the commands still return; and `gh secret list` omitting
organisation secrets. Not one of the four says *no*.

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
| Backlog → To Do | `/ai-migration-kit:create-issue <story>` — fills in the issue number |
| To Do → In Progress | `/ai-migration-kit:implement-issue <n>` — fills in the PR number and branch |
| In Progress → In Review | *no skill* — a system move, when `PRWatcher` sees the PR go ready |
| In Review → Done | `/ai-migration-kit:merge-pr <pr>` (+ repeatable `--follow-up`) |
| anything else | nothing |

The backlog holds **user stories** (`role` / `want` / `benefit` + acceptance criteria as separate
fields), not loose prose. A card is editable up to the moment it carries an issue number; after that
`updateCard` refuses rather than letting card and issue drift.

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

⛔ **The analysis panel carries no `.keyboardShortcut(.defaultAction)`.** It did as a `Window` scene,
where Return was scoped to it. As a sibling in the board window it would share Return with
`DetailPanelView`'s Save, with nothing in the code deciding between them — and the claimant here
spawns up to eight unattended runs.

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

The shell holds Accessibility even when the `cua-driver` daemon does not, so
`osascript -e 'tell application "System Events" to click at {x, y}'` selects a card and
`key code 53` is Escape. One more false negative to know: `entire contents` of the window can return
**empty** while `count of UI elements` returns 6. An empty AX dump is not an empty window.

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
