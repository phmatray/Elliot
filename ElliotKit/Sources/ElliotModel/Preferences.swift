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

    /// How many board columns wide the analysis panel opens.
    ///
    /// A *separate* preference from ``panelSpans`` rather than a shared number,
    /// for the reason `AppModel.analysisSpans` gives: they are two panels a
    /// reader sets independently, and widening the analysis to read a proposal
    /// must not also widen a card detail nobody is looking at.
    ///
    /// It is the second field, and that is the whole significance of this
    /// property beyond the feature. `AppModel`'s `panelSpans` setter writes one
    /// field of the *held* value on purpose, because rebuilding a fresh
    /// `Preferences` per save would make each setter store a struct whose other
    /// fields are back at their defaults — "a data-loss bug that cannot exist
    /// while there is only one field, and would arrive fully grown with the
    /// second". Until now that reasoning had never been executed. It can be
    /// tested from here on.
    public var analysisSpans: Int

    /// What the reader has agreed to be interrupted by.
    ///
    /// Here rather than in `UserDefaults` (#222). `StoreLocation` already argued
    /// the case in code: *"`UserDefaults.standard` is keyed by bundle
    /// identifier, so nothing can point it at a different home"* — and every
    /// on-screen verification in this project launches a second instance against
    /// a scratch `ELLIOT_HOME`. Anything left in `.standard` therefore bleeds the
    /// operator's real notification settings into the capture, and a scratch
    /// instance can mute a category in the operator's own board.
    ///
    /// It keeps its own hand-written lenient decode — an unknown category is
    /// dropped rather than thrown — so a payload written by a build with a fifth
    /// category does not turn into "no preferences at all" and silently unmute
    /// everything the reader switched off.
    public var notifications: NotificationPreferences

    /// What a reader who has never expressed a preference gets.
    ///
    /// The wide panel, which is the mockup's two-pane body: the issue and the
    /// runs side by side. The analysis opens wide for its own reason — the setup
    /// screen's lens grid is two columns, and a proposal row carries a title, a
    /// narrative, a rationale and an evidence strip.
    public static let `default` = Preferences(
        panelSpans: spanChoices.wide,
        analysisSpans: spanChoices.wide,
        notifications: .default
    )

    public init(
        panelSpans: Int = Preferences.spanChoices.wide,
        analysisSpans: Int = Preferences.spanChoices.wide,
        notifications: NotificationPreferences = .default
    ) {
        self.panelSpans = panelSpans
        self.analysisSpans = analysisSpans
        self.notifications = notifications
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
        analysisSpans =
            (try? container.decode(Int.self, forKey: .analysisSpans))
            ?? Preferences.default.analysisSpans
        notifications =
            (try? container.decode(NotificationPreferences.self, forKey: .notifications))
            ?? Preferences.default.notifications
    }

    /// Each value if the app could have produced it, that value's default
    /// otherwise.
    ///
    /// Called on the way out of the file and nowhere else. `PanelLayout.snappedSpans`
    /// already documents this exact case from the other side — *"a span outside
    /// the two choices (which the menu cannot produce, but an integer preference
    /// can hold) resolves to the default instead"* — and this is the integer
    /// preference it was anticipating.
    ///
    /// ⚠️ **Per field, not the whole struct.** This returned `.default` wholesale
    /// while there was one field, which was indistinguishable from clamping that
    /// field. With two it is not: a hand-edited `panelSpans: 9` would have thrown
    /// away a perfectly good `analysisSpans` on the way past, so one bad number
    /// in the file would silently forget an unrelated preference. That is the
    /// same shape as the rebuild-versus-mutate trap in `AppModel`'s setter — a
    /// bug that could not exist with one field and arrives fully grown with the
    /// second — reached from the read side instead of the write side.
    ///
    /// A field added later must get its own line here. There is deliberately no
    /// loop over "all the span fields": the next preference will not be a span.
    public func clamped() -> Preferences {
        Preferences(
            panelSpans: Preferences.clampSpan(panelSpans, default: Preferences.default.panelSpans),
            analysisSpans: Preferences.clampSpan(
                analysisSpans, default: Preferences.default.analysisSpans
            ),
            // Not clamped, and not by omission: `NotificationPreferences` has no
            // invalid value a hand edit could produce. Its own decode already
            // drops a category it does not recognise, and every combination of
            // the master switch and the muted set is one the app can reach.
            notifications: notifications
        )
    }

    /// One span, trusted or replaced. Extracted so the two fields cannot be
    /// clamped by two slightly different expressions.
    private static func clampSpan(_ value: Int, default fallback: Int) -> Int {
        let designed = [spanChoices.narrow, spanChoices.wide]
        return designed.contains(value) ? value : fallback
    }
}
