import ElliotIPC
import ElliotModel
import ElliotStore
import Foundation
import MCP
import Testing

@testable import ElliotMCPKit

/// The two tools that follow and stop a run.
///
/// Both go through `bridge.write` although only one of them changes anything.
/// `board_await_run` does it because a snapshot cannot advance: served from the
/// database the wait would spend its window re-reading one frozen row and then
/// report a live run as unfinished forever. `board_cancel_run` does it because
/// only the running app knows the run id is real — answered any other way,
/// cancelling a run that never existed comes back as a plausible success and the
/// caller stops watching a run that is still going.
///
/// Already covered next door in `RunReportingTests` and not repeated here:
/// `awaitTimeoutIsNotAnError`, `awaitTerminalRunIsFinal`, `awaitForwardsItsTimeout`,
/// `cancelReportsWhereItLanded` and `cancelUnknownRun`. What follows is what
/// those five leave open — the poll hint, the terminal cancel, and the fact that
/// neither tool has a path to the snapshot.
@Suite("Following and stopping a run")
struct RunControlToolTests {

    /// A bridge that is down: reads would fall back to the snapshot, writes are
    /// refused. The read side is recorded so a test can assert it was never
    /// reached, rather than only that the answer happened to be a refusal.
    private func downBridge(_ store: BoardStore, log: RequestLog) -> StubBridge {
        StubBridge(
            isAppRunning: false,
            onRead: { request in
                log.record(request)
                return .offline(store, .appNotRunning)
            },
            onWrite: { _ in
                .failure(
                    code: .appUnavailable,
                    message: "Elliot is not running and could not be launched.",
                    hint: "Open Elliot.app and try again."
                )
            }
        )
    }

    @Test("A wait that came back early says when to ask again, in seconds")
    func awaitTimeoutCarriesThePollHint() async throws {
        // The note says "call again"; this is the number that says *when*. Absent,
        // an agent either hammers the socket or invents an interval — and the
        // interval is the thing that backs off with the run's age, so inventing
        // one is how a merge-pr waiting on CI gets polled every second for an
        // hour.
        let run = makeRun(cardID: UUID(), repoID: UUID(), kind: .mergePR, state: .running)
        let bridge = StubBridge.answering(.run(RunDTO(run: run, now: epoch)))

        let answer = try await call(
            ElliotMCPServer(bridge: bridge),
            "board_await_run",
            ["run_id": .string(run.id.uuidString)]
        )

        #expect(!answer.isError)
        #expect(answer["run"]?["isTerminal"]?.boolValue == false)
        let poll = try #require(answer["run"]?["pollAfterSeconds"]?.intValue)
        #expect(poll > 0)
    }

    @Test("A run that is already over is returned as it is, not reported as newly signalled")
    func cancellingATerminalRunSaysNothingWasSignalled() async throws {
        // `board_cancel_run` attaches "Signalled, not stopped yet" whenever the
        // run it gets back is non-terminal. A run that had already finished must
        // not collect that sentence: it would tell the agent a process is winding
        // down when there is no process, and invite a board_await_run that can
        // only return the same terminal row.
        let run = makeRun(
            cardID: UUID(), repoID: UUID(), kind: .implementIssue, state: .succeeded,
            outcome: .prOpen(number: 7, url: "https://github.com/phmatray/Elliot/pull/7",
                             isDraft: false, branch: "feat/7-x")
        )
        let bridge = StubBridge.answering(.run(RunDTO(run: run, now: epoch)))

        let answer = try await call(
            ElliotMCPServer(bridge: bridge),
            "board_cancel_run",
            ["run_id": .string(run.id.uuidString)]
        )

        #expect(!answer.isError)
        #expect(answer["run"]?["isTerminal"]?.boolValue == true)
        #expect(answer["run"]?["state"]?.stringValue == "succeeded")
        #expect(answer.note.isEmpty)
        // Still the run's own record of what it managed to do before anyone
        // asked it to stop.
        #expect(answer["run"]?["verifiedOutcome"]?["kind"]?.stringValue == "pr_open")
    }

    @Test("Neither following nor stopping a run is served from the snapshot")
    func runControlIsNeverServedOffline() async throws {
        let repo = makeRepo()
        let card = makeCard(repoID: repo.id)
        let run = makeRun(cardID: card.id, repoID: repo.id, state: .running)
        let store = try await makeStore(repos: [repo], cards: [card], runs: [run])

        for tool in ["board_await_run", "board_cancel_run"] {
            let log = RequestLog()
            let answer = try await call(
                ElliotMCPServer(bridge: downBridge(store, log: log)),
                tool,
                ["run_id": .string(run.id.uuidString)]
            )

            #expect(answer.isError, "\(tool)")
            #expect(answer.error == ElliotErrorCode.appUnavailable.rawValue, "\(tool)")
            // The run is in the snapshot and could have been answered from it.
            // For `board_await_run` that answer would be a frozen row presented
            // as a wait that expired; for `board_cancel_run` it would be a
            // cancellation nobody performed.
            #expect(answer["run"] == nil, "\(tool)")
            #expect(answer.source == nil, "\(tool)")
            #expect(log.count == 0, "\(tool) consulted the read side")
        }
    }
}
