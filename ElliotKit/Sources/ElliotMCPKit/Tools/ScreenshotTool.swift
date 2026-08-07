import ElliotIPC
import ElliotModel
import Foundation
import MCP

/// Photographs one of Elliot's windows and hands the picture back as an image
/// block, so an agent can check a change that moved something on screen.
///
/// The one tool on this surface whose answer is not a single JSON text block.
/// That is deliberate: a description of a window is not a look at one, and the
/// whole point is to close the gap `swift test` cannot — it can assert a view's
/// structure and never where anything sits.
///
/// A read, and one that does **not** launch the app. Photographing a board that
/// was not running would answer a question about a live board with a picture of
/// a fresh one, which is the sort of plausible wrong answer this codebase spends
/// most of its comments preventing.
struct ScreenshotTool: BoardTool {
    var tool: Tool {
        Tool(
            name: "board_screenshot",
            description: """
                Photograph one of Elliot's own windows and return it as an image, so you can \
                see a change rather than infer it. Works while the window is in the background \
                and off screen — a window that is not frontmost still photographs at its full \
                designed size, so `is_visible: false` is a fact about the window and not a \
                failed capture. Elliot draws its own view hierarchy, which means anything in a \
                separate window — an attached sheet, a popover, a menu — and anything from \
                another app is NOT in the picture; whatever was left out is listed in \
                `not_included`. The full-resolution PNG is always written to `png_path`; the \
                inline image is bounded by `max_inline_bytes` and may be resampled, which the \
                note says when it happens.
                """,
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "window": .object([
                        "type": .string("string"),
                        // Interpolated, never spelled out: this string is the
                        // only documentation an agent reads, and a hand-written
                        // copy of the scene list went stale inside this very
                        // pull request when `main` retired one window and added
                        // another.
                        "description": .string(
                            "Which window. One of: \(ElliotWindows.sentence). Defaults to board."
                        ),
                    ]),
                    "max_inline_bytes": .object([
                        "type": .string("integer"),
                        "description": .string(
                            "Budget for the inline image, in base64 bytes. Omit for the "
                                + "server's default; a larger picture is resampled to fit."
                        ),
                    ]),
                ]),
                // Nothing required: the commonest call is "show me the board".
                "required": .array([]),
            ]),
            annotations: .init(
                title: "Photograph a window",
                readOnlyHint: true,
                // Elliot's own window, drawn by Elliot, on this machine. Nothing
                // outside is reached — the rule `BoardTool` states for the whole
                // surface.
                openWorldHint: false
            )
        )
    }

    func call(_ args: [String: Value], bridge: any BridgeProviding) async throws -> CallTool.Result {
        let window = args["window"]?.stringValue ?? "board"
        let (budget, cappedFrom) = try args.inlineBudget()

        let outcome = await bridge.read(.screenshot(window: window, maxInlineBytes: budget))
        guard case .ok(.screenshot(let shot)) = outcome.response else {
            return .refusal(outcome)
        }
        return try .screenshot(shot, source: outcome.source, budgetCappedFrom: cappedFrom)
    }
}

extension CallTool.Result {
    /// A refused capture, with the snapshot's reason kept.
    ///
    /// ⚠️ The reason matters here more than anywhere else on this surface,
    /// because a screenshot is the one read the snapshot can *never* answer — so
    /// unlike every other tool, it reaches the offline branch as a `failure`,
    /// where `render(_ outcome:)` never gets to prepend `ToolOutput.offlineNote`.
    /// `OfflineResponder` phrases its refusal as "Elliot is not running", and
    /// `AppBridge.read` also lands there when the app **is** running and the
    /// socket call failed — a timeout, or a reply past the 8 MB line cap. Told
    /// the first story for the second cause, an agent goes off to launch an app
    /// that is already on screen, and the failing socket is buried. That is
    /// precisely the defect `SnapshotReason` was introduced to prevent.
    static func refusal(_ outcome: BridgeOutcome) -> CallTool.Result {
        guard case .failure(let code, let message, let hint) = outcome.response else {
            return .failure(
                code: "internal_error",
                message: "Elliot answered a screenshot with a payload this tool cannot read.",
                hint: "The app and this helper are probably different builds."
            )
        }
        guard outcome.snapshotReason == .appUnreachable else {
            return .failure(code: code.rawValue, message: message, hint: hint)
        }
        return .failure(
            code: code.rawValue,
            message: message,
            hint: "Elliot IS running but did not answer this request, so this refusal came from a "
                + "snapshot of its database rather than from the app. Do not relaunch it — the "
                + "socket call failed or timed out. A very large max_inline_bytes can do this."
        )
    }
}

