# Portfolio standards → pre-filled backlog cards

*Design, 2026-08-07. Written in English to match the rest of the repository.*

## Why

Preflight answers **"can Elliot act in this repository?"** — tools on PATH, `gh`
authenticated, a repo profile committed, the main checkout rather than a linked
worktree. Any `.fail` blocks every drag in that repository, which is right,
because none of those cards could execute.

There is a second question Preflight deliberately does not answer: **"is this
repository the way I want it?"** Every repository should publish through Trusted
Publishing, carry the house `.editorconfig`, extend the shared Renovate preset,
have a CI that can judge a pull request. A repository failing any of those runs
fine — so folding them into Preflight would make a missing `.editorconfig` block
card execution, which is absurd.

That second question already has a written answer:
`repo-audit/skills/elliot/references/standard-portefeuille.md`, ten axes, each
with a "conforme quand" and the command that measures it. Its first line is the
same discipline `CheckResult.command` states: *an axis only enters this file if a
command measures it; an axis without a measure is an opinion.*

What it does not have is a route from "measured non-compliance" to "work that
gets done". This is that route. A violation becomes a **pre-filled Backlog
card**, and from there the board's one funnel does the rest: Backlog → To Do
files an issue, To Do → In Progress implements it.

## The finding that reframes the work

**The standard is not one rule. On four axes out of five, the prose and the code
disagree, and the code disagrees with itself.**

| Axis | Implementations found | Do they agree? |
|---|--:|---|
| `topics` | 4 (`inventory.py`, `portfolio_board.py`, `ProbeSource.cs`, the prose) | No — 21 / 21 / 29 / 38 depending on who counts. `UBIQUITOUS = {"dotnet","csharp"}` exists but is used **only** to build the topic index, never in the predicate. |
| `licence` | 2 (`license_proposal.py` proposes, nothing judges) | The prose describes neither. The code keys LaTeX papers on `primaryLanguage ∈ {TeX, Roff}`, not on a topic. |
| `renovate` | 2 (presence in `foundations_probe.py`, byte-equality in `renovate_v2.py`) | No — a repo with the old `config:recommended` is compliant for the counter and non-compliant for the deploy. |
| `editorconfig` | 1 (presence of a filename) | The prose says "the house template". **Zero bytes of the file are read anywhere in `repo-audit`.** |
| `ciJudgeable` | 2 predicates at two cardinalities, never joined | Trigger liveness is per repository; "a green is a build" is per PR. |

So porting to Swift is an **arbitration**, not a translation. For each axis
Philippe has to pick which of the existing answers is *the* standard. That
decision belongs in this spec, in the commit message, and — where the number
moves — in the card body, so a counter jumping from 21 to 38 does not read as a
regression.

⛔ This also kills the tempting shortcut of "port it, then diff the two counts to
prove the port". On four axes there is no single count to diff against.

## Decisions

| Question | Choice |
|---|---|
| Scope of **measurement** | The whole portfolio, on `origin`, via the GitHub API. Never local clones — 200 of 244 were desynchronised, and a clone does not know it is behind. |
| Scope of **cards** | Registered repositories only. `createCard` requires a `Repo` row; an unregistered violator offers *Register*, not a card. |
| Where the predicate lives | `ElliotModel`, pure. Gathering lives in `ElliotProcess`/`ElliotEngine`. This is why Swift is a better home than Python: `foundations_probe.probe()` interleaves the `gh` call and the judgement in one function. |
| Where exemptions live | `.elliot/standards.yml`, **committed in the measured repository**, read over the API. The arbitration travels with the code and is reviewable in a PR. |
| What a **violation** becomes | A `StoryProposal`, riding the existing table and accept/reject pipeline. It needs a provenance change to the type — see below; it is not a drop-in. |
| How it lands | **Auto-accepted.** The card reaches Backlog directly, as decided. Deleting the card marks the proposal `rejected`, so the sweep does not re-file it. |
| Blocking | **Never.** Standards verdicts stay out of `AppModel.repoChecks`; `PreflightService.isBlocking` treats any `.fail` as blocking every drag, and a missing `.editorconfig` must not stop execution. |
| Deleting the Python | Only per axis, and only behind the parity harness's second bar. |

