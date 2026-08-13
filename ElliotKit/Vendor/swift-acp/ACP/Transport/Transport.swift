//
//  Transport.swift
//  ACP
//
//  Transport protocol abstraction for ACP communication
//

import ACPModel
import Foundation

/// Protocol defining the transport layer for ACP communication.
/// Implementations handle the low-level message sending and receiving.
public protocol Transport: Sendable {
    /// Send data through the transport
    func send(_ data: Data) async throws

    /// Stream of incoming messages
    var messages: AsyncStream<Data> { get }

    /// Close the transport connection
    func close() async

    /// Whether the transport is currently connected/running
    var isConnected: Bool { get async }

    /// Ends the transport's agent, escalating if it ignores the request.
    ///
    /// ⛔ Vendored addition (#381). Upstream declared `send`, `messages`, `close` and
    /// `isConnected` and no way to end a child, so `Client` — which holds `any Transport` —
    /// could not escalate through the abstraction it was given: an agent that ignores its
    /// stdin closing simply survives. `close()` asks; this insists.
    ///
    /// Deliberately **not** `async`: the escalation is a signal plus a scheduled follow-up, and
    /// the one caller that most needs it is a `deinit`, which cannot await anything. An `async`
    /// backstop would be a backstop with no caller.
    func terminate(hardKillAfter grace: Duration)
}

/// Events emitted by transports for lifecycle management
public enum TransportEvent: Sendable {
    case connected
    case disconnected(Error?)
    case message(Data)
}

/// Configuration for transport behavior
public struct TransportConfiguration: Sendable {
    /// Maximum message size in bytes (0 = unlimited)
    public let maxMessageSize: Int

    /// Read buffer size
    public let bufferSize: Int

    public init(maxMessageSize: Int = 0, bufferSize: Int = 65536) {
        self.maxMessageSize = maxMessageSize
        self.bufferSize = bufferSize
    }

    public static let `default` = TransportConfiguration()
}
