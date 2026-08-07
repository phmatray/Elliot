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
    private let socketPath: String
    private let bundleIdentifier: String

    public init(
        socketPath: String = StoreLocation.socketURL.path,
        token: String? = nil,
        bundleIdentifier: String = "dev.phmatray.elliot"
    ) {
        let resolvedToken = token ?? IPCClient.readToken(at: StoreLocation.tokenURL) ?? ""
        client = IPCClient(socketPath: socketPath, token: resolvedToken)
        self.socketPath = socketPath
        self.bundleIdentifier = bundleIdentifier
    }

    public var isAppRunning: Bool { client.isAppRunning() }

    /// The socket path is unusable, said in the one way that is actionable —
    /// or nil, which is every ordinary call (#168).
    ///
    /// Consulted **before** `isAppRunning()` by both halves of the bridge,
    /// because that check asks "does something answer at this path" and a path
    /// the app could never bind has nothing to answer. Its "no" is therefore
    /// indistinguishable from an app that is down, and the helper spent five
    /// `board_screenshot` calls telling a reader to launch an Elliot whose
    /// window was on screen in front of them.
    ///
    /// The check is arithmetic on a string this process already has: both
    /// processes *compute* the socket path from `ELLIOT_HOME` rather than
    /// exchanging it, so the helper can measure a path it has never bound. That
    /// also means the answer cannot go stale — there is no artefact to expire,
    /// which is why this is the fix rather than a sentinel file the app writes.
    ///
    /// One function, two callers, on purpose: `read` and `write` telling
    /// different stories about the same path is the shape of the defect being
    /// fixed, one layer along.
    static func unusableSocketPath(_ path: String) -> ElliotResponse? {
        guard !UnixSocket.pathFits(path) else { return nil }
        return .failure(
            code: .appUnavailable,
            message: "Elliot could not open its MCP socket: the path ELLIOT_HOME leads to is "
                + "\(path.utf8.count) bytes, and a unix socket path must be under "
                + "\(UnixSocket.maxPathBytes). The path is \(path)",
            hint: "Set a shorter ELLIOT_HOME and restart Elliot, then re-register this helper. "
                + "Elliot itself may well be up — its board works without the MCP socket, and "
                + "Preflight reports the socket separately."
        )
    }

    /// A read: answered live, or from a read-only snapshot of the database.
    public func read(_ request: ElliotRequest) async -> BridgeOutcome {
        // Before anything asks whether the app is up. A read here must **not**
        // fall back to the snapshot: the database is perfectly readable, so an
        // offline answer would be correct data under a false explanation —
        // the same defect one layer down, and harder to see because the rows
        // would look right. `.live` rather than a third case because the
        // refusal is a `.failure`, which `render` returns whole without ever
        // reading `source`.
        if let refusal = Self.unusableSocketPath(socketPath) { return .live(refusal) }

        let client = client
        // Which of the two snapshot stories is true is decided here and nowhere
        // else: a socket that fails mid-request also lands in the fallback, and
        // reporting that as "Elliot is not running" sends the caller to launch
        // an app that is already up.
        let wasRunning = client.isAppRunning()
        if wasRunning {
            let response = await BlockingIO.run { try? client.send(request) }
            if let response { return .live(response) }
        }
        do {
            // The snapshot answers in the same type the app does. It used to
            // hand the store itself to the tool layer, and every read tool then
            // rebuilt the app's answer out of rows — six times, drifting each
            // time. See `OfflineResponder`.
            let responder = OfflineResponder(store: try BoardStore.openReadOnly())
            return .offline(
                await responder.respond(to: request),
                wasRunning ? .appUnreachable : .appNotRunning
            )
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
        // Same guard as `read`, and ahead of `isAppRunning()` for the same
        // reason — plus one this half feels on its own: the launch below polls
        // for twenty seconds before giving up, so without this the helper spent
        // that long waiting for an app to bind a socket it cannot bind.
        if let refusal = Self.unusableSocketPath(socketPath) { return refusal }

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

/// One answer, and where it came from.
///
/// Both cases carry an `ElliotResponse`, which is the whole point: a tool reads
/// `response`, renders it, and never learns which half of the bridge built it.
/// `offline` used to carry a `BoardStore` instead, and the six tools that had to
/// unpack it each grew a second implementation of the app's query — the clamp,
/// the repository filter, the DTO assembly, the refusals. Four of them were
/// taught the same lesson separately, months apart, because nothing in the type
/// said the two answers had to agree.
public enum BridgeOutcome: Sendable {
    case live(ElliotResponse)
    /// The app could not answer; this came from the database, and the reason
    /// says which way the app failed.
    case offline(ElliotResponse, SnapshotReason)

    public var response: ElliotResponse {
        switch self {
        case .live(let response), .offline(let response, _): response
        }
    }

    /// What the `source` field says. The one word an agent has to tell a live
    /// board from a frozen one, so it is derived here rather than written out at
    /// each tool.
    public var source: String {
        switch self {
        case .live: "live"
        case .offline: "offline-db"
        }
    }

    public var snapshotReason: SnapshotReason? {
        switch self {
        case .live: nil
        case .offline(_, let reason): reason
        }
    }
}

/// Why a read fell back to the database instead of the running app.
///
/// Two different stories, and telling the wrong one is the defect the rest of
/// this module was audited for: a snapshot labelled "Elliot is not running"
/// while Elliot *is* running sends an agent to launch an app that is already
/// up, and buries the socket failure that actually happened.
public enum SnapshotReason: Sendable {
    case appNotRunning
    /// The socket was live at the check and the request still did not complete.
    case appUnreachable
}