### Why auto-accepted rather than filed directly

A card filed directly has a defect the proposal path does not: delete it and the
next sweep re-files it, because `existingCard(forKey:)` looks at the **live**
`card` table. On this board a card is an agent — dragging the returned card
spawns `claude -p` into a repository the user had just refused. `ProposalStatus`
already models "the user said no"; `dismissedExternal` (v5) is the same idea a
second time. A third table would have been the fourth.

## What this does not touch

The rule engine, `TriggerAction`, the five columns and the three skill-firing
transitions. A sweep is not a move; a finding is not a card until it is accepted.
`BoardService` remains the only writer of `column`, and `StandardsService` reaches
it through `BoardService.createCard` like everything else.

Preflight is unchanged. Its checks stay local, blocking, and about execution.

## Model

Placement follows the dependency graph, not convenience.

| Type | Target | File |
|---|---|---|
| `Standard`, `Applicability`, `NotApplicable`, `LicencePolicy` | ElliotModel | `Standard.swift` |
| `Provenance`, `Observation`, `Unmeasured`, `FreshnessPolicy` | ElliotModel | `Observation.swift` |
| `RepoTree`, `RepoMeasurement` | ElliotModel | `RepoMeasurement.swift` |
| `Exemption`, `StandardsFile`, `StandardsFileParser` | ElliotModel | `StandardsFile.swift` |
| `StandardVerdict`, `Violation`, `StandardFinding`, `RepoStandardsAssessment` | ElliotModel | `StandardVerdict.swift` |
| `StandardsEngine` | ElliotModel | `StandardsEngine.swift` |
| `ProposalOrigin` (extends `StoryProposal`) | ElliotModel | `StoryProposal.swift` |
| `StandardsService` (collection, fan-out, proposal emission) | ElliotEngine | `StandardsService.swift` |

### `StandardFinding` and `StoryProposal` are not the same object

A `StandardFinding` is the **verdict** — one per (repository, axis), in all five
cases, for the whole portfolio including unregistered repositories. That is what
the table holds and what the counters read.

A `StoryProposal` is only ever produced for a `.violating` finding in a
**registered** repository, because `StoryProposal.repoID` is a non-optional `UUID`
and `createCard` guards on the `repo` row existing. A violation in an
unregistered repository is recorded, counted, and offers *Register* — it does not
silently vanish, and it does not auto-register anything behind a sweep.

**`StoryProposal` needs one change to accept a standards finding**, and pretending
otherwise would be the drift this spec exists to prevent. Today it carries
`analysisID: UUID`, `runID: UUID` and `angle: AnalysisAngle`, all non-optional —
a sweep has no analysis, no Claude run, and a `Standard` rather than a lens.
Replace those three fields with one provenance enum:

```swift
public enum ProposalOrigin: Codable, Sendable, Hashable {
    case analysis(analysisID: UUID, runID: UUID, angle: AnalysisAngle)
    case standard(Standard, sweepID: UUID)
}
```

This is the shape `CardOutcome` already uses for the same problem —
`Attribution.live` versus `.launchSweep`, one value, two provenances — and the
reason `Card.angle` documents itself as *provenance, not classification*. The
alternative, three optional fields plus an unwritten rule about which combination
is legal, is a second implicit enum that no compiler checks.

⚠️ `Card.angle: AnalysisAngle?` is rendered as a mark on the board and is
documented as never re-derived. A standards-born card must render its `Standard`,
not a nil lens and not a borrowed one; that is a view change, and by this
repository's own rule it is not finished until someone has looked at it.

### `Observation` — the apparatus that must cover *everything*

