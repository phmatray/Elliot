# Auto-dev — the board drives its own cards

*Design, 2026-08-08. Written in English to match the rest of the repository.*

## Why

Moving a card is the act of execution. Today every move is a human gesture — a
drag, or an agent's `board_move_card`. Auto-dev is the board making those moves
itself: you pick a repository, say how many cards, press start, and walk away.

The loop takes N cards from Backlog and advances each one — files its issue,
implements it, waits for the pull request, merges it — until every card is
either merged or blocked. Then it stops and says what happened.

Most of the machinery already exists. `rankNextSteps` already computes what a
card's next move would be and whether it is ready. `PRWatcher` already performs
In Progress → In Review on its own. `Reconciler` already establishes, after a
crash, what each run actually managed to do. `SchedulerLimits` and
`SpendCeiling` already bound the fleet. What is missing is something that
*decides to move*, and the restraint that decision needs when nobody is
watching.

## Decisions

These were arbitrated with the owner before this document was written.

| Question | Choice |
|---|---|
| How far the loop goes | To Done — but it merges **only on a verified green**. |
| Where cards come from | The existing Backlog. **No analysis inside the loop.** Optional automatic selection of the highest-value cards. |
| Who judges value | A **pure function**. An agent may *fill in* a card's missing signals; it never ranks. |
| Resume after a crash | `claude -p --resume <old> --fork-session --session-id <new>`. |
| What N counts | Cards **engaged**, fixed at start, never an N+1st. The session ends when each is merged or blocked, and writes a report. |
| A blocked repository | `repoDisabled` and `repoBlocked` abort the **whole session**, not one card. |
| Where the loop lives | An `AutoDevService` actor in `ElliotEngine`, mirroring `AnalysisService`. Not in `RunScheduler`; not an external MCP agent. |

## What the verification changed

This design was reviewed against the code by twelve readers, six of them
adversarial, plus a completeness critic. Their verdict on the first draft was
`needs-change` — on the **split**, not only on the parts. The corrections are
folded into the sections below; five are large enough to name here, because
each one reverses something the first draft asserted.

1. **The green guard was on the wrong event.** `evaluateMove` decides at
   `proposeMove` time, but `commitMove` writes the card and inserts the run in
   one transaction (`BoardService.swift:141-146`), and `pump()` may then hold
   that run: `refusal(for:)` returns `.mergeWaitsForRepoToBeIdle` while *any*
   run is going in the repository (`RunScheduler.swift:234`), the refused run
   returns to `pending` with no ageing, and `start(_:)` re-reads only the
   repository (`:333`). `PRStatus.maximumAge` is 600 s (`PRStatus.swift:60`).
   Under a session that keeps one repository busy, the merge is *structurally*
   the most-delayed run — so auto-dev would merge on a reading the system
   itself calls stale. **The guard exists twice**: at the decision, and at
   admission.

2. **`sign == nil` is not green enough.** `PRStatus.sign` blocks only
   `.blocked` and `.behind` (`PRStatus.swift:306`), so `MergeState.unstable`
   reaches `return nil` — a pull request the panel paints in
   `Palette.attention` as *mergeable, not every check is green*. And
   `StatusCheck.isNonVerdict` filters only `SKIPPED|NEUTRAL|STALE`; its own
   comment says a genuinely-succeeded CodeQL run still counts as a pass
   (`GHPayloads.swift:176-184`). That was a defensible call for a display dot.
   Promoting it to merge authority is the portfolio's `renovate/stability-days`
   lesson, one repository over. See **Open decision** at the end.

3. **`unattended` was the wrong name, in the most load-bearing file.** The word
   already has a settled meaning here — roughly twenty uses in `Sources`, all
   naming the *child process*: "a drag spawns an unattended agent under
   `bypassPermissions`" (`SpendCeiling.swift:5`). A drag is the canonical
   unattended gesture in that vocabulary, and the first draft would have built
   it with `unattended: false`. The field is `requiresVerifiedGreen`, it names
   the rule rather than the spectator, and it is **set explicitly by the
   caller** rather than derived from `MoveOrigin`.

4. **PR1 is not "nothing on screen".** A new `MoveBlock` case breaks four
   exhaustive switches (`RuleEngine.swift:26-36`, `Consequence.swift:91-101`,
   `NextRendering.swift:13-23`, `:26-41`) and three literal test lists that
   will *not* redden. `Consequence.reason` is the column legend and the refusal
   note on the card, so PR1 necessarily ships a sentence of interface.

5. **`.appraiseCards` starts outside the funnel.** A run produced by appraising
   cards passes through no transition — no `evaluateMove`, no
   `allowsSideEffects`, no `repoPreflight`. It is the only unattended agent in
   the system that starts outside "moving a card is the act of execution", and
   the only one on which the abort rule has no point of application. Its guard
   is therefore built explicitly, in `ElliotEngine`.

## What this does not touch

The five columns and the four transitions are unchanged. `BoardService`
remains the only thing that changes `Card.column`. `evaluateMove` remains the
only decision, and `rankNextSteps` keeps deciding by calling it.
`CardOutcome.applied(to:)` remains the only thing that says what a verified
outcome does to a card — auto-dev reads that answer and never writes a card
field of its own.

Auto-dev does not spawn a process. Every run it causes goes through
`launcher.launch` → `pump()` → `refusal(for:)`, so `SchedulerLimits`,
`SpendCeiling` and the repo-exclusion rules bind it exactly as they bind a
drag. There is no second path.

---

## PR1 — The rules

`ElliotModel`, plus the interface sentences the compiler demands.

### `MoveOrigin` gains a case

```swift
case autoDev(sessionID: UUID)
```

