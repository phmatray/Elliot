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
    private(set) var launched: [UUID] = []
    func launch(runID: UUID) async { launched.append(runID) }
    func cancel(runID: UUID) async {}
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
        let spy = LaunchSpy()
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
}
