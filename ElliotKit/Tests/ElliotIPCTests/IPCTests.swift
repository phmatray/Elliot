import ElliotModel
import Foundation
import Testing

@testable import ElliotIPC

private func temporarySocketPath() -> String {
    // Kept short: sun_path is 104 bytes and the default temp directory is long.
    "/tmp/elliot-\(UUID().uuidString.prefix(8)).sock"
}

private let token = "test-token"

/// Captures what the handler was asked for, across the concurrency boundary.
private actor RequestRecorder {
    private(set) var last: ElliotRequest?
    func record(_ request: ElliotRequest) { last = request }
}

private func makeServer(
    path: String,
    handler: @escaping IPCServer.Handler
) throws -> IPCServer {
    let server = IPCServer(socketPath: path, token: token, handler: handler)
    try server.start()
    return server
}

private func card(title: String = "Run log", column: ElliotModel.Column = .backlog) -> Card {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    return Card(
        repoID: UUID(), title: title, column: column,
        columnEnteredAt: now, createdAt: now, updatedAt: now
    )
}

@Suite("IPC", .serialized)
struct IPCTests {

    @Test("A request round-trips over the socket")
    func roundTrip() throws {
        let path = temporarySocketPath()
        let server = try makeServer(path: path) { request in
            guard case .listCards = request else {
                return .failure(code: .internalError, message: "unexpected", hint: nil)
            }
            return .ok(.cards([CardDTO(card: card(), repoName: "phmatray/Elliot")]))
        }
        defer { server.stop() }

        let client = IPCClient(socketPath: path, token: token)
        let response = try client.send(.listCards(repo: nil, column: nil, limit: 50))

        guard case .ok(.cards(let cards)) = response else {
            Issue.record("expected cards, got \(response)")
            return
        }
        #expect(cards.count == 1)
        #expect(cards[0].title == "Run log")
        #expect(cards[0].repo == "phmatray/Elliot")
    }

    @Test("A user story survives the wire in its three parts")
    func storyRoundTrip() async throws {
        let path = temporarySocketPath()
        let stored = RequestRecorder()
        let server = try makeServer(path: path) { request in
            await stored.record(request)
            var c = card()
            c.story = UserStory(
                role: "developer", want: "the run log", benefit: "faster diagnosis",
                acceptanceCriteria: ["streams live"]
            )
            return .ok(.card(CardDTO(card: c, repoName: "phmatray/Elliot")))
        }
        defer { server.stop() }

        let client = IPCClient(socketPath: path, token: token)
        let response = try client.send(.createCard(
            repo: "phmatray/Elliot",
            title: "Run log",
            body: "",
            story: .init(
                role: "developer", want: "the run log", benefit: "faster diagnosis",
                acceptanceCriteria: ["streams live"]
            ),
            column: .backlog
        ))

        guard case .createCard(_, _, _, let input?, _) = await stored.last else {
            Issue.record("story did not survive the request")
            return
        }
        #expect(input.role == "developer")
        #expect(input.story.narrative == "As a developer, I want the run log, so that faster diagnosis.")

        guard case .ok(.card(let dto)) = response else {
            Issue.record("expected a card")
            return
        }
        #expect(dto.story?.acceptanceCriteria == ["streams live"])
        #expect(dto.story?.narrative.hasPrefix("As a developer") == true)
    }

    @Test("A refused move comes back with a code the agent can act on")
    func blockedMove() throws {
        let path = temporarySocketPath()
        let server = try makeServer(path: path) { _ in
            .failure(
                code: .moveBlocked,
                message: "The card has no issue number.",
                hint: "Move it Backlog → To Do first to file one."
            )
        }
        defer { server.stop() }

        let client = IPCClient(socketPath: path, token: token)
        let response = try client.send(.moveCard(id: UUID(), to: .inProgress, followUps: []))

        guard case .failure(let code, _, let hint) = response else {
            Issue.record("expected a failure")
            return
        }
        #expect(code == .moveBlocked)
        #expect(hint?.contains("Backlog") == true)
    }

    @Test("A bad token is refused")
    func unauthorized() throws {
        let path = temporarySocketPath()
        let server = try makeServer(path: path) { _ in
            .ok(.cards([]))
        }
        defer { server.stop() }

        let client = IPCClient(socketPath: path, token: "wrong-token")
        let response = try client.send(.listCards(repo: nil, column: nil, limit: 10))
        guard case .failure(let code, _, _) = response else {
            Issue.record("expected a failure")
            return
        }
        #expect(code == .unauthorized)
    }

