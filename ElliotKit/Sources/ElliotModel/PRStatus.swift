import Foundation

/// What GitHub says about a pull request, at one moment, on one commit.
///
/// The board's central invariant is that `gh` is the fact. Until #174 that
/// invariant was only exercised *after* a `merge-pr` run: a card sitting in In
/// Review — which is exactly when a human decides whether to drag it to Done —
/// carried no CI state, no mergeability, no review state at all.
///
/// The raw strings are stored and the enums are computed, deliberately. A
/// `mergeStateStatus` value GitHub ships tomorrow would fail the decode of an
/// entire row if these were enums; as computed properties it renders *not
/// known*. Fail toward not knowing, never toward losing the row.
public struct PRStatus: Codable, Sendable, Hashable {
    public var repoID: UUID
    public var prNumber: Int

    /// The commit these facts were established on.
    ///
    /// Not decoration: a pull request whose head has moved has facts about a
    /// commit that is no longer under review, and `resolved(now:currentHeadOid:)`
    /// refuses to report them. This is the field that makes "I do not know"
    /// expressible, which is the whole reason the row is dated at all.
    public var headRefOid: String
    public var checkedAt: Date

    // Raw, exactly as `gh` renders them.
    public var rawMergeStateStatus: String
    public var rawMergeable: String
    public var rawReviewDecision: String
    public var checks: [GHMergeStatus.StatusCheck]

    public init(
        repoID: UUID,
        prNumber: Int,
        headRefOid: String,
        checkedAt: Date,
        rawMergeStateStatus: String,
        rawMergeable: String,
        rawReviewDecision: String,
        checks: [GHMergeStatus.StatusCheck]
    ) {
        self.repoID = repoID
        self.prNumber = prNumber
        self.headRefOid = headRefOid
        self.checkedAt = checkedAt
        self.rawMergeStateStatus = rawMergeStateStatus
        self.rawMergeable = rawMergeable
        self.rawReviewDecision = rawReviewDecision
        self.checks = checks
    }

    /// Past this, a row stops being evidence.
    ///
    /// The same discipline as `repo_sync status --brief`'s two-hour threshold in
    /// the portfolio: a tool that serves data must be able to say *I do not
    /// know* rather than serve something old in silence. `portfolio_board.py`
    /// served a six-day-old snapshot without saying so, and a stale board looks
    /// exactly like a current one.
    public static let maximumAge: TimeInterval = 600

    /// How often a row is re-read while nothing about it has changed.
    ///
    /// Shorter than `maximumAge`, and the gap between the two is the design.
    /// They answer different questions: `maximumAge` is a *display* rule — do
    /// not trust a reading this old — and this is a *fetch* rule — go and look
    /// again. Keeping the fetch strictly inside the trust window means the
    /// display rule never fires while Elliot is running, and fires exactly when
    /// it should: after the app was closed, asleep, or unable to reach `gh`.
    ///
    /// Setting them equal, or leaving the fetch out altogether, would park every
    /// card on "not established" ten minutes after its last change and leave it
    /// there — a freshness rule with no way to become fresh.
    public static let refreshInterval: TimeInterval = 300
}

// MARK: - The three facets

/// What has judged this pull request.
///
/// `noChecks` is its own case on purpose. Folding it into "green" is the false
/// green that once had `repo-audit` report 43 mergeable pull requests where 2
/// were mergeable.
public enum CIState: Sendable, Hashable {
    /// Nothing has run. Not a pass — an absence of measurement.
    case noChecks
    case running
    case passing(Int)
    case failing([String])
    case unknown
}

public enum MergeState: Sendable, Hashable {
    case clean
    case conflict
    case blocked
    case behind
    case unstable
    case unknown
}

public enum ReviewState: Sendable, Hashable {
    /// Nobody has reviewed. On a solo repository this is every pull request, so
    /// it is **never** a signal — see `PRSign`.
    case none
    case approved
    case changesRequested
    case reviewRequired
    case unknown
}

// MARK: - The single sign a card carries

/// The most blocking known fact, which is all a card has room to say.
///
/// `nil` — no sign at all — means everything known is fine. That is a different
/// answer from `.unknown`, and keeping them apart is the point: one says there
/// is nothing to report, the other says nothing was established.
public enum PRSign: Sendable, Hashable {
    case conflict
    case checksFailing(count: Int)
    case changesRequested
    case reviewRequired
    case mergeBlocked
    case checksRunning
    case noBuild
    case unknown

    /// One sentence, for the card's tooltip and the panel's headline.
    ///
    /// Here rather than in a view for the usual reason: a sentence written in a
    /// SwiftUI body is a claim nothing can test.
    public var summary: String {
        switch self {
        case .conflict:
            "In conflict with the base branch — and a conflicted pull request fires no workflow, "
                + "so any checks shown are from before it."
        case .checksFailing(let count):
            count == 1 ? "One check is failing." : "\(count) checks are failing."
        case .changesRequested:
            "Changes were requested — a human is holding this."
        case .reviewRequired:
            "A review is required before this can merge."
        case .mergeBlocked:
            "GitHub will not merge this as it stands."
        case .checksRunning:
            "Checks are still running."
        case .noBuild:
            "No check has run on this pull request — nothing has judged it."
        case .unknown:
            "Not established — the reading is missing, aged out, or from an older commit."
        }
    }
}

// MARK: - Resolution

