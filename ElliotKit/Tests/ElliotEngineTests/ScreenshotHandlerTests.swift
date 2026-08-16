import ElliotIPC
import ElliotModel
import ElliotProcess
import ElliotStore
import Foundation
import TestSupport
import Testing

@testable import ElliotEngine

/// Its own rather than shared with `OfflineParityTests`, whose copy is `private`
/// to that file. Nothing here ever launches a run — the screenshot path does not
/// touch the scheduler at all — so this exists only to satisfy `BoardService`.
private actor NeverLaunches: RunLaunching {
    func launch(runID: UUID) async {}
    func cancel(runID: UUID) async {}
}

/// The handler's whole job on a screenshot is to route and translate. What it
/// must never do is invent an answer: a build with no capturer wired in has no
/// window, and saying so is a different act from returning an empty picture.
@Suite("Screenshot routing")
struct ScreenshotHandlerTests {

    /// A capturer that answers whatever the test told it to, and records what it
    /// was asked. Sendable by being immutable; the recording box is a lock, not
    /// a var, because the handler may hop actors on the way here.
    private struct StubCapture: WindowCapturing {
        let answer: Result<ScreenshotDTO, CaptureFailure>
        let seen: Recorder

        final class Recorder: @unchecked Sendable {
            private let lock = NSLock()
            private var calls: [(String, Int)] = []
            func record(_ window: String, _ budget: Int) {
                lock.lock(); defer { lock.unlock() }
                calls.append((window, budget))
            }
            var all: [(String, Int)] {
                lock.lock(); defer { lock.unlock() }
                return calls
            }
        }

        func capture(
            window: String, maxInlineBytes: Int
        ) async -> Result<ScreenshotDTO, CaptureFailure> {
            seen.record(window, maxInlineBytes)
            return answer
        }
    }

    private static func dto(window: String = "board") -> ScreenshotDTO {
        ScreenshotDTO(
            window: window, title: "Elliot", width: 900, height: 700, scale: 2,
            pngPath: "/tmp/\(window).png", pngBase64: "eA==", byteCount: 4,
            downscaledFrom: nil, isVisible: true, isKeyWindow: true, notIncluded: []
        )
    }

    private static func handler(
        capture: (any WindowCapturing)?
    ) async throws -> MCPRequestHandler {
        _ = TestHome.root
        let store = try BoardStore.inMemory()
        let config = ToolConfig(
            ghPath: "/usr/bin/false",
            gitPath: "/usr/bin/false", environment: [:]
        )
        let launcher = NeverLaunches()
        let board = BoardService(store: store, launcher: launcher)
        let analysis = AnalysisService(
            store: store, launcher: launcher, board: board, gh: GHClient(config: config),
            gate: OpenGate()
        )
        return MCPRequestHandler(
            store: store, board: board, analysis: analysis, capture: capture
        )
    }

    @Test("A capture is passed through exactly as the capturer produced it")
    func successPassesThrough() async throws {
        let expected = Self.dto()
        let recorder = StubCapture.Recorder()
        let handler = try await Self.handler(
            capture: StubCapture(answer: .success(expected), seen: recorder)
        )

        let response = await handler.handle(
            .screenshot(window: "board", maxInlineBytes: 1234)
        )

        guard case .ok(.screenshot(let got)) = response else {
            Issue.record("expected a screenshot payload, got \(response)")
            return
        }
        // Byte-identical, not merely equivalent: the handler decides nothing
        // about a capture, so any difference here is the handler having an
        // opinion it is not allowed to have.
        #expect(got == expected)
        // And the arguments reached the capturer unaltered — a budget quietly
        // replaced by a default is the kind of thing no assertion on the reply
        // would ever notice.
        #expect(recorder.all.count == 1)
        #expect(recorder.all.first?.0 == "board")
        #expect(recorder.all.first?.1 == 1234)
    }

    @Test("An unknown window and a closed one are two different refusals")
    func unknownAndClosedDiffer() async throws {
        let unknown = try await Self.handler(
            capture: StubCapture(
                answer: .failure(.unknownWindow(known: ["board", "preflight"])),
                seen: .init()
            )
        )
        let closed = try await Self.handler(
            capture: StubCapture(
                answer: .failure(.notOpen(open: ["board"])),
                seen: .init()
            )
        )

        guard
            case .failure(let unknownCode, let unknownMessage, let unknownHint) =
                await unknown.handle(.screenshot(window: "bord", maxInlineBytes: 0)),
            case .failure(let closedCode, let closedMessage, let closedHint) =
                await closed.handle(.screenshot(window: "preflight", maxInlineBytes: 0))
        else {
            Issue.record("both should refuse")
            return
        }

        // The distinction is the whole point. "That is not a window" and "that
        // window is not open" send an agent to two different next actions, and
        // collapsing them is the defect `OfflineResponder.filter` already refuses
        // to commit for repositories.
        #expect(unknownCode != closedCode)
        #expect(unknownCode == .windowNotFound)
        #expect(closedCode == .windowNotOpen)

        // Each names its own list, so the reply is actionable without a second
        // round trip.
        #expect(unknownHint?.contains("board") == true)
        #expect(unknownHint?.contains("preflight") == true)
        #expect(unknownMessage.contains("bord"))

        #expect(closedMessage.contains("preflight"))
        #expect(closedHint?.contains("board") == true)
        // The closed refusal must not advertise a window that is shut.
        #expect(closedHint?.contains("preflight") != true)
    }

    @Test("A build with no capturer refuses rather than reporting an empty capture")
    func missingCapturerRefuses() async throws {
        let handler = try await Self.handler(capture: nil)

        let response = await handler.handle(.screenshot(window: "board", maxInlineBytes: 0))

        guard case .failure(let code, _, _) = response else {
            Issue.record("a handler with no window reported \(response)")
            return
        }
        #expect(code == .internalError)
    }

    @Test("A window that has not been laid out is refused, not photographed blank")
    func zeroSizedIsRefused() async throws {
        let handler = try await Self.handler(
            capture: StubCapture(answer: .failure(.notLaidOut(width: 0, height: 0)), seen: .init())
        )

        guard case .failure(let code, let message, _) = await handler.handle(
            .screenshot(window: "analysis", maxInlineBytes: 0)
        ) else {
            Issue.record("a zero-sized window should be refused")
            return
        }
        // A 0×0 bitmap encodes perfectly and arrives as a valid empty picture,
        // which is the exact false negative this tool exists to remove.
        #expect(code == .internalError)
        #expect(message.contains("0"))
    }

    @Test("The default initialiser still compiles and still has no window")
    func defaultInitialiserHasNoCapturer() async throws {
        // Guards the seam itself: `capture:` is defaulted so every existing call
        // site keeps working, and this pins that the default is *absent* rather
        // than some silently-constructed capturer.
        _ = TestHome.root
        let store = try BoardStore.inMemory()
        let launcher = NeverLaunches()
        let board = BoardService(store: store, launcher: launcher)
        let config = ToolConfig(
            ghPath: "/usr/bin/false",
            gitPath: "/usr/bin/false", environment: [:]
        )
        let handler = MCPRequestHandler(
            store: store, board: board,
            analysis: AnalysisService(
                store: store, launcher: launcher, board: board, gh: GHClient(config: config),
                gate: OpenGate()
            )
        )

        guard case .failure(let code, _, _) = await handler.handle(
            .screenshot(window: "board", maxInlineBytes: 0)
        ) else {
            Issue.record("the default handler claimed a window")
            return
        }
        #expect(code == .internalError)
    }
}
