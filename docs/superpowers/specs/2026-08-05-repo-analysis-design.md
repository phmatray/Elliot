# Repository analysis → proposed user stories

*Design, 2026-08-05. Written in English to match the rest of the repository.*

## Why

Elliot drives a story from backlog to merged pull request, but the story has to
come from somewhere. Today that somewhere is a person typing into a sheet.

The board already holds **structured** user stories — `role` / `want` /
`benefit` plus acceptance criteria as separate fields, not prose — and the
README says why: so that a repository can one day be read and turned into
stories without having to parse prose back apart. This is that feature.

Elliot reads a registered repository through several lenses (bugs, quick wins,
features, …), each as its own `claude -p` run, and comes back with a list of
proposed stories. The stories are **proposals, not cards**: nothing reaches the
board until you have gone through them, edited what needs editing, and accepted
what you want. Accepting drops a real card in Backlog — which, as always, runs
nothing on its own. Backlog → To Do remains the act that files an issue.

The whole feature is available over the embedded MCP server, so an agent can
run it, read the results, and accept from Claude Code.

## Decisions

| Question | Choice |
|---|---|
| Where proposals live before acceptance | A `storyProposal` table and a dedicated Analysis window. **Not** a sixth column, **not** provisional cards in Backlog. |
| Granularity | **One run per angle.** Three angles ticked = three runs. |
| How structured stories come back | The agent **writes a JSON artifact**; Elliot reads it. Falls back to the last fenced JSON block in the closing message. |
| MCP scope | Start, read, accept, reject — all four. |
| Custom lenses | No seventh enum case: free-text `extraInstructions` injected into every angle's prompt. |
| Analysis state | Derived from its runs. Never stored. |

## What this does not touch

The rule engine, `TriggerAction`, the five columns and the three transitions are
unchanged. An analysis is not a move; a proposal is not a card. The board keeps
exactly one meaning for "moving a card", and the funnel — `BoardService` as the
only thing that changes `Card.column` — keeps exactly one implementation.

Acceptance goes through `BoardService.createCard`, the same method the New Card
sheet and `board_create_card` already use. There is no second way to make a
card.

## Model (`ElliotModel`, pure)

### The angle is a lens, not a category

```swift
public enum AnalysisAngle: String, Codable, CaseIterable, Sendable, Hashable {
    case bugs, quickWins, features, techDebt, tests, docsAndDX

    public var title: String    // "Bugs", "Quick wins", …
    public var symbol: String   // emoji, for the window and the proposal rows
    /// The prompt fragment: what to look for, and what to leave alone.
    public var briefing: String
}
```

| Angle | Looks for | Leaves alone |
|---|---|---|
| 🐛 `bugs` | races, swallowed errors, unhandled edge cases | style, preferences |
| ⚡ `quickWins` | high value for one sitting's effort, low risk | anything architectural |
| ✨ `features` | capabilities the shape of the repo asks for | what already exists elsewhere |
| 🧹 `techDebt` | duplication, tangled boundaries, oversized files | cosmetic renames |
| 🧪 `tests` | uncovered invariants, error paths | chasing a coverage number |
| 📖 `docsAndDX` | onboarding friction, CLI ergonomics | typos |

`briefing` is a plain string, so the lens is data and adding one is a case plus
a paragraph — no plumbing.

### Two shapes for a proposed story

The distinction mirrors `CardDTO` vs `Card`: one is a contract we ask a model to
satisfy, the other is what Elliot keeps.

```swift
/// What the agent writes into the artifact. Flat, small, forgiving.
public struct ProposedStory: Codable, Sendable, Hashable {
    public var title: String
    public var role: String
    public var want: String
    public var benefit: String
    public var acceptanceCriteria: [String]
    public var rationale: String
    /// "Sources/ElliotProcess/ClaudeRunner.swift:142". At least one required.
    public var evidence: [String]
    /// "small" | "medium" | "large". Anything else degrades to `.medium`.
    public var effort: String
}

public struct StoryProposal: Identifiable, Codable, Sendable, Hashable {
    public var id: UUID
    public var analysisID: UUID
    public var runID: UUID
    public var repoID: UUID
    public var angle: AnalysisAngle
    public var title: String
    /// The existing type. Reusing it is the point of the whole feature.
    public var story: UserStory
    public var rationale: String
    public var evidence: [Evidence]
    public var effort: Effort
    public var status: ProposalStatus
    public var acceptedCardID: UUID?
    public var duplicateOf: DuplicateHint?
    public var createdAt: Date
}

public struct Evidence: Codable, Sendable, Hashable {
    public var path: String     // repo-relative
    public var line: Int?
    /// Resolved once, at harvest, against the repository root.
    public var exists: Bool
}

public enum Effort: String, Codable, CaseIterable, Sendable { case small, medium, large }
public enum ProposalStatus: String, Codable, CaseIterable, Sendable {
    case proposed, accepted, rejected
}
public enum DuplicateHint: Codable, Sendable, Hashable {
    case card(id: UUID, title: String)
    case issue(number: Int, title: String)
}
```

