import Foundation

/// One run of the board driving its own cards.
///
/// Auto-dev speaks about the **machine**, not about a card, so it costs zero
/// board columns. This is the value the two surfaces that report it read —
/// the Operations band and the status bar's figure — and the value the loop
/// (PR4) persists. It lives in `ElliotModel` for the ordinary reason: it is
/// pure, it carries no clock and no I/O, and both `ElliotEngine` and
/// `ElliotAppKit` need it.
///
/// ⚠️ **The engaged list is closed at start.** Every card the session may touch
/// is decided in one write, at one moment, by a person; a card dragged into
/// Backlog mid-session is invisible to it. Nothing here offers a way to append
/// to `engagedCardIDs`, and that absence is the design.
///
/// ⚠️ **Every default here lives on the initialiser, not on a stored
/// property.** Swift's synthesised `Codable` conformance therefore emits
/// `decode(_:forKey:)` for every one of these columns, not
/// `decodeIfPresent(_:forKey:)` — a decode against a database row missing a
/// column throws `keyNotFound` rather than falling back quietly. That is
/// correct today: PR4 creates this table wholesale, so every column exists
/// from the first migration that writes a row. It stops being correct the
/// moment a *later* migration adds a field to this type — that field must be
/// declared `Optional` or, **if it is a `[String]`**, wrapped in
/// `@DefaultsToEmpty` (`ElliotKit/Sources/ElliotModel/DefaultsToEmpty.swift`),
/// or a database written before the new column existed fails to decode.
/// ⚠️ The wrapper is hard-typed: its `wrappedValue` is `[String]`, and the
/// `KeyedDecodingContainer` overload that does the work is keyed to the wrapper
/// itself, so there is no generic form to reach for. For an `Int`, a `Date` or
/// a new enum the second remedy does not exist and `Optional` is the only one.
/// `BoardStore.openReadOnly` is read against exactly this hazard — it
/// deliberately reads a database older than the code reading it — and a
/// non-optional field with only an initialiser default has broken it once
/// already.
public struct AutoDevSession: Identifiable, Codable, Sendable, Hashable {

    /// Running, held by the reader, or over.
    ///
    /// `finished` is **not** the absence of a session. The outcome is a record,
    /// and the band and the figure stay on screen through it — otherwise a
    /// session that failed everywhere renders exactly like a session that never
    /// happened.
    public enum State: String, Codable, Sendable, Hashable, CaseIterable {
        case running
        case paused
        case finished
    }

    public var id: UUID
    public var repoID: UUID
    /// Fixed at start, never grows.
    public var engagedCardIDs: [UUID]
    public var maxAttemptsPerCard: Int
    /// How long a card may sit on one unchanged reason before it settles.
    ///
    /// On the session rather than a constant: a repository whose CI takes an
    /// hour and one that takes ninety seconds do not want the same answer.
    public var patience: TimeInterval
    public var startedAt: Date
    public var endedAt: Date?
    public var state: State

    public init(
        id: UUID = UUID(),
        repoID: UUID,
        engagedCardIDs: [UUID],
        maxAttemptsPerCard: Int,
        patience: TimeInterval,
        startedAt: Date,
        endedAt: Date? = nil,
        state: State = .running
    ) {
        self.id = id
        self.repoID = repoID
        self.engagedCardIDs = engagedCardIDs
        self.maxAttemptsPerCard = maxAttemptsPerCard
        self.patience = patience
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.state = state
    }
}

/// Where one engaged card got to.
///
/// Three cases and not five. The loop's own verdict — retry, wait, held,
/// settle, abort — is a decision about the *next round*; this is what the
/// report has to say about the card, and the distinctions that decision draws
/// are carried by ``AutoDevEngagement/reason`` rather than by a case each. A
/// held run and a waiting one read differently in the sentence, which is where
/// the reader needs the difference.
public enum AutoDevDisposition: String, Codable, Sendable, Hashable, CaseIterable {
    /// The session still holds it.
    case engaged
    /// `gh` said the pull request was merged.
    case merged
    /// The session gave up on it, and `reason` says why.
    case blocked
}

/// One engaged card's row in a session's report.
///
/// ⚠️ **`id` is derived, not stored.** It reads as `cardID` because a session
/// engages a card at most once — the engaged list is closed at start, so it
/// cannot hold two rows for one card — but the row's real key is the pair
/// `(sessionID, cardID)`, not `cardID` alone: two different sessions can each
/// hold a row for the same card. A future `MutablePersistableRecord`
/// conformance must key its table on that pair and must not trust `id` to be
/// a column — there isn't one.
public struct AutoDevEngagement: Identifiable, Codable, Sendable, Hashable {
    public var sessionID: UUID
    public var cardID: UUID
    public var attempts: Int
    public var disposition: AutoDevDisposition
    /// Why it is where it is, in the board's own words — a `MoveBlock`'s
    /// sentence, or a `QueueRefusal`'s. Never blank: a row with no reason is a
    /// row the reader stops at with nothing to go and do.
    public var reason: String
    public var updatedAt: Date

