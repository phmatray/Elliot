import ElliotIPC
import ElliotModel
import ElliotStore
import Foundation
import MCP
import Testing

@testable import ElliotMCPKit

/// What a run reports about itself.
///
/// The critical one. A run that finished cleanly and created nothing is a
/// success by `state` and a non-event in fact, and version 1 of this surface
/// gave an agent no way to tell those apart. Every assertion here is about
/// keeping the difference visible.
@Suite("Reporting what a run actually did")
struct RunReportingTests {

    private func page(_ runs: [SkillRun]) -> ElliotPayload {
        .runs(RunPage(runs: runs.map { RunDTO(run: $0, now: epoch) }, total: runs.count, limit: 20))
    }

    // MARK: - Verified outcome crosses the wire

    @Test("A run that created no issue does not read as an unqualified success")
    func noIssueCreatedIsDistinguishable() async throws {
        let run = makeRun(
            cardID: UUID(), repoID: UUID(),
            state: .succeeded,
            outcome: .noIssueCreated(reason: "The idea is already covered by issue #40.")
        )
        let server = ElliotMCPServer(bridge: StubBridge.answering(page([run])))

        let answer = try await call(server, "board_list_runs")

        let reported = try #require(answer["runs"]?[0])
        // Clean exit and nothing filed are both true at once. An agent reading
        // only `state` would report the issue as created.
        #expect(reported["state"]?.stringValue == "succeeded")
        #expect(reported["isTerminal"]?.boolValue == true)
        let outcome = try #require(reported["verifiedOutcome"])
        #expect(outcome["kind"]?.stringValue == "no_issue_created")
        #expect(outcome["kind"]?.stringValue != "issue_created")
        #expect(outcome["reason"]?.stringValue?.contains("#40") == true)
        // Nothing was created, so there is no number to carry.
        #expect(outcome["number"] == nil)
        #expect(outcome["url"] == nil)
    }

    @Test("A run that did create an issue carries its number and URL")
    func issueCreatedCarriesTheFacts() async throws {
        let run = makeRun(
            cardID: UUID(), repoID: UUID(),
            state: .succeeded,
            outcome: .issueCreated(number: 41, url: "https://github.com/phmatray/Elliot/issues/41")
        )

        let answer = try await call(
            ElliotMCPServer(bridge: StubBridge.answering(page([run]))),
            "board_list_runs"
        )

        let outcome = try #require(answer["runs"]?[0]?["verifiedOutcome"])
        #expect(outcome["kind"]?.stringValue == "issue_created")
        #expect(outcome["number"]?.intValue == 41)
        #expect(outcome["url"]?.stringValue?.hasSuffix("/issues/41") == true)
    }

    @Test("A merge that happened and one that did not are different answers")
    func mergedIsNotTheSameAsNotMerged() async throws {
        let merged = makeRun(
            cardID: UUID(), repoID: UUID(), kind: .mergePR, state: .succeeded,
            outcome: .merged(commitSHA: "9929281"),
            createdAt: epoch.addingTimeInterval(1)
        )
        let refused = makeRun(
            cardID: UUID(), repoID: UUID(), kind: .mergePR, state: .succeeded,
            outcome: .notMerged(reason: "Required check build-and-test is failing."),
            createdAt: epoch
        )

        let answer = try await call(
            ElliotMCPServer(bridge: StubBridge.answering(page([merged, refused]))),
            "board_list_runs"
        )

        let first = try #require(answer["runs"]?[0]?["verifiedOutcome"])
        #expect(first["kind"]?.stringValue == "merged")
        #expect(first["commitSHA"]?.stringValue == "9929281")
        // A merge that did not happen has no commit to point at, and saying so
        // by omission is the difference the agent branches on.
        #expect(first["reason"] == nil)

        let second = try #require(answer["runs"]?[1]?["verifiedOutcome"])
        #expect(second["kind"]?.stringValue == "not_merged")
        #expect(second["commitSHA"] == nil)
        #expect(second["reason"]?.stringValue?.contains("build-and-test") == true)
    }

