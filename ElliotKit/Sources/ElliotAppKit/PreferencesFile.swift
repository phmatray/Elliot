import ElliotModel
import ElliotStore
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

    /// Reads the pre-#222 notification payload, or `nil`.
    ///
    /// Supplied by ``atDefaultLocation()`` and by nothing else, which is the
    /// whole safety property: a scratch `ELLIOT_HOME` built through `init(url:)`
    /// **cannot** inherit the operator's real mutes, because the file it was
    /// handed has no way to reach them. Adoption is a property of *where the
    /// preferences live*, not of the code path that reads them.
    private let legacyNotifications: (@Sendable () -> NotificationPreferences?)?

    public init(url: URL) {
        self.url = url
        self.legacyNotifications = nil
    }

    private init(
        url: URL,
        legacyNotifications: @escaping @Sendable () -> NotificationPreferences?
    ) {
        self.url = url
        self.legacyNotifications = legacyNotifications
    }

    /// The file inside the `ELLIOT_HOME` this process resolved.
    ///
    /// The **only** resolution of `StoreLocation` in this file, and it is a
    /// separate entry point rather than a default argument on purpose: `init(url:)`
    /// stays environment-free, so a test cannot reach the operator's real
    /// preferences by leaving an argument off. It exists at all because
    /// `ElliotApp` depends on `ElliotAppKit` and nothing else, so the one
    /// production site cannot name `StoreLocation` itself.
    public static func atDefaultLocation() -> PreferencesFile {
        PreferencesFile(url: StoreLocation.preferencesURL) {
            LegacyNotificationDefaults.read(from: .standard)
        }
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
        var loaded = Self.load(from: url)

        // Adopt the pre-#222 notification settings, once, and only at the
        // default location.
        //
        // Gated on the *file* not declaring the key rather than on the decoded
        // value looking default: a reader who deliberately turned everything
        // back on would otherwise have the old mutes reimposed on them for ever.
        //
        // ⚠️ It does **not** write. `AppModel.init` calls this, and
        // `AppModelTests.restoringDoesNotWrite` pins that restoring a preference
        // never saves one — a write here would turn every launch into a write of
        // the file it had just read, which is the measured hazard that decided
        // `panelSpans`' shape. The adopted value reaches disk the first time the
        // reader changes anything, and until then this stays idempotent.
        if let legacyNotifications,
            !Self.declaresNotifications(at: url),
            let legacy = legacyNotifications()
        {
            loaded.notifications = legacy
        }
        return loaded
    }

    /// Whether the file on disk actually carries a `notifications` key.
    ///
    /// Read off the raw JSON rather than inferred from the decoded value,
    /// because `Preferences` decodes leniently: a missing key and a key holding
    /// the default are the same `NotificationPreferences` afterwards, and only
    /// one of them means "this reader has never expressed a choice here".
    private static func declaresNotifications(at url: URL) -> Bool {
        guard
            let data = try? Data(contentsOf: url),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return false }
        return object["notifications"] != nil
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
            let name = url.lastPathComponent
            let reason = error.localizedDescription
            Self.log.error(
                "Could not write \(name, privacy: .public): \(reason, privacy: .public)"
            )
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
