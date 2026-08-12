import ACP
import Foundation
import Testing
import TestSupport

@testable import ElliotProcess

/// `/bin/cat` is a perfect ACP echo for transport purposes: newline-delimited JSON in, the same
/// bytes out. It tests the framing and the plumbing without involving an agent at all.
@Suite("ACP transport")
struct ACPTransportTests {
    @Test("a line written is a message received")
    func roundTripsOneMessage() async throws {
        let transport = try ACPTransport(
            ACPAgentProcess(
                executable: "/bin/cat", arguments: [], cwd: "/tmp", environment: [:]
            )
        )
        defer { transport.terminate() }

        try await transport.send(Data(#"{"jsonrpc":"2.0","id":1,"method":"ping"}"#.utf8))

        let received = try await withTimeout(.seconds(5)) {
            var iterator = transport.messages.makeAsyncIterator()
            return await iterator.next()
        }
        let decoded = try #require(received)
        let object = try JSONSerialization.jsonObject(with: decoded) as? [String: Any]
        #expect(object?["method"] as? String == "ping")
    }

    @Test("a message split across writes still arrives whole")
    func reassemblesASplitMessage() async throws {
        let transport = try ACPTransport(
            ACPAgentProcess(
                executable: "/bin/cat", arguments: [], cwd: "/tmp", environment: [:]
            )
        )
        defer { transport.terminate() }

        // `send` appends the newline, so these are two halves of one line only because the first
        // has none of its own — which is exactly what a chunked pipe read looks like.
        try await transport.sendRaw(Data(#"{"jsonrpc":"2.0","id":"#.utf8))
        try await transport.sendRaw(Data("1}\n".utf8))

        let received = try await withTimeout(.seconds(5)) {
            var iterator = transport.messages.makeAsyncIterator()
            return await iterator.next()
        }
        let decoded = try #require(received)
        let object = try JSONSerialization.jsonObject(with: decoded) as? [String: Any]
        #expect(object?["id"] as? Int == 1)
    }

    @Test("closing ends the message stream")
    func closingEndsTheStream() async throws {
        let transport = try ACPTransport(
            ACPAgentProcess(
                executable: "/bin/cat", arguments: [], cwd: "/tmp", environment: [:]
            )
        )
        await transport.close()

        // `try` even though the closure body does not throw — `withTimeout` throws on the deadline.
        let exit = try await withTimeout(.seconds(5)) { await transport.waitForExit() }
        #expect(exit == 0)

        let isConnected = await transport.isConnected
        #expect(isConnected == false)
    }
}
