import Foundation
import Testing

@testable import ElliotModel

private let epoch = Date(timeIntervalSince1970: 1_700_000_000)

private func run(_ state: RunState, id: UUID = UUID()) -> SkillRun {
    var run = SkillRun(
        cardID: UUID(), repoID: UUID(), kind: .mergePR,
        prompt: "/ai-migration-kit:merge-pr 279", cwd: "/tmp",
        logPath: "/tmp/run.ndjson", stderrPath: "/tmp/run.log", createdAt: epoch
    )
    run.id = id
    run.state = state
    return run
}

@Suite("The silence mark, both ways")
struct RunSilenceStateTests {

    /// The two guards were hand-copied into two modules and only ever written in
    /// one direction; this walks **every** state against **every** direction, so
    /// a state added later has to be answered here rather than acquiring an
    /// answer by omission.
    @Test("Exactly one state takes each notice, and nothing else moves")
    func onlyOneStateTakesEachNotice() {
        for state in RunState.allCases {
            #expect(
                state.applying(.wentQuiet) == (state == .running ? .stalled : nil),
                Comment(rawValue: "\(state) answered the stall notice wrongly")
            )
            #expect(
                state.applying(.startedTalkingAgain) == (state == .stalled ? .running : nil),
                Comment(rawValue: "\(state) answered the resume notice wrongly")
            )
        }
    }

    @Test("A late notice never resurrects a run that has ended")
    func aLateNoticeNeverResurrects() {
        // The race the issue names: the run can finish between the watcher
        // noticing and the notice arriving. `.stalled` and `.running` are both
        // non-terminal, so a resurrected run is one the board says is still
        // going — and it holds its card against any further move.
        for finished in RunState.allCases where finished.isTerminal {
            for notice in RunSilence.allCases {
                #expect(
                    finished.applying(notice) == nil,
                    Comment(rawValue: "\(finished) was dragged out of a terminal state by \(notice)")
                )
            }
        }
        // ⛔ `.cancelling` is the sharp one and is *not* terminal, so the loop
        // above does not cover it. `RunScheduler.cancel` writes `.cancelling`
        // over whatever the run was, `.stalled` included — so the last byte a
        // stalled run emits on its way out must not drag it back to `.running`.
        #expect(RunState.cancelling.applying(.startedTalkingAgain) == nil)
        #expect(RunState.cancelling.applying(.wentQuiet) == nil)
    }

    @Test("The two directions are inverses on the states that take them")
    func theDirectionsAreInverses() {
        let stalled = RunState.running.applying(.wentQuiet)
        #expect(stalled == .stalled)
        #expect(stalled?.applying(.startedTalkingAgain) == .running)
        // And neither notice applies twice: the second is a no-op, which is what
        // makes a repeated notice harmless.
        #expect(RunState.stalled.applying(.wentQuiet) == nil)
        #expect(RunState.running.applying(.startedTalkingAgain) == nil)
    }

    @Test("A notice names one run, and the collection walk honours the name")
    func aNoticeNamesOneRun() {
        let target = run(.running)
        let bystander = run(.running)

        #expect(target.applying(.wentQuiet, ifID: target.id).state == .stalled)
        #expect(bystander.applying(.wentQuiet, ifID: target.id).state == .running)

        let quiet = run(.stalled, id: target.id)
        #expect(quiet.applying(.startedTalkingAgain, ifID: target.id).state == .running)
        #expect(quiet.applying(.startedTalkingAgain, ifID: UUID()).state == .stalled)
    }

    @Test("A run the notice does not move comes back byte for byte")
    func anUnmovedRunIsUnchanged() {
        // Not just its state: `applying` returns the run itself, so a refusal
        // cannot quietly rebuild a row and drop a field on the way through.
        let done = run(.succeeded)
        for notice in RunSilence.allCases {
            #expect(done.applying(notice, ifID: done.id) == done)
            #expect(done.applying(notice, ifID: UUID()) == done)
        }
    }
}

