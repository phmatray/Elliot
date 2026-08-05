import Dispatch
import ElliotIPC
import ElliotModel
import ElliotStore
import Foundation

/// What the tool layer is allowed to ask of the board.
///
/// A protocol rather than the concrete `AppBridge` so the tools can be exercised
/// without a socket and without an app. That is not a testing nicety: the
/// interesting behaviours of this layer — refusing an unknown repository,
/// filling `activeRunID` from a snapshot, saying that an answer was cut — all
/// live on the *offline* path, which by definition never happens on a machine
/// where Elliot is up. Without a seam here they can only be observed by killing
/// the app.
///
/// Both methods are `async` because the real one blocks on a socket for up to
/// five minutes and must not do so on a thread the runtime needs back. See
/// `BlockingIO`.
///
/// `AppBridge` is the only implementation that ships.
public protocol BridgeProviding: Sendable {
    var isAppRunning: Bool { get }

    /// A read: answered live, or from a read-only snapshot of the database.
    func read(_ request: ElliotRequest) async -> BridgeOutcome

    /// A write: only ever served by the running app.
    func write(_ request: ElliotRequest) async -> ElliotResponse
}

/// Somewhere to block that is not the cooperative pool.
///
/// `IPCClient.send` is a blocking `read()` loop with a socket timeout, and
/// `board_await_run` holds it open for up to five minutes on purpose. Called
/// straight from an async function it parks one of the runtime's threads — of
/// which there are as many as the machine has cores — for that whole window.
/// The MCP SDK dispatches every request in its own task, so a handful of
/// concurrent waits is enough to occupy all of them, and the helper then stops
/// answering anything at all: not an error, not a timeout, silence. Including
/// for the stdio loop that would have read the next request.
///
/// A concurrent `DispatchQueue` grows threads to match what is blocked on it,
/// which is the property the cooperative pool deliberately does not have.
enum BlockingIO {
    private static let queue = DispatchQueue(
        label: "dev.phmatray.elliot.mcp.socket",
        qos: .userInitiated,
        attributes: .concurrent
    )

    /// Runs blocking work off the cooperative pool and suspends until it ends.
    static func run<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: work()) }
        }
    }
}

/// How the helper reaches the board.
///
/// Three tiers, and the third one is a deliberate refusal. Reads can be served
/// from the database when Elliot is down, but a **write never can**: writing a
/// column change straight to SQLite would move a card without firing its rule,
/// which is precisely the bug this whole architecture exists to prevent. The
/// helper launches the app instead, and says so plainly if it cannot.
public struct AppBridge: Sendable, BridgeProviding {
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
    public func read(_ request: ElliotRequest) async -> BridgeOutcome {
        let client = client
        if client.isAppRunning() {
            let response = await BlockingIO.run { try? client.send(request) }
            if let response { return .live(response) }
        }
        do {
            return .offline(try BoardStore.openReadOnly())
        } catch {
            // Caught rather than `try?`. The store distinguishes "this file was
            // written by a newer Elliot than this helper" from "no board has
            // ever been set up here", and both name the one action that fixes
            // them. Flattening the pair into "Elliot is not running" told a
            // stale helper's caller to launch the app — which makes reads work
            // again by going live, and teaches nobody that the helper is old.
            return .live(Self.failure(for: error))
        }
    }

    /// Why the snapshot could not be opened, said in a way the agent can act on.
    static func failure(for error: any Error) -> ElliotResponse {
        switch error {
        case StoreError.schemaTooNew:
            .failure(
                code: .protocolMismatch,
                message: StoreError.schemaTooNew.errorDescription ?? "\(error)",
                hint: "Re-register the helper shipped inside the running app bundle: "
                    + "claude mcp add elliot -s user -- /path/to/Elliot.app/Contents/MacOS/elliot-mcp"
            )
        case StoreError.schemaMissing:
            .failure(
                code: .appUnavailable,
                message: StoreError.schemaMissing.errorDescription ?? "\(error)",
                hint: "Open Elliot.app once so it creates the board."
            )
        default:
            .failure(
                code: .appUnavailable,
                message: "Elliot is not running and its database could not be opened: "
                    + error.localizedDescription,
                hint: "Open Elliot.app."
            )
        }
    }

    /// A write: only ever served by the running app.
    public func write(_ request: ElliotRequest) async -> ElliotResponse {
        let client = client
        let bundleIdentifier = bundleIdentifier
        return await BlockingIO.run {
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
}

public enum BridgeOutcome: Sendable {
    case live(ElliotResponse)
    /// The app is down; answer from the database and say so.
    case offline(BoardStore)
}
