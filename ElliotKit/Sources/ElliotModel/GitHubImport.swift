import Foundation

public enum ExternalKind: String, Codable, Sendable, Hashable {
    case issue
    case pullRequest
}

/// One issue or one pull request, by number. The dedup key and the dismissal key.
public struct ExternalRef: Codable, Sendable, Hashable {
    public var kind: ExternalKind
    public var number: Int

    public init(kind: ExternalKind, number: Int) {
        self.kind = kind
        self.number = number
    }
}

/// One issue, its pull request, or both — whatever the board shows as one card.
public struct ImportUnit: Sendable, Equatable, Hashable {
    public var issue: GHIssue?
    public var pullRequest: GHPullRequest?

    public init(issue: GHIssue? = nil, pullRequest: GHPullRequest? = nil) {
        self.issue = issue
        self.pullRequest = pullRequest
    }

    public var refs: [ExternalRef] {
        var refs: [ExternalRef] = []
        if let issue { refs.append(ExternalRef(kind: .issue, number: issue.number)) }
        if let pr = pullRequest { refs.append(ExternalRef(kind: .pullRequest, number: pr.number)) }
        return refs
    }
}

/// Turns what `gh` lists into what the board should show. Pure — no I/O, no
/// clock, no randomness — so the whole matrix is testable, as `evaluateMove` is.
public enum GitHubImporter {

    /// Pairs each issue with the pull request that closes it; anything
    /// unclaimed stands alone. Issues are walked in ascending number and a
    /// matched pull request leaves the pool, so a pull request is claimed only
    /// once even when two issues would both score it as plausible.
    public static func group(issues: [GHIssue], pullRequests: [GHPullRequest]) -> [ImportUnit] {
        var claimed = Set<Int>()
        var units: [ImportUnit] = []

        for issue in issues.sorted(by: { $0.number < $1.number }) {
            let available = pullRequests.filter { !claimed.contains($0.number) }
            let match = PRMatcher.bestMatch(among: available, issue: issue.number)
            if let match { claimed.insert(match.number) }
            units.append(ImportUnit(issue: issue, pullRequest: match))
        }

        for pr in pullRequests.sorted(by: { $0.number < $1.number })
        where !claimed.contains(pr.number) {
            units.append(ImportUnit(pullRequest: pr))
        }
        return units
    }

    /// Where a unit belongs. Never `.backlog`: backlog is the column for a
    /// story that has not been filed, and everything here has a number.
    public static func column(for unit: ImportUnit) -> Column {
        if let pr = unit.pullRequest {
            if pr.isMerged { return .done }
            if pr.isClosedUnmerged {
                // The branch was abandoned. If the issue is still open the work
                // is not: send it back to To Do rather than call it finished.
                return (unit.issue?.isClosed ?? true) ? .done : .todo
            }
            return pr.isReadyForReview ? .inReview : .inProgress
        }
        return (unit.issue?.isClosed ?? false) ? .done : .todo
    }
}
