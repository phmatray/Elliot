# Auto-dev PR5 — The Screen Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Put an auto-dev session, and its report, permanently on screen — a band in Operations immediately above Up next, a door-figure in the status bar, a mark on every engaged card, a stop control that says what it does to the run already going — without spending a single board column.

**Architecture:** Four pure value types in `ElliotModel` carry the session and its per-card rows; one pure presentation type in `ElliotAppKit` (`AutoDevBand`, shaped like `AnalysisFooterMessage`) turns them into the sentences the two surfaces render; `AppModel` holds the session, its rows and the engaged-card set behind one assignment site, and reaches the loop through an `AutoDevDriving` protocol in `ElliotEngine` that the *next* pull request conforms to. Views render and dispatch; they do not judge.

**Tech Stack:** Swift 6.3.1 · SwiftUI (macOS 15) · swift-testing (`@Suite`/`@Test`/`#expect`/`#require`) · GRDB (untouched by this plan) · SwiftPM (`swift build`, `swift test`).

## Global Constraints

- Swift tools-version **6.3.1** — the patch is load-bearing, never `6.3`; `swiftLanguageModes: [.v6]`; deployment target macOS 15; strict concurrency — every type crossing an isolation boundary is `Sendable`.
- Build: `cd ElliotKit && swift build` · Tests: `cd ElliotKit && swift test` · One suite: `cd ElliotKit && swift test --filter <TypeName>`.
- ⚠️ `--filter` matches the **type** name, not the `@Suite` display name. A filter matching nothing prints `warning: No matching test cases were run` and **exits 0** — indistinguishable from success. Never conclude from exit 0 alone; read the printed test count.
- Test framework is **swift-testing**, not XCTest.
- ⛔ Never run `swift format` over the tree. This code is hand-formatted, 4 spaces, 110 columns. Format the lines you write by hand, to match their neighbours.
- Every async wait in a test is **bounded**, through `withTimeout` from the `TestSupport` target. No assertion measures an absolute duration. No test sleeps a fixed interval.
- ⛔ Nothing in production code waits on `Process.waitUntilExit()`.
- Migrations are additive and shipped ones are frozen. The last registered is `v8_prStatus` (`ElliotKit/Sources/ElliotStore/Migrations.swift:138`); a renumbering ships its `RenamedMigration` (`:195-202`) **in the same diff**. ⚠️ **This plan registers no migration** — PR4 owns the auto-dev tables.
- Commits: Conventional Commits with the layer as scope — `feat(model|store|process|engine|ipc|mcp|app): subject`.
- Branch: `feat/<issue>-<slug>` or `fix/<issue>-<slug>`. The number comes first, followed by `-`.
- ⚠️ Several worktrees share this repo's `.git`. Re-read `git rev-parse --abbrev-ref HEAD` **immediately before every commit** and **immediately after every push**.
- A stale `.build` produces impossible failures (wrong enum values, link errors, SIGBUS). After any `git checkout` that crosses commits: `rm -rf ElliotKit/.build` before believing a failure.
- One green run does not clear a suite. Sample five times after a clean build (~8 s total) before calling a task done.

### Prerequisites this plan assumes have landed

- **PR1 (the rules).** `MoveOrigin` carries `case autoDev(sessionID: UUID)`, `allowsSideEffects` is an exhaustive switch, and `MoveOrigin.historyLabel` (`ElliotKit/Sources/ElliotAppKit/Consequence.swift:133-145`) answers for it. Task 2 below uses `.autoDev(sessionID:)` in a test. **If `MoveOrigin.autoDev` does not exist on your branch, PR1 has not landed and this plan is being executed out of order — stop and land PR1 first.**
- **PR6 (the appraising agent).** Named in the design's delivery order as shipping before PR5. Nothing in this plan reads it; the ordering exists so PR6's `SkillKind` is not dead code at delivery.
- **PR4 (the loop) has NOT landed, by design.** The design's delivery order puts PR4 *after* PR5. Consequences this plan owns and states out loud:
  - The value types this plan declares in `ElliotModel` (Task 1) are the ones PR4 persists. PR4 adds the `Records.swift` conformance and the migration; it changes nothing in Task 1's file.

    🔴 **That last sentence is not true of PR4's plan as written, and it has to be arbitrated before
    either pull request is executed.** PR4's Task 3 creates the *same file*,
    `ElliotKit/Sources/ElliotModel/AutoDev.swift`, and declares its own per-card row —
    **`AutoDevCardState`** with **`DispositionCode { retry, wait, held, settled, aborted }`** —
    beside a transient policy verdict `Disposition`. This plan declares **`AutoDevEngagement`** with
    **`AutoDevDisposition { engaged, merged, blocked }`**, plus `AutoDevTally`, which PR4 does not
    declare at all. Two per-card row types, one rendered here and one persisted there, with nothing
    joining them. The full table and the recommended resolution — keep this plan's names, keep PR4's
    `Disposition` as transient, and decide whether the policy's code survives as a second persisted
    column — are written at the head of PR4's Task 3. ⚠️ It is a **decision**, not a merge: reading
    only this plan, the collision is invisible.

  - **PR4 does not mention `AutoDevDriving`.** Task 4 below declares that protocol and records that
    "PR4 conforms `AutoDevService` to it"; PR4's Tasks 11–14 never name it, and its actor's surface
    is a different one — `start(session: AutoDevSession, preflightChecks: [CheckResult])`,
    `advance()`, `hasRunningSession()`, `finish(_:)` — against this protocol's
    `start(repoID:cardLimit:)`, `pause/resume/stop(sessionID:)`, `engagements(sessionID:)`. PR4 also
    writes `AppModel.autoDev: AutoDevService?` while this plan writes `AppModel.autoDev:
    AutoDevSession?` — **the same property name, two types.** Either PR4 grows an
    `extension AutoDevService: AutoDevDriving` that composes the card selection this protocol's
    `start(repoID:cardLimit:)` implies, or this protocol is rewritten to PR4's surface and
    `AppModel` gains a separately-named driver property. Both are small; neither is discoverable
    from one plan.
  - `AutoDevDriving` (Task 4) has **no conformer until PR4**. `AppModel.autoDevRefusal` therefore answers *"Auto-dev is not wired into this build yet."*, the Start button is disabled with that sentence beside it, and the band renders its idle state. That is the #151 shape — a control that opens onto an explanation rather than one that cannot be switched off — and it is the honest cost of the arbitrated delivery order.
  - The on-screen pass (Task 8) therefore seeds a session through a **temporary, reverted** patch to `AppModel.start()`, rather than shipping a seam PR4 would immediately make redundant. ⚠️ Do **not** describe this as what #209 did — its pull request (#211) records something different and better, and Task 8 Step 5 names it: it never patched `AppModel`, it hosted the view in an `NSHostingView` inside an `NSWindow` against a real seeded `BoardStore` and rendered *that* with `AppKitWindowCapture.render`, because neither Accessibility nor Screen Recording was granted to that session either.

---

⚠ **Every line number in this plan is read against `main` as it stands today, and PR1, PR2,
PR3 and PR6 all land first** — three of them editing `AppModel.swift`, which this plan edits
throughout. Each step also names the construct it means — a view, a computed property, a
`ViewBuilder` block. **Locate by the name; treat the number as a hint at where to start
looking.**

## File Structure

### Created

| Path | Responsibility |
|---|---|
| `ElliotKit/Sources/ElliotModel/AutoDev.swift` | `AutoDevSession`, `AutoDevDisposition`, `AutoDevEngagement`, `AutoDevTally` — pure value types, no clock, no I/O. The vocabulary PR4 persists and the screen renders. |
| `ElliotKit/Sources/ElliotEngine/AutoDevDriving.swift` | The protocol the band's controls reach. `stop` cancels the run already going; `pause` does not. PR4 conforms `AutoDevService` to it. |
| `ElliotKit/Sources/ElliotAppKit/AutoDevBand.swift` | Every sentence the band and the figure say, decided once, holding no `Color`. Total by construction: `of` returns a band for every input including no session at all. |
| `ElliotKit/Tests/ElliotModelTests/AutoDevSessionTests.swift` | `AutoDevSessionTests` — the tally, the dispositions, the Codable round-trip. |
| `ElliotKit/Tests/ElliotAppKitTests/AutoDevBandTests.swift` | `AutoDevBandTests` — the sentences, the tones, the controls, the singular. |
| `ElliotKit/Tests/ElliotAppKitTests/AutoDevStateTests.swift` | `AutoDevStateTests` — `AppModel`'s session state, refusals, commands, and that the report survives a stop. |
| `ElliotKit/Tests/ElliotAppKitTests/OperationsBandOrderTests.swift` | `OperationsBandOrderTests` — the band sits immediately above Up next, and is not conditional. |
| `ElliotKit/Tests/ElliotAppKitTests/AutoDevCardMarkTests.swift` | `AutoDevCardMarkTests` — the mark is in the title row, not the facts row, and not suppressed by a run. |

### Modified

| Path | Change |
|---|---|
| `ElliotKit/Sources/ElliotAppKit/AppModel.swift:411-415` | `PendingMerge` gains `origin: MoveOrigin`. |
| `ElliotKit/Sources/ElliotAppKit/AppModel.swift:1068-1102` | `move` names its origin once and hands it to `armPendingMerge`. |
| `ElliotKit/Sources/ElliotAppKit/AppModel.swift:1171-1175` | `armPendingMerge(cardID:prNumber:origin:)`. |
| `ElliotKit/Sources/ElliotAppKit/AppModel.swift:1182-1193` | `confirmMerge(cardID:followUps:origin:)` — no more hardcoded `.userDrag`. |
| `ElliotKit/Sources/ElliotAppKit/AppModel.swift` (new `// MARK: - Auto-dev` section) | `autoDev`, `autoDevEngagements`, `autoDevEngagedCardIDs`, `autoDevTally`, `autoDevCardLimit`, `autoDevRefusal`, the four commands, `adopt`, and two test seams. |
| `ElliotKit/Sources/ElliotAppKit/Sheets.swift:130-132` | The `Button("Merge PR …")` passes `origin: pending.origin`. |
| `ElliotKit/Sources/ElliotAppKit/BoardView.swift:657` | A doc comment that names the selector `AppModel.armPendingMerge(cardID:prNumber:)`, which stops existing under that name. |
| `ElliotKit/Sources/ElliotAppKit/Consequence.swift` (end of file) | `AutoDevBand.Tone.tint`, `AutoDevDisposition.tint`, `AutoDevDisposition.icon` — the one place these values meet SwiftUI. |
| `ElliotKit/Sources/ElliotAppKit/OperationsView.swift:33-39` | `autoDevBand` inserted immediately above `upNextBand`. |
| `ElliotKit/Sources/ElliotAppKit/OperationsView.swift` (new section) | The band itself, its engagement rows, and the Start control. |
| `ElliotKit/Sources/ElliotAppKit/BoardView.swift:785-846` (`StatusBar.body`) | The auto-dev figure, inserted after the workers figure — which ends at `:807`, immediately before the queue figure's comment at `:809`. |
| `ElliotKit/Sources/ElliotAppKit/BoardView.swift:1348-1450` | `BoardAccessibility.autoDevFigure(state:tally:)`. |
| `ElliotKit/Sources/ElliotAppKit/CardView.swift:19-35` | The mark, in the title row beside the lens symbol. |
| `ElliotKit/Sources/ElliotAppKit/CardView.swift:204-246` | `isEngagedByAutoDev`. |
| `ElliotKit/Tests/ElliotAppKitTests/AppModelTests.swift:320-359` | The two merge-confirmation tests learn the origin; two new tests. |
| `ElliotKit/Tests/ElliotAppKitTests/BoardAccessibilityTests.swift` | Three new tests for the figure's spoken sentence, one source test for its guard. |

### Deliberately NOT modified

- **`ElliotKit/Sources/ElliotAppKit/CardView.swift:77`** — the facts-row guard, `if !facts.isEmpty || repoName != nil || stagnation != nil || prSign != nil`. Read it: it is what makes the facts row *absent* for a freshly engaged card (no issue, no pull request, no stagnation while a run is going, no PR sign). The design says the mark goes in the title row **"not in the facts row, which does not exist for a freshly engaged card"**. Widening this guard would put the mark exactly where the design forbids it. Task 7 pins that it stays out, by measuring line positions in the source.
- **`ElliotKit/Sources/ElliotStore/Migrations.swift`** — PR4 owns the auto-dev tables. This plan registers no migration, so the shared v9 slot is untouched.
- **`.toolbar`** anywhere. The start control is in the Operations band. `.toolbar` is the one region `board_screenshot` renders blank, and a control that claims more unattended runs than the analysis panel does must not hide there.

---

### Task 1: The session, its rows and their tally

**Files:**
- Create: `ElliotKit/Sources/ElliotModel/AutoDev.swift`
- Test: `ElliotKit/Tests/ElliotModelTests/AutoDevSessionTests.swift`

**Interfaces:**
- Consumes: nothing. `ElliotModel` has no dependencies.
- Produces:
  - `public struct AutoDevSession: Identifiable, Codable, Sendable, Hashable` with `public init(id: UUID = UUID(), repoID: UUID, engagedCardIDs: [UUID], maxAttemptsPerCard: Int, patience: TimeInterval, startedAt: Date, endedAt: Date? = nil, state: State = .running)` and `public enum State: String, Codable, Sendable, Hashable, CaseIterable { case running, paused, finished }`
  - `public enum AutoDevDisposition: String, Codable, Sendable, Hashable, CaseIterable { case engaged, merged, blocked }`
  - `public struct AutoDevEngagement: Identifiable, Codable, Sendable, Hashable` with `public init(sessionID: UUID, cardID: UUID, attempts: Int, disposition: AutoDevDisposition, reason: String, updatedAt: Date)` and `public var id: UUID { cardID }`
  - `public struct AutoDevTally: Sendable, Hashable` with `public init(engaged: Int, merged: Int, blocked: Int)`, `public var total: Int`, `public var settled: Int`, and `public static func of(_ engagements: [AutoDevEngagement]) -> AutoDevTally`

- [ ] **Step 1: Write the failing test**

Create `ElliotKit/Tests/ElliotModelTests/AutoDevSessionTests.swift`:

