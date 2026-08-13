import ACP
import ACPModel
import Foundation
import Testing
import TestSupport

@testable import ElliotProcess

/// An in-memory transport, so the client's request/response correlation is testable without a
/// child process at all. `/bin/cat` proves the pipe; this proves the protocol.
///
/// Vendored-brief change: the brief's sketch guarded `closed` with a raw `NSLock`, whose
/// `lock()`/`unlock()` are `noasync` on this toolchain (Swift 6.3.3) — calling them directly from
/// an `async` getter is a compile error here, not a style choice. `Locked` (`ElliotProcess`,
/// internal, reached through `@testable import`) is `ChildProcess`'s own box around `Mutex` and
/// sidesteps it the same way production code already does.
private final class LoopbackTransport: Transport, Sendable {
    let messages: AsyncStream<Data>
    private let continuation: AsyncStream<Data>.Continuation
    private let closed = Locked(false)

    /// Answers each request with a canned result keyed by method.
    private let answer: @Sendable (String, Int) -> Data?

    init(answer: @escaping @Sendable (String, Int) -> Data?) {
        var continuation: AsyncStream<Data>.Continuation!
        messages = AsyncStream(bufferingPolicy: .unbounded) { continuation = $0 }
        self.continuation = continuation!
        self.answer = answer
    }

    func send(_ data: Data) async throws {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let method = object["method"] as? String,
            let id = object["id"] as? Int
        else { return }
        if let reply = answer(method, id) { continuation.yield(reply) }
    }

    func close() async {
        closed.withLock { $0 = true }
        continuation.finish()
    }

    var isConnected: Bool {
        get async { !closed.value }
    }
}

@Suite("ACP client over a transport")
struct ACPClientTransportTests {
    @Test("initialize negotiates over whatever transport it was given")
    func initializeOverLoopback() async throws {
        let transport = LoopbackTransport { method, id in
            guard method == "initialize" else { return nil }
            return Data(
                """
                {"jsonrpc":"2.0","id":\(id),"result":{"protocolVersion":1,
                 "agentCapabilities":{},"agentInfo":{"name":"loopback","version":"0.0.1"},
                 "authMethods":[]}}
                """.utf8)
        }
        let client = Client(transport: transport)
        let response = try await withTimeout(.seconds(5)) {
            try await client.initialize(
                protocolVersion: 1,
                capabilities: ClientCapabilities(
                    fs: FileSystemCapabilities(readTextFile: false, writeTextFile: false),
                    terminal: false
                ),
                clientInfo: ClientInfo(name: "elliot")
            )
        }
        #expect(response.protocolVersion == 1)
        #expect(response.agentInfo?.name == "loopback")
    }
}
