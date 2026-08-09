import Foundation

/// The scene ids `ElliotApp` declares.
///
/// Here, in the target with no dependencies, because two layers need it and they
/// cannot see each other: `ElliotAppKit` resolves an id to an `NSWindow`, and
/// `ElliotMCPKit` prints the list in the tool description — the only
/// documentation an agent ever reads — while deliberately importing neither
/// `ElliotEngine` nor anything above it.
///
/// ⚠️ **Two copies of this list is not hypothetical drift; it happened.** While
/// #155 was in flight, `main` retired the Analysis *window* into a board panel
/// (#151) and added the Archive one (#153). The capture list and the tool
/// description each named the old set, so `board_screenshot` would have refused
/// `archive` as unknown and offered `analysis` as merely closed — the two
/// misleading answers the tool exists to prevent, produced by the tool itself.
///
/// `WindowCaptureTests` parses `ElliotApp.swift` and compares it to this, so the
/// next such move fails a test instead of reaching an agent.
public enum ElliotWindows {
    /// ⚠️ **This list shrinks as the console grows, and that is the design.**
    /// `operations` and `nextSteps` left it in the first console wave: they are
    /// `ConsoleFace` cases now, reached inside the board window, so there is no
    /// scene for `board_screenshot` to find and none for it to report shut.
    /// `ConsoleFace.allScreens` is the union of this list and the faces, and
    /// *that* is constant — a screen may change how it is reached and may not
    /// stop existing.
    public static let all = [
        "board", "archive", "newStory",
    ]

    /// For prose: `"board, repositories, …"`.
    public static var sentence: String { all.joined(separator: ", ") }
}
