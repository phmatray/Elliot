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
}
