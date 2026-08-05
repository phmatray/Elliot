# Elliot

A native macOS Kanban board where **moving a card is the act of execution**.

The `create-issue`, `implement-issue` and `merge-pr` skills already cover a
feature's whole life — idea → planned issue → implemented pull request → merge
and follow-ups — but they are invoked one at a time, by hand, in a terminal.
There is no overview: no way to see at a glance what is waiting, what is
running, and what is stuck on CI.

Elliot makes that pipeline visible and operable. Dragging a card from Backlog
to To Do genuinely runs `create-issue`. The board is not a passive mirror of a
remote state — it is the remote control.

**MCP first**: the same gesture is available to Claude Code. The app exposes an
MCP server, so an agent can create and move cards, and thereby start the same
runs. Both paths — mouse and tool call — go through *the same rule engine*.

## The board

| From → To | What happens |
|---|---|
| Backlog → To Do | `/ai-migration-kit:create-issue <story>` — fills in the issue number |
| To Do → In Progress | `/ai-migration-kit:implement-issue <n>` — fills in the PR number and branch |
| In Progress → In Review | *no skill* — automatic, when the PR goes ready |
| In Review → Done | `/ai-migration-kit:merge-pr <pr>` (+ repeatable `--follow-up`) |
| anything else | nothing |

The backlog holds **user stories**, not loose ideas: `role` / `want` / `benefit`
plus acceptance criteria, kept as separate fields. That is what will let a skill
*generate* stories from a repository later instead of parsing prose back apart.

A card can be corrected — label, story, acceptance criteria — from its detail
sheet, right up until it is filed. Once it carries an issue number the card stops
being the record: edit the issue on GitHub instead. Elliot refuses the edit rather
than letting the two drift.

## Build and run

```bash
cd ElliotKit && swift test          # 179 tests, no Xcode needed
./Scripts/build-app.sh              # assembles dist/Elliot.app
open dist/Elliot.app
```

Then register the bundled MCP helper with Claude Code (the app's Preflight
screen shows this command with the right path, ready to copy):

```bash
claude mcp add elliot -s user -- "$PWD/dist/Elliot.app/Contents/MacOS/elliot-mcp"
```

Re-run it if you move the app: the registration records an absolute path.

## Layout

```
ElliotModel     no dependencies    value types, the rule engine, prompt builder,
                                   stream-json decoder, PR matcher
ElliotStore     GRDB               schema, migrations, the one atomic move
ElliotProcess   —                  tool discovery, environment capture, spawning,
                                   line splitting, gh/git clients
ElliotIPC       —                  wire protocol, unix socket server and client
ElliotEngine    all of the above   BoardService, RunScheduler, verifiers,
                                   PRWatcher, Reconciler, preflight
ElliotMCPKit    Model+IPC+Store     the five MCP tools
ElliotApp       SwiftUI            the board
elliot-mcp      stdio              the helper Claude Code spawns
```

## Decisions worth knowing

**One funnel.** `BoardService` is the only thing that changes a card's column. A
drag and an MCP `board_move_card` reach the same two methods, so they cannot
drift: one rule engine, one place that runs it, and callers only supply an
origin. `ElliotMCPKit` deliberately imports neither `ElliotEngine` nor
`ElliotProcess` — the helper holds no copy of the rules, so it cannot diverge
from them.

**`gh` is the fact; the agent's prose is a hint.** Nothing written back to a card
is parsed out of a run's closing summary. Issue and PR numbers come from
`gh … --json`. The obvious lookup `gh pr list --head feat/<issue>-<slug>` is
unusable, because the slug is written by the agent from the issue title —
`PRMatcher` lists and scores instead, anchoring on `^<issue>-` *with* the
trailing hyphen so issue 4 cannot match `feat/47-…`.

**`is_error` is not enough.** A run can finish `subtype: "success"` while having
been refused a tool and quietly worked around the gap. A run only counts as
clean when `permission_denials` is empty too.

