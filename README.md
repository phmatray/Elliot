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

## Where stories come from

The backlog holds user stories, and Elliot can write them. *Analyze…* reads a
registered repository through six lenses — bugs, quick wins, features, tech
debt, tests, docs & DX — one `claude -p` run each, and comes back with proposed
stories you go through and accept.

Proposals are **not cards**. They live in their own table and their own window,
so a 30-story analysis does not drown the board and the five columns keep one
meaning. Accepting calls the same `BoardService.createCard` the New Card sheet
uses, and the card lands in Backlog, where nothing runs.

The same four steps are available over MCP: `board_analyze_repo`,
`board_list_proposals`, `board_accept_proposals`, `board_reject_proposals`.

## Build and run

```bash
cd ElliotKit && swift test          # 237 tests, no Xcode needed
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
ElliotMCPKit    Model+IPC+Store     the MCP tools
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

**Cancellation is a plain SIGTERM — and it already reaches the group.**
`terminate()` calls Foundation's `Process.terminate()`, and that does not stop
at the child's own pid. Measured directly (`bash -c 'sleep 300 & sleep 300'`,
and `Scripts/fake-claude.sh` with `FAKE_CLAUDE_MODE=hang`, both spawned through
`Process` and stopped with `terminate()`): every descendant that shares the
child's process group dies in the same instant the child does — a backgrounded
`sleep` included. The one thing that survives, orphaned onto pid 1, is a
descendant that has called `setsid()` and moved itself into its own session.
So there is no "reach into the process group by hand" being declined here —
Foundation already does it. Claude Code's own handling of the signal (aborting
the turn, running its SessionEnd hooks, exiting 143) happens in its own
process, not as a prerequisite for its ordinary Bash children's exit.

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

**The artifact is the fact.** There is no `gh` to appeal to about whether a
story is a good idea — the agent's judgement *is* the deliverable. So the
analogue of "`gh` is the fact" is a file: each run is told to write
`stories.json` at a path announced in its own prompt, and Elliot reads that
rather than the closing message. The path is marked `ELLIOT_OUTPUT=`, and a
property test asserts every prompt carries exactly one and that it is absolute
— the same class of invariant as the first digit run of an `implement-issue`
prompt. If the file is missing, the last fenced JSON block in the reply is
tried, and which source answered is recorded on the run.

**Evidence, checked.** Every proposed story must cite `file:line`. Elliot
resolves each citation against the repository and confines it there, so a
proposal whose files do not exist is shown struck through. It is the only
objective fact available about an opinion, and it is the fastest way to see a
story that was invented rather than found.

**An analysis cannot be stopped from writing, so it is watched.** No CLI flag
expresses "Write, but only under this path". The prompt forbids touching the
repository, `--add-dir` makes the scratch directory writable, and `git status
--porcelain` is compared before and after. A run that edited your code is
reported, not guessed at.

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

## Status

Proof of concept. What works end to end: the board, the rule engine, the
streaming runner with live logs and cancellation, `gh` verification, the PR
watcher, crash reconciliation, preflight, the MCP server, and the repository
analysis that proposes stories.

Not done: registering a repository is UI-only (no CLI), the merge path has not
been exercised against a real pull request, the `.app` is ad-hoc signed rather
than notarised, and the analysis has been proven end to end only against the
fake `claude` — no real repository has been read yet.
