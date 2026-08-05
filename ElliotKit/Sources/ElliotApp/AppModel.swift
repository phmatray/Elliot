import ElliotEngine
import ElliotIPC
import ElliotModel
import ElliotProcess
import ElliotStore
import Foundation
import Observation

/// The app's root object: it wires the store, the engine and the MCP socket
/// together, and is the only thing the views talk to.
@MainActor
@Observable
public final class AppModel {
    public private(set) var repos: [Repo] = []
    public private(set) var cards: [Card] = []
    public private(set) var runsByCard: [UUID: [SkillRun]] = [:]
    public private(set) var globalChecks: [CheckResult] = []
    public private(set) var repoChecks: [UUID: [CheckResult]] = [:]
    public private(set) var status: String = "Starting…"
    public private(set) var isReady = false
    public private(set) var isImporting = false

    public var showingAnalysis = false
    /// The analysis the window is showing. `nil` means it is still in setup.
    public private(set) var activeAnalysisID: UUID?
    public private(set) var analysisRuns: [SkillRun] = []
    public private(set) var proposals: [StoryProposal] = []
    /// Whatever the window needs to say about the last action.
    public private(set) var analysisNote: String?

    /// Live tail per run, for the card's log view. Bounded — the file on disk
    /// is the complete record.
    public private(set) var liveLog: [UUID: [String]] = [:]

    /// The run currently holding each card, for every card at once.
    ///
    /// Batched rather than fetched per card: the board asks "would this move be
    /// allowed" for every column on every render, and `runAlreadyInFlight` is
    /// one of the answers.
    public private(set) var activeRuns: [UUID: SkillRun] = [:]

    public var selectedRepoID: UUID?
    public var selectedCardID: UUID?
    public var pendingFollowUps: PendingMerge?

    /// The last refused move, kept against the card it was refused for.
    ///
    /// A refusal used to be written into `status`, at the bottom of the window,
    /// where the next message overwrote it — so the explanation of why nothing
    /// happened arrived far from the card and left again on its own. This stays
    /// until the card moves or the user dismisses it.
    public private(set) var refusal: Refusal?

    public struct Refusal: Identifiable, Sendable, Equatable {
        public var id: UUID { cardID }
        public var cardID: UUID
        public var message: String
    }

    public func dismissRefusal() { refusal = nil }

    public struct PendingMerge: Identifiable, Sendable {
        public var id: UUID { cardID }
        public var cardID: UUID
        public var prNumber: Int
    }

    private var store: BoardStore?
    private var board: BoardService?
    private var scheduler: RunScheduler?
    private var watcher: PRWatcher?
    private var importer: GitHubImportService?
    /// Repositories already imported this session. In memory on purpose: a
    /// relaunch re-importing costs two `gh` calls and cannot duplicate anything.
    private var importedThisSession: Set<UUID> = []
    private var ipcServer: IPCServer?
    private var toolConfig: ToolConfig?
    private var analysisService: AnalysisService?
    private var observationTasks: [Task<Void, Never>] = []
    private var proposalObservation: Task<Void, Never>?

    public init() {}

    // MARK: - Startup

    public func start() async {
        do {
            try StoreLocation.ensureDirectories()
            let store = try BoardStore.open()
            self.store = store

            status = "Reading your shell environment…"
            // Captured, never inherited: launched from the Finder this process
            // sees only /usr/bin:/bin:/usr/sbin:/sbin.
            let environment = await LoginShellEnvironment.capture()
            let locator = ToolLocator(environment: environment)
            async let claude = locator.locate("claude")
            async let gh = locator.locate("gh")
            async let git = locator.locate("git")

            let config = ToolConfig(
                claudePath: await claude?.path ?? "",
                ghPath: await gh?.path ?? "",
                gitPath: await git?.path ?? "",
                environment: environment.childEnvironment(cwd: NSHomeDirectory())
            )
            toolConfig = config

            let ghClient = GHClient(config: config)
            let verifier = Verifier(gh: ghClient)
            let scheduler = RunScheduler(store: store, toolConfig: config, verifier: verifier)
            let board = BoardService(store: store, launcher: scheduler)
            await scheduler.setSystemMover(board)
            self.scheduler = scheduler
            self.board = board

            observe(store: store)
            consumeSchedulerUpdates(scheduler)

            status = "Checking your setup…"
            let preflight = PreflightService(environment: environment, config: config)
            globalChecks = await preflight.globalChecks()

            let analysisService = AnalysisService(
                store: store, launcher: scheduler, board: board, gh: ghClient
            )
            self.analysisService = analysisService
            startIPC(board: board, store: store, analysis: analysisService)

            // Put the board back in touch with reality before anything is
            // dragged: runs died when the app last quit.
            let reconciler = Reconciler(
                store: store, verifier: verifier, mover: board, launcher: scheduler
            )
            let summary = await reconciler.sweep()

            let watcher = PRWatcher(store: store, gh: ghClient, mover: board)
            await watcher.start()
            self.watcher = watcher

            importer = GitHubImportService(store: store, gh: ghClient, board: board)

            await refreshRepoChecks(using: preflight)

            isReady = true
            status = summary == .init()
                ? "Ready."
                : "Ready — recovered \(summary.orphanedRuns) interrupted run(s)."
        } catch {
            status = "Could not start: \(error.localizedDescription)"
        }
    }