    @Test("A pull request closed without merging is neither merged nor a failure")
    func closedUnmergedIsItsOwnKind() async throws {
        let run = makeRun(
            cardID: UUID(), repoID: UUID(), kind: .mergePR, state: .succeeded,
            outcome: .closedUnmerged
        )

        let answer = try await call(
            ElliotMCPServer(bridge: StubBridge.answering(page([run]))),
            "board_list_runs"
        )

        #expect(answer["runs"]?[0]?["verifiedOutcome"]?["kind"]?.stringValue == "closed_unmerged")
        #expect(answer["runs"]?[0]?["state"]?.stringValue == "succeeded")
    }

    @Test("A run nobody could verify says so rather than staying silent")
    func unverifiedIsReported() async throws {
        let run = makeRun(
            cardID: UUID(), repoID: UUID(), state: .succeeded,
            outcome: .unverified(reason: "gh returned no pull request for this branch.")
        )

        let answer = try await call(
            ElliotMCPServer(bridge: StubBridge.answering(page([run]))),
            "board_list_runs"
        )

        let outcome = try #require(answer["runs"]?[0]?["verifiedOutcome"])
        #expect(outcome["kind"]?.stringValue == "unverified")
        #expect(outcome["reason"]?.stringValue?.contains("gh") == true)
    }

    @Test("The agent's own prose does not stand in for what gh established")
    func resultTextIsNotTheOutcome() async throws {
        var run = makeRun(
            cardID: UUID(), repoID: UUID(), kind: .mergePR, state: .succeeded,
            outcome: .notMerged(reason: "The pull request is a draft.")
        )
        // The exact shape of the bug: the agent says it merged, gh says it did
        // not, and both travel — under different names, so they cannot be
        // confused for one another.
        run.resultText = "Merged the pull request and deleted the branch."

        let answer = try await call(
            ElliotMCPServer(bridge: StubBridge.answering(page([run]))),
            "board_list_runs"
        )

        let reported = try #require(answer["runs"]?[0])
        #expect(reported["resultText"]?.stringValue?.contains("Merged") == true)
        #expect(reported["verifiedOutcome"]?["kind"]?.stringValue == "not_merged")
    }

    @Test("A run names its skill in the same words the rest of the wire uses")
    func runKindUsesTheSkillName() async throws {
        let runs = [
            makeRun(cardID: UUID(), repoID: UUID(), kind: .createIssue, createdAt: epoch),
            makeRun(cardID: UUID(), repoID: UUID(), kind: .implementIssue, createdAt: epoch),
            makeRun(cardID: UUID(), repoID: UUID(), kind: .mergePR, createdAt: epoch),
        ]

        let answer = try await call(
            ElliotMCPServer(bridge: StubBridge.answering(page(runs))),
            "board_list_runs"
        )

        let kinds = try #require(answer["runs"]?.arrayValue).compactMap { $0["kind"]?.stringValue }
        // Not the persisted raw value: `MoveDTO.triggered` and
        // `NextDTO.wouldTrigger` were always spelled this way, and an agent
        // correlating the three should not need a table.
        #expect(kinds == ["create-issue", "implement-issue", "merge-pr"])
    }

    @Test("A run still going is told apart from one that finished")
    func nonTerminalRunSaysWhenToLookAgain() async throws {
        let running = makeRun(cardID: UUID(), repoID: UUID(), state: .running, createdAt: epoch)
        let finished = makeRun(cardID: UUID(), repoID: UUID(), state: .failed, createdAt: epoch)

        let answer = try await call(
            ElliotMCPServer(bridge: StubBridge.answering(page([running, finished]))),
            "board_list_runs"
        )

        #expect(answer["runs"]?[0]?["isTerminal"]?.boolValue == false)
        #expect(answer["runs"]?[0]?["pollAfterSeconds"]?.intValue == 5)
        #expect(answer["runs"]?[1]?["isTerminal"]?.boolValue == true)
        // Nothing left to poll for, and saying so is what ends the loop.
        #expect(answer["runs"]?[1]?["pollAfterSeconds"] == nil)
    }

