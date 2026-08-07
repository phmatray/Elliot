import AppKit
import ElliotEngine
import ElliotIPC
import Foundation
import SwiftUI
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

    /// A window with something recognisable in it, never ordered front.
    private func makeWindow(id: String, title: String, size: NSSize = NSSize(width: 320, height: 240))
        -> NSWindow
    {
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.identifier = NSUserInterfaceItemIdentifier(id)
        window.title = title
        window.contentView = NSHostingView(
            rootView: Rectangle().fill(Color.red).frame(width: size.width, height: size.height)
        )
        return window
    }

    @Test("The known ids are the scenes ElliotApp declares")
    func knownWindowsMatchTheSceneGraph() {
        // Pinned as a set, because the *order* is presentation and the
        // *membership* is the contract: an id missing here is a window an agent
        // is told does not exist.
        #expect(
            Set(AppKitWindowCapture.knownWindows) == [
                "board", "repositories", "operations", "nextSteps",
                "preflight", "newStory", "analysis",
            ]
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
        // Never ordered front, so this is the honest reading — and it is not a
        // failure.
        #expect(dto.isVisible == false)
        #expect(dto.pngBase64 != nil)
    }
}