    private func startIPC(board: BoardService, store: BoardStore, analysis: AnalysisService) {
        do {
            let token = try IPCServer.loadOrCreateToken(at: StoreLocation.tokenURL)
            let handler = MCPRequestHandler(store: store, board: board, analysis: analysis)
            let server = IPCServer(
                socketPath: StoreLocation.socketURL.path,
                token: token
            ) { request in
                await handler.handle(request)
            }
            try server.start()
            ipcServer = server
        } catch {
            // The board still works; only the MCP side is unavailable.
            globalChecks.append(CheckResult(
                id: "mcp.socket", title: "MCP socket", status: .warn,
                detail: error.localizedDescription,
                fixHint: "Quit any other running Elliot."
            ))
        }
    }

    public func shutdown() async {
        observationTasks.forEach { $0.cancel() }
        proposalObservation?.cancel()
        await watcher?.stop()
        ipcServer?.stop()
    }

    // MARK: - Observation

    private func observe(store: BoardStore) {
        let cardObservation = store.observeCards()
        observationTasks.append(Task { [weak self] in
            do {
                for try await cards in cardObservation {
                    await MainActor.run { self?.cards = cards }
                    await self?.refreshActiveRuns()
                }
            } catch {
                await MainActor.run { self?.status = "Lost track of the board: \(error.localizedDescription)" }
            }
        })

        let repoObservation = store.observeRepos()
        observationTasks.append(Task { [weak self] in
            do {
                for try await repos in repoObservation {
                    await MainActor.run {
                        self?.repos = repos
                        if self?.selectedRepoID == nil { self?.selectedRepoID = repos.first?.id }
                    }
                }
            } catch {
                // Repos change rarely; a dropped observation is not worth a
                // banner of its own.
            }
        })
    }

    private func consumeSchedulerUpdates(_ scheduler: RunScheduler) {
        observationTasks.append(Task { [weak self] in
            for await update in scheduler.updates {
                guard let self else { return }
                await MainActor.run { self.apply(update) }
            }
        })
    }

    private func apply(_ update: SchedulerUpdate) {
        switch update {
        case .runStarted(let runID, _):
            liveLog[runID] = ["▸ started"]
            Task {
                await self.refreshActiveRuns()
                await self.refreshAnalysisRuns()
            }
        case .runOutput(let runID, let event):
            var lines = liveLog[runID] ?? []
            if let rendered = Self.describe(event) {
                lines.append(rendered)
                // The file on disk keeps everything; this is just the tail.
                if lines.count > 300 { lines.removeFirst(lines.count - 300) }
                liveLog[runID] = lines
            }
        case .runStalled(let runID, let since):
            var lines = liveLog[runID] ?? []
            lines.append("⏳ no output since \(since.formatted(date: .omitted, time: .standard))")
            liveLog[runID] = lines
        case .runFinished(let runID, let cardID, let state, _):
            var lines = liveLog[runID] ?? []
            lines.append("■ \(state.rawValue)")
            liveLog[runID] = lines
            // `cardID` is nil for an analysis run: it belongs to a repository,
            // not to a card.
            if let cardID { Task { await self.refreshRuns(cardID: cardID) } }
            Task {
                await self.refreshActiveRuns()
                await self.refreshAnalysisRuns()
            }
        }
    }