### The analysis

```swift
public struct Analysis: Identifiable, Codable, Sendable, Hashable {
    public var id: UUID
    public var repoID: UUID
    public var angles: [AnalysisAngle]
    public var extraInstructions: String
    public var maxStoriesPerAngle: Int      // default 8
    public var origin: AnalysisOrigin
    public var createdAt: Date
}

public enum AnalysisOrigin: Codable, Sendable, Hashable {
    case manual
    case mcp(client: String)
}
```

**No `state` field.** An analysis is running while any of its runs is
non-terminal, and that is a question its runs already answer. A stored counter
would be a second reservoir of truth that drifts on the first crash — the same
reason a card has no "is running" flag.

### `SkillRun` gains a shape

An analysis run has no card. Today `SkillRun.cardID` is non-optional and the
column is `NOT NULL` with a cascading foreign key.

- `cardID` becomes `UUID?`.
- `analysisID: UUID?` is added, with a cascading foreign key to `analysis`.
- Exactly one of the two is set. A store test asserts it.

Doing it this way means an analysis run is an ordinary `SkillRun` and inherits,
for free and already tested: admission and queueing, live streaming, the durable
NDJSON log, SIGTERM cancellation, the idle-silence timeout, and the launch-time
reconciliation sweep. The alternative — a parallel `analysisRun` table — costs
no migration but duplicates the scheduler, the cancellation ladder and the
reconciler, and that kind of duplication diverges within weeks.

`SkillKind` gains `.analyzeRepo`, and `slashName` becomes `String?`, nil for
that case, **because there is no `analyze-repo` skill**. The other three are
plugin skills invoked by slash command; this one is a prompt Elliot owns and
versions itself. `TriggerAction` is not extended: it stays exactly the three
board transitions, so the rule engine does not move.

### Shared text similarity

`Verifier.tokens` and `Verifier.overlap` — the 0.6 token-overlap scoring that
already recovers an issue when no URL is found in a run log — move to
`ElliotModel.TextSimilarity`. The harvester needs the same scoring for duplicate
hints, and two implementations of one heuristic would diverge.

## The prompt and the artifact

`AnalysisPromptBuilder` (pure, `ElliotModel`) builds one prompt per angle:

```
prompt(angle:repo:outputPath:existingTitles:maxStories:extraInstructions:) -> String
```

It carries, in this order:

1. what the run is for, and that it must not modify the repository;
2. the angle's `briefing`;
3. the repository's `owner/name`;
4. `ELLIOT_OUTPUT=<absolute path>` — the artifact to write, and the instruction
   to print nothing else;
5. the JSON schema, with one fully worked example;
6. the existing card titles and open issue titles — the 80 most recent, newest
   first — with an instruction not to re-propose what is already there;
7. `maxStories`, and the requirement that every story cite at least one
   `file:line`;
8. `extraInstructions`, verbatim, if any.

Two invariants worth a property test, in the spirit of "the first digit run of
an `implement-issue` prompt is the issue number":

- the prompt contains **exactly one** `ELLIOT_OUTPUT=` marker;
- the path that follows it is **absolute**.

The artifact lives beside the run's log, under
`~/Library/Application Support/Elliot/analyses/<analysisID>/<runID>/stories.json`,
and the directory is passed as `--add-dir` so it is legitimately writable.

Keeping it as a file rather than as prose in the closing message is the same
stance the rest of Elliot takes about facts. There is no `gh` to appeal to here
— the agent's judgement *is* the deliverable — so the analogue is: **the
artifact is the fact.** It is durable, it can be re-harvested without re-running,
it does not inflate the terminal event that the log view renders, and a fake
`claude` can produce one in a test.

