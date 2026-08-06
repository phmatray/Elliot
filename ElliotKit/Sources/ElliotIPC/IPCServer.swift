import Foundation

/// Answers requests from the MCP helper.
///
/// The handler runs whatever the app would have run for a drag, so an agent
/// moving a card and a human moving a card are the same act.
public final class IPCServer: @unchecked Sendable {
    /// The request, and the name the connection gave for itself in `hello`.
    ///
    /// The name is per **connection**, not per server: `IPCClient.send` opens a
    /// socket, greets, asks one question and hangs up, so two helpers talking to
    /// one app must not see each other's name. Holding it in `serve`'s own frame
    /// is what makes that true by construction.
    public typealias Handler = @Sendable (ElliotRequest, String) async -> ElliotResponse

    private let socketPath: String
    private let token: String
    private let handler: Handler
    private let queue = DispatchQueue(label: "dev.phmatray.elliot.ipc", qos: .userInitiated)

    private var listenFD: Int32 = -1
    private var source: DispatchSourceRead?

    public init(socketPath: String, token: String, handler: @escaping Handler) {
        self.socketPath = socketPath
        self.token = token
        self.handler = handler
    }

    public enum StartError: Error, LocalizedError {
        case alreadyRunning

        public var errorDescription: String? {
            switch self {
            case .alreadyRunning: "Another Elliot is already listening on this socket."
            }
        }
    }

    public func start() throws {
        if UnixSocket.isLive(path: socketPath) { throw StartError.alreadyRunning }
        // Not live but present means a previous run died; the file is stale.
        try? FileManager.default.removeItem(atPath: socketPath)

        listenFD = try UnixSocket.bindListener(path: socketPath)

        let source = DispatchSource.makeReadSource(fileDescriptor: listenFD, queue: queue)
        source.setEventHandler { [weak self] in self?.accept() }
        source.setCancelHandler { [listenFD = self.listenFD] in close(listenFD) }
        source.resume()
        self.source = source
    }

    public func stop() {
        source?.cancel()
        source = nil
        listenFD = -1
        try? FileManager.default.removeItem(atPath: socketPath)
    }

    private func accept() {
        let clientFD = Darwin.accept(listenFD, nil, nil)
        guard clientFD >= 0 else { return }
        Task.detached { [weak self] in
            await self?.serve(clientFD)
            close(clientFD)
        }
    }

    private func serve(_ fd: Int32) async {
        var greeted = false
        // Named before it is known, because a request can only reach the handler
        // after a successful `hello` — so "unknown" is unreachable rather than a
        // guess, and it is a word an audit row can carry without lying if the
        // guard above it ever changes.
        var client = "unknown"
        let reader = UnixSocket.LineReader(fd: fd)

        while let line = reader.next() {
            guard !line.isEmpty else { continue }

            let envelope: Envelope<ElliotRequest>
            do {
                envelope = try WireCodec.decode(Envelope<ElliotRequest>.self, from: line)
            } catch {
                try? send(.failure(
                    code: .internalError,
                    message: "Malformed request: \(error.localizedDescription)",
                    hint: nil
                ), id: UUID(), to: fd)
                continue
            }

            let response: ElliotResponse
            if case .hello(let version, let clientToken, let clientName) = envelope.body {
                if version != elliotProtocolVersion {
                    response = .failure(
                        code: .protocolMismatch,
                        message: "Helper speaks protocol \(version); this Elliot speaks \(elliotProtocolVersion).",
                        hint: "Re-register the helper shipped inside the running app bundle."
                    )
                } else if clientToken != token {
                    response = .failure(code: .unauthorized, message: "Bad token.", hint: nil)
                } else {
                    greeted = true
                    // Kept only on the path that also sets `greeted`: a name
                    // from a refused greeting is a name nobody authenticated.
                    client = clientName
                    // The build, not the protocol number — the version check
                    // already happened three lines up, and a bug report needs
                    // to name a build that exists.
                    response = .ok(.hello(serverVersion: ElliotBuild.version))
                }
            } else if !greeted {
                response = .failure(
                    code: .unauthorized,
                    message: "Expected hello first.",
                    hint: nil
                )
            } else {
                response = await handler(envelope.body, client)
            }

            try? send(response, id: envelope.id, to: fd)
            if case .failure(let code, _, _) = response,
               code == .protocolMismatch || code == .unauthorized {
                return
            }
        }
    }

    private func send(_ response: ElliotResponse, id: UUID, to fd: Int32) throws {
        let data = try WireCodec.encodeLine(Envelope(id: id, body: response))
        try UnixSocket.write(fd: fd, data: data)
    }

    // MARK: - Token

    /// Reads the shared token, creating one on first run.
    public static func loadOrCreateToken(at url: URL) throws -> String {
        if let existing = try? String(contentsOf: url, encoding: .utf8), !existing.isEmpty {
            return existing.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        let token = bytes.map { String(format: "%02x", $0) }.joined()
        try token.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return token
    }
}

#if canImport(Security)
import Security
#endif