**Silence, not a clock.** There is no wall-clock kill: `merge-pr` waiting hours
on CI is legitimate. What is actionable is *silence* — 20 minutes without output
marks the run stalled and asks.

**Cancellation is a plain SIGTERM.** Claude Code handles that signal itself: it
aborts the turn, terminates the process tree of any running Bash command, runs
its SessionEnd hooks and exits 143. Reaching into the process group by hand
would only pre-empt an orderly shutdown.

**The app is the sole writer.** SQLite does not notify other processes of
writes, so the helper opens the store read-only and routes every mutation back
over the socket. Reads still work when Elliot is down — labelled
`source: offline-db` — but a write never falls back: writing a column change
straight to the database would move a card without firing its rule.

**Not sandboxed.** Child processes inherit the sandbox, and security-scoped
access does not extend to them at all, so a sandboxed `claude` could not write
to `~/.claude` or reach your repositories. Hardened Runtime is on.

**Permissions.** Runs default to `--permission-mode bypassPermissions`: the point
is unattended automation, and `acceptEdits` only auto-approves *edits* while
`implement-issue` is mostly Bash. The blast radius is the repositories you
explicitly register, and every run is logged in full. `permissionMode` is a
per-repo column if you want to tighten one.

## Testing

`swift test` runs everything, including an end-to-end suite that drives the real
stack — rule engine, scheduler, actual process spawn, stream parsing, log
writing, cancellation, launch sweep — against `Scripts/fake-claude.sh`, without
spending a token or touching GitHub. The fake is driven by environment
variables (`FAKE_CLAUDE_FIXTURE`, `_DELAY_MS`, `_MODE=hang|trap|crash`,
`_ARGV_OUT`) and is equally usable by hand from a terminal.

Two invariants carry most of the weight:

- the first digit run of an `implement-issue` prompt is the issue number,
  because the skill resolves its argument with `grep -oE '[0-9]+' | head -1`;
- a system-originated move never triggers a skill, since the state it reacts to
  was produced by one.

### Running the tests

`swift test` is expected to be **deterministic and always-terminating**. Three
rules in the suites keep it that way; breaking any of them reintroduces the bug
where a wedged child held the SwiftPM build lock for a quarter of an hour and
presented as a broken toolchain rather than as a stuck test.

- **Every async wait is bounded**, through `withTimeout` in the test-only
  `TestSupport` target. An unbounded `for await …` is how one hung child stopped
  `swift test` from ever exiting.
- **`Scripts/fake-claude.sh` traps in every mode**, and installs its trap before
  anything else, so no child outlives its parent holding the runner's stdout
  pipe open. It touches `FAKE_CLAUDE_READY` once it is trap-protected.
- **No assertion measures an absolute duration**, and no test sleeps a fixed
  interval waiting for the child to be ready — it waits on that file. Wall-clock
  assertions fail under load while the code under test behaved perfectly.

The matching rule in production code: **nothing waits on
`Process.waitUntilExit()`**. Both spawners publish the exit from
`terminationHandler`, handing the waiter off under one lock
(`StreamingProcess.waitForExit`, `ProcessRunner.run`). `waitUntilExit()` spins a
run loop waiting for a notification that a concurrently-spawned sibling can
consume first — and it was doing so on a cooperative-pool thread, so one lost
notification took the whole test process with it.

`swift test --filter` matches the **type** name, not the `@Suite` display name:
`--filter ClaudeRunnerTests`, not `--filter "Claude runner"`. A filter that
matches nothing prints `warning: No matching test cases were run` and **exits
0**, which is indistinguishable from success.

## Status

Proof of concept. What works end to end: the board, the rule engine, the
streaming runner with live logs and cancellation, `gh` verification, the PR
watcher, crash reconciliation, preflight, and the MCP server.

Not done: registering a repository is UI-only (no CLI), the merge path has not
been exercised against a real pull request, and the `.app` is ad-hoc signed
rather than notarised.
