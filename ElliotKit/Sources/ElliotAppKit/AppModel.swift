import AppKit
import ElliotEngine
import ElliotIPC
import ElliotModel
import ElliotProcess
import ElliotStore
import Foundation
import OSLog
import Observation

/// The app's root object: it wires the store, the engine and the MCP socket
/// together, and is the only thing the views talk to.
@MainActor
@Observable
public final class AppModel {
    /// Where a failure goes when nobody is looking at the window.
    ///
    /// One subsystem for the app, so a bug report can be asked for
    /// `log show --predicate 'subsystem == "dev.phmatray.elliot"'` and get
    /// everything rather than a category someone has to guess.
    nonisolated static let log = Logger(subsystem: "dev.phmatray.elliot", category: "AppModel")

    public private(set) var repos: [Repo] = []
    public private(set) var cards: [Card] = []
    /// The latest pull request reading per card, for cards in In Review.
    public private(set) var prStatuses: [UUID: PRStatus] = [:]
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

    /// The owners `gh repo list` never answered for, from the same pass that
    /// produced `repoRows` (#148).
    ///
    /// Assigned beside the rows and nowhere else: the banner and the rows have
    /// to describe one refresh. A failure surviving into a later pass would be a
    /// second way of saying something nobody measured, which is the defect this
    /// carries the answer to rather than a place to reintroduce it.
    public private(set) var repoListingFailures: [OwnerListingFailure] = []

    /// What is on each repository's board, from the same pass that produced
    /// `repoRows`. Keyed by `Repo.id`; a repository the store never mentioned is
    /// absent, which `RepoBoardDigest` turns into `.empty` for the rows entitled
    /// to figures at all.
    ///
    /// It holds no refresh failure: that is session state, it arrives on a
    /// different clock, and it is joined in by `repoBoardRows` at read time.
    public private(set) var repoTallies: [UUID: RepoBoardTally] = [:]
    public private(set) var layout: RepoTreeLayout = .portfolio
    public private(set) var isReconciling = false

    /// Whether the repository observation has delivered once.
    ///
    /// Distinct from `isReady`, which waits on the shell capture, three tool
    /// lookups and a preflight sweep. Without it the board asserted "No
    /// repository yet" for the whole of startup, to a user whose repositories
    /// were sitting in the database the entire time.
    public private(set) var hasLoadedRepos = false

    /// Why the repository list could not be read, when it could not be.
    ///
    /// Recorded rather than swallowed (#118). Cleared by any delivery that
    /// succeeds, so it names a live problem rather than a historical one.
    public private(set) var startupFailure: String?

    /// How many repository rows the last read could not decode.
    ///
    /// One bad row costs one repository now rather than the whole list, but the
    /// cost is still stated — `BoardPhase.skippedNote` turns this into the
    /// sentence beside the board. Zero means every row read, which is why a
    /// healthy board says nothing.
    public private(set) var unreadableRepoCount = 0

    /// Which of the board's four screens is the true one.
    ///
    /// Asked of `ElliotModel` rather than decided here, because the defect this
    /// answers was two surfaces reading two facts with nothing owning the pair.
    /// The view renders what this returns; it does not choose.
    public var boardPhase: BoardPhase {
        BoardPhase.of(
            hasLoadedRepos: hasLoadedRepos, isReady: isReady,
            repoCount: repos.count, failure: startupFailure,
            unreadableCount: unreadableRepoCount)
    }

    /// Sheet and inspector state, here rather than in a view, because a menu
    /// command cannot reach a view's `@State`.
    public var showingInspector = true

    /// Whether the analysis panel is showing, as the board row's leading slot.
    ///
    /// ⚠️ **This is not ``analysis``.** Hiding the panel must leave the session,
    /// its runs and its live proposal observation exactly where they are:
    /// ``closeAnalysis()`` drops the `AnalysisSession`, and
    /// ``ObservationHandle`` cancels the observation from its `deinit` — so a
    /// toggle that called it would silently stop proposals landing while eight
    /// lenses were still reading. Only `Finish`, in the panel's footer, ends a
    /// session.
    ///
    /// Hidden at launch, unlike ``showingInspector``: the detail panel costs
    /// nothing with no card selected, whereas this one would claim three
    /// columns of the board for a setup form nobody asked for.
    ///
    /// This comment used to say the analysis had no flag at all, because it was
    /// a `Window` scene and its presentation was `openWindow`'s business. #151
    /// made it a panel; the scene is gone.
    public var showingAnalysisPanel = false

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
    ///
    /// **Restored, not reset** (#132): the value comes from `preferences.json`
    /// inside `ELLIOT_HOME` at launch and goes back there on every change, so a
    /// width expressed once with a drag is not re-expressed every launch. A
    /// preference that does not survive the reader closing the app is half a
    /// feature, and the half that shipped in #54 was the expensive one.
    ///
    /// Computed over private storage rather than carrying a `didSet`, and the
    /// reason is **measured, not the obvious one**. Plain Swift does not run a
    /// property observer for an assignment in the declaring type's initialiser,
    /// so `didSet { save(…) }` looks safe. `@Observable` changes that: the macro
    /// rewrites the stored property into a computed one, so `self.panelSpans = …`
    /// inside `init` becomes a real setter call and the observer *does* fire —
    /// the first launch after this shipped would rewrite the file it had just
    /// read. Verified by building the `didSet` form and watching
    /// `AppModelTests.restoringDoesNotWrite` go red on it, and only that test.
    ///
    /// (The tracking itself survives a `didSet` — that was measured too, and it
    /// is not the reason for this shape.) ``readerPreferences`` is what
    /// `@Observable` observes; this is where the save hangs, and `init` assigns
    /// the storage.
    public var panelSpans: Int {
        get { readerPreferences.panelSpans }
        set {
            // One field of the held value, never a freshly built `Preferences`.
            // Rebuilding it would make each setter save a struct whose *other*
            // fields are back at their defaults, so the second preference to be
            // added here would silently reset the first every time either one
            // changed — a data-loss bug that cannot exist while there is only one
            // field, and would arrive fully grown with the second.
            readerPreferences.panelSpans = newValue
            // Unclamped on purpose: the two affordances that reach here — the
            // drag handle and View ▸ Narrow/Widen — can only produce the two
            // designed spans (`PanelLayout.snappedSpans`), so a clamp on the way
            // *out* would only hide a caller that had invented a third. The
            // clamp belongs where the value cannot be trusted, which is the way
            // *in*, from a file (`PreferencesFile.load`).
            preferences.save(readerPreferences)
        }
    }

    /// What View ▸ Narrow/Widen Details should read right now.
    ///
    /// Here rather than in the menu because it is a judgement about which of the
    /// two designed widths is the *other* one, and a view that judged it would be
    /// a second place holding the pair — which is what `Preferences.spanChoices`
    /// exists to prevent.
    public var panelWidthToggleTitle: String {
        panelSpans >= Preferences.spanChoices.wide ? "Narrow Details" : "Widen Details"
    }

