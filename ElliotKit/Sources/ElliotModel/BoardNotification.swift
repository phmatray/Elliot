import Foundation

/// The four things Elliot is willing to interrupt someone about.
///
/// One case per switch in Settings, because a category the user cannot see is a
/// category they cannot turn off. They are deliberately about *what happened*
/// rather than about which subsystem noticed: "the board moved a card itself"
/// is one thing to a person, whether `PRWatcher` or the reconciler saw it.
public enum NotificationCategory: String, Codable, Sendable, CaseIterable, Hashable {
    /// A run finished and there is nothing to do — an issue was filed, a pull
    /// request opened, a merge landed.
    case landed
    /// A run stopped, went silent, or finished having been refused a tool.
    /// The only category that makes a sound.
    case needsYou
    /// The board advanced a card with no gesture from anyone: a pull request
    /// went ready, or was merged on github.com.
    case boardMovedItself
    /// An analysis finished and its proposals are waiting to be accepted.
    case analysisReady
}

/// One notification, decided but not yet delivered.
///
/// A value rather than a call into `UNUserNotificationCenter`, so the decision
/// of what to say is testable without a notification centre — and so the
/// delivery layer holds no policy of its own to drift from this one.
public struct BoardNotification: Sendable, Hashable {
    /// Stable per *card*, not per event. macOS replaces a notification that
    /// reuses an identifier, so "Opened issue #12" becomes "Draft PR 13 on
    /// feat/12-…" in place. Without that, a card that progresses three times
    /// leaves three notifications on screen and two of them are lies.
    public var identifier: String
    /// Groups a repository's notifications together in Notification Centre.
    public var threadIdentifier: String
    public var category: NotificationCategory
    public var title: String
    public var body: String
    /// Reserved for the things that actually need a person. An informational
    /// "it landed" that pinged would train its own dismissal.
    public var playsSound: Bool
    /// What clicking it should select. Nil for an analysis, which is about a
    /// repository rather than a card.
    public var cardID: UUID?
    public var repoID: UUID?

    public init(
        identifier: String,
        threadIdentifier: String,
        category: NotificationCategory,
        title: String,
        body: String,
        playsSound: Bool,
        cardID: UUID? = nil,
        repoID: UUID? = nil
    ) {
        self.identifier = identifier
        self.threadIdentifier = threadIdentifier
        self.category = category
        self.title = title
        self.body = body
        self.playsSound = playsSound
        self.cardID = cardID
        self.repoID = repoID
    }
}

/// What the user has agreed to be interrupted by.
///
/// Passed *into* the policy as a value rather than read from `UserDefaults`
/// inside it, which is what makes "a muted category posts nothing" a unit test
/// instead of something you discover by muting a category and waiting an hour.
public struct NotificationPreferences: Codable, Sendable, Hashable {
    /// The master switch. Dominates `muted` — off means silent, whatever the
    /// individual switches say.
    public var isEnabled: Bool
    public var muted: Set<NotificationCategory>

    /// Everything on. A default that muted something would be a feature nobody
    /// could find: a switch off in Settings with no account of why.
    public static let `default` = NotificationPreferences(isEnabled: true, muted: [])

    public init(isEnabled: Bool, muted: Set<NotificationCategory>) {
        self.isEnabled = isEnabled
        self.muted = muted
    }

    public func allows(_ category: NotificationCategory) -> Bool {
        isEnabled && !muted.contains(category)
    }

    // MARK: - Codable
    //
    // Hand-written for one reason: an unknown category must be dropped rather
    // than throw. These live in `UserDefaults`, so a build with a fifth category
    // will read payloads written by a build with four, and — on a downgrade —
    // one written by a build with five. The synthesised `Set<RawRepresentable>`
    // decoding throws on the first string it does not recognise, which would
    // turn "preferences from another build" into "no preferences at all" and
    // silently unmute every category the user had switched off.

    private enum CodingKeys: String, CodingKey {
        case isEnabled
        case muted
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        let raw = try container.decodeIfPresent([String].self, forKey: .muted) ?? []
        muted = Set(raw.compactMap(NotificationCategory.init(rawValue:)))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(isEnabled, forKey: .isEnabled)
        // Sorted, so the stored payload is stable and a diff of the defaults
        // plist is readable rather than reordering on every write.
        try container.encode(muted.map(\.rawValue).sorted(), forKey: .muted)
    }
}
