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

    /// Live tail per run, for the card's log view. Bounded — the file on disk
    /// is the complete record.
    public private(set) var liveLog: [UUID: [String]] = [:]

    public var selectedRepoID: UUID?
    public var selectedCardID: UUID?
    public var pendingFollowUps: PendingMerge?

    public struct PendingMerge: Identifiable, Sendable {
        public var id: UUID { cardID }
        public var cardID: UUID
        public var prNumber: Int
    }

    private var store: BoardStore?
    private var board: BoardService?
    private var scheduler: RunScheduler?
    private var watcher: PRWatcher?
    private var ipcServer: IPCServer?
    private var toolConfig: ToolConfig?
    private var observationTasks: [Task<Void, Never>] = []

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

            startIPC(board: board, store: store)

            // Put the board back in touch with reality before anything is
            // dragged: runs died when the app last quit.
            let reconciler = Reconciler(
                store: store, verifier: verifier, mover: board, launcher: scheduler
            )
            let summary = await reconciler.sweep()

            let watcher = PRWatcher(store: store, gh: ghClient, mover: board)
            await watcher.start()
            self.watcher = watcher

            await refreshRepoChecks(using: preflight)

            isReady = true
            status = summary == .init()
                ? "Ready."
                : "Ready — recovered \(summary.orphanedRuns) interrupted run(s)."
        } catch {
            status = "Could not start: \(error.localizedDescription)"
        }
    }

    private func startIPC(board: BoardService, store: BoardStore) {
        do {
            let token = try IPCServer.loadOrCreateToken(at: StoreLocation.tokenURL)
            let handler = MCPRequestHandler(store: store, board: board)
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
            if let cardID { Task { await self.refreshRuns(cardID: cardID) } }
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

    /// A drag. Goes through exactly the same two calls the MCP tool uses.
    public func move(cardID: UUID, to column: ElliotModel.Column) async {
        guard let board else { return }
        do {
            let result = try await board.move(cardID: cardID, to: column, origin: .userDrag)
            switch result {
            case .moved(let runID):
                status = runID == nil ? "Moved." : "Started a run."
            case .needsInput(.followUps(let pr)):
                pendingFollowUps = PendingMerge(cardID: cardID, prNumber: pr)
            case .blocked(let block):
                status = Self.explain(block)
            }
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

    static func explain(_ block: MoveBlock) -> String {
        switch block {
        case .sameColumn: "That card is already there."
        case .emptyIdea: "This card has nothing in it to file as an issue."
        case .incompleteStory: "The story is missing one of role, want or benefit."
        case .missingIssueNumber: "No issue yet — move it Backlog → To Do first."
        case .missingPRNumber: "No pull request yet — move it To Do → In Progress first."
        case .repoDisabled: "This repository is disabled; see Preflight."
        case .runAlreadyInFlight: "A run is already working on this card."
        }
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

    public func cancelRun(id: UUID) async {
        await board?.cancelRun(id: id)
    }

    public func refreshRuns(cardID: UUID) async {
        runsByCard[cardID] = (try? await store?.runs(cardID: cardID, limit: 20)) ?? []
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

    /// The command that registers the bundled helper with Claude Code.
    public static var mcpRegistrationCommand: String {
        let helper = Bundle.main.bundleURL
            .appendingPathComponent("Contents/MacOS/elliot-mcp").path
        return "claude mcp add elliot -s user -- \(helper)"
    }
}
