import ElliotIPC
import ElliotModel
import ElliotStore
import Foundation
import MCP
import TestSupport
import Testing

@testable import ElliotMCPKit

/// What the helper refuses, and what it says instead of an empty answer.
@Suite("Refusing from a snapshot")
struct SnapshotRefusalTests {

    @Test("A card id nothing matches is refused, not answered with an empty run list")
    func unknownCardOnListRuns() async throws {
        // The running app refuses this, and the two paths have to agree: "this
        // card has no runs yet" tells an agent to keep polling, and there is
        // nothing to poll for. Same defect as answering an unknown repository
        // with the whole board, one tool over.
        let repo = makeRepo()
        let card = makeCard(repoID: repo.id)
        let store = try await makeStore(repos: [repo], cards: [card])
        let server = ElliotMCPServer(bridge: StubBridge.snapshot(store))

        let answer = try await call(
            server, "board_list_runs", ["card_id": .string(UUID().uuidString)]
        )

        #expect(answer.isError)
        #expect(answer.error == ElliotErrorCode.cardNotFound.rawValue)
        #expect(answer["runs"] == nil)

        // The control: a card that exists with no runs is an empty page, not a
        // refusal. Without this, refusing everything would pass the test above.
        let empty = try await call(
            server, "board_list_runs", ["card_id": .string(card.id.uuidString)]
        )
        #expect(!empty.isError)
        #expect(empty["total"]?.intValue == 0)
    }

    @Test("A card that already carries its issue is not said to be waiting on a pull request")
    func alreadyFiledCardIsDescribedHonestly() async throws {
        // `.noAction` covers two different pieces of news, and the snapshot path
        // used to give both of them the in-flight one: "Elliot moves this card
        // itself when it notices the pull request is ready". For a backlog card
        // that already has an issue number there is no pull request and nothing
        // will ever move it, so an agent that believed the sentence would stop.
        let repo = makeRepo()
        let filed = makeCard(repoID: repo.id, title: "Already filed", column: .backlog, issueNumber: 42)
        let store = try await makeStore(repos: [repo], cards: [filed])

        let answer = try await call(ElliotMCPServer(bridge: StubBridge.snapshot(store)), "board_next")

        let item = try #require(answer["items"]?[0])
        #expect(item["blockCode"]?.stringValue == NextBlockCode.nothingToTrigger)
        #expect(item["blockReason"]?.stringValue?.contains("pull request") == false)
        #expect(item["blockReason"]?.stringValue?.contains("already carries") == true)
    }

    @Test("A limit below one is refused rather than read as the default")
    func negativeLimitIsRefused() async throws {
        // `limit: remaining - seen` going negative would otherwise answer a
        // hundred rows under isError: false, with `limit` and `truncated`
        // describing a page nobody asked for.
        for tool in ["board_list_cards", "board_list_runs", "board_next"] {
            let answer = try await call(
                ElliotMCPServer(bridge: StubBridge()), tool, ["limit": .int(-5)]
            )
            #expect(answer.isError, "\(tool)")
            #expect(answer.error == "bad_argument", "\(tool)")
            #expect(answer.message.contains("limit"), "\(tool)")
        }
    }
}

/// What the helper says when the file it can read is not a board it can read.
@Suite("Opening a database this helper does not understand")
struct SnapshotOpenFailureTests {

    @Test("A newer schema is named as a version skew, not as Elliot being down")
    func schemaTooNewIsNotAppUnavailable() {
        // "Elliot is not running — open Elliot.app" is precisely the action that
        // does not help here: launching the app makes reads work by going live
        // and teaches nobody that the helper is stale.
        guard case .failure(let code, let message, let hint) =
            AppBridge.failure(for: StoreError.schemaTooNew)
        else {
            Issue.record("expected a refusal")
            return
        }

        #expect(code == .protocolMismatch)
        #expect(message.contains("newer version of Elliot"))
        #expect(hint?.contains("claude mcp add") == true)
    }

    @Test("A board that was never set up says to open the app once")
    func schemaMissingSaysWhatToDo() {
        guard case .failure(let code, let message, _) =
            AppBridge.failure(for: StoreError.schemaMissing)
        else {
            Issue.record("expected a refusal")
            return
        }

        #expect(code == .appUnavailable)
        #expect(message.contains("has not been set up"))
    }

    @Test("Any other failure still says the database could not be opened")
    func otherFailuresAreStillReported() {
        guard case .failure(let code, let message, _) =
            AppBridge.failure(for: StoreError.readOnly)
        else {
            Issue.record("expected a refusal")
            return
        }

        #expect(code == .appUnavailable)
        #expect(message.contains("could not be opened"))
    }
}

/// What the helper says when the socket could never have existed.
///
/// The defect (#168): `AppBridge` decided everything from `isAppRunning()`,
/// which asks "does something answer at this path". A path over `sun_path`'s
/// limit is one the app could not bind, so nothing answers — and the helper
/// reported "Elliot is not running" for an app whose window the reader was
/// looking at. Told that, the reasonable next action is to launch Elliot, which
/// does nothing, and the second failure looks exactly like the first.
///
/// ⛔ Every bridge here is built with a bundle identifier no app claims. A test
/// that reached `launchAppAndWait` with the real one would launch Elliot on the
/// machine running the suite.
@Suite("A socket path that cannot be bound", .serialized)
struct UnusableSocketPathTests {

