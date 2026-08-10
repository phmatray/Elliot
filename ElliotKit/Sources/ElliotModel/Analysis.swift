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
    ///
    /// Tri-state, not a plain `Bool`: the baseline this compares against lives
    /// only in the scheduler's memory, so a run orphaned by a crash has
    /// nothing to compare against.
    /// - `nil` — the sentinel never ran; an app that died mid-run lost the
    ///   baseline, so this is honestly "unchecked", not "clean".
    /// - `false` — checked, and the tree was untouched.
    /// - `true` — checked, and the tree moved; `workingTreeDiff` says how.
    public var workingTreeChanged: Bool?
    /// `git status --porcelain` after the run, when it differs from before.
    public var workingTreeDiff: String?

    public init(
        harvestSource: HarvestSource,
        kept: Int = 0,
        dropped: [String] = [],
        workingTreeChanged: Bool? = nil,
        workingTreeDiff: String? = nil
    ) {
        self.harvestSource = harvestSource
        self.kept = kept
        self.dropped = dropped
        self.workingTreeChanged = workingTreeChanged
        self.workingTreeDiff = workingTreeDiff
    }
}

public extension AnalysisRunReport {
    /// What a repeat harvest leaves on the run.
    ///
    /// The harvest's own answer — `harvestSource`, `kept`, `dropped` — comes
    /// from `self`, the fresh read. Replacing it outright is the whole point of
    /// reading the file again: a merged `dropped` would keep complaining about
    /// a parse that has since succeeded, and a `kept` that took the larger of
    /// the two would report stories no proposal in the store corresponds to.
    ///
    /// The sentinel comes from `previous`, and is **never computed here**. A
    /// repeat harvest touches no git: `git status` an hour after the run says
    /// what has happened since, not what the run did. So `nil` stays `nil` —
    /// the tempting `workingTreeChanged = false` would claim a check that never
    /// ran, which is exactly the collapse the tri-state exists to prevent
    /// (#39), and a run orphaned by a crash is precisely the case that would be
    /// laundered into "verified clean" by being read a second time (#330).
    ///
    /// The diff travels with the flag rather than beside it, because the two
    /// are one fact: a `true` that lost its `workingTreeDiff` is a red badge
    /// with nothing under it.
    func inheritingSentinel(from previous: AnalysisRunReport?) -> AnalysisRunReport {
        var carried = self
        carried.workingTreeChanged = previous?.workingTreeChanged
        carried.workingTreeDiff = previous?.workingTreeDiff
        return carried
    }
}
