import ElliotModel
import Foundation
import TestSupport
import Testing

@testable import ElliotAppKit

/// The assertions that could not exist while `Preferences` had one field.
///
/// `AppModel`'s `panelSpans` setter writes one field of the *held* value on
/// purpose, and its comment says why: rebuilding a fresh `Preferences` per save
/// would store a struct whose other fields are back at their defaults, so "the
/// second preference to be added here would silently reset the first every time
/// either one changed — a data-loss bug that cannot exist while there is only
/// one field, and would arrive fully grown with the second".
///
/// `Preferences.clamped()` had the same shape from the read side: it returned
/// `.default` **wholesale**, which is indistinguishable from clamping one field
/// while there is only one, and throws away an unrelated preference the moment
/// there are two.
///
/// Both were arguments about a field that did not exist yet. `analysisSpans` is
/// that field, so both are now executable — which is the reason this landed
/// before anything that needs a third.
/// `@MainActor` on the suite rather than on each test, matching `AppModelTests`:
/// `AppModel` is main-actor isolated and every test here drives one.
@MainActor
@Suite("A second reader preference")
struct SecondPreferenceTests {

    private func scratchFile(_ label: String) -> URL {
        let directory = TestHome.scratch(label)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("preferences.json")
    }

    // MARK: - The write side

    /// Set one span, then the other, and read the file back: **both** survive.
    ///
    /// This is the test the setter's comment was written for. Against a setter
    /// that rebuilt `Preferences` from scratch, the second write stores the
    /// first field at its default and this fails on the first `#expect`.
    @Test("Writing one span does not reset the other")
    func writingOneSpanKeepsTheOther() {
        let url = scratchFile("prefs-two-fields")
        let file = PreferencesFile(url: url)
        let model = AppModel(preferences: file, initialPreferences: .default)

        model.panelSpans = Preferences.spanChoices.narrow
        model.analysisSpans = Preferences.spanChoices.narrow

        let reread = PreferencesFile.load(from: url)
        #expect(
            reread.panelSpans == Preferences.spanChoices.narrow,
            "setting the analysis span reset the details span — the setter rebuilt the struct"
        )
        #expect(reread.analysisSpans == Preferences.spanChoices.narrow)
    }

    /// The same in the other order, because "writes one field of the held value"
    /// is a property of both setters and a fix applied to one of them would pass
    /// the test above.
    @Test("And in the other order")
    func writingTheOtherSpanKeepsTheFirst() {
        let url = scratchFile("prefs-two-fields-reverse")
        let file = PreferencesFile(url: url)
        let model = AppModel(preferences: file, initialPreferences: .default)

        model.analysisSpans = Preferences.spanChoices.narrow
        model.panelSpans = Preferences.spanChoices.narrow

        let reread = PreferencesFile.load(from: url)
        #expect(reread.analysisSpans == Preferences.spanChoices.narrow)
        #expect(reread.panelSpans == Preferences.spanChoices.narrow)
    }

    /// A width expressed once is not re-expressed every launch — the half of
    /// #132 that #221 was missing.
    @Test("An analysis width survives a relaunch")
    func analysisWidthIsRestored() {
        let url = scratchFile("prefs-analysis-restored")
        let file = PreferencesFile(url: url)

        let first = AppModel(preferences: file, initialPreferences: .default)
        first.analysisSpans = Preferences.spanChoices.narrow

        let next = AppModel(preferences: file, initialPreferences: PreferencesFile.load(from: url))
        #expect(next.analysisSpans == Preferences.spanChoices.narrow)
    }

    // MARK: - The read side

    /// One bad number must not take a good one with it.
    ///
    /// Against the wholesale `return .default`, the hand-edited `panelSpans`
    /// resets `analysisSpans` too and this fails on the second `#expect` — a
    /// preference silently forgotten because an unrelated one was mistyped.
    @Test("A hand-edited span is clamped alone, not with its neighbour")
    func clampingIsPerField() throws {
        let url = scratchFile("prefs-one-bad-field")
        try Data(#"{"panelSpans": 9, "analysisSpans": 2}"#.utf8).write(to: url)

        let loaded = PreferencesFile.load(from: url)
        #expect(loaded.panelSpans == Preferences.default.panelSpans)
        #expect(
            loaded.analysisSpans == Preferences.spanChoices.narrow,
            "a bad panelSpans threw away a perfectly good analysisSpans"
        )
    }

    @Test("And the same the other way round")
    func clampingIsPerFieldReversed() throws {
        let url = scratchFile("prefs-other-bad-field")
        try Data(#"{"panelSpans": 2, "analysisSpans": 0}"#.utf8).write(to: url)

        let loaded = PreferencesFile.load(from: url)
        #expect(loaded.panelSpans == Preferences.spanChoices.narrow)
        #expect(loaded.analysisSpans == Preferences.default.analysisSpans)
    }

    /// The lenient decode has to reach the new field too, or a file written by
    /// the version before this one strands the preference it does declare.
    @Test("A file from before this field loads, keeping the field it does have")
    func olderFileStillLoads() throws {
        let url = scratchFile("prefs-older-file")
        try Data(#"{"panelSpans": 2}"#.utf8).write(to: url)

        let loaded = PreferencesFile.load(from: url)
        #expect(loaded.panelSpans == Preferences.spanChoices.narrow)
        #expect(loaded.analysisSpans == Preferences.default.analysisSpans)
    }

    /// Wrong JSON type reads as absent rather than fatal, which is this type's
    /// stated policy — asserted for the new field because a policy that holds
    /// for one field and not the next is not a policy.
    @Test("A span of the wrong JSON type is absent, not fatal")
    func wrongTypeIsAbsent() throws {
        let url = scratchFile("prefs-wrong-type")
        try Data(#"{"panelSpans": 2, "analysisSpans": "3"}"#.utf8).write(to: url)

        let loaded = PreferencesFile.load(from: url)
        #expect(loaded.panelSpans == Preferences.spanChoices.narrow)
        #expect(loaded.analysisSpans == Preferences.default.analysisSpans)
    }

    // MARK: - The menu's judgement

    /// The title and the act come from the model, so the menu cannot invent a
    /// third span. `ElliotApp` spelled two literal `3`s and a `2` inline, in a
    /// target that cannot import `ElliotModel` and that no test can import
    /// either.
    @Test("Toggling names the other designed width, and only the other one")
    func toggleUsesTheDesignedPair() {
        let model = AppModel()

        model.analysisSpans = Preferences.spanChoices.wide
        #expect(model.analysisWidthToggleTitle == "Narrow Analysis")
        model.toggleAnalysisWidth()
        #expect(model.analysisSpans == Preferences.spanChoices.narrow)

        #expect(model.analysisWidthToggleTitle == "Widen Analysis")
        model.toggleAnalysisWidth()
        #expect(model.analysisSpans == Preferences.spanChoices.wide)
    }

    /// `swift test` must not leave a preference in the operator's home. The
    /// default writer has nowhere to write, and widening the type is exactly
    /// when someone reaches for a convenience default.
    @Test("A model nobody gave a file to writes nothing")
    func defaultModelWritesNothing() {
        let model = AppModel()
        model.analysisSpans = Preferences.spanChoices.narrow
        #expect(model.analysisSpans == Preferences.spanChoices.narrow)
    }
}