    @Test("A stalled run is not terminal, whatever it looks like")
    func stalledIsNotTerminal() async throws {
        let run = makeRun(cardID: UUID(), repoID: UUID(), state: .stalled, createdAt: epoch)

        let answer = try await call(
            ElliotMCPServer(bridge: StubBridge.answering(page([run]))),
            "board_list_runs"
        )

        #expect(answer["runs"]?[0]?["state"]?.stringValue == "stalled")
        #expect(answer["runs"]?[0]?["isTerminal"]?.boolValue == false)
    }

    @Test("A verified outcome survives the snapshot as well as the socket")
    func outcomeSurvivesTheDatabase() async throws {
        // The offline path decodes the outcome back out of SQLite. A `kind`
        // that only exists on the live path would be a difference an agent
        // could not see coming.
        let repo = makeRepo()
        let card = makeCard(repoID: repo.id)
        let run = makeRun(
            cardID: card.id, repoID: repo.id, kind: .createIssue, state: .succeeded,
            outcome: .noIssueCreated(reason: "Already covered by issue #40.")
        )
        let store = try await makeStore(repos: [repo], cards: [card], runs: [run])

        let answer = try await call(ElliotMCPServer(bridge: StubBridge.snapshot(store)), "board_list_runs")

        let outcome = try #require(answer["runs"]?[0]?["verifiedOutcome"])
        #expect(outcome["kind"]?.stringValue == "no_issue_created")
        #expect(outcome["reason"]?.stringValue?.contains("#40") == true)
        #expect(answer["runs"]?[0]?["kind"]?.stringValue == "create-issue")
    }

    // MARK: - Waiting and cancelling

    @Test("A wait that ran out of window is not a failure")
    func awaitTimeoutIsNotAnError() async throws {
        let run = makeRun(cardID: UUID(), repoID: UUID(), kind: .mergePR, state: .running)
        let bridge = StubBridge.answering(.run(RunDTO(run: run, now: epoch)))

        let answer = try await call(
            ElliotMCPServer(bridge: bridge),
            "board_await_run",
            ["run_id": .string(run.id.uuidString)]
        )

        #expect(!answer.isError)
        #expect(answer["run"]?["isTerminal"]?.boolValue == false)
        #expect(answer.note.contains("not a failure"))
        #expect(answer.note.contains("again"))
    }

    @Test("A wait that ended says what the run achieved and does not ask to be repeated")
    func awaitTerminalRunIsFinal() async throws {
        let run = makeRun(
            cardID: UUID(), repoID: UUID(), kind: .mergePR, state: .succeeded,
            outcome: .merged(commitSHA: "41cbfd9")
        )
        let bridge = StubBridge.answering(.run(RunDTO(run: run, now: epoch)))

        let answer = try await call(
            ElliotMCPServer(bridge: bridge),
            "board_await_run",
            ["run_id": .string(run.id.uuidString)]
        )

        #expect(answer["run"]?["isTerminal"]?.boolValue == true)
        #expect(answer["run"]?["verifiedOutcome"]?["kind"]?.stringValue == "merged")
        #expect(answer.note.isEmpty)
    }

    @Test("A wait names its own window rather than letting the socket decide")
    func awaitForwardsItsTimeout() async throws {
        let log = RequestLog()
        let run = makeRun(cardID: UUID(), repoID: UUID(), state: .succeeded)
        let bridge = StubBridge(onWrite: { request in
            log.record(request)
            return .ok(.run(RunDTO(run: run, now: epoch)))
        })

        _ = try await call(
            ElliotMCPServer(bridge: bridge),
            "board_await_run",
            ["run_id": .string(run.id.uuidString), "timeout_seconds": .int(120)]
        )

        guard case .awaitRun(_, let seconds)? = log.last else {
            Issue.record("the helper did not forward an awaitRun request")
            return
        }
        #expect(seconds == 120)
        // The socket deadline has to outlive the server's own window, or the
        // client hangs up on an answer already on its way and the caller reads
        // a live run as a dead app.
        #expect(ElliotRequest.awaitRun(id: run.id, timeoutSeconds: 120).socketTimeout > 120)
    }

