import Foundation

/// Finds the pull request an `implement-issue` run produced.
///
/// The obvious lookup — `gh pr list --head feat/<issue>-<slug>` — cannot be
/// used: the slug half of the branch name is written by the agent from the
/// issue title, so it is never knowable in advance. Instead every PR is listed
/// and scored against the issue.
public enum PRMatcher {

    public struct Score: Sendable, Hashable {
        public var branchMatches: Bool
        public var titleMatches: Bool
        public var bodyCloses: Bool
        public var createdAfterRun: Bool

        public var total: Int {
            (branchMatches ? 8 : 0)
                + (titleMatches ? 4 : 0)
                + (bodyCloses ? 2 : 0)
                + (createdAfterRun ? 1 : 0)
        }

        /// A branch, a title or an explicit close is each enough on its own.
        /// Being recent is only a tiebreak — a resumed run reuses a PR that
        /// predates it, so recency must never be a filter.
        public var isPlausible: Bool { branchMatches || titleMatches || bodyCloses }
    }

    public static func score(_ pr: GHPullRequest, issue: Int, runStartedAt: Date?) -> Score {
        Score(
            branchMatches: branchMatches(pr.headRefName, issue: issue),
            titleMatches: titleMatches(pr.title, issue: issue),
            bodyCloses: bodyCloses(pr.body, issue: issue),
            createdAfterRun: {
                guard let created = pr.createdAt, let start = runStartedAt else { return false }
                return created >= start
            }()
        )
    }

    public static func bestMatch(
        among prs: [GHPullRequest],
        issue: Int,
        runStartedAt: Date? = nil
    ) -> GHPullRequest? {
        prs
            .map { ($0, score($0, issue: issue, runStartedAt: runStartedAt)) }
            .filter { $0.1.isPlausible }
            .max { lhs, rhs in
                if lhs.1.total != rhs.1.total { return lhs.1.total < rhs.1.total }
                // Same score: prefer the most recent, then the highest number,
                // so the choice is deterministic.
                let l = lhs.0.createdAt ?? .distantPast
                let r = rhs.0.createdAt ?? .distantPast
                return l != r ? l < r : lhs.0.number < rhs.0.number
            }?
            .0
    }

    /// `feat/47-add-dark-mode` matches issue 47.
    ///
    /// The trailing hyphen is load-bearing: without it, issue 4 would match
    /// `feat/47-…`. The prefix is not pinned to `feat/` because the branch
    /// convention comes from the repo profile and may be `fix/` or `chore/`.
    static func branchMatches(_ branch: String, issue: Int) -> Bool {
        guard let slash = branch.lastIndex(of: "/") else {
            return matchesLeadingNumber(branch.dropFirst(0), issue: issue)
        }
        return matchesLeadingNumber(branch[branch.index(after: slash)...], issue: issue)
    }

    private static func matchesLeadingNumber(_ tail: Substring, issue: Int) -> Bool {
        let digits = tail.prefix { $0.isNumber }
        guard !digits.isEmpty, Int(digits) == issue else { return false }
        // Must be followed by a separator, so `47` does not match `470`.
        let rest = tail.dropFirst(digits.count)
        return rest.isEmpty || rest.first == "-" || rest.first == "_"
    }

    /// `implement-issue` titles its PR `<type>(<scope>): <subject> (#47)`.
    static func titleMatches(_ title: String, issue: Int) -> Bool {
        title.contains("(#\(issue))")
    }

    /// `Closes #47`, `fixes #47`, `resolve #47`…
    static func bodyCloses(_ body: String?, issue: Int) -> Bool {
        guard let body, !body.isEmpty else { return false }
        let keywords = ["close", "closes", "closed", "fix", "fixes", "fixed", "resolve", "resolves", "resolved"]
        let lowered = body.lowercased()
        for keyword in keywords {
            var search = lowered[...]
            while let range = search.range(of: "\(keyword) #\(issue)") {
                let after = range.upperBound
                // Reject "closes #470" when looking for 47.
                if after == lowered.endIndex || !lowered[after].isNumber { return true }
                search = lowered[after...]
            }
        }
        return false
    }
}
