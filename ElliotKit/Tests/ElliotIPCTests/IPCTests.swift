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

/// Captures the client name each dispatch carried, in arrival order.
private actor ClientRecorder {
    private(set) var seen: [String] = []
    func record(_ client: String) { seen.append(client) }
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

/// A whole page of cards, for the stubs that only care that *something* came
/// back. `total` matches the count so nothing reads as truncated by accident.
private func page(_ cards: [CardDTO] = [], limit: Int = ElliotPaging.cardLimitDefault) -> CardPage {
    CardPage(cards: cards, total: cards.count, limit: limit)
}

@Suite("IPC", .serialized)
struct IPCTests {

    /// The name in `hello` has been on the wire since the first protocol
    /// version and `serve` decoded it into `_`. Every MCP move therefore
    /// recorded the literal `"mcp"`, so `MoveOrigin.mcp(client:)` was a field
    /// that existed end to end and said nothing (#101).
    ///
    /// It belongs to the **connection**, not to the server: `send` opens a
    /// socket, greets, asks one question and hangs up, so two helpers talking to
    /// one app must not see each other's name. Asserted with two clients rather
    /// than one, because a single client would pass just as well against a
    /// server that stored the last name it saw in a property.
    @Test("The client named in hello reaches the handler, and does not leak between connections")
    func helloClientReachesTheHandlerPerConnection() async throws {
        let path = temporarySocketPath()
        let seen = ClientRecorder()
        let server = try makeServer(path: path) { _, client in
            await seen.record(client)
            return .ok(.cards(page()))
        }
        defer { server.stop() }

        for name in ["agent-x", "agent-y", "agent-x"] {
            _ = try IPCClient(socketPath: path, token: token, clientName: name)
                .send(.listCards(repo: nil, column: nil, limit: 1))
        }

        #expect(await seen.seen == ["agent-x", "agent-y", "agent-x"])
    }

    @Test("A request round-trips over the socket")
    func roundTrip() throws {
        let path = temporarySocketPath()
        let server = try makeServer(path: path) { request, _ in
            guard case .listCards = request else {
                return .failure(code: .internalError, message: "unexpected", hint: nil)
            }
            return .ok(.cards(page([CardDTO(card: card(), repoName: "phmatray/Elliot")], limit: 50)))
        }
        defer { server.stop() }

        let client = IPCClient(socketPath: path, token: token)
        let response = try client.send(.listCards(repo: nil, column: nil, limit: 50))

        guard case .ok(.cards(let cards)) = response else {
            Issue.record("expected cards, got \(response)")
            return
        }
        #expect(cards.cards.count == 1)
        #expect(cards.cards[0].title == "Run log")
        #expect(cards.cards[0].repo == "phmatray/Elliot")
        #expect(!cards.truncated)
    }

    @Test("A user story survives the wire in its three parts")
    func storyRoundTrip() async throws {
        let path = temporarySocketPath()
        let stored = RequestRecorder()
        let server = try makeServer(path: path) { request, _ in
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
            column: .backlog,
            idempotencyKey: nil
        ))

        guard case .createCard(_, _, _, let input?, _, _) = await stored.last else {
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
        let server = try makeServer(path: path) { _, _ in
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
        let server = try makeServer(path: path) { _, _ in
            .ok(.cards(page()))
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
        let server = try makeServer(path: path) { _, _ in .ok(.cards(page())) }
        defer { server.stop() }

        let fd = try UnixSocket.connect(path: path)
        defer { close(fd) }
        try UnixSocket.write(fd: fd, data: WireCodec.encodeLine(Envelope(
            body: ElliotRequest.hello(protocolVersion: 999, token: token, client: "old-helper")
        )))
        let line = try #require(UnixSocket.LineReader(fd: fd).next())
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
        let server = try makeServer(path: path) { _, _ in .ok(.cards(page())) }
        defer { server.stop() }
        #expect(UnixSocket.isLive(path: path))
    }

    @Test("A second Elliot refuses to take over a live socket")
    func doubleStartRefused() throws {
        let path = temporarySocketPath()
        let first = try makeServer(path: path) { _, _ in .ok(.cards(page())) }
        defer { first.stop() }

        let second = IPCServer(socketPath: path, token: token) { _, _ in .ok(.cards(page())) }
        #expect(throws: IPCServer.StartError.self) { try second.start() }
    }

    @Test("Several requests can share one connection")
    func multipleRequestsPerConnection() throws {
        let path = temporarySocketPath()
        let server = try makeServer(path: path) { _, _ in .ok(.cards(page())) }
        defer { server.stop() }

        let fd = try UnixSocket.connect(path: path)
        defer { close(fd) }
        try UnixSocket.write(fd: fd, data: WireCodec.encodeLine(Envelope(
            body: ElliotRequest.hello(protocolVersion: elliotProtocolVersion, token: token, client: "t")
        )))
        // One reader for the connection, as the client and the server both keep:
        // a buffered read of one frame can already hold the front of the next,
        // and a reader per frame would drop it.
        let reader = UnixSocket.LineReader(fd: fd)
        _ = reader.next()

        for _ in 0..<5 {
            try UnixSocket.write(fd: fd, data: WireCodec.encodeLine(Envelope(
                body: ElliotRequest.listCards(repo: nil, column: nil, limit: 1)
            )))
            let line = try #require(reader.next())
            let response = try WireCodec.decode(Envelope<ElliotResponse>.self, from: line).body
            guard case .ok = response else {
                Issue.record("expected ok")
                return
            }
        }
    }

    @Test("Frames that arrive in one read are handed back one at a time")
    func bufferedFramesAreNotLost() throws {
        // The buffered reader pulls up to 64 KB at a time, so three small frames
        // written together arrive in a single `read()`. Anything that dropped
        // the leftover would lose two requests without a word — and the server
        // reads its whole conversation through one of these.
        var pair: [Int32] = [0, 0]
        #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0)
        // The writing end is closed on purpose below, and a descriptor closed
        // twice is a descriptor another test may have been given in between.
        defer {
            close(pair[0])
            if pair[1] >= 0 { close(pair[1]) }
        }

        try UnixSocket.write(fd: pair[1], data: Data("one\ntwo\nthree\n".utf8))
        let reader = UnixSocket.LineReader(fd: pair[0])

        #expect(reader.next().map { String(decoding: $0, as: UTF8.self) } == "one")
        #expect(reader.next().map { String(decoding: $0, as: UTF8.self) } == "two")
        #expect(reader.next().map { String(decoding: $0, as: UTF8.self) } == "three")

        // A frame split across reads is still one frame.
        try UnixSocket.write(fd: pair[1], data: Data("half".utf8))
        try UnixSocket.write(fd: pair[1], data: Data("-and-half\n".utf8))
        #expect(reader.next().map { String(decoding: $0, as: UTF8.self) } == "half-and-half")

        // End of stream is nil, not an empty frame that decodes to nothing.
        close(pair[1])
        pair[1] = -1
        #expect(reader.next() == nil)
    }

    @Test("A large payload survives framing")
    func largePayload() throws {
        let path = temporarySocketPath()
        let many = (0..<500).map { CardDTO(card: card(title: "Card \($0)"), repoName: "phmatray/Elliot") }
        let server = try makeServer(path: path) { _, _ in .ok(.cards(page(many, limit: 500))) }
        defer { server.stop() }

        let client = IPCClient(socketPath: path, token: token)
        let response = try client.send(.listCards(repo: nil, column: nil, limit: 500))
        guard case .ok(.cards(let cards)) = response else {
            Issue.record("expected cards")
            return
        }
        #expect(cards.cards.count == 500)
        #expect(cards.cards.last?.title == "Card 499")
    }

    @Test("Malformed input is answered, not fatal")
    func malformedRequest() throws {
        let path = temporarySocketPath()
        let server = try makeServer(path: path) { _, _ in .ok(.cards(page())) }
        defer { server.stop() }

        let fd = try UnixSocket.connect(path: path)
        defer { close(fd) }
        try UnixSocket.write(fd: fd, data: Data("this is not json\n".utf8))
        let line = try #require(UnixSocket.LineReader(fd: fd).next())
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
