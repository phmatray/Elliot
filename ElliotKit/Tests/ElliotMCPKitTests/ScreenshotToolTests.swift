import ElliotIPC
import ElliotModel
import Foundation
import MCP
import Testing

@testable import ElliotMCPKit

/// `board_screenshot` is the one tool whose answer is not a single JSON text
/// block, so what these pin is mostly the *shape*: an image block a model can
/// actually look at, a JSON block beside it, and — when there is no image — an
/// explicit reason rather than a quietly missing one.
@Suite("Screenshot tool")
struct ScreenshotToolTests {

    private static func dto(
        base64: String? = "aGVsbG8=",
        notIncluded: [String] = [],
        downscaledFrom: Double? = nil
    ) -> ScreenshotDTO {
        ScreenshotDTO(
            window: "board", title: "Elliot", width: 900, height: 700, scale: 2,
            pngPath: "/tmp/board.png", pngBase64: base64, byteCount: base64?.utf8.count ?? 0,
            downscaledFrom: downscaledFrom, isVisible: true, isKeyWindow: true,
            notIncluded: notIncluded
        )
    }

    private static func text(_ result: CallTool.Result) throws -> String {
        for case .text(let text, _, _) in result.content { return text }
        Issue.record("no text block in \(result.content.count) content blocks")
        return ""
    }

    @Test("A capture comes back as an image the model can see, with the JSON beside it")
    func imageAndJSON() async throws {
        let result = try await ScreenshotTool().call(
            ["window": .string("board")],
            bridge: StubBridge.answering(.screenshot(Self.dto()))
        )

        #expect(result.isError == false)
        #expect(result.content.count == 2)

        // Image first: a model that reads only the first block must get the
        // picture, not a paragraph describing one.
        guard case .image(let data, let mime, _, _) = result.content.first else {
            Issue.record("the first block is not an image: \(result.content)")
            return
        }
        #expect(data == "aGVsbG8=")
        #expect(mime == "image/png")

        let json = try Self.text(result)
        #expect(json.contains("\"window\":\"board\""))
        // The path is always there, whether or not the image was inlined — it is
        // the full-resolution copy, and the only way to read a caption the
        // budget could not afford.
        // On the key and the basename, not the whole path: `JSONEncoder` escapes
        // forward slashes, so the bytes read `\/tmp\/board.png`. That is valid
        // JSON and every parser un-escapes it — asserting the literal path would
        // be asserting against the *rendering* rather than the content, which is
        // the trap this codebase keeps a whole section of CLAUDE.md about.
        #expect(json.contains("png_path"))
        #expect(json.contains("board.png"))
        // The base64 must NOT be repeated inside the JSON: it is already the
        // image block, and sending it twice doubles the cost of the one reply
        // whose whole design is about cost.
        #expect(!json.contains("aGVsbG8="))
    }

    @Test("No image is an explanation, never a silently absent block")
    func absentImageIsExplained() async throws {
        let result = try await ScreenshotTool().call(
            ["window": .string("board")],
            bridge: StubBridge.answering(.screenshot(Self.dto(base64: nil)))
        )

        // One block, not two — and crucially not an `isError: false` reply with
        // no picture and nothing saying why, which an agent would read as a
        // successful screenshot of an empty window.
        #expect(result.content.count == 1)
        #expect(result.isError == false)

        let json = try Self.text(result)
        #expect(json.contains("note"))
        #expect(json.lowercased().contains("too large") || json.lowercased().contains("budget"))
        // On the key and the basename, not the whole path: `JSONEncoder` escapes
        // forward slashes, so the bytes read `\/tmp\/board.png`. That is valid
        // JSON and every parser un-escapes it — asserting the literal path would
        // be asserting against the *rendering* rather than the content, which is
        // the trap this codebase keeps a whole section of CLAUDE.md about.
        #expect(json.contains("png_path"))
        #expect(json.contains("board.png"))
    }

    @Test("What the picture cannot show is carried into the reply")
    func disclosuresReachTheAgent() async throws {
        let result = try await ScreenshotTool().call(
            ["window": .string("board")],
            bridge: StubBridge.answering(.screenshot(Self.dto(notIncluded: ["attached sheet: New story"])))
        )

        let json = try Self.text(result)
        #expect(json.contains("not_included"))
        #expect(json.contains("attached sheet: New story"))
        // And it is said in the note too, because a field an agent did not think
        // to read is a field that did not warn anyone.
        #expect(json.contains("note"))
    }

    @Test("A resampled picture says so, so nobody reads blur as a rendering bug")
    func downscaleIsAnnounced() async throws {
        let result = try await ScreenshotTool().call(
            ["window": .string("board")],
            bridge: StubBridge.answering(.screenshot(Self.dto(downscaledFrom: 2)))
        )
        let json = try Self.text(result)
        #expect(json.contains("downscaled_from") || json.contains("downscaledFrom"))
        #expect(json.contains("note"))
    }

