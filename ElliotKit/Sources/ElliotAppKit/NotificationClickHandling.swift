import AppKit
import Foundation
import UserNotifications

/// Presenting a notification while Elliot is running, and reacting to a click.
///
/// Its own object rather than logic on `AppModel`, because Apple requires the
/// delegate be set **before the app finishes launching**, which is earlier than
/// `AppModel.start()` runs.
@MainActor
public final class NotificationClickHandler: NSObject, UNUserNotificationCenterDelegate {
    /// Set once `AppModel` exists. Weak so the handler cannot keep the model
    /// alive past shutdown.
    public weak var model: AppModel?

    public override init() { super.init() }

    /// Show it, unconditionally.
    ///
    /// **No second opinion here.** Whether this notification deserved to exist
    /// at all was decided by `notification(for:preferences:appIsActive:)`
    /// before it was ever posted — including the frontmost rule, which is the
    /// one this method would be tempted to re-implement. Re-deciding here would
    /// be a second copy of that rule in a place no test can reach, and the two
    /// copies would disagree the first time either changed.
    public nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    /// A click brings Elliot forward with the card it was about selected.
    ///
    /// Repository first, then card: the board filters by repository, so
    /// selecting a card in a repository that is not shown selects nothing
    /// visible. A card that has since been deleted selects nothing and raises
    /// nothing — a notification outliving its subject is ordinary, not an error.
    /// `nonisolated`, because strict concurrency will not send
    /// `UNNotificationResponse` across an actor boundary — it is not `Sendable`.
    /// So the two ids are read out here and only those cross, which is the
    /// right shape anyway: nothing beyond them is wanted on the other side.
    public nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let info = response.notification.request.content.userInfo
        let repoID = (info["repoID"] as? String).flatMap(UUID.init(uuidString:))
        let cardID = (info["cardID"] as? String).flatMap(UUID.init(uuidString:))

        await MainActor.run {
            if let repoID { model?.selectRepoFromNotification(repoID) }
            if let cardID { model?.selectCardFromNotification(cardID) }
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}