```swift
import Foundation
import Testing

@testable import ElliotModel

/// The vocabulary the screen renders and the loop will persist.
///
/// Pure — no store, no clock, no `Date()` anywhere but a fixed fixture. The
/// tally is the piece with teeth: the band's headline and the status bar's
/// figure both read it, and two hand-rolled counts would be two answers to the
/// one number this feature exists to state.
@Suite("Auto-dev session")
struct AutoDevSessionTests {

    /// Fixed rather than `Date()`, for the reason `AppModelTests` gives:
    /// `ElliotModel` holds no clock, and a fixture reaching for the wall clock
    /// makes a test depend on when the suite happened to run.
    private let epoch = Date(timeIntervalSince1970: 1_770_000_000)

    private func engagement(
        _ disposition: AutoDevDisposition, session: UUID, attempts: Int = 1
    ) -> AutoDevEngagement {
        AutoDevEngagement(
            sessionID: session, cardID: UUID(), attempts: attempts,
            disposition: disposition, reason: "Because.", updatedAt: epoch
        )
    }

    @Test("The tally counts each disposition, and settled is merged plus blocked")
    func tallyCounts() {
        let session = UUID()
        let tally = AutoDevTally.of([
            engagement(.engaged, session: session),
            engagement(.engaged, session: session),
            engagement(.merged, session: session),
            engagement(.blocked, session: session),
            engagement(.blocked, session: session),
        ])

        #expect(tally.engaged == 2)
        #expect(tally.merged == 1)
        #expect(tally.blocked == 2)
        #expect(tally.total == 5)
        // The figure reads this. A card still engaged is not settled, and a
        // blocked one is — the session is done with it either way.
        #expect(tally.settled == 3)
    }

    @Test("No rows is zero of zero, not a crash and not a one")
    func emptyTally() {
        let tally = AutoDevTally.of([])
        #expect(tally == AutoDevTally(engaged: 0, merged: 0, blocked: 0))
        #expect(tally.total == 0)
        #expect(tally.settled == 0)
    }

    /// Three dispositions and not five. The loop's own verdict — retry, wait,
    /// held, settle, abort — is a decision about the *next round*; this is what
    /// the report says about the card, and the distinctions the decision draws
    /// are carried by `reason`.
    @Test("Every disposition has a distinct raw value")
    func dispositionsAreDistinct() {
        let raws = AutoDevDisposition.allCases.map(\.rawValue)
        #expect(Set(raws).count == AutoDevDisposition.allCases.count)
        #expect(raws.allSatisfy { !$0.isEmpty })
    }

    /// The engaged list is closed at start, so `id` may be the card: a session
    /// cannot hold two rows for one card. `ForEach` in the band depends on it.
    @Test("An engagement identifies itself by its card")
    func engagementIsIdentifiedByItsCard() {
        let row = engagement(.merged, session: UUID())
        #expect(row.id == row.cardID)
    }

    /// PR4 persists this. A shape that does not survive a round trip is a
    /// report that comes back from the store as something else.
    @Test("A session round-trips through Codable with its engaged list in order")
    func sessionRoundTrips() throws {
        let cards = [UUID(), UUID(), UUID()]
        let session = AutoDevSession(
            repoID: UUID(), engagedCardIDs: cards, maxAttemptsPerCard: 3,
            patience: 900, startedAt: epoch, state: .paused
        )

        let data = try JSONEncoder().encode(session)
        let back = try JSONDecoder().decode(AutoDevSession.self, from: data)

        #expect(back == session)
        // Order, not membership: the report renders these rows in the order the
        // session engaged them.
        #expect(back.engagedCardIDs == cards)
        #expect(back.state == .paused)
        #expect(back.endedAt == nil)
    }

    @Test("Every state is nameable, and no two share a raw value")
    func statesAreDistinct() {
        let raws = AutoDevSession.State.allCases.map(\.rawValue)
        #expect(Set(raws).count == 3)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd ElliotKit && swift test --filter AutoDevSessionTests`
Expected: FAIL — the target does not compile, with `error: cannot find 'AutoDevDisposition' in scope` and `error: cannot find 'AutoDevTally' in scope`.

- [ ] **Step 3: Write minimal implementation**

Create `ElliotKit/Sources/ElliotModel/AutoDev.swift`:

```swift
import Foundation

/// One run of the board driving its own cards.
///
/// Auto-dev speaks about the **machine**, not about a card, so it costs zero
/// board columns. This is the value the two surfaces that report it read —
/// the Operations band and the status bar's figure — and the value the loop
/// (PR4) persists. It lives in `ElliotModel` for the ordinary reason: it is
/// pure, it carries no clock and no I/O, and both `ElliotEngine` and
/// `ElliotAppKit` need it.
///
/// ⚠️ **The engaged list is closed at start.** Every card the session may touch
/// is decided in one write, at one moment, by a person; a card dragged into
/// Backlog mid-session is invisible to it. Nothing here offers a way to append
/// to `engagedCardIDs`, and that absence is the design.
public struct AutoDevSession: Identifiable, Codable, Sendable, Hashable {

    /// Running, held by the reader, or over.
    ///
    /// `finished` is **not** the absence of a session. The outcome is a record,
    /// and the band and the figure stay on screen through it — otherwise a
    /// session that failed everywhere renders exactly like a session that never
    /// happened.
    public enum State: String, Codable, Sendable, Hashable, CaseIterable {
        case running
        case paused
        case finished
    }

    public var id: UUID
    public var repoID: UUID
    /// Fixed at start, never grows.
    public var engagedCardIDs: [UUID]
    public var maxAttemptsPerCard: Int
    /// How long a card may sit on one unchanged reason before it settles.
    ///
    /// On the session rather than a constant: a repository whose CI takes an
    /// hour and one that takes ninety seconds do not want the same answer.
    public var patience: TimeInterval
    public var startedAt: Date
    public var endedAt: Date?
    public var state: State

    public init(
        id: UUID = UUID(),
        repoID: UUID,
        engagedCardIDs: [UUID],
        maxAttemptsPerCard: Int,
        patience: TimeInterval,
        startedAt: Date,
        endedAt: Date? = nil,
        state: State = .running
    ) {
        self.id = id
        self.repoID = repoID
        self.engagedCardIDs = engagedCardIDs
        self.maxAttemptsPerCard = maxAttemptsPerCard
        self.patience = patience
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.state = state
    }
}

/// Where one engaged card got to.
///
/// Three cases and not five. The loop's own verdict — retry, wait, held,
/// settle, abort — is a decision about the *next round*; this is what the
/// report has to say about the card, and the distinctions that decision draws
/// are carried by ``AutoDevEngagement/reason`` rather than by a case each. A
/// held run and a waiting one read differently in the sentence, which is where
/// the reader needs the difference.
public enum AutoDevDisposition: String, Codable, Sendable, Hashable, CaseIterable {
    /// The session still holds it.
    case engaged
    /// `gh` said the pull request was merged.
    case merged
    /// The session gave up on it, and `reason` says why.
    case blocked
}

/// One engaged card's row in a session's report.
public struct AutoDevEngagement: Identifiable, Codable, Sendable, Hashable {
    public var sessionID: UUID
    public var cardID: UUID
    public var attempts: Int
    public var disposition: AutoDevDisposition
    /// Why it is where it is, in the board's own words — a `MoveBlock`'s
    /// sentence, or a `QueueRefusal`'s. Never blank: a row with no reason is a
    /// row the reader stops at with nothing to go and do.
    public var reason: String
    public var updatedAt: Date

    /// The card, because a session engages a card at most once: the list is
    /// closed at start, so it cannot hold two rows for one card.
    public var id: UUID { cardID }

    public init(
        sessionID: UUID,
        cardID: UUID,
        attempts: Int,
        disposition: AutoDevDisposition,
        reason: String,
        updatedAt: Date
    ) {
        self.sessionID = sessionID
        self.cardID = cardID
        self.attempts = attempts
        self.disposition = disposition
        self.reason = reason
        self.updatedAt = updatedAt
    }
}

/// A session's rows, counted once.
///
/// One count, two readers: the band's headline and the status bar's figure.
/// Two tallies would be two answers to "how far along is it", which is the one
/// number this feature exists to state.
public struct AutoDevTally: Sendable, Hashable {
    public var engaged: Int
    public var merged: Int
    public var blocked: Int

    public var total: Int { engaged + merged + blocked }
    /// A card the session is done with, whichever way it went.
    public var settled: Int { merged + blocked }

    public init(engaged: Int, merged: Int, blocked: Int) {
        self.engaged = engaged
        self.merged = merged
        self.blocked = blocked
    }

    public static func of(_ engagements: [AutoDevEngagement]) -> AutoDevTally {
        AutoDevTally(
            engaged: engagements.count { $0.disposition == .engaged },
            merged: engagements.count { $0.disposition == .merged },
            blocked: engagements.count { $0.disposition == .blocked }
        )
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd ElliotKit && swift test --filter AutoDevSessionTests`
Expected: PASS — 6 tests, 0 failures. Read the printed count; a filter that matched nothing exits 0 too.

- [ ] **Step 5: Commit**

```bash
git rev-parse --abbrev-ref HEAD
git add ElliotKit/Sources/ElliotModel/AutoDev.swift ElliotKit/Tests/ElliotModelTests/AutoDevSessionTests.swift
git commit -m "feat(model): a session, its engaged cards and their tally"
```

---

### Task 2: The merge path carries its origin

**Files:**
- Modify: `ElliotKit/Sources/ElliotAppKit/AppModel.swift:411-415` (`PendingMerge`), `:1068-1102` (`move`), `:1171-1175` (`armPendingMerge`), `:1182-1193` (`confirmMerge`)
- Modify: `ElliotKit/Sources/ElliotAppKit/Sheets.swift:130-132`
- Modify: `ElliotKit/Sources/ElliotAppKit/BoardView.swift:657` — a doc comment naming the old selector
- Test: `ElliotKit/Tests/ElliotAppKitTests/AppModelTests.swift` (modify `armingMakesTheConfirmationReachable` and `cancellingMovesNothing`; add two tests)

**Interfaces:**
- Consumes: `MoveOrigin` and `MoveOrigin.autoDev(sessionID: UUID)` from PR1; `MoveOrigin.historyLabel` from `ElliotKit/Sources/ElliotAppKit/Consequence.swift:133-145`.
- Produces:
  - `AppModel.PendingMerge` gains `public var origin: MoveOrigin`
  - `func armPendingMerge(cardID: UUID, prNumber: Int, origin: MoveOrigin)` — internal, unchanged access
  - `public func confirmMerge(cardID: UUID, followUps: [String], origin: MoveOrigin) async`

**Why this is here and not later:** before any history is drawn, the merge path must carry its origin. `confirmMerge` hardcodes `origin: .userDrag` at `AppModel.swift:1187`, so a merge auto-dev arranged would be written into `moveAudit` as a drag and rendered by `MoveOrigin.historyLabel` as **"Dragged"** — a history that lies about who acted, in the one act the product calls irreversible.

- [ ] **Step 1: Write the failing test**

In `ElliotKit/Tests/ElliotAppKitTests/AppModelTests.swift`, replace the two existing calls to `armPendingMerge` (at lines 337 and 351) so they name an origin, and add two tests after `cancellingMovesNothing`. The two edited call sites become:

```swift
        model.armPendingMerge(cardID: review.id, prNumber: 9, origin: .userDrag)
```

Then add, immediately after the `cancellingMovesNothing` test:

```swift
    @Test("The origin travels from the arming to the confirmation")
    func armingCarriesItsOrigin() {
        // `confirmMerge` used to hardcode `.userDrag`, so every merge that went
        // through the confirmation was written into `moveAudit` as a drag —
        // whoever actually asked for it. The origin is decided by the caller
        // that arms the merge and has to survive the trip to the button.
        let a = repo("Elliot")
        let review = card("ready", repoID: a.id, column: .inReview, order: 1, issue: 4, pr: 9)
        let model = model(repos: [a], cards: [review])

        model.armPendingMerge(cardID: review.id, prNumber: 9, origin: .mcp(client: "agent-x"))

        #expect(model.pendingFollowUps?.origin == .mcp(client: "agent-x"))
    }

    @Test("An auto-dev merge is not rendered as a drag")
    func autoDevMergeIsNotDragged() {
        // The whole reason the origin has to travel. `MoveOrigin.historyLabel`
        // is what the move-history block prints; with `.userDrag` hardcoded in
        // `confirmMerge`, a session's merge appeared in the card's history as
        // "Dragged" — attributing the one irreversible act in the product to a
        // person who did not make it.
        //
        // ⚠️ `.autoDev` is PR1's case. If this does not compile, PR1 has not
        // landed and this plan is being run out of order.
        let session = UUID()
        let a = repo("Elliot")
        let review = card("ready", repoID: a.id, column: .inReview, order: 1, issue: 4, pr: 9)
        let model = model(repos: [a], cards: [review])

        model.armPendingMerge(
            cardID: review.id, prNumber: 9, origin: .autoDev(sessionID: session))

        #expect(model.pendingFollowUps?.origin == .autoDev(sessionID: session))
        #expect(MoveOrigin.autoDev(sessionID: session).historyLabel != "Dragged")
        #expect(!MoveOrigin.autoDev(sessionID: session).historyLabel.isEmpty)
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd ElliotKit && swift test --filter AppModelTests`
Expected: FAIL — the test target does not compile, with `error: extra argument 'origin' in call` at the `armPendingMerge` call sites and `error: value of type 'AppModel.PendingMerge' has no member 'origin'`.

- [ ] **Step 3: Write minimal implementation**

In `ElliotKit/Sources/ElliotAppKit/AppModel.swift`, replace the `PendingMerge` declaration at `:411-415` with:

```swift
    public struct PendingMerge: Identifiable, Sendable {
        public var id: UUID { cardID }
        public var cardID: UUID
        public var prNumber: Int
        /// Who asked for this merge.
        ///
        /// Carried from the arming to the button rather than assumed at the
        /// button, because `confirmMerge` used to write `.userDrag` for every
        /// caller — so a merge Elliot arranged for itself appeared in the
        /// card's move history as "Dragged".
        public var origin: MoveOrigin
    }
```

In `move(cardID:to:)` (`:1068-1102`), name the origin once. Replace lines 1069-1075 so the literal appears exactly once in the method:

```swift
        guard let board else { return }
        // Named once. The same origin has to reach `board.move` *and*
        // `armPendingMerge` below — two literals here is how the audit and the
        // confirmation came to disagree about who acted.
        let origin = MoveOrigin.userDrag
        // Captured before the move: by the time `board.move` returns, the
        // card's column and `activeRuns` have both changed, so asking then
        // would describe the world after the act rather than the act.
        let predicted = card(id: cardID).map { Consequence.of(preview($0, to: column)) }
        do {
            let result = try await board.move(cardID: cardID, to: column, origin: origin)
```

and the `.needsInput` arm at `:1089-1091`:

```swift
            case .needsInput(.followUps(let pr)):
                refusal = nil
                armPendingMerge(cardID: cardID, prNumber: pr, origin: origin)
```

Replace `armPendingMerge` (`:1171-1175`) and `confirmMerge` (`:1182-1193`):

```swift
    func armPendingMerge(cardID: UUID, prNumber: Int, origin: MoveOrigin) {
        selectedCardID = cardID
        showingInspector = true
        pendingFollowUps = PendingMerge(cardID: cardID, prNumber: prNumber, origin: origin)
    }
```

