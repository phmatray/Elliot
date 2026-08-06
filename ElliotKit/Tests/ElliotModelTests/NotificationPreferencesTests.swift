import Foundation
import Testing

@testable import ElliotModel

/// What the user is willing to be interrupted by, and the shape of the
/// interruption itself.
///
/// These are values, not behaviour: the decision of *whether* to post lives in
/// `NotificationPolicy`, and it takes one of these as a parameter precisely so
/// "a muted category posts nothing" is a unit test rather than something you
/// find out by muting a category and waiting.
@Suite("Notification preferences")
struct NotificationPreferencesTests {

    @Test("Out of the box, every category is allowed")
    func defaultAllowsEverything() {
        let preferences = NotificationPreferences.default
        #expect(preferences.isEnabled)
        for category in NotificationCategory.allCases {
            #expect(preferences.allows(category), "\(category.rawValue) is muted by default")
        }
        // A default that muted something would be a feature nobody could find:
        // the switch would be off in Settings with no explanation for why.
        #expect(preferences.muted.isEmpty)
    }

    @Test("A muted category is refused, and its neighbours are not")
    func mutingIsPerCategory() {
        let preferences = NotificationPreferences(isEnabled: true, muted: [.landed])

        #expect(!preferences.allows(.landed))
        for category in NotificationCategory.allCases where category != .landed {
            #expect(preferences.allows(category), "muting .landed also silenced \(category.rawValue)")
        }
    }

    @Test("The master switch refuses everything, including categories nobody muted")
    func masterSwitchWins() {
        // The switch has to dominate, or turning Elliot's notifications off in
        // Settings would leave whichever categories happened to be unmuted still
        // posting — which reads as the setting being broken.
        let preferences = NotificationPreferences(isEnabled: false, muted: [])
        for category in NotificationCategory.allCases {
            #expect(!preferences.allows(category), "\(category.rawValue) survived the master switch")
        }
    }

    @Test("Preferences round-trip through JSON unchanged")
    func roundTrip() throws {
        let preferences = NotificationPreferences(isEnabled: false, muted: [.needsYou, .analysisReady])
        let data = try JSONEncoder().encode(preferences)
        let decoded = try JSONDecoder().decode(NotificationPreferences.self, from: data)
        #expect(decoded == preferences)
    }

    @Test("A payload written before a category existed still decodes")
    func unknownCategoriesAreDropped() throws {
        // These live in `UserDefaults`, so a build that adds a fifth category
        // will read payloads written by a build that had four — and, if the user
        // ever downgrades, one written by a build that had five. A `Set` of a
        // raw-value enum throws on an unknown string by default, which would
        // turn "an old preferences payload" into "no preferences at all", and
        // silently re-enable every category the user had muted.
        let json = #"{"isEnabled":true,"muted":["landed","somethingFromTheFuture"]}"#
        let decoded = try JSONDecoder().decode(
            NotificationPreferences.self, from: Data(json.utf8)
        )

        #expect(decoded.isEnabled)
        // The category it *does* understand is still muted — the unknown one is
        // dropped rather than taking the whole payload with it.
        #expect(decoded.muted == [.landed])
        #expect(!decoded.allows(.landed))
        #expect(decoded.allows(.needsYou))
    }

    @Test("A notification carries the identity that stops it stacking")
    func notificationIdentity() {
        let cardID = UUID(), repoID = UUID()
        let notification = BoardNotification(
            identifier: "card.\(cardID.uuidString)",
            threadIdentifier: "repo.\(repoID.uuidString)",
            category: .landed,
            title: "phmatray/Elliot",
            body: "Opened issue #12",
            playsSound: false,
            cardID: cardID,
            repoID: repoID
        )

        // The identifier is per *card*, not per event: macOS replaces a
        // notification that reuses an identifier, so "Opened issue #12" becomes
        // "Draft PR 13" in place instead of leaving two claims on screen, one of
        // them stale.
        #expect(notification.identifier == "card.\(cardID.uuidString)")
        #expect(notification.threadIdentifier == "repo.\(repoID.uuidString)")
        #expect(notification.cardID == cardID)
    }
}