    @Test("A helper speaking an older protocol is told to re-register")
    func protocolMismatch() throws {
        let path = temporarySocketPath()
        let server = try makeServer(path: path) { _ in .ok(.cards([])) }
        defer { server.stop() }

        let fd = try UnixSocket.connect(path: path)
        defer { close(fd) }
        try UnixSocket.write(fd: fd, data: WireCodec.encodeLine(Envelope(
            body: ElliotRequest.hello(protocolVersion: 999, token: token, client: "old-helper")
        )))
        let line = try #require(UnixSocket.readLine(fd: fd))
        let response = try WireCodec.decode(Envelope<ElliotResponse>.self, from: line).body

        guard case .failure(let code, _, let hint) = response else {
            Issue.record("expected a failure")
            return
        }
        #expect(code == .protocolMismatch)
        #expect(hint?.contains("re-register") == true || hint?.contains("Re-register") == true)
    }

    @Test("The app is reported as not running when no socket is live")
    func appNotRunning() {
        let client = IPCClient(socketPath: temporarySocketPath(), token: token)
        #expect(!client.isAppRunning())
        #expect(throws: (any Error).self) {
            try client.send(.listCards(repo: nil, column: nil, limit: 10))
        }
    }

    @Test("A stale socket file left by a crash does not block a restart")
    func staleSocketIsCleanedUp() throws {
        let path = temporarySocketPath()
        FileManager.default.createFile(atPath: path, contents: Data())
        defer { try? FileManager.default.removeItem(atPath: path) }

        #expect(!UnixSocket.isLive(path: path))
        let server = try makeServer(path: path) { _ in .ok(.cards([])) }
        defer { server.stop() }
        #expect(UnixSocket.isLive(path: path))
    }

    @Test("A second Elliot refuses to take over a live socket")
    func doubleStartRefused() throws {
        let path = temporarySocketPath()
        let first = try makeServer(path: path) { _ in .ok(.cards([])) }
        defer { first.stop() }

        let second = IPCServer(socketPath: path, token: token) { _ in .ok(.cards([])) }
        #expect(throws: IPCServer.StartError.self) { try second.start() }
    }

    @Test("Several requests can share one connection")
    func multipleRequestsPerConnection() throws {
        let path = temporarySocketPath()
        let server = try makeServer(path: path) { _ in .ok(.cards([])) }
        defer { server.stop() }

        let fd = try UnixSocket.connect(path: path)
        defer { close(fd) }
        try UnixSocket.write(fd: fd, data: WireCodec.encodeLine(Envelope(
            body: ElliotRequest.hello(protocolVersion: elliotProtocolVersion, token: token, client: "t")
        )))
        _ = UnixSocket.readLine(fd: fd)

        for _ in 0..<5 {
            try UnixSocket.write(fd: fd, data: WireCodec.encodeLine(Envelope(
                body: ElliotRequest.listCards(repo: nil, column: nil, limit: 1)
            )))
            let line = try #require(UnixSocket.readLine(fd: fd))
            let response = try WireCodec.decode(Envelope<ElliotResponse>.self, from: line).body
            guard case .ok = response else {
                Issue.record("expected ok")
                return
            }
        }
    }

    @Test("A large payload survives framing")
    func largePayload() throws {
        let path = temporarySocketPath()
        let many = (0..<500).map { CardDTO(card: card(title: "Card \($0)"), repoName: "phmatray/Elliot") }
        let server = try makeServer(path: path) { _ in .ok(.cards(many)) }
        defer { server.stop() }

        let client = IPCClient(socketPath: path, token: token)
        let response = try client.send(.listCards(repo: nil, column: nil, limit: 500))
        guard case .ok(.cards(let cards)) = response else {
            Issue.record("expected cards")
            return
        }
        #expect(cards.count == 500)
        #expect(cards.last?.title == "Card 499")
    }

    @Test("Malformed input is answered, not fatal")
    func malformedRequest() throws {
        let path = temporarySocketPath()
        let server = try makeServer(path: path) { _ in .ok(.cards([])) }
        defer { server.stop() }

        let fd = try UnixSocket.connect(path: path)
        defer { close(fd) }
        try UnixSocket.write(fd: fd, data: Data("this is not json\n".utf8))
        let line = try #require(UnixSocket.readLine(fd: fd))
        let response = try WireCodec.decode(Envelope<ElliotResponse>.self, from: line).body
        guard case .failure(let code, _, _) = response else {
            Issue.record("expected a failure")
            return
        }
        #expect(code == .internalError)
    }

    @Test("A token is created once and then reused")
    func tokenPersistence() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("elliot-token-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("ipc.token")

        let first = try IPCServer.loadOrCreateToken(at: url)
        #expect(first.count == 64)
        #expect(try IPCServer.loadOrCreateToken(at: url) == first)
        #expect(IPCClient.readToken(at: url) == first)

        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        #expect(attributes[.posixPermissions] as? Int == 0o600)
    }
}