```swift
    /// `origin` is a parameter and not `.userDrag`, which is what it used to be
    /// for every caller. The confirmation is a *button*, not an actor: whoever
    /// armed the merge is who made it, and that is what `moveAudit` records and
    /// `MoveOrigin.historyLabel` prints.
    public func confirmMerge(cardID: UUID, followUps: [String], origin: MoveOrigin) async {
        guard let board else { return }
        pendingFollowUps = nil
        do {
            let result = try await board.move(
                cardID: cardID, to: .done, origin: origin, followUps: followUps
            )
            if case .blocked(let block) = result { status = Self.explain(block) }
        } catch {
            status = error.localizedDescription
        }
    }
```

In `ElliotKit/Sources/ElliotAppKit/Sheets.swift`, replace **lines 130-132** — the whole `Button`, not just its body. Line 130 is `Button("Merge PR \(pr)") {`, 131 is the single-line `Task { … }`, 132 is the closing `}`; replacing only 131 leaves a duplicate `Button` line:

```swift
                Button("Merge PR \(pr)") {
                    Task {
                        await model.confirmMerge(
                            cardID: pending.cardID, followUps: cleaned, origin: pending.origin)
                    }
                }
```

And in `ElliotKit/Sources/ElliotAppKit/BoardView.swift`, line 657 reads
`///    3. \`AppModel.armPendingMerge(cardID:prNumber:)\`, which selects a card *and*`.
That selector stops existing; nothing compiles it, so nothing catches it. Correct it to:

```swift
///    3. `AppModel.armPendingMerge(cardID:prNumber:origin:)`, which selects a card *and*
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd ElliotKit && swift test --filter AppModelTests`
Expected: PASS — every test in the suite, including the two new ones.

- [ ] **Step 5: Commit**

```bash
git rev-parse --abbrev-ref HEAD
git add ElliotKit/Sources/ElliotAppKit/AppModel.swift ElliotKit/Sources/ElliotAppKit/Sheets.swift ElliotKit/Sources/ElliotAppKit/BoardView.swift ElliotKit/Tests/ElliotAppKitTests/AppModelTests.swift
git commit -m "feat(app): the merge confirmation records who asked for it"
```

---

### Task 3: `AutoDevBand` — every sentence, decided once

**Files:**
- Create: `ElliotKit/Sources/ElliotAppKit/AutoDevBand.swift`
- Test: `ElliotKit/Tests/ElliotAppKitTests/AutoDevBandTests.swift`

**Interfaces:**
- Consumes: `AutoDevSession`, `AutoDevSession.State`, `AutoDevTally` from Task 1.
- Produces:
  - `struct AutoDevBand: Equatable` with `let headline: String`, `let runNote: String`, `let tone: Tone`, `let controls: [Control]`
  - `enum AutoDevBand.Tone: Equatable { case armed, attention, refused, quiet }`
  - `enum AutoDevBand.Control: Hashable, CaseIterable { case pause, resume, stop }`
  - `static func AutoDevBand.of(session: AutoDevSession?, tally: AutoDevTally, repoName: String) -> AutoDevBand`
  - `static func AutoDevBand.title(_ control: Control) -> String`
  - `static func AutoDevBand.explains(_ control: Control) -> String`
  - `static let AutoDevBand.idle: AutoDevBand`
  - `static let AutoDevBand.caption: String`
  - `static let AutoDevBand.engagedSymbol = "bolt.circle.fill"`
  - `static let AutoDevBand.engagedLabel: String`
  - `static func AutoDevBand.figureText(session: AutoDevSession?, tally: AutoDevTally) -> String?`

- [ ] **Step 1: Write the failing test**

Create `ElliotKit/Tests/ElliotAppKitTests/AutoDevBandTests.swift`:

```swift
import ElliotModel
import Foundation
import Testing

@testable import ElliotAppKit

/// The auto-dev band's sentences, held where `swift test` can reach them.
///
/// The same argument `AnalysisFooterMessageTests` makes one file over: a
/// sentence written inline in a `body` is a claim nothing can hold, and this
/// band has three states, two controls and a figure to keep consistent with
/// each other.
@Suite("Auto-dev band")
struct AutoDevBandTests {

    private let epoch = Date(timeIntervalSince1970: 1_770_000_000)

    private func session(
        _ state: AutoDevSession.State, cards: Int = 5
    ) -> AutoDevSession {
        AutoDevSession(
            repoID: UUID(), engagedCardIDs: (0..<cards).map { _ in UUID() },
            maxAttemptsPerCard: 3, patience: 900, startedAt: epoch, state: state
        )
    }

    // MARK: - Totality

    /// ⛔ The whole difference from `preflightBand`, which is *meant* to vanish.
    /// Preflight is a state nobody has to remember; a session's outcome is a
    /// record. A function with no optional return is what stops this band
    /// becoming conditional by accident.
    @Test("There is a band for every input, including no session at all")
    func ofIsTotal() {
        let states: [AutoDevSession.State?] = [nil, .running, .paused, .finished]
        for state in states {
            let band = AutoDevBand.of(
                session: state.map { session($0) },
                tally: AutoDevTally(engaged: 2, merged: 2, blocked: 1),
                repoName: "Elliot"
            )
            #expect(!band.headline.isEmpty, "\(String(describing: state)) has no headline")
            #expect(!band.runNote.isEmpty, "\(String(describing: state)) has no run note")
        }
    }

    @Test("With no session the band says so and offers no control")
    func idleBand() {
        let band = AutoDevBand.of(
            session: nil, tally: AutoDevTally(engaged: 0, merged: 0, blocked: 0),
            repoName: "Elliot")
        #expect(band == AutoDevBand.idle)
        #expect(band.controls.isEmpty)
        #expect(band.tone == .quiet)
    }

    // MARK: - The three states

    @Test("A running session names the repository, the count and what is left")
    func runningBand() {
        let band = AutoDevBand.of(
            session: session(.running), tally: AutoDevTally(engaged: 3, merged: 1, blocked: 1),
            repoName: "Elliot")
        #expect(band.headline == "Driving 5 cards in Elliot — 2 settled, 3 to go.")
        #expect(band.tone == .armed)
        #expect(band.controls == [.pause, .stop])
    }

    @Test("A paused session offers Resume in Pause's place, and keeps Stop")
    func pausedBand() {
        let band = AutoDevBand.of(
            session: session(.paused), tally: AutoDevTally(engaged: 3, merged: 1, blocked: 1),
            repoName: "Elliot")
        #expect(band.headline == "Paused — 5 cards engaged in Elliot, 2 settled.")
        #expect(band.tone == .attention)
        #expect(band.controls == [.resume, .stop])
    }

    /// The report is a record, so it keeps its sentence and loses its controls
    /// — there is nothing left to pause or to cancel.
    @Test("A finished session reports what happened and offers nothing")
    func finishedBand() {
        let band = AutoDevBand.of(
            session: session(.finished), tally: AutoDevTally(engaged: 0, merged: 3, blocked: 2),
            repoName: "Elliot")
        #expect(band.headline == "Finished — 5 cards in Elliot, 3 merged, 2 blocked.")
        #expect(band.controls.isEmpty)
        #expect(band.runNote.contains("Nothing is running"))
    }

    /// A session that blocked everything must not read like a quiet success.
    /// It is also the one outcome nothing else on the board can show: a card
    /// whose merge failed stays in Done, and `Column.naturalNext` is `nil` for
    /// `.done`, so `rankNextSteps` drops it from Up next entirely.
    @Test("A finished session with blocked cards is refused, a clean one is quiet")
    func finishedTone() {
        let dirty = AutoDevBand.of(
            session: session(.finished), tally: AutoDevTally(engaged: 0, merged: 3, blocked: 2),
            repoName: "Elliot")
        #expect(dirty.tone == .refused)

        let clean = AutoDevBand.of(
            session: session(.finished), tally: AutoDevTally(engaged: 0, merged: 5, blocked: 0),
            repoName: "Elliot")
        #expect(clean.tone == .quiet)
    }

    @Test("One card is a card")
    func singularIsWrittenOut() {
        let band = AutoDevBand.of(
            session: session(.running, cards: 1), tally: AutoDevTally(engaged: 1, merged: 0, blocked: 0),
            repoName: "Elliot")
        #expect(band.headline == "Driving 1 card in Elliot — 0 settled, 1 to go.")
        #expect(!band.headline.contains("1 cards"))
    }

    // MARK: - The controls say what they do to the run already going

    /// The design's requirement, word for word: the stop control says on its
    /// face what it does to the run already in flight, and it cannot lean on
    /// the queue's Pause, which holds *queued* runs and leaves the running one
    /// alone.
    @Test("Stop says it cancels the run already going; Pause says it does not")
    func controlsNameTheRunInFlight() {
        #expect(AutoDevBand.title(.stop) == "Stop and cancel")
        #expect(AutoDevBand.explains(.stop).contains("cancels the run already going"))
        #expect(AutoDevBand.explains(.pause).contains("run already going finishes"))
        // And the band repeats it where a title has no room: the same shape
        // `queueSentence` uses in the band above this one.
        let band = AutoDevBand.of(
            session: session(.running), tally: AutoDevTally(engaged: 5, merged: 0, blocked: 0),
            repoName: "Elliot")
        #expect(band.runNote.contains("already going"))
        #expect(band.runNote.contains("cancels"))
    }

    @Test("Every control has a distinct title and a distinct explanation")
    func controlsAreDistinct() {
        let titles = AutoDevBand.Control.allCases.map(AutoDevBand.title)
        let explains = AutoDevBand.Control.allCases.map(AutoDevBand.explains)
        #expect(Set(titles).count == AutoDevBand.Control.allCases.count)
        #expect(Set(explains).count == AutoDevBand.Control.allCases.count)
        #expect(titles.allSatisfy { !$0.isEmpty })
        #expect(explains.allSatisfy { $0.hasSuffix(".") })
    }

    // MARK: - Why this band is not Up next

    /// Two orders stacked in one window read as one unless the top one says it
    /// is not the same order. Both bands read `rankNextSteps`' world; only one
    /// of them is a ranking.
    @Test("The caption says it answers a different question from Up next")
    func captionDistinguishesItselfFromUpNext() {
        #expect(AutoDevBand.caption.contains("Up next"))
        #expect(AutoDevBand.caption.contains("not a ranking"))
    }

    // MARK: - The status bar's figure

    /// ⚠️ `nil` only when **no session has run this launch** — never because a
    /// session finished. The report is a record, and the figure is its door.
    @Test("The figure is absent only when no session exists")
    func figureIsPermanentThroughTheReport() {
        let tally = AutoDevTally(engaged: 0, merged: 3, blocked: 2)
        #expect(AutoDevBand.figureText(session: nil, tally: tally) == nil)
        for state in AutoDevSession.State.allCases {
            #expect(
                AutoDevBand.figureText(session: session(state), tally: tally) == "5/5 auto-dev",
                "\(state) lost the figure"
            )
        }
    }

    @Test("The figure counts settled against the whole engaged set")
    func figureCounts() {
        #expect(
            AutoDevBand.figureText(
                session: session(.running), tally: AutoDevTally(engaged: 3, merged: 1, blocked: 1)
            ) == "2/5 auto-dev"
        )
    }

    // MARK: - The mark on an engaged card

    @Test("The engaged mark is named, because a card is one accessibility element")
    func engagedMarkIsNamed() {
        #expect(!AutoDevBand.engagedSymbol.isEmpty)
        #expect(AutoDevBand.engagedLabel.hasSuffix("."))
        #expect(AutoDevBand.engagedLabel.lowercased().contains("auto-dev"))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd ElliotKit && swift test --filter AutoDevBandTests`
Expected: FAIL — the target does not compile, with `error: cannot find 'AutoDevBand' in scope`.

- [ ] **Step 3: Write minimal implementation**

Create `ElliotKit/Sources/ElliotAppKit/AutoDevBand.swift`:

```swift
import ElliotModel

/// What the auto-dev band says, decided once.
///
/// The band renders it and judges nothing, for the reason `AnalysisFooterMessage`
/// gives one file over: `swift test` cannot enter a view body, so a sentence
/// written inline there is a claim nothing can hold — and this one has three
/// states, three controls and a status-bar figure that all have to agree.
///
/// It holds no `Color`. ``Tone`` is mapped to `Palette` in `Consequence.swift`,
/// the one file where this project's values meet SwiftUI, so a test asserts the
/// decision rather than a colour — and a value that cannot name a colour cannot
/// be where a sixth consequence accent arrives.
///
/// ⛔ **``of(session:tally:repoName:)`` returns a band for every input,
/// including no session at all.** That totality is the difference from
/// `preflightBand` (`OperationsView.swift:47-49`), which is *meant* to vanish:
/// preflight is a **state** nobody has to remember, and a session's outcome is
/// a **record**. The record it has to carry is the failure — `Column.naturalNext`
/// is `nil` for `.done` (`Column.swift:31-35`), so a card whose merge failed,
/// which stays in Done with a `lastError`, is structurally absent from
/// `NextStepsView` and from the Up next band. This is the only surface that
/// shows it, which is why it is permanent rather than conditional.
struct AutoDevBand: Equatable {

    /// Four, and none of them a sixth accent: three are `BrandColor.consequences`
    /// and `quiet` is greyscale.
    enum Tone: Equatable {
        case armed
        case attention
        case refused
        case quiet
    }

    /// A control the band offers.
    ///
    /// ``stop`` is the one that reaches the run already going. The queue's
    /// Pause cannot: `RunScheduler.pause` holds *queued* runs and leaves the
    /// running one alone, so a session cannot lean on it to stop.
    enum Control: Hashable, CaseIterable {
        case pause
        case resume
        case stop
    }

    /// The mark drawn on an engaged card, and the sentence read in its place.
    ///
    /// A card is one combined accessibility element, so an unlabelled glyph is
    /// read aloud as whatever the system calls the character, jammed against the
    /// title — the same reason `CardView`'s lens mark carries a label.
    static let engagedSymbol = "bolt.circle.fill"
    static let engagedLabel = "Auto-dev is driving this card."

    /// Why this band sits immediately above Up next and answers a different
    /// question.
    ///
    /// Not an arbitrary neighbour: Up next is the ranking of possible moves,
    /// auto-dev is one fixed set of them being made, and both read the world
    /// `rankNextSteps` ranks. Two orders stacked in one window read as one
    /// unless the top one says it is not the same order.
    static let caption =
        "Up next below ranks every move Elliot could make, best first. This is the one "
        + "set of cards Elliot is moving by itself — fixed when the session started, "
        + "and not a ranking."

    let headline: String
    /// What the controls do to the run already going.
    ///
    /// Its own sentence, for the reason `queueSentence` is one: a control's
    /// title has no room for it, and a Stop that does not say it cancels the
    /// run is a Stop the reader has to press to find out about.
    let runNote: String
    let tone: Tone
    let controls: [Control]

    /// No session has run this launch.
    static let idle = AutoDevBand(
        headline: "Elliot is not driving anything by itself.",
        runNote: "Nothing is running.",
        tone: .quiet,
        controls: []
    )

    static func of(
        session: AutoDevSession?, tally: AutoDevTally, repoName: String
    ) -> AutoDevBand {
        guard let session else { return .idle }
        let cards = "\(tally.total) \(tally.total == 1 ? "card" : "cards")"
        switch session.state {
        case .running:
            return AutoDevBand(
                headline:
                    "Driving \(cards) in \(repoName) — \(tally.settled) settled, "
                    + "\(tally.engaged) to go.",
                runNote: liveRunNote,
                tone: .armed,
                controls: [.pause, .stop]
            )
        case .paused:
            return AutoDevBand(
                headline: "Paused — \(cards) engaged in \(repoName), \(tally.settled) settled.",
                runNote: liveRunNote,
                tone: .attention,
                controls: [.resume, .stop]
            )
        case .finished:
            return AutoDevBand(
                headline:
                    "Finished — \(cards) in \(repoName), \(tally.merged) merged, "
                    + "\(tally.blocked) blocked.",
                runNote: "Nothing is running. This report stays until the next session starts.",
                // A session that blocked everything must not read like a quiet
                // success — it is the outcome nothing else on the board shows.
                tone: tally.blocked > 0 ? .refused : .quiet,
                controls: []
            )
        }
    }

    /// The status bar's figure, or `nil` when there is no session to be a door
    /// to.
    ///
    /// ⚠️ `nil` only when **no session has run this launch**. A finished session
    /// still shows: the report is a record, and the figure is how a reader
    /// reaches it from the board.
    static func figureText(session: AutoDevSession?, tally: AutoDevTally) -> String? {
        guard session != nil else { return nil }
        return "\(tally.settled)/\(tally.total) auto-dev"
    }

    static func title(_ control: Control) -> String {
        switch control {
        case .pause: "Pause"
        case .resume: "Resume"
        case .stop: "Stop and cancel"
        }
    }

    static func explains(_ control: Control) -> String {
        switch control {
        case .pause: "Engages no further move. The run already going finishes."
        case .resume: "Starts engaging moves again."
        case .stop: "Ends the session and cancels the run already going."
        }
    }

    private static let liveRunNote =
        "Pause engages no further move and lets the run already going finish. "
        + "Stop ends the session and cancels that run."
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd ElliotKit && swift test --filter AutoDevBandTests`
Expected: PASS — 13 tests, 0 failures.

