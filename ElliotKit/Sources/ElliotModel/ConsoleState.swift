import Foundation

/// The two heights the console is designed at.
///
/// Two, and not a continuous range, for the reason `Preferences.spanChoices`
/// gives about the panel: every height between them is a console too tall to be
/// a glance and too short to be a screen. The drag snaps, so a reader who lets
/// go anywhere lands on one of the two layouts that were drawn.
///
/// An enum rather than the panel's `Int` spans, deliberately. The panel's number
/// is a count of board columns and arithmetic is performed on it; this one is a
/// choice between two designs, and an `Int` here would admit a `7` that
/// `Preferences.clamped()` would then have to repair. There is no value of this
/// type that needs repairing.
public enum ConsoleHeight: String, CaseIterable, Sendable, Hashable, Codable {
    /// A glance: enough for the figure the reader pressed and the few rows
    /// around it, with the board still showing whole cards above.
    case short
    /// A working height: the screen as it read when it was a window, at the cost
    /// of the board being scrolled rather than surveyed.
    case tall

    /// The other one. Named here rather than written as a ternary at each call
    /// site, which is how `panelWidthToggleTitle` came to exist.
    public var toggled: ConsoleHeight {
        switch self {
        case .short: .tall
        case .tall: .short
        }
    }
}

/// Which face the console is showing, and how tall it is.
///
/// A value type with its transitions on it, rather than two properties on
/// `AppModel`, because the transitions are where the rule is: pressing a door
/// twice is not the same act as choosing a screen from a menu, and a view that
/// held `face` directly would have to decide that afresh at every call site.
///
/// Pure — no clock, no store, no view — so `swift test` can hold the whole of
/// it, which is the standing reason this app's rules live below its views.
public struct ConsoleState: Equatable, Sendable, Codable {

    /// The face on screen, or `nil` when the console is folded away.
    ///
    /// One optional rather than a `Bool` beside a face: an `isOpen` that could
    /// disagree with the face is a state the type should not be able to hold,
    /// and "open, showing nothing" is not a console.
    public private(set) var face: ConsoleFace?

    /// Kept across a close, so re-opening returns the reader to the height they
    /// chose rather than to the default. It is a preference, and a preference
    /// that resets when you shut the thing is not one.
    public var height: ConsoleHeight

    public init(face: ConsoleFace? = nil, height: ConsoleHeight = .short) {
        self.face = face
        self.height = height
    }

    public var isOpen: Bool { face != nil }

    /// What a **door in the status bar** does: press the face already showing
    /// and the console folds away; press another and it switches without ever
    /// closing.
    ///
    /// The toggle belongs to the door because the door is where the reader's
    /// eye already is — the figure they pressed is the thing they are reading —
    /// so pressing it again is unmistakably "put this away". Switching without
    /// a close is the other half: a console that shut and re-opened between two
    /// doors would animate a fold for a reader who asked for neither.
    public mutating func press(_ face: ConsoleFace) {
        self.face = self.face == face ? nil : face
    }

    /// What a **menu item** does: show this face, whatever was showing.
    ///
    /// Deliberately not `press`. A menu item named "Operations" that closed
    /// Operations because it happened to be open would be an item that does the
    /// opposite of what it says on every second use, and unlike a door it
    /// carries no figure to make the toggle read as one.
    public mutating func show(_ face: ConsoleFace) {
        self.face = face
    }

    /// Fold the console away, keeping the height for next time.
    public mutating func close() {
        face = nil
    }
}
