import Foundation

/// One reading of a repository, through one or more lenses.
///
/// There is deliberately **no `state` field**. An analysis is running while any
/// of its runs is non-terminal, and its runs already answer that. A stored
/// counter would be a second reservoir of truth that drifts on the first crash
/// — the same reason a card has no "is running" flag.
public struct Analysis: Identifiable, Codable, Sendable, Hashable {
    public var id: UUID
    public var repoID: UUID
    public var angles: [AnalysisAngle]
    /// Free text folded into every angle's prompt. This is the custom lens: a
    /// seventh enum case would need a briefing, this needs a sentence.
    public var extraInstructions: String
    public var maxStoriesPerAngle: Int
    public var origin: AnalysisOrigin
    public var createdAt: Date

    public init(
        id: UUID = UUID(),
        repoID: UUID,
        angles: [AnalysisAngle],
        extraInstructions: String = "",
        maxStoriesPerAngle: Int = 8,
        origin: AnalysisOrigin = .manual,
        createdAt: Date
    ) {
        self.id = id
        self.repoID = repoID
        self.angles = angles
        self.extraInstructions = extraInstructions
        self.maxStoriesPerAngle = maxStoriesPerAngle
        self.origin = origin
        self.createdAt = createdAt
    }
}

public enum AnalysisOrigin: Codable, Sendable, Hashable {
    case manual
    case mcp(client: String)
}

/// What an analysis run has to say about itself, written onto the run when it
/// finishes.
///
/// One nullable column rather than four: every field here is meaningless for a
/// card run, and keeping them together makes that obvious.
public struct AnalysisRunReport: Codable, Sendable, Hashable {
    public enum HarvestSource: String, Codable, Sendable, Hashable {
        /// The artifact the prompt asked for.
        case artifact
        /// A fenced JSON block recovered from the closing message.
        case resultText
        case none
    }

    public var harvestSource: HarvestSource
    public var kept: Int
    /// Why each dropped story was dropped. Shown, never swallowed.
    public var dropped: [String]
    /// The git sentinel. An analysis has no business writing to the repository
    /// and Elliot cannot prevent it, so it checks the outcome instead.
    public var workingTreeChanged: Bool
    /// `git status --porcelain` after the run, when it differs from before.
    public var workingTreeDiff: String?

    public init(
        harvestSource: HarvestSource,
        kept: Int = 0,
        dropped: [String] = [],
        workingTreeChanged: Bool = false,
        workingTreeDiff: String? = nil
    ) {
        self.harvestSource = harvestSource
        self.kept = kept
        self.dropped = dropped
        self.workingTreeChanged = workingTreeChanged
        self.workingTreeDiff = workingTreeDiff
    }
}
