import Foundation

/// One screen the console can unfold, and the single vocabulary the app and the
/// MCP helper share for naming it.
///
/// The board is deliberately **not** a case. The board is the window; these are
/// what unfolds inside it, above the status bar. A `.board` face would name
/// something the console can never show, and every `switch` over this type would
/// carry a branch that cannot happen.
///
/// **The raw values are today's scene ids, byte for byte**, and that is a
/// compatibility promise rather than a coincidence. `board_screenshot
/// window=archive` is the only way an agent has ever named a screen, and #232
/// measured what it answers: every window but the board is `window_not_open`,
/// because opening one takes a click and an agent has no click. When a screen
/// stops being a window its *name* has to keep meaning the same screen, or the
/// fix for #232 arrives as a breaking change to the one caller it exists to
/// serve.
///
/// ⚠️ **`nextSteps` was a case here and is not one now (#304).** Up next did not
/// move to a third way of being reached — it stopped being a screen. It is a
/// *band* of Operations, in the way Workers, Waiting and Spending are, and a face
/// for it meant one ranking drawn twice: the face's rows moved a card, the band's
/// rows did nothing, and *"See all N"* opened the face purely to recover the
/// affordance the reader was already looking at.
///
/// The published-id promise below is not weakened by that, and the reason is
/// worth stating rather than assuming. These raw values reach **no runtime
/// caller**: `board_screenshot` resolves a window through `ElliotWindows.all` and
/// prints `ElliotWindows.sentence`, both of which have said `board` alone since
/// the console landed. So `window=nextSteps` has answered `window_not_found` for
/// as long as the face existed, and retiring the case changes nothing an agent
/// can observe. What changes is the *count of screens*, which is what
/// `ConsoleFaceTests` freezes — so that literal moves, in front of a comment
/// saying where Up next went.
public enum ConsoleFace: String, CaseIterable, Sendable, Hashable, Identifiable, Codable {
    case repositories
    case operations
    case preflight
    case archive
    case newStory

    public var id: String { rawValue }

    /// What the door in the status bar is called, and what the face titles
    /// itself once it is open.
    ///
    /// Taken from the `Window(_:id:)` titles in `ElliotApp.swift` rather than
    /// invented, so the screen a reader learned to call "Up next" is still
    /// called that when it stops being a window. `WindowCaptureTests` already
    /// parses that file; this is the same discipline applied to the label
    /// instead of the id.
    public var title: String {
        switch self {
        case .repositories: "Repositories"
        case .operations: "Operations"
        case .preflight: "Preflight"
        case .archive: "Archive"
        case .newStory: "New story"
        }
    }

    /// Every screen Elliot has, however it is currently reached.
    ///
    /// The union — not the equality — because the two halves are *supposed* to
    /// move: `ElliotWindows.all` held all seven ids before the console and holds
    /// `["board"]` now, while the faces gained exactly what it lost. Through that
    /// migration this set was constant, which is the property worth a test: a
    /// screen may change how it is reached and may not stop existing.
    ///
    /// ⚠️ **It is one smaller since #304, and that is a different kind of change
    /// from the migration this set was written for.** Up next was not re-reached;
    /// it was absorbed into Operations as a band. A set called *every screen
    /// Elliot has* that still listed it would be keeping a test literal frozen by
    /// telling a lie, so the name leaves — and `ConsoleFaceTests` records where it
    /// went rather than quietly dropping it.
    ///
    /// Written here rather than in `ElliotWindows` because `ElliotWindows` is the
    /// list of *scenes* — a fact about `ElliotApp.swift` that a test already
    /// checks against that file — and this is a fact about the product.
    public static var allScreens: Set<String> {
        Set(ElliotWindows.all).union(ConsoleFace.allCases.map(\.rawValue))
    }
}