    static func describe(_ event: StreamEvent) -> String? {
        switch event {
        case .systemInit(let info):
            "▸ \(info.model ?? "claude") in \(info.cwd ?? "?")"
        case .assistantText(let text):
            text.split(separator: "\n").first.map(String.init)
        case .assistantToolUse(let name, _, let preview):
            "⚙ \(name) \(preview.prefix(120))"
        case .toolResult(_, let isError, let preview):
            isError ? "✗ \(preview.prefix(120))" : nil
        case .result(let result):
            "■ \(result.isClean ? "done" : "finished with issues") — \(result.text?.prefix(200) ?? "")"
        case .system, .partial, .unknown, .malformed:
            nil
        }
    }

    // MARK: - Board actions

    public func cards(in column: ElliotModel.Column) -> [Card] {
        cards
            .filter { $0.column == column && (selectedRepoID == nil || $0.repoID == selectedRepoID) }
            .sorted { $0.orderIndex < $1.orderIndex }
    }

    public func repo(for card: Card) -> Repo? {
        repos.first { $0.id == card.repoID }
    }

    public func card(id: UUID?) -> Card? {
        guard let id else { return nil }
        return cards.first { $0.id == id }
    }

    public var selectedCard: Card? { card(id: selectedCardID) }

    /// What moving this card to that column *would* do, decided now, without
    /// touching the database.
    ///
    /// This is the same `evaluateMove` `BoardService` commits with, so the
    /// caption a column shows and the thing that actually happens cannot come
    /// apart. Pure by design — the rule engine takes no clock and no I/O
    /// precisely so a view can ask it during layout.
    public func preview(_ card: Card, to column: ElliotModel.Column) -> MoveOutcome {
        evaluateMove(
            from: card.column,
            to: column,
            card: card,
            context: MoveContext(
                repoIsEnabled: repo(for: card)?.isEnabled ?? false,
                activeRunID: activeRuns[card.id]?.id,
                allowSideEffects: true,
                // Left uncollected on purpose: the merge really does stop to
                // ask, and the caption says so.
                providedFollowUps: nil
            )
        )
    }

    /// A drag. Goes through exactly the same two calls the MCP tool uses.
    public func move(cardID: UUID, to column: ElliotModel.Column) async {
        guard let board else { return }
        do {
            let result = try await board.move(cardID: cardID, to: column, origin: .userDrag)
            switch result {
            case .moved(let runID):
                refusal = nil
                status = runID == nil ? "Moved." : "Started a run."
                await refreshActiveRuns()
            case .needsInput(.followUps(let pr)):
                refusal = nil
                pendingFollowUps = PendingMerge(cardID: cardID, prNumber: pr)
            case .blocked(let block):
                // Shown on the card, not only in the status bar: the reason a
                // gesture did nothing belongs where the gesture was made.
                refusal = Refusal(cardID: cardID, message: Self.explain(block))
                status = Self.explain(block)
            }
        } catch {
            refusal = Refusal(cardID: cardID, message: error.localizedDescription)
            status = error.localizedDescription
        }
    }

    /// Move the selected card one column along without a mouse.
    ///
    /// The board is a drag surface, but dragging is not the only way to mean
    /// "advance this": it is slow for a card three columns away, and it is the
    /// only path for someone who cannot drag at all.
    public func nudgeSelection(forward: Bool) async {
        guard let card = selectedCard else { return }
        let order = ElliotModel.Column.allCases
        guard let index = order.firstIndex(of: card.column) else { return }
        let target = index + (forward ? 1 : -1)
        guard order.indices.contains(target) else { return }
        await move(cardID: card.id, to: order[target])
    }

    /// Drop a card between two of its new neighbours.
    ///
    /// `orderIndex` is a `Double` so an insert is `(prev + next) / 2` rather
    /// than a renumbering — the store has always supported this, and the board
    /// simply never offered it.
    public func reorder(cardID: UUID, in column: ElliotModel.Column, above target: Card?) async {
        guard let board, let moving = card(id: cardID) else { return }
        let ordered = cards(in: column).filter { $0.id != cardID }

        let index = target.flatMap { t in ordered.firstIndex { $0.id == t.id } } ?? ordered.count
        let previous = index > 0 ? ordered[index - 1].orderIndex : nil
        let next = index < ordered.count ? ordered[index].orderIndex : nil

        do {
            if moving.column != column {
                // Crossing columns is a move first — it may file an issue or
                // merge a pull request — and only then a placement.
                await move(cardID: cardID, to: column)
                guard refusal == nil, card(id: cardID)?.column == column else { return }
            }
            try await board.reorder(cardID: cardID, between: previous, and: next)
        } catch {
            status = error.localizedDescription
        }
    }