    /// Moves the panel to the width it is not currently at, and remembers it.
    ///
    /// Goes through ``panelSpans``, so it saves exactly like a drag does — the
    /// same funnel, not a second write path.
    public func togglePanelWidth() {
        panelSpans =
            panelSpans >= Preferences.spanChoices.wide
            ? Preferences.spanChoices.narrow : Preferences.spanChoices.wide
    }

    /// Every reader preference this launch holds, and the single source of the
    /// values the setters above expose one field at a time.
    ///
    /// Held rather than reassembled per save, for the reason in `panelSpans`'s
    /// setter. ⚠️ It does **not** preserve keys this version has never heard of:
    /// `Preferences` decodes leniently but stores only what it declares, so a
    /// field written by a newer build survives a *launch* and not a *write*.
    /// That is the documented bargain (the spec says unknown fields are
    /// "ignored"), and it is worth knowing before someone reads the round-trip as
    /// lossless.
    private var readerPreferences: Preferences

    /// How many board columns wide the analysis panel is.
    ///
    /// The same kind of reader preference ``panelSpans`` is, and deliberately a
    /// *separate* one: they are two panels a reader sets independently, and the
    /// board is wide enough to want them at different widths. Sharing one
    /// number would mean widening the analysis to read a proposal also widened
    /// the card detail nobody was looking at.
    ///
    /// 3 for the same reason `panelSpans` is: the setup screen's lens grid is
    /// two columns, and a proposal row carries a title, a narrative, a
    /// rationale and an evidence strip.
    public var analysisSpans = 3

    /// What the analysis panel's setup form holds, and which proposals are
    /// staged for a bulk accept or reject.
    ///
    /// ⚠️ **On the model, not in the view, because hiding the panel destroys the
    /// view.** `showingAnalysisPanel = false` removes `.analysis` from
    /// `PanelLayout.boardOrder`, which tears down `AnalysisPanelView` and every
    /// `@State` in it. As `@State` these four made the hide lossy in a way the
    /// README, `CLAUDE.md` and the ✕'s own tooltip all say it is not: tick six
    /// lenses, type instructions, raise the limit, glance at Backlog, and come
    /// back to two lenses and an empty field. `AnalysisSessionTests` proved only
    /// that `analysis` survived — the half that already lived here.
    ///
    /// Same argument as ``logFilter`` below, one panel over.
    public var analysisAngles: Set<AnalysisAngle> = [.bugs, .quickWins]
    public var analysisInstructions = ""
    public var analysisMaxStories = 8
    /// The proposals staged for the footer's Accept / Reject.
    public var analysisSelection: Set<UUID> = []

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
    ///
    /// One value rather than four members and a task: they have one lifetime,
    /// and holding them apart meant `openAnalysis` and `closeAnalysis` each
    /// had to enumerate it. They had already drifted — see ``AnalysisSession``.
    public private(set) var analysis: AnalysisSession?

    /// Why the last Start did not start anything, or `nil`.
    ///
    /// ⚠️ **This is not ``AnalysisSession/note``, and merging the two reopens
    /// #138.** They are two messages with two owners and two lifetimes: a note
    /// belongs to an analysis that exists, and this belongs to a start that
    /// never produced one. #134 put the note *inside* the session precisely so
    /// that closing an analysis takes its sentence with it — and that is what
    /// leaves a failed start with nowhere to land, because in setup
    /// ``analysis`` is `nil` and `analysis?.note = …` is a no-op that compiles.
    /// Hoisting `note` back out here would fix this case by restoring the one
    /// #134 removed, where a sentence from a failed start rendered under the
    /// *next* analysis you opened. Two optionals say the two lifetimes; one
    /// does not.
    ///
    /// Cleared at exactly two points — the top of ``startAnalysis(repoID:angles:instructions:maxStories:)``
    /// and ``openAnalysis(id:)`` — and set at exactly one. ``closeAnalysis()``
    /// deliberately leaves it alone: returning to setup after an analysis that
    /// ran is not a failure.
    ///
    /// ⚠️ **Scoped to the repository it was thrown for**, which is why it is
    /// computed rather than plain storage. Stored flat, a failure against a
    /// disabled repository A went on being rendered — in the refusal accent,
    /// beside a *live* Start button — after the picker moved to a healthy
    /// repository B. That is #134's defect on a second axis: a sentence shown
    /// under a subject it does not belong to. The panel is about one repository
    /// at a time, so the message is too.
    ///
    /// Switching away and back brings it back, deliberately. Nothing has been
    /// attempted for that repository in between, so the sentence is exactly as
    /// true as it was — no staler than the spec already accepts when the reader
    /// stays put and toggles lenses.
    public var startFailure: String? {
        guard startFailureRepoID == selectedRepoID else { return nil }
        return startFailureMessage
    }

    /// The failure's text and the repository it belongs to, which only ever move
    /// together — hence ``clearStartFailure()`` rather than two assignments at
    /// each of the two clearing points.
    private var startFailureMessage: String?
    private var startFailureRepoID: UUID?

    private func clearStartFailure() {
        startFailureMessage = nil
        startFailureRepoID = nil
    }

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

    /// Every move the selected card has made, newest first, as the store
    /// returned them. Filled by `refreshHistory` from the panel's own `.task`,
    /// never from `CardView` — see `refreshRuns` for why the two reads are not
    /// one read.
    public private(set) var historyByCard: [UUID: [MoveAudit]] = [:]

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
    /// What has been brought in from GitHub this session, and what could not be.
    ///
    /// In memory on purpose: a relaunch re-importing costs two `gh` calls and
    /// cannot duplicate anything. It used to be a bare `Set<UUID>` inserted into
    /// *before* the await, which made "we tried" indistinguishable from "we
    /// succeeded" — see ``ImportSessionState``.
    private var importSession = ImportSessionState()
    private var registry: RepoRegistryService?
    private var ipcServer: IPCServer?
    private var toolConfig: ToolConfig?
    private var analysisService: AnalysisService?
    private var observationTasks: [Task<Void, Never>] = []
    /// Posts what the pure policy decides. Built by a factory that hands back a
    /// no-op when there is no bundle to post from, so `swift run ElliotApp` and
    /// `swift test` never reach `UNUserNotificationCenter`.
    private var presenter: NotificationPresenter?
    /// When this launch began. The audit observation starts here so relaunching
    /// does not replay a week of history as a week of banners.
    private let launchedAt = Date()

    /// Where a changed reader preference goes.
    ///
    /// ⚠️ **The default writes nowhere, and that is the feature.** Every test in
    /// `ElliotAppKitTests` builds `AppModel()`, several of them assign
    /// `panelSpans`, and most never touch `TestHome` — so a writer that defaulted
    /// to the real file would make "does `swift test` leave a preference in
    /// `~/Library/Application Support/Elliot`" depend on which suite ran first.
    /// Persistence is opted into, by exactly one production site
    /// (`ElliotApp.swift`), the way `makeNotificationDelivery()` hands back
    /// `NoDelivery` outside a bundle.
    private let preferences: any PreferencesWriting