`allowsSideEffects` **becomes an exhaustive switch** rather than staying
`if case .system = self { return false }; return true`
(`SkillRun.swift:227-230`). The current form is why a new case inherits `true`
in silence — on the single property that decides whether an unattended agent
starts. A switch makes the fifth case a compile error instead of a gift.

Three sites read `MoveOrigin` with a `guard case .system` and would swallow
`.autoDev` silently. Two of them matter, and both must learn the new case in
this PR:

- `Consequence.arrivalNote` (`Consequence.swift:110-118`), rendered at
  `DetailPanelView.swift:240` — otherwise a card moved by auto-dev explains
  nothing about how it got there.
- `NotificationPolicy` (`NotificationPolicy.swift:144`) — otherwise an
  unattended session produces **no notification at all**, which is the worst
  possible silence for the one feature that runs with nobody watching.

`MoveOrigin.historyLabel` (`Consequence.swift:133-145`) is the one exhaustive
switch; the compiler will ask for it.

`MoveOrigin` does **not** travel on the IPC wire — `ElliotRequest.moveCard`
carries `(id, to, followUps)` (`Protocol.swift:107`), `MoveDTO` carries no
origin (`:667-697`), and `MCPRequestHandler.moveCard` hardcodes
`.mcp(client:)` (`MCPRequestHandler.swift:302`). **No protocol bump.**

⚠️ **Corrected 2026-08-09.** This read "`elliotProtocolVersion` stays 6
(`Protocol.swift:46`)". No bump is right and is the claim that matters; **6 is
not**. `origin/main` carries **7**, and has since before PR1 was written — the
number was read off a merge base twenty-three commits behind, exactly the
mistake that made PR1's whole prerequisite premise false. A wire version quoted
in a document that does not change it is a number nothing keeps true. Read it
from `Protocol.swift`.

It *is* persisted, as JSON text in `moveAudit.origin`
(`Migrations.swift:344`), through the synthesised `Codable`. A new case is
additive for reading existing rows; an older build cannot read a new one.
There is no downgrade path, and the migration note says so.

### `MoveContext` gains two fields, without defaults

```swift
/// This move must not merge on anything short of a verified green.
/// Named for the rule, not for the caller: `.mcp` and `.userDrag` set it
/// false today, and a future caller that wants the restraint asks for it
/// by name rather than by claiming to be unwatched.
public var requiresVerifiedGreen: Bool
/// What `gh` established about the pull request, already resolved against
/// the clock and the current head. `nil` is *nothing established*, which is
/// not a green.
public var prVerdict: ResolvedPRStatus?
```

**No default values.** The memberwise init defaults every existing parameter
(`RuleEngine.swift:73-83`), so two defaulted parameters would compile
everywhere and nothing would catch the fourth construction site. Without
defaults, the three production sites (`AppModel.swift:1037`,
`BoardService.swift:98`, `RuleEngine.swift:220`) and roughly twenty test
constructions refuse to build until each has stated its answer. The template is
`providedFollowUps`, whose two sites diverge deliberately.

`ResolvedPRStatus` is already `Sendable, Hashable` in `ElliotModel`
(`PRStatus.swift:213`), so this costs no conformance and no new dependency.

### `MoveBlock` gains a case that carries its cause

```swift
case notVerifiedGreen(reason: NotGreenReason)
case systemOwnedTransition
```

⚠️ **This carried `sign: PRSign?` until it was implemented, and that was wrong** — found by a
reviewer working beside its own task, on 2026-08-09, after the case had already landed and
passed review. `nil` was documented here as *nothing was read*, while `PRSign` documents `nil`
as *everything known is fine* (`PRStatus.swift:160-162`): the same optional, opposite meanings,
two files apart.

It was not academic. `isMergeableUnattended` refuses **while `sign == nil`** in exactly the two
holes it exists to close — `merge == .unstable`, and an analyser-only green — and in both the
pull request *was* read. The feature's two flagship refusals would have rendered as "nothing has
been read about this pull request".

The payload is therefore the reason, total by construction:

```swift
public enum NotGreenReason: Equatable, Sendable, Hashable {
    case noReading                 // nothing came back: no row, or `gh` unreachable
    case sign(PRSign)              // a sign names it; `PRSign.summary` already says it well
    case notClean(MergeState)      // read, and not `.clean` — `.unstable` above all
    case noBuildVerdict            // read, clean, unsigned, and every green is an analyser
}
```

`code` stays `"not_verified_green"`.

⚠️ **Corrected 2026-08-09, in the final review of PR1.** `noReading` was
implemented — and commented here — as covering a **stale** reading too. It must
not. Stale means the stored row describes a commit that is no longer the head:
somebody pushed while the board was deciding. That is the *most likely* refusal
in production, and it is not "nothing has been read"; it is the same defect that
turned this payload from a `PRSign?` into a reason, one layer further in. It
answers `.sign(.unknown)`, whose sentence already exists and is already right —
`resolved(now:)` stamps a stale row `sign: .unknown`, and `PRSign.unknown.summary`
reads *"Not established — the reading is missing, aged out, or from an older
commit."* `noReading` keeps the two facts it genuinely cannot separate: no row at
all, and a row `PRVerdictReader` could not check because `gh` was unreachable.

`code` is `"not_verified_green"` and `"system_owned_transition"` — snake_case,
per the rule written at `Protocol.swift:398-401`.

⚠️ **Corrected 2026-08-09.** This said the sentence was "written once, from
`sign?.summary ?? "No reading of the pull request."`". Both halves are now
wrong. There is no bare sign to fall back on, and the sentence is written
**twice, deliberately** — a four-arm switch in each renderer
(`NextRendering.swift`, `Consequence.swift`), phrased in each one's own voice.
`RefusalWordingTests` asserts the two stay *different* and that neither contains
the other, so a single shared string would fail it. `PRSign.summary` still does
the work inside the `.sign(_)` arm, which is the only arm that has a sign.

