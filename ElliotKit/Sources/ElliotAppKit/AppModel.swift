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

    /// What Preflight last read about each repository.
    ///
    /// ⛔ **A reading, not an array of checks, and the absence of one is the
    /// point.** This was `[UUID: [CheckResult]]`, read as `repoChecks[id] ?? []`
    /// — and `isBlocking([])` is `false`, so every screen reported a repository
    /// nobody had swept exactly as it reported one that passed. `Repo.preflight`
    /// had learned to say `notChecked` in #249; the screens had not (#302).
    public private(set) var repoReadings: [UUID: PreflightReading] = [:]

    /// Whether the per-repository sweep is running right now.
    ///
    /// It is a real question rather than a spinner: the sweep shells out to `gh`
    /// and `git` several times per repository, so on a handful of them *Check
    /// again* was a button that looked dead for tens of seconds. It is also the
    /// re-entrancy guard — see ``refreshRepoChecks(using:)``.
    public private(set) var isCheckingRepos = false

    /// What the card editor may claim about each repository's labels.
    ///
    /// Absent means *nobody has asked yet*, which `labels(for:)` reports as
    /// `.unavailable` — a third silence that is honestly the same as the second
    /// one: nothing has been established. The editor asks on open.
    private var repoLabels: [UUID: RepositoryLabels] = [:]
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

    /// The runs the machine is doing right now, ordered and capped, with the
    /// remainder counted.
    ///
    /// Derived rather than stored, like `nextSteps`: it is a function of
    /// `recentRuns`, which is already observed and already stall-marked, and a
    /// stored copy is one more thing that can be stale. The selection — which
    /// runs, in what order, how many, and what to say about the rest — is
    /// `RunningNow`'s, in `ElliotModel`, so `swift test` can hold all of it.
    public var runningNow: RunningNow { RunningNow.of(recentRuns) }

    public private(set) var ceiling: SpendCeiling = .off

    /// Today's spend, total and split by skill, both read from one midnight.
    ///
    /// One property rather than two, because the pair is one reading: a split
    /// assembled from a second `startOfDay` call would disagree with its own
    /// total across midnight, and nothing on screen would say so. `DaySpend`
    /// carries the boundary it was taken at for that reason.
    public private(set) var daySpend: DaySpend = .nothing

    /// What has been spent today, as a bare `Spend`.
    ///
    /// Derived rather than stored: it was a stored property assigned beside the
    /// split, which is exactly the arrangement where one gets refreshed and the
    /// other does not. The screens that only want the number keep reading this.
    public var spentToday: Spend { daySpend.total }

    /// Today's spend split by skill, each figure carrying the runs of its own
    /// kind that are still going.
    ///
    /// The pairing is `DaySpend.figures`, in `ElliotModel`: the split is a
    /// reading of what **ended**, and the runs in flight are a different fact
    /// from a different source — `RunningNow.countByKind`, the same selection
    /// the Running now band draws, so the rows saying "not in this figure yet"
    /// are the rows a reader can see above.
    public var todayByKind: [(kind: SkillKind, figure: SpendFigure)] {
        daySpend.figures(inFlight: runningNow.countByKind)
    }

    public private(set) var isOverDailyCeiling = false

    /// Today's spend *and* the runs it cannot have counted — the pair, because
    /// `spentToday` alone reads as complete while the money is being spent.
    ///
    /// The store's query keys on `endedAt`, so an eight-lens analysis
    /// contributes nothing to this figure until it finishes and then lands on it
    /// all at once. Every screen showing the day's total reads this rather than
    /// `spentToday`, so there is one answer to "is that the whole bill".
    public var todayFigure: SpendFigure {
        SpendFigure(spend: spentToday, inFlight: occupancy.writers + occupancy.analyses)
    }

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

    /// What the launch-time artefact sweep removed, once it has finished.
    ///
    /// `nil` until then, and that is not the same as `SweepReport()`: "no sweep
    /// has finished" is a fact about this launch, "a sweep found nothing" is a
    /// fact about the directories. Only the second is worth rendering, and only
    /// the second is what `SweepReport.sentence` speaks for.
    public private(set) var artifactSweep: SweepReport?

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

    /// Which screen the console is unfolding above the status bar, and how tall.
    ///
    /// One value rather than a face beside a `Bool`, and its transitions live on
    /// `ConsoleState` rather than here: pressing a door twice is not the same act
    /// as choosing a screen from a menu, and this model would otherwise decide
    /// that afresh at each of the call sites below.
    ///
    /// ⚠️ **Not persisted, deliberately, and unlike the two panel spans.** A
    /// board that reopened onto Operations would be reporting on a machine state
    /// from a previous session, over the columns the reader actually came back
    /// for. The *height* is a designed preference and will be persisted when
    /// something exists to set it with; which screen was open is a session.
    public var console = ConsoleState()

    /// What a **door in the status bar** does.
    ///
    /// The figure a reader presses is the thing they are reading, so pressing it
    /// again unmistakably means "put this away". `ConsoleState.press` holds that
    /// rule; this is the funnel to it.
    public func pressConsoleDoor(_ face: ConsoleFace) {
        console.press(face)
    }

    /// What a **menu item** does: show this screen, whatever was showing.
    ///
    /// Deliberately not ``pressConsoleDoor``. An item named "Operations" that
    /// closed Operations would do the opposite of what it says on every second
    /// use, and unlike a door it carries no figure to make the toggle read as
    /// one.
    public func showConsoleFace(_ face: ConsoleFace) {
        console.show(face)
    }

    /// Folds the console away, keeping the height for next time.
    ///
    /// Reached by the header's ✕ and by Escape, whose order is
    /// `EscapeRoute.next(consoleIsOpen:hasSelectedCard:)` and not this method's
    /// business.
    public func closeConsole() {
        console.close()
    }

    /// What View ▸ Shorten/Lengthen Console should read right now.
    ///
    /// Here for the reason ``panelWidthToggleTitle`` gives: which of the two
    /// designed heights is the *other* one is a judgement about the designed
    /// pair, and a menu that made it would be a second place holding it.
    public var consoleHeightToggleTitle: String {
        console.height == .tall ? "Shorten Console" : "Lengthen Console"
    }

    /// Moves the console to the height it is not currently at.
    public func toggleConsoleHeight() {
        console.height = console.height.toggled
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

    /// The archive's term, pages and folded days.
    ///
    /// On the model rather than in `ArchiveView`, for the two reasons
    /// ``ArchiveReader`` sets out: the seam between a keystroke and a read had
    /// no test and **could have none** while the term was `@State` (#230), and a
    /// view's state dies with the view — which is what a board slot's hide does.
    ///
    /// A `let`: `@Observable` tracks through a nested reference fine, but a
    /// satellite *reassigned* wholesale invalidates every reader of it, and
    /// nothing here ever wants a second archive.
    let archive = ArchiveReader()

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

    /// What the reader has agreed to be interrupted by.
    ///
    /// The third reader preference, and it reaches disk exactly like the other
    /// two: one field of the *held* value, then a save. It used to live in
    /// `UserDefaults.standard`, which is keyed by bundle identifier and so
    /// cannot follow `ELLIOT_HOME` — meaning every scratch-home check in this
    /// project read *and wrote* the operator's real settings (#222).
    public var notificationPreferences: NotificationPreferences {
        get { readerPreferences.notifications }
        set {
            readerPreferences.notifications = newValue
            preferences.save(readerPreferences)
            // The presenter decides whether to post from a value it holds, so it
            // has to be told. One writer, pushing — rather than the presenter
            // reaching back for a getter, which is the shape that made this a
            // `UserDefaults` read in the first place.
            presenter?.preferences = newValue
        }
    }

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
    ///
    /// **Restored, not reset** (#221): this was an in-memory `= 3`, so half the
    /// board forgot its width at every launch while the other half remembered.
    /// Computed over ``readerPreferences`` and saved on write, exactly like
    /// ``panelSpans`` — the same funnel, deliberately not a second write path,
    /// because two save paths into one file is how the field written last wins.
    public var analysisSpans: Int {
        get { readerPreferences.analysisSpans }
        set {
            // One field of the held value. See `panelSpans`'s setter: rebuilding
            // a fresh `Preferences` here would save a struct whose *other* field
            // is back at its default, so setting either span would silently
            // reset the other. That comment described a bug that could not yet
            // exist; this is the field that makes it possible, and
            // `PreferencesFileTests` now holds the pair.
            readerPreferences.analysisSpans = newValue
            // Unclamped, like `panelSpans`, and for the same reason: the drag
            // handle and View ▸ Narrow/Widen Analysis can only produce the two
            // designed spans. The clamp belongs where the value cannot be
            // trusted, which is `PreferencesFile.load`.
            preferences.save(readerPreferences)
        }
    }

    /// What View ▸ Narrow/Widen Analysis should read right now.
    ///
    /// Here rather than in the menu for the reason ``panelWidthToggleTitle``
    /// gives: which of the two designed widths is "the other one" is a judgement
    /// about the pair, and a menu that judged it would be a second place holding
    /// it. `ElliotApp` spelled `model.analysisSpans >= 3 ? … : …` inline, with
    /// the literal `3` — the exact shape `Preferences.spanChoices` exists to
    /// prevent, and the one `panelWidthToggleTitle` was extracted out of.
    public var analysisWidthToggleTitle: String {
        analysisSpans >= Preferences.spanChoices.wide ? "Narrow Analysis" : "Widen Analysis"
    }

    /// Moves the analysis panel to the width it is not at, and remembers it.
    public func toggleAnalysisWidth() {
        analysisSpans =
            analysisSpans >= Preferences.spanChoices.wide
            ? Preferences.spanChoices.narrow : Preferences.spanChoices.wide
    }

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
    ///
    /// ⚠️ **Stored on the session, not here** — the three above are setup state
    /// and outlive an analysis on purpose; this one belongs to the analysis and
    /// outliving it was #290. The `@State`-versus-model argument in the comment
    /// above is about surviving a *hide*; this is about not surviving a
    /// *Finish*, and the two pull in opposite directions. The session lives on
    /// this model, so the hide stays lossless either way.
    ///
    /// Reads as empty and swallows a write when no analysis is open. That is the
    /// correct answer rather than a silent failure: in setup there are no
    /// proposals to stage, so there is nothing a write could mean.
    public var analysisSelection: Set<UUID> {
        get { analysis?.selection ?? [] }
        set { analysis?.selection = newValue }
    }

    /// Which decided group the review list is showing (#331).
    ///
    /// The same pass-through `analysisSelection` is, for the same two reasons:
    /// on the session so it dies with the analysis it filters (#290), and read
    /// through here so the panel binds to one property rather than reaching
    /// into the session. Reads `.proposed` and swallows a write when no analysis
    /// is open — in setup there is no list to filter, so there is nothing a
    /// write could mean.
    public var analysisReview: ProposalStatus {
        get { analysis?.review ?? .proposed }
        set { analysis?.review = newValue }
    }

    /// The open proposal editor and everything typed into it.
    ///
    /// On the session for the same two reasons as `analysisSelection`: it must
    /// survive the panel being hidden — which destroys the view, and took the
    /// draft with it (#291) — and it must not survive the analysis it belongs
    /// to.
    public var analysisEdit: ProposalEdit? {
        get { analysis?.edit }
        set { analysis?.edit = newValue }
    }

    /// Opens the editor on a proposal, seeded from the proposal itself.
    ///
    /// Seeding here rather than in the view's `init` is the whole fix:
    /// `ProposalEditor` built its draft in `init` from the proposal, so every
    /// rebuild of a torn-down subtree started again from the stored text.
    public func beginEditingProposal(_ proposal: StoryProposal) {
        analysisEdit = ProposalEdit(
            proposalID: proposal.id, draft: CardDraft(proposal: proposal))
    }

    public func endEditingProposal() { analysisEdit = nil }

    /// Drops an edit whose proposal is no longer open for decision.
    ///
    /// ⚠️ A proposal can be accepted or rejected over MCP, or by this panel's
    /// own footer, while the editor is hidden. Re-applying a draft over a
    /// decided proposal is worse than losing it: an accepted one already has a
    /// Backlog card carrying its text, and a save would rewrite the proposal
    /// the card came from.
    ///
    /// Called when the list of open proposals changes rather than from `body` —
    /// a view that mutated the model while rendering it is a different bug.
    public func dropStaleAnalysisEdit(openProposalIDs: Set<UUID>) {
        guard let edit = analysisEdit else { return }
        guard !edit.survives(amongOpen: openProposalIDs) else { return }
        analysisEdit = nil
        analysis?.note = "The proposal you were editing was decided elsewhere, so the edit was dropped."
    }

    /// Which shipping days are folded, for **every** surface that draws them.
    ///
    /// One set, because there is one thing being folded. Done and the Archive
    /// each held their own — a `@State` in `BoardView` and a member of
    /// `ArchiveReader` — over the same `ShipDay.start` keys, with the toggle
    /// written out twice, verbatim. In a shell that puts the two side by side
    /// that reads as a bug: fold *Yesterday* in Done and it is still open in
    /// the Archive two feet to the right, showing the same cards under the same
    /// heading. This repository has paid three defects for one mechanism
    /// written twice (#146); this is the cheap instance of it.
    ///
    /// ⛔ **Not to be merged with `ColumnView`'s repository-group fold.** A
    /// repository and a day are different things to have folded, and no column
    /// shows both — collapsing them would be this very drift, one level up.
    ///
    /// ⚠️ The keys are `calendar.startOfDay`, so a set that outlives midnight
    /// keeps stale ones. Harmless — a day nobody can see stays folded — and
    /// deliberately not swept: a sweep would need the clock, and this is the
    /// same midnight hazard #231 names for caching `dayRows`.
    public var collapsedDays: Set<Date> = []

    public func isDayCollapsed(_ start: Date) -> Bool { collapsedDays.contains(start) }

    /// Fold or unfold a day — said, rather than flipped.
    ///
    /// ⚠️ The board draws a folded day **open** while it holds the selection
    /// (`ColumnRows.build`), so at that one heading what the reader sees and
    /// what this set holds disagree, and a flip would *unfold* a day they had
    /// just asked to fold. Done therefore says which way it means; the Archive,
    /// which has no selection and so no disagreement, keeps ``toggleDay(_:)``.
    public func setDay(_ start: Date, folded: Bool) {
        if folded {
            collapsedDays.insert(start)
        } else {
            collapsedDays.remove(start)
        }
    }

    public func toggleDay(_ start: Date) {
        setDay(start, folded: !collapsedDays.contains(start))
    }

    /// Which rows of a run log the panel is showing.
    ///
    /// One filter for the pane rather than one per run box: it is a reading
    /// mode — "show me only what failed" — and a reader who sets it on the run
    /// they are looking at means it for the card, not for that box. It lives on
    /// the model rather than in `@State` for the ordinary reason: a `@State` in
    /// a run box is reset every time the selection changes, so the choice would
    /// not survive clicking the next card.
    public var logFilter: RunLogFilter = .all

    /// The story being written in the New story face — every character of it.
    ///
    /// ⚠️ **On the model, not in the view, because hiding the face destroys the
    /// view.** It is the identical mechanism `analysisAngles` records one screen
    /// over: folding the console removes the face from the board's column, which
    /// tears `NewStoryView` down and every `@State` in it with it. As `@State`
    /// this made ⎋, the ✕ and any door in the status bar silently discard a
    /// three-field story and its acceptance criteria — and nothing distinguishes
    /// a draft that was lost from one that was never typed.
    ///
    /// **One struct property rather than a field each.** `@Observable`
    /// invalidates per stored property, so a keystroke here invalidates exactly
    /// the readers of *this* value — the face — and the board's card list, which
    /// never touches it, does not re-evaluate per character.
    public var newCardDraft = CardDraft()

    /// Which repository the reader has **chosen** for the story being written,
    /// or `nil` for "whatever the board is pointed at".
    ///
    /// ⚠️ `nil` is not "none" and never was a valid target: a card must land
    /// somewhere. It means *nobody has chosen*, and ``newCardRepo`` resolves
    /// that against the board. Two call sites used to assign
    /// `selectedRepoID ?? repos.first?.id` into here at the moment the face was
    /// opened — the same two lines written twice — which froze alphabetical luck
    /// into a stored id and gave the reader no way to correct it (#314).
    ///
    /// Cleared with the draft it belongs to, in ``clearNewStory()``: the choice
    /// is part of *this* story, so once the story is filed the face is fresh and
    /// follows the board again.
    public var newCardRepoID: UUID?

    /// The repository the story being written will actually be filed against.
    ///
    /// Resolved against ``repos`` rather than trusted as an id, which is the
    /// whole point of it being computed: a repository can be forgotten from the
    /// Repositories face while this one is open, and a stored id that outlived
    /// its repository reached `BoardService.createCard` as
    /// `BoardError.repoNotFound` — a refusal, on a screen that closed itself and
    /// destroyed the story on the way out.
    ///
    /// The order is the reader's choice, then the board's picker, then the first
    /// repository. That last fallback is what makes this total in one useful
    /// direction: **it is `nil` if and only if the board has no repositories at
    /// all**, so the face has exactly one repository-less state and it is one the
    /// reader can see the reason for.
    public var newCardRepo: Repo? {
        repos.first { $0.id == newCardRepoID }
            ?? repos.first { $0.id == selectedRepoID }
            ?? repos.first
    }

    /// Why the last *Add to backlog* filed nothing, or `nil`.
    ///
    /// ⛔ **A field of its own, not ``status``.** `status` is a single narration
    /// owned by whoever spoke last — an import finishing, a run starting, the
    /// launch sweep — and the status bar renders it on one truncated line at the
    /// bottom of the window. A refusal the reader has to act on must stay beside
    /// the buttons that were refused, for as long as the story is still being
    /// written. This repository has the general form of that lesson on file:
    /// *"a fact that has to survive needs a field of its own"* (`artifactSweep`).
    ///
    /// ⚠️ **Scoped to the repository it was thrown for**, which is why it is
    /// computed rather than plain storage — the same shape, and the same reason,
    /// as ``startFailure``. The face now carries its own repository picker, so
    /// the subject can change while the sentence is on screen; stored flat, a
    /// refusal about repository A would go on rendering in the refusal accent
    /// beside a live Add button for repository B.
    ///
    /// Switching away and back brings it back, deliberately: nothing has been
    /// attempted for that repository in between, so the sentence is exactly as
    /// true as it was.
    public var newStoryRefusal: String? {
        guard newStoryRefusalRepoID == newCardRepo?.id else { return nil }
        return newStoryRefusalMessage
    }

    /// The refusal's text and the repository it belongs to, which only ever move
    /// together — hence ``clearNewStoryRefusal()`` rather than two assignments at
    /// each site, exactly as `clearStartFailure()` exists one screen over.
    private var newStoryRefusalMessage: String?
    private var newStoryRefusalRepoID: UUID?

    private func clearNewStoryRefusal() {
        newStoryRefusalMessage = nil
        newStoryRefusalRepoID = nil
    }

    /// Records why nothing was filed, against the repository it was refused for.
    private func refuseNewStory(_ message: String) {
        newStoryRefusalMessage = message
        newStoryRefusalRepoID = newCardRepo?.id
    }

    /// Empties the face: the story is filed, so there is no story and no choice.
    ///
    /// The draft and the chosen repository are cleared **together** because the
    /// choice belongs to the story that was just filed. Its own method for the
    /// reason `clearStartFailure()` is one: two values that only ever move
    /// together are one act, and a caller that cleared the draft and left the
    /// choice would leave the next story pointed somewhere nobody chose it.
    private func clearNewStory() {
        newCardDraft = CardDraft()
        newCardRepoID = nil
        clearNewStoryRefusal()
    }

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
    /// and ``openAnalysis(_:)`` — and set at exactly one. ``closeAnalysis()``
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

    /// Every suppression, live off the table.
    ///
    /// Fed by ``BoardStore/observeDismissals()`` rather than by the last import
    /// summary. `ImportSummary.sentence` still says "3 dismissed" and that
    /// sentence is a *record of one pass*: it cannot decrement when a row is
    /// restored, and it is overwritten by whatever speaks into `status` next. A
    /// figure that is a reading of the table cannot outlive the fact it reports.
    public private(set) var dismissedItems: [DismissedItem] = []

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
    /// ``CardLanding`` is top-level rather than nested here, and the reason is
    /// written on it: this class is `@MainActor`, a nested type inherits that,
    /// and `ColumnFocus` — the rule that decides what a column scrolls to — has
    /// to be able to read `cardID` without one.
    public private(set) var lastLanded: CardLanding?

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
        /// Who asked for this merge.
        ///
        /// Carried from the arming to the button rather than assumed at the
        /// button, because `confirmMerge` used to write `.userDrag` for every
        /// caller — so a merge Elliot arranged for itself appeared in the
        /// card's move history as "Dragged".
        public var origin: MoveOrigin
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
            // `ELLIOT_GH_PATH` and friends, read once here (#238). Prepending a
            // shim to `PATH` before `open` does **not** work — the capture above
            // is a login shell, whose own rc files re-prepend their bin
            // directories and out-rank whatever was inherited (#188). This is
            // the mechanism that does.
            let locator = ToolLocator(
                environment: environment, overrides: .fromProcessEnvironment())
            async let claude = locator.locate("claude")
            async let gh = locator.locate("gh")
            async let git = locator.locate("git")

            // An unusable override resolves to no path at all rather than to
            // whatever `PATH` would have given, so the app refuses to run a
            // binary the reader did not choose. Preflight names the variable.
            let config = ToolConfig(
                claudePath: await claude.tool?.path ?? "",
                ghPath: await gh.tool?.path ?? "",
                gitPath: await git.tool?.path ?? "",
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
            // One reader, shared: the board's merge decision and the MCP
            // surface's card reads then spend one `gh pr list` between them
            // rather than one each, and there is one place where "what did `gh`
            // establish about this pull request" is answered.
            let verdicts = PRVerdictReader(store: store, gh: ghClient)
            let board = BoardService(store: store, launcher: scheduler, verdicts: verdicts)
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
            // The packs the registered repositories actually run, read from the
            // store rather than from `repos`: this runs inside `start()`, before
            // the repo observation has published anything, so `repos` is still
            // empty here. `packsInUse` folds the default in either way.
            let registered = (try? await store.repos()) ?? []
            globalChecks = await preflight.globalChecks(
                layout: layout, packs: PreflightService.packsInUse(registered))

            let presenter = NotificationPresenter(
                delivery: makeNotificationDelivery(),
                preferences: readerPreferences.notifications
            )
            self.presenter = presenter
            // Asked once, on launch, and never nagged about again. A denial
            // degrades Elliot to exactly what it was before this feature.
            await presenter.requestAuthorizationIfNeeded()
            // Read back from the system rather than inferred from what the
            // request returned — see `UserNotificationDelivery.summary`.
            globalChecks.append(await presenter.authorizationSummary())

            let analysisService = AnalysisService(
                store: store, launcher: scheduler, board: board, gh: ghClient,
                // A live reading, not `repoReadings` and not `Repo.preflight`.
                // Both of those are a screen's cache: the readings are not
                // persisted and the verdict is, so between launch and the first
                // sweep every repository looks unmeasured — which permits. The
                // board can live with that (a person is dragging one card, and
                // freezing every repository for the first seconds of a launch
                // is worse); a service that starts up to eight unattended agents
                // should ask. `preflight` is already built above for the global
                // checks, so this costs no second service.
                gate: PreflightGate(preflight: preflight)
            )
            self.analysisService = analysisService
            startIPC(board: board, store: store, analysis: analysisService, verdicts: verdicts)

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

            // Housekeeping: bound `runs/`, `screenshots/` and `analyses/`, which
            // nothing else has ever removed a file from.
            //
            // *After* the reconciler, and that is the load-bearing half of the
            // placement: the runs it has just marked failed are exactly the ones
            // whose logs stop being protected, and the ones it re-queued are the
            // ones whose logs start being. Reading the runs table ahead of it
            // would read it one state behind reality.
            //
            // Detached, because nothing on screen waits for it: it walks three
            // directories and unlinks files, to bound something nobody is looking
            // at. A failure inside cannot reach start-up either — `sweep()` does
            // not throw, by construction.
            //
            // ⛔ The result is *recorded*, never written into `status`. Appending
            // to that line was the first attempt and it is unfixable by
            // placement: this task shares the main actor with `start()`, so it
            // resumes at whichever suspension comes next — which is
            // `importIfNeeded`'s `await importer.importRepo(repo)`, whose very
            // next statement assigns `status`. The sentence was overwritten
            // within milliseconds, every time, and left no trace. `status` is a
            // single narration owned by whoever spoke last; a fact that has to
            // survive belongs in a field of its own, and the status bar renders
            // it from there.
            let sweeper = ArtifactSweeper(store: store)
            Task { [weak self] in
                let report = await sweeper.sweep()
                self?.artifactSweep = report
            }

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

    private func startIPC(
        board: BoardService, store: BoardStore, analysis: AnalysisService,
        verdicts: PRVerdictReader
    ) {
        do {
            let token = try IPCServer.loadOrCreateToken(at: StoreLocation.tokenURL)
            // The one place the app hands the engine a way to look at itself.
            // `MCPRequestHandler` defaults this to `nil` and refuses a
            // screenshot without it, so every headless construction — the tests,
            // the parity harness — is honest about having no windows rather than
            // reporting a picture of none.
            let handler = MCPRequestHandler(
                store: store, board: board, analysis: analysis,
                capture: AppKitWindowCapture(), verdicts: verdicts
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

    // MARK: - Repositories → the board

    /// Scope the board to a repository, and report whether it worked.
    ///
    /// Guarded for the same reason `selectRepoFromNotification` above is, and it
    /// is worth saying which reason: `repoRows` is a snapshot of a sweep, so a
    /// `forget` applied between that sweep and this click would otherwise point
    /// the picker at a registration that no longer exists — an empty board under
    /// a phantom name. On refusal the current selection is left **as it was**
    /// rather than cleared, because clearing it answers a stale row by silently
    /// dumping the reader onto the whole portfolio.
    ///
    /// It returns whether it selected rather than raising the window itself:
    /// `openWindow` belongs to a view's environment, and the caller should only
    /// raise a window when there is something to raise it for.
    @discardableResult
    public func showBoard(repoID: UUID) -> Bool {
        guard repos.contains(where: { $0.id == repoID }) else {
            // Said out loud, in the page's own outcome line, rather than
            // returning `false` into a caller that can only do nothing with it.
            // A visible button that silently does nothing is indistinguishable
            // from one that worked — which is the exact defect `FixOutcome`
            // was introduced to fix, one screen over.
            lastFixOutcome = FixOutcome(
                detail: "That repository is no longer registered, so it has no board. "
                    + "The list is from an earlier sweep — Refresh to see what is there now.",
                succeeded: false)
            return false
        }
        selectedRepoID = repoID
        return true
    }

    /// The same act, from a row's board action rather than a bare id.
    ///
    /// The unwrap lives here and not at each call site because there are four
    /// of them — the row's button, its double-click, its context menu, and ↩ —
    /// plus ⌘↩ in `ElliotApp`'s `Commands`, which is in a different **module**
    /// and so cannot reuse a private method in the view. That last one is why
    /// this is on the model: it is the only place all five can share.
    @discardableResult
    public func showBoard(_ action: RepoRowBoardAction) -> Bool {
        guard case .open(let repoID) = action else { return false }
        return showBoard(repoID: repoID)
    }

    /// Whether the selected row can open the board.
    ///
    /// Derived from `selectedRowBoardAction`, so the menu item's enablement and
    /// its action still ask one question — it exists only because `ElliotApp`
    /// cannot name `RepoRowBoardAction` (it depends on `ElliotAppKit` and
    /// nothing else) and so cannot pattern-match the case itself.
    public var canOpenBoardForSelectedRow: Bool {
        if case .open = selectedRowBoardAction { return true }
        return false
    }

    /// The Repositories list's selection, by `RepoRow.id` — `"owner/name"`.
    ///
    /// On the model rather than in `RepositoriesView`'s `@State` because the
    /// menu item that gives this act its ⌘↩ lives in `ElliotApp`'s `Commands`,
    /// which is not a view hierarchy and cannot read another view's state.
    public var selectedRepoRowID: String?

    /// The board action of whatever row is selected.
    ///
    /// Asked once, here, so the menu item's enablement and its action cannot
    /// disagree — the two used to be the classic pair of independent guesses.
    /// A selection can outlive its row (it is a string into a list every sweep
    /// rebuilds), and that case answers `.unavailable` like any other row with
    /// nowhere to go.
    public var selectedRowBoardAction: RepoRowBoardAction {
        guard let id = selectedRepoRowID,
            let row = repoRows.first(where: { $0.id == id })
        else { return .unavailable }
        return row.boardAction
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

    /// Internal rather than `private` so a test can start the **real**
    /// observation instead of a four-line replica of it.
    ///
    /// `reorder`'s cross-column guard reads `cards`, and `cards` has exactly one
    /// writer: the pump below. A suite that re-implemented it would be asserting
    /// against its own copy — the trap that makes a measurement describe its
    /// rendering rather than its subject. Everything started here is
    /// store-backed, so it costs a test no network, no clock and no process.
    /// `shutdown()` cancels all of it. See `ReorderGlueTests`.
    func observe(store: BoardStore) {
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

        // Its own observation, for the reason the PR statuses above have one:
        // nothing about a dismissal touches a card row, so a figure refreshed
        // off the card observation would follow a restore exactly never.
        let dismissalObservation = store.observeDismissals()
        observationTasks.append(Task { [weak self] in
            do {
                for try await rows in dismissalObservation {
                    await MainActor.run { self?.dismissedItems = rows }
                }
            } catch {
                // Quiet, like the statuses: a lost figure costs a door in the
                // status bar, not the board, and the face is still reachable
                // from the View menu. A banner would be louder than the fact.
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
            // its write, so a refresh racing it reads the row as it was and
            // writes `.running` back over the answer. The guard is
            // `RunState.applying`, which the scheduler's own write calls too, so
            // the two cannot disagree about which runs may stall.
            mark(.wentQuiet, runID: runID)
            notify(runID: runID, stalled: true)
        case .runResumed(let runID):
            // The mirror, and the whole of this issue: the mark used to be
            // one-way, so a `merge-pr` that waited twenty-one minutes on CI and
            // then produced its next tool call kept the attention tint and "No
            // output for a while" until it exited.
            //
            // Deliberately no `notify`. `NotificationEvent` has `.runStalled`
            // and `.runFinished` because both ask the reader for a decision; "it
            // is talking again" asks for nothing, and a banner per recovery on a
            // run that goes quiet between tool calls is noise. The stall's own
            // banner is not withdrawn either — `UNUserNotificationCenter` is
            // reachable only from a launched bundle, so that is unverifiable
            // from `swift test` and is left alone rather than half-done.
            mark(.startedTalkingAgain, runID: runID)
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

    /// Applies a silence notice to every copy of the run the screen draws from.
    ///
    /// Four collections hold runs and any of them can be the one on screen:
    /// `activeRuns` feeds the card's `RunningStrip`, `runsByCard` the selected
    /// card's Runs pane, `recentRuns` the overview, `analysis?.runs` the analysis
    /// window. Marking three of four is a stall that shows on some screens and
    /// not others, which is worse than one that shows nowhere — so this walks
    /// all four, through one function.
    ///
    /// ⛔ **One walk for both directions, not two walks.** A `markResumed` beside
    /// a `markStalled` would be four more `mapValues` to keep in step, and a
    /// fifth collection added later would have to be remembered twice. Taking
    /// the direction as an argument is what makes "the mirror was never written"
    /// impossible to repeat: there is nothing left to write.
    func mark(_ notice: RunSilence, runID: UUID) {
        activeRuns = activeRuns.mapValues { $0.applying(notice, ifID: runID) }
        recentRuns = recentRuns.map { $0.applying(notice, ifID: runID) }
        runsByCard = runsByCard.mapValues { runs in runs.map { $0.applying(notice, ifID: runID) } }
        analysis?.mark(notice, runID)
    }

    /// The most recent event of this run that says anything in one line.
    ///
    /// Searched backwards rather than taken from the end: `liveLog` holds every
    /// event now, and most of them — a successful tool result, a `system` line,
    /// a partial — collapse to nothing. Taking the last event outright would
    /// blank the strip every time one of those arrived last.
    ///
    /// Here rather than in `CardView`, where it was, because `RunningStrip` is
    /// drawn on the card *and* in Operations' Running now band. A second copy in
    /// the second caller is how the two would come to disagree about what "the
    /// last line" is — the shape #146 paid for one layer down.
    func lastLine(of run: SkillRun) -> String? {
        guard let events = liveLog[run.id] else { return nil }
        return events.reversed().lazy.compactMap(AppModel.describe).first
    }

    /// One event collapsed to one line, for `RunningStrip` and nowhere else.
    ///
    /// A strip shows a single line of a run in flight, so a collapse is the
    /// right answer *there* — it is the wrong answer everywhere a log is read,
    /// which is why the panel folds `liveLog` into `RunLogRow`s instead. Keep
    /// this narrow: widening it back is how the log became a `[String]`.
    ///
    /// Its one caller is `lastLine(of:)` above. It said "`CardView`'s running
    /// strip" until the strip became a component two screens draw.
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

    /// ⛔ **Deliberately not memoised, and that is a measured answer rather than
    /// an omission (#282).**
    ///
    /// The proposal was to cache the per-column, repo-filtered slice under
    /// `@ObservationIgnored`, exactly as `parsedBodies` below caches a parsed
    /// issue body. Its own *What to watch* said to measure first, so
    /// `CardsInColumnCostTests` does — versioned and rerunnable rather than a
    /// throwaway script whose number outlives its code:
    ///
    /// ```
    /// cd ElliotKit && ELLIOT_MEASURE=1 swift test --filter CardsInColumnCostTests
    /// ```
    ///
    /// Release build, Apple silicon, 20 repositories, picker on "All
    /// repositories", 2026-08-09:
    ///
    /// | cards on the board | one `cards(in:)` | one board pass |
    /// |---|---|---|
    /// | 100 | 8.8 µs | 232 µs |
    /// | 500 | 36 µs | 565 µs |
    /// | 2 000 | 169 µs | 1.9 ms |
    /// | 10 000 | 854 µs | 9.0 ms |
    ///
    /// A *board pass* is all five columns rebuilding the list they draw —
    /// grouping and Done's day bucketing included — which is what a selection
    /// change, a keystroke in the analysis panel or a one-second `RunningStrip`
    /// tick causes. At the sizes this board is used at that is a small fraction
    /// of a 16.7 ms frame. The cache would buy nothing anyone can feel, and cost
    /// a key that has to name **every** input: miss one and a moved card keeps
    /// drawing in its old column, which is a correctness bug traded for speed
    /// nobody could see.
    ///
    /// ⚠️ It would also be aimed at the smaller half. Even at 10 000 cards, five
    /// `cards(in:)` calls are 4.3 ms of that 9.0 ms — the rest is `groupByRepo`
    /// and `shippingLog`, which the proposal does not cache. If this ever has to
    /// get cheaper, that is where to look, and the table above is to be re-run
    /// first on the board that actually hurt.
    ///
    /// Debug is slower — 2.5× on `cards(in:)`, 1.6–2.0× on a pass, so 22 µs and
    /// 376 µs at 100 cards — and debug is what `swift test` and a bare
    /// `./Scripts/build-app.sh` give you. A board that feels slow is worth
    /// re-measuring in release before that is believed.
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

    /// The repository a **run** belongs to, which a card cannot answer for: an
    /// analysis run has no card, and it is the kind Operations exists to show.
    public func repo(id: UUID) -> Repo? {
        repos.first { $0.id == id }
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
    /// This is the same `evaluateMove` `BoardService` commits with, so every
    /// `MoveBlock` this function can report — a disabled repo, a repository
    /// Preflight refused, an active run, the same column, a method with no step
    /// for this transition — matches what `commitMove` actually does with it.
    /// Pure by design: the rule engine takes no clock and no I/O precisely so a
    /// view can ask it during layout.
    ///
    /// ⚠️ **That claim was false for one day, and the repair is why `method` is
    /// in `MoveContext`.** Wave 1 first refused an unknown method and a stepless
    /// pack by throwing in `BoardService.makeRun`, *downstream* of
    /// `evaluateMove`. `MoveContext` carried no method, so this function had
    /// nothing to check them against: a BMAD card — BMAD ships no steps by
    /// design — previewed as ready and was refused at commit. It failed closed,
    /// and the board still lied about itself. Both refusals are `MoveBlock`s
    /// now, so drag, `board_move_card` and `board_next` cannot disagree again.
    ///
    /// `makeRun` keeps its two `throw`s as an unreachable floor rather than the
    /// gate — see the comment there.
    public func preview(_ card: Card, to column: ElliotModel.Column) -> MoveOutcome {
        evaluateMove(
            from: card.column,
            to: column,
            card: card,
            context: MoveContext(
                repoIsEnabled: repo(for: card)?.isEnabled ?? false,
                // The persisted verdict, not `repoChecks` — the same value
                // `BoardService` will read when the drop is committed. Reading
                // the in-memory dictionary here would make the caption a second
                // opinion about the drop, which is the one thing `preview`
                // exists not to be.
                repoPreflight: repo(for: card)?.preflightVerdict ?? .notChecked,
                // Same rule, and it was briefly broken: wave 1 first refused an
                // unknown method and a stepless pack by *throwing* in
                // `BoardService.makeRun`, downstream of `evaluateMove`. The
                // caption could not see either, so a BMAD card — BMAD declares
                // no steps at all — previewed as ready and then refused at
                // commit. Carrying the resolution here is what made that
                // sentence above true again.
                method: repo(for: card)?.method ?? MethodCatalog.resolve(nil),
                activeRunID: activeRuns[card.id]?.id,
                allowSideEffects: true,
                // Left uncollected on purpose: the merge really does stop to
                // ask, and the caption says so.
                providedFollowUps: nil,
                // A caption is drawn for somebody who is looking at it, so it
                // previews the move *they* would make. A preview held to an
                // unattended rule would read "not a verified green" at a person
                // who is perfectly entitled to merge, and this runs inside
                // `body` — it cannot read a verdict without doing I/O in layout.
                requiresVerifiedGreen: false,
                prVerdict: nil
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
    /// - Parameter orderIndex: Where the card should land in `column`, when the
    ///   caller already knows. `nil` appends, which is what every caller but a
    ///   cross-column drop means.
    ///
    ///   It travels **with** the move rather than being applied after it (#205).
    ///   `reorder` used to move and then re-read `cards` to confirm the card had
    ///   arrived before placing it — and `cards` has exactly one writer, the
    ///   GRDB observation pump, which nothing sequences against the move. When
    ///   the delivery had not landed the guard was false, the placement was
    ///   dropped, and the card sat in the right column at the wrong index. That
    ///   reads as "it just went to the bottom", not as a bug.
    ///
    ///   ⚠️ The placement was never *late*, it was **lost**: nothing retries a
    ///   guard that has already returned. #205 called the coupling latent on 47
    ///   local samples that never lost; CI lost it twice on two different runs,
    ///   the second time through a 10-second bounded wait that had nothing to
    ///   wait for.
    public func move(
        cardID: UUID, to column: ElliotModel.Column, orderIndex: Double? = nil
    ) async {
        guard let board else { return }
        // Named once. The same origin has to reach `board.move` *and*
        // `armPendingMerge` below — two literals here is how the audit and the
        // confirmation came to disagree about who acted.
        let origin = MoveOrigin.userDrag
        // Captured before the move: by the time `board.move` returns, the
        // card's column and `activeRuns` have both changed, so asking then
        // would describe the world after the act rather than the act.
        let predicted = card(id: cardID).map { Consequence.of(preview($0, to: column)) }
        do {
            let result = try await board.move(
                cardID: cardID, to: column, origin: origin, orderIndex: orderIndex,
                // The drag itself, and `false`: the person who made it is
                // looking at the board. Stated rather than defaulted — see
                // `BoardService.proposeMove`'s ⛔ note for what a defaulted
                // `false` would let a later caller merge by omission.
                requiresVerifiedGreen: false)
            switch result {
            case .moved(let runID):
                refusal = nil
                lastLanded = CardLanding(cardID: cardID, stamp: UUID())
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
                armPendingMerge(cardID: cardID, prNumber: pr, origin: origin)
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
        switch card.column.step(forward: forward) {
        case .to(let target):
            await move(cardID: card.id, to: target)
        case .atEdge(let reason):
            // It used to `return` here. ⌘→ on a Done card was enabled, did
            // nothing, and left no mark — where the same refusal reached by
            // dropping writes one on the card. The keyboard is the only path for
            // someone who cannot drag, and it was the silent one.
            refusal = Refusal(cardID: card.id, message: reason)
            status = reason
        }
    }

    /// What `Card ▸ Advance` and `Card ▸ Move back` should say, and whether they
    /// should be live.
    ///
    /// ⛔ **Calls `preview`; re-derives nothing.** A second copy of the
    /// transition rules is the invariant this project names first, and
    /// `rankNextSteps` exists precisely so the board predicts itself by calling
    /// `evaluateMove` rather than holding an opinion about it. The menu title is
    /// therefore the same sentence the column caption shows for the same move.
    ///
    /// Returned as one value so a caller cannot take the title from here and the
    /// enabled state from somewhere else — the shape that let ⌘→ be enabled on a
    /// card it could not move.
    public func nudgeOffer(forward: Bool) -> NudgeOffer {
        let verb = forward ? "Advance" : "Move back"
        guard let card = selectedCard else {
            return NudgeOffer(title: verb, isEnabled: false, detail: nil)
        }
        switch card.column.step(forward: forward) {
        case .atEdge(let reason):
            // Enabled, deliberately: pressing it is how the reason gets said.
            // Disabling it restores the silence — the reader presses, nothing
            // happens, and nothing explains why.
            return NudgeOffer(title: verb, isEnabled: true, detail: reason)
        case .to(let target):
            let consequence = Consequence.of(preview(card, to: target))
            return NudgeOffer(
                title: "\(verb) — \(consequence.summary)",
                isEnabled: true,
                detail: consequence.summary)
        }
    }

    /// The board's hint line, for the card that is actually selected.
    ///
    /// See ``NudgeOffer`` for why a refused move stays pressable.
    ///
    /// It read a flat "⌘→ advance · ⌘← back · esc deselect" for every card,
    /// including the ones where ⌘→ does nothing at all.
    public var selectionHint: String {
        guard selectedCard != nil else { return "↑↓←→ pick a card" }
        let forward = nudgeOffer(forward: true)
        return "⌘→ \(forward.detail ?? "advance") · ⌘← back · esc deselect"
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
            // Crossing columns is a move — it may file an issue, open a pull
            // request or merge one — and the placement rides along with it
            // rather than chasing it. One call, one write, and no re-read of
            // observed state (#205).
            //
            // ⛔ This used to be `await move(…)` followed by
            // `guard refusal == nil, card(id: cardID)?.column == destination`,
            // and that guard was the defect. `card(id:)` reads `cards`, whose
            // only writer is the GRDB observation pump; nothing sequences that
            // pump against the move. When the delivery had not arrived the
            // guard was false and the placement was **dropped for good** —
            // nothing retries a guard that has already returned.
            //
            // A refused move still places nothing, and now for a structural
            // reason instead of a second guard kept in step by hand:
            // `commitMove` writes `orderIndex` only in its two moved cases, so
            // `.blocked` and `.needsInput` write no row at all.
            //
            // ⚠️ `p`/`n` are the destination column's neighbours as they stand
            // *before* the move. That index is still right afterwards because
            // `commitMove` does not renumber neighbours — an invariant this
            // branch now depends on, and `neighboursAreNotRenumberedByAMove`
            // is what keeps it true.
            await move(
                cardID: cardID, to: destination,
                orderIndex: CardReorder.index(previous: p, next: n))
            return
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
    ///
    /// - Parameter origin: Who asked for the merge. **Not defaulted**, for the
    ///   same reason `BoardService.move`'s `requiresVerifiedGreen` is not: the
    ///   caller that arms a merge is the only one who knows whose act it is,
    ///   and a default is exactly what stops the compiler catching the one who
    ///   forgot. It travels on `PendingMerge` to the button.
    func armPendingMerge(cardID: UUID, prNumber: Int, origin: MoveOrigin) {
        selectedCardID = cardID
        showingInspector = true
        pendingFollowUps = PendingMerge(cardID: cardID, prNumber: prNumber, origin: origin)
    }

    /// Abandons a merge the user decided against, without moving the card.
    public func cancelPendingMerge() {
        pendingFollowUps = nil
    }

    /// `origin` is a parameter and not `.userDrag`, which is what it used to be
    /// for every caller. The confirmation is a *button*, not an actor: whoever
    /// armed the merge is who made it, and that is what `moveAudit` records and
    /// `MoveOrigin.historyLabel` prints.
    public func confirmMerge(cardID: UUID, followUps: [String], origin: MoveOrigin) async {
        guard let board else { return }
        pendingFollowUps = nil
        do {
            let result = try await board.move(
                cardID: cardID, to: .done, origin: origin, followUps: followUps,
                // The one merge a human performs by hand, having just typed the
                // follow-ups into the panel. `false` is the whole point of the
                // field being named for the rule rather than for the caller.
                //
                // ⛔ It is a claim about *this* caller, and this method now has
                // an `origin` it did not have — so the claim is only still true
                // while every path here ends at the Merge button. Threading the
                // origin does not make the gate travel with it: an `origin` says
                // who asked, `requiresVerifiedGreen` says what may be skipped,
                // and `MoveContext.requiresVerifiedGreen` is explicit that the
                // second is never derived from the first.
                //
                // So the day a caller with nobody watching reaches this funnel —
                // an auto-dev session confirming its own merge — this `false`
                // becomes *its* claim by inheritance, which is precisely the
                // "merge by omission" `BoardService.proposeMove` refuses to
                // allow by defaulting. That caller must bring the value with it
                // (a parameter here, no default), not accept this one.
                requiresVerifiedGreen: false
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

    /// Files the story being written, and decides what that means for the face.
    ///
    /// ⛔ **The view does not branch on the outcome, because it cannot see one.**
    /// This is the shape #313 is about: `createCard` swallowed every failure
    /// (`_ = try? …`, and a `guard let board else { return }` that did nothing at
    /// all), and the caller closed the console on the next line regardless — so a
    /// refused create looked exactly like a successful one and took a full user
    /// story with it. Returning `Bool` and asking the view to check it would fix
    /// today's caller and leave tomorrow's free to forget; taking the whole act —
    /// read the draft, file it, clear or explain — removes the decision from the
    /// view entirely. There is no longer a create-a-card method a view can call
    /// and get wrong.
    ///
    /// ⚠️ It reads ``newCardDraft`` and ``newCardRepo`` rather than taking them
    /// as arguments, and that is the same removal one step further: a caller that
    /// could pass a *different* draft could file a story the reader cannot see,
    /// and a caller that could pass a repository id could file against one the
    /// picker never offered.
    ///
    /// Every path either files or explains. `BoardService.createCard` stays the
    /// funnel; nothing here writes a card, and nothing here touches a column.
    public func addStoryToBacklog() async {
        clearNewStoryRefusal()

        guard let repo = newCardRepo else {
            refuseNewStory("No repository is registered, so there is nowhere to file this story.")
            return
        }
        // The same expression the Add button is disabled by, so what is judged
        // fileable is what gets filed (#202's rule, one screen over). Unreachable
        // through the button today — which is exactly the claim `isBlocking` made
        // for four views and no rule.
        guard newCardDraft.isValid else {
            refuseNewStory("A story needs a board label and a complete user story before it can be filed.")
            return
        }
        guard let board else {
            refuseNewStory("The board is not ready yet, so nothing was filed.")
            return
        }

        do {
            _ = try await board.createCard(
                repoID: repo.id,
                // `trimmedTitle`, not `title` — see `CardDraft.trimmedTitle`: the
                // gate and the write are one expression (#202).
                title: newCardDraft.trimmedTitle,
                body: newCardDraft.body,
                story: newCardDraft.story,
                labels: newCardDraft.labels
            )
            clearNewStory()
            closeConsole()
        } catch {
            refuseNewStory("Could not file the story: \(error.localizedDescription)")
        }
    }

    /// Deletes a card, and says so when it cannot.
    ///
    /// It was `try? await board?.deleteCard(id: id)`: a board that was not ready
    /// and a store that refused the write were both indistinguishable from a
    /// delete that worked, from the Archive's context menu and from the board's
    /// (#313). Through ``status`` rather than a field of its own — unlike
    /// ``newStoryRefusal`` — because there is nothing typed at stake here and no
    /// surface of the act's own to keep it beside: the card the reader tried to
    /// delete is simply still there.
    public func deleteCard(id: UUID) async {
        guard let board else {
            status = "The board is not ready yet; the card was not deleted."
            return
        }
        do {
            try await board.deleteCard(id: id)
        } catch {
            status = "Could not delete the card: \(error.localizedDescription)"
        }
    }

    /// Unlike `deleteCard`, this reports failure where the reader is looking: the
    /// panel that called it still holds the text the user typed, and silently
    /// dropping an edit is worse than saying it was refused.
    public func updateCard(id: UUID, draft: CardDraft) async -> Bool {
        guard let board else {
            // The sheet shows `status` as the reason it refused; leaving the
            // previous one there would blame the wrong thing.
            status = "The board is not ready yet; the edit was not saved."
            return false
        }
        do {
            try await board.updateCard(
                // `trimmedTitle`, not `title` — the same value `isValid` gated
                // on, so what was judged saveable is what gets saved (#202).
                id: id, title: draft.trimmedTitle, body: draft.body, story: draft.story,
                labels: draft.labels
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

    /// How many of a card's runs `refreshRuns` loads.
    ///
    /// Named rather than written inline because the number is only meaningful
    /// beside the note `RunsPane` draws when the read comes back at it: a count
    /// read at its own cap is a floor, not a total, and the two have to move
    /// together or the pane will promise completeness it never had.
    public nonisolated static let runWindow = 20

    public func refreshRuns(cardID: UUID) async {
        runsByCard[cardID] =
            (try? await store?.runs(cardID: cardID, limit: Self.runWindow)) ?? []
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

    /// Discards **one** waiting run.
    ///
    /// The engine could always do this — `cancel` drops the id and writes
    /// `.cancelled` with an `endedAt`, so the launch sweep cannot revive it —
    /// and no UI reached it, which left "Discard all" as the only way to clear
    /// one stuck entry. Nothing new is decided here; this is the missing door.
    ///
    /// Only ever called for a **queued** run. Cancelling a running one is a
    /// SIGTERM and belongs to the band that shows what is running, so the two
    /// are not offered by the same button.
    public func cancelQueued(runID: UUID) async {
        guard let scheduler else { return }
        await scheduler.cancel(runID: runID)
        status = "Discarded 1 queued run. Nothing running was stopped."
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

    /// One clock read, one boundary, both halves.
    ///
    /// ⛔ The `startOfDay` is a `let` on purpose. This runs on every scheduler
    /// update, and calling `Calendar.current.startOfDay(for: Date())` once per
    /// query would put the total and the split on two different days for
    /// whichever refresh straddles midnight — the split would stop adding up to
    /// the total beside it, on the one screen whose subject is money, with
    /// nothing saying so. `BoardStore.daySpend` takes the boundary once so this
    /// cannot be written the other way.
    /// ⚠️ Two guards, not one. It was `guard let store, let scheduler`, which
    /// made the day's figures depend on a scheduler they have nothing to do
    /// with: with one absent, neither was read. They are two facts from two
    /// sources — what the store has recorded, and what the running scheduler is
    /// refusing — and each is now read when its own source exists.
    func refreshSpend() async {
        let startOfDay = Calendar.current.startOfDay(for: Date())
        if let store {
            daySpend = (try? await store.daySpend(since: startOfDay)) ?? .nothing
        }
        if let scheduler {
            isOverDailyCeiling = await scheduler.isOverDailyCeiling()
        }
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

    /// Which repository Up next is showing, and whether it shows blocked rows.
    ///
    /// On `AppModel` rather than in the view, and not because a menu needs it:
    /// the Up next list is on its way to being a pane inside the board window,
    /// and hiding a pane destroys the view. `@State` here would silently reset
    /// the reader's filter every time the pane closed — the lesson the analysis
    /// panel's own state already records.
    public var nextStepsRepoFilter: UUID?
    public var nextStepsShowsBlocked = true

    /// Whether the Up next band is showing the whole ranking or its first few.
    ///
    /// Here for the reason the two above are, and it is the same reason
    /// literally: since #304 Up next *is* a band inside the board window, and
    /// folding the console destroys `OperationsView` and everything under it.
    /// `@State` in the band would collapse the list every time the reader shut
    /// the console — the defect the analysis panel's own state already records,
    /// at one third the scale and therefore easier to miss.
    public var nextStepsExpanded = false

    /// `nextSteps` as the reader asked to see it.
    ///
    /// ⛔ The repository choice filters the **candidates**, so the board is
    /// asked a smaller question rather than given a smaller answer. The blocked
    /// toggle cannot: whether a step is blocked *is* `evaluateMove`'s verdict,
    /// which only exists once the ranking has run — so it is applied after, by
    /// `nextStepsWindow`, which reads that verdict and never forms one.
    ///
    /// `nextSteps` itself stays unfiltered on purpose: it is what `board_next`
    /// answers, and the Operations band summarises the board rather than this
    /// screen's view of it.
    public var nextStepsView: NextStepsWindow {
        let candidates = nextCandidates(
            cards: nextStepsRepoFilter.map { id in cards.filter { $0.repoID == id } } ?? cards,
            repos: repos,
            activeRunIDs: activeRuns.mapValues(\.id)
        )
        return nextStepsWindow(rankNextSteps(candidates), showsBlocked: nextStepsShowsBlocked)
    }

    /// The repositories worth offering as a filter — those with a card the board
    /// could advance. Offering one that can only ever answer "nothing" is a
    /// choice that punishes the reader for making it.
    public var nextStepsRepoChoices: [Repo] {
        let live = Set(nextSteps.map(\.card.repoID))
        return repos.filter { live.contains($0.id) }.sorted { $0.nameWithOwner < $1.nameWithOwner }
    }

    /// The chosen repository's name, or nil when nothing is chosen **or** the
    /// choice no longer names a repository the board knows.
    ///
    /// The second half is the distinction four MCP tools each had to be taught
    /// separately: an unknown repository is not "no filter". Here it decides
    /// whether an empty list says "this repository has nothing" or "the filter
    /// points at a repository that is gone".
    public var nextStepsRepoFilterName: String? {
        nextStepsRepoFilter.flatMap { id in repos.first { $0.id == id }?.nameWithOwner }
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

    // MARK: - The labels a repository has

    /// What is currently known about `repoID`'s labels.
    ///
    /// `.notAsked` until a lookup has actually run — **not** `.unavailable`,
    /// which is a claim that `gh` was asked and did not answer. It read
    /// `.unavailable` until code review caught it, and the cost was the editor
    /// asserting *"gh did not answer for this repository"* for the whole
    /// duration of every healthy lookup, and for ever on a board whose
    /// `toolConfig` is still nil.
    public func labels(for repoID: UUID) -> RepositoryLabels {
        repoLabels[repoID] ?? .notAsked
    }

    /// Reads a repository's labels through `gh`, for the card editor's picker.
    ///
    /// One `gh label list` per open, not per keystroke, and it does **not**
    /// cache a failure as an answer — `RepositoryLabels(ghAnswer:)` maps a
    /// throw to `.unavailable`, so the next open asks again rather than
    /// remembering that the network was down once.
    ///
    /// Nothing here refuses anything. A card may ask for a label this call
    /// could not confirm; the editor marks it, and the card keeps recording
    /// what someone asked for. That is criterion 6, and it is why this is a
    /// read and not a validator.
    public func loadLabels(for repoID: UUID) async {
        guard let toolConfig, let repo = repos.first(where: { $0.id == repoID }) else { return }
        let gh = GHClient(config: toolConfig)
        let answer = try? await gh.labels(repo: repo.nameWithOwner)
        repoLabels[repoID] = RepositoryLabels(ghAnswer: answer)
    }

    // MARK: - Repos

    /// Preflight's *Add a repository…*, which is a **registration** plus what is
    /// this screen's own: select it, check it, import its work.
    ///
    /// ⛔ It used to be a second implementation of registering, and the two
    /// stored different rows for the same directory — this one wrote no
    /// `visibility` and never verified a `.git`. Since `visibility` is what
    /// `expectedPath` uses to decide where a clone belongs, a repository could
    /// be reported misplaced or silently exempted according to *which button*
    /// had registered it. It goes through `RepoRegistryService.register` now,
    /// the same call `RepoFix.register` makes.
    ///
    /// ⚠️ Not through `apply(_ fix:)`, deliberately: that is the Repositories
    /// page's act and ends in `refreshRepoRows()`, a portfolio-wide sweep with a
    /// `git fetch` per clone. Adding one repository from Preflight should not
    /// cost that.
    public func addRepo(path: String) async {
        guard let store, let registry else { return }
        let outcome = await registry.apply(.register(path: path), layout: layout)
        // Said under the button, not only in `status`, which is on another
        // screen. A refusal that leaves no mark reads exactly like a success.
        lastAddRepoOutcome = FixOutcome(detail: outcome.detail, succeeded: outcome.succeeded)
        status = outcome.detail
        guard outcome.succeeded, let repo = try? await store.repo(path: path) else { return }
        selectedRepoID = repo.id
        await refreshRepoChecks()
        await importIfNeeded(repoID: repo.id)
    }

    /// What the last *Add a repository…* did, for the sentence under the button.
    public private(set) var lastAddRepoOutcome: FixOutcome?

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
        guard let registry, applyingFix == nil else { return }
        // Raised around the *fix*, not around the refresh that follows it. It
        // used to be raised only inside `refreshRepoRows()`, so for the whole of
        // a `gh repo clone` — bounded at 600 seconds — the page was
        // indistinguishable from idle: every `.disabled(model.isReconciling)`
        // button stayed live, and a second press or a Move on another row could
        // interleave with a directory relocation.
        applyingFix = fix
        let outcome = await registry.apply(fix, layout: layout)
        status = outcome.detail
        // ⛔ Cleared before the refresh, not after. `refreshRepoRows()` guards on
        // `!isReconciling` and takes minutes of its own; holding this across it
        // would disable the page for a sweep that is not the fix.
        applyingFix = nil
        await refreshRepoRows()
        // After the refresh, which clears it: this is the sentence the page
        // itself shows, and `status` is on a different screen.
        lastFixOutcome = FixOutcome(detail: outcome.detail, succeeded: outcome.succeeded)
    }

    /// The fix running right now, or nil.
    ///
    /// A `RepoFix?` rather than a second `Bool`, because the page has to say
    /// *which* act it is waiting on — "Cloning phmatray/Elliot…" is the whole
    /// difference between a slow page and a broken one — and because the
    /// one-at-a-time rule `RepoRegistryService` documents is then enforced by
    /// the same value that renders it.
    public private(set) var applyingFix: RepoFix?

    /// Whether the page must not start anything: a fix is running, or the
    /// portfolio sweep is. Asked once so a button cannot consult half of it.
    public var isRepoWorkInFlight: Bool { applyingFix != nil || isReconciling }

    /// What is happening, in the fix's own words. The wording lives beside
    /// `RepoFix.label` in `ElliotModel`, so the verb on the button that started
    /// it and the verb in the header cannot drift apart.
    public var applyingFixSentence: String? { applyingFix?.runningSentence }

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
    /// Re-imports one repository, or everything the picker is showing.
    ///
    /// `repoID` is what the banner's Retry passes. Each banner row names **one**
    /// repository and one `gh` message, and its button re-imported every
    /// repository on the board whenever the picker said "All repositories" —
    /// serially, with `isImporting` disabling every other row's Retry for the
    /// duration. The banner exists precisely because a failure written into
    /// `status` was overwritten seconds later; a Retry that touches everything
    /// undoes half of that scoping.
    ///
    /// ⚠️ `repoID` overrides the picker rather than intersecting with it. The
    /// banner is scoped to what the picker shows, so the two cannot disagree —
    /// and a row a reader can see is a row whose button must mean that row.
    public func refreshFromGitHub(repoID: UUID? = nil) async {
        guard let importer, !isImporting else { return }
        let scope = repoID ?? selectedRepoID
        let targets = scope.flatMap { id in repos.filter { $0.id == id } } ?? repos
        // An id that names no repository is **not** "no filter" — the collapse
        // that four MCP tools each had to be taught separately, and which here
        // would turn one row's Retry into a whole-board import. It is also not a
        // silent no-op: this button was pressed on purpose.
        guard !targets.isEmpty else {
            if scope != nil {
                status = "That repository is no longer on the board."
            }
            return
        }

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

    /// What the **Dismissed** face draws: the repositories in view, each with
    /// its own rows already ordered.
    ///
    /// "In view" is the board's picker, exactly as ``clearDismissals()`` and
    /// ``visibleImportFailures`` already read it — one repository selected shows
    /// its own rows, *All repositories* shows every one, grouped.
    public var visibleDismissals: [DismissalGroup] {
        DismissalDigest.groups(dismissedItems, repoID: selectedRepoID)
    }

    /// The door in the status bar, or `nil` when there is nothing to open it
    /// for.
    ///
    /// Counts what is **in view**, not the whole table, so the figure names
    /// exactly the rows the face it opens will show and the act beside them —
    /// *Forget dismissed items* — would clear.
    public var dismissedFigure: String? {
        DismissalDigest.figure(
            count: DismissalDigest.rows(dismissedItems, repoID: selectedRepoID).count)
    }

    /// Undoes **one** suppression, so the next refresh may bring that item back
    /// and nothing else changes.
    ///
    /// ⛔ **Creates no card.** The importer creates cards; a second path that
    /// inserted one here would be the write path `BoardService` exists to
    /// prevent, and it would insert a card carrying what the row remembered
    /// rather than what GitHub says now. The row goes; the refresh does the
    /// rest.
    ///
    /// ⚠️ `importSession.forget` is not housekeeping — it is what makes the act
    /// visible. Without it a repository whose one unattended attempt is already
    /// spent picks nothing up until the reader presses Refresh, so *Restore*
    /// appears to do nothing at all. `clearDismissals` below has called it for
    /// exactly this reason since it was written.
    public func restoreDismissal(_ item: DismissedItem) async {
        guard let store else { return }
        do {
            try await store.undismiss(item.ref, repoID: item.repoID)
        } catch {
            status = "Could not restore \(item.ref.label): \(error.localizedDescription)"
            return
        }
        importSession.forget(repoID: item.repoID)
        // `item.ref.label` is a `String`, and `status` is rendered by a `Text`
        // built from a variable — so the number stays "PR #1234" rather than
        // being group-separated into "PR #1.234" (`MergeConfirmation`).
        status = "\(item.ref.label) restored — refresh to bring it back."
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

    /// Chooses the method a repository runs — the one setting on that page that
    /// changes what a drag *executes*.
    ///
    /// It re-runs this repository's checks rather than only saving, and that is
    /// the point rather than tidiness: the project-requirement warnings, the
    /// plugin the profile hint names and — for an id no pack answers — the
    /// `.fail` that blocks the board are all functions of the value just
    /// written. Leaving them until the next sweep would show the previous
    /// method's verdict beside the new method's name, which is a screen lying
    /// about what will happen on the next drag.
    ///
    /// Only **this** repository's, through `record`, exactly as `apply(_ fix:)`
    /// does: pressing one menu item must not start a full-board sweep at ~6
    /// subprocesses per repository with no progress and no re-entrancy guard.
    ///
    /// ⛔ The save is not `try?`, unlike `setRepoEnabled` directly above. If it
    /// is lost the menu shows a method the store does not hold, and the next
    /// drag runs the old one — a screen disagreeing with the board about which
    /// commands a card will spawn, silently. A dropped `isEnabled` is visible
    /// on the next sweep; a dropped `methodID` is not.
    ///
    /// ⛔ The method is set on the row **re-read here**, not on the `repo` the
    /// view was rendering — the rule `setRunTerms` below states and `record`
    /// states one way further down. This shipped as `var updated = repo`, a
    /// whole-row write built from a view snapshot, and the merge is what made it
    /// dangerous rather than untidy: `Repo` has since gained `permissionMode`,
    /// `extraAllowedTools` (#333) and `labelPolicy` (#199). Tighten a
    /// repository's run terms, then pick a method from the picker still holding
    /// the pre-tightening snapshot, and the picker puts `bypassPermissions`
    /// back — a control that silently re-arms an unattended agent. A failed read
    /// refuses rather than writing the stale copy anyway: "I could not find out"
    /// is not "nothing has changed".
    public func setRepoMethod(_ repo: Repo, methodID: String?) async {
        guard let store else {
            status = "Elliot is still starting; try again in a moment."
            return
        }
        let updated: Repo
        do {
            guard try await store.saveRepoMethod(id: repo.id, methodID: methodID) else {
                // Reachable rather than theoretical, for `setRunTerms`' reason:
                // Preflight carries a Forget button, and the row can go while
                // the menu holding this picker is open. The store answers this
                // from the `UPDATE`'s own row count, so there is no second call
                // that could disagree with the first.
                status = "\(repo.displayName) is no longer registered."
                return
            }
            // Read **back**, never `repo` with the field poked into it. The
            // checks below are computed from a whole row — the path, the
            // taxonomy, the run terms — and the copy this menu was rendering may
            // have aged. Missing now means the row went between the write and
            // this read, which costs nothing: there is no repository left to
            // check.
            guard let current = try await store.repo(id: repo.id) else { return }
            updated = current
        } catch {
            status = "Could not set the method for \(repo.displayName): "
                + error.localizedDescription
            return
        }

        guard let toolConfig else { return }
        let preflight = PreflightService(
            environment: LoginShellEnvironment(
                variables: toolConfig.environment, capturedVia: "session"
            ),
            config: toolConfig
        )
        // `updated`, never `repo`: the checks must be read against the method
        // just written, and `record` compares the fresh verdict to the one on
        // the row it is handed — the stale copy would compare against a verdict
        // computed for the *previous* method and could skip the write.
        await record(await preflight.repoChecks(updated), for: updated)
    }

    /// Change one repository's run terms — the only writer either field has.
    ///
    /// Both are v1 columns, read at spawn and reported by `board_list_repos`,
    /// and until #333 nothing ever assigned them: every registration took
    /// `bypassPermissions` and `[]` permanently, so a drag in *any* registered
    /// repository started `claude -p` accepting every tool call and asking
    /// nobody. Preflight already carries the other two brakes on what that
    /// costs — `Runs at once` and `Spending` — and this is the only one that
    /// bounds what a run may *do* rather than how much of it there may be.
    ///
    /// ⛔ Not `try?`, unlike ``setRepoEnabled(_:enabled:)`` beside it. A lost
    /// write here leaves the row on `bypassPermissions` while the picker shows
    /// the tightened value — the screen and the spawn disagreeing about a
    /// safety control, silently, which is the whole failure mode. The sentence
    /// follows `record`'s precedent and its comment.
    ///
    /// The edit arrives as one ``RunTermsEdit`` rather than two optional
    /// parameters, so "called with neither" is not a shape this function can be
    /// handed, and `applied(to:)` normalises on the way in.
    ///
    /// The edit is applied to the row **re-read here**, not to the `repo` the
    /// view was rendering. Otherwise this is the hazard `saveRepoPreflight`
    /// exists to close, pointed the other way: a whole-row write built from a
    /// copy that may have aged. A failed read is a refusal and not a licence to
    /// write the stale copy anyway — "I could not find out" is not "nothing has
    /// changed".
    public func setRunTerms(_ repo: Repo, _ edit: RunTermsEdit) async {
        guard let store else { return }
        do {
            guard let current = try await store.repo(id: repo.id) else {
                // Preflight carries a Forget button, so this is reachable
                // rather than theoretical: the row can go while the disclosure
                // holding its picker is open.
                status = "\(repo.displayName) is no longer registered."
                return
            }
            try await store.saveRepo(edit.applied(to: current))
            status = edit.sentence(for: current)
        } catch {
            status = "Could not change \(repo.displayName)'s run terms: "
                + error.localizedDescription
        }
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

    /// Re-reads every registered repository's checks, eight at a time.
    ///
    /// ⛔ **One sweep at a time.** The launch sweep and *Check again* reach this
    /// same method, and a second pass started over the first would run every
    /// `gh` and `git` call twice for nothing and land two readings per
    /// repository in an order neither caller chose. The guard is the flag the
    /// button is disabled by, so the refusal is visible rather than silent.
    ///
    /// Eight in flight, matching `RepoRegistryService.probe` and
    /// `repo-audit/repo_sync.py`: one repository costs about six subprocesses,
    /// one of which is a networked `gh label list`, and this is the screen most
    /// likely to meet GitHub's rate limit. Serial, it was tens of seconds on a
    /// handful of repositories with nothing on screen saying so.
    ///
    /// ⚠️ It does **not** carry `probe`'s input-order guarantee, and that is a
    /// decision rather than an omission: `probe` returns an array the page draws
    /// in place, so completion order would make every refresh jump. These land
    /// in a dictionary keyed by repository and are drawn in `repos` order
    /// whatever happens, so arrival order is not observable — and recording each
    /// as it lands is what makes the screen fill in progressively instead of all
    /// at once at the end.
    public func refreshRepoChecks(using service: PreflightService? = nil) async {
        // The tool configuration is what *builds* the default service, so a
        // caller that brought its own does not need one. Written this way round
        // rather than as a leading `guard let toolConfig`, which made the whole
        // sweep — the guard, the fan-out, the recording — unreachable from a
        // test even with a service in hand.
        let preflight: PreflightService
        if let service {
            preflight = service
        } else {
            guard let toolConfig else { return }
            preflight = PreflightService(
                environment: LoginShellEnvironment(
                    variables: toolConfig.environment, capturedVia: "session"
                ),
                config: toolConfig
            )
        }
        guard !isCheckingRepos else { return }
        isCheckingRepos = true
        defer { isCheckingRepos = false }
        // Cleared on an explicit refresh, the way `reloadRepoRows` clears the
        // Repositories page's. A sentence about a fix, still sitting under a row
        // the user has just re-checked, describes a board state that may no
        // longer hold.
        lastCheckFix = nil
        // Captured once: `repos` is observed and can be republished mid-sweep,
        // and an index into a collection that changed under the task group is a
        // reading recorded against the wrong repository.
        let targets = repos
        await withTaskGroup(of: (Int, [CheckResult]).self) { group in
            let window = min(8, targets.count)
            for index in 0..<window {
                group.addTask { (index, await preflight.repoChecks(targets[index])) }
            }
            var next = window
            while let (index, results) = await group.next() {
                await record(results, for: targets[index])
                if next < targets.count {
                    let pending = next
                    group.addTask { (pending, await preflight.repoChecks(targets[pending])) }
                    next += 1
                }
            }
        }
    }

    /// Records a sweep's results in the two places that need them.
    ///
    /// `repoReadings` is what the screens read; `Repo.preflight` is what the
    /// rule engine reads, through the row `BoardService.proposeMove` already
    /// loads. One method rather than two assignments at each of the two sweep
    /// sites, because the whole defect being fixed here is a verdict that
    /// existed in one place and was unreachable from the other — writing it
    /// twice by hand is how it would become unreachable again.
    ///
    /// The reading carries the moment it was taken, and this is the only thing
    /// that builds one: a caller cannot record checks without recording that
    /// somebody looked.
    ///
    /// The write is skipped when the verdict has not moved. The repo table is
    /// observed, so an unconditional save on every sweep would republish every
    /// row and reload the board for nothing.
    private func record(_ results: [CheckResult], for repo: Repo) async {
        let reading = PreflightReading(results: results, checkedAt: .now)
        repoReadings[repo.id] = reading
        let verdict = reading.verdict
        guard repo.preflightVerdict != verdict, let store else { return }
        do {
            // `saveRepoPreflight`, not `saveRepo(updated)`. `repo` was captured
            // before `preflight.repoChecks(repo)`, which shells out to `gh` and
            // `git` — seconds, not microseconds — so writing the whole row back
            // reverts anything saved during that window. Since #333 that window
            // can swallow a repository's run terms, and a safety control that
            // quietly returns to `bypassPermissions` while the screen shows
            // otherwise is worse than none.
            try await store.saveRepoPreflight(id: repo.id, verdict: verdict)
        } catch {
            // Not `try?`. If this write is lost the board silently goes on
            // permitting moves in a repository Elliot has just diagnosed as
            // broken — which is the exact failure this whole change removes, so
            // it is the last thing that should fail quietly.
            status = "Could not record Preflight's verdict for \(repo.displayName): "
                + error.localizedDescription
        }
    }

    /// Why this repository's cards cannot move, and where to read about it — or
    /// `nil` when they can.
    ///
    /// ⛔ **Decided on `Repo.preflightVerdict`, the value `evaluateMove` reads,
    /// never on the reading.** This was `PreflightService.isBlocking(repoChecks[…]
    /// ?? [])`, which is a *second opinion about the drop* — the mistake
    /// `preview` names in as many words one screen over. The two genuinely
    /// disagree for the first seconds of every launch: the verdict is persisted
    /// and the readings are not, so a repository that failed last session
    /// refused every drag while its cards drew no badge at all.
    ///
    /// The reading supplies only *which* check, when there is one to name.
    ///
    /// `allowsMoves` rather than `== .failing`, so that the day `notChecked`
    /// starts refusing a move — which `PreflightState` says is one line in
    /// `evaluateMove` — the badge follows it instead of having to be found.
    func blockedBadge(for repo: Repo) -> BlockedBadge? {
        guard !repo.preflightVerdict.allowsMoves else { return nil }
        return BlockedBadge(repoID: repo.id, check: repoReadings[repo.id]?.blocking)
    }

    /// The repository Preflight should scroll to when it next appears.
    ///
    /// Written by ``openPreflight(_:)`` and read by `PreflightView`. It is not
    /// cleared once honoured, deliberately: re-opening Preflight lands on the
    /// last finding a card sent the reader to, which is where they were.
    private(set) var preflightFocus: UUID?

    /// Which check disclosures the reader has opened or closed.
    ///
    /// ⚠️ **On the model rather than in `PreflightView`, and not for tidiness.**
    /// Preflight is a console face, so folding the console destroys the view and
    /// takes its `@State` with it — the lesson `AnalysisPanelView` paid for with
    /// four values. And a card's badge has to be able to open a disclosure in a
    /// screen that is not on screen yet, which state living inside that screen
    /// cannot do.
    private var checkExpansion: [CheckAddress: Bool] = [:]

    /// Whether this check's disclosure is open.
    ///
    /// Open on arrival when the check is failing — that is the one you came for
    /// — and the reader's own collapse wins afterwards. The rule is here rather
    /// than in the binding because `swift test` can hold this and cannot hold a
    /// `Binding` built inside a `body`.
    func isCheckExpanded(_ address: CheckAddress, failing: Bool) -> Bool {
        checkExpansion[address] ?? failing
    }

    func setCheckExpanded(_ address: CheckAddress, _ open: Bool) {
        checkExpansion[address] = open
    }

    /// Takes the reader from a card to the finding that is holding it.
    ///
    /// Three acts, one call, because two of them without the third is a
    /// no-op the reader has to explain to themselves: unfolding Preflight,
    /// aiming it at the repository, and opening the check. Only the scrolling
    /// happens in the view, which is the one part `swift test` cannot see.
    func openPreflight(_ badge: BlockedBadge) {
        console.show(.preflight)
        preflightFocus = badge.repoID
        if let address = badge.address { setCheckExpanded(address, true) }
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
        let outcome = await preflight.apply(fix, repo: repo, board: board, store: store)
        lastCheckFix = (fix.id, FixOutcome(detail: outcome.detail, succeeded: outcome.succeeded))
        // A seeded card needs no reload here: the board observes the store, so
        // it arrives the way every other card does. Only the checks have to be
        // asked again — and only **this** repository's.
        //
        // `refreshRepoChecks` loops every registered repository at ~6
        // subprocesses each, plus a networked `gh label list` per repo since
        // #170. Pressing one button should not start a full-board sweep with no
        // progress and no re-entrancy guard.
        // Through `record` so the repository row learns the new verdict too: a
        // fix that repairs the failing check must clear the block here, not at
        // the next full sweep. That is what bounds the staleness this column
        // trades for being readable by the rule engine.
        await record(await preflight.repoChecks(repo), for: repo)
    }

    // MARK: - Analysis

    /// Which repository the analysis panel is about — the one answer, read by
    /// the header, the run rows, the evidence links and the Start button.
    ///
    /// While a session is open it is that analysis's **own** repository, and
    /// moving the board's picker cannot change it. With nothing open the panel
    /// is a setup form aimed at whatever is picked, which is what Start will
    /// target — that fallback is the whole of the second half.
    ///
    /// ⛔ The panel used to compute this itself as
    /// `repos.first { $0.id == selectedRepoID }`, five times over, and the
    /// picker has nothing to do with which repository an open analysis read
    /// (#213). Read this rather than reaching for `selectedRepoID` again: a
    /// second expression for the same question is how the two answers get to
    /// disagree, and `AnalysisPanelViewSourceTests` fails if one comes back.
    public var analysisRepoID: UUID? { analysis?.repoID ?? selectedRepoID }

    /// ``analysisRepoID`` resolved against the registered repositories.
    ///
    /// `nil` when the analysis's repository has since been forgotten — the
    /// header renders `…` and evidence chips go un-clickable, which is strictly
    /// better than the silent borrowing of whichever repository happened to be
    /// picked. It deliberately does **not** fall through to the picker: an
    /// unresolvable subject is a different fact from an absent one.
    public var analysisRepo: Repo? {
        analysisRepoID.flatMap { id in repos.first { $0.id == id } }
    }

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
    /// ⚠️ Reads ``selectedRepoID``, not ``analysisRepoID``, and that is not an
    /// oversight: it gates **Start**, which renders only in setup — the branch
    /// where the two are equal by construction — and its first sentence is what
    /// tells the reader *which* repository Start would target. Pointing it at
    /// ``analysisRepoID`` would compile, read as tidier, and quietly make it
    /// answerable for a session it has no business refusing.
    /// ⚠️ **An ``AnalysisRefusal`` rather than a `String` since #294**, so the
    /// footer can offer the remedy the sentence names instead of describing it —
    /// the shape `CheckResult.fixes` (#170) and `RepoRow.fixes` (#12) already
    /// have. The three sentences are unchanged, and the ordering that used to
    /// live here moved into
    /// ``AnalysisRefusal/decide(subject:registered:blocked:)`` so a test can reach
    /// it without an `AppModel`. Internal rather than `public` for the same reason
    /// ``blockedBadge(for:)`` and ``openPreflight(_:)`` are: it now names types no
    /// other module has any use for.
    /// ⚠️ **The rule underneath is ``ElliotModel/UnattendedStartRefusal``**, which
    /// `AnalysisService` and the appraisal consult too — an appraisal passes
    /// through no transition, so `evaluateMove` was never a place it could be
    /// asked. This property renders that answer and adds the remedy; it does not
    /// decide it, and it must not grow a second opinion about it.
    var analysisRefusal: AnalysisRefusal? {
        let subject = selectedRepoID.flatMap { id in repos.first { $0.id == id } }
        return AnalysisRefusal.decide(
            subject: subject,
            registered: repos,
            // ⚠️ The **remedy**, not the gate: `decide` reads the persisted
            // verdict off the row it was handed, which is the value `blockedBadge`
            // decides on too, so the sentence and the card's badge cannot
            // disagree about one repository. What the badge adds is *which* check
            // to send the reader to. Reading the in-memory checks to gate on
            // would answer "fine" for the whole of every launch in a repository
            // whose every drag was being refused — and an analysis is eight
            // unattended runs.
            blocked: subject.flatMap { blockedBadge(for: $0) })
    }

    /// Performs one of ``AnalysisRefusal``'s fixes.
    ///
    /// ⛔ **Deterministic, every case, and no agent** — the argument is written
    /// out on ``AnalysisFix``. Two of the three are a single assignment and the
    /// third is a store write; reaching `claude -p` from here would put a second
    /// place that starts an unattended run outside the board.
    ///
    /// ⚠️ **No `FixOutcome`, unlike ``apply(_:)`` for a `CheckFix`, and that is a
    /// decision rather than an omission.** A `CheckFix` reports because its
    /// finding is re-read over the network and can half-succeed. These three are
    /// judged by the refusal itself, which is recomputed from ``repos`` on every
    /// render: a fix that lands takes its own sentence and its own button off the
    /// screen, and one that does not leaves both exactly where they were. A
    /// sentence claiming *switched on* under a refusal still reading *switched
    /// off* would be a second opinion about one fact.
    func apply(_ fix: AnalysisFix) async {
        switch fix {
        case .analyse(let repoID, _):
            // Guarded rather than assigned blind. The offer was built from
            // `repos` while the footer rendered, so a repository forgotten
            // between then and the press would point the board at a
            // registration that is gone — an empty board under a phantom name,
            // which is what `showBoard(repoID:)` refuses one screen over.
            guard repos.contains(where: { $0.id == repoID }) else { return }
            selectedRepoID = repoID
        case .enable(let repoID, _):
            // Re-read here, never carried in the fix: `setRepoEnabled` writes
            // the whole row, so the copy it is handed has to be the current one.
            guard let repo = repos.first(where: { $0.id == repoID }) else { return }
            await setRepoEnabled(repo, enabled: true)
        case .showPreflight(let badge):
            openPreflight(badge)
        }
    }

    /// The lenses already reading, as last read — private, so nothing can draw
    /// it without going through the two scoped accessors below.
    ///
    /// ⛔ **Not a `Set<AnalysisAngle>`, and not readable without naming a
    /// repository.** ``startFailure`` is computed against ``selectedRepoID`` for
    /// exactly this reason, one sentence over: the panel's subject can move
    /// while a read is in flight, and a value that does not carry the
    /// repository it was read for is a value that will eventually be drawn
    /// under the wrong header with nothing saying so (#213). Here the guard is
    /// `BusyLenses`'s own — it answers with nothing when asked about a
    /// repository it was not read for — so the view never sees a mismatch it
    /// could render.
    private var busyLensReading: BusyLenses?

    /// Re-reads which lenses are busy in the repository the panel is about.
    ///
    /// Called from the panel's `.task`, which is keyed on ``analysisRepoID`` and
    /// cancelled when the panel is hidden. Failure is silence rather than a
    /// banner: this is a courtesy on a screen that already has three things to
    /// say, and losing it costs the reader a hint, not an act — `Start` still
    /// gets its answer from `AnalysisService`.
    public func refreshBusyLenses() async {
        guard let analysisService, let repoID = analysisRepoID else {
            busyLensReading = nil
            return
        }
        let reading = try? await analysisService.busyLenses(repoID: repoID)
        // The picker can have moved while that was in flight. Dropping a
        // mismatched reading here is belt to `BusyLenses`'s braces — the
        // accessors below would refuse it anyway — but it keeps a stale
        // repository's snapshot from sitting in the model waiting for the
        // picker to come back to it.
        guard reading?.repoID == analysisRepoID else { return }
        busyLensReading = reading
    }

    /// How far along the run holding `angle` is, in the repository the panel is
    /// about — or `nil` when that lens is free, unread, or the reading belongs
    /// to another repository.
    ///
    /// ⚠️ **A hint.** It was true when it was read; `AnalysisService.start` is
    /// what decides whether a Start goes. Nothing may be disabled on this.
    public func lensBusy(_ angle: AnalysisAngle) -> LensBusy? {
        busyLensReading?.state(of: angle, in: analysisRepoID)
    }

    /// The armed lenses in the strip's own order.
    ///
    /// One expression, because three places need the same list in the same
    /// order: what Start hands the service, what the footer names in a
    /// sentence, and what the clash check is measured against. It was written
    /// out in the view's Start closure and would have been written out twice
    /// more here.
    public var armedAngles: [AnalysisAngle] {
        AnalysisAngle.allCases.filter(analysisAngles.contains)
    }

    /// The armed lenses the last reading says are already busy — the ones that
    /// would make Start refuse the whole set.
    public var clashingLenses: [AnalysisAngle] {
        busyLensReading?.clashes(with: armedAngles, in: analysisRepoID) ?? []
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
            openAnalysis(started.analysis)
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

    /// Opens `analysis` in the panel.
    ///
    /// ⛔ **Takes the whole `Analysis`, not its id, and that is the fix rather
    /// than a convenience.** An id alone cannot say which repository the
    /// analysis read, so a session opened from one was a session with no
    /// subject — and the panel went looking for one in the board's picker
    /// (#213). Both callers already hold an `Analysis`, so naming the
    /// repository costs nothing and forgetting it stops compiling.
    /// The parameter is `opened` rather than `analysis` on purpose: `analysis`
    /// is also the stored session this method assigns, and a parameter of a
    /// *different* type shadowing it makes every bare mention in the body mean
    /// the opposite of what it reads as.
    public func openAnalysis(_ opened: Analysis) {
        let id = opened.id
        // The failure belongs to a start that did not happen, not to the
        // analysis about to be on screen — including the one picked from the
        // header's *Earlier analyses* menu, which is the path that does not go
        // through `startAnalysis` at all.
        clearStartFailure()
        // One assignment. The outgoing session goes with it, and its
        // observation is cancelled by `ObservationHandle.deinit` rather than
        // by a line here that a sixth member could out-live.
        analysis = AnalysisSession(id: id, repoID: opened.repoID)
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

    /// The *Earlier analyses* menu, scoped to the repository the **panel** is
    /// about rather than to the board's picker (#213) — otherwise it offers a
    /// different repository's history, and opening one of those rows is how the
    /// panel ended up mismatched in the first place.
    ///
    /// Reads ``analysisRepoID``, it does not watch it: the caller re-asks, which
    /// is why the panel's `.task` is keyed on that same value.
    public func recentAnalyses() async -> [Analysis] {
        guard let store else { return [] }
        return (try? await store.analyses(repoID: analysisRepoID, limit: 20)) ?? []
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

    /// Every write to the analysis, funnelled so that none of them can report a
    /// success that did not happen.
    ///
    /// ⛔ **`try? await analysisService?.…` cannot be written correctly**, and
    /// that is why this exists rather than a rule asking people to be careful.
    /// It fails two ways and reports neither: the `try?` discards a `throw`, and
    /// the `?` turns an absent service into a silent no-op *before* the `try?`
    /// is reached. Both were live — ``updateProposal`` closed its editor exactly
    /// as on success (#223), and ``rejectProposals`` went further and asserted
    /// "Rejected N proposals" whichever had happened.
    ///
    /// Returns `nil` when the write landed. The note is **cleared before the
    /// await and set after**, which is `acceptProposals`' rule: replacing one
    /// sentence with another in place reads as nothing having happened.
    private func analysisWrite(
        _ body: (AnalysisService) async throws -> Void
    ) async -> AnalysisWriteFailure? {
        analysis?.note = nil
        guard let analysisService else {
            let failure = AnalysisWriteFailure.serviceUnavailable
            analysis?.note = failure.sentence
            return failure
        }
        do {
            try await body(analysisService)
            return nil
        } catch {
            let failure = AnalysisWriteFailure.refused(error.localizedDescription)
            analysis?.note = failure.sentence
            return failure
        }
    }

    /// Saves an edited proposal, and says whether it saved.
    ///
    /// The return value is the whole fix for #223: the editor closes on `nil`
    /// and stays open otherwise, so a reader is never left believing an edit
    /// landed. A `Void` return could not express that, which is how the silent
    /// dismissal survived.
    @discardableResult
    public func updateProposal(_ proposal: StoryProposal) async -> AnalysisWriteFailure? {
        await analysisWrite { try await $0.updateProposal(proposal) }
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

    /// ⚠️ **This claimed success unconditionally**, and it is the louder half of
    /// #223: the `try?` swallowed the error and the very next line wrote
    /// "Rejected N proposals" whether or not anything had been. A silent failure
    /// leaves a reader guessing; an asserted one leaves them certain and wrong.
    @discardableResult
    public func rejectProposals(ids: [UUID]) async -> AnalysisWriteFailure? {
        let failure = await analysisWrite { try await $0.reject(proposalIDs: ids) }
        analysis?.note = AnalysisWriteFailure.rejectionNote(count: ids.count, failure: failure)
        return failure
    }

    /// Puts rejected proposals back on the list, and says whether they moved.
    ///
    /// Through ``analysisWrite`` like the other three, so an absent service is a
    /// reported failure rather than the silent no-op `analysisService?.…` makes
    /// of it (#223). The note is the one place the two counts meet: `restore`
    /// answers with what the store actually changed, and
    /// ``AnalysisWriteFailure/restorationNote(asked:restored:failure:)`` turns
    /// that into a sentence — so a restore refused because the proposal already
    /// produced a card says so, instead of claiming a success the list will
    /// visibly contradict.
    @discardableResult
    public func restoreProposals(ids: [UUID]) async -> AnalysisWriteFailure? {
        // Written by the closure below rather than returned from it:
        // `analysisWrite` funnels every analysis write and answers with the
        // *failure*, which is the whole of #223's fix. Giving it a generic
        // return would let a caller thread a value out of it and, in doing so,
        // out of the funnel.
        var restored = 0
        let failure = await analysisWrite { restored = try await $0.restore(proposalIDs: ids) }
        analysis?.note = AnalysisWriteFailure.restorationNote(
            asked: ids.count, restored: restored, failure: failure
        )
        return failure
    }

    /// Reads a finished lens's `stories.json` again, from the file Elliot
    /// already kept beside its log (#330).
    ///
    /// Through ``analysisWrite`` like the other four, so an absent service is a
    /// reported failure rather than the silent no-op `analysisService?.…` makes
    /// of it (#223) — and so a refusal (`alreadyHarvested`, `runStillRunning`,
    /// a repository since forgotten) lands in the panel's note instead of
    /// vanishing.
    ///
    /// The runs are refreshed afterwards because the report is what the lens row
    /// draws: without this the row would keep saying `0 kept` beside proposals
    /// that had just appeared in the list below it.
    @discardableResult
    public func reharvest(runID: UUID) async -> AnalysisWriteFailure? {
        let failure = await analysisWrite { _ = try await $0.reharvest(runID: runID) }
        await refreshAnalysisRuns()
        return failure
    }

    /// The angles still working, for the window's header.
    public var runningAngles: [AnalysisAngle] {
        analysis?.runs.filter { !$0.state.isTerminal }.compactMap(\.analysisAngle) ?? []
    }

    // MARK: - Auto-dev

    /// The auto-dev session this launch has run, and what happened to each card.
    ///
    /// ⚠️ **Held through `finished` on purpose.** `Column.naturalNext` returns
    /// `nil` for `.done`, so `rankNextSteps` drops every card in Done — and a
    /// card whose *merge* failed stays in Done carrying a `lastError`. It is
    /// therefore structurally absent from `NextStepsView` and from the Up next
    /// band, and this is the only surface that shows it. Cleared when the next
    /// session starts, which is exactly what ``lastSyncSummary`` does.
    ///
    /// ⛔ **Assigned only by ``adopt(_:engagements:)``**, together with
    /// ``autoDevEngagements`` and ``autoDevEngagedCardIDs``. The argument is
    /// written out there.
    public private(set) var autoDev: AutoDevSession?

    /// One row per engaged card: how many attempts, where it got to, and why.
    public private(set) var autoDevEngagements: [AutoDevEngagement] = []

    /// The engaged cards as a set, so `CardView` asks once per card rather than
    /// rebuilding the set per card.
    ///
    /// Derived from the **session** and not from the rows: the mark has to
    /// appear the instant the session exists, and the rows arrive on their own
    /// clock.
    public private(set) var autoDevEngagedCardIDs: Set<UUID> = []

    public var autoDevTally: AutoDevTally { AutoDevTally.of(autoDevEngagements) }

    /// How many Backlog cards the next session engages.
    ///
    /// ⚠️ On the model, never as `@State` in the band, for the reason the four
    /// analysis fields carry: hiding a view destroys it and every `@State` in
    /// it, and the band lives in a console face the reader folds away.
    public var autoDevCardLimit = 3

    /// Why auto-dev cannot start right now, or `nil` when it can.
    ///
    /// One answer, read by the band's footer and by the Start button — the shape
    /// ``analysisRefusal`` has, and for the same reason: the gate belongs on the
    /// **act**, not on a control's visibility. An unattended session that starts
    /// in a checkout Preflight has already refused is the failure #151 nearly
    /// shipped one panel over, and this one *merges*.
    ///
    /// ⛔ **The repository half is not decided here.** Whether an unattended
    /// agent may start against a repository is one rule —
    /// ``ElliotModel/UnattendedStartRefusal`` — and this is its fourth asker,
    /// after `AnalysisRefusal`, `AnalysisService.start` and the appraisal. That
    /// rule exists precisely because the analysis path's only gate had once been
    /// a computed property on a SwiftUI model; writing `!repo.isEnabled` or
    /// `== .failing` out again here would restore the shape that let
    /// `isBlocking` be asserted in three documents and implemented in none.
    /// `UnattendedStartDelegationTests.theAutoDevScreenAsksTheRule` is what says
    /// so — no behavioural test can, because every value either side of the
    /// delegation is identical.
    ///
    /// What *is* auto-dev's own, and belongs here, is the pair above the rule: a
    /// build with no loop attached, and one session at a time. Neither is a fact
    /// about a repository, so neither could be a case the other three askers
    /// would have to switch over and could never reach — the reason
    /// `.noRepositoryChosen` stayed out of the rule too.
    ///
    /// ⚠️ **The verdict is `repo.preflightVerdict`, the persisted column**,
    /// deliberately the value ``blockedBadge(for:)`` and ``analysisRefusal``
    /// decide on, so the three cannot disagree about one repository. It is *not*
    /// ``repoReadings``: `PreflightReading.verdict(of: nil)` is `.notChecked`,
    /// which admits — so a launch whose persisted verdict is `.failing` and
    /// whose reading has not arrived yet would be **permitted** by the
    /// fresher-looking value. That is the two-valued answer #302 removed from
    /// the screens. A caller that has just swept hands the rule its own reading;
    /// this model has no sweep of its own to be fresher than.
    public var autoDevRefusal: String? {
        if autoDevDriver == nil { return "Auto-dev is not wired into this build yet." }
        if let session = autoDev, session.state != .finished {
            return "A session is already going. Stop it before starting another."
        }
        guard let id = selectedRepoID, let repo = repos.first(where: { $0.id == id }) else {
            return "Pick a single repository to drive."
        }
        return UnattendedStartRefusal.refusal(repo: repo, preflight: repo.preflightVerdict)?
            .sentence
    }

    public func startAutoDev() async {
        // ⛔ **Every arm of this guard is a sentence ``autoDevRefusal`` is
        // already showing beside the control**, recomputed on every render —
        // which is why this one may return in silence where the three commands
        // below may not. `driver` and `repoID` are non-`nil` by construction
        // once the refusal is `nil`: they are the same two values it guards on.
        // An arm that property does not name would be a refused act with
        // nothing on the screen, which is exactly the silence being removed one
        // method down.
        guard autoDevRefusal == nil, let driver = autoDevDriver, let repoID = selectedRepoID
        else { return }
        do {
            // `.automatic`: the band's stepper asks for a count, and the rule
            // that turns a count into a set of cards lives behind the protocol,
            // never here. A view dispatches; it does not judge.
            let session = try await driver.start(
                repoID: repoID, selection: .automatic(limit: autoDevCardLimit))
            adopt(session, engagements: await driver.engagements(sessionID: session.id))
        } catch {
            noteAutoDev(error.localizedDescription)
        }
    }

    /// Engages no further move. The run already going finishes.
    public func pauseAutoDev() async {
        await autoDevCommand("pause") { await $0.pause(sessionID: $1) }
    }

    public func resumeAutoDev() async {
        await autoDevCommand("resume") { await $0.resume(sessionID: $1) }
    }

    /// Ends the session and cancels the run already going.
    ///
    /// The report is **not** cleared: ``adopt(_:engagements:)`` is handed the
    /// finished session, so the band, the figure and the marks all stay exactly
    /// where they are.
    public func stopAutoDev() async {
        await autoDevCommand("stop") { await $0.stop(sessionID: $1) }
    }

    /// Runs one of the three session commands, and **says so when it does not
    /// land**.
    ///
    /// ⛔ **A silent `return` is not available to these three.** Written as
    /// `guard let driver, let id, let updated = await driver.pause(…) else {
    /// return }`, a driver answering `nil` — a session it does not know, one
    /// already over, an actor that refused — produced no status line, no log
    /// entry and no visible change, *on the controls that stop an unattended
    /// agent*. That is this repository's own catalogue entry: a mechanism that
    /// substitutes a different answer instead of erroring, and never says no.
    ///
    /// **Three failures, three sentences, deliberately not one.** "There is no
    /// loop in this build", "nothing has been started" and "the loop did not
    /// answer" are three different things to do about it; collapsing them is the
    /// two-valued answer to a three-valued question that `PreflightState` and
    /// `MethodResolution` both exist to refuse.
    ///
    /// ⚠️ The third sentence claims only what is observable: the **board** is
    /// unchanged. Whether the loop acted and failed to confirm is not knowable
    /// from here, and a sentence that guessed would be a cause invented at the
    /// one place a reader would trust it.
    ///
    /// `verb` is the act in the reader's own sentence, so one helper serves all
    /// three rather than three copies of the same three guards — the reason
    /// ``adopt(_:engagements:)`` is one method rather than three assignments at
    /// each site.
    private func autoDevCommand(
        _ verb: String, _ act: (any AutoDevDriving, UUID) async -> AutoDevSession?
    ) async {
        guard let driver = autoDevDriver else {
            noteAutoDev("Cannot \(verb) auto-dev: it is not wired into this build yet.")
            return
        }
        guard let id = autoDev?.id else {
            noteAutoDev("Cannot \(verb) auto-dev: no session has been started.")
            return
        }
        guard let updated = await act(driver, id) else {
            noteAutoDev(
                "Auto-dev did not \(verb): the loop gave no session back, "
                    + "so the board is unchanged.")
            return
        }
        adopt(updated, engagements: await driver.engagements(sessionID: id))
    }

    /// Re-reads the session's rows.
    ///
    /// ⚠️ **A poll-shaped seam with no caller in this build.** This doc used to
    /// say *"the band's `.task` drives it"*; there is no `.task` in
    /// `OperationsView.swift`, and `grep -rn refreshAutoDev Sources` finds this
    /// declaration and a single cross-reference in `AutoDevDriving`'s doc. PR4
    /// wires it — on a `.task`, on its own tick — or replaces it with a push
    /// from the loop. The plan this screen was built from asks for none of the
    /// three, so the absence is the delivery order rather than a missing line;
    /// what it is **not** is a board that already re-polls.
    ///
    /// ⚠️ **Silence here is deliberate, and it is the one place it is** — and
    /// the reason stands on the *shape* of the call rather than on the sentence
    /// above. This is the only auto-dev entry point nobody presses: whatever
    /// ends up driving it drives it repeatedly and unasked, so a build with no
    /// loop attached would repaint the status bar with a refusal nobody asked
    /// for, on every tick. The three commands may not make that trade, because
    /// a reader is looking at the button they just used.
    /// ``refreshBusyLenses()`` makes the same one one section up and for the
    /// same reason: losing a refresh costs a hint, losing a `stop` costs a
    /// cancelled agent.
    public func refreshAutoDev() async {
        guard let driver = autoDevDriver, let session = autoDev else { return }
        adopt(session, engagements: await driver.engagements(sessionID: session.id))
    }

    /// Said out loud *and* logged.
    ///
    /// A visible message and a logged one are not alternatives — the log is what
    /// a bug report is rebuilt from, which is why ``startAnalysis(repoID:angles:instructions:maxStories:)``
    /// keeps both.
    ///
    /// ⚠️ `status` is a single narration owned by whoever spoke last, and a fact
    /// that has to survive needs a field of its own — the artefact sweep's
    /// report has one for exactly that reason. These four sentences are answers
    /// to a press: the reader is looking at the control they just used, so the
    /// status bar is where they are.
    private func noteAutoDev(_ sentence: String) {
        status = sentence
        Self.log.error("Auto-dev: \(sentence, privacy: .public)")
    }

    /// The one place the session, its rows and the engaged set are assigned.
    ///
    /// ⛔ **One assignment site for all three, and it must stay one.** Not a
    /// style rule: `AutoDevBand` takes its noun from the **session** and its
    /// settled count from the **rows**, because the two genuinely disagree in
    /// the window between a start returning and its first rows landing. The
    /// design's answer is that the disagreement is *transient*, bounded by one
    /// assignment at one moment. A second writer makes it permanent — and does
    /// so invisibly, because the band still renders and the figure still
    /// renders, and they simply describe two different moments.
    ///
    /// `AutoDevStateTests.adoptIsTheOnlyWriter` reads this file and fails naming
    /// the site, because no behavioural test can see the difference.
    /// ⚠️ **What it can and cannot see is written on the test, and this sentence
    /// used to overstate it.** Its first version counted assignments only, so
    /// `autoDevEngagedCardIDs.removeAll()` and `autoDev?.state = .finished` in
    /// this file passed a suite that was green — under this very comment
    /// promising they would not. It now classifies every mention and fails on
    /// any write shape or unsanctioned call; a write through a key path is still
    /// invisible to it. Read the test before trusting a claim made here.
    private func adopt(_ session: AutoDevSession?, engagements: [AutoDevEngagement]) {
        autoDev = session
        autoDevEngagements = engagements
        autoDevEngagedCardIDs = Set(session?.engagedCardIDs ?? [])
    }

    /// The loop, in every build that has one.
    ///
    /// `nil` until PR4 lands a conformer, which is the arbitrated delivery order
    /// rather than an omission: with none attached ``autoDevRefusal`` says so,
    /// the Start control is disabled with that sentence beside it, and the band
    /// renders idle.
    private var autoDevDriver: (any AutoDevDriving)?

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

    /// The same trick for one repository's preflight reading.
    ///
    /// `repoReadings` is filled by a real preflight sweep, and the rules that
    /// need it — which check a card's badge names, what a section says about a
    /// repository nobody has read — are exactly the ones no unit test can reach
    /// without shelling out to `gh` and `git`.
    ///
    /// ⚠️ It seeds the **reading only**, never `Repo.preflight`. That is the
    /// pair `blockedBadge` is about: the verdict decides *whether* a card is
    /// blocked and the reading decides *what it says*, and a helper that wrote
    /// both would make the one case that shipped broken — a persisted failure
    /// with no reading — unseedable.
    func testOnlySeedChecks(repo: UUID, _ checks: [CheckResult], at checkedAt: Date = .now) {
        repoReadings[repo] = PreflightReading(results: checks, checkedAt: checkedAt)
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
        if !analysis.isEmpty {
            // A repository id these runs do not belong to would be a fixture
            // that disagrees with itself, so it comes off the runs.
            let repoID = analysis.first?.repoID ?? UUID()
            self.analysis = AnalysisSession(id: UUID(), repoID: repoID, runs: analysis)
        }
    }

    /// Seeds the analysis window's state without a store behind it.
    ///
    /// `testOnlySeedRuns(analysis:)` seeded a bare array; the session needs an
    /// id, so this takes the session's members and leaves that seam to the
    /// three collections that are still plain.
    /// `proposals` is defaulted so the existing callers stay as they were. It
    /// exists because the editor's state is *about* a proposal, and #291 is
    /// exactly the question of what survives when the view holding it is
    /// destroyed — which cannot be asked of a session with nothing to edit.
    func testOnlySeedAnalysis(
        runs: [SkillRun], note: String?, proposals: [StoryProposal]? = nil
    ) {
        guard var session = analysis else { return }
        session.runs = runs
        session.note = note
        if let proposals { session.proposals = proposals }
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

    /// Puts the suppression table in front of the model without an observation
    /// behind it.
    ///
    /// `dismissedItems` is `private(set)` because ``observeDismissals()`` fills
    /// it, and the rules that read it — which repositories the face groups, what
    /// the door's figure counts — are about the **picker**, not about GRDB.
    /// Standing a real observation up to assert them would test delivery and
    /// call it a test of the filter.
    ///
    /// ⚠️ It therefore proves nothing about the wiring. That claim is
    /// `DismissedListTests.theTableIsObserved`, which subscribes for real.
    func testOnlySeedDismissals(_ items: [DismissedItem]) {
        dismissedItems = items
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

    /// Puts a real board behind the model without `start()`.
    ///
    /// Every seam above deliberately leaves `board` nil so a seeded model cannot
    /// write. `reorder` is the one rule that cannot be proved under that
    /// arrangement: its first line is `guard let board`, so with no board it
    /// returns before deciding anything, and the assertion would pass for a
    /// method whose body never ran.
    ///
    /// What needs proving is not the arithmetic — `CardReorderTests` owns that,
    /// purely — but the *glue* #49's criterion 2 is about: a cross-column drop
    /// performs the column move first, and a refused one places nothing. That
    /// step sits between two tested ends and had no test of its own, which is
    /// the same gap `CaretAnchorTests` was written to close one layer up.
    func testOnlyAttachBoard(_ board: BoardService) {
        self.board = board
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

    /// Puts a driver behind the model without `start()`.
    ///
    /// Optional because *detaching* is a seam of its own: with none attached
    /// ``startAutoDev()`` returns at its guard and the three commands return
    /// having said why, which is the state this build ships in until the loop
    /// lands — and the state most of this suite is about.
    func testOnlyAttachAutoDev(_ driver: (any AutoDevDriving)?) {
        autoDevDriver = driver
    }

    /// Puts a session and its rows in front of the model with no driver at all.
    ///
    /// The band and the figure are the things under test in most of this
    /// feature, and both read only what ``adopt(_:engagements:)`` assigns. A
    /// test that stood a driver up to assert a sentence would be testing the
    /// fake.
    ///
    /// ⛔ Through `adopt`, never by assigning the three properties here: a seam
    /// that wrote them itself would be the second assignment site the whole
    /// design forbids, and it would be one no gate could distinguish from
    /// production code.
    func testOnlySeedAutoDev(
        _ session: AutoDevSession?, engagements: [AutoDevEngagement] = []
    ) {
        adopt(session, engagements: engagements)
    }
}