    /// The card, because a session engages a card at most once: the list is
    /// closed at start, so it cannot hold two rows for one card.
    public var id: UUID { cardID }

    public init(
        sessionID: UUID,
        cardID: UUID,
        attempts: Int,
        disposition: AutoDevDisposition,
        reason: String,
        updatedAt: Date
    ) {
        self.sessionID = sessionID
        self.cardID = cardID
        self.attempts = attempts
        self.disposition = disposition
        self.reason = reason
        self.updatedAt = updatedAt
    }
}

/// A session's rows, counted once.
///
/// One count, two readers: the band's headline and the status bar's figure.
/// Two tallies would be two answers to "how far along is it", which is the one
/// number this feature exists to state.
///
/// ⚠️ **Deliberately not `Codable`.** It is derived from a session's
/// engagements via ``of(_:)`` and carries no identity of its own — nothing
/// should ever persist it as a column or a row. Recompute it from the
/// engagements the store already holds.
public struct AutoDevTally: Sendable, Hashable {
    public var engaged: Int
    public var merged: Int
    public var blocked: Int

    public var total: Int { engaged + merged + blocked }
    /// A card the session is done with, whichever way it went.
    public var settled: Int { merged + blocked }

    public init(engaged: Int, merged: Int, blocked: Int) {
        self.engaged = engaged
        self.merged = merged
        self.blocked = blocked
    }

    public static func of(_ engagements: [AutoDevEngagement]) -> AutoDevTally {
        AutoDevTally(
            engaged: engagements.count { $0.disposition == .engaged },
            merged: engagements.count { $0.disposition == .merged },
            blocked: engagements.count { $0.disposition == .blocked }
        )
    }
}

extension AutoDevEngagement {
    /// The row-level form of ``AutoDevTally/settled``: `.engaged` is `AutoDevDisposition`'s only
    /// case still in flight, so being settled is defined as *not* that, rather than as an
    /// enumeration of the other two. That form is the defensible one — a fourth
    /// `AutoDevDisposition` case with no arm written for it here reads as settled, which surfaces
    /// in the report as something to go look at, rather than silently staying "still engaged"
    /// forever the way `== .merged || == .blocked` would leave it.
    public var isSettled: Bool {
        disposition != .engaged
    }
}

/// What the loop decided to do about one card, this round.
///
/// Transient — never persisted. ``AutoDevEngagement/disposition`` (`AutoDevDisposition`) is what a
/// session's report renders; this is the finer-grained verdict the policy (`AutoDevPolicy`, a later
/// task) computes each round to get there, and ``engagement`` below is the total, compile-checked
/// bridge from one to the other.
///
/// `.held` is distinct from `.wait` on purpose: `.paused`, `.dailyCeilingReached` and
/// `.mergeWaitsForRepoToBeIdle` are the *scheduler* holding a run, not the board waiting on the
/// world, and a report that confused them would send the reader to fix the wrong thing.
///
/// `.wait` and `.abortSession` carry a sentence: the report renders one line per card, and a bare
/// case renders nothing at all.
public enum Disposition: Sendable, Hashable {
    case retry
    case wait(reason: String)
    case held(QueueRefusal)
    /// The card is done, one way or the other. The first element says which — `.merged` or
    /// `.blocked`, never `.engaged`.
    ///
    /// ⚠️ The type cannot enforce that: `AutoDevDisposition` has three cases, and nothing here
    /// stops a future caller writing `.settle(.engaged, reason: "…")`, which would mean a
    /// disposition that just settled a card simultaneously reporting it as still engaged — a
    /// contradiction the compiler will not catch. Every construction site of `.settle` must supply
    /// `.merged` or `.blocked` and never derive it from `reason`, which is prose, not a value.
    case settle(AutoDevDisposition, reason: String)
    case abortSession(reason: String)

    /// One sentence, for the report and for the row's `reason`.
    public var reason: String {
        switch self {
        case .retry: "Moving this card now."
        case .wait(let reason): reason
        case .held(let refusal): refusal.sentence
        case .settle(_, let reason): reason
        case .abortSession(let reason): reason
        }
    }

    /// Whether this card is finished with, one way or the other.
    public var isSettled: Bool {
        switch self {
        case .settle, .abortSession: true
        case .retry, .wait, .held: false
        }
    }
}

extension Disposition {
    /// What this verdict means for the persisted row. Total by construction — a `switch` with no
    /// `default`, so a sixth disposition is a compile error rather than a card silently reported
    /// as still engaged.
    public var engagement: AutoDevDisposition {
        switch self {
        case .retry, .wait, .held: .engaged
        case .settle(let outcome, _): outcome
        case .abortSession: .blocked
        }
    }
}
