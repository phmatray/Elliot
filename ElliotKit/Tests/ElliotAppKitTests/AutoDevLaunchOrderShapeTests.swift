import Foundation
import Testing

@testable import ElliotAppKit

/// The launch order `AppModel.start()` promises: the auto-dev round trigger,
/// its session probe, and the driver's own attachment are wired only after
/// `Reconciler.sweep()` has returned — never beside them, and never before.
///
/// `swift test` cannot see this behaviourally. `start()` opens the real
/// store, captures a login shell and runs three tool lookups before any of
/// this runs, so nothing in this target can drive it end to end; and even a
/// harness that could would prove one interleaving of a scheduler and a PR
/// watcher racing an actor, not the *rule* that the registration always sits
/// on one side of the sweep. `RunSchedulerShapeTests` (`ElliotEngineTests`)
/// is the idiom for exactly this shape of claim over engine code; this reads
/// `AppModel.swift` the same way, through `HiddenFaceState`
/// (`AutoDevStateTests.adoptIsTheOnlyWriter` already reaches for it once in
/// this target) — new gates reach for the shared reader rather than growing
/// a third copy of the walk.
///
/// ⚠️ **What this does not catch.** This is a check of *textual* order in the
/// source, not of *execution* order. A refactor that left every line exactly
/// where it is but wrapped the trigger registration in a `Task { ... }` that
/// is never awaited — so it could race ahead of, or run concurrently with,
/// the code that follows it in the file — would leave every assertion below
/// green while reopening the exact hazard the ordering exists to close: a
/// round reading an orphan still marked `.running` before the sweep has
/// reconciled it. The guarantee this pins is narrower and still real: as
/// long as `reconciler.sweep()` and the registration calls are each `await`ed
/// synchronously in `start()`'s own body — which is how every `await` in this
/// method already reads — textual order **is** execution order, and that is
/// the shape the registration site's own comment argues for.
@Suite("AppModel — the launch order (source shape)")
struct AutoDevLaunchOrderShapeTests {

    /// The body of `public func start() async { ... }`, found by
    /// `HiddenFaceState.body(of:in:)`'s brace walk from the comment-stripped
    /// source — the same reader `AutoDevStateTests.adoptIsTheOnlyWriter`
    /// already uses on this file.
    ///
    /// ⚠️ **The signature passed must not include the trailing `{`.**
    /// `body(of:in:)` starts walking at `signature`'s own end and returns as
    /// soon as depth returns to zero, so it expects the **first** brace it
    /// meets to be the function's own opening one. Measured directly: passing
    /// `"public func start() async {"` (the shape `RunSchedulerShapeTests`'
    /// own hand-rolled walk uses, which is a different algorithm) made this
    /// helper treat `start()`'s first `guard store == nil else { return }` as
    /// the whole function and return `" return "` — eight characters, not the
    /// ~200-line body. `AutoDevStateTests.adoptIsTheOnlyWriter`'s own call,
    /// `body(of: "private func adopt(", in: code)`, is the working precedent:
    /// it stops short of `adopt`'s own `{` for the same reason.
    private func startBody() throws -> String {
        let code = try HiddenFaceState.code(of: "AppModel.swift")
        return try HiddenFaceState.body(of: "public func start() async", in: code)
    }

