import AppKit
import ElliotEngine
import ElliotIPC
import ElliotModel
import ElliotStore
import Foundation

/// Photographs one of Elliot's own windows, in-process.
///
/// The mechanism is `NSView.cacheDisplay(in:to:)` on the window's **frame** view,
/// and every part of that sentence was measured before it was written:
///
/// - **In-process, so no TCC grant.** ScreenCaptureKit needs Screen Recording,
///   which this machine's automation does not hold and which can be revoked
///   without anything erroring — the failure family `CLAUDE.md` records four
///   times. `CGWindowListCreateImage`, the classic alternative, is not merely
///   deprecated: the macOS 15 SDK marks it *obsoleted*, so it is a compile error
///   on this project's own deployment floor.
/// - **Works off screen.** Measured on a window with `isVisible == false` in an
///   app that was not frontmost: it rendered at full designed size. That is the
///   case this repository has misread as "the window did not open" nine times.
/// - **The frame view, not the content view**, so the title bar is in the
///   picture — which is how a human recognises which window they are looking at.
///
/// The price is that it draws only Elliot's own hierarchy. A sheet, a popover or
/// a menu lives in its *own* window and is simply absent, as is anything from
/// another app. That is knowable at capture time and is therefore reported, in
/// `ScreenshotDTO.notIncluded`, rather than left for the reader to discover.
public struct AppKitWindowCapture: WindowCapturing {
    /// Every scene id `ElliotApp` declares.
    ///
    /// A list rather than a lookup because there is nothing to look it up in:
    /// SwiftUI does not publish its scene graph. `WindowCaptureTests` pins the
    /// membership so a scene added without a line here fails a test instead of
    /// being reported to an agent as a window that does not exist.
    public static let knownWindows = [
        "board", "repositories", "operations", "nextSteps", "preflight", "newStory", "analysis",
    ]

    /// Where the windows come from. Injected so the capture can be tested
    /// against windows a test built, rather than only against a running app.
    private let windows: @MainActor @Sendable () -> [NSWindow]

    public init(
        windows: @escaping @MainActor @Sendable () -> [NSWindow] = { NSApp?.windows ?? [] }
    ) {
        self.windows = windows
    }

    public func capture(
        window id: String, maxInlineBytes: Int
    ) async -> Result<ScreenshotDTO, CaptureFailure> {
        await MainActor.run {
            let all = windows()
            if let failure = Self.failure(for: id, among: all) { return .failure(failure) }
            guard let target = Self.window(id: id, among: all) else {
                // Unreachable given `failure(for:among:)` above, and spelled out
                // rather than force-unwrapped: a crash here would take the whole
                // app down to avoid an error message.
                return .failure(.notOpen(open: Self.openWindowIDs(among: all)))
            }
            do {
                return .success(try Self.photograph(id: id, window: target, budget: maxInlineBytes))
            } catch let failure as CaptureFailure {
                return .failure(failure)
            } catch {
                return .failure(.encodingFailed(error.localizedDescription))
            }
        }
    }

    // MARK: - Finding

    /// By scene id, which is what `NSWindow.identifier` carries for a SwiftUI
    /// `Window(_:id:)` — measured, not assumed.
    ///
    /// Never by title: a title is a display string, it is localised, and on this
    /// board it changes with the selection. Matching on it would fail as "that
    /// window is not open", which is the quiet kind of wrong.
    static func window(id: String, among windows: [NSWindow]) -> NSWindow? {
        windows.first { $0.identifier?.rawValue == id }
    }

    /// The declared scenes that are open right now.
    ///
    /// Filtered against `knownWindows` because AppKit hands out panels, tooltips
    /// and hosting windows nobody declared; offering those back as things an
    /// agent could photograph invites a request that can never work.
    static func openWindowIDs(among windows: [NSWindow]) -> [String] {
        knownWindows.filter { id in windows.contains { $0.identifier?.rawValue == id } }
    }

