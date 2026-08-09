import Foundation
import Testing

@testable import ElliotModel

/// The rule that decides which lenses are already reading, and the guard that
/// stops one repository's answer being drawn against another.
@Suite("Busy lenses")
struct BusyLensesTests {

    private static func run(
        repoID: UUID,
        analysisID: UUID? = UUID(),
        angle: AnalysisAngle?,
        state: RunState,
        startedAt: Date? = nil
    ) -> SkillRun {
        SkillRun(
            cardID: nil, repoID: repoID, analysisID: analysisID, analysisAngle: angle,
            kind: .analyzeRepo, prompt: "…", cwd: "/tmp", state: state, startedAt: startedAt,
            logPath: "/tmp/run.ndjson", stderrPath: "/tmp/run.log",
            createdAt: Date(timeIntervalSince1970: 0)
        )
    }

    // MARK: - The rule

    @Test("A running analysis run marks its lens, with the time it started")
    func aRunningLensIsBusy() {
        let repo = UUID()
        let started = Date(timeIntervalSince1970: 1_000)
        let busy = BusyLenses(
            repoID: repo,
            runs: [Self.run(repoID: repo, angle: .bugs, state: .running, startedAt: started)])

        #expect(busy.state(of: .bugs, in: repo) == .reading(since: started))
        #expect(busy.state(of: .techDebt, in: repo) == nil)
    }

    /// ⛔ Queued is busy too — the service refuses on it, so a tile that called
    /// it free would promise a Start that throws.
    @Test("A queued run is busy, and says so without inventing a stopwatch")
    func aQueuedLensIsBusyWithNoElapsedTime() {
        let repo = UUID()
        let busy = BusyLenses(
            repoID: repo,
            runs: [Self.run(repoID: repo, angle: .tests, state: .queued)])

        #expect(busy.state(of: .tests, in: repo) == .queued)
        #expect(busy.state(of: .tests, in: repo)?.since == nil)
    }

    @Test("Stalled and cancelling still hold their lens; the terminal states do not")
    func onlyTheNonTerminalStatesHold() {
        let repo = UUID()
        for state in RunState.allCases {
            let busy = BusyLenses(
                repoID: repo,
                runs: [Self.run(repoID: repo, angle: .bugs, state: state, startedAt: Date())])
            #expect(
                (busy.state(of: .bugs, in: repo) != nil) == !state.isTerminal,
                Comment(rawValue: "\(state) disagreed with RunState.isTerminal"))
        }
    }

    /// A run that belongs to no analysis is a card's run — an `implement-issue`,
    /// a merge — and it holds no lens.
    @Test("A run with no analysis, or no angle, marks nothing")
    func onlyAnalysisRunsCount() {
        let repo = UUID()
        let busy = BusyLenses(
            repoID: repo,
            runs: [
                Self.run(repoID: repo, analysisID: nil, angle: .bugs, state: .running),
                Self.run(repoID: repo, angle: nil, state: .running),
            ])
        #expect(AnalysisAngle.allCases.allSatisfy { busy.state(of: $0, in: repo) == nil })
    }

    /// Two active runs for one lens is what `AnalysisService` refuses, so this
    /// cannot arise in a healthy store — the point is that it degrades to the
    /// honest answer rather than to whichever row SQLite returned last.
    @Test("Two runs on one lens report the longer wait, and a started one beats a queued one")
    func theLongestWaitWins() {
        let repo = UUID()
        let early = Date(timeIntervalSince1970: 100)
        let late = Date(timeIntervalSince1970: 900)

        let both = BusyLenses(
            repoID: repo,
            runs: [
                Self.run(repoID: repo, angle: .bugs, state: .running, startedAt: late),
                Self.run(repoID: repo, angle: .bugs, state: .running, startedAt: early),
            ])
        #expect(both.state(of: .bugs, in: repo) == .reading(since: early))

        let mixed = BusyLenses(
            repoID: repo,
            runs: [
                Self.run(repoID: repo, angle: .bugs, state: .queued),
                Self.run(repoID: repo, angle: .bugs, state: .running, startedAt: late),
            ])
        #expect(mixed.state(of: .bugs, in: repo) == .reading(since: late))
    }

    // MARK: - The repository guard

    /// ⛔ The reason this type exists rather than a bare set. A snapshot read for
    /// one repository must be undrawable against another — the panel's subject
    /// can move while the read is in flight (#213).
    @Test("A snapshot answers about its own repository and no other")
    func aSnapshotIsScopedToItsRepository() {
        let mine = UUID()
        let other = UUID()
        let busy = BusyLenses(
            repoID: mine,
            runs: [Self.run(repoID: mine, angle: .bugs, state: .running, startedAt: Date())])

        #expect(busy.state(of: .bugs, in: mine) != nil)
        #expect(busy.state(of: .bugs, in: other) == nil)
        #expect(busy.state(of: .bugs, in: nil) == nil)
        #expect(busy.clashes(with: [.bugs], in: other).isEmpty)
        #expect(busy.clashes(with: [.bugs], in: nil).isEmpty)
    }

    // MARK: - Clashes

    @Test("Only the armed lenses clash, and they come back in the order they were asked")
    func clashesKeepTheCallersOrder() {
        let repo = UUID()
        let busy = BusyLenses(
            repoID: repo,
            lenses: [.bugs: .queued, .techDebt: .reading(since: Date()), .tests: .queued])

        // Armed: three, two of which are busy. `features` is armed and free;
        // `tests` is busy and not armed, so it is not a clash.
        #expect(busy.clashes(with: [.bugs, .features, .techDebt], in: repo) == [.bugs, .techDebt])
        #expect(busy.clashes(with: [.techDebt, .bugs], in: repo) == [.techDebt, .bugs])
        #expect(busy.clashes(with: [.features], in: repo).isEmpty)
        #expect(busy.clashes(with: [], in: repo).isEmpty)
    }
}