## Harvest

`ProposalHarvester` (`ElliotEngine`) replaces the `Verifier` when an analysis
run finishes:

1. **Read** `stories.json`. If it is missing or does not decode, extract the
   last fenced JSON block from `run.resultText`. Which source was used
   (`artifact` / `resultText` / `none`) is recorded on the run and shown in the
   window — you know which path produced what you are looking at.
2. **Decode and validate.** The decoder never throws and never drops silently:
   it returns `(stories: [ProposedStory], dropped: [String])`. A story is
   dropped, *with its reason*, when it is missing any of `role` / `want` /
   `benefit`, when its title is empty, or when it cites no evidence at all. A
   model returning 200 stories is capped at `maxStoriesPerAngle`, and the window
   says how many were cut.
3. **Resolve evidence.** Split `path:line`, resolve against the repository root,
   set `exists`. A proposal whose cited files do not exist is *not* rejected —
   it is marked, and the window strikes it through. That is the fastest signal
   that a story was invented rather than found. Citing nothing at all is a
   different matter and was already dropped in step 2: an unfalsifiable story is
   worth less than a wrong one.
4. **Hint at duplicates.** `TextSimilarity` at 0.6 against existing card titles
   and open issue titles, producing `duplicateOf`.
5. **Persist** the proposals.

`RunScheduler.finish` splits in exactly one place — `completeCardRun` (verify,
write to the card, possible system move) and `completeAnalysisRun` (harvest) —
rather than letting one method acquire two personalities.

## Scheduling

An analysis reads the working tree, so admission has to account for that.

| In flight in the same repo | Analysis admitted? | Why |
|---|---|---|
| `mergePR` | **no** | it rewrites `main`, removes worktrees and deletes branches; a reader would see a moving target and the git sentinel would fire spuriously |
| `implementIssue` | yes | it works in a worktree, not the main checkout |
| `createIssue` | yes | it does not touch the tree |
| another analysis | yes | two readers |

The other direction is already covered: `mergePR` requires `sameRepo.isEmpty`,
so it waits for a running analysis without a line being added.

The global cap of 2 exists because worktrees isolate git but not `.build/`,
`node_modules/` or `DerivedData/`. An analysis compiles nothing, so making it
compete for that cap would mean ticking three angles starves a queued
`implement-issue`. Analysis runs get **their own lane, cap 3**, independent of
the mutating lane.

Dedupe key: `(repoID, angle)`. A second run of the same angle while one is in
flight is **refused, not queued** — the same rule as a second
`implement-issue 47`. This also contains the one loop worth worrying about: an
analysis run inherits your MCP configuration, so its agent can see `elliot` and
could call `board_analyze_repo` from inside an analysis.

## The git sentinel

An analysis has no business writing to your repository, and **Elliot cannot
prevent it.** No CLI flag expresses "Write, but only under this path". The
prompt forbids it and `--add-dir` makes the scratch directory legitimately
writable, and that is the extent of the prevention.

So the house rule applies: do not trust the instruction, check the outcome.
`git status --porcelain` is recorded before the spawn and again after exit. If
the working tree changed, the run is flagged and the diff is surfaced. An
analysis that modified your code is visible, not guessed at.

## The Analysis window

One window, not two sheets. Opened by an *Analyze…* toolbar button on the
selected repository; disabled when the repository is disabled or blocked by
preflight, for the same reason cards are.

It starts in setup — the six angles with their briefing as subtitle, stories per
angle, the free-text instructions field — and after launching, **the same window
shows the runs at the top and fills in with proposals as each angle lands**.
That is what makes "one run per angle" worth its cost: quick wins are readable
and sortable while the bugs angle is still working.

Each proposal expands to its narrative, criteria, rationale and evidence.
Non-existent evidence paths are struck through. A `duplicateOf` hint shows as a
badge. Everything is **editable before acceptance** — the corrected version is
what becomes the card, not the model's.

The footer acts on the selection: *Rejeter*, or *→ Backlog (n)*.

Past analyses for a repository are reachable from the same button's menu.

## MCP and IPC

Four tools, four `ElliotRequest` cases, and the payloads to carry them.