    @Test("A run asked to stop reports which of cancelling and cancelled it reached")
    func cancelReportsWhereItLanded() async throws {
        let run = makeRun(cardID: UUID(), repoID: UUID(), kind: .implementIssue, state: .cancelling)
        let bridge = StubBridge.answering(.run(RunDTO(run: run, now: epoch)))

        let answer = try await call(
            ElliotMCPServer(bridge: bridge),
            "board_cancel_run",
            ["run_id": .string(run.id.uuidString)]
        )

        #expect(answer["run"]?["state"]?.stringValue == "cancelling")
        #expect(answer.note.contains("Signalled, not stopped yet"))
    }

    @Test("A run id that names nothing is run_not_found")
    func cancelUnknownRun() async throws {
        let bridge = StubBridge.refusing(.runNotFound, "No run with that id.")

        let answer = try await call(
            ElliotMCPServer(bridge: bridge),
            "board_cancel_run",
            ["run_id": .string(UUID().uuidString)]
        )

        #expect(answer.isError)
        #expect(answer.error == "run_not_found")
    }

    // MARK: - Moves and corrections

    @Test("A move that started a run says so, and says when to look again")
    func moveReportsItsRun() async throws {
        let cardID = UUID(), runID = UUID()
        let bridge = StubBridge.answering(.moved(MoveDTO(
            cardID: cardID, from: "todo", to: "inProgress",
            runID: runID, triggered: "implement-issue", pollAfterSeconds: 5,
            summary: "Moved to In Progress and started implement-issue."
        )))

        let answer = try await call(
            ElliotMCPServer(bridge: bridge),
            "board_move_card",
            ["card_id": .string(cardID.uuidString), "to": .string("inProgress")]
        )

        #expect(answer["run_id"]?.stringValue == runID.uuidString)
        #expect(answer["triggered"]?.stringValue == "implement-issue")
        #expect(answer["poll_after_seconds"]?.intValue == 5)
        // Returns when the run is queued, not when it is done — an agent that
        // reads this as completion reports work that has not happened.
        #expect(answer.note.contains("queued, not finished"))
        #expect(answer.note.contains(runID.uuidString))
    }

    @Test("A move that started nothing does not invent a run")
    func moveWithoutARunSaysNothingAboutOne() async throws {
        let cardID = UUID()
        let bridge = StubBridge.answering(.moved(MoveDTO(
            cardID: cardID, from: "inProgress", to: "inReview",
            runID: nil, triggered: nil, summary: "Moved to In Review."
        )))

        let answer = try await call(
            ElliotMCPServer(bridge: bridge),
            "board_move_card",
            ["card_id": .string(cardID.uuidString), "to": .string("inReview")]
        )

        #expect(answer["run_id"] == nil)
        #expect(answer["triggered"] == nil)
        #expect(answer.note.isEmpty)
    }

    @Test("A refused move comes back with the rule engine's own code")
    func blockedMoveKeepsItsCode() async throws {
        let bridge = StubBridge.refusing(
            .moveBlocked,
            "The card has no issue number.",
            hint: "Move it backlog → todo first, which files the issue."
        )

        let answer = try await call(
            ElliotMCPServer(bridge: bridge),
            "board_move_card",
            ["card_id": .string(UUID().uuidString), "to": .string("inProgress")]
        )

        #expect(answer.isError)
        #expect(answer.error == "move_blocked")
        #expect(answer.hint.contains("backlog"))
    }

    @Test("A create that matched an idempotency key says nothing was created")
    func idempotentCreateSaysSo() async throws {
        let card = CardDTO(
            id: UUID(), title: "Stream the run log", column: "backlog", repo: "phmatray/Elliot"
        )
        let bridge = StubBridge.answering(.created(CardCreatedDTO(card: card, alreadyExisted: true)))

        let answer = try await call(
            ElliotMCPServer(bridge: bridge),
            "board_create_card",
            [
                "repo": .string("phmatray/Elliot"),
                "title": .string("Stream the run log"),
                "idempotency_key": .string("stream-the-run-log"),
            ]
        )

        #expect(!answer.isError)
        #expect(answer["already_existed"]?.boolValue == true)
        #expect(answer["card"]?["id"]?.stringValue == card.id.uuidString)
        #expect(answer.note.contains("already existed"))
    }