- [ ] **Step 5: Commit**

```bash
git rev-parse --abbrev-ref HEAD
git add ElliotKit/Sources/ElliotAppKit/AutoDevBand.swift ElliotKit/Tests/ElliotAppKitTests/AutoDevBandTests.swift
git commit -m "feat(app): every sentence the auto-dev band says, decided once"
```

---

### Task 4: The session on `AppModel`, and the seam the loop will fill

**Files:**
- Create: `ElliotKit/Sources/ElliotEngine/AutoDevDriving.swift`
- Modify: `ElliotKit/Sources/ElliotAppKit/AppModel.swift` — a new `// MARK: - Auto-dev` section placed immediately after the existing `// MARK: - Analysis` block, which runs from `:1916` to `:2113` and ends with `runningAngles` (`:2110-2113`); and two seams added to the test-seam block, which starts at `:2122` and ends with `testOnlyAttachAnalysisService` at `:2230-2232`, one line above the class's closing brace at `:2233`
- Test: `ElliotKit/Tests/ElliotAppKitTests/AutoDevStateTests.swift`

**Interfaces:**
- Consumes: `AutoDevSession`, `AutoDevEngagement`, `AutoDevTally`, `AutoDevDisposition` (Task 1); `AutoDevBand.figureText(session:tally:)` (Task 3, in one assertion); and, existing: `Consequence.reason(_:)`, `AppModel.isBlocked(_:)`, `AppModel.selectedRepoID`, `AppModel.repos`, `AppModel.status`, `AppModel.testOnlySeed(repos:cards:)`, `AppModel.testOnlySeedChecks(repo:_:)`, `AppModel.testOnlySeedRuns(active:byCard:recent:analysis:)`, `ElliotModel.SkillRun`, `ElliotEngine.CheckResult`.
- Produces:
  - `public protocol AutoDevDriving: Sendable` in `ElliotEngine`, with `start(repoID:cardLimit:) async throws -> AutoDevSession`, `pause(sessionID:) async -> AutoDevSession?`, `resume(sessionID:) async -> AutoDevSession?`, `stop(sessionID:) async -> AutoDevSession?`, `engagements(sessionID:) async -> [AutoDevEngagement]`

> ⚠️ **Cross-plan: `cardLimit` is a count, and nothing in the six plans says *which* cards.**
> The design promises "optional automatic selection of the highest-value cards", and PR2 delivers
> the whole apparatus for it — `CardValue.of(_:)`, `CardValue.rankable`, and `CardRanking.rank(_:)`
> returning `(ranked:refused:)` — with the rule that a card which is not `.ranked` is **refused, not
> ranked low**. **No plan consumes any of it.** This protocol's `start(repoID:cardLimit:)` says only
> "at most `cardLimit` Backlog cards"; PR4's `AutoDevService.start(session:preflightChecks:)` takes
> the ids already chosen and validates that they belong to the repository. So the selection sits in
> the seam between the two, and each plan reads as though the other owned it.
> **This is a gap to close, not a note to carry.** The natural home is the conformer's
> `start(repoID:cardLimit:)` — `CardRanking.rank(backlogCards).ranked.prefix(cardLimit)` — which is
> in PR4, and PR4's Prerequisites currently declare PR2 *"not required"*. Whoever arbitrates the
> `AutoDevDriving` question above should settle this in the same breath, because the answer decides
> whether PR4 depends on PR2 at all.
  - `AppModel.autoDev: AutoDevSession?` (`public private(set)`)
  - `AppModel.autoDevEngagements: [AutoDevEngagement]` (`public private(set)`)
  - `AppModel.autoDevEngagedCardIDs: Set<UUID>` (`public private(set)`)
  - `AppModel.autoDevTally: AutoDevTally` (computed)
  - `AppModel.autoDevCardLimit: Int` (`public var`, default 3)
  - `AppModel.autoDevRefusal: String?` (computed)
  - `AppModel.startAutoDev() async`, `pauseAutoDev() async`, `resumeAutoDev() async`, `stopAutoDev() async`, `refreshAutoDev() async`
  - `AppModel.testOnlyAttachAutoDev(_:)`, `AppModel.testOnlySeedAutoDev(_:engagements:)`

- [ ] **Step 1: Write the failing test**

Create `ElliotKit/Tests/ElliotAppKitTests/AutoDevStateTests.swift`:

```swift
import ElliotEngine
import ElliotModel
import Foundation
import Testing

@testable import ElliotAppKit

/// A driver that answers from memory.
///
/// An `actor` for the same reason `InertLauncher` in `AppModelTests` is one:
/// `AutoDevDriving` is `Sendable`, and the real conformer (PR4's
/// `AutoDevService`) is an actor too. It records what it was asked so a test
/// can tell "the command reached the driver" from "the model changed its own
/// mind".
private actor FakeAutoDev: AutoDevDriving {
    private var session: AutoDevSession?
    private var rows: [AutoDevEngagement] = []
    /// What `start` was asked for, so a test can tell "the command reached the
    /// driver" from "the model changed its own mind".
    private(set) var startedWith: (repoID: UUID, cardLimit: Int)?
    /// Whether `stop` was called — the one command that must also cancel the
    /// run already going.
    private(set) var stopped = false

    private let cards: [UUID]
    private let failsToStart: Bool

    init(cards: [UUID], failsToStart: Bool = false) {
        self.cards = cards
        self.failsToStart = failsToStart
    }

    struct Refused: Error, LocalizedError {
        var errorDescription: String? { "The driver refused." }
    }

    func start(repoID: UUID, cardLimit: Int) async throws -> AutoDevSession {
        startedWith = (repoID, cardLimit)
        if failsToStart { throw Refused() }
        let made = AutoDevSession(
            repoID: repoID, engagedCardIDs: Array(cards.prefix(cardLimit)),
            maxAttemptsPerCard: 3, patience: 900,
            startedAt: Date(timeIntervalSince1970: 1_770_000_000)
        )
        session = made
        rows = made.engagedCardIDs.map {
            AutoDevEngagement(
                sessionID: made.id, cardID: $0, attempts: 1, disposition: .engaged,
                reason: "Waiting for the pull request to open.",
                updatedAt: Date(timeIntervalSince1970: 1_770_000_000))
        }
        return made
    }

    func pause(sessionID: UUID) async -> AutoDevSession? { transition(to: .paused) }
    func resume(sessionID: UUID) async -> AutoDevSession? { transition(to: .running) }

    func stop(sessionID: UUID) async -> AutoDevSession? {
        stopped = true
        return transition(to: .finished)
    }

    func engagements(sessionID: UUID) async -> [AutoDevEngagement] { rows }

    /// Marks the first row merged, so a test can watch the tally move.
    func settleFirstAsMerged() {
        guard !rows.isEmpty else { return }
        rows[0].disposition = .merged
        rows[0].reason = "gh says the pull request was merged."
    }

    private func transition(to state: AutoDevSession.State) -> AutoDevSession? {
        session?.state = state
        return session
    }
}

/// What `AppModel` holds about an auto-dev session, and what it refuses.
///
/// `@MainActor` on the suite rather than on each test: `AppModel` is main-actor
/// isolated, so every touch of it needs the hop.
@MainActor
@Suite("Auto-dev state")
struct AutoDevStateTests {

    private let epoch = Date(timeIntervalSince1970: 1_770_000_000)

    private func repo(_ name: String, enabled: Bool = true) -> Repo {
        var repo = Repo(
            path: "/tmp/\(name)", nameWithOwner: "phmatray/\(name)",
            defaultBranch: "main", displayName: name
        )
        repo.isEnabled = enabled
        return repo
    }

    private func card(_ title: String, repoID: UUID, order: Double) -> Card {
        Card(
            repoID: repoID, title: title, column: .backlog, orderIndex: order,
            columnEnteredAt: epoch, createdAt: epoch, updatedAt: epoch
        )
    }

    /// A model with one selected repository and three Backlog cards.
    private func seeded(enabled: Bool = true) -> (AppModel, Repo, [Card]) {
        let subject = repo("Elliot", enabled: enabled)
        let cards = [
            card("one", repoID: subject.id, order: 1),
            card("two", repoID: subject.id, order: 2),
            card("three", repoID: subject.id, order: 3),
        ]
        let model = AppModel()
        model.testOnlySeed(repos: [subject], cards: cards)
        model.selectedRepoID = subject.id
        return (model, subject, cards)
    }

    // MARK: - Refusals

    /// The #151 shape: the gate is on the **act**, stated in a sentence, not a
    /// control that cannot be switched off. Until PR4 lands there is no driver,
    /// and the band has to say that rather than look broken.
    @Test("With no driver attached, the refusal says so and Start does nothing")
    func noDriverIsARefusal() async {
        let (model, _, _) = seeded()
        #expect(model.autoDevRefusal == "Auto-dev is not wired into this build yet.")

        await model.startAutoDev()

        #expect(model.autoDev == nil)
        #expect(model.autoDevEngagedCardIDs.isEmpty)
    }

    @Test("A repository Preflight has refused cannot be driven")
    func blockedRepositoryIsRefused() async {
        let (model, subject, cards) = seeded()
        model.testOnlyAttachAutoDev(FakeAutoDev(cards: cards.map(\.id)))
        model.testOnlySeedChecks(
            repo: subject.id,
            [CheckResult(id: "gh.auth", title: "gh", status: .fail, detail: "Not signed in.")])

        #expect(model.autoDevRefusal?.contains("Preflight") == true)
        await model.startAutoDev()
        #expect(model.autoDev == nil)
    }

    @Test("A switched-off repository is refused in the board's own words")
    func disabledRepositoryIsRefused() async {
        let (model, _, cards) = seeded(enabled: false)
        model.testOnlyAttachAutoDev(FakeAutoDev(cards: cards.map(\.id)))
        #expect(model.autoDevRefusal == Consequence.reason(.repoDisabled))
    }

    @Test("No repository picked is a refusal, not a silent no-op")
    func noRepositoryIsARefusal() async {
        let (model, _, cards) = seeded()
        model.testOnlyAttachAutoDev(FakeAutoDev(cards: cards.map(\.id)))
        model.selectedRepoID = nil
        #expect(model.autoDevRefusal == "Pick a single repository to drive.")
    }

    // MARK: - Starting

    @Test("Starting engages the cards and marks them")
    func startingEngages() async throws {
        let (model, subject, cards) = seeded()
        let driver = FakeAutoDev(cards: cards.map(\.id))
        model.testOnlyAttachAutoDev(driver)
        model.autoDevCardLimit = 2

        await model.startAutoDev()

        // The number the stepper holds is what the driver was asked for. A
        // model that engaged three cards while the band said two would be a
        // control that promises one thing and does another.
        let asked = await driver.startedWith
        #expect(asked?.repoID == subject.id)
        #expect(asked?.cardLimit == 2)

        let session = try #require(model.autoDev)
        #expect(session.repoID == subject.id)
        #expect(session.state == .running)
        #expect(model.autoDevEngagedCardIDs == Set(cards.prefix(2).map(\.id)))
        #expect(model.autoDevEngagements.count == 2)
        #expect(model.autoDevTally == AutoDevTally(engaged: 2, merged: 0, blocked: 0))
    }

    @Test("A second session is refused while one is going")
    func oneSessionAtATime() async {
        let (model, _, cards) = seeded()
        model.testOnlyAttachAutoDev(FakeAutoDev(cards: cards.map(\.id)))
        await model.startAutoDev()

        #expect(model.autoDevRefusal?.contains("already going") == true)
    }

    @Test("A start that throws lands in the status line rather than vanishing")
    func failedStartIsReported() async {
        let (model, _, cards) = seeded()
        model.testOnlyAttachAutoDev(FakeAutoDev(cards: cards.map(\.id), failsToStart: true))

        await model.startAutoDev()

        #expect(model.autoDev == nil)
        #expect(model.status == "The driver refused.")
    }

    // MARK: - Pausing and stopping

    @Test("Pause holds the session; Resume puts it back")
    func pauseAndResume() async {
        let (model, _, cards) = seeded()
        model.testOnlyAttachAutoDev(FakeAutoDev(cards: cards.map(\.id)))
        await model.startAutoDev()

        await model.pauseAutoDev()
        #expect(model.autoDev?.state == .paused)

        await model.resumeAutoDev()
        #expect(model.autoDev?.state == .running)
    }

    /// The permanence claim, at the model layer. Stopping ends the session; it
    /// does **not** clear the report, and it does not unmark the cards. A card
    /// whose merge failed stays in Done, where `rankNextSteps` cannot see it —
    /// this is the only place it is still visible.
    @Test("Stopping finishes the session and keeps every row and every mark")
    func stoppingKeepsTheReport() async {
        let (model, _, cards) = seeded()
        let driver = FakeAutoDev(cards: cards.map(\.id))
        model.testOnlyAttachAutoDev(driver)
        await model.startAutoDev()
        let engaged = model.autoDevEngagedCardIDs

        await model.stopAutoDev()

        // It reached the driver: stopping is the one command that also cancels
        // the run already going, and the queue's Pause cannot do that.
        #expect(await driver.stopped)
        #expect(model.autoDev?.state == .finished)
        #expect(model.autoDevEngagements.count == 3)
        #expect(model.autoDevEngagedCardIDs == engaged, "the report keeps its cards marked")
        #expect(AutoDevBand.figureText(session: model.autoDev, tally: model.autoDevTally) != nil)
    }

    /// The other half of permanence: the report stays *until the next session*,
    /// which is exactly what `lastSyncSummary` does (`AppModel.swift:1476`). A
    /// report that outlived the session after it would be two sessions rendered
    /// as one.
    @Test("Starting a new session replaces the previous report")
    func aNewSessionReplacesTheReport() async throws {
        let (model, _, cards) = seeded()
        model.testOnlyAttachAutoDev(FakeAutoDev(cards: cards.map(\.id)))
        await model.startAutoDev()
        let first = try #require(model.autoDev?.id)
        await model.stopAutoDev()
        #expect(model.autoDev?.id == first, "stopping keeps the session it finished")

        await model.startAutoDev()

        let second = try #require(model.autoDev?.id)
        #expect(second != first, "a new session is a new record, not an amendment")
        #expect(model.autoDev?.state == .running)
        #expect(model.autoDevTally == AutoDevTally(engaged: 3, merged: 0, blocked: 0))
    }

    // MARK: - Refreshing the rows

    @Test("Refreshing re-reads the rows and the tally follows")
    func refreshingMovesTheTally() async {
        let (model, _, cards) = seeded()
        let driver = FakeAutoDev(cards: cards.map(\.id))
        model.testOnlyAttachAutoDev(driver)
        await model.startAutoDev()
        #expect(model.autoDevTally.settled == 0)

        await driver.settleFirstAsMerged()
        await model.refreshAutoDev()

        #expect(model.autoDevTally == AutoDevTally(engaged: 2, merged: 1, blocked: 0))
    }

    // MARK: - The mark's source of truth

    /// The mark on a card is read from the **session**, not from the rows, and
    /// not suppressed by a run. A card auto-dev is driving is *most*
    /// interesting while its run is going, which is the opposite of `stagnation`
    /// and `prSign`, both of which the strip rightly hides.
    @Test("An engaged card stays marked while a run is in flight")
    func markSurvivesARunInFlight() async {
        let (model, subject, cards) = seeded()
        model.testOnlyAttachAutoDev(FakeAutoDev(cards: cards.map(\.id)))
        await model.startAutoDev()

        var run = SkillRun(
            cardID: cards[0].id, repoID: subject.id, kind: .createIssue,
            prompt: "/ai-migration-kit:create-issue x", cwd: "/tmp",
            logPath: "/tmp/run.ndjson", stderrPath: "/tmp/run.log", createdAt: epoch
        )
        run.state = .running
        model.testOnlySeedRuns(active: [cards[0].id: run])

        #expect(model.autoDevEngagedCardIDs.contains(cards[0].id))
    }

    @Test("Seeding a session without a driver is enough to render one")
    func seedingWorksWithoutADriver() {
        let (model, subject, cards) = seeded()
        let session = AutoDevSession(
            repoID: subject.id, engagedCardIDs: cards.map(\.id), maxAttemptsPerCard: 3,
            patience: 900, startedAt: epoch, state: .finished)

        model.testOnlySeedAutoDev(
            session,
            engagements: [
                AutoDevEngagement(
                    sessionID: session.id, cardID: cards[0].id, attempts: 2,
                    disposition: .blocked, reason: "No build has judged the pull request.",
                    updatedAt: epoch)
            ])

        #expect(model.autoDev?.state == .finished)
        #expect(model.autoDevTally == AutoDevTally(engaged: 0, merged: 0, blocked: 1))
        #expect(model.autoDevEngagedCardIDs.count == 3)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd ElliotKit && swift test --filter AutoDevStateTests`
