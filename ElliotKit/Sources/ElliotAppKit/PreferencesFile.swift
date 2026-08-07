import ElliotModel
import Foundation
import OSLog

/// Somewhere for a preference to go when it changes.
///
/// A seam rather than a direct call, and the reason is the **default**: the
/// implementation everything gets unless it asks otherwise is
/// ``NoPreferenceWriting``, which writes nowhere. So `swift test` cannot leave a
/// preference behind whatever order its suites happen to run in — the same
/// bargain `makeNotificationDelivery()` strikes by handing back `NoDelivery`
/// when there is no bundle to post from. One production site opts in
/// (`ElliotApp.swift`), and a test that wants persistence asks for it and hands
/// over a scratch URL.
///
/// The alternative — write by default, isolate by remembering to — is what
/// deferred this feature once already: the hazard is not that a test *might*
/// write into `~/Library/Application Support/Elliot`, it is that whether it does
/// depends on which suite ran first.
public protocol PreferencesWriting: Sendable {
    func save(_ preferences: Preferences)
}

/// A `preferences.json` at a given URL.
///
/// **Every path here uses the URL it was handed**, and nothing in this file
/// resolves `StoreLocation`. That is what keeps the type's behaviour independent
/// of the environment: `ELLIOT_HOME` is read once, by whoever built the writer.
public struct PreferencesFile: PreferencesWriting {
    private static let log = Logger(subsystem: "dev.phmatray.elliot", category: "Preferences")

    private let url: URL

    public init(url: URL) {
        self.url = url
    }

    /// What the file holds, or the default when it holds nothing usable.
    ///
    /// Absent, unreadable, not JSON, a directory, or holding a span the panel was
    /// never designed at all give the same answer, and none of them is an error:
    /// the policy is `NotificationPresenter.preferences`'s — *"a payload that
    /// will not decode is treated as absent rather than fatal"* — and refusing to
    /// open the panel over a corrupt 30-byte file would be a far worse failure
    /// than opening it at the width everyone starts at.
    ///
    /// The clamp happens here rather than inside the decode so that a written 3
    /// and a repaired 9 stay distinguishable to anything that reads the raw
    /// value (see `PreferencesTests`).
    public static func load(from url: URL) -> Preferences {
        guard
            let data = try? Data(contentsOf: url),
            let decoded = try? JSONDecoder().decode(Preferences.self, from: data)
        else { return .default }
        return decoded.clamped()
    }

    /// What *this* file holds. The same read as ``load(from:)``, addressed by the
    /// writer rather than by a URL, so a caller that has one cannot restore from
    /// one file and save into another.
    public func load() -> Preferences {
        Self.load(from: url)
    }

    /// Writes the preference, or loses it — never throws, never crashes.
    ///
    /// Synchronous, and small enough for that to be the simpler choice: the two
    /// affordances that change the panel's width land on release
    /// (`PanelLayout.snappedSpans`) and the accessibility actions are discrete,
    /// so writes are rare by construction and there is nothing to debounce. An
    /// asynchronous hop would buy nothing here and could let two saves land out
    /// of order.
    ///
    /// Atomic, so that a crash mid-write leaves the previous preference rather
    /// than a truncated file — and it does **not** create the directory tree.
    /// `StoreLocation.ensureDirectories()` owns that on launch; a save into a
    /// home somebody deleted underneath the app is a lost panel width, which is
    /// not worth a crash.
    public func save(_ preferences: Preferences) {
        do {
            let data = try JSONEncoder().encode(preferences)
            try data.write(to: url, options: .atomic)
        } catch {
            // Logged rather than surfaced: there is no action a reader could take
            // and nothing about the board is wrong.
            Self.log.error("Could not write \(self.url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }
}

/// The writer everything gets by default: it has nowhere to write, and writes
/// nothing.
///
/// Deliberately holds **no URL**. A no-op that carried a path could be made to
/// write by a later edit; one that carries nothing cannot, which is what turns
/// "no test writes a preference it did not ask to" from a convention into a
/// property of the type. `PreferencesFileTests` pins the emptiness.
public struct NoPreferenceWriting: PreferencesWriting {
    public init() {}
    public func save(_ preferences: Preferences) {}
}
