import Foundation
import Testing

/// The race tests in `SchedulerConcurrentPumpTests` prove the symptom is gone
/// in the interleavings they happened to hit. They cannot prove the *rule*,
/// because whether two pumps overlap is a scheduling outcome. This one can: it
/// reads the source, the way `DrainDuplicationTests` does, and fails naming the
/// invariant that was moved.
///
/// It also carries the whole of AC 1 on its own. `pump` no longer assigning
/// `pending` is what prevents the silent drop, and no behavioural test in this
/// suite reproduces that drop — healing it needs a pump with a stale snapshot to
/// finish last, which none of the fixtures can force without a timing hook the
/// repo's testing rules forbid.
@Suite("RunScheduler — the shape the race tests cannot see")
struct RunSchedulerShapeTests {

    private static let source: String = {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // ElliotEngineTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // ElliotKit
            .appendingPathComponent("Sources/ElliotEngine/RunScheduler.swift")
        return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }()

    /// The source with `//` line comments removed, so these tests measure code
    /// and not prose.
    ///
    /// Not a refinement — without it two of the three tests below fail on the
    /// very comments that document them. `pump`'s comment quotes the line it
    /// warns against (`pending = stillPending`) so `pumpDoesNotRebuildTheQueue`
    /// would read its own explanation as the defect; `start`'s comment argues
    /// about where the `await`s are, which is what `theClaimSitsAboveTheFirstAwait`
    /// searches for. A source-shape test that a comment can turn red teaches
    /// everyone to delete the comment.
    private static let code: String = {
        source
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> String in
                guard let marker = line.range(of: "//") else { return String(line) }
                return String(line[..<marker.lowerBound])
            }
            .joined(separator: "\n")
    }()

    /// The body of `private func start(_ run: SkillRun) async {` up to the next
    /// declaration at the same indentation.
    private func startBody() -> String {
        let code = Self.code
        guard let begin = code.range(of: "private func start(_ run: SkillRun) async {") else {
            return ""
        }
        let rest = code[begin.upperBound...]
        guard let end = rest.range(of: "\n    private func ") ?? rest.range(of: "\n    static func ")
        else { return String(rest) }
        return String(rest[..<end.lowerBound])
    }

    @Test("start claims the run in inFlight before its first await")
    func theClaimSitsAboveTheFirstAwait() {
        let body = startBody()
        #expect(!body.isEmpty, "start(_:) not found — this test's parser needs updating, not deleting")

        let claim = body.range(of: "inFlight[run.id] =")
        let firstAwait = body.range(of: "await ")
        #expect(claim != nil, "start no longer writes inFlight — the double-spawn guard is gone")
        guard let claim, let firstAwait else { return }
        #expect(
            claim.lowerBound < firstAwait.lowerBound,
            """
            `start` suspends before it claims the run in `inFlight`. Two pumps can \
            then both admit the same id and both spawn a `claude` for it. The guard \
            and the assignment must stay adjacent and above every `await`.
            """
        )
    }

    @Test("start refuses a run already in flight")
    func theClaimIsGuarded() {
        #expect(
            startBody().contains("guard inFlight[run.id] == nil else { return }"),
            "start no longer refuses a run that is already in flight — a second pump can re-enter it"
        )
    }

    /// The body of `private func pump() async {` up to the next declaration.
    ///
    /// Stops at `mergeAdmission`, not `queueSnapshot` — Task 7 inserted
    /// `mergeAdmission` between the two, and the older boundary would silently
    /// fold its body into what these tests call "pump's body", which is not
    /// what any of them mean to measure.
    private func pumpBody() -> String {
        let code = Self.code
        guard let begin = code.range(of: "private func pump() async {"),
              let end = code.range(of: "\n    private func mergeAdmission(")
        else { return "" }
        return String(code[begin.upperBound..<end.lowerBound])
    }

    /// A containment check *before* the read is a shortcut; the one that carries
    /// the invariant has to sit after it. `drain` and `cancel` both take their id
    /// out of `pending` synchronously and only then suspend to mark the row
    /// `.cancelled`, so a pump whose read landed in that window resumes holding a
    /// stale `.queued` value.
    ///
    /// This is the deterministic half, for the same reason Task 5 exists at all:
    /// the behavioural evidence destroys itself. If the defect fires, `start`
    /// saves `.running` over the `.cancelled` row, so the very state a test would
    /// assert on is gone by the time it could look.
    @Test("pump re-checks the queue after the read that suspends it")
    func pumpRechecksContainmentAfterTheRead() {
        let body = pumpBody()
        #expect(!body.isEmpty, "pump() not found — this test's parser needs updating, not deleting")
        guard let read = body.range(of: "await store.run(") else {
            Issue.record("pump no longer reads the run — parser needs updating, not deleting")
            return
        }
        #expect(
            body[read.upperBound...].contains("pending.contains(runID)"),
            """
            `pump` decides on a run without re-checking that it is still in the \
            queue after the read that suspended it. `drain` and `cancel` remove \
            their id from `pending` and only then suspend to mark the row \
            `.cancelled`, so this pump can be holding a stale `.queued` value — \
            starting it spawns a `claude` for a run the user just discarded, and \
            `start` then writes `.running` over the `.cancelled` row so the \
            cancellation disappears too. For `merge-pr` that is a merge to `main` \
            after being told to stop.
            """
        )
    }

    /// Task 7 added a second suspension of its own: `mergeAdmission` awaits a
    /// card read and a `prStatus` read, for exactly the run kind this whole
    /// guard exists for. That is one `await` later than the window
    /// `pumpRechecksContainmentAfterTheRead` covers, and it needs its own
    /// recheck for the identical reason — a review of `3d22861` found the gap
    /// empirically (a cancelled, demanding merge still ran to `.succeeded`)
    /// before it was closed here.
    ///
    /// Deterministic for the same reason its sibling above is: a behavioural
    /// reproduction was attempted first — real `GRDB` suspensions, `launch`
    /// and `cancel` raced concurrently via `withTaskGroup`, up to 500
    /// sequential and 100×11 concurrent iterations with bounded `Task.yield()`
    /// delays sweeping the gap between the two calls — and none of it landed
    /// the interleaving reliably enough to trust as a regression guard. See
    /// `task-7-report.md` §4 for the full account. This is the one that can
    /// prove the rule instead.
    @Test("pump re-checks the queue again after mergeAdmission's own suspension")
    func pumpRechecksContainmentAfterMergeAdmissionToo() {
        let body = pumpBody()
        #expect(!body.isEmpty, "pump() not found — this test's parser needs updating, not deleting")
        guard let admission = body.range(of: "await mergeAdmission(") else {
            Issue.record(
                "pump no longer computes a merge admission — parser needs updating, not deleting")
            return
        }
        #expect(
            body[admission.upperBound...].contains("pending.contains(runID)"),
            """
            `pump` decides on a run without re-checking that it is still in the \
            queue after `mergeAdmission`'s own suspension. `mergeAdmission` \
            awaits a card read and a `prStatus` read for exactly the run kind \
            this guard exists for, so `drain`/`cancel` can land their \
            synchronous `pending.removeAll` in *this* window too — one `await` \
            later than the window the recheck above already covers. Starting \
            the run anyway spawns a `claude` for one the user just discarded, \
            and `start` then writes `.running` over the `.cancelled` row so the \
            cancellation disappears too. For `merge-pr` that is a merge to \
            `main` after being told to stop.
            """
        )
    }

    /// The obvious symptom of this ordering — a double spawn — is masked by
    /// `start`'s own `inFlight` claim (`theClaimSitsAboveTheFirstAwait`
    /// above), so a behavioural test of *that* symptom stays green even with
    /// this ordering inverted. What breaking it actually opens is the same
    /// class of window `pumpRechecksContainmentAfterMergeAdmissionToo` closes:
    /// a `cancel` landing while `start` is still suspended can write
    /// `.cancelled`, and `start`'s own later `.running` save — captured before
    /// any of this began, never re-read — overwrites it. Source-shape is the
    /// only thing that can pin the ordering itself rather than one symptom of
    /// breaking it.
    @Test("pump removes an admitted run from pending before start suspends")
    func pumpRemovesFromPendingBeforeStart() {
        let body = pumpBody()
        #expect(!body.isEmpty, "pump() not found — this test's parser needs updating, not deleting")
        guard let start = body.range(of: "await start(run)") else {
            Issue.record("pump no longer starts a run directly — parser needs updating, not deleting")
            return
        }
        guard
            let admitBranch = body.range(
                of: "} else {", options: .backwards, range: body.startIndex..<start.lowerBound)
        else {
            Issue.record("pump's admit branch has no else clause — parser needs updating, not deleting")
            return
        }
        #expect(
            body[admitBranch.upperBound..<start.lowerBound].contains("pending.removeAll { $0 == runID }"),
            """
            `pump` starts a run before removing it from `pending`. A concurrent \
            `cancel` landing while `start` is still suspended takes the \
            "already pending" branch (`discardQueued`, unconditional) and \
            writes `.cancelled` — and `start`'s own `.running` save, still in \
            flight, can land after it and overwrite the cancellation with no \
            re-read and no compare-and-swap. For `merge-pr` that is a merge to \
            `main` after being told to stop.
            """
        )
    }

    @Test("pump does not assign the whole pending array")
    func pumpDoesNotRebuildTheQueue() {
        let body = pumpBody()
        #expect(!body.isEmpty, "pump() not found — this test's parser needs updating, not deleting")
        #expect(
            !body.contains("pending ="),
            """
            `pump` assigns `pending` wholesale again. Every `await` in it releases \
            the actor, so the array it writes back is a view from before the \
            suspension: a run `launch` appended is dropped, and a run `drain` \
            cancelled comes back. Remove by identity instead.
            """
        )
    }

    /// `pumpDoesNotRebuildTheQueue` only greps for `"pending ="`, so a
    /// wholesale rebuild of `lastRefusals` alone — leaving `pending` itself
    /// edited correctly — passes it clean. The consequence is milder than a
    /// double-spawn or a revived cancellation (a stale or missing queue-display
    /// entry, not a wrongly-started merge), but it is the same class of gap:
    /// `launch` can append a run and record nothing for it while this pump is
    /// suspended, and a wholesale `lastRefusals = …` after the loop would
    /// discard that entry rather than leave it be.
    ///
    /// Scoped to the loop's own body, deliberately: the line just past the
    /// loop, `lastRefusals = lastRefusals.filter { pending.contains($0.key) }`,
    /// is a *legitimate* wholesale reassignment — it exists to drop stale
    /// entries for runs no longer pending, and is the one place this
    /// substring is supposed to appear. Searching all of `pumpBody()` would
    /// make that line indistinguishable from the defect.
    @Test("pump edits lastRefusals incrementally inside the loop, never wholesale")
    func pumpEditsRefusalsIncrementally() {
        let body = pumpBody()
        #expect(!body.isEmpty, "pump() not found — this test's parser needs updating, not deleting")
        guard let loopBegin = body.range(of: "for runID in pending {") else {
            Issue.record("pump's loop not found — parser needs updating, not deleting")
            return
        }
        guard
            let loopEnd = body.range(
                of: "\n        lastRefusals = lastRefusals.filter",
                range: loopBegin.upperBound..<body.endIndex)
        else {
            Issue.record(
                "the line after pump's loop was not found — parser needs updating, not deleting")
            return
        }
        let loop = body[loopBegin.upperBound..<loopEnd.lowerBound]
        #expect(
            !loop.contains("lastRefusals = "),
            """
            `pump`'s loop reassigns `lastRefusals` wholesale instead of editing \
            it by key. Every `await` inside the loop releases the actor, so a \
            wholesale reassignment here would be a view from before the \
            suspension — discarding the refusal `launch` recorded for a run \
            appended while this pump was reading the store.
            """
        )
    }

    /// The body of `private func finish(run: SkillRun, outcome: AgentRunOutcome?) async {`
    /// up to the next declaration at the same indentation.
    private func finishBody() -> String {
        let code = Self.code
        guard
            let begin = code.range(
                of: "private func finish(run: SkillRun, outcome: AgentRunOutcome?) async {")
        else { return "" }
        let rest = code[begin.upperBound...]
        guard let end = rest.range(of: "\n    private func ") ?? rest.range(of: "\n    static func ")
        else { return String(rest) }
        return String(rest[..<end.lowerBound])
    }

    /// The body of `private func discardQueued(_ runID: UUID) async -> Bool {`
    /// up to the next declaration.
    private func discardQueuedBody() -> String {
        let code = Self.code
        guard let begin = code.range(of: "private func discardQueued(_ runID: UUID) async -> Bool {")
        else { return "" }
        let rest = code[begin.upperBound...]
        guard let end = rest.range(of: "\n    public func promote(") else { return String(rest) }
        return String(rest[..<end.lowerBound])
    }

    /// `RoundTriggeringTests` (`AutoDevServiceTests.swift`) proves the trigger
    /// fires from `finish`. It cannot prove *where* — a behavioural test that
    /// never exercises the ordering stays green whichever side of `pump()` the
    /// call sits on, which is exactly what fix round 1 found: moving the call
    /// above `pump()` reddened nothing in the whole suite. The design's entire
    /// stated reason for this task (see `RoundTriggering.swift`'s doc comment
    /// and the plan's own note) is that a round triggered from here must never
    /// observe a queue that has not yet reconsidered itself under the run that
    /// just finished — which only holds if `pump()` has already returned.
    /// Source-shape is the only thing that can pin the ordering itself, the
    /// same reasoning `pumpRemovesFromPendingBeforeStart` above gives for its
    /// own ordering claim.
    @Test("finish tells the round trigger only after pump() has drained the queue")
    func finishTriggersARoundAfterPumpNotBefore() {
        let body = finishBody()
        #expect(
            !body.isEmpty,
            "finish(run:outcome:) not found — this test's parser needs updating, not deleting")
        let pump = body.range(of: "await pump()")
        let trigger = body.range(of: "await roundTrigger?.triggerRound()")
        #expect(pump != nil, "finish no longer calls pump() — the queue would never re-drain")
        #expect(trigger != nil, "finish no longer tells the round trigger — Task 9's whole point")
        guard let pump, let trigger else { return }
        #expect(
            pump.lowerBound < trigger.lowerBound,
            """
            `finish` tells the round trigger before calling `pump()`, or the \
            call moved out of `finish` entirely. A round triggered before \
            `pump()` has drained the queue can observe pending runs that have \
            not yet been reconsidered under the occupancy this run's ending \
            just freed — the exact half-finished state the placement was \
            chosen to avoid.
            """
        )
    }

    /// `discardQueued` is the reader cancelling a queued run, not a run ending
    /// on its own — cancellation is a later task's subject, and the override
    /// that shaped this task said so explicitly. Nothing behavioural pins the
    /// omission: fix round 1 found that adding a trigger call here passes the
    /// full 2 692-test suite unchanged, which is exactly "one refactor from
    /// being reversed silently." The comment left at the call site is the
    /// only thing standing between that and a silent reversal; this is the
    /// gate that makes the comment enforceable.
    @Test("discardQueued never tells the round trigger")
    func discardQueuedDoesNotTriggerARound() {
        let body = discardQueuedBody()
        #expect(
            !body.isEmpty,
            "discardQueued(_:) not found — this test's parser needs updating, not deleting")
        #expect(
            !body.contains("triggerRound"),
            """
            `discardQueued` now calls the round trigger. That reverses a \
            deliberate omission: this is the reader cancelling a *queued* run \
            before it ever started, not a run ending on its own, and \
            cancellation is a later task's subject (see the comment at the \
            call site in `RunScheduler.swift`). If cancellation now needs to \
            trigger a round too, that is a decision for the task that owns \
            cancellation to make and pin — not something to fall out of this \
            file going untested.
            """
        )
    }
}
