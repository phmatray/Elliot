import Foundation

public enum RunState: String, Codable, CaseIterable, Sendable, Hashable {
    case queued
    case running
    case cancelling
    case succeeded
    /// Finished without error but was refused at least one tool along the way.
    case completedWithDenials
    case failed
    case cancelled
    /// No output for longer than the idle timeout. Still alive; the user
    /// decides whether to keep waiting.
    case stalled
    case timedOut

    public var isTerminal: Bool {
        switch self {
        case .queued, .running, .cancelling, .stalled: false
        case .succeeded, .completedWithDenials, .failed, .cancelled, .timedOut: true
        }
    }

    /// A run in one of these states holds its card: no further move is allowed.
    public var isActive: Bool { !isTerminal }
}

/// What `gh` says actually happened, as opposed to what the agent said.
public enum VerifiedOutcome: Codable, Sendable, Hashable {
    case issueCreated(number: Int, url: String)
    /// `create-issue` found the idea already covered and skipped it. A real
    /// success, not a failure — the card just has no new issue.
    case noIssueCreated(reason: String)
    case prOpen(number: Int, url: String, isDraft: Bool, branch: String)
    case merged(commitSHA: String?)
    case notMerged(reason: String)
    case closedUnmerged
    case unverified(reason: String)
}

/// One invocation of `claude -p`.
public struct SkillRun: Identifiable, Codable, Sendable, Hashable {
    /// Also passed as `--session-id`, so the CLI transcript path is known
    /// before the process emits anything.
    public var id: UUID
    public var cardID: UUID
    public var repoID: UUID
    public var kind: SkillKind
    /// The exact `-p` argument.
    public var prompt: String
    /// The full argv, kept so a run can be reproduced by hand.
    public var argv: [String]
    public var cwd: String
    public var state: RunState
    public var startedAt: Date?
    public var endedAt: Date?
    public var exitCode: Int32?
    public var logPath: String
    public var stderrPath: String
    /// The `result` field of the terminal event. Display only — never parsed
    /// for issue or PR numbers.
    public var resultText: String?
    public var totalCostUSD: Double?
    public var numTurns: Int?
    public var permissionDenials: [String]
    public var verifiedOutcome: VerifiedOutcome?
    public var createdAt: Date

    public init(
        id: UUID = UUID(),
        cardID: UUID,
        repoID: UUID,
        kind: SkillKind,
        prompt: String,
        argv: [String] = [],
        cwd: String,
        state: RunState = .queued,
        startedAt: Date? = nil,
        endedAt: Date? = nil,
        exitCode: Int32? = nil,
        logPath: String,
        stderrPath: String,
        resultText: String? = nil,
        totalCostUSD: Double? = nil,
        numTurns: Int? = nil,
        permissionDenials: [String] = [],
        verifiedOutcome: VerifiedOutcome? = nil,
        createdAt: Date
    ) {
        self.id = id
        self.cardID = cardID
        self.repoID = repoID
        self.kind = kind
        self.prompt = prompt
        self.argv = argv
        self.cwd = cwd
        self.state = state
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.exitCode = exitCode
        self.logPath = logPath
        self.stderrPath = stderrPath
        self.resultText = resultText
        self.totalCostUSD = totalCostUSD
        self.numTurns = numTurns
        self.permissionDenials = permissionDenials
        self.verifiedOutcome = verifiedOutcome
        self.createdAt = createdAt
    }
}

/// Why a card changed column. Recorded for every move, including the ones that
/// trigger nothing, so the board's history is explainable after the fact.
public enum MoveOrigin: Codable, Sendable, Hashable {
    case userDrag
    case mcp(client: String)
    case system(reason: SystemReason)

    public enum SystemReason: String, Codable, Sendable, Hashable {
        case prBecameReady
        case prMergedExternally
        case reconciliation
    }

    /// System moves react to reality rather than changing it, so they must
    /// never fire a skill.
    public var allowsSideEffects: Bool {
        if case .system = self { return false }
        return true
    }
}

public struct MoveAudit: Identifiable, Codable, Sendable, Hashable {
    public var id: UUID
    public var cardID: UUID
    public var from: Column
    public var to: Column
    public var origin: MoveOrigin
    public var runID: UUID?
    public var at: Date

    public init(
        id: UUID = UUID(),
        cardID: UUID,
        from: Column,
        to: Column,
        origin: MoveOrigin,
        runID: UUID? = nil,
        at: Date
    ) {
        self.id = id
        self.cardID = cardID
        self.from = from
        self.to = to
        self.origin = origin
        self.runID = runID
        self.at = at
    }
}