```swift
public struct Provenance: Codable, Sendable, Hashable {
    /// The exact invocation, so a reader can re-run it rather than take Elliot's
    /// word — the contract `CheckResult.command` already states.
    public var command: String
    public var observedAt: Date
}

public enum Unmeasured: Codable, Sendable, Hashable {
    case requestFailed(String), rateLimited, notPermitted
    /// The git-trees API set `truncated`. A path absent from a truncated tree
    /// proves nothing. `foundations_probe.py:53` pipes through `--jq .tree[].path`,
    /// which throws the flag away before anyone can read it.
    case treeTruncated
    case stale(age: TimeInterval)
    case exemptionsUnreadable(String)
    case exemptionsMalformed(line: Int, detail: String)
}

public enum Observation<Value: Codable & Sendable & Hashable>: Codable, Sendable, Hashable {
    case observed(Value, Provenance)
    case unavailable(Unmeasured, Provenance)

    /// Deliberately no `valueOrDefault`, no `?? []`, no `Bool` accessor.
    /// `(try? …) ?? []` is the one line that turns a rate limit into "no files
    /// found", i.e. non-compliant on every axis at once.
    public func value(freshAt now: Date, policy: FreshnessPolicy) -> Result<Value, Unmeasured>
}
```

**The universe is an `Observation` too — this is load-bearing.** `assess` takes
`Observation<GHRepoSummary>`, not a bare summary, and step 0 unwraps it before
`applicability` is consulted. Left bare, a six-hour-old `gh repo list` renders a
just-unarchived repository `.notApplicable(.archived)` and a just-created one as
no row at all: **a perfect green on an amputated denominator**. That is precisely
the defect `foundations_probe.py` shipped — 25 active repositories invisible,
including a paying client and the tooling itself, while the counter read "0
missing". Reproducing it in Swift is the one outcome this subsystem exists to
avoid.

### `RepoTree` — three-valued, and `paths` is private

```swift
public struct RepoTree: Codable, Sendable, Hashable {
    private var paths: Set<String>
    public var truncated: Bool

    public func contains(_ path: String) -> Bool? {
        if paths.contains(path) { return true }
        return truncated ? nil : false
    }
    /// nil when truncated — an enumeration over an incomplete list is not a set.
    public func paths(withPrefix prefix: String) -> Set<String>?
}
```

`paths` is **private**. `ciJudgeable` and `dependencyAutomation`'s tier
calculation *enumerate* rather than look up, and a monorepo whose truncation
falls before `.github/workflows/` would yield an empty set → "no workflow
triggers on a PR" → `violating` → card → agent. A false positive that spends an
unattended run. A source-reading test in the `DrainDuplicationTests` idiom fails
if `.paths` appears outside `RepoMeasurement.swift`.

### `StandardVerdict` — five cases, no `Bool`

```swift
public enum StandardVerdict: Sendable, Hashable {
    case compliant(detail: String)
    case violating(Violation)
    case exempt(Exemption)
    case notApplicable(NotApplicable)
    case unmeasured(Unmeasured)

    /// The one question the emitter may ask. Deliberately no `isCompliant`:
    /// every caller that wants one wants it true for four of five cases, and
    /// `unmeasured` is not one of them.
    public var producesCard: Bool { if case .violating = self { true } else { false } }

    /// Excludes what was not measured, so a ratio can never be inflated by a
    /// failure.
    public var countsInDenominator: Bool {
        switch self {
        case .compliant, .violating, .exempt: true
        case .notApplicable, .unmeasured: false
        }
    }
}
```

`unmeasured` is first-class for the reason `RepoIssue.unlisted` gives in its own
comment: *a row that says "fine" when the real answer is "I could not check" is a
non-measurement rendered as a pass, which is the one thing this codebase spends
its effort refusing to do.*

### Scope reuses `RepoIssue.OutOfScope`

Fork and archived are **already** modelled, on the same `GHRepoSummary`, at
`RepoReconciliation.swift:36-47,175-183`. `Standard.applicability` must call a
factored `RepoIssue.OutOfScope.of(_:)` rather than re-read `isFork` for itself —
otherwise a repository can be `.notCloned` with an active *Clone* button in
Repositories and `.notApplicable(.empty)` in Standards at the same moment.

Order is the rule, not an implementation detail: fork → archived → empty → no
default branch → meta-repository → per-axis. A fork is reported as a fork
whatever GitHub thinks its language is.

### Age is two different things, and the design conflates them

- `observationLag = assessedAt − observedAt` — how stale the input was when the
  predicate ran.
- `staleness(at: now) = now − assessedAt` — how old the **verdict** is.

