import ElliotModel
import Foundation

/// The **only** place in `ElliotAppKit` that touches `UserDefaults`.
///
/// It exists to read one thing, once: the `notificationPreferences` payload
/// written by every build before #222, so a reader who muted a category does not
/// silently get it back on the launch that moves the setting into
/// `preferences.json`.
///
/// ⛔ **Nothing else here may reach for `UserDefaults`, and that is enforced by
/// `PreferencesHomeTests` rather than asked for.** The reason is written in
/// `StoreLocation`: `UserDefaults.standard` is keyed by bundle identifier, so
/// nothing can point it at a different home — while every on-screen check in
/// this project launches a second instance against a scratch `ELLIOT_HOME`.
/// Anything left in `.standard` therefore reads *and writes* the operator's real
/// settings from a throwaway board. Moving one value out is a fix; making it an
/// invariant is what stops the third preference re-opening the question, which
/// is exactly how the second one arrived.
///
/// It is deliberately **read-only**. Nothing writes this key again, so the old
/// payload is left where it is: a downgrade then finds the settings it expects
/// rather than a board that has forgotten them, and adoption stays idempotent.
enum LegacyNotificationDefaults {

    /// The key every build before #222 wrote under.
    static let key = "notificationPreferences"

    /// What the pre-#222 build stored, or `nil` if it stored nothing readable.
    ///
    /// A payload that will not decode is treated as absent rather than fatal —
    /// this type's policy everywhere, and the alternative is refusing to launch
    /// over a corrupt defaults entry.
    static func read(from defaults: UserDefaults) -> NotificationPreferences? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(NotificationPreferences.self, from: data)
    }
}
