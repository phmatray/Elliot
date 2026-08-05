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
    public func send(_ request: ElliotRequest, timeout: TimeInterval = 30) throws -> ElliotResponse {
        let fd = try UnixSocket.connect(path: socketPath, timeout: timeout)
        defer { close(fd) }

        let greeting = try exchange(
            .hello(protocolVersion: elliotProtocolVersion, token: token, client: clientName),
            on: fd
        )
        if case .failure = greeting { return greeting }

        return try exchange(request, on: fd)
    }

    private func exchange(_ request: ElliotRequest, on fd: Int32) throws -> ElliotResponse {
        let envelope = Envelope(body: request)
        try UnixSocket.write(fd: fd, data: WireCodec.encodeLine(envelope))
        guard let line = UnixSocket.readLine(fd: fd), !line.isEmpty else {
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