The primary key `(nameWithOwner, standard)` only overwrites on a *new*
measurement. If measurement stops — an expired `gh` token, a repository falling
into `standardSweep.skipped` every pass — August's row survives intact and reads
"3 s old" in November. Every view and every MCP reply passes the
`FreshnessPolicy` and degrades to `.unmeasured(.stale)` beyond it, through the
same function as `Observation.value`, not a second one. Rows carry `sweepID`.

A finding rests on up to four observations of different ages, so it holds
`provenances: [Provenance]` and its age is the **maximum** — the age of a verdict
is that of its oldest input, never its youngest.

## `.elliot/standards.yml`

Committed in the measured repository, read at
`gh api repos/{r}/contents/.elliot/standards.yml?ref=<default>`. **A 404 is a
fact** (no exemptions); any other failure is `.unmeasured(.exemptionsUnreadable)`
— fail closed, the way `add_editorconfig.py:40-44` treats a non-404 as SKIP
rather than as absence.

| Key | Req. | Notes |
|---|---|---|
| `version` | ✅ | `1`. An unknown version is a refusal, not a best-effort parse. |
| `repo` | ➖ | `owner/name`. Disagreeing with the repo under measurement → refusal (catches a copy-pasted file). |
| `exemptions[].standard` | ✅ | One of the raw values. Unknown → refusal. |
| `exemptions[].reason` | ✅ | Non-blank. Blank ⇒ not an exemption. |
| `exemptions[].granted_by` | ✅ | |
| `exemptions[].granted_at` | ✅ | `YYYY-MM-DD`. |
| `exemptions[].expires` | ➖ | Absent = permanent. Past = violation again. |
| `exemptions[].evidence` | ➖ | ADR path or issue URL. |

```yaml
version: 1
repo: phmatray/AtypWebsite
exemptions:
  - standard: ciJudgeable
    reason: >
      The only workflow is a Nuke + Docker deployment that publishes the public
      site image on push to dev. Removing its pull_request branch filter would
      arm docker/build-push-action on every PR and overwrite the public `latest`
      tag of the company site. A separate build-only PR workflow is the real fix
      and is tracked; until it lands this repository is knowingly unjudgeable.
    granted_by: philippe
    granted_at: 2026-08-07
    evidence: https://github.com/phmatray/AtypWebsite/issues/61
```

`StandardsFileParser` is **total and strict** — the `IssueMarkdownParser`
contract. It refuses what it does not understand rather than skipping it: a
silently skipped exemption line becomes a violation, a violation becomes a card,
and a card is an agent sent into a repository someone deliberately excused.

**Parser choice: hand-written, over a strict subset.** `ElliotModel` has no
dependencies by design and Swift has no stdlib YAML. Adding Yams to the purest
target to read an eight-key file is the wrong trade; JSON would be worse to write
and to review.

## Migration

**`v9_standards`.** `v7_cardAngle` is the last on `main`, but
`origin/feat/174-pr-status` registers `v8_prStatus`. Neither has landed, so this
is a race; taking v9 costs nothing if #174 lands first and leaves a harmless gap
if it does not. ⛔ Never rename after it has run anywhere without a
`RenamedMigration` entry carrying a schema check.

Two tables, keyed by `nameWithOwner` **and not `repoID`** — the measurement
universe is every repository of both accounts, the card universe is the
registered ones, and a UUID key could not hold a finding for an unregistered
repository. `repoID` and `cardID` are nullable with `ON DELETE SET NULL`, not
CASCADE: forgetting a registration must not erase the measurement of a repository
that still exists on GitHub.

`standardSweep` persists the `SyncSummary.skipped` contract — *what this pass left
out, and why*. A repository the sweep could not reach survives as a row.
Disappearing is how a probe reported 148 of 210.

GRDB conformance copies `DismissalRecord` verbatim: **`databaseUUIDEncodingStrategy`
is a function in GRDB 7**; as a `static var` it compiles, is ignored, writes
blobs, and the foreign key never fires.

## The pure function

```swift
public static func assess(
    repo: Observation<GHRepoSummary>,
    measurement: RepoMeasurement,
    exemptions: Observation<StandardsFile>,
    now: Date,
    freshness: FreshnessPolicy = .default
) -> RepoStandardsAssessment
```

Decision order inside `verdict`, which **is** the rule:

