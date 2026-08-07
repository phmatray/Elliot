import Foundation

/// What a reader chose about how Elliot looks, kept between launches.
///
/// Distinct from everything in the store, and deliberately: board state is what
/// GitHub and the engine establish, and this is what a person expressed with a
/// gesture. Nothing here crosses the MCP socket, and none of it is a fact about
/// a card.
///
/// The type is pure because the only thing about a preference that is a *rule*
/// is what a valid value is, and that question is asked at the one point where
/// the answer cannot be trusted: reading a file. The two affordances that set
/// the panel's width — the drag handle and View ▸ Narrow/Widen — can only
/// produce the two designed spans, so nothing in the app needs the clamp.
/// A `preferences.json` someone hand-edited does.
public struct Preferences: Codable, Sendable, Equatable {

    /// The only two widths the details panel is designed at, and therefore the
    /// only two values ``panelSpans`` may hold.
    ///
    /// ⚠️ **This is the single definition** — `PanelLayout.spanChoices` is a
    /// re-export of it, not a second copy. It lives down here rather than beside
    /// the layout because the *clamp* needs it and `ElliotModel` is
    /// dependency-free, so the alternative was writing `2` and `3` in two
    /// targets and hoping they stayed equal. `PanelLayout.snappedSpans` explains
    /// what the pair means for a drag; `PanelResizeTests` pins the numbers
    /// themselves at the layout that uses them.
    public static let spanChoices = (narrow: 2, wide: 3)

    /// How many board columns wide the details panel opens.
    ///
    /// Stored as the span rather than a width in points: spans are what the
    /// model holds, and points are a function of the window — a remembered
    /// width would be wrong the first time the reader resized the window.
    public var panelSpans: Int

    /// What a reader who has never expressed a preference gets.
    ///
    /// The wide panel, which is the mockup's two-pane body: the issue and the
    /// runs side by side.
    public static let `default` = Preferences(panelSpans: spanChoices.wide)

    public init(panelSpans: Int = Preferences.spanChoices.wide) {
        self.panelSpans = panelSpans
    }

    /// Decodes leniently, so that a file written by another version still loads.
    ///
    /// A missing field takes the default and an unrecognised one is ignored,
    /// which is what lets a field be added later without stranding the files
    /// already on disk. **A field of the wrong JSON type is also treated as
    /// absent** rather than thrown: the file is hand-editable, `"2"` for `2` is
    /// the likeliest way a hand edit goes wrong, and the whole of this type's
    /// policy is `NotificationPresenter.preferences`'s — *"a payload that will
    /// not decode is treated as absent rather than fatal"*.
    ///
    /// It does **not** clamp. Deciding whether to trust the value belongs to
    /// whoever read the file (``PreferencesFile.load``), because a decode that
    /// quietly corrected its input would leave nothing able to tell a written 3
    /// from a repaired 9.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // `try?` rather than `decodeIfPresent`, which throws on a present key of
        // the wrong type and would make `"2"` fatal where a missing key is not.
        panelSpans =
            (try? container.decode(Int.self, forKey: .panelSpans))
            ?? Preferences.default.panelSpans
    }

    /// This value if the app could have produced it, the default otherwise.
    ///
    /// Called on the way out of the file and nowhere else. `PanelLayout.snappedSpans`
    /// already documents this exact case from the other side — *"a span outside
    /// the two choices (which the menu cannot produce, but an integer preference
    /// can hold) resolves to the default instead"* — and this is the integer
    /// preference it was anticipating.
    public func clamped() -> Preferences {
        guard panelSpans == Preferences.spanChoices.narrow
            || panelSpans == Preferences.spanChoices.wide
        else { return .default }
        return self
    }
}