The second case exists so the refusal is *truthful*. Reusing
`notVerifiedGreen` for In Progress → In Review would tell the reader the CI is
the problem when the real answer is that this transition has one owner.

Adding the case is a compile error at four sites and a **silent** omission at
three test literals (`AppModelTests.swift:282-285`,
`RunsPaneEmptyStateTests.swift:127-130`, `NextRenderingTests.swift:114-117`).
Those three are replaced by a local exhaustive `switch`, so the next case
cannot slip past them either.

### Two branches of `evaluateMove` change

```swift
case (.inProgress, .inReview):
    // Filled by PRWatcher alone. A caller that requires a verified green asking
    // for it is asking to skip the pull request entirely, and `arrivalNote`
    // could not explain such an arrival — it only knows `.system` reasons.
    if context.requiresVerifiedGreen { return .blocked(.systemOwnedTransition) }
    return .noAction

case (.inReview, .done):
    guard let pr = card.prNumber else { return .blocked(.missingPRNumber) }
    if context.requiresVerifiedGreen {
        guard let verdict = context.prVerdict, verdict.isMergeableUnattended
        else { return .blocked(.notVerifiedGreen(reason: verdictRefusal(context.prVerdict))) }
    }
    guard let followUps = context.providedFollowUps else {
        return .needsInput(.followUps(prNumber: pr))
    }
    return .action(.mergePR(prNumber: pr, followUps: followUps))
```

`isMergeableUnattended` is a new computed property on `ResolvedPRStatus`, and
it is **not** `sign == nil`. See **Open decision**.

The guard sits **before** `providedFollowUps` on purpose: a caller that
requires a verified green can never usefully receive `.needsInput`, whose own
documentation says the information "only a human (or an explicit tool
argument) can supply" (`RuleEngine.swift:39-40`). A loop with no human can only
read that return as "blocked, I will try again" — a loop that spins. The
invariant is stronger than the ordering, so it is pinned as a property test
over all 25 transitions rather than as one assertion here.

### `nextCandidates` keeps `requiresVerifiedGreen: false` — deliberately

`board_next` answers *what an agent can do*, and an agent is a human's proxy
with a human behind it. Two existing tests establish this today by accident
(`NextStepTests.swift:83-93`, `:125-132`); a test now establishes it on
purpose, with the reason in its name.

The reason is sharper than the tests: **`OfflineResponder` cannot know a
verdict.** If `nextCandidates` demanded one, the offline answer would mean
"I could not ask" while encoding as "the CI is not green" — and
`OfflineParityTests` compares encoded bytes (`OfflineParityTests.swift:43-45`),
so it would pass green on exactly that disagreement. `AutoDevService` builds
its own `MoveContext`; it does not borrow the board's.

### Reading the verdict

One helper, internal to `ElliotEngine`, called by both `BoardService` and
`MCPRequestHandler.prStatusDTO` — not a fourth hand-written
`resolved(now: Date(), currentHeadOid: nil)`. Both live in the same module, so
the target-boundary excuse at `MCPRequestHandler.swift:588-591` does not apply.

It passes the **real** `currentHeadOid`, read from the `gh pr list` that
`PRWatcher` already performs (`GHClient.swift:117`), never `nil`. Passing `nil`
disables the sha rule (`PRStatus.swift:251-253`) and leaves the 600-second age
as the only protection — while `PRWatcher` backs off to ~300 s ± 20 %
(`PRWatcher.swift:88-95`, `:164-167`). For a merge, that is not enough.

---

## PR2 — The value

### What travels, and why it is a schema question

`StoryProposal` carries `effort: Effort` and `evidence: [Evidence]`
(`StoryProposal.swift:171-172`). `AnalysisService.accept` calls
`board.createCard(repoID:title:body:story:column:angle:)`
(`AnalysisService.swift:207-217`) — and both die there. The Backlog therefore
carries almost nothing to rank by.

**Where they land depends on who writes them, and the criterion is written in
the code.** The v8 comment (`Migrations.swift:118-127`) says a datum decided by
`VerifiedOutcome.applied(to:)` belongs on `card`, while an observation written
by a poller belongs in its own table, because "mixing the two families on one
type, with nothing marking the boundary, is how the next person writes a card
field from the watcher and nobody notices".

**Decision: columns on `card`, and PR6 writes them inside the funnel.** The
appraisal run carries a `cardID` (see PR6), so `activeRun(cardID:)`
(`BoardStore.swift:746`) holds the card for the run's whole duration and closes
the read-modify-write window in both directions. That is what makes them
provenance rather than observation, and it is what makes v7's columns the right
precedent instead of v8's table.

The counterpart is measured and favourable: `observeCards()` uses
`.removeDuplicates()` over `[Card]` (`BoardStore.swift:631-638`), so a column
write is observable for free, where a separate table costs a second
`ValueObservation` — priced at `BoardStore.swift:640-648`.

```swift
public var effort: Effort?
public var evidence: [Evidence]?
public var appraisedAt: Date?
```

`evidence` is optional, not `[]`, for the reason at `BoardStore.swift:41-47`.
Before that reasoning reaches a pull request body, it is **measured**: rewind a
store below the new version (template: `SchemaUpgradeTests.rewindToV1`,
`SchemaUpgradeTests.swift:73-101`), open it with a new build through
`BoardStore.openReadOnly`, call `cards(repoID:)`, and see whether it throws.

`appraisedAt` is the third state. Without it, "nobody has ever appraised this
repository" and "this card was appraised and has no signal" are the same value
— the exact collapse `AnalysisRunReport.workingTreeChanged` exists to prevent
one type away (`Analysis.swift:64-72`).

