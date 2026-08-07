import ElliotIPC
import Foundation

/// Whatever can photograph one of Elliot's own windows.
///
/// A protocol, and one with no AppKit in it, for the reason `ElliotMCPKit`
/// imports neither `ElliotEngine` nor `ElliotProcess`: the layer order is the
/// dependency graph, and `ElliotEngine` sits below the views. The only
/// implementation that ships is `AppKitWindowCapture` in `ElliotAppKit`, injected
/// where the handler is built — which is also what lets the routing be tested
/// without a window server, a display, or a running app.
public protocol WindowCapturing: Sendable {
    /// `window` is a scene id; `maxInlineBytes` is a base64 budget, non-positive
    /// meaning "you decide".
    func capture(window: String, maxInlineBytes: Int) async -> Result<ScreenshotDTO, CaptureFailure>
}

/// Why a window could not be photographed.
///
/// Four cases rather than one message, because they are four different next
/// actions for the caller. Flattening them into a string is how "that is not a
/// window" and "that window is not open" end up looking alike — the same
/// collapse `OfflineResponder.filter` refuses to make for repositories, where it
/// once turned a typo into an answer about the whole board.
public enum CaptureFailure: Error, Sendable, Equatable {
    /// No scene by that id. Carries every id there is, so the reply is
    /// actionable without a second round trip.
    case unknownWindow(known: [String])
    /// A real id whose window is not open. Carries the ones that *are* open —
    /// and deliberately not the one that was asked for.
    case notOpen(open: [String])
    /// The window exists but has no drawable size yet. Refused rather than
    /// photographed: a 0×0 bitmap encodes cleanly and arrives as a valid, empty
    /// picture, which is precisely the false negative a screenshot tool exists
    /// to remove.
    case notLaidOut(width: Double, height: Double)
    /// The bitmap could not be produced or encoded. Carries the reason as prose
    /// because there is nothing more structured to say about it.
    case encodingFailed(String)
}

public extension CaptureFailure {
    /// How this failure is said on the wire.
    ///
    /// Here rather than in `MCPRequestHandler` so the handler keeps its promise
    /// of deciding nothing, and so the two window refusals are phrased once
    /// instead of at every future caller.
    ///
    /// `requested` is passed in rather than carried in the case: the capturer
    /// knows which windows exist, the caller knows which one was asked for, and
    /// a refusal that does not quote the name back is a refusal an agent cannot
    /// match to the call it made.
    func response(for requested: String) -> ElliotResponse {
        switch self {
        case .unknownWindow(let known):
            .failure(
                code: .windowNotFound,
                message: "No Elliot window is called \"\(requested)\".",
                hint: "Known windows: \(known.joined(separator: ", "))."
            )
        case .notOpen(let open):
            .failure(
                code: .windowNotOpen,
                message: "The window \"\(requested)\" exists but is not open.",
                hint: open.isEmpty
                    ? "No Elliot windows are open."
                    : "Open right now: \(open.joined(separator: ", "))."
            )
        case .notLaidOut(let width, let height):
            .failure(
                code: .internalError,
                message: "That window has no drawable size yet (\(Int(width))×\(Int(height))).",
                hint: "It is probably still opening; try again in a moment."
            )
        case .encodingFailed(let reason):
            .failure(
                code: .internalError,
                message: "Elliot could not encode the capture: \(reason)",
                hint: nil
            )
        }
    }
}
