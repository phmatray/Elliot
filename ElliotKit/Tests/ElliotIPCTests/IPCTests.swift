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

    /// The limit is the platform's, so it is asserted as a range rather than as
    /// 104: pinning the number would make this suite the thing that has to be
    /// edited when Darwin changes it, and `MemoryLayout` already knows.
    @Test("sun_path's size is read from the platform, not hard-coded")
    func maxPathBytesIsThePlatformLimit() {
        #expect(UnixSocket.maxPathBytes > 100)
        #expect(UnixSocket.maxPathBytes < 110)
    }

    /// `<`, not `<=`. `strcpy` writes a terminating NUL, so a path of exactly
    /// `maxPathBytes` needs one byte the field does not have — and this is the
    /// off-by-one that would let `pathFits` say yes to a path `bind` then
    /// refuses, which is the whole reason the two share one expression.
    @Test("A path fits by its bytes, one short of the field")
    func pathFitsMeasuresBytesAndLeavesRoomForTheTerminator() {
        #expect(UnixSocket.pathFits("/tmp/elliot.sock"))

        let exact = String(repeating: "a", count: UnixSocket.maxPathBytes)
        #expect(exact.utf8.count == UnixSocket.maxPathBytes)
        #expect(!UnixSocket.pathFits(exact))
        #expect(UnixSocket.pathFits(String(exact.dropLast())))

        // Bytes, not characters: `é` is two bytes in UTF-8, so a path of
        // `maxPathBytes` of them is half the *characters* and twice the limit.
        // Counting `.count` here would call it comfortably short.
        let accented = String(repeating: "é", count: UnixSocket.maxPathBytes / 2)
        #expect(accented.count < UnixSocket.maxPathBytes)
        #expect(!UnixSocket.pathFits(accented))
    }

    // MARK: - Why a path is unbindable (#193)

    /// A scratch directory that removes itself. Real filesystem rather than a
    /// stub: the whole claim is about what `bind` would meet, and a stub would
    /// assert that this function agrees with a *model* of the filesystem rather
    /// than with the filesystem.
    ///
    /// ⚠️ **Under `/tmp`, not `NSTemporaryDirectory()`, and that is the subject
    /// of these tests biting the tests themselves.** macOS returns a per-user
    /// `/var/folders/hp/xyc…/T/` path; add a UUID and a filename and every case
    /// below comes back `.tooLong(bytes: 116…128)` before it can reach the cause
    /// it means to assert — measured, all five at once. It is the same reason
    /// `CLAUDE.md` insists a scratch `ELLIOT_HOME` be `/tmp/elliot-check`: the
    /// obvious temporary directory does not fit in `sun_path`.
    private func withScratch(_ body: (String) throws -> Void) throws {
        let root = "/tmp/eo-" + UUID().uuidString.prefix(8)
        try FileManager.default.createDirectory(
            atPath: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: root) }
        try body(root)
    }

    @Test("A healthy directory has no obstruction")
    func aUsablePathIsNotObstructed() throws {
        try withScratch { root in
            #expect(UnixSocket.obstruction(to: root + "/elliot.sock") == nil)
        }
    }

    /// #168's cause, now one case of four rather than the only one measured.
    @Test("Too long is reported with both numbers, so the reader can see the margin")
    func tooLongCarriesItsMeasurements() {
        let long = "/tmp/" + String(repeating: "a", count: UnixSocket.maxPathBytes)
        #expect(
            UnixSocket.obstruction(to: long)
                == .tooLong(bytes: long.utf8.count, limit: UnixSocket.maxPathBytes))
    }

    /// The cause #193 is about: every one of these used to fall through to
    /// "does something answer at this path", whose "no" is the same "no" an app
    /// that was never launched gives.
    @Test("A missing directory is named as missing, not as an absent app")
    func aMissingDirectoryIsNamed() throws {
        try withScratch { root in
            let absent = root + "/no-such-dir"
            #expect(UnixSocket.obstruction(to: absent + "/elliot.sock") == .directoryMissing(absent))
        }
    }

    @Test("A file where the directory should be is named as not a directory")
    func aFileInTheWayIsNamed() throws {
        try withScratch { root in
            let file = root + "/imposter"
            try Data().write(to: URL(filePath: file))
            #expect(UnixSocket.obstruction(to: file + "/elliot.sock") == .notADirectory(file))
        }
    }

    @Test("A read-only directory is named as not writable")
    func aReadOnlyDirectoryIsNamed() throws {
        try withScratch { root in
            let locked = root + "/locked"
            try FileManager.default.createDirectory(
                atPath: locked, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o500])
            defer {
                try? FileManager.default.setAttributes(
                    [.posixPermissions: 0o700], ofItemAtPath: locked)
            }
            #expect(
                UnixSocket.obstruction(to: locked + "/elliot.sock")
                    == .directoryNotWritable(locked))
        }
    }

    /// ⛔ The one that decides whether this guard may run ahead of "is the app
    /// up" at all — #193's fourth criterion, and the reason the socket-file
    /// check is not an optimisation.
    ///
    /// A bound socket needs its *directory* writable only at bind time;
    /// `connect` needs no such thing. So a directory whose permissions changed
    /// after launch describes an app that is running and answering — and a
    /// probe that reported it unusable would invert the very answer this whole
    /// mechanism exists to get right, more confidently than the bug it replaces.
    @Test("A socket that exists is never called unusable, whatever its directory now says")
    func aBoundSocketSurvivesAnUnwritableDirectory() throws {
        try withScratch { root in
            let directory = root + "/live"
            try FileManager.default.createDirectory(
                atPath: directory, withIntermediateDirectories: true)
            let socket = directory + "/elliot.sock"
            try Data().write(to: URL(filePath: socket))
            // The directory becomes unwritable *after* the socket exists, which
            // is the only ordering that can produce the false refusal.
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o500], ofItemAtPath: directory)
            defer {
                try? FileManager.default.setAttributes(
                    [.posixPermissions: 0o700], ofItemAtPath: directory)
            }

            #expect(
                UnixSocket.obstruction(to: socket) == nil,
                """
                the socket is right there and something bound it, yet the probe called the path \
                unusable — that refuses a live app by reading its directory's permissions, which \
                connect() never consults
                """
            )
        }
    }

    /// The guard and the check are one expression, so a caller that asks
    /// `pathFits` first can never be told yes by a path `makeAddress` rejects.
    @Test("What pathFits refuses is exactly what binding refuses")
    func bindAgreesWithPathFits() {
        let tooLong = "/tmp/" + String(repeating: "x", count: UnixSocket.maxPathBytes)
        #expect(!UnixSocket.pathFits(tooLong))
        #expect(throws: SocketError.self) { try UnixSocket.makeAddress(path: tooLong) }

        let fits = temporarySocketPath()
        #expect(UnixSocket.pathFits(fits))
        #expect(throws: Never.self) { try UnixSocket.makeAddress(path: fits) }
    }

    // MARK: - A merged outcome names its pull request on the wire too (#139)

    /// The DTO already had `number`, `url` and `branch` for `pr_open`; what was
    /// missing was the two cases passing them through. A helper that renders a
    /// Done card's receipt has no other source for them.
    @Test("A merged outcome carries its number, URL and branch through the DTO")
    func mergedCarriesItsPullRequestOverTheWire() throws {
        let dto = VerifiedOutcomeDTO(
            .merged(
                commitSHA: "abc1234", number: 42,
                url: "https://github.com/o/r/pull/42", branch: "feat/7-x"
            )
        )

        #expect(dto.kind == "merged")
        #expect(dto.commitSHA == "abc1234")
        #expect(dto.number == 42)
        #expect(dto.url == "https://github.com/o/r/pull/42")
        #expect(dto.branch == "feat/7-x")

        // And it survives the encode/decode the wire actually performs.
        let round = try JSONDecoder().decode(
            VerifiedOutcomeDTO.self, from: JSONEncoder().encode(dto)
        )
        #expect(round == dto)
    }

    @Test("A closed-unmerged outcome carries its number, URL and branch too")
    func closedUnmergedCarriesItsPullRequestOverTheWire() {
        let dto = VerifiedOutcomeDTO(
            .closedUnmerged(
                number: 42, url: "https://github.com/o/r/pull/42", branch: "feat/7-x"
            )
        )

        #expect(dto.kind == "closed_unmerged")
        #expect(dto.number == 42)
        #expect(dto.url == "https://github.com/o/r/pull/42")
        #expect(dto.branch == "feat/7-x")
    }

    /// `VerifiedOutcome` crosses the wire, so widening two of its cases is a
    /// wire-format change: an old helper in an old bundle must be refused at
    /// `hello` rather than silently rendering a receipt with no pull request.
    ///
    /// The plan for #139 said "4 → 5"; `main` had already reached 6 by the time
    /// it was executed, and writing 5 would have *lowered* the version and
    /// readmitted exactly the helpers the bump exists to refuse.
    ///
    /// It happened again at 8: #288's plan said "bump from 6", against a base
    /// that had reached 7. This is the assertion that turns that mistake into a
    /// red test rather than a version silently standing still — so when it
    /// fails, **read `Protocol.swift` and raise both**, never lower the
    /// constant to match the number written here.
    /// And again at 9: `RepoDTO` gained `extraAllowedTools` (#333), the other
    /// half of the terms a run gets. Until then neither term could be *written*,
    /// so every row reported the same defaults and a reply carrying half of them
    /// was indistinguishable from the whole.
    @Test("Widening the outcome, attributing closing text, and reporting run terms, bumped it")
    func protocolVersionIsNine() {
        #expect(elliotProtocolVersion == 9)
    }
}