    /// Why this id cannot be photographed, or `nil` if it can.
    ///
    /// Two failures and not one. "That is not a window" is a typo to fix; "that
    /// window is not open" is a window to open. An agent told only that
    /// *something* was wrong retries the one that can never succeed.
    static func failure(for id: String, among windows: [NSWindow]) -> CaptureFailure? {
        guard knownWindows.contains(id) else { return .unknownWindow(known: knownWindows) }
        guard window(id: id, among: windows) != nil else {
            return .notOpen(open: openWindowIDs(among: windows))
        }
        return nil
    }

    // MARK: - Disclosing

    /// What this picture cannot contain, in words.
    ///
    /// The honest half of the trade this capture makes. An attached sheet and a
    /// popover are separate windows, so they are invisible to a hierarchy render
    /// — and "the sheet is not in the picture" must never be readable as "the
    /// sheet did not open".
    @MainActor
    static func disclosures(for window: NSWindow) -> [String] {
        var said: [String] = []
        if let sheet = window.attachedSheet {
            said.append("attached sheet: \(sheet.title.isEmpty ? "untitled" : sheet.title)")
        }
        let children = window.childWindows?.count ?? 0
        if children > 0 {
            said.append(
                "\(children) child window\(children == 1 ? "" : "s") "
                    + "(popovers and menus draw in their own windows and are not in this picture)"
            )
        }
        // ⚠️ Measured on the real board, not predicted. A `cacheDisplay` of the
        // frame view renders the toolbar's *material* and not its contents: the
        // picture came back with two blank white capsules where "All
        // repositories", "New story", "Refresh", "Analyse", "Details",
        // "Repositories" and "Preflight" actually are — confirmed by comparing
        // it against an independent whole-screen capture of the same window.
        //
        // SwiftUI hosts `.toolbar` items in titlebar accessory view controllers,
        // a hierarchy hung off the window rather than inside the frame view's
        // draw path. This is said out loud because the toolbar is precisely
        // where this project's changes land — `BoardView.swift`'s toolbar is a
        // named conflict hot-spot — so a silently blank one would let a toolbar
        // regression pass a look that appeared to work. That is the exact
        // false negative this tool exists to close, and it must not be the tool
        // producing it.
        if window.toolbar != nil {
            said.append(
                "toolbar controls (they render blank: SwiftUI draws .toolbar items in titlebar "
                    + "accessory views, which an in-process hierarchy render does not reach — "
                    + "blank here is NOT evidence a toolbar item is missing or broken)"
            )
        }
        return said
    }

    // MARK: - Drawing

    /// One rendered bitmap and what it cost.
    struct Rendered {
        var data: Data
        var pixelWidth: Int
        var pixelHeight: Int
        /// Points, as laid out — the numbers a human compares against a design.
        var pointWidth: Double
        var pointHeight: Double
        /// The window's real backing scale, which is what the file on disk is at.
        var backingScale: Double
        /// The linear factor applied to the inline copy, `1.0` when none was.
        var inlineFactor: Double
        /// The inline copy, or `nil` when no scale inside the floor could fit the
        /// budget. Absent rather than blank: a 0×0 picture arrives looking like a
        /// working screenshot of a broken window.
        var inline: Data?
    }

