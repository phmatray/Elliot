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

/// A card that does not exist yet. `orderIndex` is deliberately absent: only
/// the store can allocate one, and a placeholder would be a second wrong source.
public struct CardSeed: Sendable, Equatable, Hashable {
    public var repoID: UUID
    public var title: String
    public var body: String
    public var column: Column
    public var issueNumber: Int?
    public var issueURL: String?
    public var prNumber: Int?
    public var prURL: String?
    public var branch: String?
    /// The GitHub object's creation date: the work is as old as the issue.
    public var createdAt: Date

    public init(
        repoID: UUID, title: String, body: String, column: Column,
        issueNumber: Int? = nil, issueURL: String? = nil,
        prNumber: Int? = nil, prURL: String? = nil, branch: String? = nil,
        createdAt: Date
    ) {
        self.repoID = repoID
        self.title = title
        self.body = body
        self.column = column
        self.issueNumber = issueNumber
        self.issueURL = issueURL
        self.prNumber = prNumber
        self.prURL = prURL
        self.branch = branch
        self.createdAt = createdAt
    }
}

/// The fields an adoption overwrites — and only these. Column, order, story and
/// error keep their own owners.
public struct AdoptedFields: Sendable, Equatable, Hashable {
    public var title: String
    public var body: String
    public var issueNumber: Int?
    public var issueURL: String?
    public var prNumber: Int?
    public var prURL: String?
    public var branch: String?

    public init(
        title: String, body: String,
        issueNumber: Int? = nil, issueURL: String? = nil,
        prNumber: Int? = nil, prURL: String? = nil, branch: String? = nil
    ) {
        self.title = title
        self.body = body
        self.issueNumber = issueNumber
        self.issueURL = issueURL
        self.prNumber = prNumber
        self.prURL = prURL
        self.branch = branch
    }
}

public enum ImportAction: Sendable, Equatable, Hashable {
    case create(CardSeed)
    /// `moveTo` is non-nil only for a strictly forward move.
    case adopt(cardID: UUID, fields: AdoptedFields, moveTo: Column?)
    case unchanged(cardID: UUID)
}

public struct ImportPlan: Sendable, Equatable {
    public var actions: [ImportAction]
    public var skippedDismissed: Int

    public init(actions: [ImportAction] = [], skippedDismissed: Int = 0) {
        self.actions = actions
        self.skippedDismissed = skippedDismissed
    }

    public var created: Int { actions.count { if case .create = $0 { true } else { false } } }
    public var adopted: Int { actions.count { if case .adopt = $0 { true } else { false } } }
    public var moved: Int {
        actions.count { if case .adopt(_, _, let to) = $0 { to != nil } else { false } }
    }
    public var unchanged: Int { actions.count { if case .unchanged = $0 { true } else { false } } }
}

public extension GitHubImporter {

    /// What a refresh should do. Pure — apply it with `GitHubImportService`.
    static func plan(
        repoID: UUID,
        issues: [GHIssue],
        pullRequests: [GHPullRequest],
        existingCards: [Card],
        dismissed: Set<ExternalRef>,
        now: Date
    ) -> ImportPlan {
        var plan = ImportPlan()

        for unit in group(issues: issues, pullRequests: pullRequests) {
            // The user deleted this card and meant it.
            guard !unit.refs.contains(where: dismissed.contains) else {
                plan.skippedDismissed += 1
                continue
            }

            let issueOwner = unit.issue.flatMap { issue in
                existingCards.first { $0.issueNumber == issue.number }
            }
            let prOwner = unit.pullRequest.flatMap { pr in
                existingCards.first { $0.prNumber == pr.number }
            }

            // Ownership is first-come and permanent, and that cuts both ways:
            // when the issue and the pull request are already held by two
            // *different* cards, this pass does not get to merge them. Each
            // keeps only what it already holds, so neither number is claimed
            // twice. Handing the pull request to the issue's card here — or the
            // issue to the pull request's card, which is the same mistake
            // mirrored — would violate the unique indexes on write.
            if let issueOwner, let prOwner, issueOwner.id != prOwner.id {
                plan.actions.append(action(for: ImportUnit(issue: unit.issue), owner: issueOwner))
                plan.actions.append(action(for: ImportUnit(pullRequest: unit.pullRequest), owner: prOwner))
                continue
            }

            guard let owner = issueOwner ?? prOwner else {
                plan.actions.append(
                    .create(seed(for: unit, repoID: repoID, column: column(for: unit), now: now)))
                continue
            }
            plan.actions.append(action(for: unit, owner: owner))
        }
        return plan
    }

    /// What one unit does to the one card that already owns part of it.
    ///
    /// The owner's own numbers win over the unit's, so a card keeps what it
    /// holds; it only ever *gains* a number no other card had.
    private static func action(for unit: ImportUnit, owner: Card) -> ImportAction {
        let fields = AdoptedFields(
            title: unit.issue?.title ?? unit.pullRequest?.title ?? owner.title,
            body: unit.issue?.body ?? unit.pullRequest?.body ?? owner.body,
            issueNumber: owner.issueNumber ?? unit.issue?.number,
            issueURL: owner.issueURL ?? unit.issue?.url,
            prNumber: owner.prNumber ?? unit.pullRequest?.number,
            prURL: owner.prURL ?? unit.pullRequest?.url,
            branch: owner.branch ?? unit.pullRequest?.headRefName)

        // Forward only. A card in In Progress with a run in flight has no
        // pull request yet; recomputing it to To Do would drag it back under
        // the agent's feet. Demotion belongs to PRWatcher, which has real
        // evidence and records it as an error instead.
        let target = column(for: unit)
        let moveTo = target.boardIndex > owner.column.boardIndex ? target : nil

        if moveTo == nil, fields == AdoptedFields(of: owner) { return .unchanged(cardID: owner.id) }
        return .adopt(cardID: owner.id, fields: fields, moveTo: moveTo)
    }

    private static func seed(
        for unit: ImportUnit, repoID: UUID,
        column: Column, now: Date
    ) -> CardSeed {
        CardSeed(
            repoID: repoID,
            title: unit.issue?.title ?? unit.pullRequest?.title ?? "",
            body: unit.issue?.body ?? unit.pullRequest?.body ?? "",
            column: column,
            issueNumber: unit.issue?.number,
            issueURL: unit.issue?.url,
            prNumber: unit.pullRequest?.number,
            prURL: unit.pullRequest?.url,
            branch: unit.pullRequest?.headRefName,
            createdAt: unit.issue?.createdAt ?? unit.pullRequest?.createdAt ?? now)
    }
}

extension AdoptedFields {
    /// The same fields, read off a card the adoption would overwrite.
    ///
    /// "Has anything changed?" is then `==` rather than a hand-written
    /// comparison — which is what keeps a field added here later from silently
    /// falling out of it and reporting a changed card as `unchanged`.
    init(of card: Card) {
        self.init(
            title: card.title, body: card.body,
            issueNumber: card.issueNumber, issueURL: card.issueURL,
            prNumber: card.prNumber, prURL: card.prURL, branch: card.branch)
    }
}