    @Test("A first create does not claim anything already existed")
    func firstCreateIsNotFlagged() async throws {
        let card = CardDTO(
            id: UUID(), title: "Stream the run log", column: "backlog", repo: "phmatray/Elliot"
        )
        let bridge = StubBridge.answering(.created(CardCreatedDTO(card: card, alreadyExisted: false)))

        let answer = try await call(
            ElliotMCPServer(bridge: bridge),
            "board_create_card",
            ["repo": .string("phmatray/Elliot"), "title": .string("Stream the run log")]
        )

        #expect(answer["already_existed"]?.boolValue == false)
        #expect(answer.note.isEmpty)
    }

    @Test("The three parts of a story reach the app separately")
    func storyIsSentInParts() async throws {
        let log = RequestLog()
        let card = CardDTO(id: UUID(), title: "T", column: "backlog", repo: "phmatray/Elliot")
        let bridge = StubBridge(onWrite: { request in
            log.record(request)
            return .ok(.created(CardCreatedDTO(card: card, alreadyExisted: false)))
        })

        _ = try await call(
            ElliotMCPServer(bridge: bridge),
            "board_create_card",
            [
                "repo": .string("phmatray/Elliot"),
                "title": .string("Stream the run log"),
                "role": .string("developer"),
                "want": .string("the run log streamed"),
                "benefit": .string("I can diagnose a failure while it happens"),
                "acceptance_criteria": .array([.string("lines appear within a second")]),
            ]
        )

        guard case .createCard(_, _, _, let story?, _, _)? = log.last else {
            Issue.record("the story did not survive the tool boundary")
            return
        }
        #expect(story.role == "developer")
        #expect(story.acceptanceCriteria == ["lines appear within a second"])
    }

    @Test("A card already filed as an issue is refused permanently, not as read-only")
    func alreadyFiledIsItsOwnRefusal() async throws {
        // `read_only` means Elliot is down, which clears when it starts — so an
        // agent hearing it retries. This refusal never clears.
        let bridge = StubBridge.refusing(
            .cardAlreadyFiled,
            "This card is filed as issue #123; edit the issue on github.com."
        )

        let answer = try await call(
            ElliotMCPServer(bridge: bridge),
            "board_update_card",
            ["card_id": .string(UUID().uuidString), "title": .string("Corrected")]
        )

        #expect(answer.isError)
        #expect(answer.error == "card_already_filed")
        #expect(answer.error != "read_only")
    }

    @Test("Correcting a card without a title is refused, because it is a replacement")
    func updateWithoutTitleIsRefused() async throws {
        let answer = try await call(
            ElliotMCPServer(bridge: StubBridge()),
            "board_update_card",
            ["card_id": .string(UUID().uuidString), "body": .string("just the note")]
        )

        #expect(answer.isError)
        #expect(answer.error == "bad_argument")
        #expect(answer.message.contains("patching"))
    }

    // MARK: - A result that cannot be serialised

    @Test("A payload that will not serialise is an error, never an empty success")
    func unserialisablePayloadIsAnError() async throws {
        // A cost of infinity is what a malformed terminal event can leave on a
        // run; JSON has no way to write it. The point is not the value, it is
        // that the encode step is fallible at all — and that it used to reach
        // the agent as `{}` with `isError: false`, which gets believed.
        let run = makeRun(
            cardID: UUID(), repoID: UUID(), state: .succeeded, totalCostUSD: .infinity
        )
        let bridge = StubBridge.answering(
            .runs(RunPage(runs: [RunDTO(run: run, now: epoch)], total: 1, limit: 20))
        )

        let answer = try await call(ElliotMCPServer(bridge: bridge), "board_list_runs")

        #expect(answer.isError)
        #expect(answer.error == "internal_error")
        #expect(answer["runs"] == nil)
        #expect(!answer.text.contains("\"runs\":null"))
    }

