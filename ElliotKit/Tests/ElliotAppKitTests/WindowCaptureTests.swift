import AppKit
import ElliotEngine
import ElliotIPC
import Foundation
import SwiftUI
import TestSupport
import Testing

@testable import ElliotAppKit

/// What can be asserted without a running app: which ids exist, how a window is
/// found, what a capture admits it left out, and that a real `NSWindow` renders
/// to a real PNG.
///
/// The last one is the load-bearing measurement of #155 and it does **not** need
/// the app: `cacheDisplay` draws a view hierarchy in-process, so a window built
/// here — never ordered on screen, in a process that is not frontmost — is
/// exactly the case the tool has to survive.
@Suite("Window capture")
@MainActor
struct WindowCaptureTests {

    /// ⛔ **Touch `TestHome.root` before anything that resolves a `StoreLocation`
    /// path.** SwiftPM links every test target into one process and `ELLIOT_HOME`
    /// is only set by that lazy static, so a capture taken without it writes its
    /// PNG into the developer's *real* `~/Library/Application Support/Elliot`.
    ///
    /// Not hypothetical: the first version of this suite left four files there,
    /// 640×544 — this suite's own 320×240 window at 2×, in Philippe's live board
    /// directory. `TestHome`'s doc comment already stated the rule and this suite
    /// was the one place that skipped it.
    private init() { _ = TestHome.root }

    /// Reports itself open without a window server having to put it on screen.
    ///
    /// A test must not order real windows front — that flashes them at whoever
    /// is running the suite and depends on a display. Overriding the one
    /// property the liveness check reads keeps the assertion about *our* rule
    /// rather than about AppKit's ordering.
    private final class OpenWindow: NSWindow {
        override var isVisible: Bool { true }
    }

    /// A window with something recognisable in it, never ordered front.
    ///
    /// `open` defaults to true because that is the interesting case; pass false
    /// for a window that is closed or has never been shown.
    private func makeWindow(
        id: String,
        title: String,
        size: NSSize = NSSize(width: 320, height: 240),
        open: Bool = true
    ) -> NSWindow {
        let rect = NSRect(origin: .zero, size: size)
        let mask: NSWindow.StyleMask = [.titled, .closable, .resizable]
        let window: NSWindow = open
            ? OpenWindow(contentRect: rect, styleMask: mask, backing: .buffered, defer: false)
            : NSWindow(contentRect: rect, styleMask: mask, backing: .buffered, defer: false)
        window.identifier = NSUserInterfaceItemIdentifier(id)
        window.title = title
        window.contentView = NSHostingView(
            rootView: Rectangle().fill(Color.red).frame(width: size.width, height: size.height)
        )
        return window
    }

