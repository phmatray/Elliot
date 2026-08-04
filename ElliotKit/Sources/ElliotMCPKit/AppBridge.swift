import ElliotIPC
import ElliotModel
import ElliotStore
import Foundation

/// How the helper reaches the board.
///
/// Three tiers, and the third one is a deliberate refusal. Reads can be served
/// from the database when Elliot is down, but a **write never can**: writing a
/// column change straight to SQLite would move a card without firing its rule,
/// which is precisely the bug this whole architecture exists to prevent. The
/// helper launches the app instead, and says so plainly if it cannot.
public struct AppBridge: Sendable {
    private let client: IPCClient
    private let bundleIdentifier: String

    public init(
        socketPath: String = StoreLocation.socketURL.path,
        token: String? = nil,
        bundleIdentifier: String = "dev.phmatray.elliot"
    ) {
        let resolvedToken = token ?? IPCClient.readToken(at: StoreLocation.tokenURL) ?? ""
        client = IPCClient(socketPath: socketPath, token: resolvedToken)
        self.bundleIdentifier = bundleIdentifier
    }

    public var isAppRunning: Bool { client.isAppRunning() }

    /// A read: answered live, or from a read-only snapshot of the database.
    public func read(_ request: ElliotRequest) -> BridgeOutcome {
        if client.isAppRunning() {
            if let response = try? client.send(request) {
                return .live(response)
            }
        }
        guard let store = try? BoardStore.openReadOnly() else {
            return .live(.failure(
                code: .appUnavailable,
                message: "Elliot is not running and its database could not be opened.",
                hint: "Open Elliot.app."
            ))
        }
        return .offline(store)
    }

    /// A write: only ever served by the running app.
    public func write(_ request: ElliotRequest) -> ElliotResponse {
        if !client.isAppRunning() {
            // `-g -j` so a card move asked for by an agent does not yank the
            // user out of whatever they are doing.
            guard client.launchAppAndWait(bundleIdentifier: bundleIdentifier) else {
                return .failure(
                    code: .appUnavailable,
                    message: "Elliot is not running and could not be launched.",
                    hint: "Open Elliot.app and try again."
                )
            }
        }
        do {
            return try client.send(request)
        } catch {
            return .failure(
                code: .appUnavailable,
                message: error.localizedDescription,
                hint: "Check that Elliot is still running."
            )
        }
    }
}

public enum BridgeOutcome: Sendable {
    case live(ElliotResponse)
    /// The app is down; answer from the database and say so.
    case offline(BoardStore)
}