    public func confirmMerge(cardID: UUID, followUps: [String]) async {
        guard let board else { return }
        pendingFollowUps = nil
        do {
            let result = try await board.move(
                cardID: cardID, to: .done, origin: .userDrag, followUps: followUps
            )
            if case .blocked(let block) = result { status = Self.explain(block) }
        } catch {
            status = error.localizedDescription
        }
    }

    /// One sentence per refusal, written once.
    ///
    /// This used to be a second switch with its own wording, so a repository
    /// switched off was "disabled; see Preflight" on the card and "switched off
    /// in Preflight" in the column caption — the same refusal, named two ways,
    /// in one window.
    static func explain(_ block: MoveBlock) -> String {
        Consequence.reason(block)
    }

    public func createCard(
        repoID: UUID, title: String, story: UserStory?, body: String
    ) async {
        guard let board else { return }
        _ = try? await board.createCard(repoID: repoID, title: title, body: body, story: story)
    }

    public func deleteCard(id: UUID) async {
        try? await board?.deleteCard(id: id)
    }

    /// Unlike `createCard` / `deleteCard`, this reports failure: the sheet that
    /// called it still holds the text the user typed, and silently dropping an
    /// edit is worse than saying it was refused.
    public func updateCard(id: UUID, draft: CardDraft) async -> Bool {
        guard let board else {
            // The sheet shows `status` as the reason it refused; leaving the
            // previous one there would blame the wrong thing.
            status = "The board is not ready yet; the edit was not saved."
            return false
        }
        do {
            try await board.updateCard(
                id: id, title: draft.title, body: draft.body, story: draft.story
            )
            return true
        } catch {
            status = error.localizedDescription
            return false
        }
    }

    public func cancelRun(id: UUID) async {
        await board?.cancelRun(id: id)
    }

    public func refreshRuns(cardID: UUID) async {
        runsByCard[cardID] = (try? await store?.runs(cardID: cardID, limit: 20)) ?? []
    }

    /// One query for the whole board rather than one per card.
    public func refreshActiveRuns() async {
        guard let store else { return }
        let ids = cards.map(\.id)
        guard !ids.isEmpty else {
            activeRuns = [:]
            return
        }
        activeRuns = (try? await store.activeRuns(cardIDs: ids)) ?? [:]
    }

    // MARK: - Repos

    public func addRepo(path: String) async {
        guard let store, let toolConfig else { return }
        let gh = GHClient(config: toolConfig)
        let info = try? await gh.repoInfo(cwd: path)
        let repo = Repo(
            path: path,
            nameWithOwner: info?.nameWithOwner ?? URL(fileURLWithPath: path).lastPathComponent,
            defaultBranch: info?.defaultBranch ?? "main",
            displayName: URL(fileURLWithPath: path).lastPathComponent
        )
        try? await store.saveRepo(repo)
        selectedRepoID = repo.id
        await refreshRepoChecks()
        await importIfNeeded(repoID: repo.id)
    }

    // MARK: - GitHub import

    /// The Refresh button. Imports the selected repository, or every enabled one
    /// when "All repositories" is chosen.
    public func refreshFromGitHub() async {
        guard let importer, !isImporting else { return }
        let targets = selectedRepoID.flatMap { id in repos.filter { $0.id == id } } ?? repos
        guard !targets.isEmpty else { return }

        isImporting = true
        status = targets.count == 1
            ? "Refreshing \(targets[0].displayName) from GitHub…"
            : "Refreshing \(targets.count) repositories from GitHub…"

        let summaries = await importer.importAll(targets)
        targets.forEach { importedThisSession.insert($0.id) }
        isImporting = false
        status = summaries.map(\.sentence).joined(separator: "   ")
    }

    /// The first time a repository is shown, bring in what GitHub already knows.
    /// Once per repository per session — the button covers the rest.
    public func importIfNeeded(repoID: UUID?) async {
        guard let repoID, !importedThisSession.contains(repoID), !isImporting,
              let repo = repos.first(where: { $0.id == repoID }), repo.isEnabled,
              let importer
        else { return }

        importedThisSession.insert(repoID)
        isImporting = true
        let summary = await importer.importRepo(repo)
        isImporting = false
        status = summary.sentence
    }