### `Effort` gains `unstated`

`Effort.parse` folds "the model said nothing" onto `.medium` in three places
(`StoryProposal.swift:29`, `:62`, `:96-100`). For a display badge that is a
kindness; as an input to an unattended ranking it is an invention. `parse`
returns `.unstated` for anything unrecognised, the two decode defaults stop
saying `"medium"`, and `.medium` survives only as a rendering choice.

**This is a joint constraint with PR6**: adding `.unstated` without imposing it
on PR6's decoder changes nothing, and imposing it on PR6 without adding it here
does not compile. Whichever ships second carries the other half.

### `Grounding`, not a `Bool`

`StoryProposal.isGrounded` (`:212-214`) conflates two different facts. Replaced
by an enum in `ElliotModel`, shaped like `PRSign`:

```swift
public enum Grounding: Sendable, Hashable {
    case notCited                 // nobody ever cited a file — a silence
    case grounded                 // every cited file was found
    case missing(count: Int)      // files were cited and are not there — an admission
}
```

with a `code: String` that is deliberately not the case name, and a
one-sentence `summary`. `StoryProposal.isGrounded` becomes a call into it, so
there is one definition and two readers.

### `CardValue`

```swift
public enum CardValue: Sendable, Hashable {
    case ranked(score: Double, because: [Signal])
    case ungradeable(because: Grounding)
    case neverAppraised
}
```

**Not a `Double?`.** An optional invites `?? 0`, and "absence becomes the
lowest score" is precisely the failure `CIState.noChecks` exists to prevent.
Here it would mean every hand-written and every imported card silently sinking
to the bottom of an unattended queue.

The three angle/effort/grounding weights are **data**, in the shape of
`AnalysisAngle.briefing` — adding a lens stays "a case and a number".

**A card that is not `.ranked` is refused, never ranked low.** Neither
`.ungradeable` nor `.neverAppraised` may enter a comparator: a sort has to put
an absence *somewhere*, and both answers are wrong — at the bottom, auto-dev
never engages a hand-written card; at the top, it engages first what nobody has
measured. The refusal is spoken in the existing vocabulary: a sentence that says
nothing has measured this card, not a rank.

The verdict is decided on **content**, never on the column:
`.ungradeable` when `evidence?.isEmpty != false || effort == .unstated`, and
`.neverAppraised` when `appraisedAt == nil`. The measured counterexample is in
the test: `ProposedStory(evidence: ["   "])` passes `isUsable`
(`StoryProposal.swift:79-81`) and `ProposalDecoder.swift:76`, then
`ProposalHarvester.resolve` (`:121-138`) empties it — so a backfilled card
carries `[]` and must fall to `.ungradeable`, not to a low score.

### Closing the write window before an agent stands in it

`commitMove` writes the whole card row from a `Card` read three `await`s
earlier, and the three pollers do the same. The window is symmetric, so a
one-directional fix leaves the other half. It is closed by ownership: the
appraisal run holds its card (PR6), so no poller can write it concurrently.
Both directions are tested.

`CardFieldWritersTests` — in the idiom of `DrainDuplicationTests` — reads
`RunScheduler.swift`, `Reconciler.swift` and `PRWatcher.swift` and fails,
**naming the field**, if any of
`issueNumber|issueURL|prNumber|prURL|branch|lastError|effort|evidence` appears
followed by ` = `. The invariant holds today (the four occurrences in those
files are reads: `PRWatcher.swift:112`, `:114`, `:147`, `:149`) and is held
only by prose in CLAUDE.md. PR2 and PR6 widen the protected set at the exact
moment an unattended agent becomes a writer, which is the right moment to make
the grep a test.

---

## PR3 — The resume

**PR3 produces a verdict, not a relaunch.** Who relaunches, how many times and
under what bound belongs to `AutoDevPolicy` in PR4. Written the other way, PR3
ships an unbounded loop: a refused fork costs nothing and returns instantly, so
"relaunch, without spending an attempt" is a spin.

### The argv

```swift
// ClaudeInvocation
/// The session to fork from. `nil` is a fresh conversation.
public var resumeFrom: UUID?
```

The three tokens are built in **one** `if let`, after `"--add-dir", cwd`:

```swift
if let resumeFrom {
    args += ["--resume", resumeFrom.uuidString.lowercased(), "--fork-session"]
}
```

One block is the point: a bare `--resume` without `--fork-session` becomes
inexpressible, which is a guarantee rather than a test. The CLI enforces the
pairing anyway — *"--session-id can only be used with --continue or --resume if
--fork-session is also specified"* — and this shape means we never meet it.

Measured on 2026-08-08 with Elliot's real flags: the forked run's `result`
carries `"session_id"` equal to **the id we passed**, so `runID == sessionID`
survives, `StoreLocation.runLogURL(runID:)` is unchanged, and the run stays one
row.

`start(_:)` passes **`run.cwd`**, not `repo.path` (`RunScheduler.swift:343`).
The CLI's transcript lives under a slug of the cwd of the first attempt; two
sources for one fact make the resume fail silently with `No conversation
found`, which is the entrance to the spin.

### The verdict

```swift
// ElliotModel, pure
public enum ResumeVerdict: Sendable, Hashable { case sessionGone, ran }

public static func of(resumedFrom: UUID?, result: RunResult?) -> ResumeVerdict
```

`.sessionGone` requires the **full** predicate, not `numTurns` alone:

```
resumedFrom != nil
  && result.isError
  && result.numTurns == 0
  && result.subtype == "error_during_execution"
  && result.errors.contains { $0.hasPrefix("No conversation found") }
```

`RunResult` already decodes `subtype`, `numTurns`, `sessionID` and `errors`
(`StreamEvent.swift:61-99`), so nothing new is parsed. This makes PR3 the first
consumer of `errors`, which is decoded and read nowhere.