    @Test("The two window refusals reach the agent with their own codes")
    func refusalsArePassedThrough() async throws {
        let unknown = try await ScreenshotTool().call(
            ["window": .string("bord")],
            bridge: StubBridge.refusing(.windowNotFound, "No Elliot window is called \"bord\".", hint: "Known: board.")
        )
        let closed = try await ScreenshotTool().call(
            ["window": .string("preflight")],
            bridge: StubBridge.refusing(.windowNotOpen, "not open", hint: "Open right now: board.")
        )

        #expect(unknown.isError == true)
        #expect(closed.isError == true)
        // Verbatim: the helper never rewords a refusal it did not decide.
        #expect(try Self.text(unknown).contains("window_not_found"))
        #expect(try Self.text(closed).contains("window_not_open"))
        #expect(try Self.text(unknown).contains("bord"))
    }

    @Test("The board is the default, so the commonest call needs no argument")
    func defaultsToTheBoard() async throws {
        let asked = Recorder()
        let bridge = StubBridge(onRead: { request in
            if case .screenshot(let window, let budget) = request {
                asked.record(window: window, budget: budget)
            }
            return .live(.ok(.screenshot(Self.dto())))
        })

        _ = try await ScreenshotTool().call([:], bridge: bridge)

        #expect(asked.window == "board")
        // And the budget the caller did not name is the server's, not zero.
        #expect(asked.budget == ScreenshotBudget.defaultInlineBytes)
    }

    @Test("A caller's own budget is passed through, and a silly one is refused")
    func budgetIsHonoured() async throws {
        let asked = Recorder()
        let bridge = StubBridge(onRead: { request in
            if case .screenshot(let window, let budget) = request {
                asked.record(window: window, budget: budget)
            }
            return .live(.ok(.screenshot(Self.dto())))
        })

        _ = try await ScreenshotTool().call(
            ["window": .string("board"), "max_inline_bytes": .int(4096)], bridge: bridge
        )
        #expect(asked.budget == 4096)

        // Zero would silently become the default downstream; a caller who typed
        // it meant something, and guessing which is how a discarded argument
        // becomes an answer to a question nobody asked.
        await #expect(throws: ToolFailure.self) {
            try await ScreenshotTool().call(
                ["window": .string("board"), "max_inline_bytes": .int(0)], bridge: bridge
            )
        }
    }

    @Test("A budget past the ceiling is clamped, and the reply says by how much")
    func hugeBudgetIsClamped() async throws {
        let asked = Recorder()
        let bridge = StubBridge(onRead: { request in
            if case .screenshot(let window, let budget) = request {
                asked.record(window: window, budget: budget)
            }
            return .live(.ok(.screenshot(Self.dto())))
        })

        let result = try await ScreenshotTool().call(
            ["window": .string("board"), "max_inline_bytes": .int(64_000_000)], bridge: bridge
        )

        // Clamped before it reaches the app. Unclamped, the reply is one IPC
        // line past `UnixSocket`'s 8 MB cap: the reader truncates, the decode
        // throws, and the whole call degrades into "Elliot is not running" for a
        // request that was merely too big.
        #expect(asked.budget == ScreenshotBudget.maxInlineBytes)
        // And said out loud, as `ElliotPaging` already insists for every other
        // size argument here — a silently substituted number is an answer to a
        // question nobody asked.
        let json = try Self.text(result)
        #expect(json.contains("max_inline_bytes_capped_from"))
        #expect(json.contains("64000000"))
    }

    @Test("An unreachable app is not an absent one, and the hint must not say relaunch")
    func unreachableIsNotAbsent() async throws {
        // `AppBridge.read` lands on the snapshot for two different reasons, and
        // a screenshot is the one read that always reaches it as a *failure* —
        // so `render(_ outcome:)` never gets to prepend the offline note that
        // keeps the two stories apart. Told the wrong one, an agent goes off to
        // launch an app that is already on screen and buries a failing socket.
        let bridge = StubBridge(onRead: { _ in
            .offline(
                .failure(
                    code: .appUnavailable,
                    message: "Elliot is not running; a snapshot of its database has no window "
                        + "to photograph.",
                    hint: "Open Elliot.app."
                ),
                .appUnreachable
            )
        })

        let result = try await ScreenshotTool().call(["window": .string("board")], bridge: bridge)
        let json = try Self.text(result)

        #expect(result.isError == true)
        #expect(json.contains("IS running"))
        #expect(json.contains("Do not relaunch"))
        // The stale advice must be gone, not merely accompanied.
        #expect(!json.contains("Open Elliot.app."))
    }

    @Test("A snapshot cannot answer, and says which app to open")
    func offlineIsRefused() async throws {
        let result = try await ScreenshotTool().call(
            ["window": .string("board")],
            bridge: StubBridge.refusing(
                .appUnavailable,
                "Elliot is not running; a snapshot of its database has no window to photograph.",
                hint: "Open Elliot.app."
            )
        )
        #expect(result.isError == true)
        #expect(try Self.text(result).contains("app_unavailable"))
        #expect(try Self.text(result).contains("Elliot.app"))
    }

    /// A tiny box so the scripted bridge can report what it was asked, without
    /// the closure having to capture a `var`.
    final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var _window: String?
        private var _budget: Int?
        func record(window: String, budget: Int) {
            lock.lock(); defer { lock.unlock() }
            _window = window; _budget = budget
        }
        var window: String? { lock.lock(); defer { lock.unlock() }; return _window }
        var budget: Int? { lock.lock(); defer { lock.unlock() }; return _budget }
    }
}
