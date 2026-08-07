import Foundation

/// How much of a screenshot may travel inline in a tool result.
///
/// The same bargain `ElliotMCPServer.logTailLimit` strikes for a run log: the
/// full-resolution file is always written to disk, and what comes back in the
/// reply is bounded. A board window at 2× is a few hundred kilobytes of PNG
/// before base64, and an agent that asked one question should not have its
/// context spent by the answer.
///
/// Here rather than beside the capture because it is arithmetic: no AppKit, no
/// clock, no file system. The capture decides what to draw; this decides how big
/// what it drew is allowed to arrive.
public enum ScreenshotBudget {
    /// Enough for a downscaled board window, small enough not to bury a context.
    public static let defaultInlineBytes = 768 * 1024

    /// The floor on the linear scale.
    ///
    /// Not a tuning knob — a guard. Without it a pathologically large capture
    /// scales towards zero and produces a 0×0 bitmap, which encodes cleanly and
    /// arrives as a valid, empty picture. That is exactly the false negative this
    /// tool exists to remove, manufactured by the code meant to prevent it. A
    /// capture that still does not fit at this scale is reported *without* an
    /// inline image and with a reason, rather than with a blank one.
    public static let minimumScale = 0.05

    /// The linear scale to draw at so the result lands inside `budget`.
    ///
    /// Square root, not the ratio itself: bytes follow the pixel count, and pixels
    /// are the product of two dimensions. Scaling each side by the ratio would
    /// overshoot to its square — asked to halve, it would quarter, and the caller
    /// would read the too-small picture as a bad capture rather than as a budget
    /// working.
    ///
    /// A non-positive `budget` or `byteCount` means "you decide" rather than
    /// "none", which is the reading `ElliotPaging.clamp` already gives a
    /// non-positive limit.
    public static func scale(toFit byteCount: Int, budget: Int) -> Double {
        guard budget > 0, byteCount > budget else { return 1.0 }
        let ratio = Double(budget) / Double(byteCount)
        return max(minimumScale, min(1.0, ratio.squareRoot()))
    }

    /// What `count` raw bytes cost once base64-encoded: four characters per three
    /// bytes, rounded up to the group.
    ///
    /// Spelled out because the budget is spent in *encoded* bytes while a PNG is
    /// measured in raw ones. Comparing a file size against an encoded budget ships
    /// a third more than asked for, every time, with nothing reporting an
    /// overrun — the quiet kind of wrong this repository keeps finding.
    public static func base64Size(ofRawBytes count: Int) -> Int {
        guard count > 0 else { return 0 }
        return ((count + 2) / 3) * 4
    }
}