    /// `AppBridge.init` resolves `StoreLocation.tokenURL`, so the shared home has
    /// to be settled before the first one is built — this suite shares a process
    /// with ones that write there.
    init() { _ = TestHome.root }

    private static let noSuchApp = "dev.phmatray.elliot.tests.no-such-bundle"

    /// Two hundred characters: comfortably over the limit on any platform, and
    /// close to the ~145 an agent's scratchpad home actually measured in #155.
    private static let overlongPath =
        "/tmp/" + String(repeating: "elliot-scratch/", count: 13) + "ipc.sock"

    private func shortPath() -> String {
        "/tmp/elliot-\(UUID().uuidString.prefix(8)).sock"
    }

    @Test("A read refuses with the length, and does not blame an absent app")
    func readNamesTheLengthRatherThanBlamingTheApp() async {
        let path = Self.overlongPath
        #expect(path.utf8.count > UnixSocket.maxPathBytes)

        let bridge = AppBridge(socketPath: path, token: "t", bundleIdentifier: Self.noSuchApp)
        guard case .failure(let code, let message, let hint) = await bridge.read(.listRepos).response
        else {
            Issue.record("expected a refusal")
            return
        }

        #expect(code == .appUnavailable)
        #expect(message.contains("\(path.utf8.count)"))
        #expect(message.contains("\(UnixSocket.maxPathBytes)"))
        #expect(message.contains(path))
        // The whole point. The old answer was true about the socket and false
        // about the app, and only the false half was actionable.
        #expect(!message.contains("is not running"))
        #expect(hint?.contains("ELLIOT_HOME") == true)
    }

    /// A read must **not** fall back to the snapshot here. The database is
    /// perfectly readable, so a snapshot answer would be correct data under a
    /// false explanation — the same defect one layer down, and harder to see
    /// because the rows would look right.
    @Test("A read refuses rather than serving the snapshot under a false reason")
    func readDoesNotFallBackToTheSnapshot() async {
        let outcome = await AppBridge(
            socketPath: Self.overlongPath, token: "t", bundleIdentifier: Self.noSuchApp
        ).read(.listRepos)

        #expect(outcome.snapshotReason == nil)
    }

    @Test("A write refuses with the same words, and never tries to launch anything")
    func writeNamesTheLengthToo() async {
        let path = Self.overlongPath
        let bridge = AppBridge(socketPath: path, token: "t", bundleIdentifier: Self.noSuchApp)

        guard case .failure(let code, let message, let hint) =
            await bridge.write(.moveCard(id: UUID(), to: .todo, followUps: []))
        else {
            Issue.record("expected a refusal")
            return
        }

        #expect(code == .appUnavailable)
        #expect(message.contains("\(path.utf8.count)"))
        #expect(message.contains("\(UnixSocket.maxPathBytes)"))
        #expect(!message.contains("is not running"))
        #expect(hint?.contains("ELLIOT_HOME") == true)

        // Both halves of the bridge read one guard, so they cannot tell
        // different stories about the same path.
        #expect(await bridge.read(.listRepos).response.refusalMessage == message)
    }

    /// The control, and the reason it is not written as a `write` against a dead
    /// socket: that path polls `launchAppAndWait` for twenty seconds before
    /// answering, and this suite has to terminate promptly. A live server is
    /// both faster and a stronger claim — it proves the ordinary path still
    /// *works*, not merely that it still fails the old way.
    @Test("A path that fits is untouched: a write still reaches a running app")
    func aShortPathStillTalksToTheApp() async throws {
        let path = shortPath()
        let server = IPCServer(socketPath: path, token: "t") { _, _ in .ok(.repos([])) }
        try server.start()
        defer { server.stop() }

        let bridge = AppBridge(socketPath: path, token: "t", bundleIdentifier: Self.noSuchApp)
        let response = await bridge.write(.moveCard(id: UUID(), to: .todo, followUps: []))

        guard case .ok = response else {
            Issue.record("expected the write to reach the app, got \(response)")
            return
        }
        // And the read half of the same bridge goes live rather than offline.
        #expect(await bridge.read(.listRepos).source == "live")
    }

    /// The ordinary "Elliot is down" story is still told when it is the true
    /// one. Without this, a guard that fired on every path would pass every
    /// assertion above.
    @Test("A path that fits and an app that is down still reads from the snapshot")
    func aShortPathWithNoAppIsTheOldStory() async {
        let outcome = await AppBridge(
            socketPath: shortPath(), token: "t", bundleIdentifier: Self.noSuchApp
        ).read(.listRepos)

        #expect(outcome.response.refusalMessage?.contains("too long") != true)
        // Either the snapshot answered, or the store could not be opened and
        // said so in its own words. What it must not be is the length refusal.
        if let reason = outcome.snapshotReason {
            #expect(reason == .appNotRunning)
        }
    }
}

extension ElliotResponse {
    /// The message of a refusal, or nil for an answer. Only the assertions above
    /// need it, and they need it twice.
    fileprivate var refusalMessage: String? {
        guard case .failure(_, let message, _) = self else { return nil }
        return message
    }
}
