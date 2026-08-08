import Foundation
import Testing

@testable import ElliotModel

/// What a reader chose, and the one rule about it that is a rule: which panel
/// spans are values a reader could actually have produced.
///
/// The clamp is here rather than beside the file that reads it because a
/// preference arrives from **disk**, where anything at all can be written, while
/// the two affordances that set it — the drag handle and View ▸ Narrow/Widen —
/// can only produce the two designed widths. `PanelLayout.snappedSpans` already
/// says so about the same integer: *"a span outside the two choices (which the
/// menu cannot produce, but an integer preference can hold) resolves to the
/// default instead"*. This suite is that sentence's other half.
@Suite("Reader preferences")
struct PreferencesTests {

    // MARK: - The clamp

    @Test("The two designed spans survive the clamp untouched")
    func designedSpansAreLeftAlone() {
        for spans in [Preferences.spanChoices.narrow, Preferences.spanChoices.wide] {
            #expect(Preferences(panelSpans: spans).clamped().panelSpans == spans)
        }
    }

    @Test("A span the panel was never designed at resolves to the default")
    func nonsenseSpansResolveToTheDefault() {
        for spans in [0, 1, 4, -7, Int.max, Int.min] {
            #expect(
                Preferences(panelSpans: spans).clamped() == .default,
                "\(spans) is not a width the panel is designed at"
            )
        }
    }

    @Test("Clamping is idempotent — a clamped value clamps to itself")
    func clampIsIdempotent() {
        for spans in [0, 1, 2, 3, 4, -7] {
            let once = Preferences(panelSpans: spans).clamped()
            #expect(once.clamped() == once)
        }
    }

    @Test("The default is the wide panel, the two-pane body")
    func theDefaultIsWide() {
        #expect(Preferences.default.panelSpans == Preferences.spanChoices.wide)
        #expect(Preferences.default == Preferences.default.clamped())
    }

    @Test("The narrow span is narrower than the wide one, and they differ")
    func spanChoicesAreOrdered() {
        #expect(Preferences.spanChoices.narrow < Preferences.spanChoices.wide)
    }

    // MARK: - Decoding, which has to survive a file nobody validated

    @Test("A payload with no panelSpans at all decodes to the default")
    func missingFieldDecodesToTheDefault() throws {
        let decoded = try JSONDecoder().decode(Preferences.self, from: Data("{}".utf8))
        #expect(decoded == .default)
    }

    @Test("A payload carrying a field this version has never heard of still decodes")
    func unknownFieldsAreIgnored() throws {
        let json = #"{"panelSpans": 2, "somethingAddedLater": {"nested": [1, 2]}}"#
        let decoded = try JSONDecoder().decode(Preferences.self, from: Data(json.utf8))
        #expect(decoded.panelSpans == 2)
    }

    @Test("Encode then decode round-trips both designed spans")
    func encodeDecodeRoundTrips() throws {
        for spans in [Preferences.spanChoices.narrow, Preferences.spanChoices.wide] {
            let original = Preferences(panelSpans: spans)
            let data = try JSONEncoder().encode(original)
            #expect(try JSONDecoder().decode(Preferences.self, from: data) == original)
        }
    }

    @Test("Decoding is faithful, and clamping is a separate act")
    func decodeDoesNotClamp() throws {
        // Kept apart deliberately: the reader of the file decides whether to
        // trust what it holds (`PreferencesFile.load` clamps), and a decode that
        // silently corrected its input would leave nothing able to tell a
        // written 3 from a repaired 9.
        let decoded = try JSONDecoder().decode(
            Preferences.self, from: Data(#"{"panelSpans": 9}"#.utf8)
        )
        #expect(decoded.panelSpans == 9)
        #expect(decoded.clamped() == .default)
    }

    @Test("A panelSpans of the wrong JSON type is not fatal either")
    func wrongTypeDecodesToTheDefault() throws {
        // A hand-edited file is the whole reason this type is lenient, and
        // `"2"` is the most likely way a hand edit goes wrong.
        let decoded = try JSONDecoder().decode(
            Preferences.self, from: Data(#"{"panelSpans": "2"}"#.utf8)
        )
        #expect(decoded == .default)
    }
}