    /// - Parameters:
    ///   - preferences: where a changed preference is written. Defaults to
    ///     nowhere.
    ///   - initialPreferences: what was read at launch, clamped on the way in.
    ///     Passed in rather than loaded here so that this type reaches no
    ///     environment variable and no filesystem — the two belong to the same
    ///     file and are handed over together by whoever resolved it.
    public init(
        preferences: any PreferencesWriting = NoPreferenceWriting(),
        initialPreferences: Preferences = .default
    ) {
        self.preferences = preferences
        // The storage directly, never through `panelSpans` — going through the
        // setter would save the value on the way in, so the first launch after
        // this ships would rewrite the file it had just read.
        self.readerPreferences = initialPreferences.clamped()
    }

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

            let presenter = NotificationPresenter(delivery: makeNotificationDelivery())
            self.presenter = presenter
            // Asked once, on launch, and never nagged about again. A denial
            // degrades Elliot to exactly what it was before this feature.
            await presenter.requestAuthorizationIfNeeded()
            // Read back from the system rather than inferred from what the
            // request returned — see `UserNotificationDelivery.summary`.
            globalChecks.append(await presenter.authorizationSummary())

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

            // The first import is kicked from here, and the order above is
            // load-bearing — do not reshuffle it without reading this (#120).
            //
            // `BoardView` imports from `.task(id: selectedRepoID)`, and by now
            // that has almost certainly already fired and done nothing:
            // `observe(store:)` publishes a selection one local read after
            // launch, while everything between it and here waits on the login
            // shell, three tool lookups, a reconciler sweep and a PR watcher.
            // It found `importer` nil and returned — and `.task(id:)` re-runs
            // on an id *change*, so it never asks again. The result was that a
            // cold launch on an already-registered repository imported nothing
            // at all, silently, which is indistinguishable from a repository
            // with no open work.
            //
            // The obvious repair — build `importer` before `observe(store:)` —
            // is not available: it needs `ghClient`, which needs the located
            // `gh`, which needs the very shell capture that `observe` is
            // deliberately hoisted above so the board stops claiming "No
            // repository yet" for the whole of startup.
            //
            // So both orders are covered instead of one being enforced: if the
            // selection arrived early, this call does the import; if the
            // repositories are still loading, this is a no-op on a nil id and
            // the view's `.task` does it when the id changes, by which time
            // `importer` exists either way. `shouldAutoImport` keeps that to
            // exactly one unattended import per repository per session, so the
            // pair cannot double-import.
            //
            // After `status` is set, not before: `importIfNeeded` writes the
            // import's own sentence there, and "Ready." would overwrite it.
            await importIfNeeded(repoID: selectedRepoID)
        } catch {
            status = "Could not start: \(error.localizedDescription)"
        }
    }

    private func startIPC(board: BoardService, store: BoardStore, analysis: AnalysisService) {
        do {
            let token = try IPCServer.loadOrCreateToken(at: StoreLocation.tokenURL)
            // The one place the app hands the engine a way to look at itself.
            // `MCPRequestHandler` defaults this to `nil` and refuses a
            // screenshot without it, so every headless construction — the tests,
            // the parity harness — is honest about having no windows rather than
            // reporting a picture of none.
            let handler = MCPRequestHandler(
                store: store, board: board, analysis: analysis,
                capture: AppKitWindowCapture()
            )
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
        // Dropping the session cancels its observation.
        analysis = nil
        await watcher?.stop()
        ipcServer?.stop()
    }

    // MARK: - Notifications

    /// Selecting from a notification click, kept apart from ordinary selection
    /// so the intent is legible: a click may arrive for a card that has since
    /// been deleted, and that selects nothing rather than clearing what the
    /// user was looking at.
    public func selectRepoFromNotification(_ repoID: UUID) {
        guard repos.contains(where: { $0.id == repoID }) else { return }
        selectedRepoID = repoID
    }

    public func selectCardFromNotification(_ cardID: UUID) {
        guard cards.contains(where: { $0.id == cardID }) else { return }
        selectedCardID = cardID
    }

    /// Turns a scheduler update into a `NotificationEvent`, or drops it.
    ///
    /// Re-reads the run from the store rather than trusting the update's own
    /// `state` and `outcome`: the notification body is built from
    /// `verifiedOutcome`, and the row is where the verifier wrote it. A card or
    /// repository that has since been deleted drops the event silently — that
    /// is not an error, and a banner about a card you removed would be worse
    /// than saying nothing.
    private func notify(runID: UUID, stalled: Bool) {
        guard presenter != nil, let store else { return }
        Task { [weak self] in
            guard
                let run = try? await store.run(id: runID),
                let cardID = run.cardID,
                let card = try? await store.card(id: cardID),
                let repo = try? await store.repo(id: card.repoID)
            else { return }
            let event: NotificationEvent = stalled
                ? .runStalled(run: run, card: card, repo: repo)
                : .runFinished(run: run, card: card, repo: repo)
            await self?.presenterHandle(event)
        }
    }

    private func presenterHandle(_ event: NotificationEvent) async {
        await presenter?.handle(event)
    }

    /// The board's own moves, read from the trail that records *why*.
    ///
    /// Watching cards instead would see a column change and have to guess who
    /// caused it, and that guess is how a user's own drag becomes a
    /// notification telling them what they just did. `since: launchedAt` so a
    /// relaunch replays nothing.
    private func observeMoveAudits(store: BoardStore) {
        let auditObservation = store.observeMoveAudits(since: launchedAt)
        observationTasks.append(Task { [weak self] in
            var seen = Set<UUID>()
            do {
                for try await audits in auditObservation {
                    for audit in audits where !seen.contains(audit.id) {
                        seen.insert(audit.id)
                        guard
                            let card = try? await store.card(id: audit.cardID),
                            let repo = try? await store.repo(id: card.repoID)
                        else { continue }
                        await self?.presenterHandle(
                            .systemMove(audit: audit, card: card, repo: repo)
                        )
                    }
                }
            } catch {
                // The board is unaffected; only this channel stopped.
                await MainActor.run { self?.status = "Stopped following the move trail." }
            }
        })
    }

    // MARK: - Observation

    private func observe(store: BoardStore) {
        observeMoveAudits(store: store)
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

        // Its own observation, because `PRWatcher` writes the reading without
        // touching any card row: refreshing off the card observation alone would
        // land the badge exactly never. Same reason `observePRStatuses` exists.
        let statusObservation = store.observePRStatuses()
        observationTasks.append(Task { [weak self] in
            do {
                for try await rows in statusObservation {
                    await MainActor.run { self?.applyPRStatuses(rows) }
                }
            } catch {
                // Deliberately quiet, unlike the card observation above: a lost
                // status stream costs a badge, not the board, and a banner
                // saying so would be louder than the fact it reports.
            }
        })

        let repoObservation = store.observeRepos()
        observationTasks.append(Task { [weak self] in
            do {
                for try await scan in repoObservation {
                    await MainActor.run {
                        self?.repos = scan.repos
                        // Carried, not dropped: the board says how many rows it
                        // could not read beside the ones it could.
                        self?.unreadableRepoCount = scan.unreadable
                        // Set on every delivery, including an empty one: an
                        // empty store is a loaded store, and the board's real
                        // empty state must be reachable.
                        self?.hasLoadedRepos = true
                        // A delivery that arrives is the answer to whatever
                        // failed before it. Left set, a transient error would
                        // keep accusing a store that is now being read.
                        self?.startupFailure = nil
                        if self?.selectedRepoID == nil { self?.selectedRepoID = scan.repos.first?.id }
                    }
                }
            } catch {
                // The old comment here reasoned about *frequency* — "repos
                // change rarely, a dropped observation is not worth a banner" —
                // when what decides this is *severity*. A dropped update is
                // cosmetic; a failure on the **first** delivery is terminal,
                // because `hasLoadedRepos` is only ever set inside the loop, so
                // it stays false for the life of the process and the board sits
                // on "Still starting" for ever with "Ready." underneath (#118).
                //
                // Recorded rather than shown directly: `BoardPhase` decides
                // whether this takes the screen or sits beside repositories
                // already loaded, so a late failure cannot blank a working
                // board.
                //
                // Logged as well as recorded, because criterion 3 asks for both
                // and they answer different people: the screen tells whoever is
                // looking at it, `log stream --predicate 'subsystem ==
                // "dev.phmatray.elliot"'` tells whoever is holding a bug report
                // and cannot see the screen. It is also the only signal
                // available when the window itself cannot be read.
                // ⚠️ `privacy: .public` is load-bearing. `Logger` redacts an
                // interpolated non-literal by default, so this line read
                // "repository observation failed: <private>" — a log saying
                // something went wrong without saying what, which is the exact
                // shape of the defect being fixed. Verified by reading it back
                // from `log show`, not by assuming. A GRDB decode error names a
                // column and a type; it carries no user content.
                Self.log.error(
                    "repository observation failed: \(error.localizedDescription, privacy: .public)")
                await MainActor.run {
                    self?.startupFailure = error.localizedDescription
                }
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
        case .runStarted(let runID, let cardID):
            // Emptied rather than seeded with a line: the tail carries events
            // now, and "started" is not one. `RunningStrip` and `RunRow` both
            // already show the run's state from the run itself.
            liveLog[runID] = []
            // The same refresh `.runFinished` does below, for the same reason:
            // **nothing re-reads a run row on its own.** Both `.task(id:)`
            // callers of `refreshRuns` — `CardView` and `DetailPanelView` — are
            // keyed on the *card's* id, which a starting run does not change,
            // so neither fires here. Without this the panel you opened to watch
            // the run draws "Nothing has run yet" for the whole run and offers
            // no Cancel, while the card beside it spins from `activeRuns`: the
            // same split `markStalled` below refuses to leave, one update
            // earlier.
            //
            // The read finds the row because `RunScheduler` saves it
            // (`RunScheduler.swift:381`) before it yields this update (`:384`).
            // That ordering is the whole reason a refresh is the right answer
            // here and the wrong one for `.runStalled`, which is yielded
            // *before* its write.
            //
            // `cardID` is nil for an analysis run, which belongs to a
            // repository; `analysis?.runs` is refreshed by the `Task` below.
            if let cardID { Task { await self.refreshRuns(cardID: cardID) } }
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
            // `recentRuns`, `runsByCard`, `analysis?.runs` — went on holding
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
            notify(runID: runID, stalled: true)
        case .runFinished(let runID, let cardID, _, _):
            // A run takes minutes and nobody watches it for all of them. One
            // Dock bounce, only when Elliot is not the front app — no
            // notification permission, and nothing to dismiss.
            if !NSApp.isActive { NSApp.requestUserAttention(.informationalRequest) }
            notify(runID: runID, stalled: false)
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
    /// card's Runs pane, `recentRuns` the overview, `analysis?.runs` the analysis
    /// window. Marking three of four is a stall that shows on some screens and
    /// not others, which is worse than one that shows nowhere — so this walks
    /// all four, through one function.
    func markStalled(runID: UUID) {
        activeRuns = activeRuns.mapValues { Self.stalling(runID, $0) }
        recentRuns = recentRuns.map { Self.stalling(runID, $0) }
        runsByCard = runsByCard.mapValues { runs in runs.map { Self.stalling(runID, $0) } }
        analysis?.markStalled(runID)
    }

    /// The rule itself: **only a run that is still running can stall.**
    ///
    /// Pure and static so `swift test` can hold it, and written once rather than
    /// four times. The guard is `RunScheduler.markStalled`'s, deliberately
    /// spelled the same way: a run that finished between the idle watcher
    /// noticing the silence and this arriving must keep the outcome it reached,
    /// not be dragged back to a non-terminal state by a late notice.
    nonisolated static func stalling(_ runID: UUID, _ run: SkillRun) -> SkillRun {
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

    /// Done as a dated log rather than a pile.
    ///
    /// Built on `cards(in:)` so the repository picker is applied in exactly one
    /// place — a second filter here is how the board and this column would come
    /// to disagree about what "All repositories" means.
    ///
    /// The log re-sorts by `columnEnteredAt`, which makes Done the one column
    /// whose on-screen order is not `orderIndex`. That is deliberate:
    /// `orderIndex` records a position a human chose while the card was still
    /// in play, and it says nothing once the card is finished. Noted here
    /// because an asymmetry nobody wrote down reads as a bug to whoever finds
    /// it next.
    ///
    /// `now` and `calendar` are parameters with ambient defaults: the view
    /// wants the wall clock, and a test cannot have one.
    public func doneLog(
        now: Date = Date(),
        calendar: Calendar = .current,
        horizonDays: Int? = ShippingLog.defaultHorizonDays
    ) -> ShippingLog {
        shippingLog(cards(in: .done), now: now, calendar: calendar, horizonDays: horizonDays)
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
    /// than a renumbering — the store has always supported this, and until #49
    /// the board simply never offered it.
    ///
    /// **Where the drop lands is decided by `CardReorder.placement`, not here.**
    /// It used to be three `if`s in this method, which meant the self-drop guard
    /// #47's review asked for would have lived somewhere no test could see it.
    /// This method now does only the two things a model layer must: perform the
    /// column move when the placement says one is needed, and write.
    public func reorder(cardID: UUID, in column: ElliotModel.Column, above target: Card?) async {
        guard let board, let moving = card(id: cardID) else { return }

        let placement = CardReorder.placement(
            moving: moving, onto: target, in: column, columnCards: cards(in: column))

        let previous: Double?
        let next: Double?
        switch placement {
        case .none:
            // A card dropped on itself. Nothing is written — not even the index
            // it already has.
            return
        case .reorder(let p, let n):
            (previous, next) = (p, n)
        case .moveThenReorder(let destination, let p, let n):
            // Crossing columns is a move first — it may file an issue, open a
            // pull request or merge one — and only then a placement. A refused
            // move places nothing, which is why this returns rather than
            // falling through.
            await move(cardID: cardID, to: destination)
            guard refusal == nil, card(id: cardID)?.column == destination else { return }
            (previous, next) = (p, n)
        }

        do {
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
        //
        // Still one row, deliberately, and it is `refreshHistory` below that
        // reads the rest. This runs from `CardView.task` for **every visible
        // card**, so widening it to the full history would put the whole board's
        // audit trail behind a scroll to feed one sentence in a header.
        lastMove[cardID] = (try? await store?.audits(cardID: cardID, limit: 1))??.first
    }

    /// Every move one card has made, for the panel that is open on it.
    ///
    /// Separate from `refreshRuns` for the reason written there — this is called
    /// only from `DetailPanelView.task(id:)`, so the 100-row read happens once
    /// per selection rather than once per visible card.
    ///
    /// A failed read leaves `[]` rather than the previous card's rows: an empty
    /// history draws no block at all, which is honest, where stale rows would
    /// attribute one card's moves to another.
    public func refreshHistory(cardID: UUID) async {
        historyByCard[cardID] =
            (try? await store?.audits(cardID: cardID, limit: MoveHistory.auditLimit)) ?? []
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
        await refreshPRStatuses()
    }

    /// The pull request readings `PRWatcher` has stored, keyed by card.
    ///
    /// Only for cards in In Review, matching what the watcher bothers to read:
    /// asking for the others would return nothing and make the map look like a
    /// board-wide answer it is not.
    func refreshPRStatuses() async {
        guard let store else { return }
        var rows: [PRStatus] = []
        for repoID in Set(cards.filter { $0.column == .inReview }.map(\.repoID)) {
            rows += (try? await store.prStatuses(repoID: repoID)) ?? []
        }
        applyPRStatuses(rows)
    }

    /// Joins readings to cards on `(repoID, prNumber)`.
    ///
    /// Shared by the pull and the observation on purpose. The two arrive from
    /// different directions — a card changed, or a reading landed — and each
    /// used to need the whole answer; two copies of this join would drift on
    /// which columns count, which is the one rule it holds.
    func applyPRStatuses(_ rows: [PRStatus]) {
        let byKey = Dictionary(
            rows.map { (Key(repoID: $0.repoID, prNumber: $0.prNumber), $0) },
            uniquingKeysWith: { first, _ in first })
        var next: [UUID: PRStatus] = [:]
        for card in cards where card.column == .inReview {
            if let number = card.prNumber,
               let row = byKey[Key(repoID: card.repoID, prNumber: number)] {
                next[card.id] = row
            }
        }
        prStatuses = next
    }

    private struct Key: Hashable {
        var repoID: UUID
        var prNumber: Int
    }

    /// What the card and the panel render. `nil` for a card nothing has read —
    /// which is not the same as a card whose pull request is fine, so the views
    /// draw nothing rather than an all-clear.
    func prStatus(for card: Card) -> ResolvedPRStatus? {
        // `currentHeadOid` is nil for the same reason as on the MCP side:
        // establishing the head right now would be a network call in a view
        // body, and `PRWatcher` already re-reads whenever the head moves. The
        // age rule still governs.
        prStatuses[card.id]?.resolved(now: Date(), currentHeadOid: nil)
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
        let page = await registry.rows(layout: layout)
        let probed = await registry.probe(page.rows)
        let tallies = await boardTallies()
        // One assignment site for all three, and the rows assigned last: the
        // page reads `repoRows` to decide whether to speak at all, so a banner
        // that arrived a turn before the rows it belongs to would briefly
        // describe the previous pass.
        //
        // The figures belong to that same group for the same reason. A row
        // saying `11 cards` beside a verdict from the previous reconcile is two
        // moments rendered as one, which is what this method's shape exists to
        // rule out — and the cheapest way to get there would have been a view
        // that asked the store as it drew each row, producing per-row answers
        // from N different moments with no pass to attribute them to.
        repoListingFailures = page.listingFailures
        repoTallies = tallies
        repoRows = probed
    }

    /// Re-reads only the figures — no `gh`, no disk scan.
    ///
    /// The Repositories page calls this when it opens with rows already in
    /// hand, where `refreshRepoRows()` is what a first arrival calls: rebuilding
    /// the rows costs one `gh repo list` per owner, and re-counting cards is
    /// three grouped statements, so the second visit should pay the cheaper one
    /// rather than nothing.
    ///
    /// ⚠️ Not "on every arrival" — `.task` does not re-run for a window that
    /// stayed open and was re-focused. The header's **Refresh** is what bounds
    /// the staleness, and it goes through `reloadRepoRows()`, which reassigns
    /// the rows, the listing failures and these figures together.
    ///
    /// Safe to call while `isReconciling`: it touches no other state, so it
    /// cannot leave the rows and the figures describing different passes in a
    /// way `reloadRepoRows` would not immediately correct.
    public func refreshRepoTallies() async {
        repoTallies = await boardTallies()
    }

    /// Today's figures, or nothing at all if there is no store behind the model.
    ///
    /// An empty dictionary rather than a thrown error: every entitled row then
    /// reads `.empty`, which is "no cards" — and that is honest for a model with
    /// no database, which is exactly what a seeded test model is.
    private func boardTallies() async -> [UUID: RepoBoardTally] {
        guard let store else { return [:] }
        // The day boundary `spentToday` and `RunScheduler` already use, supplied
        // by the caller rather than read from a clock inside the store.
        let startOfDay = Calendar.current.startOfDay(for: Date())
        return (try? await store.repoBoardTallies(since: startOfDay)) ?? [:]
    }

    /// The rows the Repositories page renders: the reconciler's verdicts, with
    /// board figures attached to the rows entitled to them.
    ///
    /// The join happens **on read**, against `importSession.failures`, rather
    /// than being snapshotted into `repoTallies`. Failures are recorded by
    /// `record(_:for:)` from two call sites that have nothing to do with this
    /// page, so a row holding a copy would be one refresh behind the banner it
    /// is supposed to agree with — and the two disagreeing is the defect, not
    /// the staleness.
    public var repoBoardRows: [RepoRow] {
        RepoBoardDigest.decorate(
            repoRows, tallies: repoTallies, failures: importSession.failures)
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
        // The one destructive fix on this page goes through the confirmation.
        // Gating here rather than at the button covers every caller of
        // `.forget`, and leaves the row's button untouched.
        if case .forget(let repoID) = fix {
            await requestForget(repoID: repoID, origin: .repositories)
            return
        }
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

        // Imported one at a time rather than through `importAll`, so each
        // summary is attributable to the repository that produced it.
        // `importAll` filters on `isEnabled`, so its output can be *shorter*
        // than its input and position does not identify anything; matching on
        // `ImportSummary.repoName` would be no better, since that is
        // `displayName` and two repositories may share one. Here the id is in
        // hand at the point the outcome is recorded, so there is nothing to
        // match. The `isEnabled` filter is kept.
        var summaries: [ImportSummary] = []
        for repo in targets where repo.isEnabled {
            let summary = await importer.importRepo(repo)
            summaries.append(summary)
            record(summary, for: repo.id)
        }
        isImporting = false
        status = summaries.map(\.sentence).joined(separator: "   ")
    }

    /// One place where an `ImportSummary` becomes session state, so the two
    /// call sites cannot drift apart — which is how the second site came to
    /// carry the same bug as the first.
    ///
    /// Internal rather than private so `ElliotAppKitTests` can drive an outcome
    /// without standing up a `GitHubImportService` and a real `gh`. That is the
    /// same seam `testOnlySeed` uses, and it is what lets criterion 5 be met
    /// here rather than only one layer down in `ImportSessionState`.
    func record(_ summary: ImportSummary, for repoID: UUID) {
        if let failure = summary.failure {
            importSession.recordFailure(repoID: repoID, message: failure)
        } else {
            importSession.recordSuccess(repoID: repoID)
        }
    }

    /// Why this repository shows no cards, when the answer is not "it has none".
    ///
    /// Survives `status` being overwritten by the next event, which is the half
    /// of #42 that actually bites: the one-shot sentence was the only signal.
    public func importFailure(repoID: UUID?) -> String? {
        repoID.flatMap { importSession.failure(repoID: $0) }
    }

    /// Whether anything in view could not be refreshed — for the "All
    /// repositories" case, where no single id is selected.
    public var importFailures: [(repo: Repo, message: String)] {
        repos.compactMap { repo in
            importSession.failure(repoID: repo.id).map { (repo, $0) }
        }
    }

    /// The failures the board should be showing, given what the picker is on.
    ///
    /// Here rather than in `BoardView` because it is a decision — "which of
    /// these does the user need to see right now" — and a view cannot be
    /// tested. One repository selected shows only its own failure; "All
    /// repositories" shows every one, because in that case an empty board is
    /// the sum of all of them.
    public var visibleImportFailures: [(repo: Repo, message: String)] {
        guard let selectedRepoID else { return importFailures }
        return importFailures.filter { $0.repo.id == selectedRepoID }
    }

    /// The first time a repository is shown, bring in what GitHub already knows.
    /// Once per repository per session — the button covers the rest.
    /// This is the unattended path, so it guards on `shouldAutoImport`: one
    /// attempt per repository per session whatever the outcome. A failure stays
    /// retryable — but by a gesture (Refresh), never by the view re-evaluating.
    /// That is criterion 4 held by construction rather than by an assumption
    /// about when SwiftUI re-runs `.task(id:)`.
    public func importIfNeeded(repoID: UUID?) async {
        guard let repoID, importSession.shouldAutoImport(repoID: repoID), !isImporting,
              let repo = repos.first(where: { $0.id == repoID }), repo.isEnabled,
              let importer
        else { return }

        isImporting = true
        let summary = await importer.importRepo(repo)
        // Recorded *after* the await, and branched on the outcome. Inserting
        // before it is the bug this fixes: `importRepo` never throws, so a
        // failed fetch used to leave the repository marked done for the session.
        record(summary, for: repoID)
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
            // `forget`, not just "un-succeed": this has to restore the
            // unattended attempt too, or a repository whose import failed
            // earlier would not pick the dismissed cards back up until the
            // user pressed Refresh.
            importSession.forget(repoID: repo.id)
        }
        status = "Dismissed items forgotten — refresh to bring them back."
    }

    public func setRepoEnabled(_ repo: Repo, enabled: Bool) async {
        var repo = repo
        repo.isEnabled = enabled
        try? await store?.saveRepo(repo)
    }

    /// A forget waiting for an answer.
    ///
    /// One optional rather than a per-screen flag: both screens present the same
    /// dialog from this, so a second one cannot appear with different words.
    public struct ForgetRequest: Identifiable, Sendable, Hashable {
        /// Which button asked, and therefore which deleter runs on confirm.
        /// Preflight deletes through the store; the Repositories page goes back
        /// through `RepoRegistryService` so it keeps its outcome sentence and
        /// its row refresh. The *confirmation* is what had to exist once.
        public enum Origin: Sendable, Hashable { case preflight, repositories }

        public let id: UUID
        public let displayName: String
        public let path: String
        public let impact: ForgetImpact
        public let origin: Origin

        public var prompt: ForgetPrompt {
            ForgetPrompt(impact: impact, displayName: displayName, path: path)
        }
    }

    public private(set) var forgetRequest: ForgetRequest?

    /// Counts what would go, then asks. Nothing is deleted here.
    ///
    /// A failure to count refuses the whole act rather than falling through to a
    /// dialog with no numbers in it: a gate that fails open is not a gate, and a
    /// vague warning is what this replaced.
    public func requestForget(repoID: UUID, origin: ForgetRequest.Origin) async {
        guard let store, let repo = repos.first(where: { $0.id == repoID }) else { return }
        do {
            let impact = try await store.forgetImpact(repoID: repoID)
            forgetRequest = ForgetRequest(
                id: repoID, displayName: repo.displayName, path: repo.path,
                impact: impact, origin: origin)
        } catch {
            status = "Could not work out what forgetting \(repo.displayName) would delete: "
                + error.localizedDescription
        }
    }

    public func cancelForget() {
        forgetRequest = nil
    }

    /// Takes the request rather than reading `forgetRequest`, and that is
    /// load-bearing, not a style choice.
    ///
    /// SwiftUI clears `isPresented` **synchronously** as it dismisses the
    /// dialog, and the Forget button's action can only be `Task { … }` because
    /// this is `async`. So the modifier's `set:` — which treats a dismissal as a
    /// cancel — always runs first, and a no-argument version reading
    /// `forgetRequest` would find it nil and return at its guard: the dialog
    /// would close, the status bar would stay quiet, and nothing would be
    /// deleted. The button would look like it worked. Handing the value in is
    /// the same fix as `presenting:` one layer up (#9).
    public func confirmForget(_ request: ForgetRequest) async {
        // Idempotent: the dismissal usually cleared it already, but a
        // programmatic confirm must not leave a stale prompt behind.
        forgetRequest = nil
        switch request.origin {
        case .preflight:
            guard let store else {
                status = "Could not forget \(request.displayName): the board is not open yet."
                return
            }
            do {
                try await store.deleteRepo(id: request.id)
                status = "Forgot \(request.displayName). The clone on disk is untouched."
            } catch {
                // `try?` here would report a completed forget over a registration
                // that survived — the failure mode `apply(_:)` exists to avoid.
                status = "Could not forget \(request.displayName): "
                    + error.localizedDescription
            }
        case .repositories:
            guard let registry else {
                status = "Could not forget \(request.displayName): the repository "
                    + "registry is not ready."
                return
            }
            let outcome = await registry.apply(.forget(repoID: request.id), layout: layout)
            status = outcome.detail
            await refreshRepoRows()
            lastFixOutcome = FixOutcome(detail: outcome.detail, succeeded: outcome.succeeded)
        }
    }

    public func refreshRepoChecks(using service: PreflightService? = nil) async {
        guard let toolConfig else { return }
        // Cleared on an explicit refresh, the way `reloadRepoRows` clears the
        // Repositories page's. A sentence about a fix, still sitting under a row
        // the user has just re-checked, describes a board state that may no
        // longer hold.
        lastCheckFix = nil
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

    /// What the last **Preflight** fix did, and **which fix it was**.
    ///
    /// The id is not decoration. `lastCheckFixOutcome` alone was read inside the
    /// row loop, so one model-wide sentence appeared under *every* check of
    /// *every* repository: press "Create 2 labels" on one repository and the
    /// "Working tree" check of another announced "Created 2 labels", as if that
    /// were about it. The doc comment claimed "shown beside the row that offered
    /// it" while the code did nothing of the kind — and it survived a Check
    /// again, unlike the Repositories page's outcome, which its refresh clears.
    ///
    /// Its own property beside `lastFixOutcome`, which belongs to the
    /// Repositories page: two screens sharing one slot would each wipe the
    /// other's sentence. They share the display *type* and not the storage.
    public private(set) var lastCheckFix: (id: String, outcome: FixOutcome)?

    /// The sentence to show under this check, if the last fix was one of its own.
    public func fixOutcome(for result: CheckResult) -> FixOutcome? {
        guard let last = lastCheckFix, result.fixes.contains(where: { $0.id == last.id })
        else { return nil }
        return last.outcome
    }

    /// Performs a `CheckFix` and **re-runs the checks** rather than editing the
    /// row to look fixed.
    ///
    /// Re-running is the point. A row edited in place to say "pass" is a row
    /// that lies when the fix half-worked — and `apply` reports partial success
    /// precisely because half-working is the realistic outcome of creating four
    /// labels over a network. Asking again is the only answer that cannot drift
    /// from what GitHub actually has.
    public func apply(_ fix: CheckFix) async {
        guard let toolConfig, let board else {
            lastCheckFix = (
                fix.id,
                FixOutcome(detail: "Elliot is still starting; try again in a moment.", succeeded: false)
            )
            return
        }
        // Resolved from the fix's own `repoID`, never from which row was
        // pressed. A repository that is no longer registered is said out loud —
        // a button that silently does nothing is the failure this screen is
        // being taught to avoid.
        guard let repo = repos.first(where: { $0.id == fix.repoID }) else {
            lastCheckFix = (
                fix.id,
                FixOutcome(detail: "That repository is no longer registered.", succeeded: false)
            )
            return
        }

        let preflight = PreflightService(
            environment: LoginShellEnvironment(
                variables: toolConfig.environment, capturedVia: "session"
            ),
            config: toolConfig
        )
        let outcome = await preflight.apply(fix, repo: repo, board: board)
        lastCheckFix = (fix.id, FixOutcome(detail: outcome.detail, succeeded: outcome.succeeded))
        // A seeded card needs no reload here: the board observes the store, so
        // it arrives the way every other card does. Only the checks have to be
        // asked again — and only **this** repository's.
        //
        // `refreshRepoChecks` loops every registered repository at ~6
        // subprocesses each, plus a networked `gh label list` per repo since
        // #170. Pressing one button should not start a full-board sweep with no
        // progress and no re-entrancy guard.
        repoChecks[repo.id] = await preflight.repoChecks(repo)
    }

    // MARK: - Analysis

    /// Why an analysis cannot start right now, or `nil` when it can.
    ///
    /// One answer, read by both surfaces: the toolbar button's tooltip and the
    /// panel's own footer. It used to be a `private var` on `BoardView` feeding
    /// a `.disabled(…)` built from a *second* expression beside it, and #151
    /// removed that `.disabled` — correctly, because a disabled toggle is a
    /// toggle you cannot switch off, but the same expression was the **only**
    /// preflight gate on the analysis path. `AnalysisService.start` checks
    /// `isEnabled` and the in-flight dedupe and nothing else, so eight
    /// unattended runs could have started in a checkout Preflight had already
    /// refused. The gate belongs on the act, not on the panel's visibility.
    public var analysisRefusal: String? {
        guard let id = selectedRepoID, let repo = repos.first(where: { $0.id == id }) else {
            return "Pick a single repository to analyse."
        }
        if !repo.isEnabled { return Consequence.reason(.repoDisabled) }
        if isBlocked(repo) {
            return "A Preflight check is failing for this repository — fix it there first."
        }
        return nil
    }

    public func startAnalysis(
        repoID: UUID, angles: [AnalysisAngle], instructions: String, maxStories: Int
    ) async {
        // Above the guard, deliberately: the reader has pressed Start, so
        // whatever the last one said has stopped being the outcome of anything.
        // Below it, the clear would be conditional on a member the reader
        // cannot see, and a stale sentence would sit there reading as the
        // verdict on the attempt they just made.
        clearStartFailure()
        guard let analysisService else { return }
        do {
            let started = try await analysisService.start(
                repoID: repoID, angles: angles, extraInstructions: instructions,
                maxStoriesPerAngle: maxStories, origin: .manual
            )
            analysis = nil
            openAnalysis(id: started.analysis.id)
        } catch {
            // Not `analysis?.note`: this is a *failed* start, so there is no
            // session and that assignment was a no-op that compiled and read as
            // if it did something. See ``startFailure`` for why the two are not
            // one member, and why the repository travels with the message.
            startFailureMessage = error.localizedDescription
            startFailureRepoID = repoID
            // Kept. A visible message and a logged one are not alternatives —
            // the log is what a bug report can be reconstructed from.
            Self.log.error("Analysis failed to start: \(error.localizedDescription, privacy: .public)")
        }
    }

    public func openAnalysis(id: UUID) {
        // The failure belongs to a start that did not happen, not to the
        // analysis about to be on screen — including the one picked from the
        // header's *Earlier analyses* menu, which is the path that does not go
        // through `startAnalysis` at all.
        clearStartFailure()
        // One assignment. The outgoing session goes with it, and its
        // observation is cancelled by `ObservationHandle.deinit` rather than
        // by a line here that a sixth member could out-live.
        analysis = AnalysisSession(id: id)
        Task { await refreshAnalysisRuns() }

        // Proposals arrive run by run, so the list fills in as each angle
        // lands rather than all at once when the last one does.
        guard let store else { return }
        let observation = store.observeProposals(analysisID: id)
        let task = Task { [weak self] in
            do {
                for try await proposals in observation {
                    await MainActor.run {
                        guard let self, AnalysisSession.accepts(self.analysis, rowsFor: id) else { return }
                        self.analysis?.proposals = proposals
                    }
                }
            } catch {
                await MainActor.run {
                    guard let self, AnalysisSession.accepts(self.analysis, rowsFor: id) else { return }
                    self.analysis?.note = error.localizedDescription
                }
            }
        }
        analysis?.observation = ObservationHandle(task)
    }

    public func closeAnalysis() { analysis = nil }

    public func refreshAnalysisRuns() async {
        guard let store, let id = analysis?.id else { return }
        let runs = (try? await store.runs(analysisID: id)) ?? []
        // The window can close, or another analysis open, while this read is
        // in flight. Without this the rows land in whatever is open when the
        // read ends rather than in what asked for them.
        guard AnalysisSession.accepts(analysis, rowsFor: id) else { return }
        analysis?.runs = runs
        await notifyIfAnalysisFinished(id: id, runs: runs, store: store)
    }

    /// Ids of analyses already announced, so six angles produce one banner.
    ///
    /// An analysis is many runs; this fires when the **last** of them reaches a
    /// terminal state. Announcing per angle would be six notifications for one
    /// act, which is the fastest way to make a channel worth muting.
    private var announcedAnalyses: Set<UUID> = []

    /// The runs are passed in rather than re-read, so this cannot disagree
    /// with the read that produced them.
    private func notifyIfAnalysisFinished(id: UUID, runs: [SkillRun], store: BoardStore) async {
        guard !announcedAnalyses.contains(id) else { return }
        // An empty list is a analysis that has not started, not one that
        // finished — `allSatisfy` on nothing is true, and would announce it.
        guard !runs.isEmpty, runs.allSatisfy(\.state.isTerminal) else { return }
        announcedAnalyses.insert(id)

        guard
            let repoID = runs.first?.repoID,
            let repo = try? await store.repo(id: repoID)
        else { return }
        // What the harvest actually kept, counted from the store rather than
        // from whatever the agents said they found.
        let kept = (try? await store.proposals(analysisID: id))?.count ?? 0
        await presenterHandle(.analysisFinished(analysisID: id, repo: repo, proposalCount: kept))
    }

    public func recentAnalyses() async -> [Analysis] {
        guard let store else { return [] }
        return (try? await store.analyses(repoID: selectedRepoID, limit: 20)) ?? []
    }

    /// One page of the finished history, and how many rows the same filter
    /// matches overall.
    ///
    /// Both halves come back together because the archive cannot use one
    /// without the other: the page is what it draws, the total is the only
    /// thing that can say whether to offer another. Read in one call so they
    /// answer the same filter — asking separately is how a "Load more" that
    /// loads nothing gets built.
    ///
    /// Honours `selectedRepoID`, like every other read on this model. The
    /// caller has to re-ask when that changes — this reads it, it does not
    /// watch it.
    ///
    /// **`nil` means "could not look", and is not the same as an empty page.**
    /// `store` is nil until `start()` has opened it, and macOS restores an open
    /// `Window` scene at launch — so the archive's first read can genuinely
    /// arrive before there is a database to read. Collapsing that into
    /// `([], 0)` let the window state "Nothing has reached Done yet." on the
    /// strength of a question it never got to ask, permanently, because nothing
    /// re-ran the read. Same distinction the board draws everywhere else
    /// between an answer and an absence of one.
    public func archivePage(
        search: String,
        limit: Int,
        offset: Int
    ) async -> (cards: [Card], total: Int)? {
        guard let store else { return nil }
        let term = search.isEmpty ? nil : search
        guard
            let cards = try? await store.doneCards(
                repoID: selectedRepoID, search: term, limit: limit, offset: offset
            ),
            let total = try? await store.doneCardCount(repoID: selectedRepoID, search: term)
        else { return nil }
        return (cards, total)
    }

    public func updateProposal(_ proposal: StoryProposal) async {
        try? await analysisService?.updateProposal(proposal)
    }

    public func acceptProposals(ids: [UUID]) async {
        guard let analysisService else { return }
        // Cleared before the await, not after: replacing one sentence with
        // another in place reads as nothing having happened.
        analysis?.note = nil
        do {
            let cards = try await analysisService.accept(proposalIDs: ids)
            analysis?.note = cards.isEmpty
                ? "Nothing to accept — those were already decided."
                : "Accepted \(cards.count == 1 ? "1 story" : "\(cards.count) stories") — waiting in Backlog. Nothing was filed on GitHub."
        } catch {
            analysis?.note = error.localizedDescription
        }
    }

    public func rejectProposals(ids: [UUID]) async {
        analysis?.note = nil
        try? await analysisService?.reject(proposalIDs: ids)
        analysis?.note = ids.count == 1 ? "Rejected 1 proposal." : "Rejected \(ids.count) proposals."
    }

    /// The angles still working, for the window's header.
    public var runningAngles: [AnalysisAngle] {
        analysis?.runs.filter { !$0.state.isTerminal }.compactMap(\.analysisAngle) ?? []
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

    /// The same trick for one repository's preflight verdict.
    ///
    /// `repoChecks` is filled by a real preflight sweep, and the rule that needs
    /// it — "an analysis must not start in a repository Preflight has refused" —
    /// is exactly the one #151 broke by deleting the toolbar's `.disabled`. A
    /// rule whose only failing case cannot be seeded is a rule with no test.
    func testOnlySeedChecks(repo: UUID, _ checks: [CheckResult]) {
        repoChecks[repo] = checks
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
        if !analysis.isEmpty { self.analysis = AnalysisSession(id: UUID(), runs: analysis) }
    }

    /// Seeds the analysis window's state without a store behind it.
    ///
    /// `testOnlySeedRuns(analysis:)` seeded a bare array; the session needs an
    /// id, so this takes the session's members and leaves that seam to the
    /// three collections that are still plain.
    func testOnlySeedAnalysis(runs: [SkillRun], note: String?) {
        guard var session = analysis else { return }
        session.runs = runs
        session.note = note
        analysis = session
    }

    /// The same trick for the Repositories page's two halves.
    ///
    /// `repoRows` and `repoTallies` are `private(set)` because one method fills
    /// both, and that method needs a `RepoRegistryService` — `gh repo list` per
    /// owner, a disk scan and a git probe per clone. What `repoBoardRows` is
    /// about is none of that: it is which rows the figures reach, and whether
    /// the failure joined on read agrees with the banner. Seeding the pair is
    /// what lets those be asserted without the fan-out that produces them.
    /// ⚠️ Rendering `RepositoriesView` itself needs one more thing this seam
    /// deliberately does not give: `isReady`, which the page's whole body sits
    /// behind. Without it the view draws "Still starting", so a render taken
    /// this way is a picture of the empty state. #209's on-screen check added an
    /// `isReady:` parameter here temporarily to take its screenshot and removed
    /// it again rather than leave a seam with no caller — if you are here to
    /// render the page, that is the line you need.
    func testOnlySeedRepoBoard(rows: [RepoRow], tallies: [UUID: RepoBoardTally] = [:]) {
        repoRows = rows
        repoTallies = tallies
    }

    /// Puts a real store behind the model without `start()`.
    ///
    /// The two seams above exist to avoid a database; this one exists because
    /// the thing under test *is* a read. `refreshHistory` and `refreshRuns`
    /// differ only in the limit they pass, and a fake would assert the limit I
    /// wrote rather than the rows SQLite returns — which is the whole question
    /// (#101). `board` stays nil, so a seeded model still cannot write.
    func testOnlySeedStore(_ store: BoardStore) {
        self.store = store
    }

    /// Puts an importer behind the model without `start()`.
    ///
    /// The thing under test in #120 is *when* `importer` becomes non-nil
    /// relative to the selection, and the real answer takes a login-shell
    /// capture and three tool lookups to arrive. This lets a test move that
    /// moment by hand and check both orders, with the importer pointed at
    /// `Scripts/fake-gh.sh` so no real `gh` is involved.
    func testOnlyAttachImporter(_ importer: GitHubImportService) {
        self.importer = importer
    }

    /// Puts an analysis service behind the model without `start()`.
    ///
    /// The rule under test in #138 is what `startAnalysis` does with a **thrown**
    /// error, and only a real `AnalysisService` throws the errors it throws. It
    /// takes an optional because *detaching* is the seam: with no service,
    /// `startAnalysis` returns at its own guard without attempting anything, so
    /// a cleared failure afterwards can only have come from the clear placed
    /// above that guard — which is otherwise indistinguishable from a second
    /// failure that happened not to occur.
    func testOnlyAttachAnalysisService(_ service: AnalysisService?) {
        analysisService = service
    }
}