    @MainActor
    static func render(window: NSWindow, maxInlineBytes: Int) throws -> Rendered {
        guard let content = window.contentView else {
            throw CaptureFailure.encodingFailed("that window has no content view")
        }
        // The frame view rather than the content view, so the title bar — and
        // with it the window's identity — is in the picture.
        let view = content.superview ?? content
        let bounds = view.bounds
        guard bounds.width >= 1, bounds.height >= 1 else {
            throw CaptureFailure.notLaidOut(width: bounds.width, height: bounds.height)
        }
        guard let rep = view.bitmapImageRepForCachingDisplay(in: bounds) else {
            throw CaptureFailure.encodingFailed("AppKit would not allocate a bitmap for that window")
        }
        view.cacheDisplay(in: bounds, to: rep)
        guard let full = rep.representation(using: .png, properties: [:]) else {
            throw CaptureFailure.encodingFailed("the bitmap could not be encoded as PNG")
        }

        let budget = maxInlineBytes > 0 ? maxInlineBytes : ScreenshotBudget.defaultInlineBytes
        var inline: Data? = full
        var factor = 1.0
        if ScreenshotBudget.base64Size(ofRawBytes: full.count) > budget {
            factor = ScreenshotBudget.scale(
                toFit: ScreenshotBudget.base64Size(ofRawBytes: full.count), budget: budget
            )
            let resampled = downscale(rep, by: factor)
            // Checked again after resampling rather than trusted: the budget
            // maths assumes bytes follow area, and PNG compression does not owe
            // anyone that. A copy that is still over budget is dropped, and the
            // reply says the picture is missing instead of shipping it anyway.
            inline = resampled.flatMap {
                ScreenshotBudget.base64Size(ofRawBytes: $0.count) <= budget ? $0 : nil
            }
        }

        return Rendered(
            data: full,
            pixelWidth: rep.pixelsWide,
            pixelHeight: rep.pixelsHigh,
            pointWidth: bounds.width,
            pointHeight: bounds.height,
            backingScale: window.backingScaleFactor,
            inlineFactor: inline == nil ? 1.0 : factor,
            inline: inline
        )
    }

    /// Resamples with high interpolation. Nearest-neighbour on a board of small
    /// text produces something that is technically a picture and practically
    /// unreadable, which would defeat the point of sending one at all.
    @MainActor
    static func downscale(_ rep: NSBitmapImageRep, by factor: Double) -> Data? {
        let width = max(1, Int(Double(rep.pixelsWide) * factor))
        let height = max(1, Int(Double(rep.pixelsHigh) * factor))
        guard let target = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ) else { return nil }
        target.size = NSSize(width: width, height: height)

        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        guard let context = NSGraphicsContext(bitmapImageRep: target) else { return nil }
        NSGraphicsContext.current = context
        context.imageInterpolation = .high
        rep.draw(in: NSRect(x: 0, y: 0, width: width, height: height))
        context.flushGraphics()

        return target.representation(using: .png, properties: [:])
    }

    // MARK: - Assembling

    @MainActor
    static func photograph(id: String, window: NSWindow, budget: Int) throws -> ScreenshotDTO {
        let rendered = try render(window: window, maxInlineBytes: budget)
        let path = try write(rendered.data, for: id)

        return ScreenshotDTO(
            window: id,
            title: window.title,
            width: Int(rendered.pointWidth.rounded()),
            height: Int(rendered.pointHeight.rounded()),
            // The effective scale of the picture that travelled, so a reader can
            // multiply it by the points above and get the pixels they received.
            scale: rendered.backingScale * rendered.inlineFactor,
            pngPath: path,
            pngBase64: rendered.inline?.base64EncodedString(),
            byteCount: rendered.inline.map { ScreenshotBudget.base64Size(ofRawBytes: $0.count) } ?? 0,
            downscaledFrom: rendered.inlineFactor < 1 ? rendered.backingScale : nil,
            // Reported, never judged. A background window is `false` here and is
            // a perfectly good capture — that is the entire point of the design.
            isVisible: window.isVisible,
            isKeyWindow: window.isKeyWindow,
            notIncluded: disclosures(for: window)
        )
    }

    /// Writes the full-resolution PNG and hands back its path.
    ///
    /// Always, even when the inline copy fits: the file is the lossless sink, and
    /// a caller that needs to read a column caption needs the pixels the reply
    /// could not afford.
    static func write(_ data: Data, for id: String) throws -> String {
        try FileManager.default.createDirectory(
            at: StoreLocation.screenshotsDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let url = StoreLocation.screenshotURL(window: id, at: Date())
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            throw CaptureFailure.encodingFailed(
                "the capture could not be written to \(url.path): \(error.localizedDescription)"
            )
        }
        return url.path
    }
}
