import ElliotIPC
import ElliotModel
import ElliotProcess
import ElliotStore
import Foundation
import TestSupport
import Testing

@testable import ElliotEngine

/// Records what would have been launched, without spawning anything.
private actor LaunchSpy: RunLaunching {
    private let store: BoardStore
    private(set) var launched: [UUID] = []

    init(store: BoardStore) { self.store = store }

    func launch(runID: UUID) async { launched.append(runID) }

    /// Mirrors the never-started branch of `RunScheduler.cancel`: a queued run
    /// has no live process to signal, so it goes straight to `.cancelled`
    /// rather than through `.cancelling`.
    ///
    /// A spy that ignored cancellation would leave the run `queued`, and
    /// `BoardService.cancel` — which delegates here and then re-reads the
    /// store — would hand the handler back an untouched run. The cancel path
    /// would be driven without ever being exercised.
    func cancel(runID: UUID) async {
        guard var run = try? await store.run(id: runID), run.state.isActive else { return }
        run.state = .cancelled
        run.endedAt = Date()
        try? await store.saveRun(run)
    }

    func ids() -> [UUID] { launched }
}

private struct Fixture {
    var store: BoardStore
    var board: BoardService
    var analysis: AnalysisService
    var handler: MCPRequestHandler
    var spy: LaunchSpy
    var repo: Repo

    static func make(enabled: Bool = true) async throws -> Fixture {
        // `AnalysisService.start` computes an artifact path through
        // `StoreLocation` even with an in-memory store. Same reason
        // `AnalysisServiceTests` does this, and the only sanctioned way to
        // move `ELLIOT_HOME` in this target.
        _ = TestHome.root
        let store = try BoardStore.inMemory()
        let config = ToolConfig(
            claudePath: "/usr/bin/false", ghPath: "/usr/bin/false",
            gitPath: "/usr/bin/false", environment: [:]
        )
        let spy = LaunchSpy(store: store)
        let board = BoardService(store: store, launcher: spy)
        let analysis = AnalysisService(
            store: store, launcher: spy, board: board, gh: GHClient(config: config)
        )
        var repo = Repo(
            path: "/tmp/repo-\(UUID().uuidString)",
            nameWithOwner: "phmatray/Elliot",
            displayName: "Elliot"
        )
        repo.isEnabled = enabled
        try await store.saveRepo(repo)
        return Fixture(
            store: store, board: board, analysis: analysis,
            handler: MCPRequestHandler(store: store, board: board, analysis: analysis),
            spy: spy, repo: repo
        )
    }
}

/// Unwraps a refusal, so a test that expected one but got an `.ok` says so
/// instead of falling through and passing.
private func failureOf(
    _ response: ElliotResponse
) -> (code: ElliotErrorCode, message: String, hint: String?)? {
    guard case .failure(let code, let message, let hint) = response else { return nil }
    return (code, message, hint)
}

@Suite("MCP request handler")
struct MCPRequestHandlerTests {

    @Test("hello answers with the server's own version")
    func hello() async throws {
        let f = try await Fixture.make()
        let response = await f.handler.handle(
            .hello(protocolVersion: elliotProtocolVersion, token: "t", client: "tests")
        )
        guard case .ok(.hello(let serverVersion)) = response else {
            Issue.record("expected .hello, got \(response)")
            return
        }
        #expect(serverVersion == ElliotBuild.version)
    }

    @Test("listCards with no repo names every card; a known name narrows it")
    func listCardsFilters() async throws {
        let f = try await Fixture.make()
        var other = Repo(path: "/tmp/other", nameWithOwner: "phmatray/Other", displayName: "Other")
        other.isEnabled = true
        try await f.store.saveRepo(other)
        _ = try await f.board.createCard(repoID: f.repo.id, title: "Here", body: "")
        _ = try await f.board.createCard(repoID: other.id, title: "There", body: "")

        guard case .ok(.cards(let all)) = await f.handler.handle(
            .listCards(repo: nil, column: nil, limit: 0)
        ) else {
            Issue.record("expected a page for every repo")
            return
        }
        #expect(all.total == 2)

        guard case .ok(.cards(let mine)) = await f.handler.handle(
            .listCards(repo: "phmatray/Elliot", column: nil, limit: 0)
        ) else {
            Issue.record("expected a page for one repo")
            return
        }
        #expect(mine.total == 1)
        #expect(mine.cards.first?.title == "Here")
    }

