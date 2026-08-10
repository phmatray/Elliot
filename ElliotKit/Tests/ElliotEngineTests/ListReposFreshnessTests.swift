import ElliotIPC
import ElliotModel
import ElliotProcess
import ElliotStore
import Foundation
import Testing

@testable import ElliotEngine
@testable import ElliotMCPKit

/// Criterion 4 of #333: `board_list_repos` reports a changed mode with no
/// restart.
///
/// It was already true — `.listRepos` re-reads the repo table on every call, so
/// there is no cache that could go stale — and that is exactly why it needed
/// pinning rather than assuming. The claim had never been exercised, because
/// until #333 nothing could change a mode in the first place: every reply
/// reported `bypassPermissions` because every row *was* `bypassPermissions`, and
/// a handler that cached hard would have looked identical.
///
/// Both answers are asserted, live and offline. A setting that decides whether a
/// move starts an agent accepting every tool call is the last one the two
/// branches may disagree about — and `OfflineResponder` is a second
/// implementation by construction, since `ElliotMCPKit` may not import
/// `ElliotEngine`.
@Suite("board_list_repos reads the current terms")
struct ListReposFreshnessTests {

    @Test("A mode saved after the handler was built is in the next reply")
    func theHandlerDoesNotCacheTheMode() async throws {
        let store = try BoardStore.inMemory()
        let repo = Repo(
            path: "/tmp/freshness-\(UUID().uuidString)",
            nameWithOwner: "phmatray/Elliot", displayName: "Elliot"
        )
        try await store.saveRepo(repo)

        let handler = try Self.handler(store: store)
        let responder = OfflineResponder(store: store)

        #expect(try await Self.mode(handler.handle(.listRepos)) == "bypassPermissions")
        #expect(try await Self.mode(responder.respond(to: .listRepos)) == "bypassPermissions")

        // No handler, responder or store is re-created here — this is the whole
        // assertion.
        try await store.saveRepo(RunTermsEdit.mode(.plan).applied(to: repo))

        #expect(try await Self.mode(handler.handle(.listRepos)) == "plan")
        #expect(try await Self.mode(responder.respond(to: .listRepos)) == "plan")
    }

    /// Beyond the four criteria, and separable: the tool's description tells an
    /// agent to read the terms before moving a card, and until now it reported
    /// half of them.
    @Test("The extra allowed tools travel beside the mode, on both branches")
    func toolsTravelWithTheMode() async throws {
        let store = try BoardStore.inMemory()
        let repo = Repo(
            path: "/tmp/freshness-\(UUID().uuidString)",
            nameWithOwner: "phmatray/Elliot", displayName: "Elliot"
        )
        try await store.saveRepo(repo)

        let handler = try Self.handler(store: store)
        let responder = OfflineResponder(store: store)

        // Empty renders as an empty array, never as a missing key: "allows
        // nothing extra" and "this reply does not say" must not look the same.
        #expect(try await Self.tools(handler.handle(.listRepos)) == [])
        #expect(try await Self.tools(responder.respond(to: .listRepos)) == [])

        try await store.saveRepo(
            RunTermsEdit.tools([" Read ", "", "Bash(git status *)"]).applied(to: repo)
        )

        #expect(try await Self.tools(handler.handle(.listRepos))
            == ["Read", "Bash(git status *)"])
        #expect(try await Self.tools(responder.respond(to: .listRepos))
            == ["Read", "Bash(git status *)"])
    }

    // MARK: -

    private static func handler(store: BoardStore) throws -> MCPRequestHandler {
        let config = ToolConfig(
            claudePath: "/usr/bin/false", ghPath: "/usr/bin/false", gitPath: "/usr/bin/false",
            environment: ["PATH": "/usr/bin:/bin"]
        )
        let scheduler = RunScheduler(
            store: store, toolConfig: config, verifier: Verifier(gh: .init(config: config))
        )
        let board = BoardService(store: store, launcher: scheduler)
        return MCPRequestHandler(
            store: store, board: board,
            analysis: AnalysisService(
                store: store, launcher: scheduler, board: board, gh: GHClient(config: config),
                gate: OpenGate()
            )
        )
    }

    private static func repos(_ response: ElliotResponse) throws -> [RepoDTO] {
        guard case .ok(let payload) = response, case .repos(let repos) = payload else {
            throw StoreError.readOnly
        }
        return repos
    }

    private static func mode(_ response: ElliotResponse) throws -> String? {
        try repos(response).first?.permissionMode
    }

    private static func tools(_ response: ElliotResponse) throws -> [String]? {
        try repos(response).first?.extraAllowedTools
    }
}
