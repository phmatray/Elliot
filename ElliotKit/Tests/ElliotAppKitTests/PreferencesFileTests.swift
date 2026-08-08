import ElliotModel
import Foundation
import TestSupport
import Testing

@testable import ElliotAppKit

/// Reading and writing the preferences file, and the default that does neither.
///
/// Every test here hands over a URL of its own. Nothing in this suite resolves
/// `StoreLocation`, which is deliberate: a reader that reached for the
/// environment would make its own behaviour depend on which suite ran first, and
/// that ordering hazard is the reason this feature was deferred once already.
@Suite("The preferences file")
struct PreferencesFileTests {

    private func scratchFile(_ label: String) -> URL {
        let directory = TestHome.scratch(label)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("preferences.json")
    }

    // MARK: - Reading a file nobody validated

    @Test("A file that is not there is the first launch, not an error")
    func missingFileLoadsTheDefault() {
        let url = scratchFile("prefs-missing").deletingLastPathComponent()
            .appendingPathComponent("never-written.json")
        #expect(!FileManager.default.fileExists(atPath: url.path))
        #expect(PreferencesFile.load(from: url) == .default)
    }

    @Test("Bytes that are not JSON load the default rather than throwing")
    func malformedBytesLoadTheDefault() throws {
        let url = scratchFile("prefs-malformed")
        try Data("this is not json {{{".utf8).write(to: url)
        #expect(PreferencesFile.load(from: url) == .default)
    }

    @Test("An empty file loads the default")
    func emptyFileLoadsTheDefault() throws {
        let url = scratchFile("prefs-empty")
        try Data().write(to: url)
        #expect(PreferencesFile.load(from: url) == .default)
    }

    @Test("A span the panel was never designed at is repaired on the way out")
    func storedNonsenseIsClamped() throws {
        let url = scratchFile("prefs-nonsense")
        try Data(#"{"panelSpans": 9}"#.utf8).write(to: url)
        let loaded = PreferencesFile.load(from: url)
        #expect(loaded == .default)
        #expect(loaded.panelSpans != 9)
    }

    @Test("A directory where a file was expected is also just the default")
    func aDirectoryLoadsTheDefault() {
        let url = TestHome.scratch("prefs-directory")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        #expect(PreferencesFile.load(from: url) == .default)
    }

    // MARK: - Writing

    @Test("Both designed spans survive a save and a load at the same URL")
    func saveThenLoadRoundTrips() {
        for spans in [Preferences.spanChoices.narrow, Preferences.spanChoices.wide] {
            let url = scratchFile("prefs-roundtrip-\(spans)")
            PreferencesFile(url: url).save(Preferences(panelSpans: spans))
            #expect(FileManager.default.fileExists(atPath: url.path))
            #expect(PreferencesFile.load(from: url).panelSpans == spans)
        }
    }

    @Test("A second save replaces the first rather than appending to it")
    func saveOverwrites() {
        let url = scratchFile("prefs-overwrite")
        let file = PreferencesFile(url: url)
        file.save(Preferences(panelSpans: Preferences.spanChoices.wide))
        file.save(Preferences(panelSpans: Preferences.spanChoices.narrow))
        #expect(PreferencesFile.load(from: url).panelSpans == Preferences.spanChoices.narrow)
    }

    @Test("Saving into a tree that does not exist loses the preference, and nothing else")
    func saveIntoMissingDirectoryIsQuiet() {
        // `StoreLocation.ensureDirectories()` makes the home before anything
        // reads it, so this is the state after someone deletes it underneath a
        // running app. A lost panel width is not worth a crash.
        let url = TestHome.scratch("prefs-absent-tree")
            .appendingPathComponent("nor-this-one", isDirectory: true)
            .appendingPathComponent("preferences.json")
        PreferencesFile(url: url).save(Preferences(panelSpans: Preferences.spanChoices.narrow))
        #expect(!FileManager.default.fileExists(atPath: url.path))
        #expect(PreferencesFile.load(from: url) == .default)
    }

    // MARK: - The default that writes nowhere

    @Test("The no-op writer creates nothing where the real one would have")
    func noPreferenceWritingWritesNothing() throws {
        let url = scratchFile("prefs-nowhere")

        // First establish that this URL is one a real writer reaches, so that
        // the absence below is the writer's doing and not a bad path.
        PreferencesFile(url: url).save(Preferences(panelSpans: Preferences.spanChoices.narrow))
        #expect(FileManager.default.fileExists(atPath: url.path))
        try FileManager.default.removeItem(at: url)

        let writer: any PreferencesWriting = NoPreferenceWriting()
        writer.save(Preferences(panelSpans: Preferences.spanChoices.narrow))
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test("The no-op writer holds no URL to write to in the first place")
    func noPreferenceWritingHasNowhereToWrite() {
        // Structural rather than behavioural, and that is the point: a default
        // that writes nowhere because it was *given* nowhere cannot be made to
        // write by a test that forgot to isolate itself. `Mirror` reads the
        // stored properties, so this fails if someone gives it a URL later.
        #expect(Mirror(reflecting: NoPreferenceWriting()).children.isEmpty)
    }
}