/// A `PRStatus` read against a clock and the pull request's current head.
///
/// Card and panel both read this one value rather than each applying the
/// staleness rules themselves — the same reason `CardOutcome` carries the fields
/// and the move together: a caller that could take one and forget the other is
/// the bug the type prevents.
public struct ResolvedPRStatus: Sendable, Hashable {
    public var ci: CIState
    public var merge: MergeState
    public var review: ReviewState

    /// Carried through so the panel can show provenance without a second read.
    public var checkedAt: Date
    public var headRefOid: String

    /// The reading no longer describes the pull request in front of you.
    public var isStale: Bool

    /// The most blocking known fact; `nil` when there is nothing to say.
    public var sign: PRSign?

    public init(
        ci: CIState, merge: MergeState, review: ReviewState,
        checkedAt: Date, headRefOid: String, isStale: Bool, sign: PRSign?
    ) {
        self.ci = ci
        self.merge = merge
        self.review = review
        self.checkedAt = checkedAt
        self.headRefOid = headRefOid
        self.isStale = isStale
        self.sign = sign
    }
}

public extension PRStatus {
    /// The facets and the sign, with both staleness rules already applied.
    ///
    /// - Parameters:
    ///   - now: the clock, passed in so this stays pure.
    ///   - currentHeadOid: the pull request's head as of the latest listing, or
    ///     `nil` when it is not known. `nil` disables the sha rule and leaves the
    ///     age rule in force — not knowing where the head is cannot be allowed to
    ///     *prove* the row is fresh.
    func resolved(now: Date, currentHeadOid: String?) -> ResolvedPRStatus {
        let movedOn = currentHeadOid.map { $0 != headRefOid } ?? false
        let agedOut = now.timeIntervalSince(checkedAt) >= Self.maximumAge
        let stale = movedOn || agedOut

        guard !stale else {
            return ResolvedPRStatus(
                ci: .unknown, merge: .unknown, review: .unknown,
                checkedAt: checkedAt, headRefOid: headRefOid, isStale: true, sign: .unknown)
        }

        let ci = ciState
        let merge = mergeState
        let review = reviewState
        return ResolvedPRStatus(
            ci: ci, merge: merge, review: review,
            checkedAt: checkedAt, headRefOid: headRefOid, isStale: false,
            sign: Self.sign(ci: ci, merge: merge, review: review))
    }

    /// Whether this pull request is worth spending a `gh pr view` on.
    ///
    /// The cost of the whole feature lives in this one function. `PRWatcher`
    /// already lists a repository's pull requests every tick; `headRefOid` rides
    /// along on that listing as a cheap scalar, and comparing it here is what
    /// turns a per-card call into one that is usually skipped.
    ///
    /// A reading is worth taking when there is none, when the commit under
    /// review has changed, when something was still running and will have
    /// finished, or when the row is old enough to be drifting toward
    /// `maximumAge`. Otherwise the facts are about a finished commit and cannot
    /// have changed.
    static func needsRefresh(stored: PRStatus?, currentHeadOid: String?, now: Date) -> Bool {
        guard let stored else { return true }
        if let currentHeadOid, currentHeadOid != stored.headRefOid { return true }
        if stored.checks.contains(where: \.isPending) { return true }
        return now.timeIntervalSince(stored.checkedAt) >= refreshInterval
    }

    /// Most blocking first, first match winning.
    ///
    /// `conflict` outranks a failing check for a measured reason: a conflicted
    /// pull request triggers no `pull_request` workflow at all, so the checks
    /// read on it predate the conflict and the failure shown may be a ghost.
    /// That misreading cost this repository a wrong diagnosis written into a
    /// pull request body as a fact (#140).
    ///
    /// A definite bad fact always outranks an absence: the first sighting of a
    /// pull request has `mergeStateStatus: UNKNOWN` while its checks are already
    /// known, and answering `.unknown` there would hide something we hold.
    static func sign(ci: CIState, merge: MergeState, review: ReviewState) -> PRSign? {
        if merge == .conflict { return .conflict }
        if case .failing(let labels) = ci { return .checksFailing(count: labels.count) }
        if review == .changesRequested { return .changesRequested }
        if review == .reviewRequired { return .reviewRequired }
        if merge == .blocked || merge == .behind { return .mergeBlocked }
        if ci == .running { return .checksRunning }
        if ci == .noChecks { return .noBuild }
        if ci == .unknown || merge == .unknown || review == .unknown { return .unknown }
        return nil
    }

    private var ciState: CIState {
        guard !checks.isEmpty else { return .noChecks }
        let failing = checks.filter(\.hasFailed).map(\.label)
        // A failure is already decided; a sibling still running cannot undo it.
        if !failing.isEmpty { return .failing(failing) }
        if checks.contains(where: \.isPending) { return .running }
        return .passing(checks.count)
    }

    private var mergeState: MergeState {
        // `mergeable` is asked first: it names a conflict outright, while
        // `mergeStateStatus` can still be UNKNOWN on the same reading.
        if rawMergeable.uppercased() == "CONFLICTING" { return .conflict }
        switch rawMergeStateStatus.uppercased() {
        case "DIRTY": return .conflict
        case "CLEAN", "HAS_HOOKS": return .clean
        // A draft cannot merge, and not because anything is wrong with it.
        case "BLOCKED", "DRAFT": return .blocked
        case "BEHIND": return .behind
        case "UNSTABLE": return .unstable
        default: return .unknown
        }
    }

    private var reviewState: ReviewState {
        switch rawReviewDecision.uppercased() {
        case "": return .none
        case "APPROVED": return .approved
        case "CHANGES_REQUESTED": return .changesRequested
        case "REVIEW_REQUIRED": return .reviewRequired
        default: return .unknown
        }
    }
}
