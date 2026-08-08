import AppKit
import ElliotEngine
import ElliotModel
import Foundation

/// Turns an event into a posted notification, holding no judgement of its own.
///
/// Everything it knows how to decide is `if let`. Whether the event is worth an
/// interruption, what it says, whether it makes a sound and what identifier it
/// reuses are all `ElliotModel.notification(for:preferences:appIsActive:)` —
/// pure, and covered by `NotificationPolicyTests`. What lives here is only the
/// two facts the policy cannot know by itself: what the user chose, and whether
/// they are looking at the board right now.
@MainActor
final class NotificationPresenter {
    private let delivery: any NotificationDelivering
    /// Injected so a test can drive the frontmost rule without an `NSApp`.
    private let appIsActive: @MainActor () -> Bool

    init(
        delivery: any NotificationDelivering,
        preferences: NotificationPreferences = .default,
        appIsActive: @escaping @MainActor () -> Bool = { NSApp?.isActive ?? false }
    ) {
        self.delivery = delivery
        self.preferences = preferences
        self.appIsActive = appIsActive
    }

    /// What the user chose, pushed in by whoever owns the preference.
    ///
    /// Plain storage since #222. It read and wrote `UserDefaults.standard`,
    /// which is keyed by bundle identifier and cannot follow `ELLIOT_HOME`, so a
    /// scratch instance decided what the operator's real board would post — and
    /// could mute a category in it. The value lives in `preferences.json` beside
    /// the panel widths now, and `AppModel.notificationPreferences` is the one
    /// writer.
    ///
    /// Still a *value* the policy is handed rather than something it reaches
    /// for, which is what keeps "a muted category posts nothing" a unit test.
    var preferences: NotificationPreferences

    func requestAuthorizationIfNeeded() async {
        await delivery.requestAuthorizationIfNeeded()
    }

    func authorizationSummary() async -> CheckResult {
        await delivery.authorizationSummary()
    }

    /// The whole of this class's behaviour.
    func handle(_ event: NotificationEvent) async {
        guard
            let decided = notification(
                for: event, preferences: preferences, appIsActive: appIsActive()
            )
        else { return }
        await delivery.post(decided)
    }
}