The verdict is computed in `RunScheduler.finish`, where `numTurns` exists
(`RunScheduler.swift:430`), and **passed to** `completeCardRun` — not used to
skip it. Verification always happens; what changes is the `reason` carried by
`.noIssueCreated` (`Verifier.swift:66-70`), which must not be the `resultText`
of a run that never had a turn.

### The one thing that must be fixed before PR3 ships

`Verifier.verifyCreateIssue` filters on `since = run.startedAt ?? run.createdAt`
(`Verifier.swift:39`). For a resumed run that is the **resume's** start, so an
issue created by the first attempt falls outside the window, the verifier
reports nothing created, and the loop files a second issue. With no human
watching, that is duplicate issues on github.com.

`since` becomes the start of the **first** attempt in the chain. The principle
is already written three files away: *"recency must never be a filter"*
(`PRMatcher.swift:26`).

### `SkillRun.resumedFrom`

Documented, word for word, as **the last attempt that actually created a
session** — unchanged when the predecessor was refused, advanced when it ran.
Anything vaguer makes the chain unreadable after two failures.

---

## PR4 — The loop

### The session

```swift
public struct AutoDevSession: Identifiable, Codable, Sendable, Hashable {
    public var id: UUID
    public var repoID: UUID
    public var engagedCardIDs: [UUID]     // fixed at start, never grows
    public var maxAttemptsPerCard: Int
    /// How long a card may sit on one unchanged reason before it settles.
    /// On the session rather than a constant: a repository whose CI takes an
    /// hour and one that takes ninety seconds do not want the same answer.
    public var patience: TimeInterval
    public var startedAt: Date
    public var endedAt: Date?
    public var state: State               // running | paused | finished
}
```

plus one row per engaged card — `(sessionID, cardID, attempts, disposition,
reason, updatedAt)` — because that is what the report renders, and a JSON blob
does not join.

**The engaged list is closed at start.** Every card auto-dev may touch is
decided in one write, at one moment, by a person. A card dragged into Backlog
mid-session is invisible to it.

Session and rows land in **one transaction**, the shape and the reason of
`AnalysisService.saveAnalysis(_:runs:)` (`AnalysisService.swift:118-124`).

`Records.swift` needs both halves of the conformance:
`databaseTableName`, and `databaseUUIDEncodingStrategy(for:)` as a **`func`**,
never a `static var` (`Records.swift:8-14`, `:113-118`).

### Advancing is re-evaluation, not progression

On each event — `RunScheduler.updates` on `.runFinished`, plus a new observation
hook on `PRWatcher` shaped like the `SystemMoving` it already holds — the
session walks its unsettled cards and calls
`board.proposeMove(cardID:to: naturalNext, origin: .autoDev(sessionID:),
requiresVerifiedGreen: true)`.

Nothing is remembered between rounds. There is no cursor saying "this card is
at step 3"; the question is asked again. That is what makes resuming after a
crash trivial: there is no state to rebuild.

It always passes `followUps: []` — merge, filing nothing of its own. Follow-ups
genuinely found in the pull request are filed by `merge-pr` itself.

### `AutoDevPolicy`, pure, with the clock injected

The idiom is `PRStatus.resolved(now:currentHeadOid:)` — "the clock, passed in
so this stays pure".

```swift
AutoDevPolicy.disposition(
    block: MoveBlock, attempts: Int, unchangedSince: Date, now: Date
) -> Disposition   // .retry | .wait | .held(QueueRefusal) | .settle(reason) | .abortSession
```

`prStatus` is passed **non-optional**, with an explicit `.noReading` case for
"the caller has none". Writing `resolved?.sign == nil` is forbidden by review:
it returns `true` for *no row at all*.

| refusal | disposition |
|---|---|
| `emptyIdea`, `incompleteStory` | `.settle` — no repetition completes a story |
| `missingIssueNumber`, `missingPRNumber` | `.wait` — the previous step has not landed |
| `runAlreadyInFlight` | `.wait` |
| `repoDisabled`, `repoBlocked` | **`.abortSession`** |
| `notVerifiedGreen(.sign(.checksRunning))` · `.sign(.unknown)` | `.wait` — and `.sign(.unknown)` is the ordinary *somebody just pushed* case, so it must wait rather than settle |
| `notVerifiedGreen(.sign(.noBuild / .conflict / .changesRequested / .reviewRequired / .mergeBlocked / .checksFailing))` | `.settle` |
| `notVerifiedGreen(.noReading)` | `.wait` — nothing has been read yet, which a later tick can fix |
| `notVerifiedGreen(.notClean(_))` | `.settle` — GitHub will merge it, but not every check is green, and waiting does not change that |
| `notVerifiedGreen(.noBuildVerdict)` | `.settle` — the only passing checks are analysers; no build is coming |
| `systemOwnedTransition` | `.settle` — the loop asked for a move that is not its to make; waiting cannot fix a category error |
| `sameColumn` | `.settle` — unreachable via `naturalNext`, and a `.wait` here would spin |

`.held` is distinct from `.wait` on purpose: `.paused`, `.dailyCeilingReached`
and `.mergeWaitsForRepoToBeIdle` are the scheduler holding a run, not the board
waiting on the world, and a report that confuses them sends the reader to fix
the wrong thing. Reading them needs more than `any RunLaunching`, which
declares only `launch`/`cancel` (`RunScheduler.swift:11-14`) — hence a
`RunQueueReading` protocol carrying `paused` and `queueSnapshot()`.

Patience is bounded: a card in `.wait` whose reason has not changed for the
patience window settles. Without it, one stuck CI holds a session open for ever.

### The second green guard, at admission