    @Test("The scheduler's round trigger is registered only after the launch sweep returns")
    func schedulerTriggerRegistersAfterTheSweep() throws {
        let body = try startBody()
        #expect(!body.isEmpty, "start() not found — this test's parser needs updating, not deleting")

        let sweep = body.range(of: "await reconciler.sweep()")
        let trigger = body.range(of: "scheduler.setRoundTrigger(autoDevService)")
        #expect(
            sweep != nil,
            "start() no longer sweeps with the reconciler — has it moved, or been renamed?")
        #expect(
            trigger != nil,
            """
            start() no longer registers the scheduler's round trigger on the auto-dev service — \
            the wiring this task added is gone
            """)
        guard let sweep, let trigger else { return }
        #expect(
            sweep.upperBound < trigger.lowerBound,
            """
            `scheduler.setRoundTrigger(autoDevService)` sits before, or beside rather than after, \
            `reconciler.sweep()`. `Reconciler.sweep()` re-launches runs that only got as far as \
            `.queued` and re-derives what every run that died with the app actually managed to do; \
            a round triggered before it returns can read an orphan still marked `.running`, answer \
            `runAlreadyInFlight`, and wait for an event the sweep itself would have produced — but \
            has not reached that run yet.
            """
        )
    }

    @Test("The PR watcher's round trigger and session probe are registered only after the launch sweep")
    func watcherTriggerAndProbeRegisterAfterTheSweep() throws {
        let body = try startBody()
        #expect(!body.isEmpty, "start() not found — this test's parser needs updating, not deleting")

        let sweep = body.range(of: "await reconciler.sweep()")
        let watcherTrigger = body.range(of: "watcher.setRoundTrigger(autoDevService)")
        let watcherProbe = body.range(of: "watcher.setSessionProbe")
        #expect(
            sweep != nil,
            "start() no longer sweeps with the reconciler — has it moved, or been renamed?")
        #expect(
            watcherTrigger != nil,
            "start() no longer registers the PR watcher's round trigger on the auto-dev service")
        #expect(watcherProbe != nil, "start() no longer gives the PR watcher a session probe")
        guard let sweep, let watcherTrigger, let watcherProbe else { return }
        #expect(
            sweep.upperBound < watcherTrigger.lowerBound,
            """
            the PR watcher's round trigger is registered before the launch sweep returns — a round \
            it triggers can read an orphan the sweep has not reconciled yet
            """
        )
        #expect(
            sweep.upperBound < watcherProbe.lowerBound,
            "the PR watcher's session probe is registered before the launch sweep returns"
        )
    }

    /// The one place the wiring is deliberately split across the sweep: the
    /// actor itself costs nothing to build and needs nothing the sweep
    /// produces, so it is constructed early, beside `analysisService` — but
    /// it must not become *reachable* through `autoDevDriver` (which
    /// `autoDevRefusal` and every one of the three session commands consult)
    /// until the same instant the triggers are registered.
    @Test("The driver is built beside the other services, but attached to the model only after the sweep")
    func driverAttachesAfterTheSweepEvenThoughItIsBuiltEarlier() throws {
        let body = try startBody()
        #expect(!body.isEmpty, "start() not found — this test's parser needs updating, not deleting")

        let sweep = body.range(of: "await reconciler.sweep()")
        let construction = body.range(of: "let autoDevService = AutoDevService(")
        let attach = body.range(of: "self.autoDevDriver = autoDevService")
        #expect(
            sweep != nil,
            "start() no longer sweeps with the reconciler — has it moved, or been renamed?")
        #expect(
            construction != nil,
            "start() no longer builds an AutoDevService — this task's wiring is gone")
        #expect(
            attach != nil,
            """
            start() no longer attaches the auto-dev service to autoDevDriver — every control would \
            read "Auto-dev is not wired into this build yet." for the life of the launch
            """)
        guard let sweep, let construction, let attach else { return }
        #expect(
            construction.upperBound < sweep.lowerBound,
            """
            AutoDevService is now constructed after the sweep — harmless, but it was deliberately \
            built early (beside analysisService) since it costs nothing and needs nothing the sweep \
            produces; if that changed on purpose, this assertion should move with it
            """
        )
        #expect(
            sweep.upperBound < attach.lowerBound,
            """
            `autoDevDriver` is assigned before the launch sweep returns. `autoDevRefusal` and every \
            one of `startAutoDev`/`pauseAutoDev`/`resumeAutoDev`/`stopAutoDev` read `autoDevDriver` \
            to decide whether they may act at all — attaching it before the sweep would let one of \
            those race the sweep, reaching the same `runAlreadyInFlight` hazard the trigger \
            registration above exists to avoid.
            """
        )
    }
}
