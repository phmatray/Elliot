# Elliot

<img src="docs/elliot-icon.png" width="128" alt="Elliot's mark: three interlocking chevron cards, each pointed on the right and notched on the left, on a plate that runs from violet to crimson.">

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

**Preflight findings you can act on**: a check can now carry a fix, not just a
sentence describing one. The first is labels — `create-issue` silently drops a
label a repository does not have and files the issue anyway, so Preflight names
the missing ones and offers to create them. Creating a *declared* label is
deterministic, so that button runs `gh`, not an agent. Deciding a repository's
own taxonomy is not, and edits a committed file, so that button adds a **card**
— the work goes through the board, which is where Elliot starts agents.

**And an agent can look at the result**: `board_screenshot` photographs one of
Elliot's own windows and hands back the image, so a change that moved something
on screen can be checked rather than assumed. Elliot draws its own hierarchy, so
it needs no Screen Recording grant and works while the window sits in the
background — but a sheet, a popover and the toolbar's controls live in separate
windows and do **not** appear. Whatever was left out is listed in
`not_included`, because "it is not in the picture" must never read as "it did
not open".

## The board

| From → To | What happens |
|---|---|
| Backlog → To Do | `/ai-migration-kit:create-issue <story>` (+ repeatable `--label`) — fills in the issue number |
| To Do → In Progress | `/ai-migration-kit:implement-issue <n>` — fills in the PR number and branch |
| In Progress → In Review | *no skill* — automatic, when the PR goes ready |
| In Review → Done | `/ai-migration-kit:merge-pr <pr>` (+ repeatable `--follow-up`) |
| anything else | nothing |

The backlog holds **user stories**, not loose ideas: `role` / `want` / `benefit`
plus acceptance criteria, kept as separate fields. That is what will let a skill
*generate* stories from a repository later instead of parsing prose back apart.

A card can be corrected — label, story, acceptance criteria, GitHub labels — from
its detail sheet, right up until it is filed. Once it carries an issue number the
card stops being the record: edit the issue on GitHub instead. Elliot refuses the
edit rather than letting the two drift.

### The labels a card asks for

A card says which GitHub labels its issue should carry, and they travel to
`create-issue` as `--label "bug" --label "documentation"`. Left empty — the
common case — the prompt gains nothing at all and the skill picks labels the way
it always has.

They are chosen from **the repository's own labels**, read through
`gh label list`, so a card cannot quietly ask for one that does not exist. A
label the repository turns out not to have is **struck through and marked on the
card**, never dropped: the card records what someone asked for, and the mark is
what says the repository disagrees. If `gh` cannot be reached at all, the card's
own labels still show and the picker says so — *could not be established* is a
different sentence from *this repository has no labels*, and Elliot does not
print one when it means the other.

A story from the analysis arrives with its lens's label already ticked, where you
can see it and take it off: 🐛 bugs → `bug`, ✨ features → `enhancement`,
📖 docs & DX → `documentation`. The other five lenses suggest nothing, on purpose
— a quick win is a claim about effort and tech debt is a claim about where the
work is, and neither names a kind of issue. A guess dressed as a decision is the
thing this replaces.

⚠️ **`--label` is an instruction, not a parsed flag.** Measured against
ai-migration-kit 1.9.0: `merge-pr` documents `--follow-up` as an argument,
`create-issue` documents no arguments and chooses labels itself. An agent reading
the prompt will very likely honour it; nothing obliges it to. So the card is the
record of the *intent*, and what the issue ended up with is read back from `gh`.

## Where stories come from

The backlog holds user stories, and Elliot can write them. *Analyse* reads a
registered repository through eight lenses — bugs, quick wins, features, tech
debt, tests, docs & DX, UX & UI, best practices — one `claude -p` run each, and
comes back with proposed stories you go through and accept.

It is a **panel on the board**, the slot before Backlog: two or three columns
wide, hideable from the toolbar or View ▸ Show Analysis, resized by dragging its
outer edge — the same shape the detail panel has. It sits there because that is
where its output lands, in the column immediately to its right.

Proposals are **not cards**. They live in their own table, so a 30-story
analysis does not drown the board and the five columns keep one meaning.
Accepting calls the same `BoardService.createCard` the New Card window uses, and
the card lands in Backlog, where nothing runs.

Hiding the panel is not ending the analysis: runs in flight keep going, proposals
keep arriving, and the lenses you ticked, the instructions you typed and the
proposals you staged are all still there when you show it again. *Finish*, in its
footer, is the act that ends a session.

Starting is refused for a repository Preflight is failing, one that is switched
off, or none at all — and the panel says which, where the disabled button is.

The same four steps are available over MCP: `board_analyze_repo`,
`board_list_proposals`, `board_accept_proposals`, `board_reject_proposals`.

## Build and run