`refusal(for:)` gains a branch that refuses a `.mergePR` run whose verdict has
aged past `PRStatus.maximumAge`, with its own `QueueRefusal`. The verdict is
read **once per drain** and passed in as a parameter, exactly as `overBudget`
is — `refusal(for:)` is deliberately synchronous, and its comment explains why.

A session also **serialises its merges**: at most one `merge-pr` in flight, and
no new `implement-issue` engaged while a merge is waiting. `pump()` steps over
a refused run and admits the next (`RunScheduler.swift:254-266`), so on a
repository auto-dev keeps busy, `.mergeWaitsForRepoToBeIdle` can otherwise
never lift.

### Termination

A session is finished when every engaged card is settled. Settled is decided on
**`run.verifiedOutcome == .merged`**, read from the persisted row
(`RunScheduler.swift:448`) — never on `column == .done`, and never by a fourth
`switch VerifiedOutcome`.

The reason is measured: `commitMove` puts the card in Done *before* the run
(`BoardService.swift:141-146`), and `CardOutcome.applied` returns no move for
`.notMerged` (`CardOutcome.swift:107-109`) and none for `.merged` when the card
is already there (`:104-107`). A failed merge therefore leaves the card in Done
with a `lastError`. Column and audit separate neither case.

Paths that could otherwise run for ever, and what cuts each:

- a card in the resume fallback, alternating between `.runAlreadyInFlight` and
  free — cut by counting a fork refusal against the patience window even though
  it costs no attempt;
- a `.stalled` run, which is non-terminal and holds its card through
  `activeRun(cardID:)` for ever — cut by the session **cancelling** it at the
  end. Abandoning a card and cancelling its run are not the same act, and only
  the second frees the card;
- a merge held by `.mergeWaitsForRepoToBeIdle` — cut by serialising merges;
- a CI that never finishes — cut by the patience window.

### Guards that belong to the act

`AutoDevService.start(session:)` refuses, by name, in `ElliotEngine`:

- a repository Preflight blocks — `AutoDevError.repoBlocked`, with an
  `ElliotErrorCode` shaped like `analysisRefused` (`Protocol.swift:201`). Not
  in `AppModel`: a `.disabled()` on a button is exactly the shape #151 nearly
  shipped, and it does not reach a session started any other way;
- no `SpendCeiling.perDayUSD` is set. `SpendCeiling.swift:5-12` says the brake
  was sized against the rhythm of a human dragging cards; auto-dev removes that
  assumption, so a session either finds a daily ceiling or carries its own.

### Launch order

`Reconciler.sweep()` runs **before** auto-dev resumes. Otherwise auto-dev sees
an orphaned run still marked `.running`, reads `runAlreadyInFlight`, waits, and
waits for an event that will never come.

---

## PR5 — The screen

Auto-dev speaks about the **machine**, not about a card, so it costs **zero
`BoardSlot`**. Width is the exhausted resource; this design spends none of it.

- **A band in `Operations`, above Up next.** Not an arbitrary neighbour: Up next
  is the ranking of possible moves, auto-dev is that ranking executed. Both read
  `rankNextSteps`. The band says in words that it answers a different question
  from `CardValue`'s ordering, so two orders stacked in one window do not read
  as one.
- **A figure in the status bar** — a door, like `2/4 workers`. Its spoken
  sentence goes in `BoardAccessibility` (`BoardView.swift:1348-1449`), with the
  singular written by hand as `:1343-1347` requires, passed through `figure`'s
  `spoken:` parameter.
- **The band and the figure are permanent** for the life of a session *and its
  report* — never conditional. A session's outcome is a record, which D5
  requires persisted; the template is `model.lastSyncSummary`
  (`RepositoriesView.swift:136-161`), which stays after the sweep.
- **A stop control in the band**, in the shape `queueBand` already uses
  (`OperationsView.swift:156-166`), saying on its face what it does to the run
  already in flight. It cannot lean on the queue's Pause, which holds queued
  runs and not the running one.
- **A mark on an engaged card**, in the title row beside the lens symbol
  (`CardView.swift:19-35`) — which is unconditional and survives a run — not in
  the facts row, which does not exist for a freshly engaged card. No sixth
  tint: engaged cards are `armed`, which they already are.

The start button is **not** in `.toolbar` — the one region `board_screenshot`
renders blank — and never carries `.keyboardShortcut(.defaultAction)`. The
analysis panel was refused one for claiming up to eight unattended runs; this
claims more, and merges.

Auto-dev view state lives on `AppModel`, never as `@State` in the band: hiding
a view destroys it.

**A failed session must be visible.** `Column.naturalNext` returns `nil` for
`.done` (`Column.swift:31-35`), so a card whose merge failed — which stays in
Done — is structurally absent from both `NextStepsView` and the Up next band.
The report band is the only surface that shows it, which is why it is permanent
rather than conditional. Otherwise a session that fails everywhere renders
exactly like a session that never happened.

Before any history is drawn, the merge path must carry its origin:
`armPendingMerge` (`AppModel.swift:1171-1175`) passes it and `confirmMerge`
(`:1186-1188`) stops hardcoding `.userDrag`, or an auto-dev merge shows as
"Dragged".

---

## PR6 — The agent that fills in

A read-only run that writes `effort`, `evidence` and `appraisedAt` onto
unmeasured cards. It fills in; it never ranks.

**One run per card, and no migration.** The `skillRun` CHECK is a **XOR** —
`("cardID" IS NULL) <> ("analysisID" IS NULL)` (`Migrations.swift:425`) — so a
run carries a card *or* an analysis, never both. The appraisal run carries a
**`cardID`**: it satisfies the CHECK as written, needs no migration, and buys
the ownership PR2's schema decision rests on, since `activeRun(cardID:)`
(`BoardStore.swift:746`) then holds that card for the run's whole life and
closes the write window in both directions. It is also the deduplication: a
second appraisal of the same card cannot start.