    @Test("The known ids are the scenes ElliotApp actually declares")
    func knownWindowsMatchTheSceneGraph() throws {
        // ⚠️ Read out of `ElliotApp.swift`, not restated here. The first version
        // of this test asserted the list against a second copy of itself, which
        // cannot fail: it passed while the list carried `analysis` (retired into
        // a board panel by #151) and lacked `archive` (added by #153) — the two
        // scenes that had moved under this branch while it was in flight. A
        // capture tool with a stale scene list answers `window_not_found` for a
        // real window and `window_not_open` for one that no longer exists, which
        // are precisely the misleading answers it exists to prevent.
        let source = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()      // ElliotAppKitTests
            .deletingLastPathComponent()      // Tests
            .deletingLastPathComponent()      // ElliotKit
            .appendingPathComponent("Sources/ElliotApp/ElliotApp.swift")
        let text = try String(contentsOf: source, encoding: .utf8)

        // Only `Window(…, id: "…")` scene declarations — not the `openWindow(id:)`
        // call sites, which name the same ids and would make the assertion pass
        // by counting the buttons instead of the scenes.
        var declared: Set<String> = []
        for line in text.split(separator: "\n") where line.contains("Window(") {
            guard let idRange = line.range(of: "id: \"") else { continue }
            let rest = line[idRange.upperBound...]
            guard let end = rest.firstIndex(of: "\"") else { continue }
            declared.insert(String(rest[..<end]))
        }

        #expect(!declared.isEmpty, "parsed no scenes out of \(source.path)")
        #expect(
            Set(AppKitWindowCapture.knownWindows) == declared,
            """
            knownWindows has drifted from ElliotApp.swift.
              missing from knownWindows: \(declared.subtracting(AppKitWindowCapture.knownWindows))
              no longer declared:        \(Set(AppKitWindowCapture.knownWindows).subtracting(declared))
            """
        )
    }

    @Test("A window is found by its scene id, which is not its title")
    func lookupIsByIdentifier() {
        // Measured on a real SwiftUI `Window(_:id:)`: `identifier.rawValue` is
        // the declared scene id verbatim, while `title` is the display string.
        // Matching on the title would break the moment a window is localised or
        // retitled with the selection — and would break silently, as "not open".
        let window = makeWindow(id: "board", title: "Elliot")
        let found = AppKitWindowCapture.window(id: "board", among: [window])
        #expect(found === window)
        #expect(AppKitWindowCapture.window(id: "Elliot", among: [window]) == nil)
    }

    @Test("A closed window is not an open one, even though AppKit still lists it")
    func closedWindowIsNotOpen() {
        // Measured with a probe on a real SwiftUI scene: after `performClose`
        // the NSWindow stays in `NSApp.windows` with `isVisible == false`. The
        // first version of this file matched on `identifier` alone, so once a
        // window had been opened `notOpen` became unreachable and a *closed*
        // window was photographed from its stale hierarchy — then reported as
        // `isVisible: false`, which the reply called "not a failed capture".
        let closed = makeWindow(id: "board", title: "Elliot", open: false)
        #expect(closed.isVisible == false)
        #expect(AppKitWindowCapture.isOpen(closed) == false)
        #expect(AppKitWindowCapture.window(id: "board", among: [closed]) == nil)
        #expect(AppKitWindowCapture.openWindowIDs(among: [closed]).isEmpty)
        #expect(AppKitWindowCapture.failure(for: "board", among: [closed]) == .notOpen(open: []))
    }

    @Test("A miniaturised window is still open, because it still has a hierarchy")
    func miniaturisedCountsAsOpen() {
        // The one case where `isVisible == false` must NOT mean closed: a window
        // in the Dock is open and perfectly drawable. Asserted on the predicate
        // rather than by miniaturising for real, which needs a window server.
        final class Miniaturised: NSWindow {
            override var isMiniaturized: Bool { true }
        }
        let docked = Miniaturised(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        docked.identifier = NSUserInterfaceItemIdentifier("board")
        #expect(docked.isVisible == false)
        #expect(AppKitWindowCapture.isOpen(docked))
        #expect(AppKitWindowCapture.openWindowIDs(among: [docked]) == ["board"])
    }

    @Test("An id nobody declared and an id nobody opened are different answers")
    func unknownAndClosedAreDistinct() {
        let open = [makeWindow(id: "board", title: "Elliot")]

        #expect(AppKitWindowCapture.failure(for: "bord", among: open) == .unknownWindow(
            known: AppKitWindowCapture.knownWindows
        ))
        // A declared scene that is simply shut: the answer names what *is* open,
        // and does not name the one that was asked for.
        #expect(AppKitWindowCapture.failure(for: "preflight", among: open) == .notOpen(open: ["board"]))
        // And a window that is open is not a failure at all.
        #expect(AppKitWindowCapture.failure(for: "board", among: open) == nil)
    }

    @Test("The open list only counts Elliot's own scenes")
    func openListIgnoresStrayWindows() {
        // AppKit hands out panels, tooltips and hosting windows nobody declared.
        // Listing them back to an agent as things it could photograph would be
        // an invitation to ask for something that can never work.
        let windows = [
            makeWindow(id: "board", title: "Elliot"),
            makeWindow(id: "NSColorPanel", title: "Colours"),
            NSWindow(),
        ]
        #expect(AppKitWindowCapture.openWindowIDs(among: windows) == ["board"])
    }

    @Test("A bare window admits to hiding nothing")
    func noDisclosuresOnAPlainWindow() {
        // Empty must mean "nothing was left out" and nothing else, or the field
        // stops being readable as evidence.
        #expect(AppKitWindowCapture.disclosures(for: makeWindow(id: "board", title: "Elliot")).isEmpty)
    }

    @Test("A window with a toolbar warns that the toolbar did not draw")
    func toolbarIsDisclosed() {
        // Found by looking at a real capture of the real board and comparing it
        // against an independent whole-screen shot: the toolbar came back as two
        // blank white capsules where seven controls are. Pinned here so the
        // warning cannot be dropped by someone who has not seen that picture.
        let window = makeWindow(id: "board", title: "Elliot")
        window.toolbar = NSToolbar(identifier: "test")

        let said = AppKitWindowCapture.disclosures(for: window)
        #expect(said.contains { $0.contains("toolbar") })
        // And it must say that blank is not a finding, or the disclosure trades
        // one false negative for another.
        #expect(said.contains { $0.contains("NOT evidence") })
    }

    @Test("A child window is named, because the picture cannot contain it")
    func childWindowsAreDisclosed() {
        let parent = makeWindow(id: "board", title: "Elliot")
        parent.addChildWindow(makeWindow(id: "child", title: "Popover"), ordered: .above)

        let said = AppKitWindowCapture.disclosures(for: parent)
        #expect(said.count == 1)
        #expect(said[0].contains("child window"))
    }

    @Test("A real window renders to a real PNG, off screen and not frontmost")
    func capturesAnOffScreenWindow() throws {
        // The measurement the whole feature rests on, run as a test rather than
        // trusted as a claim. This window is never ordered front and this process
        // is not the active application.
        let window = makeWindow(id: "board", title: "Elliot")
        window.layoutIfNeeded()

        let shot = try AppKitWindowCapture.render(window: window, maxInlineBytes: 4 * 1024 * 1024)

        #expect(shot.data.count > 0)
        #expect(shot.pixelWidth > 0)
        #expect(shot.pixelHeight > 0)
        // PNG's magic number: proves an encoder ran, not merely that some bytes
        // were produced.
        #expect(Array(shot.data.prefix(4)) == [0x89, 0x50, 0x4E, 0x47])

        // And it is not a blank rectangle. A 0×0 or an all-transparent bitmap
        // encodes perfectly and arrives looking like a working screenshot of a
        // broken window — the false negative this tool exists to remove.
        let rep = try #require(NSBitmapImageRep(data: shot.data))
        var distinct = Set<String>()
        for y in stride(from: 0, to: rep.pixelsHigh, by: max(1, rep.pixelsHigh / 20)) {
            for x in stride(from: 0, to: rep.pixelsWide, by: max(1, rep.pixelsWide / 20)) {
                if let colour = rep.colorAt(x: x, y: y) {
                    distinct.insert(String(format: "%.1f-%.1f-%.1f",
                                           colour.redComponent,
                                           colour.greenComponent,
                                           colour.blueComponent))
                }
            }
        }
        #expect(distinct.count > 1, "the capture is a single flat colour: \(distinct)")
    }

    @Test("A window with no drawable size is refused rather than photographed")
    func zeroSizedWindowIsRefused() {
        let window = makeWindow(id: "board", title: "Elliot", size: NSSize(width: 0, height: 0))
        #expect(throws: CaptureFailure.self) {
            try AppKitWindowCapture.render(window: window, maxInlineBytes: 1024)
        }
    }

    @Test("A budget too small to honour drops the image instead of blanking it")
    func tinyBudgetDropsTheInlineImage() async throws {
        let window = makeWindow(id: "board", title: "Elliot")
        window.layoutIfNeeded()

        let capture = AppKitWindowCapture(windows: { [window] })
        // One byte: no resampling can reach it, so the honest answer is a path
        // and no inline picture — never a blank one, and never silence.
        guard case .success(let dto) = await capture.capture(window: "board", maxInlineBytes: 1) else {
            Issue.record("a tiny budget should still produce a capture record")
            return
        }
        #expect(dto.pngBase64 == nil)
        #expect(!dto.pngPath.isEmpty)
        #expect(FileManager.default.fileExists(atPath: dto.pngPath))
    }

    @Test("A capture reports the window it photographed, not the one it was asked for")
    func capturedFieldsDescribeTheWindow() async throws {
        let window = makeWindow(id: "operations", title: "Operations")
        window.layoutIfNeeded()

        let capture = AppKitWindowCapture(windows: { [window] })
        guard case .success(let dto) = await capture.capture(
            window: "operations", maxInlineBytes: 8 * 1024 * 1024
        ) else {
            Issue.record("expected a capture")
            return
        }

        #expect(dto.window == "operations")
        #expect(dto.title == "Operations")
        #expect(dto.width > 0)
        #expect(dto.height > 0)
        #expect(dto.scale >= 1)
        // Open, therefore visible. Since the liveness rule landed, `isVisible` is
        // `false` on a capture only for a *miniaturised* window — a closed one is
        // refused before it can be photographed, which is the whole point of that
        // rule. Being in the background does not make it false: measured on the
        // real board, captured with Finder frontmost.
        #expect(dto.isVisible == true)
        #expect(dto.pngBase64 != nil)
    }
}