```bash
cd ElliotKit && swift test          # 459 tests, no Xcode needed
./Scripts/build-app.sh              # assembles dist/Elliot.app
open dist/Elliot.app
```

Then register the bundled MCP helper with Claude Code (the app's Preflight
screen shows this command with the right path, ready to copy):

```bash
claude mcp add elliot -s user -- "$PWD/dist/Elliot.app/Contents/MacOS/elliot-mcp"
```

Re-run it if you move the app: the registration records an absolute path.

The app icon is rendered at build time from the mark's geometry in
`ElliotModel` — there is no committed `.icns`. The one image that *is*
committed, `docs/elliot-icon.png`, comes from the same source and can be
checked against it:

```bash
cd ElliotKit && swift build --product elliot-icon
.build/debug/elliot-icon png ../docs/elliot-icon.png --pixels 512 --check
```

## Layout

```
ElliotModel     no dependencies    value types, the rule engine, prompt builder,
                                   stream-json decoder, PR matcher,
                                   RepoTreeLayout, RepoReconciler
ElliotStore     GRDB               schema, migrations, the one atomic move
ElliotProcess   —                  tool discovery, environment capture, spawning,
                                   line splitting, gh/git clients
ElliotIPC       —                  wire protocol, unix socket server and client
ElliotEngine    all of the above   BoardService, RunScheduler, verifiers,
                                   PRWatcher, Reconciler, preflight,
                                   RepoTreeScanner, RepoRegistryService
ElliotMCPKit    Model+IPC+Store     the MCP tools
ElliotApp       SwiftUI            the board
elliot-mcp      stdio              the helper Claude Code spawns
```

## Repositories

The board drives repositories you register one at a time. The **Repositories**
page, next to Preflight in the toolbar, shows the whole fleet instead: every
repository of the accounts you configure, what is wrong with it, and one button
that fixes exactly that.

A setting names the **tree root** (default `~/Repositories`), and the layout
under it is `<owner>/<public|private>/<name>` — one level, exactly. Anything that
does not match is **out of scope, not misplaced**: a sibling root like
`_worktrees/`, a nested directory, an owner you do not manage. The distinction is
the safety property. "Misplaced" offers to move a directory; a recursive walk
that mistook a worktree for a clone would offer to move that too.

Each row carries a verdict and the fixes it allows:

| Verdict | What it means | The button |
|---|---|---|
| ok | cloned in the right place, and registered | — |
| not cloned | on GitHub, no clone under the root | **Clone** |
| not registered | cloned in the right place, unknown to Elliot | **Register** |
| misplaced | cloned under the wrong owner or visibility folder | **Move to …** |
| missing | registered, but nothing is at that path | **Forget** |
| out of scope | a fork, archived, a linked worktree, or outside the owner folders | — |
| behind by *n* | clean, attached, and *n* commits behind its upstream | **Pull** |
| dirty | uncommitted changes | — |
| ahead | local commits not pushed | — |
| diverged | commits on both sides | — |
| detached | HEAD is a commit, not a branch | — |
| no remote | no upstream branch to compare against | — |
| unreadable | git could not be asked | — |

The last seven come from a **probe** that runs after the reconcile and refines
every row it called `ok`. It asks git, eight clones at a time, and the order it
asks in *is* the safety property: worktree, then detached, then dirty, and only
then the counts. A clone that is both dirty and behind reads **dirty**, because
that is the one Sync must refuse.

The probe fetches before it counts, and that is not ceremony. `git rev-list
@{u}...HEAD` reads a **local** ref: without a preceding fetch it answers
`behind: 0` for a clone that is in fact behind. That is how this portfolio once
measured 200 of 244 clones as current while they were not — the clones did not
know.

**Sync** is the one batch on the page. It fast-forwards every clone that is
strictly behind — eight at a time — and reports `N pulled · M skipped · K
failed`, naming every repository it left out and why. `dirty`, `ahead`,
`diverged` and `detached` are all refused, because each of the four means a
human has work in that tree and Elliot has nothing to say about work in
progress beyond *I left it alone*. **Sync never merges, never rebases, never
stashes, and never moves a directory**: the pull is `--ff-only` or it fails, and
`move` stays a per-row click.

That is also why a batch is allowed here at all. The question is not "batch or
not" but "does every action in the batch refuse itself when it is unsafe?"
`--ff-only` does; `moveItem` does not.

Five rules hold the page together:

- **One fix per click.** `clone` is additive; `move` relocates a directory in
  your portfolio. Only one at a time keeps them at different distances from your
  finger, and makes a failure attributable to one row.
- **Nothing is dropped from a sweep silently.** Every row Sync passes over is
  named with its reason, because a repository quietly missing from a report
  reads exactly like one that succeeded.
- **Move names its destination on the button**, refuses an occupied one, and
  repoints the registration in the same step — so the store never points at a
  path that was moved out from under it.
