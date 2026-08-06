import ElliotModel
import Foundation
import Testing

@testable import ElliotAppKit

@Suite("Analysis session")
struct AnalysisSessionTests {
    /// An analysis run: `cardID` nil, `kind` `.analyzeRepo`. Built with
    /// `SkillRun`'s own initialiser — the one the scheduler uses — so the
    /// fixture is the real shape rather than a stand-in, exactly as
    /// `AppModelTests.run(cardID:state:)` does it.
    private func run(state: RunState = .running) -> SkillRun {
        var run = SkillRun(
            cardID: nil, repoID: UUID(), analysisID: UUID(), analysisAngle: .bugs,
            kind: .analyzeRepo, prompt: "analyse", cwd: "/tmp",
            logPath: "/tmp/run.ndjson", stderrPath: "/tmp/run.log",
            createdAt: Date(timeIntervalSince1970: 0)
        )
        run.state = state
        return run
    }

    @Test("Every member but the id has a default, which is what makes a new one free")
    func defaults() {
        // AC 4 rests on this: `openAnalysis` names only the id, so a member
        // added later arrives at its default instead of costing a line in
        // `openAnalysis` and another in `closeAnalysis`.
        let session = AnalysisSession(id: UUID())
        #expect(session.runs.isEmpty)
        #expect(session.proposals.isEmpty)
        #expect(session.note == nil)
        #expect(session.observation == nil)
    }

    @Test("Rows are accepted only by the analysis they were read for")
    func acceptsOnlyItsOwnRows() {
        let id = UUID()
        let session = AnalysisSession(id: id)
        #expect(AnalysisSession.accepts(session, rowsFor: id))
        // Closed while the read was in flight.
        #expect(!AnalysisSession.accepts(nil, rowsFor: id))
        // Replaced while the read was in flight — the worse case, because
        // the rows would land in a session that renders them.
        #expect(!AnalysisSession.accepts(AnalysisSession(id: UUID()), rowsFor: id))
    }

    @Test("A stall marks the named run and leaves the others alone")
    func markStalledIsByID() {
        let target = run()
        let other = run()
        var session = AnalysisSession(id: UUID(), runs: [target, other])
        session.markStalled(target.id)
        #expect(session.runs.first(where: { $0.id == target.id })?.state == .stalled)
        #expect(session.runs.first(where: { $0.id == other.id })?.state == .running)
    }

    @Test("Releasing the handle cancels the observation")
    func handleCancelsOnRelease() {
        // The load-bearing claim of the whole change: `analysis = nil` is
        // allowed to be the only line in `closeAnalysis` precisely because
        // dropping the session drops this handle, and ARC cancels here.
        //
        // Synchronous on purpose, and it does not wait on anything: `deinit`
        // runs when the last strong reference goes, and `Task.cancel()` sets
        // the flag whether or not the task has started. Nothing here sleeps,
        // and nothing measures a duration.
        let task = Task<Void, Never> { try? await Task.sleep(for: .seconds(60)) }
        var handle: ObservationHandle? = ObservationHandle(task)
        #expect(handle != nil)
        #expect(!task.isCancelled)

        handle = nil

        #expect(task.isCancelled)
        task.cancel()  // the test owns this one too; leave nothing running
    }
}