0. **Universe** — `repo.value(freshAt:policy:)`. A stale or unreadable universe is
   `.unmeasured`, never `.notApplicable`.
1. **Scope** — a fork is a fork whatever else is true, and an out-of-scope
   repository must never reach a predicate that could file a card into it.
2. **Exemptions** — before measurement, but an unreadable exemptions file is
   `.unmeasured`, never "no exemptions".
3. **Measurement** — every read is a `Result`, so a missing observation exits as
   `.unmeasured` instead of defaulting to a false.

## Porting order

Wave 1 is this spec. Waves 2 and 3 get their own.

| Wave | Axes | Why here |
|---|---|---|
| 1 | `editorconfig`, `dependencyAutomation`, `ciJudgeable`, `topics`, `licence` | genuine predicates over a path set plus `gh` metadata |
| 2 | README (21 features), TFM, community health | parsing, but deterministic and already specified |
| 3 | NuGet / Trusted Publishing, supply-chain patterns | six verdicts, three joined sources; the probe's own v1 misclassified four valid OIDC repositories by matching a *pattern instead of the thing* |

### What each wave-1 axis must arbitrate

- **`editorconfig`** — presence or content? Today: presence of a lowercased
  filename at the root (`foundations_probe.py:77`). `add_editorconfig.py` is
  create-if-absent and never overwrites, so a three-line CRLF file is compliant
  **for ever**. Measuring content needs one more API call per repository and a
  canonical artefact.
- **`dependencyAutomation`** — presence, or byte-equality against
  `json.dumps(…, indent=2) + "\n"`? ⛔ If byte-equality: **emit the literal
  string, never re-encode.** Foundation escapes `/` as `\/`, spaces differently
  around `:` when `.prettyPrinted`, and omits the trailing newline — 199 of 202
  repositories would flip to non-compliant on a formatting difference.
- **`ciJudgeable`** — repository half only (does any live workflow trigger on a PR
  to the default branch). The PR half ("a green is a build") is a different
  cardinality and belongs with `GHMergeStatus`, which today carries **only** a
  failure classifier: `failingChecks` has no notion of an inert green. Writing
  `var isGreen: Bool { failingChecks.isEmpty }` is the 43-greens-for-2 bug,
  verbatim.
- **`topics`** — four implementations, four numbers. Implement the **documented**
  rule (`topics − {dotnet, csharp}` non-empty, GitHub universe, forks excluded)
  and say so in the commit. ⚠️ `repositoryTopics` is `null` — never `[]` — on 66
  of 348 repositories; a non-optional `[Topic]` fails to decode the **entire**
  portfolio, since `gh` returns one array.
- **`licence`** — the code keys LaTeX papers on `primaryLanguage ∈ {TeX, Roff}`,
  not on a topic; porting the prose instead of the code gives CC-BY-4.0 to
  anything tagged `latex`. And `gh repo view --json licenseInfo` **omits
  `spdxId`** — read `.license.spdx_id` from the REST payload.

## Parity harness

A silently wrong port looks exactly like a correct one. The precedent is exact
and in this portfolio: a .NET board re-implemented a CI judge already fixed in
Python, read the aggregate rollup instead of the named checks, and reported **43
green PRs where there were 2** — nobody caught it because the number was
plausible.

The solution precedent is in this repository: `OfflineParityTests` drives one
seeded board through `MCPRequestHandler` and `OfflineResponder` and compares the
**encoded bytes**, precisely because the two cannot share code.

**Shape.** Freeze the *inputs* — the bytes `gh` returned for a captured corpus of
repositories — as versioned fixtures. Replay them into both the Python probe (via
a `PATH`-shimmed fake `gh`, the seam production already uses, so zero Python
edits) and the Swift predicate. Compare verdict-by-verdict. Offline,
deterministic, and it separates "my predicate moved" from "the world moved".

**Three defects to close in the harness itself**, each already identified:

1. ⛔ **`regenerate-goldens.sh` must not run the probe in place.** `foundations_probe.py`
   rewrites `foundations_gap.json` and both `fresh_<owner>.json` — three *tracked*
   files that arm `--commit` sweeps downstream (`renovate_v2.py:128`,
   `add_editorconfig.py:62`, `add_renovate.py:53`, `ci_pilot.py:80`). A golden
   regeneration would rewrite them with the frozen corpus's universe,
   indistinguishable from a routine refresh, and two weeks later
   `renovate_v2.py probe && deploy --commit` builds its plan on it. Copy the probe
   into a scratch directory (its `ROOT` follows `__file__`, so the copy redirects
   all three writes) and exit non-zero if `git -C repo-audit status --porcelain`
   on those paths is non-empty afterwards.
2. **The exit bar must be derived, not typed.** The proposed bar counts traps per
   axis as literals copied from the extraction dossier — and they are wrong on two
   axes. Parse `len(axis['traps'])` from the versioned dossier and fail, naming
   the trap, when one has no oracle case.
3. **Two of five axes cannot regenerate their goldens offline.** `ci_trigger_fix.py`
   and `inventory.py` read `inventory.json` and walk the disk under
   `repo_sync.require_fresh()`. Either capture those as corpus artefacts and point
   the tools at the copy by environment variable, or **state on the tin that Layer
   A covers three axes of five** — "3 of 5" is not "all", and a harness that
   overstates its coverage is the defect it exists to catch.

**Two bars.** *Ported* (the Swift may serve the board): parity on the corpus, plus
an oracle case per documented trap. *Deletable* (the Python may go): the axis has
survived a real sweep, and no other `repo-audit` tool reads its output — measured,
not assumed.

## Measuring is not acting

repo-audit has two halves and only one is ported here. The acting half —
`add_editorconfig.py --commit`, `renovate_v2.py deploy`, `ci_trigger_fix.py ship`
— writes by `GET` content → `PUT`, idempotent through markers, create-if-absent.

Routing all of that through cards does not work: `.editorconfig` on the 190
repositories missing it would be ~380 unattended `claude -p` runs in 190 real
checkouts, to deliver a file identical to the byte that a `PUT` per repository
delivers. Slower, dearer, less reliable.

The line is not measure/act, it is the **nature of the fix**:

| Nature | Tool | Examples |
|---|---|---|
| Templated, identical everywhere | a sweep — idempotent `PUT`, no agent | `.editorconfig`, the 2-line `renovate.json`, community health, a dead `pull_request` filter |
| Needs per-repository judgement | a card; the agent earns its cost | Trusted Publishing, TFM, README |

So "Elliot replaces repo-audit" implies Elliot growing a **second execution
mode**: templated writes by API, on a PR branch (portfolio rule 2), never
delegated to a subagent (rule 12). That is a real architectural addition to an app
that today has exactly one execution mode — moving a card — and it is **out of
scope for this spec**. Wave 1 measures and files cards; the sweep mode gets its
own design.

## Open questions

1. **`editorconfig`: presence or content?** If content, is
   `repo-audit/templates/editorconfig-dotnet` the authority, vendored or fetched?
2. **`dependencyAutomation`: presence or byte-equality?**
3. **`topics`: confirm 38** (the documented rule) over the four measured numbers.
4. **Rate limit.** ~343 × (tree + exemptions + workflows) is well into the 5000/h
   budget. Sweep cadence? And does a partial sweep merge into the previous
   measurement or replace it?
5. **Who may grant an exemption?** The file is committed in the measured
   repository, so anyone with write access can self-exempt. Fine for the
   portfolio; fine for `customers/`?
6. **Migration race** — v9 taken while `v8_prStatus` is unmerged. Renumber before
   landing if #174 is abandoned?

## Two defects found in `repo-audit` on the way

Independent of this work, and actionable today.

1. ⛔ **`add_editorconfig.py --commit` without `--only` targets 10 repositories,
   and all 10 are forks.** Verified: `isFork` is requested in
   `foundations_probe.py:39`'s `CHAMPS` and **never read** — one occurrence across
   the three tools in the chain. Twelve forks also sit in the `is_code`
   denominator. CLAUDE.md's "192/202, and the 10 remaining are all forks" is true
   but hand-produced; the tool is armed to do exactly what the standard forbids.
2. **The `.editorconfig` axis is unenforceable past the first pass.** It measures
   a filename, and the sweep is create-if-absent. A three-line CRLF file is
   compliant for ever.
