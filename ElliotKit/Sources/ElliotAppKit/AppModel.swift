import AppKit
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

    /// How many runs may go at once, and how many are going.
    ///
    /// `occupancy` is refreshed from the scheduler on every run update rather
    /// than polled: a stepper reading "4" says nothing without "2 in flight"
    /// beside it, and a number that lags is worse than no number.
    public private(set) var limits: SchedulerLimits = .default
    public private(set) var occupancy: (writers: Int, analyses: Int) = (0, 0)

    /// The most Elliot may spend, and what it has spent today.
    ///
    /// `isOverDailyCeiling` is held rather than derived in a view: a queue that
    /// sits still with no reason given reads as a broken scheduler, and this is
    /// the one refusal a user cannot deduce from the board.
    /// The runs waiting to start, in the order the scheduler will consider
    /// them, each carrying the rule holding it. Pushed by the scheduler on every
    /// drain — nothing polls.
    public private(set) var queue: [QueuedRun] = []

    /// The most recent runs across the whole board, independent of what is
    /// selected. `runsByCard` is loaded per selected card and is right to be —
    /// this is the shallower path an overview needs.
    public private(set) var recentRuns: [SkillRun] = []
    public private(set) var isQueuePaused = false

    public private(set) var ceiling: SpendCeiling = .off
    public private(set) var spentToday: Spend = .nothing
    public private(set) var isOverDailyCeiling = false

    /// One row per repository of the configured owners: GitHub's list, the disk
    /// and the store, reconciled. The judgement is `RepoReconciler`'s — the page
    /// renders it and never decides anything itself.
    public private(set) var repoRows: [RepoRow] = []
    public private(set) var layout: RepoTreeLayout = .portfolio
    public private(set) var isReconciling = false

    /// Whether the repository observation has delivered once.
    ///
    /// Distinct from `isReady`, which waits on the shell capture, three tool
    /// lookups and a preflight sweep. Without it the board asserted "No
    /// repository yet" for the whole of startup, to a user whose repositories
    /// were sitting in the database the entire time.
    public private(set) var hasLoadedRepos = false

    /// Sheet and inspector state, here rather than in a view, because a menu
    /// command cannot reach a view's `@State`.
    ///
    /// Analysis is deliberately absent: it is a `Window` scene now, so its
    /// presentation is `openWindow`'s business and there is no flag to keep in
    /// step with it.
    public var showingInspector = true

    /// How many board columns wide the detail panel is.
    ///
    /// A **reader preference**, not a function of the window: the panel is
    /// measured in columns (`PanelLayout.panelWidth`) so that it reads as being
    /// *of* the column it came from, and how much of the board a reader is
    /// willing to give up for it is their call, not the window's.
    ///
    /// 3 is the mockup's two-pane body — the issue and the runs side by side. At
    /// 2 only one pane fits and a segmented switch appears to choose it; the
    /// merge confirmation stays in the header at both, where no switch can hide
    /// it.
    public var panelSpans = 3

    /// Which rows of a run log the panel is showing.
    ///
    /// One filter for the pane rather than one per run box: it is a reading
    /// mode — "show me only what failed" — and a reader who sets it on the run
    /// they are looking at means it for the card, not for that box. It lives on
    /// the model rather than in `@State` for the ordinary reason: a `@State` in
    /// a run box is reset every time the selection changes, so the choice would
    /// not survive clicking the next card.
    public var logFilter: RunLogFilter = .all

    /// Which repository a new story will be filed against.
    ///
    /// Here rather than passed in, because `NewCardWindow` is a `Window` scene
    /// and a scene cannot be handed a parameter the way a sheet's closure can.
    /// Set at the moment the window is opened, so it captures the repository
    /// that was selected then rather than following the picker afterwards.
    public var newCardRepoID: UUID?

    /// The repository a new story should default to: the one in the picker, or
    /// the first, when "All repositories" is chosen.
    public var defaultRepoIDForNewCard: UUID? { selectedRepoID ?? repos.first?.id }

    /// The analysis the window is showing. `nil` means it is still in setup.
    public private(set) var activeAnalysisID: UUID?
    public private(set) var analysisRuns: [SkillRun] = []
    public private(set) var proposals: [StoryProposal] = []
    /// Whatever the window needs to say about the last action.
    public private(set) var analysisNote: String?

    /// Live tail per run, for the card's strip and the panel's log. Bounded —
    /// the file on disk is the complete record.
    ///
    /// Events rather than rendered lines. Collapsing to `String` here threw
    /// away the tool-use id a result has to be nested under, the whole of an
    /// agent turn after its first line, and every successful tool call — and it
    /// threw them away in the model, before any view could ask for them.
    public private(set) var liveLog: [UUID: [StreamEvent]] = [:]

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

    /// The card that most recently landed somewhere, so the board can scroll to
    /// it.
    ///
    /// The stamp is load-bearing: a bare `UUID?` would not fire `onChange` when
    /// the same card lands twice in a row, which is the ordinary case of
    /// walking one card across the board.
    public struct Landing: Equatable, Sendable {
        public var cardID: UUID
        public var stamp: UUID
    }

    public private(set) var lastLanded: Landing?

    /// What the last repository fix actually did.
    ///
    /// Its sentence used to go to `status`, which lives in the board's status
    /// bar — a different window from the button that was pressed. A fix that
    /// failed quietly read exactly like one that worked.
    public struct FixOutcome: Equatable, Sendable {
        public var detail: String
        public var succeeded: Bool
    }

    public private(set) var lastFixOutcome: FixOutcome?

    /// What the last sweep did, and every repository it left out with the reason.
    /// Nil until Sync has run once, and cleared by a plain Refresh.
    public private(set) var lastSyncSummary: SyncSummary?

    /// The most recent audited move per card, so the inspector can say who made
    /// it. `BoardStore.audits` had no non-test caller before this.
    public private(set) var lastMove: [UUID: MoveAudit] = [:]

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
    private var registry: RepoRegistryService?
    private var ipcServer: IPCServer?
    private var toolConfig: ToolConfig?
    private var analysisService: AnalysisService?
    private var observationTasks: [Task<Void, Never>] = []
    private var proposalObservation: Task<Void, Never>?

    public init() {}

    // MARK: - Startup

    public func start() async {
        // A window rebuild must not start a second engine. Without this a
        // reopen re-registers the observations, re-`start()`s `IPCServer` on
        // the same socket, overwrites `watcher` without stopping the first
        // `PRWatcher`, and runs a second concurrent `Reconciler.sweep()` — in a
        // process whose whole design rests on being the sole writer.
        guard store == nil else { return }
        do {
            try StoreLocation.ensureDirectories()
            let store = try BoardStore.open()
            self.store = store

            // Before the shell capture, not after: observing needs only the
            // store, and everything below it takes seconds. The board used to
            // assert "No repository yet" through all of it.
            observe(store: store)

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
            // Read before the scheduler is built, not applied to it afterwards:
            // the launch sweep further down admits runs that died with the app,
            // and it must do so under the caps the user chose rather than under
            // the defaults for the moment it takes to override them.
            limits = (try? await store.limits()) ?? .default
            ceiling = (try? await store.spendCeiling()) ?? .off
            let scheduler = RunScheduler(
                store: store, toolConfig: config, verifier: verifier,
                limits: limits, ceiling: ceiling
            )
            let board = BoardService(store: store, launcher: scheduler)
            await scheduler.setSystemMover(board)
            self.scheduler = scheduler
            self.board = board

            consumeSchedulerUpdates(scheduler)

            // Loaded before preflight runs: the tree-root check reports on the
            // configured root, and `.portfolio` is only the default for a store
            // that has never been told otherwise.
            layout = (try? await store.layout()) ?? .portfolio
            registry = RepoRegistryService(store: store, config: config)

            status = "Checking your setup…"
            let preflight = PreflightService(environment: environment, config: config)
            globalChecks = await preflight.globalChecks(layout: layout)

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

            // Once at startup. These are otherwise only refreshed when a run
            // reports, so a board that has not run anything since launch would
            // show an empty queue and $0.00 spent — indistinguishable from a
            // board that has genuinely spent nothing, and wrong on any store
            // with history in it.
            await refreshOccupancy()

            isReady = true
            status = summary == .init()
                ? "Ready."
                : "Ready — recovered \(summary.orphanedRuns == 1 ? "1 interrupted run" : "\(summary.orphanedRuns) interrupted runs")."
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
            ) { request, client in
                await handler.handle(request, client: client)
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
                        // Set on every delivery, including an empty one: an
                        // empty store is a loaded store, and the board's real
                        // empty state must be reachable.
                        self?.hasLoadedRepos = true
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

    /// Internal rather than private: the 300-entry cap below, and the
    /// accumulation it bounds, are unreachable from a test otherwise — and that
    /// cap is the only thing between a run that talks for an hour and an
    /// unbounded array held in memory.
    func apply(_ update: SchedulerUpdate) {
        switch update {
        case .queueChanged(let queue):
            self.queue = queue
        case .runStarted(let runID, _):
            // Emptied rather than seeded with a line: the tail carries events
            // now, and "started" is not one. `RunningStrip` and `RunRow` both
            // already show the run's state from the run itself.
            liveLog[runID] = []
            Task {
                await self.refreshActiveRuns()
                await self.refreshAnalysisRuns()
                await self.refreshOccupancy()
            }
        case .runOutput(let runID, let event):
            var events = liveLog[runID] ?? []
            events.append(event)
            // The file on disk keeps everything; this is just the tail. The
            // oldest go, never the newest — a tail that dropped its own end
            // would stop following the run.
            if events.count > 300 { events.removeFirst(events.count - 300) }
            liveLog[runID] = events
        case .runStalled(let runID, _):
            // This used to `break`, on the reasoning that `markStalled` had
            // already written `.stalled` to the store and `RunningStrip` reads
            // it off `run.state`. Both halves are true and the conclusion is
            // not: **nothing re-reads a run row on its own.** The store held
            // `.stalled` and every copy the screen draws from — `activeRuns`,
            // `recentRuns`, `runsByCard`, `analysisRuns` — went on holding
            // `.running`, so the card kept its spinner and "No output for a
            // while" was drawn by nobody.
            //
            // That is not cosmetic. There is deliberately no wall-clock kill,
            // because `merge-pr` waiting hours on CI is legitimate, so silence
            // is the *only* signal a wedged run gives. Losing it leaves nothing
            // at all between a run that is thinking and one that is stuck.
            //
            // Marked in place rather than re-read, and that is not an
            // optimisation: the scheduler yields this update *before* it awaits
            // `markStalled`, so a refresh racing it reads the row as it was and
            // writes `.running` back over the answer. The guard below is
            // `markStalled`'s own, so the two cannot disagree about which runs
            // may stall.
            markStalled(runID: runID)
        case .runFinished(_, let cardID, _, _):
            // A run takes minutes and nobody watches it for all of them. One
            // Dock bounce, only when Elliot is not the front app — no
            // notification permission, and nothing to dismiss.
            if !NSApp.isActive { NSApp.requestUserAttention(.informationalRequest) }
            // `cardID` is nil for an analysis run: it belongs to a repository,
            // not to a card.
            if let cardID { Task { await self.refreshRuns(cardID: cardID) } }
            Task {
                await self.refreshActiveRuns()
                await self.refreshAnalysisRuns()
                await self.refreshOccupancy()
            }
        }
    }

    /// Marks one run stalled in every copy the screen draws from.
    ///
    /// Four collections hold runs and any of them can be the one on screen:
    /// `activeRuns` feeds the card's `RunningStrip`, `runsByCard` the selected
    /// card's Runs pane, `recentRuns` the overview, `analysisRuns` the analysis
    /// window. Marking three of four is a stall that shows on some screens and
    /// not others, which is worse than one that shows nowhere — so this walks
    /// all four, through one function.
    func markStalled(runID: UUID) {
        activeRuns = activeRuns.mapValues { Self.stalling(runID, $0) }
        recentRuns = recentRuns.map { Self.stalling(runID, $0) }
        runsByCard = runsByCard.mapValues { runs in runs.map { Self.stalling(runID, $0) } }
        analysisRuns = analysisRuns.map { Self.stalling(runID, $0) }
    }

    /// The rule itself: **only a run that is still running can stall.**
    ///
    /// Pure and static so `swift test` can hold it, and written once rather than
    /// four times. The guard is `RunScheduler.markStalled`'s, deliberately
    /// spelled the same way: a run that finished between the idle watcher
    /// noticing the silence and this arriving must keep the outcome it reached,
    /// not be dragged back to a non-terminal state by a late notice.
    static func stalling(_ runID: UUID, _ run: SkillRun) -> SkillRun {
        guard run.id == runID, run.state == .running else { return run }
        var stalled = run
        stalled.state = .stalled
        return stalled
    }

    /// One event collapsed to one line, for `CardView`'s running strip and
    /// nowhere else.
    ///
    /// A card shows a single line of a run in flight, so a collapse is the
    /// right answer *there* — it is the wrong answer everywhere a log is read,
    /// which is why the panel folds `liveLog` into `RunLogRow`s instead. Keep
    /// this narrow: widening it back is how the log became a `[String]`.
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

    /// The card's issue body, parsed into blocks — memoised per card, and
    /// invalidated by the body itself rather than by a notification.
    ///
    /// Memoised because this is called during `body` evaluation: re-parsing a
    /// long issue on every render is real work, and this repository's own
    /// issues run to hundreds of lines. Keyed on the body as well as the card
    /// so an edit or a re-import cannot be served a stale parse — the body is
    /// the input, so comparing it is the whole of the cache's correctness.
    func issueDocument(for card: Card) -> IssueDocument {
        if let cached = parsedBodies[card.id], cached.body == card.body { return cached.document }
        let document = IssueMarkdownParser.parse(card.body)
        parsedBodies[card.id] = (body: card.body, document: document)
        return document
    }

    /// `@ObservationIgnored` deliberately: `issueDocument(for:)` runs inside
    /// `body`, and a tracked mutation there would invalidate the very view that
    /// just read it. Nothing observes the cache — the cards do the observing.
    @ObservationIgnored
    private var parsedBodies: [UUID: (body: String, document: IssueDocument)] = [:]

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

    /// Answers a drop synchronously, so a refused drag snaps back instead of
    /// being accepted and then contradicted a round trip later.
    ///
    /// `dropDestination` must return a `Bool` now; `move` is async, so it
    /// returned `true` — "accepted" — for every drop, including the ones it was
    /// about to refuse. The card animated into its new column and then jumped
    /// back with a note on it.
    ///
    /// Nothing new is decided here: the verdict is `evaluateMove`'s, reached
    /// through `preview`, which is the same pure function `BoardService` commits
    /// with.
    public func refuse(cardID: UUID, to column: ElliotModel.Column) -> Bool {
        guard let card = card(id: cardID) else { return true }
        guard case .blocked(let block) = preview(card, to: column) else { return false }
        refusal = Refusal(cardID: cardID, message: Self.explain(block))
        status = Self.explain(block)
        return true
    }

    /// A drag. Goes through exactly the same two calls the MCP tool uses.
    public func move(cardID: UUID, to column: ElliotModel.Column) async {
        guard let board else { return }
        // Captured before the move: by the time `board.move` returns, the
        // card's column and `activeRuns` have both changed, so asking then
        // would describe the world after the act rather than the act.
        let predicted = card(id: cardID).map { Consequence.of(preview($0, to: column)) }
        do {
            let result = try await board.move(cardID: cardID, to: column, origin: .userDrag)
            switch result {
            case .moved(let runID):
                refusal = nil
                lastLanded = Landing(cardID: cardID, stamp: UUID())
                if runID == nil {
                    status = "Moved to \(column.displayName). Nothing ran."
                } else {
                    // The column promised a specific act; say that act is
                    // happening, not that "a run" started.
                    let running = predicted?.running ?? ""
                    status = running.isEmpty ? "Started a run." : running
                }
                await refreshActiveRuns()
            case .needsInput(.followUps(let pr)):
                refusal = nil
                armPendingMerge(cardID: cardID, prNumber: pr)
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

    /// Puts the merge confirmation somewhere the user can actually see it.
    ///
    /// The panel only draws for a selected card and only when it is open, so the
    /// order here is the difference between a confirmation and a merge with
    /// nowhere to confirm it — the one way moving this out of a sheet could fail
    /// *closed*. A drag selects the card on its way past; the Card menu's
    /// Advance and the panel's own Next step button do not, and a sheet did not
    /// care.
    ///
    /// Its own method so `swift test` can prove the three happen together.
    func armPendingMerge(cardID: UUID, prNumber: Int) {
        selectedCardID = cardID
        showingInspector = true
        pendingFollowUps = PendingMerge(cardID: cardID, prNumber: prNumber)
    }

    /// Abandons a merge the user decided against, without moving the card.
    public func cancelPendingMerge() {
        pendingFollowUps = nil
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
        // Read here rather than from a new call site: `CardView.task` and the
        // inspector already call this per card.
        lastMove[cardID] = (try? await store?.audits(cardID: cardID, limit: 1))??.first
    }

    // MARK: - Scheduler limits

    /// Saves the caps and applies them to the running scheduler.
    ///
    /// Saved first: if the write fails the user must not be left with a board
    /// running four workers and a store that will restore two on next launch.
    public func updateLimits(_ new: SchedulerLimits) async {
        guard let store else { return }
        do {
            try await store.saveLimits(new)
        } catch {
            status = "Could not save the run limits: \(error.localizedDescription)"
            return
        }
        limits = new
        await scheduler?.setLimits(new)
        await refreshOccupancy()
    }

    func refreshOccupancy() async {
        guard let scheduler else { return }
        occupancy = await scheduler.occupancy
        isQueuePaused = await scheduler.paused
        await refreshSpend()
        await refreshRecentRuns()
    }

    // MARK: - Queue commands

    /// Pause, resume, empty, or push one run to the front.
    ///
    /// Thin on purpose: every one of these is the scheduler's decision, and a
    /// second copy of the reasoning here is how the board and the engine start
    /// disagreeing about what the queue is doing.
    public func pauseQueue() async {
        await scheduler?.pause()
        await refreshOccupancy()
    }

    public func resumeQueue() async {
        await scheduler?.resume()
        await refreshOccupancy()
    }

    /// Says how many were discarded. A command that empties something must
    /// report what it emptied, or an accidental press is indistinguishable from
    /// a queue that was already empty.
    public func drainQueue() async {
        guard let scheduler else { return }
        let cleared = await scheduler.drain()
        status = cleared == 0
            ? "Nothing was waiting."
            : "Discarded \(cleared == 1 ? "1 queued run" : "\(cleared) queued runs"). Nothing running was stopped."
        await refreshOccupancy()
    }

    public func promoteQueued(runID: UUID) async {
        await scheduler?.promote(runID: runID)
        await refreshOccupancy()
    }

    /// Saves the ceiling and applies it, in that order, for the same reason
    /// `updateLimits` does: a failed write must not leave the running scheduler
    /// enforcing something the store will not restore.
    public func updateCeiling(_ new: SpendCeiling) async {
        guard let store else { return }
        do {
            try await store.saveSpendCeiling(new)
        } catch {
            status = "Could not save the spend ceiling: \(error.localizedDescription)"
            return
        }
        ceiling = new
        await scheduler?.setCeiling(new)
        await refreshSpend()
    }

    func refreshRecentRuns() async {
        guard let store else { return }
        recentRuns = (try? await store.recentRuns(limit: 50)) ?? []
    }

    func refreshSpend() async {
        guard let store, let scheduler else { return }
        spentToday = (try? await store.spend(since: Calendar.current.startOfDay(for: Date())))
            ?? .nothing
        isOverDailyCeiling = await scheduler.isOverDailyCeiling()
    }

    // MARK: - What to do next

    /// What Elliot thinks should happen next, in order.
    ///
    /// The ranking is `rankNextSteps`, the same pure function `board_next`
    /// answers with over MCP. It was written, tested and served to agents while
    /// the human got five columns and had to rebuild the order in their head at
    /// every glance.
    ///
    /// Computed rather than stored: it is derived entirely from `cards`, `repos`
    /// and `activeRuns`, all of which are already observed, and a stored copy is
    /// one more thing that can be stale.
    ///
    /// **No sorting here.** `rankNextSteps` has already ordered them, and a
    /// second sort is a second opinion that will drift from what the MCP tool
    /// answers for the same board.
    public var nextSteps: [NextStep] {
        rankNextSteps(
            nextCandidates(
                cards: cards,
                repos: repos,
                activeRunIDs: activeRuns.mapValues(\.id)
            )
        )
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

    // MARK: - The repository tree

    /// Re-reads GitHub, the disk and the store, and rebuilds every row.
    ///
    /// Whole-list rather than per-row: `clone` and `move` change more than the
    /// row they were clicked on — a clone becomes registered, a move empties one
    /// folder and fills another.
    public func refreshRepoRows() async {
        guard registry != nil, !isReconciling else { return }
        isReconciling = true
        lastFixOutcome = nil
        // The previous sweep's report answers "what did that button just decide
        // not to do?", and an unrelated refresh makes it an answer to a question
        // nobody asked.
        lastSyncSummary = nil
        await reloadRepoRows()
        isReconciling = false
    }

    /// Rebuilds the rows without touching `isReconciling`, so a caller that is
    /// already holding the flag up — the sweep — can refresh without the guard
    /// in `refreshRepoRows()` turning its own refresh into a no-op.
    ///
    /// Both halves run before anything is assigned: the reconcile is quick and
    /// the probe is a fetch per clone, and a page that flashed a flat `ok` for
    /// every repository before refining it would be asserting the exact thing
    /// this feature exists to disprove.
    private func reloadRepoRows() async {
        guard let registry else { return }
        let reconciled = await registry.rows(layout: layout)
        repoRows = await registry.probe(reconciled)
    }

    /// Fast-forwards every clone the probe found strictly behind, and keeps the
    /// account of what it refused.
    ///
    /// It sweeps the rows on screen rather than re-probing first, so what the
    /// user was looking at is what gets swept.
    public func syncAll() async {
        guard let registry, !isReconciling else { return }
        isReconciling = true
        lastFixOutcome = nil
        let summary = await registry.syncAll(rows: repoRows)
        lastSyncSummary = summary
        status = summary.sentence
        // Re-read rather than trusting the sweep's own account of itself: the
        // verdicts on screen have to come from git.
        await reloadRepoRows()
        isReconciling = false
    }

    /// Applies exactly one fix, and says what happened either way.
    ///
    /// The outcome's sentence reaches `status` on success *and* on failure: a
    /// fix that failed quietly reads exactly like one that worked, which is the
    /// failure mode this page exists to remove.
    public func apply(_ fix: RepoFix) async {
        guard let registry else { return }
        let outcome = await registry.apply(fix, layout: layout)
        status = outcome.detail
        await refreshRepoRows()
        // After the refresh, which clears it: this is the sentence the page
        // itself shows, and `status` is on a different screen.
        lastFixOutcome = FixOutcome(detail: outcome.detail, succeeded: outcome.succeeded)
    }

    public func setRepositoriesRoot(_ path: String) async {
        guard let store else { return }
        let updated = RepoTreeLayout(root: path, owners: layout.owners)
        do {
            try await store.saveLayout(updated)
        } catch {
            status = error.localizedDescription
            return
        }
        layout = updated
        // Only the tree-root entry is recomputed. It is a pure filesystem check,
        // where `refreshRepoChecks()` is five subprocesses per repository.
        let check = PreflightService.repositoriesRootCheck(updated)
        if let index = globalChecks.firstIndex(where: { $0.id == check.id }) {
            globalChecks[index] = check
        }
        status = "Repository tree root is now \(updated.root)."
        await refreshRepoRows()
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
        // Cleared before the await, not after: replacing one sentence with
        // another in place reads as nothing having happened.
        analysisNote = nil
        do {
            let cards = try await analysisService.accept(proposalIDs: ids)
            analysisNote = cards.isEmpty
                ? "Nothing to accept — those were already decided."
                : "Accepted \(cards.count == 1 ? "1 story" : "\(cards.count) stories") — waiting in Backlog. Nothing was filed on GitHub."
        } catch {
            analysisNote = error.localizedDescription
        }
    }

    public func rejectProposals(ids: [UUID]) async {
        analysisNote = nil
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

    /// Puts rows in front of the model without a database behind them.
    ///
    /// `start()` opens the store, captures the login shell, runs three tool
    /// lookups and sweeps preflight; none of that is what a test of `cards(in:)`
    /// or `preview` is about, and a test that needed it would not be a unit
    /// test. Deliberately leaves `board` nil, so anything that tries to *write*
    /// from a seeded model returns rather than reaching a store that is not
    /// there — the reason `nudgeSelection` at the end of the board is worth a
    /// test of its own.
    func testOnlySeed(repos: [Repo], cards: [Card]) {
        self.repos = repos
        self.cards = cards
        hasLoadedRepos = true
        selectedRepoID = nil
    }

    /// The same trick for the four collections that hold runs.
    ///
    /// They are `private(set)` because the store fills them, and a stall has to
    /// be provable without one: the scheduler yields `.runStalled` *before* it
    /// writes `.stalled`, so a refresh is exactly the wrong way to learn about
    /// it and a test that stood a database up would be testing the race rather
    /// than the rule.
    func testOnlySeedRuns(
        active: [UUID: SkillRun] = [:],
        byCard: [UUID: [SkillRun]] = [:],
        recent: [SkillRun] = [],
        analysis: [SkillRun] = []
    ) {
        activeRuns = active
        runsByCard = byCard
        recentRuns = recent
        analysisRuns = analysis
    }
}
