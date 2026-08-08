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

    /// The head commit, carried on the **listing** so the board can tell whether
    /// a status it stored still describes this pull request — without paying for
    /// a second call. One cheap scalar; it is what turns the per-card `pr view`
    /// into something that can be skipped.
    public var headRefOid: String?

    public init(
        number: Int,
        url: String,
        title: String,
        body: String? = nil,
        headRefName: String,
        isDraft: Bool,
        state: String,
        createdAt: Date? = nil,
        mergedAt: Date? = nil,
        headRefOid: String? = nil
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
        self.headRefOid = headRefOid
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
        if isMerged {
            return .merged(commitSHA: nil, number: number, url: url, branch: headRefName)
        }
        if isClosedUnmerged {
            return .closedUnmerged(number: number, url: url, branch: headRefName)
        }
        return .prOpen(number: number, url: url, isDraft: isDraft, branch: headRefName)
    }
}

public struct GHMergeStatus: Codable, Sendable, Hashable {
    public var state: String
    public var mergedAt: Date?
    public var mergeCommit: MergeCommit?
    public var url: String?
    public var statusCheckRollup: [StatusCheck]?

    /// `MERGEABLE` · `CONFLICTING` · `UNKNOWN`.
    public var mergeable: String?
    /// `CLEAN` · `DIRTY` · `BLOCKED` · `BEHIND` · `UNSTABLE` · `DRAFT` ·
    /// `HAS_HOOKS` · `UNKNOWN`. GitHub computes this lazily, so the first
    /// request for a pull request it has not considered lately answers
    /// `UNKNOWN` — observed on #164 and #154.
    public var mergeStateStatus: String?
    /// `APPROVED` · `CHANGES_REQUESTED` · `REVIEW_REQUIRED`, or `""` when nobody
    /// has reviewed. An empty string, not null.
    public var reviewDecision: String?
    /// The commit the checks above were run against.
    public var headRefOid: String?

    public struct MergeCommit: Codable, Sendable, Hashable {
        public var oid: String?
        public init(oid: String?) { self.oid = oid }
    }

    public struct StatusCheck: Codable, Sendable, Hashable {
        public var name: String?
        public var context: String?
        public var conclusion: String?
        public var state: String?

        /// A CheckRun's lifecycle — `QUEUED`, `IN_PROGRESS`, `COMPLETED`.
        ///
        /// Distinct from `state`, which is what a *legacy StatusContext* carries;
        /// the two shapes arrive in the same array and only one of the two fields
        /// is ever populated. Requesting `statusCheckRollup` already returns this
        /// — it was simply never decoded, which is why nothing could tell a check
        /// still running from one that had passed.
        ///
        /// Appended last, here and in the memberwise `init`, so every existing
        /// call site keeps compiling unchanged.
        public var status: String?

        public init(
            name: String? = nil, context: String? = nil, conclusion: String? = nil,
            state: String? = nil, status: String? = nil
        ) {
            self.name = name
            self.context = context
            self.conclusion = conclusion
            self.state = state
            self.status = status
        }

        /// `gh` reports check runs under `name` and legacy statuses under
        /// `context`; either may be the human label.
        public var label: String { name ?? context ?? "check" }

        public var hasFailed: Bool {
            let verdict = (conclusion ?? state ?? "").uppercased()
            return ["FAILURE", "ERROR", "TIMED_OUT", "CANCELLED", "ACTION_REQUIRED", "STARTUP_FAILURE"]
                .contains(verdict)
        }

        /// Finished without judging anything.
        ///
        /// A GitHub Actions job gated by an `if:` comes back `COMPLETED` with
        /// `SKIPPED`; `NEUTRAL` and `STALE` are the same shape. Counting these
        /// as passes is the "a lot of checks all `skipped` is not a green" trap,
        /// which is the *same* false green `CIState.noChecks` exists to name,
        /// reached by a different route.
        ///
        /// ⚠️ This is **not** the name-based inert-check discounting that was
        /// deliberately declined for this feature. That one needs a maintained
        /// list of check *names* — `CodeQL`, `renovate/*` — which drifts, and
        /// whose data already lives in `repo-audit`. This reads GitHub's own
        /// `conclusion` vocabulary: no list, nothing to keep in sync, and a
        /// CodeQL run that genuinely succeeded still counts as a pass.
        public var isNonVerdict: Bool {
            ["SKIPPED", "NEUTRAL", "STALE"].contains((conclusion ?? "").uppercased())
        }

        /// Still to come. A check that has not finished cannot be counted green,
        /// and a check that says *nothing at all* is counted as pending too —
        /// erring toward "not yet" rather than toward a pass nobody established.
        public var isPending: Bool {
            if let status, !status.isEmpty {
                return status.uppercased() != "COMPLETED"
            }
            if let state, !state.isEmpty {
                return ["PENDING", "EXPECTED", "QUEUED", "IN_PROGRESS", "WAITING", "REQUESTED"]
                    .contains(state.uppercased())
            }
            // Empty, not just absent: captured from the wire, `gh` renders an
            // unfinished check's conclusion as `""` rather than as null. Testing
            // `conclusion == nil` alone counted a running check as finished.
            return (conclusion ?? "").isEmpty
        }
    }

    public init(
        state: String,
        mergedAt: Date? = nil,
        mergeCommit: MergeCommit? = nil,
        url: String? = nil,
        statusCheckRollup: [StatusCheck]? = nil,
        mergeable: String? = nil,
        mergeStateStatus: String? = nil,
        reviewDecision: String? = nil,
        headRefOid: String? = nil
    ) {
        self.state = state
        self.mergedAt = mergedAt
        self.mergeCommit = mergeCommit
        self.url = url
        self.statusCheckRollup = statusCheckRollup
        self.mergeable = mergeable
        self.mergeStateStatus = mergeStateStatus
        self.reviewDecision = reviewDecision
        self.headRefOid = headRefOid
    }

    public var isMerged: Bool { state.uppercased() == "MERGED" && mergedAt != nil }

    public var failingChecks: [String] {
        (statusCheckRollup ?? []).filter(\.hasFailed).map(\.label)
    }

    /// This reading, as the dated row the board keeps.
    ///
    /// An absent field becomes `""`, which the facets read as *unknown* for
    /// mergeability and as *nobody reviewed* for the review. That asymmetry is
    /// deliberate and safe in one direction only: `ReviewState.none` is never a
    /// sign, so a field nobody asked for cannot invent a warning. Mergeability
    /// goes the other way and degrades to `.unknown`, which is the honest answer
    /// when nothing was requested.
    public func prStatus(repoID: UUID, prNumber: Int, checkedAt: Date) -> PRStatus {
        PRStatus(
            repoID: repoID,
            prNumber: prNumber,
            headRefOid: headRefOid ?? "",
            checkedAt: checkedAt,
            rawMergeStateStatus: mergeStateStatus ?? "",
            rawMergeable: mergeable ?? "",
            rawReviewDecision: reviewDecision ?? "",
            checks: statusCheckRollup ?? []
        )
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
