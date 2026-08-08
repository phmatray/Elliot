import ElliotModel
import Foundation
import TestSupport
import Testing

@testable import ElliotAppKit

/// One home for everything Elliot persists, made an invariant rather than a
/// decision (#222).
///
/// The move itself is small. What matters is that it stays moved: the second
/// preference arrived in `UserDefaults` because nothing said it could not, and
/// a third would arrive the same way. `StoreLocation` already carries the
/// argument — `UserDefaults.standard` is keyed by bundle identifier, so nothing
/// can point it at a different home — while every on-screen check in this
/// project launches a second instance against a scratch `ELLIOT_HOME`.
@MainActor
@Suite("One preferences home")
struct PreferencesHomeTests {

    private func scratchFile(_ label: String) -> URL {
        let directory = TestHome.scratch(label)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("preferences.json")
    }

    // MARK: - The gate

    /// `UserDefaults` may appear in exactly one file, and it is the one whose
    /// whole job is reading the pre-#222 payload once.
    ///
    /// A source-reading gate in the `DrainDuplicationTests` idiom, because the
    /// thing worth holding is a *shape*: nothing behaves differently on the day
    /// someone adds a second `UserDefaults.standard`, and the damage — a scratch
    /// board writing the operator's real settings — is invisible from inside the
    /// app.
    @Test("UserDefaults is reachable from one file only")
    func userDefaultsHasOneHome() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // ElliotAppKitTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // ElliotKit
            .appendingPathComponent("Sources/ElliotAppKit")

        let sanctioned = "LegacyNotificationDefaults.swift"
        var offenders: [String] = []

        for file in try FileManager.default.contentsOfDirectory(atPath: sources.path)
        where file.hasSuffix(".swift") && file != sanctioned {
            let body = try String(contentsOf: sources.appendingPathComponent(file), encoding: .utf8)
            for (index, line) in body.components(separatedBy: "\n").enumerated() {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                // Comments may discuss it — several now explain why it moved.
                guard !trimmed.hasPrefix("//"), line.contains("UserDefaults") else { continue }
                offenders.append("\(file):\(index + 1)")
            }
        }

        #expect(
            offenders.isEmpty,
            """
            \(offenders.joined(separator: ", ")) reaches UserDefaults. Everything Elliot \
            persists lives under ELLIOT_HOME, because `UserDefaults.standard` is keyed by \
            bundle identifier and cannot follow it — so a scratch home reads and writes the \
            operator's real settings. If this genuinely belongs in defaults, say why in \
            `LegacyNotificationDefaults` and put it there.
            """
        )
    }

    // MARK: - Adoption

    @Test("The legacy payload is read when it is there, and absent when it is not")
    func legacyPayloadRoundTrips() throws {
        let suite = try #require(UserDefaults(suiteName: "elliot-tests-\(UUID().uuidString)"))
        defer { suite.removePersistentDomain(forName: suite.dictionaryRepresentation().description) }

        #expect(LegacyNotificationDefaults.read(from: suite) == nil)

        let muted = NotificationPreferences(isEnabled: true, muted: [.needsYou])
        suite.set(try JSONEncoder().encode(muted), forKey: LegacyNotificationDefaults.key)
        #expect(LegacyNotificationDefaults.read(from: suite) == muted)

        suite.set(Data("not json".utf8), forKey: LegacyNotificationDefaults.key)
        #expect(
            LegacyNotificationDefaults.read(from: suite) == nil,
            "a corrupt payload must read as absent, not throw"
        )
    }

    /// The safety property, stated as a test: a file built by `init(url:)` — every
    /// scratch home, every test — **cannot** inherit the operator's mutes,
    /// because it has no way to reach them.
    @Test("A file at a scratch location never adopts the operator's settings")
    func scratchLocationDoesNotAdopt() throws {
        let url = scratchFile("prefs-no-adoption")
        try Data(#"{"panelSpans": 2}"#.utf8).write(to: url)

        let loaded = PreferencesFile(url: url).load()

        #expect(loaded.panelSpans == Preferences.spanChoices.narrow)
        #expect(
            loaded.notifications == .default,
            "a scratch home inherited notification settings from somewhere outside it"
        )
    }

    // MARK: - The third field

    @Test("Notification settings survive the round trip beside the two spans")
    func notificationsRoundTrip() {
        let url = scratchFile("prefs-three-fields")
        let file = PreferencesFile(url: url)
        let model = AppModel(preferences: file, initialPreferences: .default)

        model.panelSpans = Preferences.spanChoices.narrow
        model.notificationPreferences = NotificationPreferences(
            isEnabled: false, muted: [.needsYou]
        )
        model.analysisSpans = Preferences.spanChoices.narrow

        let reread = PreferencesFile.load(from: url)
        #expect(reread.panelSpans == Preferences.spanChoices.narrow)
        #expect(reread.analysisSpans == Preferences.spanChoices.narrow)
        #expect(!reread.notifications.isEnabled)
        #expect(reread.notifications.muted == [.needsYou])
    }

    /// The third field must not be clamped away, and the two spans must survive a
    /// file that carries it. `clamped()` rebuilds the struct field by field, so
    /// forgetting to carry one through is a silent reset.
    @Test("Clamping a bad span leaves the notification settings alone")
    func clampingKeepsNotifications() throws {
        let url = scratchFile("prefs-clamp-keeps-notifications")
        try Data(#"{"panelSpans": 9, "notifications": {"isEnabled": false, "muted": []}}"#.utf8)
            .write(to: url)

        let loaded = PreferencesFile.load(from: url)
        #expect(loaded.panelSpans == Preferences.default.panelSpans)
        #expect(
            !loaded.notifications.isEnabled,
            "clamping a span threw away the notification settings"
        )
    }

    @Test("A file from before this field loads with notifications at their default")
    func olderFileLoads() throws {
        let url = scratchFile("prefs-before-notifications")
        try Data(#"{"panelSpans": 2, "analysisSpans": 2}"#.utf8).write(to: url)

        let loaded = PreferencesFile.load(from: url)
        #expect(loaded.notifications == .default)
    }
}