extension [String: Value] {
    /// The inline budget the caller wrote, or the server's default.
    ///
    /// Zero is refused rather than read as "you decide". The wire treats a
    /// non-positive budget as "you decide", so `max_inline_bytes: 0` would come
    /// back as a full-size picture — the opposite of what someone typing a zero
    /// meant, delivered under `isError: false`. The same reading `limit()`
    /// already refuses to give a zero page size.
    func inlineBudget() throws -> (budget: Int, cappedFrom: Int?) {
        guard let value = try integer("max_inline_bytes") else {
            return (ScreenshotBudget.defaultInlineBytes, nil)
        }
        guard value > 0 else {
            throw ToolFailure(
                code: "bad_argument",
                message: "max_inline_bytes must be at least 1. "
                    + "Omit it for this server's default budget."
            )
        }
        // Clamped, and the cap reported — the bargain `ElliotPaging.clamp`
        // already strikes for every other size argument here.
        //
        // Not politeness: an unclamped budget makes the app base64 a
        // full-resolution PNG into one IPC line, and past `UnixSocket`'s 8 MB
        // line cap the reader returns a truncated buffer, the decode throws, and
        // `try? client.send` yields nil. The call then degrades into the offline
        // branch and comes back as "Elliot is not running" — for a request that
        // was simply too big.
        guard value <= ScreenshotBudget.maxInlineBytes else {
            return (ScreenshotBudget.maxInlineBytes, value)
        }
        return (value, nil)
    }
}

extension CallTool.Result {
    /// A capture: the image first, then the JSON describing it.
    ///
    /// **Image first on purpose.** A model that reads only the first block must
    /// get the picture; a paragraph describing a window is exactly what this
    /// tool exists to stop being the answer.
    ///
    /// The base64 is deliberately **not** repeated in the JSON. It is already the
    /// image block, and sending it twice would double the cost of the one reply
    /// on this surface whose entire design is about cost.
    static func screenshot(
        _ shot: ScreenshotDTO, source: String, budgetCappedFrom: Int? = nil
    ) throws -> CallTool.Result {
        var fields: [String: Value] = [
            "window": .string(shot.window),
            "title": .string(shot.title),
            "width": .int(shot.width),
            "height": .int(shot.height),
            "scale": .double(shot.scale),
            // Always present, even when the image was inlined: this is the
            // lossless copy, and the only way to read something the budget could
            // not afford to send.
            "png_path": .string(shot.pngPath),
            "is_visible": .bool(shot.isVisible),
            "is_key_window": .bool(shot.isKeyWindow),
            // From the outcome, never the literal `"live"`. It is the one field
            // an agent has to tell a live board from a frozen one, and hard-coding
            // it is correct only for exactly as long as no capture can ever be
            // served from anywhere but the running app.
            "source": .string(source),
        ]
        if let budgetCappedFrom {
            fields["max_inline_bytes_capped_from"] = .int(budgetCappedFrom)
        }
        if !shot.notIncluded.isEmpty {
            fields["not_included"] = .array(shot.notIncluded.map { .string($0) })
        }
        if let from = shot.downscaledFrom {
            fields["downscaled_from"] = .double(from)
        }

        // Every note is a sentence about how to read the picture, and each is
        // attached only when it is true — an empty note reads as a finding.
        ToolOutput.attachNote(
            &fields,
            shot.pngBase64 == nil
                ? "The capture was too large for the inline budget even after resampling, so no "
                    + "image is attached. Read the full-resolution PNG at png_path instead."
                : nil,
            shot.downscaledFrom != nil
                ? "The inline image was resampled to fit the budget, so fine detail is softer "
                    + "than the window really is; png_path holds the full-resolution copy."
                : nil,
            shot.notIncluded.isEmpty
                ? nil
                : "This picture does not include: \(shot.notIncluded.joined(separator: "; "))"
                    + ". Elliot draws its own hierarchy, so a separate window is absent from the "
                    + "capture — that is not evidence it failed to open.",
            shot.isVisible
                ? nil
                : "This window is miniaturised in the Dock. It still photographs at its designed "
                    + "size, so that is a fact about the window and not a failed capture — a "
                    + "*closed* window is refused with window_not_open instead.",
            budgetCappedFrom.map {
                "You asked for \($0) inline bytes; this server sends at most "
                    + "\(ScreenshotBudget.maxInlineBytes)."
            }
        )

        var content: [Tool.Content] = []
        if let base64 = shot.pngBase64 {
            content.append(.image(data: base64, mimeType: "image/png", annotations: nil, _meta: nil))
            fields["byte_count"] = .int(shot.byteCount)
        }
        content.append(.text(text: try json(fields), annotations: nil, _meta: nil))
        return CallTool.Result(content: content, isError: false)
    }
}
