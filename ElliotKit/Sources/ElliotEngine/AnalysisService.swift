import ElliotModel
import ElliotProcess
import ElliotStore
import Foundation

public enum AnalysisError: Error, LocalizedError, Equatable {
    case repoNotFound(UUID)
    case repoDisabled(String)
    case noAngles
    case angleAlreadyRunning(AnalysisAngle)
    case analysisNotFound(UUID)

    public var errorDescription: String? {
        switch self {
        case .repoNotFound(let id): "No repository with id \(id)."
        case .repoDisabled(let name): "\(name) is disabled in Elliot."
        case .noAngles: "Pick at least one angle to read the repository through."
        case .angleAlreadyRunning(let angle): "A \(angle.title) analysis is already running on this repository."
        case .analysisNotFound(let id): "No analysis with id \(id)."
        }
    }
}

/// Starting analyses, and turning their proposals into cards.
///
/// Acceptance goes through `BoardService.createCard` — the same method the New
/// Card sheet and `board_create_card` use. There is deliberately no second way
/// to make a card, just as there is no second way to move one.
public actor AnalysisService {
    private let store: BoardStore
    private let launcher: any RunLaunching
    private let board: BoardService
    private let gh: GHClient

    public init(store: BoardStore, launcher: any RunLaunching, board: BoardService, gh: GHClient) {
        self.store = store
        self.launcher = launcher
        self.board = board
        self.gh = gh
    }

    public struct Started: Sendable {
        public var analysis: Analysis
        public var runs: [SkillRun]
    }

    // MARK: - Starting

    public func start(
        repoID: UUID,
        angles: [AnalysisAngle],
        extraInstructions: String = "",
        maxStoriesPerAngle: Int = 8,
        origin: AnalysisOrigin
    ) async throws -> Started {
        guard let repo = try await store.repo(id: repoID) else {
            throw AnalysisError.repoNotFound(repoID)
        }
        guard repo.isEnabled else { throw AnalysisError.repoDisabled(repo.displayName) }

        // Ordered-unique: ticking an angle twice in the UI is a slip, not a
        // request for two runs.
        var wanted: [AnalysisAngle] = []
        for angle in angles where !wanted.contains(angle) { wanted.append(angle) }
        guard !wanted.isEmpty else { throw AnalysisError.noAngles }

        // Dedupe key `(repoID, angle)`, refused rather than queued — the same
        // rule as a second `implement-issue 47`. It is also what contains the
        // one loop worth worrying about: an analysis run inherits the user's
        // MCP config, so its agent can see `elliot` and call board_analyze_repo.
        let inFlight = Set(
            (try await store.activeAnalysisRuns(repoID: repoID)).compactMap(\.analysisAngle)
        )
        if let clash = wanted.first(where: inFlight.contains) {
            throw AnalysisError.angleAlreadyRunning(clash)
        }

        let (titles, githubReachable) = await existingTitles(repo: repo)

        let now = Date()
        let analysis = Analysis(
            repoID: repoID, angles: wanted, extraInstructions: extraInstructions,
            maxStoriesPerAngle: maxStoriesPerAngle, origin: origin, createdAt: now
        )

        var runs: [SkillRun] = []
        for angle in wanted {
            let runID = UUID()
            let artifact = StoreLocation.analysisArtifactURL(analysisID: analysis.id, runID: runID)
            // Created up front so the agent has somewhere to write, and so
            // `--add-dir` points at a directory that exists.
            try? FileManager.default.createDirectory(
                at: artifact.deletingLastPathComponent(),
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            runs.append(SkillRun.analysis(
                id: runID,
                repoID: repoID,
                analysisID: analysis.id,
                analysisAngle: angle,
                prompt: AnalysisPromptBuilder.prompt(
                    angle: angle,
                    repoNameWithOwner: repo.nameWithOwner,
                    outputPath: artifact.path,
                    existingTitles: titles,
                    maxStories: maxStoriesPerAngle,
                    extraInstructions: extraInstructions,
                    githubTitlesAvailable: githubReachable
                ),
                cwd: repo.path,
                logPath: StoreLocation.runLogURL(runID: runID).path,
                stderrPath: StoreLocation.runStderrURL(runID: runID).path,
                createdAt: now
            ))
        }

        // The analysis and its runs land in one transaction; the scheduler is
        // handed the ids only after it commits. A crash in between leaves
        // nothing behind — not a queued run with no analysis, and not an
        // analysis with fewer runs than it was queued with — the same shape
        // as `commitMove`.
        try await store.saveAnalysis(analysis, runs: runs)
        for run in runs { await launcher.launch(runID: run.id) }

        return Started(analysis: analysis, runs: runs)
    }

    /// Board titles and open issue titles, newest first.
    ///
    /// The second element says whether GitHub answered: a partial duplicate
    /// check should be admitted in the prompt, not passed off as a complete one.
    private func existingTitles(repo: Repo) async -> ([String], Bool) {
        var dated: [(Date, String)] = []
        for card in (try? await store.cards(repoID: repo.id)) ?? [] {
            let title = card.displayTitle
            if !title.isEmpty { dated.append((card.createdAt, title)) }
        }

        var reachable = false
        if let issues = try? await gh.issues(repo: repo.nameWithOwner, limit: 100) {
            reachable = true
            for issue in issues where issue.isOpen {
                dated.append((issue.createdAt ?? .distantPast, issue.title))
            }
        }

        let titles = dated
            .sorted { $0.0 > $1.0 }
            .map(\.1)
            .prefix(AnalysisPromptBuilder.maxExistingTitles)
        return (Array(titles), reachable)
    }

    // MARK: - Reading

    public func analyses(repoID: UUID? = nil, limit: Int = 50) async throws -> [Analysis] {
        try await store.analyses(repoID: repoID, limit: limit)
    }

    public func proposals(
        analysisID: UUID? = nil,
        repoID: UUID? = nil,
        status: ProposalStatus? = nil,
        limit: Int = 500
    ) async throws -> [StoryProposal] {
        try await store.proposals(
            analysisID: analysisID, repoID: repoID, status: status, limit: limit
        )
    }

    // MARK: - Deciding

    /// The edited proposal is what will become the card. That is the point of
    /// letting them be edited: the corrected story reaches the board, not the
    /// model's first draft.
    public func updateProposal(_ proposal: StoryProposal) async throws {
        try await store.saveProposal(proposal)
    }

    @discardableResult
    public func accept(proposalIDs: [UUID]) async throws -> [Card] {
        var created: [Card] = []
        for id in proposalIDs {
            // The claim is the compare-and-set: only the caller that flips
            // proposed → accepted may create a card. `AnalysisService` is a
            // reentrant actor, so a plain "fetch, check .proposed, write" here
            // — as this used to be — lets two concurrent `accept` calls for the
            // same id (a double-tap, a retried MCP call) both pass the check
            // before either writes, and both create a card. A caller that
            // loses the claim moves on, the same as it used to for an id that
            // was already decided.
            guard try await store.claimProposal(id: id) else { continue }
            guard var proposal = try await store.proposal(id: id) else { continue }

            do {
                let card = try await board.createCard(
                    repoID: proposal.repoID,
                    title: proposal.title,
                    body: proposal.rationale,
                    story: proposal.story,
                    column: .backlog
                )
                proposal.acceptedCardID = card.id
                try await store.saveProposal(proposal)
                created.append(card)
            } catch {
                // The claim already flipped this to `.accepted`; card creation
                // failed after it. Give the proposal back rather than
                // stranding it accepted with nothing behind it.
                proposal.status = .proposed
                try? await store.saveProposal(proposal)
                throw error
            }
        }
        return created
    }

    public func reject(proposalIDs: [UUID]) async throws {
        for id in proposalIDs {
            guard var proposal = try await store.proposal(id: id), proposal.status == .proposed
            else { continue }
            // Marked, not deleted: an analysis you have been through should
            // still read as what it found, including what you turned down.
            proposal.status = .rejected
            try await store.saveProposal(proposal)
        }
    }
}
