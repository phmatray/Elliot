import Foundation

// Decoded straight from `gh … --json`. These are the authority on what a run
// produced: the agent's prose is a hint, `gh` is the fact.

public struct GHIssue: Codable, Sendable, Hashable {
    public var number: Int
    public var title: String
    public var url: String
    public var state: String?
    public var createdAt: Date?

    public init(number: Int, title: String, url: String, state: String? = nil, createdAt: Date? = nil) {
        self.number = number
        self.title = title
        self.url = url
        self.state = state
        self.createdAt = createdAt
    }

    public var isOpen: Bool { (state ?? "OPEN").uppercased() == "OPEN" }
}

public struct GHPullRequest: Codable, Sendable, Hashable {
    public var number: Int
    public var url: String
    public var title: String
    public var body: String?
    public var headRefName: String
    public var isDraft: Bool
    public var state: String
    public var createdAt: Date?
    public var mergedAt: Date?

    public init(
        number: Int,
        url: String,
        title: String,
        body: String? = nil,
        headRefName: String,
        isDraft: Bool,
        state: String,
        createdAt: Date? = nil,
        mergedAt: Date? = nil
    ) {
        self.number = number
        self.url = url
        self.title = title
        self.body = body
        self.headRefName = headRefName
        self.isDraft = isDraft
        self.state = state
        self.createdAt = createdAt
        self.mergedAt = mergedAt
    }

    public var isOpen: Bool { state.uppercased() == "OPEN" }
    public var isMerged: Bool { state.uppercased() == "MERGED" || mergedAt != nil }
    public var isClosedUnmerged: Bool { state.uppercased() == "CLOSED" && mergedAt == nil }
    /// The state the board calls "In Review": open and no longer a draft.
    public var isReadyForReview: Bool { isOpen && !isDraft }
}

public struct GHMergeStatus: Codable, Sendable, Hashable {
    public var state: String
    public var mergedAt: Date?
    public var mergeCommit: MergeCommit?
    public var url: String?
    public var statusCheckRollup: [StatusCheck]?

    public struct MergeCommit: Codable, Sendable, Hashable {
        public var oid: String?
        public init(oid: String?) { self.oid = oid }
    }

    public struct StatusCheck: Codable, Sendable, Hashable {
        public var name: String?
        public var context: String?
        public var conclusion: String?
        public var state: String?

        public init(name: String? = nil, context: String? = nil, conclusion: String? = nil, state: String? = nil) {
            self.name = name
            self.context = context
            self.conclusion = conclusion
            self.state = state
        }

        /// `gh` reports check runs under `name` and legacy statuses under
        /// `context`; either may be the human label.
        public var label: String { name ?? context ?? "check" }

        public var hasFailed: Bool {
            let verdict = (conclusion ?? state ?? "").uppercased()
            return ["FAILURE", "ERROR", "TIMED_OUT", "CANCELLED", "ACTION_REQUIRED", "STARTUP_FAILURE"]
                .contains(verdict)
        }
    }

    public init(
        state: String,
        mergedAt: Date? = nil,
        mergeCommit: MergeCommit? = nil,
        url: String? = nil,
        statusCheckRollup: [StatusCheck]? = nil
    ) {
        self.state = state
        self.mergedAt = mergedAt
        self.mergeCommit = mergeCommit
        self.url = url
        self.statusCheckRollup = statusCheckRollup
    }

    public var isMerged: Bool { state.uppercased() == "MERGED" && mergedAt != nil }

    public var failingChecks: [String] {
        (statusCheckRollup ?? []).filter(\.hasFailed).map(\.label)
    }
}

public struct GHRepoInfo: Codable, Sendable, Hashable {
    public var nameWithOwner: String
    public var defaultBranchRef: BranchRef?

    public struct BranchRef: Codable, Sendable, Hashable {
        public var name: String
        public init(name: String) { self.name = name }
    }

    public init(nameWithOwner: String, defaultBranchRef: BranchRef? = nil) {
        self.nameWithOwner = nameWithOwner
        self.defaultBranchRef = defaultBranchRef
    }

    public var defaultBranch: String { defaultBranchRef?.name ?? "main" }
}