    /// Undoes every dismissal for the repositories in view, so the next refresh
    /// brings back what was deleted.
    public func clearDismissals() async {
        guard let store else { return }
        let targets = selectedRepoID.flatMap { id in repos.filter { $0.id == id } } ?? repos
        for repo in targets {
            try? await store.clearDismissals(repoID: repo.id)
            importedThisSession.remove(repo.id)
        }
        status = "Dismissed items forgotten — refresh to bring them back."
    }

    public func setRepoEnabled(_ repo: Repo, enabled: Bool) async {
        var repo = repo
        repo.isEnabled = enabled
        try? await store?.saveRepo(repo)
    }

    public func removeRepo(id: UUID) async {
        try? await store?.deleteRepo(id: id)
    }

    public func refreshRepoChecks(using service: PreflightService? = nil) async {
        guard let toolConfig else { return }
        let environment = LoginShellEnvironment(
            variables: toolConfig.environment, capturedVia: "session"
        )
        let preflight = service ?? PreflightService(environment: environment, config: toolConfig)
        for repo in repos {
            repoChecks[repo.id] = await preflight.repoChecks(repo)
        }
    }

    public func isBlocked(_ repo: Repo) -> Bool {
        PreflightService.isBlocking(repoChecks[repo.id] ?? [])
    }

    // MARK: - Analysis

    public func startAnalysis(
        repoID: UUID, angles: [AnalysisAngle], instructions: String, maxStories: Int
    ) async {
        guard let analysisService else { return }
        do {
            let started = try await analysisService.start(
                repoID: repoID, angles: angles, extraInstructions: instructions,
                maxStoriesPerAngle: maxStories, origin: .manual
            )
            analysisNote = nil
            openAnalysis(id: started.analysis.id)
        } catch {
            analysisNote = error.localizedDescription
        }
    }

    public func openAnalysis(id: UUID) {
        activeAnalysisID = id
        proposals = []
        analysisRuns = []
        Task { await refreshAnalysisRuns() }

        // Proposals arrive run by run, so the list fills in as each angle
        // lands rather than all at once when the last one does.
        proposalObservation?.cancel()
        guard let store else { return }
        let observation = store.observeProposals(analysisID: id)
        proposalObservation = Task { [weak self] in
            do {
                for try await proposals in observation {
                    await MainActor.run { self?.proposals = proposals }
                }
            } catch {
                await MainActor.run { self?.analysisNote = error.localizedDescription }
            }
        }
    }

    public func closeAnalysis() {
        proposalObservation?.cancel()
        proposalObservation = nil
        activeAnalysisID = nil
        analysisRuns = []
        proposals = []
        analysisNote = nil
    }

    public func refreshAnalysisRuns() async {
        guard let store, let id = activeAnalysisID else { return }
        analysisRuns = (try? await store.runs(analysisID: id)) ?? []
    }

    public func recentAnalyses() async -> [Analysis] {
        guard let store else { return [] }
        return (try? await store.analyses(repoID: selectedRepoID, limit: 20)) ?? []
    }

    public func updateProposal(_ proposal: StoryProposal) async {
        try? await analysisService?.updateProposal(proposal)
    }

    public func acceptProposals(ids: [UUID]) async {
        guard let analysisService else { return }
        do {
            let cards = try await analysisService.accept(proposalIDs: ids)
            analysisNote = cards.isEmpty
                ? "Nothing to accept — those were already decided."
                : "Added \(cards.count == 1 ? "1 card" : "\(cards.count) cards") to Backlog. Nothing was filed on GitHub."
        } catch {
            analysisNote = error.localizedDescription
        }
    }

    public func rejectProposals(ids: [UUID]) async {
        try? await analysisService?.reject(proposalIDs: ids)
        analysisNote = ids.count == 1 ? "Rejected 1 proposal." : "Rejected \(ids.count) proposals."
    }

    /// The angles still working, for the window's header.
    public var runningAngles: [AnalysisAngle] {
        analysisRuns.filter { !$0.state.isTerminal }.compactMap(\.analysisAngle)
    }

    /// The command that registers the bundled helper with Claude Code.
    public static var mcpRegistrationCommand: String {
        let helper = Bundle.main.bundleURL
            .appendingPathComponent("Contents/MacOS/elliot-mcp").path
        return "claude mcp add elliot -s user -- \(helper)"
    }
}