The alternative — a synthetic `analysisID` on an `Analysis` with `angles: []`,
which is legal because `Analysis` carries no invariant (`Analysis.swift:9-36`)
and `.noAngles` lives only in `AnalysisService.start` (`:65`) — is also
migration-free, but it buys analysis bookkeeping instead of card ownership, and
ownership is what PR2 needs. Rebuilding the table to relax the CHECK is the
option to avoid outright: a hand-written `INSERT … SELECT` over 22 columns
(`Migrations.swift:394-445`) that, if PR3 shipped first, silently drops
`resumedFrom` from every existing row.

The cost is N runs for N cards rather than one. It is bounded by the read-only
lane, which is where they belong anyway.

`StoreLocation` gains `appraisalArtifactURL(runID:)` beside
`analysisArtifactURL(analysisID:runID:)`, since there is no analysis to key on.

`SkillKind` gains **one** predicate, and `finish` gains a **third branch**:

```swift
var isReadOnly: Bool   // scheduling lane, and the working-tree sentinel
```

wired at `RunScheduler.swift:180`, `:219`, `:220`, `:226`, `:238` and the
sentinel at `:352`. `:226` becomes `filter { !$0.kind.isReadOnly }` — a
**negation** the compiler will not check, so it ships with the witness
`SchedulerLimitsAdmissionTests` lacks: saturate `maxConcurrent` with two
writers and prove an appraisal starts anyway.

Routing is not a second boolean. `finish`'s `if updated.isAnalysis` becomes an
exhaustive `switch run.kind` with three outcomes — harvest proposals
(`.analyzeRepo`), harvest an appraisal (`.appraiseCards`), verify against `gh`
(the three writers). A boolean would have routed the appraisal into
`completeCardRun`, which asks `gh` about an issue and a pull request the card
does not have. A switch makes a sixth kind a compile error instead.

`treeBaselines.removeValue` moves **above** the routing in `finish` rather than
being copied into a second branch: the dictionary has exactly three sites
(`:356`, `:370`, `:472`), and a fourth path with no erasure leaks one entry per
run.

The harvester reads the **artifact or nothing**. It never falls back to
`resultText`: leaving a card unappraised and saying so beats persisting prose
into a card field. The artifact directory is passed to `--add-dir`, so the write
does not depend on `bypassPermissions` alone.

The appraisal invocation uses a **tighter** `permissionMode` than
`repo.permissionMode`. That makes the MCP self-call loop *measurable* — denials
land in `permissionDenials` and the run ends `.completedWithDenials`
(`RunScheduler.swift:511-515`) — instead of invisible.

### The guard this PR must build, because no transition provides one

An appraisal run passes through no move: no `evaluateMove`, no
`allowsSideEffects`, no `repoPreflight`. It is the only unattended agent that
starts outside the funnel. Before it ships, the Preflight refusal moves down
out of `AppModel.analysisRefusal` (`AppModel.swift:1929-1938`) into a pure
function in `ElliotModel`, fed by `PreflightService`, called by
`AnalysisService.start` — which checks only `isEnabled` today (`:59`) — by the
appraisal path, and read back by `AppModel`. One rule, one implementation,
three callers.

---

## Testing

Pure and exhaustive, no store and no clock:

- `evaluateMove` with `requiresVerifiedGreen` across the **whole** `PRSign`
  matrix — eight signs plus `nil` plus `isStale`, not three cases.
- A property test over `Column.allCases × Column.allCases`, twin of
  `systemMovesNeverTrigger` (`RuleEngineTests.swift:177-193`): a context with
  `requiresVerifiedGreen: true` **never** returns `.needsInput`, on any of the
  25 transitions. It survives a future `.needsInput` added elsewhere.
- `MoveOrigin.allowsSideEffects` is `true` for `.autoDev` and `false` for all
  four `SystemReason`s. No test measures this property today, on the property
  that decides whether an unattended agent starts.
- `nextCandidates` keeps `requiresVerifiedGreen: false` **on purpose**, with the
  reason in the test's name.
- `Consequence.reason(.notVerifiedGreen)` and
  `MoveBlockText.explain(.notVerifiedGreen)` are linked in the
  **non-identity** direction (template: `MoveHistoryTests`). They are two
  hand-written phrasings of every `MoveBlock`, in two targets, with no link.
- `AutoDevPolicy.disposition` across every `MoveBlock` × attempts × injected
  clock.
- `CardValue`: `.neverAppraised` for a card nothing has read, `.ungradeable`
  for cited-and-missing files, `.ranked` otherwise — and that neither
  `.ungradeable` nor `.neverAppraised` can enter a comparator.
- `ClaudeInvocation.arguments()` with `resumeFrom` — the exact argv.

Against the store and the fakes:

- **The admission test, the most important of the set**: seed a green
  `prStatus`, commit the move, hold the merge behind a sibling run in the same
  repository, advance the clock past `maximumAge`, release the sibling, and
  require that the merge does **not** start. Without it, PR1 is green, PR4 is
  green, and merging on a stale reading is invisible.
- A whole session against `fake-claude.sh` and `fake-gh.sh`, with `FAKE_GH_PRS`
  in two sets: a green pull request that must merge, and a `noChecks` one that
  must settle blocked.
- **Termination**: a session where every card is blocked must *finish*. Under
  `withTimeout`.
- **`Reconciler` before auto-dev**: an orphan still `.running` plus a `running`
  session; the card must advance.
- **The resume fallback**: a fixture returning a `result` with `numTurns: 0`
  and `is_error: true`. Exactly one fresh relaunch, attempt counter unchanged.