    @Test("An unknown repository is refused, not answered as if it were every repository")
    func unknownRepoIsRefused() async throws {
        let f = try await Fixture.make()
        _ = try await f.board.createCard(repoID: f.repo.id, title: "Here", body: "")

        let refusal = try #require(
            failureOf(await f.handler.handle(.listCards(repo: "nope/nope", column: nil, limit: 0)))
        )
        #expect(refusal.code == .repoNotFound)
        #expect(refusal.hint?.contains("phmatray/Elliot") == true)
    }

    @Test("getCard on an unknown id refuses")
    func getCardUnknown() async throws {
        let f = try await Fixture.make()
        let refusal = try #require(failureOf(await f.handler.handle(.getCard(id: UUID()))))
        #expect(refusal.code == .cardNotFound)
    }

    @Test("listRuns on an unknown card is an error, not an empty page")
    func listRunsUnknownCard() async throws {
        let f = try await Fixture.make()
        let refusal = try #require(
            failureOf(await f.handler.handle(.listRuns(cardID: UUID(), limit: 0)))
        )
        #expect(refusal.code == .cardNotFound)
    }

    @Test("listRepos names the registered repositories")
    func listRepos() async throws {
        let f = try await Fixture.make()
        guard case .ok(.repos(let repos)) = await f.handler.handle(.listRepos) else {
            Issue.record("expected repos")
            return
        }
        #expect(repos.map(\.nameWithOwner) == ["phmatray/Elliot"])
    }

    @Test("createCard is idempotent under a repeated key")
    func createCardIdempotent() async throws {
        let f = try await Fixture.make()
        let first = await f.handler.handle(.createCard(
            repo: "phmatray/Elliot", title: "Run log", body: "",
            story: nil, column: .backlog, idempotencyKey: "k1"
        ))
        guard case .ok(.created(let a)) = first else {
            Issue.record("expected .created, got \(first)")
            return
        }
        #expect(a.alreadyExisted == false)

        let second = await f.handler.handle(.createCard(
            repo: "phmatray/Elliot", title: "Run log", body: "",
            story: nil, column: .backlog, idempotencyKey: "k1"
        ))
        guard case .ok(.created(let b)) = second else {
            Issue.record("expected .created, got \(second)")
            return
        }
        #expect(b.alreadyExisted == true)
        #expect(b.card.id == a.card.id)
        #expect(try await f.store.cardCount(repoID: f.repo.id, column: nil) == 1)
    }

    @Test("A filed card refuses edits with its own code, and is left untouched")
    func updateRefusedOnceFiled() async throws {
        let f = try await Fixture.make()
        var card = try await f.board.createCard(
            repoID: f.repo.id, title: "Run log", body: "original"
        ).card
        card.issueNumber = 42
        try await f.store.saveCard(card)

        let refusal = try #require(failureOf(await f.handler.handle(
            .updateCard(id: card.id, title: "changed", body: "changed", story: nil)
        )))
        // Not `.readOnly`: an agent told "read only" retries when Elliot comes
        // up, and this refusal never clears.
        #expect(refusal.code == .cardAlreadyFiled)
        #expect(refusal.message.contains("42"))
        #expect(try await f.store.card(id: card.id)?.body == "original")
    }

    @Test("Backlog to To Do moves the card and names the skill it started")
    func moveStartsCreateIssue() async throws {
        let f = try await Fixture.make()
        let card = try await f.board.createCard(
            repoID: f.repo.id,
            title: "Run log",
            story: UserStory(
                role: "developer",
                want: "to see the run log inside the card",
                benefit: "I can diagnose without a terminal"
            )
        ).card

        guard case .ok(.moved(let moved)) = await f.handler.handle(
            .moveCard(id: card.id, to: .todo, followUps: [])
        ) else {
            Issue.record("expected .moved")
            return
        }
        #expect(moved.from == Column.backlog.rawValue)
        #expect(moved.to == Column.todo.rawValue)
        #expect(moved.triggered == "create-issue")
        #expect(moved.runID != nil)
        #expect(try await f.store.card(id: card.id)?.column == .todo)
    }

    @Test("A blocked move refuses in the same words board_next predicts")
    func moveBlockedSpeaksTheSharedText() async throws {
        let f = try await Fixture.make()
        let card = try await f.board.createCard(
            repoID: f.repo.id, title: "Run log", body: "b"
        ).card

        let sameColumn = try #require(failureOf(await f.handler.handle(
            .moveCard(id: card.id, to: .backlog, followUps: [])
        )))
        #expect(sameColumn.code == .moveBlocked)
        #expect(sameColumn.message == MoveBlockText.explain(.sameColumn))
    }

    @Test("moveCard on an unknown card refuses")
    func moveUnknownCard() async throws {
        let f = try await Fixture.make()
        let refusal = try #require(failureOf(await f.handler.handle(
            .moveCard(id: UUID(), to: .todo, followUps: [])
        )))
        #expect(refusal.code == .cardNotFound)
    }

    @Test("awaitRun on an unknown id refuses and says where runs are listed")
    func awaitUnknownRun() async throws {
        let f = try await Fixture.make()
        let refusal = try #require(failureOf(await f.handler.handle(
            .awaitRun(id: UUID(), timeoutSeconds: 1)
        )))
        #expect(refusal.code == .runNotFound)
        #expect(refusal.hint?.contains("board_list_runs") == true)
    }

    @Test("awaitRun timing out is not an error: it returns the run as it stands")
    func awaitTimesOutWithTheRun() async throws {
        let f = try await Fixture.make()
        let card = try await f.board.createCard(
            repoID: f.repo.id,
            title: "Run log",
            story: UserStory(role: "developer", want: "a log", benefit: "I can diagnose")
        ).card
        guard case .moved(let runID?) = try await f.board.move(
            cardID: card.id, to: .todo, origin: .userDrag
        ) else {
            Issue.record("expected a queued run")
            return
        }

        // Bounded: the handler clamps 1 second to 1 second, and nothing here
        // ever completes the run, so this must return on the timeout path.
        let response = try await withTimeout(.seconds(20)) {
            await f.handler.handle(.awaitRun(id: runID, timeoutSeconds: 1))
        }
        guard case .ok(.run(let run)) = response else {
            Issue.record("a timeout is not an error; got \(response)")
            return
        }
        #expect(run.id == runID)
        #expect(run.isTerminal == false)
    }

    @Test("cancelRun on an unknown id refuses")
    func cancelUnknownRun() async throws {
        let f = try await Fixture.make()
        let refusal = try #require(failureOf(await f.handler.handle(.cancelRun(id: UUID()))))
        #expect(refusal.code == .runNotFound)
    }

    @Test("Cancelling a queued run answers with the run, not with a bare success")
    func cancelQueuedRun() async throws {
        let f = try await Fixture.make()
        let card = try await f.board.createCard(
            repoID: f.repo.id,
            title: "Run log",
            story: UserStory(role: "developer", want: "a log", benefit: "I can diagnose")
        ).card
        guard case .moved(let runID?) = try await f.board.move(
            cardID: card.id, to: .todo, origin: .userDrag
        ) else {
            Issue.record("expected a queued run")
            return
        }

        guard case .ok(.run(let run)) = await f.handler.handle(.cancelRun(id: runID)) else {
            Issue.record("expected the cancelled run back")
            return
        }
        #expect(run.id == runID)
        #expect(run.state == RunState.cancelling.rawValue || run.state == RunState.cancelled.rawValue)
    }

    @Test("next ranks the board and refuses an unknown repository")
    func nextRanksAndRefuses() async throws {
        let f = try await Fixture.make()
        _ = try await f.board.createCard(
            repoID: f.repo.id,
            title: "Ready",
            story: UserStory(role: "developer", want: "a log", benefit: "I can diagnose")
        )

        guard case .ok(.next(let page)) = await f.handler.handle(.next(repo: nil, limit: 0)) else {
            Issue.record("expected a next page")
            return
        }
        #expect(page.items.first?.rank == 1)
        #expect(page.total >= 1)

        let refusal = try #require(failureOf(await f.handler.handle(.next(repo: "nope/nope", limit: 0))))
        #expect(refusal.code == .repoNotFound)
    }
}
