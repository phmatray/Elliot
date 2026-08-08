import Foundation

// Decoded straight from `gh … --json`. These are the authority on what a run
// produced: the agent's prose is a hint, `gh` is the fact.

public struct GHIssue: Codable, Sendable, Hashable {
    public var number: Int
    public var title: String
    public var url: String
    public var state: String?
    public var createdAt: Date?

    /// The issue text. Becomes the imported card's `body`; `nil` when the caller
    /// asked `gh` for a narrower `--json` set.
    ///
    /// Appended last, here and in the memberwise `init`, so every existing call
    /// site keeps compiling unchanged.
    public var body: String?

    public init(
        number: Int, title: String, url: String,
        state: String? = nil, createdAt: Date? = nil, body: String? = nil
    ) {
        self.number = number
        self.title = title
        self.url = url
        self.state = state
        self.createdAt = createdAt
        self.body = body
    }

    public var isOpen: Bool { (state ?? "OPEN").uppercased() == "OPEN" }

    /// `gh` omits `state` when it was not requested. An issue Elliot cannot
    /// classify is treated as open — the state that keeps it on the board
    /// rather than quietly filing it under Done.
    public var isClosed: Bool { (state ?? "OPEN").uppercased() == "CLOSED" }
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

    /// The same three conclusions `Verifier` reaches, stated in the same
    /// vocabulary — so `PRWatcher` joins that vocabulary instead of
    /// paraphrasing it into a fourth copy of a switch that lives elsewhere.
    ///
    /// The order matters: GitHub reports a merged pull request as `CLOSED`
    /// with `mergedAt` set, so `isMerged` — which reads both — must be asked
    /// first, or every merge would be read as an abandonment.
    ///
    /// `commitSHA` is `nil` because `gh pr list` does not carry it; the merge
    /// commit is something only `GHMergeStatus` knows.
    public var verifiedOutcome: VerifiedOutcome {
        if isMerged { return .merged(commitSHA: nil) }
        if isClosedUnmerged { return .closedUnmerged }
        return .prOpen(number: number, url: url, isDraft: isDraft, branch: headRefName)
    }
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

/// GitHub's primary-language classification.
public struct GHLanguage: Codable, Sendable, Hashable {
    public var name: String
    public init(name: String) { self.name = name }
}

/// One row of `gh repo list <owner> --json …`.
public struct GHRepoSummary: Codable, Sendable, Hashable {
    public var nameWithOwner: String
    public var visibility: String
    public var defaultBranchRef: GHRepoInfo.BranchRef?
    public var isFork: Bool
    public var isArchived: Bool
    public var url: String?

    /// `null` for a repository with no detectable code. The field is always
    /// requested — `GHClientFieldsTests` pins that — so `nil` here means
    /// "GitHub detected no language", never "nobody asked".
    public var primaryLanguage: GHLanguage?
    public var isEmpty: Bool

    public init(
        nameWithOwner: String, visibility: String,
        defaultBranchRef: GHRepoInfo.BranchRef? = nil,
        isFork: Bool = false, isArchived: Bool = false, url: String? = nil,
        primaryLanguage: GHLanguage? = nil, isEmpty: Bool = false
    ) {
        self.nameWithOwner = nameWithOwner
        self.visibility = visibility
        self.defaultBranchRef = defaultBranchRef
        self.isFork = isFork
        self.isArchived = isArchived
        self.url = url
        self.primaryLanguage = primaryLanguage
        self.isEmpty = isEmpty
    }

    public var defaultBranch: String { defaultBranchRef?.name ?? "main" }
    public var repoVisibility: RepoVisibility { RepoVisibility(ghVisibility: visibility) }
    public var name: String { String(nameWithOwner.split(separator: "/").last ?? "") }
}

public extension GHRepoSummary {
    /// The languages the portfolio standard counts as code.
    ///
    /// ⚠️ GitHub classifies on byte volume, not on what a repository builds. This
    /// decides SCOPE — whether a code-only axis applies — and never which
    /// template or rule to use.
    static let codeLanguages: Set<String> = [
        "C#", "F#", "TypeScript", "JavaScript", "Rust", "Go", "Java", "Python",
        "Swift", "C", "C++", "Kotlin", "Ruby", "PHP", "HTML", "CSS",
    ]

    var isCode: Bool {
        guard let name = primaryLanguage?.name else { return false }
        return Self.codeLanguages.contains(name)
    }
}
