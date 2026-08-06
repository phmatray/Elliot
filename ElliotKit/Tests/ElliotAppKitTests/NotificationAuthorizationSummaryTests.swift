import ElliotEngine
import Foundation
import Testing
import UserNotifications

@testable import ElliotAppKit

/// What Preflight is allowed to claim about whether notifications can arrive.
///
/// This exists because of a measurement, not a hunch. A probe bundle signed
/// exactly the way `Scripts/build-app.sh` signs Elliot — ad-hoc, no team
/// identifier, no entitlements — was launched from three locations:
///
/// - from `/private/tmp`, `requestAuthorization` failed with `UNErrorDomain`
///   Code 1, *"Notifications are not allowed for this application"*, nothing was
///   delivered, and `authorizationStatus` stayed **`notDetermined`** — it never
///   became `denied`;
/// - from `~/Applications` and from the repository's own `dist/`, authorization
///   was granted and the notification arrived.
///
/// So ad-hoc signing is not what stops delivery; location is. And the failure is
/// **silent by default**: the centre constructs, `notificationSettings()`
/// answers, and the status says "nobody has asked yet" for the rest of time.
/// A row reporting the status alone would promise a question that will never be
/// asked again while every notification failed — the same trap as `gh secret
/// list` omitting organisation secrets.
///
/// Hence: a refusal outranks the status, and no state nobody understood is ever
/// reported as passing.
@Suite("Notification authorization summary")
struct NotificationAuthorizationSummaryTests {

    private func summary(
        _ status: UNAuthorizationStatus, refusal: String? = nil
    ) -> CheckResult {
        UserNotificationDelivery.summary(status: status, lastRefusal: refusal)
    }

    @Test("A refusal outranks the status, however encouraging the status looks")
    func refusalWins() {
        // The measured case, exactly: macOS declined, and said so only through
        // the call — the status still reads `notDetermined`.
        let result = summary(.notDetermined, refusal: "Notifications are not allowed for this application")

        #expect(result.status == .warn)
        #expect(result.detail.contains("refused"))
        // The message from the system reaches the row verbatim, because the
        // whole point is that it is the only place the truth appeared.
        #expect(result.detail.contains("not allowed for this application"))
        // And the hint names the fix that actually works — not "grant
        // permission", which is not what was withheld.
        #expect(result.fixHint?.contains("Applications") == true)
        #expect(!result.detail.contains("Not asked yet"), "the status wording survived a refusal")
    }

    @Test("Without a refusal, each authorization state reads as itself")
    func eachStateIsDistinct() {
        #expect(summary(.authorized).status == .pass)
        #expect(summary(.provisional).status == .pass)
        #expect(summary(.denied).status == .warn)
        #expect(summary(.notDetermined).status == .warn)

        // Distinct wording, not just distinct levels: two states that read the
        // same on screen are one state as far as anyone using it is concerned.
        let details = [
            summary(.authorized).detail, summary(.provisional).detail,
            summary(.denied).detail, summary(.notDetermined).detail,
        ]
        #expect(Set(details).count == 4, "two states share wording: \(details)")
    }

    @Test("Provisional is a pass, and says why it is quiet")
    func provisionalIsHonest() {
        // Provisional delivers, but silently and with no banner. Reporting it as
        // a plain pass would leave someone wondering why nothing ever appears.
        let result = summary(.provisional)
        #expect(result.status == .pass)
        #expect(result.detail.lowercased().contains("quiet"))
    }

    @Test("A passing state offers no fix, and every other state does")
    func fixHintsFollowTheStatus() {
        #expect(summary(.authorized).fixHint == nil)
        for status in [UNAuthorizationStatus.denied, .notDetermined] {
            #expect(summary(status).fixHint?.isEmpty == false, "\(status.rawValue) offers no way out")
        }
    }

    @Test("The row keeps one identity, whatever it is reporting")
    func identityIsStable() {
        // Preflight rows are keyed by id; a row that renamed itself per state
        // would appear as four different checks appearing and disappearing.
        for status in [UNAuthorizationStatus.authorized, .denied, .notDetermined, .provisional] {
            #expect(summary(status).id == "notifications")
            #expect(summary(status).title == "Notifications")
        }
        #expect(summary(.notDetermined, refusal: "x").id == "notifications")
    }
}