@Suite("The idle watch")
struct IdleWatchTests {

    private let window = Duration.seconds(20 * 60)

    /// Ticks the watch at `secondsAfter` epoch, returning what it announced.
    private func tick(_ watch: inout IdleWatch, at secondsAfter: TimeInterval) -> RunSilence? {
        watch.tick(now: epoch.addingTimeInterval(secondsAfter), idleTimeout: window)
    }

    private func output(_ watch: inout IdleWatch, at secondsAfter: TimeInterval) -> RunSilence? {
        watch.sawOutput(at: epoch.addingTimeInterval(secondsAfter))
    }

    @Test("Silence is announced once, on the tick that crosses the window")
    func silenceIsAnnouncedOnce() {
        var watch = IdleWatch(lastOutput: epoch)
        #expect(tick(&watch, at: 60) == nil)
        #expect(tick(&watch, at: 20 * 60) == nil, "the window has to be crossed, not reached")
        #expect(tick(&watch, at: 20 * 60 + 1) == .wentQuiet)
        // Every later tick says nothing. Without the latch the watchdog would
        // repeat "still quiet" at every poll for the whole of a merge-pr waiting
        // on CI.
        #expect(tick(&watch, at: 40 * 60) == nil)
        #expect(tick(&watch, at: 60 * 60) == nil)
    }

    @Test("Output ends an announced silence, once")
    func outputEndsAnAnnouncedSilence() {
        // The defect: this clearing happened and told nobody, so nothing
        // downstream could take the mark off the run.
        var watch = IdleWatch(lastOutput: epoch)
        #expect(tick(&watch, at: 21 * 60) == .wentQuiet)
        #expect(output(&watch, at: 22 * 60) == .startedTalkingAgain)
        // The byte after it is ordinary output, not a second recovery.
        #expect(output(&watch, at: 22 * 60 + 1) == nil)
    }

    @Test("Output while nobody was worried announces nothing")
    func quietOutputIsSilent() {
        var watch = IdleWatch(lastOutput: epoch)
        #expect(output(&watch, at: 1) == nil)
        #expect(tick(&watch, at: 60) == nil)
        #expect(output(&watch, at: 61) == nil)
        #expect(!watch.announced)
    }

    @Test("The notices strictly alternate across a whole run")
    func theNoticesAlternate() {
        // Scripted rather than sampled: a run that goes quiet, talks, goes quiet
        // again and talks again must produce exactly four notices in exactly
        // this order. Two of either in a row is a latch that stopped latching.
        var watch = IdleWatch(lastOutput: epoch)
        var announced: [RunSilence] = []
        for (minute, isOutput) in [
            (5.0, true), (30.0, false), (45.0, false), (46.0, true), (47.0, true),
            (80.0, false), (95.0, false), (96.0, true),
        ] {
            let notice = isOutput
                ? output(&watch, at: minute * 60)
                : tick(&watch, at: minute * 60)
            if let notice { announced.append(notice) }
        }
        #expect(announced == [
            .wentQuiet, .startedTalkingAgain, .wentQuiet, .startedTalkingAgain,
        ])
    }

    @Test("A sub-second window is not truncated to nothing")
    func aSubSecondWindowIsNotTruncated() {
        // ⚠️ `Duration.components.seconds` alone reads 20ms as **zero**, so
        // every tick would cross the window and a run would be announced stalled
        // the instant it started. Invisible at the shipped twenty minutes, and
        // the exact window a test of this loop has to use.
        var watch = IdleWatch(lastOutput: epoch)
        let window = Duration.milliseconds(20)
        #expect(watch.tick(now: epoch.addingTimeInterval(0.005), idleTimeout: window) == nil)
        #expect(watch.tick(now: epoch.addingTimeInterval(0.019), idleTimeout: window) == nil)
        #expect(watch.tick(now: epoch.addingTimeInterval(0.030), idleTimeout: window) == .wentQuiet)
    }
}
