import ElliotEngine
import ElliotModel
import Foundation
import UserNotifications

/// Posting a decided notification, and saying honestly whether it can arrive.
///
/// A protocol so everything above it is testable without a notification centre,
/// and so `swift test` never touches the real one. The decision of *what* to
/// post is `ElliotModel.notification(for:preferences:appIsActive:)` and is not
/// re-made here — an implementation of this protocol posts what it is given.
protocol NotificationDelivering: Sendable {
    /// Asks once. Safe to call again; the system answers from its own record.
    func requestAuthorizationIfNeeded() async
    /// Read back from the system every time, never a cached first-launch answer.
    func authorizationSummary() async -> CheckResult
    func post(_ notification: BoardNotification) async
}

/// What the app gets when there is no bundle to post from.
///
/// `swift run ElliotApp` and `swift test` both produce a bare executable with
/// no `Bundle.main.bundleIdentifier`, and `UNUserNotificationCenter.current()`
/// **raises** there rather than returning nil — so the guard has to be in the
/// factory, before the centre is ever touched.
struct NoDelivery: NotificationDelivering {
    func requestAuthorizationIfNeeded() async {}
    func post(_ notification: BoardNotification) async {}

    func authorizationSummary() async -> CheckResult {
        CheckResult(
            id: "notifications",
            title: "Notifications",
            status: .warn,
            detail: "Not available: this build is running outside an app bundle.",
            fixHint: "Run ./Scripts/build-app.sh and open dist/Elliot.app."
        )
    }
}

/// Builds the real delivery, or a no-op when there is no bundle to post from.
///
/// The guard is `Bundle.main.bundleIdentifier != nil` and it is checked *here*,
/// not inside `UserNotificationDelivery`, because the check has to happen before
/// `UNUserNotificationCenter.current()` is called at all.
@MainActor
func makeNotificationDelivery() -> any NotificationDelivering {
    guard Bundle.main.bundleIdentifier != nil else { return NoDelivery() }
    return UserNotificationDelivery()
}

/// The only file in Elliot that talks to `UNUserNotificationCenter`.
///
/// ### Why `authorizationSummary` reports the last *call*, not just the status
///
/// Measured while building this (#36), with a probe bundle signed exactly the
/// way `Scripts/build-app.sh` signs Elliot — ad-hoc, no team identifier, no
/// entitlements, no sandbox:
///
/// | bundle location | `requestAuthorization` | delivered | `authorizationStatus` after |
/// |---|---|---|---|
/// | `/private/tmp/…` | `UNErrorDomain` Code 1, "Notifications are not allowed for this application" | no | **`notDetermined`** |
/// | `~/Applications/…` | granted | yes | `provisional` |
/// | the repo's `dist/` | granted | yes | `provisional` |
///
/// So ad-hoc signing is **not** what stops delivery — location is. And in the
/// case where it is refused, nothing errors on the way in: the centre
/// constructs, `notificationSettings()` answers, and the status stays
/// `notDetermined` **forever** rather than becoming `denied`.
///
/// A Preflight row that reported `authorizationStatus` alone would therefore
/// say "not asked yet — Elliot will ask on next launch" for the rest of time,
/// while every notification failed silently. That is the same trap as
/// `gh secret list` omitting organisation secrets, and as an accessibility tree
/// that is empty because permission is missing rather than because the window
/// is. So the last refusal is remembered and reported beside the status.
@MainActor
final class UserNotificationDelivery: NotificationDelivering {
    /// The error from the most recent `requestAuthorization` or `add`, if it
    /// refused. `nil` means nothing has been refused, not that anything worked.
    ///
    /// A plain `var` because this class is main-actor isolated: the centre is a
    /// UI facility and everything that reaches it here already hops.
    private var lastRefusal: String?

    private var center: UNUserNotificationCenter { .current() }

    func requestAuthorizationIfNeeded() async {
        do {
            _ = try await center.requestAuthorization(options: [.alert, .sound])
            lastRefusal = nil
        } catch {
            // Not fatal, and not silent either. A denial degrades Elliot to
            // exactly what it was before this feature and blocks nothing.
            lastRefusal = error.localizedDescription
        }
    }

    func post(_ notification: BoardNotification) async {
        let content = UNMutableNotificationContent()
        content.title = notification.title
        content.body = notification.body
        content.threadIdentifier = notification.threadIdentifier
        if notification.playsSound { content.sound = .default }
        var info: [String: String] = [:]
        if let cardID = notification.cardID { info["cardID"] = cardID.uuidString }
        if let repoID = notification.repoID { info["repoID"] = repoID.uuidString }
        content.userInfo = info

        // A stable identifier and no trigger: post now, and replace whatever
        // this card said before rather than stacking a second claim beside it.
        let request = UNNotificationRequest(
            identifier: notification.identifier, content: content, trigger: nil
        )
        do {
            try await center.add(request)
            lastRefusal = nil
        } catch {
            lastRefusal = error.localizedDescription
        }
    }

    func authorizationSummary() async -> CheckResult {
        let settings = await center.notificationSettings()
        return Self.summary(status: settings.authorizationStatus, lastRefusal: lastRefusal)
    }

    /// Split out from the system read so the wording is decidable without a
    /// notification centre — the one part of this file a test could reach.
    nonisolated static func summary(
        status: UNAuthorizationStatus, lastRefusal: String?
    ) -> CheckResult {
        // A refusal outranks the status, because it is the newer and more
        // specific fact: `notDetermined` *plus* a refusal is macOS declining
        // this copy of Elliot, which "not asked yet" would misreport as a
        // question still to come.
        if let lastRefusal {
            return CheckResult(
                id: "notifications",
                title: "Notifications",
                status: .warn,
                detail: "macOS refused this copy of Elliot: \(lastRefusal)",
                fixHint: "Move Elliot.app somewhere durable — /Applications or "
                    + "~/Applications — and relaunch it from the Finder."
            )
        }

        let detail: String
        let level: CheckStatus
        switch status {
        case .authorized:
            (level, detail) = (.pass, "Authorized — notifications will arrive.")
        case .provisional:
            (level, detail) = (.pass, "Provisional — notifications arrive quietly, without a banner.")
        case .denied:
            (level, detail) = (.warn, "Denied — Elliot will not notify you.")
        case .notDetermined:
            (level, detail) = (.warn, "Not asked yet — Elliot asks on next launch.")
        @unknown default:
            // Never `.pass` for a state nobody read back and understood.
            (level, detail) = (.warn, "Unrecognised authorization state (\(status.rawValue)).")
        }
        return CheckResult(
            id: "notifications",
            title: "Notifications",
            status: level,
            detail: detail,
            fixHint: level == .pass ? nil : "System Settings → Notifications → Elliot."
        )
    }
}
