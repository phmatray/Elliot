import Foundation

/// Why a run that has been admitted to the queue has not started yet.
///
/// `canStart` returned a bare `Bool` and threw the reason away, so a queue that
/// stopped moving was indistinguishable from a broken scheduler. Every one of
/// these is a rule the engine already enforced; the only change is that it now
/// says which.
///
/// In ElliotModel so the wording is testable outside the app target, and so it
/// lives exactly once — the same discipline `Consequence.reason` applies to the
/// board's refusals.
public enum QueueRefusal: Sendable, Equatable, Hashable {
    /// A merge is running in this repository. It removes a worktree and deletes
    /// a branch; nothing else may touch the repo while it does.
    case mergeInFlightInRepo
    /// The writer cap is full.
    case writerCapReached(inFlight: Int, cap: Int)
    /// The analysis cap is full.
    case analysisCapReached(inFlight: Int, cap: Int)
    /// Another `create-issue` is running here, and each does duplicate detection
    /// against a repository the other is about to change.
    case duplicateCreateIssueInRepo
    /// A merge waits for everything else in its repository, analyses included.
    case mergeWaitsForRepoToBeIdle
    /// Today's spend has reached the ceiling.
    case dailyCeilingReached
    /// The scheduler is paused.
    case paused

    /// Stable identifier, for MCP callers and for tests that must not depend on
    /// the prose.
    public var code: String {
        switch self {
        case .mergeInFlightInRepo: "merge_in_flight_in_repo"
        case .writerCapReached: "writer_cap_reached"
        case .analysisCapReached: "analysis_cap_reached"
        case .duplicateCreateIssueInRepo: "duplicate_create_issue_in_repo"
        case .mergeWaitsForRepoToBeIdle: "merge_waits_for_repo_to_be_idle"
        case .dailyCeilingReached: "daily_ceiling_reached"
        case .paused: "paused"
        }
    }

    /// One sentence, written once. Says what is holding the run and what would
    /// release it — a reason with no remedy is only a nicer way of saying no.
    public var sentence: String {
        switch self {
        case .mergeInFlightInRepo:
            "A merge is running in this repository. It removes a worktree and deletes a branch, so nothing else may touch the repository until it finishes."
        case .writerCapReached(let inFlight, let cap):
            "All \(cap) run \(cap == 1 ? "slot is" : "slots are") busy — \(inFlight) going. Raise the writer limit in Preflight, or wait."
        case .analysisCapReached(let inFlight, let cap):
            "All \(cap) analysis \(cap == 1 ? "slot is" : "slots are") busy — \(inFlight) going. Raise the analysis limit in Preflight, or wait."
        case .duplicateCreateIssueInRepo:
            "Another story is being filed in this repository. Two at once would each miss the other's issue when checking for duplicates."
        case .mergeWaitsForRepoToBeIdle:
            "A merge waits for everything else in its repository to finish, analyses included."
        case .dailyCeilingReached:
            "Today's spending ceiling is reached. Queued runs are held until tomorrow, or until you raise it in Preflight."
        case .paused:
            "The queue is paused."
        }
    }
}

/// One entry of the pending queue, as the board shows it.
///
/// `pending` was a private `[UUID]` inside the scheduler actor with no accessor,
/// so moving three cards made two of them disappear into a queue nothing showed.
public struct QueuedRun: Sendable, Equatable, Identifiable {
    public var id: UUID { runID }
    public var runID: UUID
    public var cardID: UUID?
    public var repoID: UUID
    public var repoName: String
    public var cardTitle: String?
    public var kind: SkillKind
    /// Position in the queue, 1-based, in the order `pump()` will consider them.
    public var position: Int
    public var refusal: QueueRefusal
    public var queuedAt: Date

    public init(
        runID: UUID,
        cardID: UUID?,
        repoID: UUID,
        repoName: String,
        cardTitle: String?,
        kind: SkillKind,
        position: Int,
        refusal: QueueRefusal,
        queuedAt: Date
    ) {
        self.runID = runID
        self.cardID = cardID
        self.repoID = repoID
        self.repoName = repoName
        self.cardTitle = cardTitle
        self.kind = kind
        self.position = position
        self.refusal = refusal
        self.queuedAt = queuedAt
    }
}