    @Test("A payload this build cannot read is an error, not an empty answer")
    func unreadablePayloadIsAnError() async throws {
        // Two different builds of the app and the helper is exactly when this
        // happens, and it is the moment an empty-looking success is most
        // expensive.
        let bridge = StubBridge.answering(.hello(serverVersion: "9.9.9"))

        let answer = try await call(
            ElliotMCPServer(bridge: bridge),
            "board_get_card",
            ["card_id": .string(UUID().uuidString)]
        )

        #expect(answer.isError)
        #expect(answer.error == "internal_error")
        #expect(answer.hint.contains("builds"))
    }

    // MARK: - An analysis run is more than a UUID

    @Test("An analysis run reports which reading it was, and what it harvested")
    func analysisRunIsSelfDescribing() async throws {
        let analysisID = UUID()
        let run = makeAnalysisRun(
            repoID: UUID(),
            analysisID: analysisID,
            angle: .quickWins,
            report: AnalysisRunReport(
                harvestSource: .resultText,
                kept: 3,
                dropped: ["story 4: cited a file that does not exist"],
                workingTreeChanged: false
            )
        )
        let server = ElliotMCPServer(bridge: StubBridge.answering(page([run])))

        let answer = try await call(server, "board_list_runs")

        let reported = try #require(answer["runs"]?[0])
        #expect(reported["cardID"] == nil)
        #expect(reported["analysisID"]?.stringValue == analysisID.uuidString)
        #expect(reported["angle"]?.stringValue == "quickWins")
        let report = try #require(reported["analysisReport"])
        // `resultText`, not `artifact`: the stories had to be recovered from
        // the closing message, which is worth knowing about their quality.
        #expect(report["source"]?.stringValue == "resultText")
        #expect(report["kept"]?.intValue == 3)
        #expect(report["dropped"]?.arrayValue?.count == 1)
    }

    /// The whole point of the sentinel, asserted where an agent actually reads
    /// it. Task 1 pins the encoding; this pins that nothing between the codec
    /// and the tool result collapses the two.
    @Test("Checked-and-clean does not read the same as never-checked")
    func workingTreeTriStateSurvivesTheToolSurface() async throws {
        let clean = makeAnalysisRun(
            repoID: UUID(), angle: .bugs,
            report: AnalysisRunReport(
                harvestSource: .artifact, kept: 1, workingTreeChanged: false
            )
        )
        let unchecked = makeAnalysisRun(
            repoID: UUID(), angle: .tests,
            report: AnalysisRunReport(harvestSource: .artifact, kept: 1)
        )
        let server = ElliotMCPServer(bridge: StubBridge.answering(page([clean, unchecked])))

        let answer = try await call(server, "board_list_runs")

        let first = try #require(answer["runs"]?[0]?["analysisReport"])
        let second = try #require(answer["runs"]?[1]?["analysisReport"])
        // Present and false: the sentinel ran, the tree was untouched.
        #expect(first["workingTreeChanged"]?.boolValue == false)
        // Absent: nobody looked. An agent must not read this as clean.
        #expect(second["workingTreeChanged"] == nil)
    }

    @Test("A run that wrote to the repository says so, and says what changed")
    func aRunThatEditedTheRepositoryIsLoud() async throws {
        let run = makeAnalysisRun(
            repoID: UUID(), angle: .techDebt,
            report: AnalysisRunReport(
                harvestSource: .artifact, kept: 2,
                workingTreeChanged: true,
                workingTreeDiff: " M ElliotKit/Sources/ElliotModel/Analysis.swift"
            )
        )
        let server = ElliotMCPServer(bridge: StubBridge.answering(page([run])))

        let answer = try await call(server, "board_list_runs")

        let report = try #require(answer["runs"]?[0]?["analysisReport"])
        #expect(report["workingTreeChanged"]?.boolValue == true)
        #expect(report["workingTreeDiff"]?.stringValue?.contains("Analysis.swift") == true)
    }
}
