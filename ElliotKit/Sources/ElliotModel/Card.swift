import Foundation

/// A board card: one unit of work, from backlog story to merged PR.
///
/// The backlog holds **user stories**, so `story` is the normal payload and
/// `title` is just the board label. `body` remains for cards that are a plain
/// note rather than a story. `issueNumber` is filled in once `create-issue` has
/// run; `prNumber` and `branch` once `implement-issue` has. Those three are
/// learned from `gh`, never guessed — see the verifiers.
public struct Card: Identifiable, Codable, Sendable, Hashable {
    public var id: UUID
    public var repoID: UUID
    public var title: String
    public var body: String
    public var story: UserStory?
    public var column: Column

    /// Position within the column. `Double` so an insert between two neighbours
    /// is `(prev + next) / 2` instead of renumbering the whole column.
    public var orderIndex: Double

    public var issueNumber: Int?
    public var issueURL: String?
    public var prNumber: Int?
    public var prURL: String?

    /// The PR's head branch, read back from `gh` (`headRefName`). The slug half
    /// is chosen by the agent from the issue title, so it can only be learned.
    public var branch: String?

    public var columnEnteredAt: Date
    public var lastError: String?
    public var createdAt: Date
    public var updatedAt: Date

    /// The caller's own key for the request that made this card, when it gave
    /// one. Unique across the board; `nil` means no guarantee was asked for.
    ///
    /// Kept on the row rather than in a table of recent requests: a create that
    /// times out on the way back is retried against an app that may have
    /// started up in between, and nothing held in memory would have seen the
    /// first attempt.
    public var idempotencyKey: String?

    public init(
        id: UUID = UUID(),
        repoID: UUID,
        title: String,
        body: String = "",
        story: UserStory? = nil,
        column: Column = .backlog,
        orderIndex: Double = 0,
        issueNumber: Int? = nil,
        issueURL: String? = nil,
        prNumber: Int? = nil,
        prURL: String? = nil,
        branch: String? = nil,
        columnEnteredAt: Date,
        lastError: String? = nil,
        createdAt: Date,
        updatedAt: Date,
        idempotencyKey: String? = nil
    ) {
        self.id = id
        self.repoID = repoID
        self.title = title
        self.body = body
        self.story = story
        self.column = column
        self.orderIndex = orderIndex
        self.issueNumber = issueNumber
        self.issueURL = issueURL
        self.prNumber = prNumber
        self.prURL = prURL
        self.branch = branch
        self.columnEnteredAt = columnEnteredAt
        self.lastError = lastError
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.idempotencyKey = idempotencyKey
    }
}

public extension Card {
    /// What the board shows. A story's own words win over a stale label.
    var displayTitle: String {
        let t = title.trimmed()
        if !t.isEmpty { return t }
        return story?.shortTitle ?? ""
    }

    /// The free text handed to `create-issue`.
    ///
    /// For a story card this is the narrative plus its acceptance criteria —
    /// the label is left out, since it only restates the `want` clause.
    var ideaText: String {
        if let story, story.isComplete { return story.issueBody }
        let t = title.trimmed(), b = body.trimmed()
        if b.isEmpty { return t }
        if t.isEmpty { return b }
        return t.hasSuffix(".") ? "\(t) \(b)" : "\(t). \(b)"
    }

    /// A story was started but is missing one of its three parts. Distinguished
    /// from "nothing to file at all" so the UI can point at the gap.
    var hasIncompleteStory: Bool {
        guard let story else { return false }
        return !story.isComplete
    }
}