- **Nothing deletes on disk.** There is no `.delete` case in `RepoFix` and there
  must never be one. **Forget** removes a registration and leaves the checkout
  alone — though it does drop that repository's cards, because `card.repoID`
  cascades, and the button says so. Nothing here pushes, commits, stashes,
  merges, rebases or switches a branch either. It fetches and it fast-forwards,
  and those are the only two things it will ever do inside a working tree.
- **The page judges nothing.** Every verdict is computed in `ElliotModel` and
  `ElliotEngine`, both pure enough to test; what counts as "behind" is
  `RepoIssue.isBehind`, asked once and shared, so the count on the Sync button
  cannot promise something the sweep will not do.

Preflight gains a **Repository tree** check for the configured root, and names
the command it used.

## Notifications

Elliot's most important moments happen after you have gone somewhere else: a `merge-pr` deliberately
has no wall-clock kill, because waiting on CI is legitimate. So it tells macOS about them.

**It notifies about facts it established, never about gestures you made.** A drag, a
`board_move_card`, a run starting, a move refused — none of these post anything; you were there.
What posts is a run *finishing*, a run *going quiet*, the board moving a card *by itself*, and an
analysis *finishing*.

A "landed" notification's body is built from the run's `verifiedOutcome` — what `gh` established —
and never from `resultText`, which is the agent's own account of its own work. A run that succeeded
with nothing verified says exactly that rather than quoting the agent.

Four categories, one switch each under ⌘,: **landed** · **needs you** · **the board moved itself** ·
**analysis ready**. Only *needs you* makes a sound, and only *needs you* gets through while Elliot is
the front application — the rest are already on the board you are looking at. One notification per
card at a time, replaced in place: "Opened issue #12" becomes "Draft PR 13 on feat/12-…" rather than
leaving two claims on screen, one of them stale.

The decision of what to notify and what it says is a pure function in `ElliotModel` with tests. Only
delivery touches `UNUserNotificationCenter`.

⚠️ **Notifications need a bundle, and a durable one.** `UNUserNotificationCenter.current()` raises
without a `CFBundleIdentifier`, so `swift run ElliotApp` and `swift test` never reach it — they get a
no-op delivery instead. And macOS refuses to deliver from a bundle in a scratch location: measured,
an identically ad-hoc-signed build in `/tmp` had every request rejected with *"Notifications are not
allowed for this application"* while `authorizationStatus` still read `notDetermined`, whereas the
same build in `dist/` or `~/Applications` delivered normally. Ad-hoc signing is not the problem;
location is. Preflight's **Notifications** row reports the last refusal for exactly that reason —
the status alone would say "not asked yet" forever.

## Decisions worth knowing

**The board adopts, it does not mirror.** Opening a repository pulls its open issues and pull requests
in as ordinary cards — draggable, and dragging one does the real thing. Placement comes from GitHub (no
PR → To Do, draft → In Progress, ready → In Review, merged → Done) and never from Backlog, which means
*not filed*. Adoption goes through `applySystemMove`, so a card landing in In Review cannot fire
`merge-pr`; and two partial unique indexes on `(repoID, issueNumber)` and `(repoID, prNumber)` make a
duplicated card impossible in the database rather than merely unlikely in the planner. Deleting an
imported card dismisses it so a refresh cannot resurrect it — nothing on GitHub is touched.

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

`gh` has the same treatment in `Scripts/fake-gh.sh`, which answers `issue list`
and `pr list` from `Fixtures/gh/*.json` (`FAKE_GH_ISSUES`, `FAKE_GH_PRS`,
`FAKE_GH_MODE=ok|fail`, `FAKE_GH_ARGV_OUT`). That is how the GitHub import is
tested end to end — real subprocess, real JSON decode, real store writes —
without `gh` existing on the machine:

```bash
FAKE_GH_ISSUES=Fixtures/gh/issues-basic.json \
  ./Scripts/fake-gh.sh issue list --repo x --json number | python3 -m json.tool
```

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
watcher, crash reconciliation, preflight, the MCP server, the repository
analysis that proposes stories, the GitHub import — so the board shows the
work a repository already had, not only what was typed into Elliot after
installing it — and the Repositories page, which reconciles the accounts you
configure against the tree on disk and repairs a row at a time.

Not done: keeping each clone up to date — `fetch`, ahead/behind, `pull --ff-only`
— is the follow-up to the Repositories page and the only part that writes
*inside* a working tree; the four fixes have been proven against temporary
directories rather than a live portfolio, and `Clone` in particular has not yet
been watched against a real `gh repo clone`. The merge path has not
been exercised against a real pull request, the `.app` is ad-hoc signed rather
than notarised, and the analysis has been proven end to end only against the
fake `claude` — no real repository has been read yet. The import's two
properties a screenshot cannot show — a second ⌘R changing nothing, and a
deleted card staying deleted — are covered at the unit level but have not yet
been watched by hand against a live repository.