```
board_analyze_repo(repo, angles[], max_stories, instructions)
    → { analysis_id, runs: [{run_id, angle}] }      returns immediately
board_list_proposals(analysis_id | repo, status, limit)
    → { proposals: [...], source: "live" | "offline-db" }
    status defaults to "proposed"; one of analysis_id or repo is required
board_accept_proposals(proposal_ids[])  → { cards: [...] }
board_reject_proposals(proposal_ids[])
```

`board_list_proposals` is a read, so it answers from the read-only database
snapshot when Elliot is not running, annotated `offline-db`, like every other
read. The three others are writes and go through the running app — the helper
never writes the database.

Tool descriptions must state plainly that an analysis takes minutes and that
`board_list_runs` is how to follow it, and that accepting lands cards in
**Backlog**, where nothing runs. An agent must not think it just opened five
issues.

New error codes: `analysis_not_found`, `proposal_not_found`, `unknown_angle`.

`ElliotMCPKit` still imports neither `ElliotEngine` nor `ElliotProcess`. It
holds no analysis logic, exactly as it holds no move rules.

## Storage

Migration `v2_analysis`, registered with `foreignKeyChecks: .deferred`:

- create `analysis` and `storyProposal`;
- rebuild `skillRun` — SQLite cannot relax a `NOT NULL` in place, so:
  `rename` → `create` with the new shape → `INSERT … SELECT` → `drop`;
- index `storyProposal(analysisID, status)` and `storyProposal(repoID, status)`.

A store test starts from a populated v1 database and asserts that migrating
loses no row and that `cardID` is now nullable.

Artifacts and logs live together under
`~/Library/Application Support/Elliot/analyses/<analysisID>/<runID>/`.

## Testing

Pure and instant, run by `swift test`:

- **`AnalysisPromptBuilderTests`** — exactly one `ELLIOT_OUTPUT` marker and it is
  absolute; the briefing appears; existing titles are capped at 80; the schema
  and the worked example are present; `extraInstructions` passes through
  verbatim.
- **`ProposalDecoderTests`** — a valid artifact; unknown extra fields tolerated;
  a story missing `benefit` dropped *with its reason*; 200 stories capped;
  garbage that is not JSON; the fenced-block fallback; an empty file. Assertion,
  as for the stream-json decoder: **never throws, never drops silently**.
- **`EvidenceTests`** — inside the repo, outside the repo, non-existent, no line
  number, a malformed `path:line`.
- **`TextSimilarityTests`** — moved with the code, plus the duplicate-hint
  threshold.
- **`SchedulerAdmissionTests`** — the table above, parameterized.
- **`StoreMigrationTests`** — v1 populated → v2, no row lost.

End to end, against the fake `claude`, without spending a token or touching
GitHub. `Scripts/fake-claude.sh` gains `FAKE_CLAUDE_STORIES`: it greps its own
`-p` argument for `ELLIOT_OUTPUT=` and drops the fixture there before replaying
the NDJSON. The test then runs: start an analysis on two angles → two runs →
proposals harvested with their duplicate hints → accept two → two Backlog cards
→ drag one to To Do → `create-issue` fires. One test crosses every new seam and
joins them to the existing ones.

Plus a sentinel fixture: a fake mode that touches a file in the repository, to
confirm that an analysis which modified your code is reported.

## Out of scope

- Scheduling analyses (nightly, on push). Manual and MCP only.
- Comparing two analyses over time, or tracking whether a proposal was later
  implemented.
- Turning the analysis prompt into a plugin skill. Elliot owns it for now;
  extracting it is a v2 question and the artifact contract would not change.
- Ranking or scoring proposals beyond `effort` and the angle they came from.

## Risks

1. **The model ignores the artifact instruction** and answers in prose. Mitigated
   by the fenced-block fallback, and visible either way because the harvest
   source is recorded. If it turns out to be the common case, approach B becomes
   the primary path and nothing else in the design changes.
2. **Proposal quality is unknown until it is tried.** The evidence requirement
   and the `exists` check are the only objective handles on an opinion. Expect
   the briefings to need iteration; they are data, so iterating is cheap.
3. **Cost.** Three angles on a large repository is three full reads. The stories
   cap bounds the output but not the input. The window shows the running total.
4. **An analysis writes to the repository.** Cannot be prevented, only detected —
   see the git sentinel.
5. **Duplicate hints depend on `gh`.** With `gh` unavailable, deduplication falls
   back to local cards only, and the window says so rather than implying the
   check was complete.
