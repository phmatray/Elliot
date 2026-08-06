import ElliotIPC
import ElliotModel
import ElliotStore
import Foundation
import MCP
import Testing

@testable import ElliotMCPKit

/// The two reads an agent makes before it does anything: what to do next, and
/// where it is allowed to do it.
///
/// Both are reads, so both survive Elliot being down — and `board_next` ranks
/// from the snapshot through the same pure `rankNextSteps` the app uses, never
/// through a second implementation.
///
/// `OfflineBoardTests` already pins the ranking itself (`readyOutranksBlocked`
/// covers the order, `wouldTrigger`, `blockCode` and `rank`; `reposCarryPermissionMode`
/// covers the offline repository list; `rankedAnswerFromTheApp` covers the live
/// field names). None of that is repeated. What follows is what those leave
/// open: the live path of `board_list_repos`, a repository that is disabled, and
/// the filter argument `board_next` forwards rather than resolves.
@Suite("What to do next, and where")
struct NextAndReposToolTests {

    @Test("The repositories come back from the running app the same way they come back from a snapshot")
    func liveReposMatchTheSnapshotShape() async throws {
        // The two paths build this answer in two different places — one renders
        // the app's `RepoDTO`s, the other maps rows out of the database. A field
        // present on one and absent on the other is a difference an agent reads
        // as "this repository has no default branch" rather than as "I asked the
        // wrong half of the system".
        var repo = makeRepo("phmatray/Elliot")
        repo.permissionMode = .bypassPermissions
        let store = try await makeStore(repos: [repo])

        let offline = try await call(
            ElliotMCPServer(bridge: StubBridge.snapshot(store)), "board_list_repos"
        )
        let live = try await call(
            ElliotMCPServer(bridge: StubBridge.answering(.repos([RepoDTO(repo: repo)]))),
            "board_list_repos"
        )

        #expect(live.source == "live")
        #expect(offline.source == "offline-db")
        // Only the provenance differs. The repository itself is the same object.
        #expect(live["repos"]?[0] == offline["repos"]?[0])
        #expect(live["total"]?.intValue == 1)
        // A live answer has nothing to warn about; the snapshot has to say it is
        // one, or a frozen board reads as a live one.
        #expect(live.note.isEmpty)
        #expect(offline.note.contains("snapshot"))
    }

    @Test("A repository Elliot has been told to leave alone is listed, and listed as disabled")
    func disabledRepositoryIsListedAsDisabled() async throws {
        // Filtering it out would be worse than useless: the cards are still
        // there, `board_create_card` still accepts the name, and every move that
        // would trigger work is refused. An agent that cannot see the repository
        // cannot see why.
        let enabled = makeRepo("phmatray/Elliot")
        let disabled = makeRepo("phmatray/Frozen", isEnabled: false)
        let store = try await makeStore(repos: [enabled, disabled])

        let answer = try await call(
            ElliotMCPServer(bridge: StubBridge.snapshot(store)), "board_list_repos"
        )

        #expect(answer["total"]?.intValue == 2)
        let repos = try #require(answer["repos"]?.arrayValue)
        let frozen = try #require(repos.first { $0["nameWithOwner"]?.stringValue == "phmatray/Frozen" })
        #expect(frozen["isEnabled"]?.boolValue == false)
        #expect(repos.first { $0["nameWithOwner"]?.stringValue == "phmatray/Elliot" }?["isEnabled"]?
            .boolValue == true)
    }

    @Test("board_next hands the repository filter to the app rather than resolving it here")
    func nextForwardsItsFilterUntouched() async throws {
        // The helper holds no copy of the board. Resolving `repo` here — even
        // just deciding it matches nothing — would be a second answer to a
        // question the app already answers, and the two would drift; the offline
        // path has to refuse an unknown name the same way, which is why
        // `OfflineBoard.filter` exists rather than a nil that means "everything".
        let log = RequestLog()
        let bridge = StubBridge(onRead: { request in
            log.record(request)
            return .live(.ok(.next(NextPage(items: [], total: 0, limit: 10, readyCount: 0))))
        })

        let answer = try await call(
            ElliotMCPServer(bridge: bridge),
            "board_next",
            ["repo": .string("phmatray/Elliot"), "limit": .int(3)]
        )

        #expect(!answer.isError)
        #expect(answer.source == "live")
        guard case .next(let repo, let limit)? = log.last else {
            Issue.record("the helper did not forward a next request")
            return
        }
        #expect(repo == "phmatray/Elliot")
        // Unclamped, for the reason `board_list_cards` sends its limit
        // unclamped: clamp here first and the app can never report that its own
        // cap applied, so the cap becomes silent.
        #expect(limit == 3)
    }
}
