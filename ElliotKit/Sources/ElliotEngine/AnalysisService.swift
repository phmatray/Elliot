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
    case runNotFound(UUID)
    case notAnAnalysisRun
    case runStillRunning
    case alreadyHarvested
    case reharvestInFlight

    public var errorDescription: String? {
        switch self {
        case .repoNotFound(let id): "No repository with id \(id)."
        case .repoDisabled(let name): "\(name) is disabled in Elliot."
        case .noAngles: "Pick at least one angle to read the repository through."
        case .angleAlreadyRunning(let angle): "A \(angle.title) analysis is already running on this repository."
        case .analysisNotFound(let id): "No analysis with id \(id)."
        case .runNotFound(let id): "No run with id \(id)."
        case .notAnAnalysisRun: "That run read no repository, so there is no artifact to re-read."
        case .runStillRunning: "This lens is still reading. It will be harvested when it finishes."
        case .alreadyHarvested: "This lens already landed proposals; re-reading it would duplicate them."
        case .reharvestInFlight: "This lens is already being harvested again."
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
    /// The **same** harvester `RunScheduler` holds, built here from the two
    /// collaborators this service already has — so no call site changes, and
    /// `ProposalHarvester.harvest` stays the one thing that turns an artifact
    /// into proposals. A second *holder* is not a second implementation, which
    /// is what the invariant protects.
    private let harvester: ProposalHarvester
    /// Re-harvests past their first `await` and not yet finished.
    ///
    /// This actor is **reentrant**: every guard in `reharvest` suspends, so two
    /// taps can both be past the store read that says "no proposals yet" before
    /// either has written any. The store read settles the *sequential* repeat —
    /// a stale view, a report claiming `kept: 0` while rows exist — and this
    /// settles the concurrent one. Neither closes the other's hole, which is
    /// the same pairing `claimProposal`'s comment spells out at length, and the
    /// same shape `start` already uses for `(repoID, angle)`.
    private var reharvesting: Set<UUID> = []

    public init(store: BoardStore, launcher: any RunLaunching, board: BoardService, gh: GHClient) {
        self.store = store
        self.launcher = launcher
        self.board = board
        self.gh = gh
        harvester = ProposalHarvester(store: store, gh: gh)
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
        //
        // ⛔ **All or nothing, and that is a decision rather than an accident of
        // where the `throw` sits.** Arming eight lenses while one is busy starts
        // none of them. Launching the other seven would be a *partial* success
        // that no caller can see: `board_analyze_repo` would answer with fewer
        // runs than it was asked for and no error, and `Analysis.angles` would
        // have to record the reduced set — so the panel, the harvester's
        // fallback angle and the MCP reply would all quietly describe something
        // other than what was requested. A named refusal is the cheaper failure.
        // What #293 fixes is that the refusal used to arrive only *after* the
        // press; the setup grid and footer now say it before.
        //
        // Through `BusyLenses` rather than a `Set` built here: the panel draws
        // its seals from the same value, so the hint and the fact are one query
        // and one rule rather than two that agree today.
        let busy = BusyLenses(
            repoID: repoID, runs: try await store.activeAnalysisRuns(repoID: repoID))
        if let clash = busy.clashes(with: wanted, in: repoID).first {
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

    // MARK: - Harvesting again

    /// Reads a finished lens's `stories.json` a second time, from the file
    /// Elliot already kept.
    ///
    /// `StoreLocation.analysisRunDirectory` has always promised this — *"kept
    /// beside the run's log so a harvest can be repeated from disk without
    /// spawning anything"* — and until #330 nothing repeated it. Two ways to
    /// lose a harvest both leave the file intact: the app dying mid-run, which
    /// `Reconciler.sweep` records as `.none` with *"Elliot stopped before this
    /// analysis was harvested"*, and a parse that kept nothing. The only
    /// recovery was Start, i.e. another `claude -p` at `bypassPermissions` and
    /// another full read of the repository, to re-derive a file already on disk.
    ///
    /// ⛔ **It launches nothing, and it lives here rather than on
    /// `RunScheduler` for exactly that reason.** The scheduler's whole job is
    /// starting children; a deliberately spawn-free action placed inside it is
    /// one "while we're here, if the artifact is missing, just re-run it" away
    /// from violating its own point. `harvest` does still ask `gh issue list`
    /// for duplicate hints — already `try?`-wrapped, so an unreachable GitHub
    /// costs hints and not proposals — because hobbling that would make a
    /// recovered harvest strictly worse than the original for no benefit.
    ///
    /// ⚠️ **Deliberately not gated on `repo.isEnabled`, unlike `start`.** This
    /// reads Elliot's own disk; a repository disabled or blocked in Preflight is
    /// precisely the case where re-running is worst and recovering the file
    /// already written is best. The only repository access is a
    /// `FileManager.fileExists` per evidence citation.
    @discardableResult
    public func reharvest(runID: UUID) async throws -> AnalysisRunReport {
        // Claimed **before the first `await`**, so no other call can reach the
        // guards below while this one is between them. Released in a `defer`,
        // which also covers every `throw` under it.
        guard !reharvesting.contains(runID) else { throw AnalysisError.reharvestInFlight }
        reharvesting.insert(runID)
        defer { reharvesting.remove(runID) }

        guard var run = try await store.run(id: runID) else {
            throw AnalysisError.runNotFound(runID)
        }
        guard run.isAnalysis, let analysisID = run.analysisID else {
            throw AnalysisError.notAnAnalysisRun
        }
        // A run still in flight has a live sentinel baseline in the scheduler's
        // memory and will be harvested by `completeAnalysisRun`. Re-harvesting
        // under it is how one report acquires two writers.
        guard run.state.isTerminal else { throw AnalysisError.runStillRunning }
        guard let analysis = try await store.analysis(id: analysisID) else {
            throw AnalysisError.analysisNotFound(analysisID)
        }
        guard let repo = try await store.repo(id: run.repoID) else {
            throw AnalysisError.repoNotFound(run.repoID)
        }

        // ⛔ **The store is the authority on whether this run already landed
        // rows, never the report.** `analysisReport.kept` is what the last
        // harvest *said*; this is what is actually in the table, which is the
        // only thing that can stop one story growing two proposals.
        guard try await store.proposals(runID: runID, limit: 1).isEmpty else {
            throw AnalysisError.alreadyHarvested
        }

        let fresh = await harvester.harvest(
            run: run,
            analysis: analysis,
            repo: repo,
            artifactURL: StoreLocation.analysisArtifactURL(analysisID: analysisID, runID: runID)
        )
        // Replaced, not merged — and the sentinel carried rather than recomputed.
        // Both halves are one decision, made once, in `ElliotModel`.
        let report = fresh.inheritingSentinel(from: run.analysisReport)
        run.analysisReport = report
        try await store.saveRun(run)
        return report
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

    /// Which lenses are already reading `repoID`, right now.
    ///
    /// The **same query and the same rule** `start` refuses on, exposed so the
    /// setup grid can say so before the press instead of after it. Two readers
    /// of one fact rather than a second implementation of it: a panel that
    /// counted "busy" its own way would be free to disagree with the throw, and
    /// the reader would have no way to tell which one was wrong.
    ///
    /// ⚠️ **It is a snapshot, and it stays one.** A run can start between this
    /// answer and the press — the caller's own MCP agent can start it — so
    /// nothing built on this may refuse anything. `start` is the authority; this
    /// is the courtesy.
    public func busyLenses(repoID: UUID) async throws -> BusyLenses {
        BusyLenses(repoID: repoID, runs: try await store.activeAnalysisRuns(repoID: repoID))
    }

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
            // was already decided. The same claim is what stops a concurrent
            // `reject` on this id from winning either: it is the identical
            // conditional update, aimed at `.rejected` instead, so whichever
            // of the two calls SQLite serializes first is the only one that
            // can still find `.proposed` to act on.
            guard try await store.claimProposal(id: id, .accept) else { continue }
            guard var proposal = try await store.proposal(id: id) else { continue }

            let card: Card
            do {
                // No idempotency key: the claim above is already the
                // compare-and-set that makes a double accept impossible, and it
                // is the stronger guard of the two — it is the proposal's own
                // status, so it also settles a concurrent `reject`, which a key
                // on the card would know nothing about.
                card = try await board.createCard(
                    repoID: proposal.repoID,
                    title: proposal.title,
                    body: proposal.rationale,
                    story: proposal.story,
                    column: .backlog,
                    // The one line this whole issue is about: the lens was
                    // chosen before the run and recorded on the proposal, and
                    // until now it stopped existing here.
                    angle: proposal.angle,
                    // And the label that lens honestly implies, for the three
                    // that have one — pre-ticked, shown in the editor, and
                    // removable like any other thing written on a card.
                    //
                    // Through `board.createCard` rather than written here:
                    // `BoardService` stays the only thing that makes a card, so
                    // this is a *caller* saying what it wants and not a second
                    // writer. `nil` from a lens with no honest label becomes no
                    // label at all, never a guess.
                    labels: proposal.angle.suggestedLabel.map { [$0] } ?? [],
                    // And the two signals that die the same way. The analysis
                    // sized the work and resolved every citation against the
                    // repository root; without these the Backlog carries almost
                    // nothing to rank by, and every accepted card reads as
                    // never appraised.
                    effort: proposal.effort,
                    evidence: proposal.evidence,
                    // The proposal's own moment, not `now`: that is when the
                    // harvest resolved the citations. Dating the reading to
                    // whenever somebody clicked Accept would make a week-old
                    // proposal look freshly measured.
                    appraisedAt: proposal.createdAt
                ).card
            } catch {
                // No card exists yet, so the claim can safely be given back —
                // a retry is exactly a fresh `accept` of a `.proposed`
                // proposal, not a duplicate waiting to happen.
                proposal.status = .proposed
                try? await store.saveProposal(proposal)
                throw error
            }

            // The card exists on the board from here on, regardless of what
            // happens next — `board.createCard` already committed it. Rolling
            // the claim back to `.proposed` at this point, the way the failure
            // path above does, would be the wrong failure mode: a retry would
            // create a *second* card for a proposal that already has one. If
            // this write fails, the honest state is the claim's own —
            // `.accepted`, just possibly missing the `acceptedCardID`
            // backlink — not a proposal that looks untouched while a card
            // for it already sits on the board.
            created.append(card)
            proposal.acceptedCardID = card.id
            try await store.saveProposal(proposal)
        }
        return created
    }

    public func reject(proposalIDs: [UUID]) async throws {
        for id in proposalIDs {
            // Same atomic claim `accept` uses, aimed the other way. A plain
            // "fetch, check .proposed, write" here — as this used to be —
            // reads a snapshot and later writes it back unconditionally: a
            // `reject` that loses a race against a concurrent `accept` for
            // the same id can read `.proposed` before the accept commits, and
            // then overwrite whatever the accept already committed —
            // including wiping `acceptedCardID` off a card that genuinely
            // exists. Marked, not deleted, same as before: an analysis you
            // have been through should still read as what it found, including
            // what you turned down — just never what you turned down after
            // someone else had already taken it.
            _ = try await store.claimProposal(id: id, .reject)
        }
    }

    /// Puts rejected proposals back on the list, and says how many really moved.
    ///
    /// The undo for `reject`, which marks rather than deletes precisely so that
    /// there is something left to put back — a promise the app could not keep
    /// until now, because nothing could read a `.rejected` row back and
    /// `claimProposal` could only move rows *out of* `.proposed` (#292).
    ///
    /// ⛔ **The count is the return value, not `proposalIDs.count`.** A restore
    /// can lose its claim to something that leaves a card on the board — a
    /// proposal carrying an `acceptedCardID` is refused by the store outright —
    /// and reporting the number asked for would hide exactly the case the
    /// refusal exists for. `reject` can afford to be looser because losing its
    /// claim only ever means "already decided"; this one cannot.
    @discardableResult
    public func restore(proposalIDs: [UUID]) async throws -> Int {
        var restored = 0
        for id in proposalIDs {
            // The identical compare-and-set `accept` and `reject` use, aimed
            // from `.rejected` back to `.proposed`. Not a fetch-check-write:
            // that is the shape whose race this method's two neighbours are
            // written to avoid, and running it here would reintroduce it one
            // direction further round.
            if try await store.claimProposal(id: id, .restore) { restored += 1 }
        }
        return restored
    }
}
