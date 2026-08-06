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
    private let defaults: UserDefaults
    /// Injected so a test can drive the frontmost rule without an `NSApp`.
    private let appIsActive: @MainActor () -> Bool

    static let preferencesKey = "notificationPreferences"

    init(
        delivery: any NotificationDelivering,
        defaults: UserDefaults = .standard,
        appIsActive: @escaping @MainActor () -> Bool = { NSApp?.isActive ?? false }
    ) {
        self.delivery = delivery
        self.defaults = defaults
        self.appIsActive = appIsActive
    }

    /// What the user chose, or everything-on when they have chosen nothing.
    ///
    /// A payload that will not decode is treated as absent rather than fatal:
    /// preferences are not board state, and refusing to start over a corrupt
    /// defaults entry would be a worse failure than notifying too much.
    var preferences: NotificationPreferences {
        get {
            guard
                let data = defaults.data(forKey: Self.preferencesKey),
                let decoded = try? JSONDecoder().decode(NotificationPreferences.self, from: data)
            else { return .default }
            return decoded
        }
        set {
            guard let data = try? JSONEncoder().encode(newValue) else { return }
            defaults.set(data, forKey: Self.preferencesKey)
        }
    }

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
