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

    /// The analysis lens this card was found through, when it was found rather
    /// than written.
    ///
    /// `nil` for a card from the New-story sheet, from `board_create_card`, or
    /// imported from GitHub — and `nil` is drawn as nothing, never as a
    /// placeholder glyph. A mark meaning "no lens" reads as a mark meaning
    /// something, which is the guess this field exists to avoid making.
    ///
    /// Provenance, not classification: it records which lens *found* the card,
    /// so it is set once at acceptance and never re-derived from the card's
    /// words afterwards. Inferring it later would put what was guessed in the
    /// same face as what was chosen.
    public var angle: AnalysisAngle?

    /// The labels the issue this card becomes should carry, by **name**.
    ///
    /// A decision someone made and can see, which is the whole of the point:
    /// without it `create-issue` picks labels from its own reading of the prose
    /// and the board never says which. Empty by default, and empty is the
    /// common path — the prompt then gains no `--label` at all and the skill
    /// behaves exactly as it always has.
    ///
    /// Names rather than ids, because a name is what `gh issue create --label`
    /// takes and what a human reads. The cost is that a renamed label stops
    /// matching, and that is the **wanted** outcome: the card goes on recording
    /// what someone asked for and the editor marks it as one this repository no
    /// longer has, instead of silently forgetting it.
    ///
    /// No colour is stored beside them. The repository owns colours and
    /// `RequiredLabel` carries them for creation; a second copy here would be a
    /// second source of truth with nothing keeping it current.
    public var labels: [String]

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
        angle: AnalysisAngle? = nil,
        labels: [String] = [],
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
        self.angle = angle
        self.labels = labels
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

/// How long a card has sat where it is, when that is worth saying.
///
/// `columnEnteredAt` has been recorded since the first migration and read in
/// exactly one place — the inspector, whose own comment calls a card stuck
/// three days in review "the single most useful thing a pipeline can tell
/// you". It was invisible on the board, which is where you actually look.
///
/// The judgement lives here rather than in the view for the usual reason:
/// `ElliotApp` has no test target, so a threshold written in a SwiftUI body is
/// a rule nothing can prove.
public enum Stagnation: Sendable, Equatable {
    /// Sitting, but not yet long enough to mean anything.
    case waiting(days: Int)
    /// Long enough that it is probably not moving on its own.
    case stalled(days: Int)

    /// Day-grained on purpose: this is an age, and an age that ticks is a
    /// stopwatch. `RunningStrip` already owns the second-by-second clock.
    public var shortLabel: String {
        switch self {
        case .waiting(let days), .stalled(let days): "\(days)d"
        }
    }

    public var days: Int {
        switch self {
        case .waiting(let days), .stalled(let days): days
        }
    }
}

public extension Card {
    /// Below this a card is simply in play, not stagnant.
    internal static let waitingThresholdDays = 1
    /// At or past this it has stopped being a queue and started being a pile.
    internal static let stalledThresholdDays = 3

    /// How long this card has been in its column, or `nil` when that says
    /// nothing.
    ///
    /// Backlog and Done are excluded by design, not by omission: a backlog is
    /// *meant* to hold things for weeks, and a merged card is finished. Age
    /// only carries information for the three columns a card is passing
    /// through.
    ///
    /// One honest limit: a card imported from GitHub gets `columnEnteredAt =
    /// now`, so a two-year-old issue reads as fresh until it next moves. The
    /// field records when Elliot saw it arrive, which is all it ever claimed.
    func stagnation(now: Date) -> Stagnation? {
        switch column {
        case .backlog, .done: return nil
        case .todo, .inProgress, .inReview: break
        }
        let days = Int(now.timeIntervalSince(columnEnteredAt) / 86_400)
        guard days >= Self.waitingThresholdDays else { return nil }
        return days >= Self.stalledThresholdDays ? .stalled(days: days) : .waiting(days: days)
    }
}