- A run seeded with `resumedFrom` non-nil before any `skillRun` rebuild and read
  back after — the only possible witness to a column dropped from a hand-written
  `INSERT … SELECT`.
- The card write window, **both ways**: an appraisal written between a poller's
  read and its `saveCard` must not lose the column; a move committed between the
  appraisal's read and write must not lose the appraisal.
- `CardFieldWritersTests`, reading sources, naming the field.

---

## Delivery order

The announced 1 → 6 is wrong in three places.

**Hard prerequisites, outside this design.** PR 0·2 (`repoPreflight`,
`repoBlocked`) — auto-dev consumes it and cannot supply it. PR 0·3 (#179, the
concurrent `pump()` race) — `pump()` carries `run.state == .queued`
(`RunScheduler.swift:255`) but that check precedes an `await`, and `start`
persists `.running` only after the spawn; two concurrent drains both cross it.
Auto-dev multiplies drains by construction: every `commitMove` triggers one,
every `finish` triggers one, every resume attempt triggers one.

1. **PR6's write decision** — before PR2. Not the whole PR: only the answer to
   *who writes `effort`/`evidence`, and when*. Without it PR2 picks its schema
   against the criterion at `Migrations.swift:118-127` by coin toss and buys a
   second migration.
2. **PR1**, then **PR2** — never in parallel. Both edit `RuleEngine.swift`,
   which is **not** in the union-merge list (that list is `Package.swift`,
   `AppModel.swift`, `Migrations.swift`, `README.md` and test files). PR 0·2
   touches the same four switches and the same three test literals.
3. **PR3**, totally ordered with respect to PR6, and the chosen order written in
   the second one's body.
4. **PR6**, before PR5. As split, PR6 ships a `SkillKind` nothing can start — no
   wire case, no control on screen, no call from the loop. That is dead code at
   delivery.
5. **PR5**.
6. **PR4 last** among the engine PRs, and not before the admission-time verdict
   re-read has an owner. Shipping PR4 on PR1 alone ships a loop that merges on
   stale readings in exactly the configuration D5 imposes.

**The migration number is a resource shared by four PRs.** The last registered
is `v8_prStatus` (`Migrations.swift:138`). PR2 (columns on `card`), PR3 (a
column on `skillRun`) and PR4 (the session tables) all want v9. Every
renumbering ships its `RenamedMigration` (`Migrations.swift:194-202`) **in the
same diff**: GRDB identifies a migration by name, so a machine that ran the
losing branch replays it against tables that already exist — a real incident,
recorded at `Migrations.swift:180-184`. Auto-dev is developed by running
unmerged branches on the owner's machine, so the escape stops being the
exception and becomes the normal case.

A v9 that only *creates* a table needs no change to
`SchemaUpgradeTests.rewindToV1` — v4, v6 and v8 are not in its `IN` clause
either. A v9 that **alters `card`** does need its `DROP COLUMN` there, beside
`"idempotencyKey"` (`:77`) and `"angle"` (`:83`), or the backfill test runs
against an already-current database and measures nothing. Adding an identifier
to the `IN` clause without raising the `precondition(db.changesCount == 4)`
(`:98-101`) is what breaks it.

---

## Open decision — what counts as green

`isMergeableUnattended` is the one predicate this document does not settle,
because it decides what an unattended agent is allowed to merge to a default
branch on github.com.

`sign == nil` — the obvious answer, and the first draft's — is **too weak**, in
two measured ways:

1. `PRStatus.sign` blocks only `.blocked` and `.behind` (`PRStatus.swift:306`),
   so `MergeState.unstable` reaches `return nil`. `PRStatusBlock.swift:137`,
   `:146` paints that same state in `Palette.attention` and calls it
   *mergeable, not every check is green*.
2. `StatusCheck.isNonVerdict` filters only `SKIPPED|NEUTRAL|STALE`
   (`GHPayloads.swift:176-184`). Its own comment records the choice: a CodeQL
   run that genuinely succeeded still counts as a pass. Defensible for a
   display dot; it is the portfolio's `renovate/stability-days` and
   `Codacy`-only-green lesson if it becomes merge authority.

**Recommendation, and what this document assumes unless told otherwise:**

```swift
extension ResolvedPRStatus {
    /// Stricter than `sign == nil`, deliberately — see the design note.
    var isMergeableUnattended: Bool {
        !isStale && sign == nil && merge == .clean && ci.hasBuildVerdict
    }
}
```

with `hasBuildVerdict` requiring at least one passing check whose name is not
in a small, named, **data** list of analysers and reporters — the shape of
`board/non_build_checks.json` in the portfolio, which exists because this exact
family of false greens cost 43-versus-2 mergeable pull requests there.

⚠️ **Option A is not expressible today, and that is part of its price.**
`CIState.passing` carries an `Int` (`PRStatus.swift:324`), and
`ResolvedPRStatus` carries only the `CIState` — so the passing checks' *names*
never reach the predicate. A carries a prior change: `case passing([String])`,
symmetric with `case failing([String])` which already carries its labels. That
is a small and honest change — the labels exist at
`PRStatus.ciState` and are discarded one line later — but it touches every
reader of `.passing`, so it belongs in PR1 rather than being discovered in PR4.
Options B and C need none of it.

Three ways to go, in descending strictness:

- **A. As above.** Costs a names list Elliot does not have, and a census to seed
  it honestly.
- **B. `!isStale && sign == nil && merge == .clean`.** Closes `unstable`, leaves
  the analyser hole. Cheap, and strictly better than the first draft.
- **C. `sign == nil`.** What the first draft said. Merges pull requests whose
  only green is an analyser.

The rest of this design is written to be correct under any of the three: the
predicate is one property on one type, read from one place.