Expected: FAIL — the target does not compile, with `error: cannot find type 'AutoDevDriving' in scope` and `error: value of type 'AppModel' has no member 'autoDevRefusal'`.

- [ ] **Step 3: Write minimal implementation**

Create `ElliotKit/Sources/ElliotEngine/AutoDevDriving.swift`:

```swift
import ElliotModel
import Foundation

/// What the board's auto-dev controls reach.
///
/// A protocol rather than a concrete type, because the loop that conforms to it
/// is the **next** pull request: this one ships the screen. `AppModel` holds one
/// optional conformer exactly as it holds `analysisService`, so with none
/// attached every control returns at its guard and `AppModel.autoDevRefusal`
/// says so in a sentence — the #151 shape, an explanation rather than a control
/// that cannot be switched off.
///
/// ⚠️ **`stop` cancels the run already going; `pause` does not.** That is the
/// whole reason a session cannot lean on the queue's Pause
/// (`RunScheduler.pause`), which holds *queued* runs and leaves the running one
/// alone — and it is why the band's stop control says on its face what it does
/// to that run.
///
/// The three mutating calls hand back the session they produced rather than
/// `Void`, so the board's copy and the loop's cannot come apart while nobody is
/// pushing updates. PR4 may add a push; nothing here forbids one.
public protocol AutoDevDriving: Sendable {
    /// Engages at most `cardLimit` Backlog cards of `repoID` and starts driving
    /// them. The engaged list is closed here and never grows.
    func start(repoID: UUID, cardLimit: Int) async throws -> AutoDevSession

    /// Engages no further move. The run already going finishes.
    func pause(sessionID: UUID) async -> AutoDevSession?

    func resume(sessionID: UUID) async -> AutoDevSession?

    /// Ends the session **and cancels the run already going**. Abandoning a card
    /// and cancelling its run are not the same act, and only the second frees
    /// the card.
    func stop(sessionID: UUID) async -> AutoDevSession?

    /// The session's per-card rows, as the report renders them.
    func engagements(sessionID: UUID) async -> [AutoDevEngagement]
}
```

In `ElliotKit/Sources/ElliotAppKit/AppModel.swift`, add a new section immediately after the analysis section — that is, after `runningAngles`' closing brace at `:2113`, and before the `/// The command that registers the bundled helper with Claude Code.` comment at `:2115` that introduces `mcpRegistrationCommand` (`:2116`). ⚠️ There is no `// MARK: - MCP` in this file; `mcpRegistrationCommand` sits under no mark at all, so the mark you are adding is the boundary:

```swift
    // MARK: - Auto-dev

    /// The auto-dev session this launch has run, and what happened to each card.
    ///
    /// ⚠️ **Held through `finished` on purpose.** `Column.naturalNext` returns
    /// `nil` for `.done` (`Column.swift:31-35`), so `rankNextSteps` drops every
    /// card in Done — and a card whose *merge* failed stays in Done carrying a
    /// `lastError`. It is therefore structurally absent from `NextStepsView`
    /// and from the Up next band, and this is the only surface that shows it.
    /// Cleared when the next session starts, which is exactly what
    /// `lastSyncSummary` does (`:1476`).
    public private(set) var autoDev: AutoDevSession?

    /// One row per engaged card: how many attempts, where it got to, and why.
    public private(set) var autoDevEngagements: [AutoDevEngagement] = []

    /// The engaged cards as a set, so `CardView` asks once per card rather than
    /// rebuilding the set per card.
    ///
    /// Derived from the **session** and not from the rows: the mark has to
    /// appear the instant the session exists, and the rows arrive on their own
    /// clock.
    public private(set) var autoDevEngagedCardIDs: Set<UUID> = []

    public var autoDevTally: AutoDevTally { AutoDevTally.of(autoDevEngagements) }

    /// How many Backlog cards the next session engages.
    ///
    /// ⚠️ On the model, never as `@State` in the band, for the reason the four
    /// analysis fields carry (`:241-258`): hiding a view destroys it and every
    /// `@State` in it, and the band lives in a window the reader closes.
    public var autoDevCardLimit = 3

    /// Why auto-dev cannot start right now, or `nil` when it can.
    ///
    /// One answer, read by the band's footer and by the Start button — the
    /// shape `analysisRefusal` has (`:1929-1938`), and for the same reason: the
    /// gate belongs on the **act**, not on a control's visibility. An
    /// unattended session that starts in a checkout Preflight has already
    /// refused is the failure #151 nearly shipped one panel over, and this one
    /// merges.
    public var autoDevRefusal: String? {
        if autoDevDriver == nil { return "Auto-dev is not wired into this build yet." }
        if let session = autoDev, session.state != .finished {
            return "A session is already going. Stop it before starting another."
        }
        guard let id = selectedRepoID, let repo = repos.first(where: { $0.id == id }) else {
            return "Pick a single repository to drive."
        }
        if !repo.isEnabled { return Consequence.reason(.repoDisabled) }
        if isBlocked(repo) {
            return "A Preflight check is failing for this repository — fix it there first."
        }
        return nil
    }

    public func startAutoDev() async {
        guard autoDevRefusal == nil, let driver = autoDevDriver, let repoID = selectedRepoID
        else { return }
        do {
            let session = try await driver.start(repoID: repoID, cardLimit: autoDevCardLimit)
            adopt(session, engagements: await driver.engagements(sessionID: session.id))
        } catch {
            // Said out loud *and* logged: a visible message and a logged one are
            // not alternatives — the log is what a bug report is rebuilt from.
            status = error.localizedDescription
            Self.log.error(
                "Auto-dev failed to start: \(error.localizedDescription, privacy: .public)")
        }
    }

    public func pauseAutoDev() async {
        guard let driver = autoDevDriver, let id = autoDev?.id,
              let updated = await driver.pause(sessionID: id)
        else { return }
        adopt(updated, engagements: await driver.engagements(sessionID: id))
    }

    public func resumeAutoDev() async {
        guard let driver = autoDevDriver, let id = autoDev?.id,
              let updated = await driver.resume(sessionID: id)
        else { return }
        adopt(updated, engagements: await driver.engagements(sessionID: id))
    }

    /// Ends the session and cancels the run already going.
    ///
    /// The report is **not** cleared: `adopt` is handed the finished session,
    /// so the band, the figure and the marks all stay exactly where they are.
    public func stopAutoDev() async {
        guard let driver = autoDevDriver, let id = autoDev?.id,
              let updated = await driver.stop(sessionID: id)
        else { return }
        adopt(updated, engagements: await driver.engagements(sessionID: id))
    }

    public func refreshAutoDev() async {
        guard let driver = autoDevDriver, let session = autoDev else { return }
        adopt(session, engagements: await driver.engagements(sessionID: session.id))
    }

    /// The one place the session, its rows and the engaged set are assigned.
    ///
    /// One assignment site for all three, for the reason `reloadRepoRows` gives
    /// (`:1489-1508`): a mark drawn from one pass beside a row from another is
    /// two moments rendered as one.
    private func adopt(_ session: AutoDevSession?, engagements: [AutoDevEngagement]) {
        autoDev = session
        autoDevEngagements = engagements
        autoDevEngagedCardIDs = Set(session?.engagedCardIDs ?? [])
    }

    private var autoDevDriver: (any AutoDevDriving)?
```

And add the two seams to the test-seam block at the end of the type, after `testOnlyAttachAnalysisService` (`:2230-2232`):

```swift
    /// Puts a driver behind the model without `start()`.
    ///
    /// Optional because *detaching* is a seam of its own: with none attached
    /// every control returns at its guard, which is the state this build ships
    /// in until the loop lands.
    func testOnlyAttachAutoDev(_ driver: (any AutoDevDriving)?) {
        autoDevDriver = driver
    }

    /// Puts a session and its rows in front of the model with no driver at all.
    ///
    /// The band and the figure are the things under test in most of this
    /// feature, and both read only what `adopt` assigns. A test that stood a
    /// driver up to assert a sentence would be testing the fake.
    func testOnlySeedAutoDev(
        _ session: AutoDevSession?, engagements: [AutoDevEngagement] = []
    ) {
        adopt(session, engagements: engagements)
    }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd ElliotKit && swift test --filter AutoDevStateTests`
Expected: PASS — 13 tests, 0 failures.

- [ ] **Step 5: Commit**

```bash
git rev-parse --abbrev-ref HEAD
git add ElliotKit/Sources/ElliotEngine/AutoDevDriving.swift ElliotKit/Sources/ElliotAppKit/AppModel.swift ElliotKit/Tests/ElliotAppKitTests/AutoDevStateTests.swift
git commit -m "feat(engine,app): the board holds an auto-dev session, and refuses one by name"
```

---

### Task 5: The band, immediately above Up next

**Files:**
- Modify: `ElliotKit/Sources/ElliotAppKit/Consequence.swift` (append three extensions at the end of the file)
- Modify: `ElliotKit/Sources/ElliotAppKit/OperationsView.swift:33-39` (the band list) and a new `// MARK: - Auto-dev` section between `spendingBand` and `// MARK: - Up next` (`:278`)
- Test: `ElliotKit/Tests/ElliotAppKitTests/OperationsBandOrderTests.swift`

**Interfaces:**
- Consumes: `AutoDevBand.of(session:tally:repoName:)`, `AutoDevBand.caption`, `AutoDevBand.title(_:)`, `AutoDevBand.explains(_:)`, `AutoDevBand.Control` (Task 3); `AppModel.autoDev`, `autoDevEngagements`, `autoDevTally`, `autoDevCardLimit`, `autoDevRefusal`, `startAutoDev()`, `pauseAutoDev()`, `resumeAutoDev()`, `stopAutoDev()` (Task 4); `AppModel.card(id:)`, `AppModel.repos`, `AppModel.selectedRepoID`; the existing `band(_:content:)` chrome helper at `OperationsView.swift:323-331`.
- Produces:
  - `var AutoDevBand.Tone.tint: Color`, `var AutoDevDisposition.tint: Color`, `var AutoDevDisposition.icon: String` in `Consequence.swift`
  - `OperationsView.autoDevBand`, drawn between `spendingBand` and `upNextBand`

- [ ] **Step 1: Write the failing test**

Create `ElliotKit/Tests/ElliotAppKitTests/OperationsBandOrderTests.swift`:

```swift
import Foundation
import Testing

@testable import ElliotAppKit

/// Where the auto-dev band sits, and that it sits there always.
///
/// `swift test` cannot see the screen — this project has paid three merges for
/// pretending otherwise (#47, #50, #52, #53) — but it can read the source, which
/// is the idiom `CardAngleMarkTests` and `DrainDuplicationTests` already use for
/// claims about a view's *shape*. Two claims here, and both are load-bearing:
///
/// 1. **Adjacency.** "Above Up next" is not "somewhere above": Up next is the
///    ranking of moves Elliot could make and auto-dev is one fixed set of them
///    being made, so the two have to be read together or the caption explaining
///    the difference is explaining a difference the reader cannot see.
/// 2. **Unconditionality.** `preflightBand` is `@ViewBuilder` and vanishes when
///    nothing is failing, and it is right to: preflight is a state nobody has to
///    remember. A session's outcome is a record — and the record it carries is a
///    failed merge, which stays in Done where `rankNextSteps` cannot see it.
@Suite("Operations band order")
struct OperationsBandOrderTests {

    /// Where the views live, found from this file rather than from the working
    /// directory — `swift test` promises nothing about the latter.
    private static var viewSources: URL {
        URL(filePath: #filePath)          // …/Tests/ElliotAppKitTests/<this file>
            .deletingLastPathComponent()  // …/Tests/ElliotAppKitTests
            .deletingLastPathComponent()  // …/Tests
            .deletingLastPathComponent()  // …/ElliotKit
            .appending(path: "Sources/ElliotAppKit")
    }

    private static func source() throws -> String {
        try String(
            contentsOf: viewSources.appending(path: "OperationsView.swift"), encoding: .utf8)
    }

    /// The bare band identifiers inside the screen's one `VStack`, in order.
    private static func bandOrder(in source: String) throws -> [String] {
        let lines = source.components(separatedBy: "\n")
        let start = try #require(
            lines.firstIndex { $0.contains("VStack(alignment: .leading, spacing: 18) {") },
            "the screen's band stack has been restructured — this scan is now looking at nothing"
        )
        var order: [String] = []
        for raw in lines[(start + 1)...] {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line == "}" { break }
            guard !line.hasPrefix("//"), line.hasSuffix("Band") else { continue }
            order.append(line)
        }
        return order
    }

    @Test("The auto-dev band is drawn immediately above Up next")
    func bandSitsDirectlyAboveUpNext() throws {
        let order = try Self.bandOrder(in: try Self.source())
        #expect(
            order == [
                "preflightBand", "workersBand", "queueBand", "spendingBand",
                "autoDevBand", "upNextBand",
            ],
            "read \(order)"
        )
    }

    /// The one thing a source scan can say about permanence, and the reason it
    /// is worth saying: the failure this band exists to show is invisible
    /// everywhere else, so a band that learned to hide itself would take the
    /// evidence with it.
    @Test("The band is not conditional on there being a session")
    func bandIsUnconditional() throws {
        let source = try Self.source()
        #expect(source.contains("AutoDevBand.of("))
        #expect(
            !source.contains("if model.autoDev"),
            "the band must ask AutoDevBand.of for an answer, not decide whether to draw at all"
        )
        #expect(
            !source.contains("if let session = model.autoDev"),
            "same: `of` is total, so there is nothing to guard on"
        )
    }

    /// ⛔ The start control claims more unattended runs than the analysis panel
    /// does, and it merges. Two places it must not be: `.toolbar`, the one
    /// region `board_screenshot` renders blank, and the Return key, which it
    /// would share with `DetailPanelView`'s Save with nothing deciding between
    /// them.
    @Test("The start control is neither in the toolbar nor on Return")
    func startControlIsWhereItCanBeSeenAndNotWhereItCanBeHit() throws {
        let source = try Self.source()
        #expect(source.contains("Start auto-dev"))
        #expect(!source.contains(".toolbar"))
        #expect(!source.contains(".keyboardShortcut(.defaultAction)"))

        // And it is not hiding in the board's toolbar either.
        let board = try String(
            contentsOf: Self.viewSources.appending(path: "BoardView.swift"), encoding: .utf8)
        #expect(!board.contains("Start auto-dev"))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd ElliotKit && swift test --filter OperationsBandOrderTests`
Expected: FAIL — three failures. `bandSitsDirectlyAboveUpNext` records `read ["preflightBand", "workersBand", "queueBand", "spendingBand", "upNextBand"]`; `bandIsUnconditional` and `startControlIsWhereItCanBeSeenAndNotWhereItCanBeHit` fail on the missing `AutoDevBand.of(` and `Start auto-dev`.

- [ ] **Step 3: Write minimal implementation**

Append to `ElliotKit/Sources/ElliotAppKit/Consequence.swift`:

```swift
extension AutoDevBand.Tone {
    /// The same arrangement as `RunState.tint` above, and for the same reason:
    /// the *sentence* is `AutoDevBand`'s and only the colour is decided here,
    /// because only the colour needs SwiftUI. **Two** surfaces draw this band's
    /// tone — the Operations band and the status bar's figure — so one mapping
    /// rather than two is the point.
    ///
    /// Four cases and no sixth accent: three are `BrandColor.consequences`, and
    /// `quiet` is greyscale, which spends none of the budget.
    var tint: Color {
        switch self {
        case .armed: Palette.armed
        case .attention: Palette.attention
        case .refused: Palette.refused
        case .quiet: Palette.quiet
        }
    }
}

extension AutoDevDisposition {
    /// `merged` is `verified` and not `irreversible`: the merge has already
    /// happened and `gh` confirmed it, which is precisely what `verified` means.
    /// `irreversible` is reserved for the act about to be taken.
    var tint: Color {
        switch self {
        case .engaged: Palette.armed
        case .merged: Palette.verified
        case .blocked: Palette.refused
        }
    }

    var icon: String {
        switch self {
        case .engaged: "bolt.circle.fill"
        case .merged: "checkmark.seal.fill"
        case .blocked: "xmark.seal.fill"
        }
    }
}
```

In `ElliotKit/Sources/ElliotAppKit/OperationsView.swift`, replace the band list at `:33-39`:

```swift
            VStack(alignment: .leading, spacing: 18) {
                preflightBand
                workersBand
                queueBand
                spendingBand
                autoDevBand
                upNextBand
            }
```

and insert this section immediately before `// MARK: - Up next` (`:278`):

```swift
    // MARK: - Auto-dev

    /// Immediately above Up next, and the adjacency is the argument.
    ///
    /// Up next is the ranking of moves Elliot *could* make; auto-dev is one
    /// fixed set of them being made. Both read the world `rankNextSteps` ranks,
    /// so two orders stacked in one window read as one unless the top one says
    /// it is not the same order — which is what `AutoDevBand.caption` says.
    ///
    /// **Permanent, never conditional** — unlike `preflightBand` above, and the
    /// difference is not taste. Preflight is a *state* nobody has to remember;
    /// a session's outcome is a **record**, and the record it has to carry is
    /// the failure: `Column.naturalNext` is `nil` for `.done`
    /// (`Column.swift:31-35`), so a card whose merge failed — which stays in
    /// Done with a `lastError` — is structurally absent from `NextStepsView`
    /// and from Up next below. A conditional band would render a session that
    /// failed everywhere exactly like a session that never happened. The
    /// template is `model.lastSyncSummary` (`RepositoriesView.swift:136-161`),
    /// which stays after the sweep.
    ///
    /// It computes nothing: `AutoDevBand.of` is total and decides every
    /// sentence, and this renders what it returns.
    private var autoDevBand: some View {
        let rendering = AutoDevBand.of(
            session: model.autoDev, tally: model.autoDevTally, repoName: autoDevRepoName)
        return band("Auto-dev") {
            Text(rendering.headline)
                .font(Type.prose)
                .foregroundStyle(rendering.tone.tint)
                .fixedSize(horizontal: false, vertical: true)

            Text(AutoDevBand.caption)
                .font(Type.prose)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            // The queue band's shape (`:150-167`): the sentence that says what
            // the controls do, then the controls. The sentence is not decoration
            // — a title has no room to say that Stop cancels the run already
            // going, and the queue's own Pause cannot do that at all.
            HStack(alignment: .top, spacing: 8) {
                Text(rendering.runNote)
                    .font(Type.prose)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                ForEach(rendering.controls, id: \.self) { control in
                    Button(AutoDevBand.title(control)) { act(control) }
                        .controlSize(.small)
                        .help(AutoDevBand.explains(control))
                        .accessibilityHint(AutoDevBand.explains(control))
                }
            }

            ForEach(model.autoDevEngagements) { engagement in
                engagementRow(engagement)
            }

            startRow
        }
    }

    /// One engaged card, in `queueRow`'s shape: what it is, and the rule that
    /// decided it. The reason is the row's point — a report that says a card is
    /// blocked without saying why sends the reader nowhere.
    private func engagementRow(_ engagement: AutoDevEngagement) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: engagement.disposition.icon)
                .font(.system(size: 10))
                .foregroundStyle(engagement.disposition.tint)
                .frame(width: 18)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(engagementTitle(engagement))
                    .font(Type.prose)
                    .fixedSize(horizontal: false, vertical: true)
                Text(engagement.reason)
                    .font(Type.prose)
                    .foregroundStyle(engagement.disposition.tint)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            Fact(text: "\(engagement.attempts)", tint: Palette.quiet, small: true)
                .help("Attempts on this card")
        }
        .padding(8)
        .background(Surface.recess)
        .clipShape(RoundedRectangle(cornerRadius: Metric.cardRadius))
        .accessibilityElement(children: .combine)
    }

    /// A deleted card still has a row: the session engaged it, and dropping the
    /// row would make the report quietly shorter than the session it describes.
    private func engagementTitle(_ engagement: AutoDevEngagement) -> String {
        model.card(id: engagement.cardID)?.displayTitle ?? "A card that is no longer on the board"
    }

    /// Start, how many cards it engages, and — when it cannot start — why.
    ///
    /// ⛔ Deliberately **not** in `.toolbar`, the one region `board_screenshot`
    /// renders blank, and it never carries `.keyboardShortcut(.defaultAction)`.
    /// The analysis panel was refused one for claiming up to eight unattended
    /// runs; this claims more, and merges.
    ///
    /// The refusal is *stated beside* a disabled Start rather than hidden — the
    /// same arrangement `AnalysisPanelView` reached after #151: a control you
    /// cannot press has to say what would let you press it.
    private var startRow: some View {
        @Bindable var model = model
        return HStack(spacing: 8) {
            Stepper(value: $model.autoDevCardLimit, in: 1...10) {
                Text(
                    "\(model.autoDevCardLimit) "
                        + (model.autoDevCardLimit == 1 ? "card" : "cards")
                )
                .font(Type.prose)
            }
            .fixedSize()

            Button("Start auto-dev") { Task { await model.startAutoDev() } }
                .controlSize(.small)
                .disabled(model.autoDevRefusal != nil)

            if let refusal = model.autoDevRefusal {
                Text(refusal)
                    .font(Type.prose)
                    .foregroundStyle(Palette.refused)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }

    /// The session's repository, or the one the picker is on before a session
    /// exists. Never blank: the headline names it.
    private var autoDevRepoName: String {
        guard let id = model.autoDev?.repoID ?? model.selectedRepoID,
              let repo = model.repos.first(where: { $0.id == id })
        else { return "no repository" }
        return repo.displayName
    }

    private func act(_ control: AutoDevBand.Control) {
        Task {
            switch control {
            case .pause: await model.pauseAutoDev()
            case .resume: await model.resumeAutoDev()
            case .stop: await model.stopAutoDev()
            }
        }
    }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd ElliotKit && swift test --filter OperationsBandOrderTests`
Expected: PASS — 3 tests, 0 failures.

- [ ] **Step 5: Commit**

```bash
git rev-parse --abbrev-ref HEAD
git add ElliotKit/Sources/ElliotAppKit/OperationsView.swift ElliotKit/Sources/ElliotAppKit/Consequence.swift ElliotKit/Tests/ElliotAppKitTests/OperationsBandOrderTests.swift
git commit -m "feat(app): an auto-dev band in Operations, immediately above Up next"
```

---

### Task 6: The figure in the status bar, and what it says aloud

