import Foundation

/// The helper's side of the socket.
public struct IPCClient: Sendable {
    private let socketPath: String
    private let token: String
    private let clientName: String

    public init(socketPath: String, token: String, clientName: String = "elliot-mcp") {
        self.socketPath = socketPath
        self.token = token
        self.clientName = clientName
    }

    public func isAppRunning() -> Bool {
        UnixSocket.isLive(path: socketPath)
    }

    /// Opens a connection, greets, and runs one request.
    ///
    /// The deadline comes from the request unless the caller overrides it.
    /// `awaitRun` holds the connection open for minutes on purpose, and a fixed
    /// 30-second socket would hang up on it: `readLine` would return nil, the
    /// caller would read `connectionClosed`, and a run that was still going
    /// would look like a dead app. Letting the request name its own deadline
    /// means no call site has to remember which requests are slow.
    public func send(_ request: ElliotRequest, timeout: TimeInterval? = nil) throws -> ElliotResponse {
        let fd = try UnixSocket.connect(path: socketPath, timeout: timeout ?? request.socketTimeout)
        defer { close(fd) }
        // One reader for the connection, not one per exchange: the greeting and
        // the answer share it, and a buffered read of the first can already hold
        // the front of the second.
        let reader = UnixSocket.LineReader(fd: fd)

        let greeting = try exchange(
            .hello(protocolVersion: elliotProtocolVersion, token: token, client: clientName),
            on: fd,
            reading: reader
        )
        if case .failure = greeting { return greeting }

        return try exchange(request, on: fd, reading: reader)
    }

    private func exchange(
        _ request: ElliotRequest,
        on fd: Int32,
        reading reader: UnixSocket.LineReader
    ) throws -> ElliotResponse {
        let envelope = Envelope(body: request)
        try UnixSocket.write(fd: fd, data: WireCodec.encodeLine(envelope))
        guard let line = reader.next(), !line.isEmpty else {
            throw SocketError.connectionClosed
        }
        return try WireCodec.decode(Envelope<ElliotResponse>.self, from: line).body
    }

    /// Launches the app and waits for it to answer.
    ///
    /// `-g` keeps it from stealing focus and `-j` starts it hidden: a card move
    /// asked for by an agent should not yank the user out of what they are doing.
    @discardableResult
    public func launchAppAndWait(
        bundleIdentifier: String = "dev.phmatray.elliot",
        timeout: TimeInterval = 20
    ) -> Bool {
        if isAppRunning() { return true }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-g", "-j", "-b", bundleIdentifier]
        try? process.run()
        // Deliberately not `waitUntilExit()`. `open` returns the moment it has
        // handed the launch to the system, so waiting on it tells us nothing the
        // poll below does not — and it tells it dangerously: `waitUntilExit`
        // spins a run loop on its calling thread, and the one caller of this is
        // reached from an `async` context, where that thread belongs to the
        // cooperative pool. It intermittently never returns there, which would
        // hang an agent's card move outright.

        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if isAppRunning() { return true }
            Thread.sleep(forTimeInterval: 0.25)
        }
        return false
    }

    public static func readToken(at url: URL) -> String? {
        try? String(contentsOf: url, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