**Files:**
- Modify: `ElliotKit/Sources/ElliotAppKit/BoardView.swift:785-846` (`StatusBar.body` — the insertion point is between the workers figure, which ends at `:807`, and the queue figure's comment at `:809`) and `:1348-1450` (`BoardAccessibility`)
- Test: `ElliotKit/Tests/ElliotAppKitTests/BoardAccessibilityTests.swift` (add four tests)

**Interfaces:**
- Consumes: `AutoDevBand.of(session:tally:repoName:)`, `AutoDevBand.figureText(session:tally:)`, `AutoDevBand.Tone.tint` (Tasks 3, 5); `AppModel.autoDev`, `autoDevTally` (Task 4); the existing `StatusBar.figure(text:tint:help:spoken:window:)` at `BoardView.swift:853-863`.
- Produces: `static func BoardAccessibility.autoDevFigure(state: AutoDevSession.State, tally: AutoDevTally) -> String`

- [ ] **Step 1: Write the failing test**

Add to `ElliotKit/Tests/ElliotAppKitTests/BoardAccessibilityTests.swift`, immediately after the `analysisPanelCaptionNamesTheRepositoryAndTheBacklogOfDecisions` test (before `// MARK: - 3. Reduce motion`):

```swift
    // MARK: - 2b. The auto-dev figure

    /// "3/5 auto-dev" is a screen reader's nightmare for the reason `figure`'s
    /// own comment gives (`BoardView.swift:848-852`): a number with no sentence
    /// around it says nothing to anyone who cannot see where it sits. And the
    /// state matters as much as the count — a running session and a finished
    /// one showing the same numbers are two different things to be told.
    @Test("The auto-dev figure says the state and the count, in a sentence")
    func autoDevFigureIsASentence() {
        let five = AutoDevTally(engaged: 2, merged: 2, blocked: 1)
        #expect(
            BoardAccessibility.autoDevFigure(state: .running, tally: five)
                == "Auto-dev running, 3 of 5 cards settled")
        #expect(
            BoardAccessibility.autoDevFigure(state: .paused, tally: five)
                == "Auto-dev paused, 3 of 5 cards settled")
        #expect(
            BoardAccessibility.autoDevFigure(state: .finished, tally: five)
                == "Auto-dev finished, 3 of 5 cards settled")
    }

    /// Singular written out by hand, as `:1343-1347` requires of every caption
    /// in this file. "1 cards settled" is read aloud.
    @Test("One card is a card, in the auto-dev figure too")
    func autoDevFigureSingular() {
        #expect(
            BoardAccessibility.autoDevFigure(
                state: .finished, tally: AutoDevTally(engaged: 0, merged: 1, blocked: 0))
                == "Auto-dev finished, 1 of 1 card settled")
    }

    /// Over every case rather than a sample: a fourth state added without a
    /// phrase would be spoken as whatever the third one says.
    @Test("Every session state is spoken, and no two the same")
    func everyAutoDevStateIsSpoken() {
        let tally = AutoDevTally(engaged: 1, merged: 1, blocked: 0)
        let spoken = AutoDevSession.State.allCases.map {
            BoardAccessibility.autoDevFigure(state: $0, tally: tally)
        }
        #expect(spoken.allSatisfy { !$0.isEmpty })
        #expect(Set(spoken).count == AutoDevSession.State.allCases.count)
    }

    /// The figure is a door to the **report**, so its guard is "a session
    /// exists", never "a session is running". A session that failed everywhere
    /// is the one this feature has to leave visible: its cards stay in Done,
    /// where `Column.naturalNext` is `nil` and `rankNextSteps` drops them.
    ///
    /// It also pins **where the figure's text comes from**. `AutoDevBand.figureText`
    /// is that sentence, and `AutoDevBandTests` holds it — including that it is
    /// present for a `finished` session. A second `"…/… auto-dev"` spelled out
    /// inline here would be two authors for the one number this feature exists
    /// to state, and the shipped one would be the untested one.
    @Test("The figure is gated on a session existing, not on it running")
    func autoDevFigureSurvivesTheReport() throws {
        let source = try String(
            contentsOf: Self.viewSources.appending(path: "BoardView.swift"), encoding: .utf8)
        #expect(source.contains("if let autoDevSession = model.autoDev,"))
        #expect(
            source.contains("AutoDevBand.figureText("),
            "the status bar must render AutoDevBand's sentence, not build its own"
        )
        #expect(
            !source.contains("model.autoDev?.state == .running"),
            "the figure must not disappear when the session ends — that is the report"
        )
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd ElliotKit && swift test --filter BoardAccessibilityTests`
Expected: FAIL — the target does not compile, with `error: type 'BoardAccessibility' has no member 'autoDevFigure'`.

- [ ] **Step 3: Write minimal implementation**

In `ElliotKit/Sources/ElliotAppKit/BoardView.swift`, add the figure to `StatusBar.body` immediately after the workers figure (which ends at `:807`) and before the queue figure's comment at `:809`:

```swift
            // Permanent for the life of a session **and its report**, which is
            // the difference from the queue's figure below: that one is a live
            // state and rightly disappears, this one is a record. The card the
            // record has to carry — one whose merge failed — stays in Done,
            // where `Column.naturalNext` is `nil` and `rankNextSteps` drops it,
            // so nothing else on the board can show it.
            //
            // Gone only when **no session has run this launch**, and cleared by
            // the next session starting. The template is `lastSyncSummary`.
            //
            // The text is `AutoDevBand.figureText`'s and not this view's:
            // `swift test` cannot enter a `body`, so a sentence written here is
            // a claim nothing can hold, and the band already says this one.
            // It is optional for exactly one case — no session at all — which
            // is why it is a clause of the same `if let` rather than a `??`
            // fallback nothing could ever reach.
            //
            // The tally is read **once**, above the `if`: `AutoDevTally.of`
            // walks the rows three times, and this strip re-renders on every
            // status change.
            let autoDevTally = model.autoDevTally
            if let autoDevSession = model.autoDev,
               let autoDevText = AutoDevBand.figureText(
                   session: autoDevSession, tally: autoDevTally) {
                let autoDevBand = AutoDevBand.of(
                    session: autoDevSession, tally: autoDevTally, repoName: autoDevRepoName)
                figure(
                    text: autoDevText,
                    tint: autoDevBand.tone.tint,
                    help: autoDevBand.headline,
                    spoken: BoardAccessibility.autoDevFigure(
                        state: autoDevSession.state, tally: autoDevTally),
                    window: "operations"
                )
            }
```

and add to `StatusBar`, after the `figure` helper (`:863`) and before the closing brace of the struct:

```swift
    /// The session's repository, for the tooltip's sentence. Never blank.
    private var autoDevRepoName: String {
        guard let id = model.autoDev?.repoID,
              let repo = model.repos.first(where: { $0.id == id })
        else { return "no repository" }
        return repo.displayName
    }
```

In `BoardAccessibility` (`:1348-1450`), add before the private `cards(_:)` helper:

```swift
    /// The status bar's auto-dev figure, as a sentence.
    ///
    /// The state and the count, because the two together are the answer: "3 of
    /// 5 settled" says nothing about whether anything is still going, and a
    /// finished session showing the same numbers as a running one is exactly
    /// the confusion the permanent figure would otherwise create.
    ///
    /// Singular written out by hand, as this file's header requires of every
    /// caption in it: these strings are read aloud.
    static func autoDevFigure(state: AutoDevSession.State, tally: AutoDevTally) -> String {
        let phase: String
        switch state {
        case .running: phase = "running"
        case .paused: phase = "paused"
        case .finished: phase = "finished"
        }
        return "Auto-dev \(phase), \(tally.settled) of \(tally.total) \(cards(tally.total)) settled"
    }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd ElliotKit && swift test --filter BoardAccessibilityTests`
Expected: PASS — the whole suite, including the four new tests.

- [ ] **Step 5: Commit**

```bash
git rev-parse --abbrev-ref HEAD
git add ElliotKit/Sources/ElliotAppKit/BoardView.swift ElliotKit/Tests/ElliotAppKitTests/BoardAccessibilityTests.swift
git commit -m "feat(app): a status-bar figure for the auto-dev session, and its spoken sentence"
```

---

### Task 7: The mark on an engaged card

**Files:**
- Modify: `ElliotKit/Sources/ElliotAppKit/CardView.swift:19-35` (the title row) and `:204-246` (the computed properties)
- Test: `ElliotKit/Tests/ElliotAppKitTests/AutoDevCardMarkTests.swift`

**Interfaces:**
- Consumes: `AutoDevBand.engagedSymbol`, `AutoDevBand.engagedLabel` (Task 3); `AppModel.autoDevEngagedCardIDs` (Task 4).
- Produces: `CardView.isEngagedByAutoDev` (private) and the mark itself. No new public API.

**⚠️ `CardView.swift:77` is deliberately not amended.** Read that line: `if !facts.isEmpty || repoName != nil || stagnation != nil || prSign != nil`. It is the **facts row**'s guard, and it is precisely what makes that row *absent* for a freshly engaged card — no issue, no pull request, `stagnation` and `prSign` both suppressed while a run is going. The design puts the mark in the title row **"not in the facts row, which does not exist for a freshly engaged card"**. Adding the engagement as a fourth disjunct there would put the mark exactly where the design forbids it, and would also draw a facts row containing only the mark. Step 1's `markIsInTheTitleRow` measures line positions and fails if anyone moves it.

**No sixth tint.** The mark is `Palette.armed`, which engaged cards already are.

- [ ] **Step 1: Write the failing test**

Create `ElliotKit/Tests/ElliotAppKitTests/AutoDevCardMarkTests.swift`:

```swift
import AppKit
import Foundation
import Testing

@testable import ElliotAppKit

/// The auto-dev mark, on the card.
///
/// The same bound `CardAngleMarkTests` states one file over: nothing in
/// `swift test` can see that a glyph is on screen, and this project has paid
/// four times for pretending otherwise (#47, #50, #52, #53). What a test *can*
/// hold is that the symbol resolves at all, and where in the source the mark is
/// drawn — which is the whole question here, because "title row, not facts row"
/// is the design decision and the two rows behave differently.
@Suite("The auto-dev mark on a card")
struct AutoDevCardMarkTests {

    private static var viewSources: URL {
        URL(filePath: #filePath)          // …/Tests/ElliotAppKitTests/<this file>
            .deletingLastPathComponent()  // …/Tests/ElliotAppKitTests
            .deletingLastPathComponent()  // …/Tests
            .deletingLastPathComponent()  // …/ElliotKit
            .appending(path: "Sources/ElliotAppKit")
    }

    private static func cardViewLines() throws -> [String] {
        try String(contentsOf: viewSources.appending(path: "CardView.swift"), encoding: .utf8)
            .components(separatedBy: "\n")
    }

    /// A symbol name that does not resolve draws **nothing** and errors
    /// nowhere — the sixth member of this repository's family of mechanisms
    /// that substitute different behaviour instead of saying no. One line of
    /// measurement closes it.
    @Test("The mark's symbol exists on this system")
    func symbolResolves() {
        #expect(
            NSImage(systemSymbolName: AutoDevBand.engagedSymbol, accessibilityDescription: nil)
                != nil,
            "\(AutoDevBand.engagedSymbol) does not resolve — the card would draw an empty gap"
        )
    }

    /// The design's placement, measured rather than assumed.
    ///
    /// The title row (`CardView.swift:19-35`) is unconditional and survives a
    /// run. The facts row's guard (`:77`) is what makes that row *absent* for a
    /// freshly engaged card — no issue, no pull request, and `stagnation` and
    /// `prSign` both suppressed while a run is going. A mark that landed there
    /// would be invisible for exactly the cards it is about.
    @Test("The mark is drawn in the title row, above the facts row's guard")
    func markIsInTheTitleRow() throws {
        let lines = try Self.cardViewLines()
        let titleRow = try #require(
            lines.firstIndex { $0.contains("HStack(alignment: .firstTextBaseline, spacing: 5)") },
            "the card's title row has moved — this scan is looking at nothing")
        let factsRow = try #require(
            lines.firstIndex { $0.contains("if !facts.isEmpty || repoName != nil") },
            "the facts row's guard has moved — this scan is looking at nothing")
        let mark = try #require(
            lines.firstIndex { $0.contains("AutoDevBand.engagedSymbol") },
            "the mark is not drawn anywhere in CardView")

        #expect(mark > titleRow, "the mark must be inside the title row")
        #expect(mark < factsRow, "the mark must not be in the facts row, which can be absent")
    }

    /// `stagnation` (`CardView.swift:229-232`) and `prSign` (`:243-246`) both
    /// open with `guard activeRun == nil`, and both are right to: `RunningStrip`
    /// owns the card's attention while a run is going, and two elapsed times on
    /// one card read as one contradicting the other. The engagement mark is not
    /// that kind of fact — a card auto-dev is driving is **most** interesting
    /// while its run is going — so it must not learn the same habit from its
    /// neighbours.
    @Test("The mark is not suppressed by a run in flight")
    func markSurvivesARun() throws {
        let lines = try Self.cardViewLines()
        let start = try #require(
            lines.firstIndex { $0.contains("private var isEngagedByAutoDev") },
            "isEngagedByAutoDev is not declared")
        let declaration = lines[start..<min(lines.count, start + 4)].joined(separator: "\n")

        #expect(
            !declaration.contains("activeRun"),
            "the engagement mark must survive a run — see stagnation and prSign for the habit"
        )
    }

    /// No sixth tint. Engaged cards are `armed`, which they already are.
    @Test("The mark spends no new accent")
    func markUsesArmed() throws {
        let lines = try Self.cardViewLines()
        let mark = try #require(lines.firstIndex { $0.contains("AutoDevBand.engagedSymbol") })
        let block = lines[mark..<min(lines.count, mark + 6)].joined(separator: "\n")
        #expect(block.contains("Palette.armed"))
        #expect(block.contains("AutoDevBand.engagedLabel"))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd ElliotKit && swift test --filter AutoDevCardMarkTests`
Expected: FAIL — three failures. `markIsInTheTitleRow` fails on its third `#require` with *"the mark is not drawn anywhere in CardView"*, `markSurvivesARun` on *"isEngagedByAutoDev is not declared"*, and `markUsesArmed` on its `#require`. `symbolResolves` passes.

- [ ] **Step 3: Write minimal implementation**

In `ElliotKit/Sources/ElliotAppKit/CardView.swift`, replace the title row at `:19-35`:

```swift
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                if let angle = card.angle {
                    Text(angle.symbol)
                        .font(Type.cardTitle)
                        // The card is one combined accessibility element, so an
                        // unlabelled emoji is read as whatever the system calls
                        // the character, jammed against the title. The lens has
                        // a name.
                        .accessibilityLabel(angle.title)
                        .help(angle.title)
                }
                // Beside the lens, in the title row, because this row is
                // unconditional and survives a run. It is deliberately **not**
                // in the facts row below: that row's guard (`:77` before this
                // mark existed) makes it absent for a freshly engaged card —
                // no issue, no pull request, `stagnation` and `prSign` both
                // suppressed while a run is going — which is exactly the card
                // this mark is about.
                //
                // ⚠️ No `guard activeRun == nil`, unlike `stagnation` and
                // `prSign`. A card auto-dev is driving is *most* interesting
                // while its run is going, and the mark says who is driving it,
                // not what state it is in.
                //
                // `Palette.armed` and no sixth tint: engaged cards are armed,
                // which is what `armed` already means.
                if isEngagedByAutoDev {
                    Image(systemName: AutoDevBand.engagedSymbol)
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.armed)
                        .accessibilityLabel(AutoDevBand.engagedLabel)
                        .help(AutoDevBand.engagedLabel)
                }
                Text(card.displayTitle)
                    .font(Type.cardTitle)
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
```

and add, immediately after `private var activeRun: SkillRun? { model.activeRuns[card.id] }` (`:205`):

```swift
    /// Whether an auto-dev session has engaged this card.
    ///
    /// Read from the **session's** engaged list rather than from its rows: the
    /// list is closed at start, so the mark is right from the instant the
    /// session exists, and it stays right through the report — a card whose
    /// merge failed is still a card the session engaged.
    private var isEngagedByAutoDev: Bool { model.autoDevEngagedCardIDs.contains(card.id) }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd ElliotKit && swift test --filter AutoDevCardMarkTests`
Expected: PASS — 4 tests, 0 failures.

Then the whole suite, five times after a clean build, because this task touched the file every column draws:

```bash
cd ElliotKit && swift build && for i in 1 2 3 4 5; do swift test 2>&1 | tail -3; done
```
Expected: five runs, each reporting `0 failures`.

- [ ] **Step 5: Commit**

```bash
git rev-parse --abbrev-ref HEAD
git add ElliotKit/Sources/ElliotAppKit/CardView.swift ElliotKit/Tests/ElliotAppKitTests/AutoDevCardMarkTests.swift
git commit -m "feat(app): mark the cards an auto-dev session has engaged"
```

---

### Task 8: The on-screen pass

**Files:**
- Temporarily modify then revert: `ElliotKit/Sources/ElliotAppKit/AppModel.swift` (a seed inside `start()`)
- Nothing committed by this task except, if the look finds a defect, the fix.

**Interfaces:**
- Consumes: everything above.
- Produces: nothing in code. It produces the one claim `swift test` cannot make.

**Why this task exists.** `swift test` cannot see layout, and this project has lost three merges to a change that was green on the whole suite and destroyed the window (#47 → #50 → #52 → #53). A change that moves anything on screen is not finished until someone has looked at it. This task moves five things: a new band in Operations, a new figure in a status bar that has been shoved around by its own contents before, a new glyph in every card's title row, a stepper, and a refusal sentence.

**⚠️ What `board_screenshot` can and cannot cover here.**
- It renders **Elliot's own window hierarchy**, so the board, its columns, the cards and the **status bar** are all real — the figure and the card mark are checkable this way.
- It renders the **toolbar blank**: SwiftUI hosts `.toolbar` in titlebar accessory views the frame-view render never reaches. Nothing this plan adds is in the toolbar, which is deliberate, so this blind spot costs nothing here — but do not read a blank toolbar as a regression.
- It **cannot open a window**. `AppKitWindowCapture.isOpen` is `isVisible || isMiniaturized`, and Operations opens only from the View menu or from clicking the status-bar figure. So **the band itself needs a person**, or a person's click, before any capture of it is possible. Plan for that rather than discover it.
- An agent's shell holds neither Accessibility nor Screen Recording on this machine (measured twice, #132 and #162): `osascript … click`, `press_key`, window-position reads and `screencapture` all fail. Do not plan a pass around them.

- [ ] **Step 1: Build the bundle and prepare an isolated store**

SwiftPM emits no bundle, and the app must be launched from the Finder — `PATH` is captured from a login shell, not inherited, and a terminal launch hides that.

```bash
cd /Users/phmatray/Repositories/phmatray/private/Elliot/.claude/worktrees/precious-beaming-wand
rm -rf /tmp/elliot-check && mkdir -p /tmp/elliot-check
mkdir -p /tmp/sandbox && git -C /tmp/sandbox init -q
./Scripts/build-app.sh
open -n --env ELLIOT_HOME=/tmp/elliot-check dist/Elliot.app
```

⚠️ Keep the home short — `/tmp/elliot-check` is short **on purpose**. `sun_path` is capped at 104 bytes on macOS, so a scratch home under a deep path makes `startIPC` fail silently; Preflight says so under *MCP socket*.

Let the app finish starting (the status bar reads `Ready.`), then quit it. The store now exists with every migration run, which is what the next step writes into.

- [ ] **Step 2: Seed the scratch store**

⛔ **The ids are `UUID`s.** Insert `'sandbox'` as a repo id and the app starts, paints its chrome, and sits on **"Still starting"** for ever while the status bar underneath reads **"Ready."** — the repo observation's `catch` swallows the decode error with no banner. `uuidgen` emits uppercase, which is what `Records.swift` stores (`databaseUUIDEncodingStrategy` is `.uppercaseString`).

```bash
export ELLIOT_HOME=/tmp/elliot-check
RID=$(uuidgen); C1=$(uuidgen); C2=$(uuidgen); C3=$(uuidgen); C4=$(uuidgen)
NOW='2026-08-08 10:00:00.000'

sqlite3 "$ELLIOT_HOME/elliot.sqlite" "
INSERT INTO repo (id,path,nameWithOwner,defaultBranch,displayName,permissionMode,extraAllowedTools,isEnabled,visibility)
VALUES ('$RID','/tmp/sandbox','phmatray/sandbox','main','sandbox','bypassPermissions','[]',1,NULL);

INSERT INTO card (id,repoID,title,body,story,\"column\",orderIndex,issueNumber,issueURL,prNumber,prURL,branch,columnEnteredAt,lastError,createdAt,updatedAt,idempotencyKey,angle)
VALUES ('$C1','$RID','A card auto-dev is driving','',NULL,'backlog',1,NULL,NULL,NULL,NULL,NULL,'$NOW',NULL,'$NOW','$NOW',NULL,NULL);

INSERT INTO card (id,repoID,title,body,story,\"column\",orderIndex,issueNumber,issueURL,prNumber,prURL,branch,columnEnteredAt,lastError,createdAt,updatedAt,idempotencyKey,angle)
VALUES ('$C2','$RID','A second engaged card with a long enough title to wrap onto two lines','',NULL,'backlog',2,NULL,NULL,NULL,NULL,NULL,'$NOW',NULL,'$NOW','$NOW',NULL,'bugs');

INSERT INTO card (id,repoID,title,body,story,\"column\",orderIndex,issueNumber,issueURL,prNumber,prURL,branch,columnEnteredAt,lastError,createdAt,updatedAt,idempotencyKey,angle)
VALUES ('$C3','$RID','A merge that failed','',NULL,'done',3,41,'https://example.invalid/41',42,'https://example.invalid/42','42-x','$NOW','Not merged — the pull request was not merged.','$NOW','$NOW',NULL,NULL);

INSERT INTO card (id,repoID,title,body,story,\"column\",orderIndex,issueNumber,issueURL,prNumber,prURL,branch,columnEnteredAt,lastError,createdAt,updatedAt,idempotencyKey,angle)
VALUES ('$C4','$RID','A card nobody engaged','',NULL,'backlog',4,NULL,NULL,NULL,NULL,NULL,'$NOW',NULL,'$NOW','$NOW',NULL,NULL);
"
sqlite3 "$ELLIOT_HOME/elliot.sqlite" "PRAGMA wal_checkpoint(TRUNCATE);"
echo "repo=$RID cards=$C1 $C2 $C3 $C4"
```

`/tmp/sandbox` is a throwaway `git init`, never one of Philippe's checkouts: the cards then render *"Repository blocked — see Preflight"*, which is the state a look-only pass wants — no transition can spawn an agent from it. **To Do** and **In Progress** are left empty so the arrows-skip-empty-columns rule is exercised. `C3` is in Done with a `lastError`: it is the card `Column.naturalNext` drops from Up next, and the whole reason the band is permanent.

- [ ] **Step 3: Seed a session with a temporary patch, and write down that it must come out**

There is no seam for this and there must not be one: the loop lands in PR4, and a shipped hook that seeds a fake session is a second way to make the board claim something nobody measured. So it goes in, gets looked at, and comes back out in Step 6 — which is why Step 6 proves the removal rather than trusting it.

⚠️ If you would rather not touch `AppModel.swift` at all, Step 5's second route seeds nothing in production code: it hosts the view directly and renders it. Read Step 5 before starting here, and pick one.

Insert into `ElliotKit/Sources/ElliotAppKit/AppModel.swift`, in `start()`, immediately after `isReady = true` (`:574`) and before the `status = summary == .init()` line under it (`:575`):

```swift
            // ⚠️ TEMPORARY — PR5's on-screen pass only. `git checkout` this file
            // before committing. There is deliberately no seam for it: PR4
            // brings the driver, and a shipped hook that seeds a fake session
            // is a way for the board to claim something nobody measured.
            let seededCards = cards.prefix(3).map(\.id)
                + (0..<max(0, 3 - cards.count)).map { _ in UUID() }
            let seededSession = AutoDevSession(
                repoID: repos.first?.id ?? UUID(), engagedCardIDs: Array(seededCards),
                maxAttemptsPerCard: 3, patience: 900, startedAt: .now, state: .running)
            let seededDispositions: [AutoDevDisposition] = [.engaged, .merged, .blocked]
            let seededReasons = [
                "Waiting for the pull request to open.",
                "gh says PR 42 was merged.",
                "No build has judged the pull request.",
            ]
            testOnlySeedAutoDev(
                seededSession,
                engagements: seededCards.enumerated().map { index, cardID in
                    AutoDevEngagement(
                        sessionID: seededSession.id, cardID: cardID, attempts: index + 1,
                        disposition: seededDispositions[index], reason: seededReasons[index],
                        updatedAt: .now)
                })
```

⚠️ **This seed reads `repos` and `cards`, and `start()` never waits for either.** They are filled by
`observe(store:)`, which is hoisted above the login-shell capture (`:489`) precisely so the board
stops claiming "No repository yet" during startup — so by `isReady = true`, after three tool
lookups, a reconciler sweep and a PR watcher, they are populated in practice but not by
construction. If the headline reads *"…in no repository"* or no card carries a mark, that is what
happened: quit and relaunch against the same warm store rather than reading it as a defect in
Tasks 5–7.

Then rebuild and relaunch:

```bash
./Scripts/build-app.sh
open -n --env ELLIOT_HOME=/tmp/elliot-check dist/Elliot.app
```

- [ ] **Step 4: Look at the board**

⛔ **Not through the accessibility tree, if you are an agent.** The warning block above says an
agent's shell holds neither grant, and that is exactly what this step would otherwise use: measured
twice (#132, #162), `osascript … entire contents` answers `-1719 osascript is not allowed assistive
access` and `screencapture -x` answers `could not create image from display`. Neither says "no
grant" in words, and an empty tree reads as an empty window. `board_screenshot` is the one route
that needs no grant, because Elliot renders its own hierarchy in-process. A person sitting at the
machine may read the tree instead; an agent plans without it.

`board_screenshot window=board` needs a helper pointed at **this** home — the registered helper
talks to the everyday board, and it fails by returning a perfectly good screenshot of the wrong app.
Spawn one yourself and speak JSON-RPC at its stdin, one JSON object per line
(`initialize` → `notifications/initialized` → `tools/call`):

```bash
printf '%s\n' \
  '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"pr5-screen-check","version":"1"}}}' \
  '{"jsonrpc":"2.0","method":"notifications/initialized"}' \
  '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"board_screenshot","arguments":{"window":"board"}}}' \
  | ELLIOT_HOME=/tmp/elliot-check dist/Elliot.app/Contents/MacOS/elliot-mcp
```

The tool's name and its `window` argument are read from
`ElliotKit/Sources/ElliotMCPKit/Tools/ScreenshotTool.swift:21` and `:37`; `window` defaults to
`board`. ⚠️ The `protocolVersion` string is **not** measured — if `initialize` refuses it, read the
version its reply names and send that. The reply to the second call carries `png_path`: open that
file, which is the full-resolution copy under `/tmp/elliot-check/screenshots/`, rather than the
inline image, which is resampled to a byte budget.

Check, and write each answer into the pull request body:

1. The status bar carries **`2/3 auto-dev`** between `0/2 workers` and the day's spend. Its tooltip is the band's headline.
2. The bar is still **one line** at `Metric.statusBarHeight` (28 pt) and has not pushed the board upwards. This strip has grown and shoved the board before.
3. Cards `C1` and `C2` in Backlog carry the ⚡ mark **before** their title; `C2` shows the lens emoji **and** the mark, in that order, and its two-line title sits under itself rather than under the glyphs.
4. `C4` carries **no** mark and **no** reserved gutter where one would be.
5. `C3` in Done carries the mark and its `lastError`.
6. The toolbar renders blank in the capture. That is `board_screenshot`, not a regression.

- [ ] **Step 5: Look at the Operations band**

⛔ **`board_screenshot` photographs an open window; it cannot open one.** `AppKitWindowCapture.isOpen` is `isVisible || isMiniaturized` (`ElliotKit/Sources/ElliotAppKit/AppKitWindowCapture.swift:155`), and Operations opens only from **View ▸ Operations** or from clicking the `2/3 auto-dev` figure — a click, which an agent has no grant to post. Two routes, and take whichever you have:

- **With a person at the machine:** ask for the menu item, or better, ask for a click on the `2/3 auto-dev` figure — that click is also the check that the figure is a door. Then `board_screenshot window=operations` works.
- **Without one:** host the view yourself and render it, which is what PR #211 did for the Repositories page when that session held neither grant either (its body records the whole run). Put `OperationsView()` in an `NSHostingView` inside a **720×780** `NSWindow` — the scene's own `.defaultSize` (`ElliotKit/Sources/ElliotApp/ElliotApp.swift:109`), so check 4's width claim still means something — give it a real `AppModel` seeded through `testOnlySeed(repos:cards:)` and `testOnlySeedAutoDev(_:engagements:)`, and render *that* window with `AppKitWindowCapture.render(window:maxInlineBytes:)` (`AppKitWindowCapture.swift:250`). No patch to `AppModel.start()` at all on this route, so Step 3 and Step 6 fall away with it. `cacheDisplay` needs no grant and no window on screen; #211 got 1800×1464 at 2× this way. ⚠️ `render` is **internal** to `ElliotAppKit`, so the caller has to be a `@testable` context — a scratch test file, deleted afterwards.

Either way, check:

1. The band's title is **AUTO-DEV**, and it sits **between Spending and Up next** with nothing in between.
2. Its headline reads *"Driving 3 cards in sandbox — 2 settled, 1 to go."* in `Palette.armed`.
3. The caption underneath names **Up next** and says it is **not a ranking**.
4. The run note says Pause lets the run already going finish and Stop cancels it — and it is legible, not truncated, at the window's default 720 pt width.
5. **Pause** and **Stop and cancel** are both present; hovering each shows its own sentence.
6. Three engagement rows, in the session's order: a bolt in armed, a seal in verified, a cross in refused, each with its reason and an attempt count on the right.
7. The Start row shows a stepper reading **3 cards**, a **disabled** *Start auto-dev*, and beside it *"Auto-dev is not wired into this build yet."* in the refusal accent. **That sentence is correct for this build** — PR4 brings the driver.
8. Press **Stop and cancel**. With no driver attached nothing happens, which is the same guard. Note it and move on: the state transitions are covered by `AutoDevStateTests`, and the thing being looked at here is layout.
9. Resize the window narrow (~520 pt) and confirm the run note and the caption wrap rather than clipping, and that the controls stay on the row.

- [ ] **Step 6: Revert the temporary patch and prove it is gone**

```bash
cd /Users/phmatray/Repositories/phmatray/private/Elliot/.claude/worktrees/precious-beaming-wand
git checkout -- ElliotKit/Sources/ElliotAppKit/AppModel.swift
git status --porcelain
grep -n "TEMPORARY" ElliotKit/Sources/ElliotAppKit/AppModel.swift
```
Expected: `git status --porcelain` prints nothing, and `grep` prints nothing and exits 1.

Then rebuild the bundle from the reverted source and confirm the band still draws its idle state, so what ships is what was looked at:

```bash
rm -rf /tmp/elliot-check && mkdir -p /tmp/elliot-check
./Scripts/build-app.sh
open -n --env ELLIOT_HOME=/tmp/elliot-check dist/Elliot.app
```
Expected on screen: no `auto-dev` figure in the status bar (no session has run), no mark on any card, and the Operations band present with *"Elliot is not driving anything by itself."*, *"Nothing is running."* and the disabled Start row. **The band being there with no session is the permanence claim** — a conditional band would be missing entirely here, and that is the state a failed session would also render as.

- [ ] **Step 7: Sample the suite and commit nothing, or commit the fix**

```bash
cd ElliotKit && rm -rf .build && swift build
for i in 1 2 3 4 5; do swift test 2>&1 | tail -3; done
```
Expected: five runs, `0 failures` each.

If the look found nothing, this task commits nothing — record the seven checks and their answers in the pull request body. If it found a defect, fix it, re-run the suite, and:

```bash
git rev-parse --abbrev-ref HEAD
git add <the exact files you changed>
git commit -m "fix(app): <what the on-screen pass found>"
```
