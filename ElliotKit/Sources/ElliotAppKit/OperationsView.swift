import ElliotEngine
import ElliotModel
import SwiftUI

/// What the machine is doing, what it will do next, and what it costs.
///
/// The board answers "what work exists". Repositories answers "what is wrong
/// with each repo". Neither answers the other two questions a control room has
/// to answer, and the review's finding was that the four windows were peers with
/// no home among them.
///
/// One screen, not four features. Bands, each the visible half of work already
/// landed and tested — listed by what they are, not in the order they are drawn:
///
/// - **Up next** — `rankNextSteps` (#67), the order `board_next` gives an agent.
///   Since #304 it is `UpNextBand`, the whole list rather than a preview of one,
///   and **the only band here a gesture acts through**.
/// - **Workers** — the caps (#56) and the queue with its reasons (#58) and its
///   commands (#59).
/// - **Spending** — the aggregates (#61) against the ceiling (#57).
///
/// It computes nothing. Every number here was decided by the engine or the
/// store, and a second opinion in this file would be a fifth place for the
/// board's rules to live. ⛔ That held for the *numbers* and did not hold for the
/// **rows**: this file drew its own Up next list for as long as it existed, and
/// the copy was inert where the original could act. `UpNextBandSourceTests` is
/// what stops it coming back.
///
/// `public` only because `ConsoleRegion` renders it as a face — the `Scene` that
/// used to name it is gone.
public struct OperationsView: View {
    public init() {}

    @Environment(AppModel.self) private var model

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                preflightBand
                runningBand
                workersBand
                queueBand
                spendingBand
                autoDevBand
                upNextBand
            }
            .padding(16)
        }
        // No `.navigationTitle`: this is a console face now, and a title set
        // here propagates to the *board window* and renames it — measured, and
        // not stopped by a nested NavigationStack nor by an ancestor re-asserting
        // the board's own. The console header names the screen.
    }

    // MARK: - Preflight

    /// Only when something is failing. Preflight is a *state*, not a place, and
    /// a permanently green band saying "nothing is wrong" is the kind of thing
    /// a reader learns to stop seeing — and then misses on the day it turns red.
    @ViewBuilder
    private var preflightBand: some View {
        let failing = failingChecks
        if !failing.isEmpty {
            band("Something is broken") {
                ForEach(failing, id: \.key) { entry in
                    Label {
                        VStack(alignment: .leading, spacing: 1) {
                            HStack(spacing: 6) {
                                Text(entry.check.title).font(Type.rowTitle)
                                if let repoName = entry.repoName {
                                    Fact(text: repoName, tint: Palette.quiet, small: true)
                                }
                            }
                            Text(entry.check.detail)
                                .font(Type.prose)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    } icon: {
                        Image(systemName: "xmark.octagon.fill").foregroundStyle(Palette.refused)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(spoken(entry))
                }
                // ⚠️ `showConsoleFace`, not `openWindow(id: "preflight")`. This
                // and the two below were `openWindow` calls naming a scene the
                // console deleted, so all three did **nothing at all** — SwiftUI
                // logs an unknown scene id and returns. Found while folding Up
                // next into this screen (#304); the same defect one door over,
                // and the same reason it was invisible: a button that silently
                // does nothing looks exactly like a button nobody pressed.
                // `ConsoleReachabilityTests` now refuses an `openWindow` id that
                // `ElliotApp` does not declare.
                Button("Open Preflight") { model.showConsoleFace(.preflight) }
                    .controlSize(.small)
            }
        }
    }

    private func spoken(_ entry: FailingCheck) -> String {
        guard let repoName = entry.repoName else {
            return "\(entry.check.title): \(entry.check.detail)"
        }
        return "\(entry.check.title), \(repoName): \(entry.check.detail)"
    }

    /// A failing check, and which repository it is about.
    ///
    /// The repository name is not decoration. The readings are keyed by
    /// repository and several can fail the *same* check, so without it the band
    /// draws two identical rows and reads as a rendering bug rather than as two
    /// repositories with the same problem. Seen on screen before this shipped.
    private struct FailingCheck {
        var key: String
        var repoName: String?
        var check: CheckResult
    }

    /// Machine-wide checks first — a missing `gh` is why every repository below
    /// it is also failing, and listing them the other way round buries the
    /// cause under its own symptoms.
    private var failingChecks: [FailingCheck] {
        let global = model.globalChecks
            .filter { $0.status == .fail }
            .map { FailingCheck(key: "global.\($0.id)", repoName: nil, check: $0) }

        // A repository with no reading contributes nothing, and that is the
        // honest answer here rather than the silence it is elsewhere: this band
        // lists what *is* failing, and nobody has looked. What that costs is
        // said on Preflight, which is where the sweep lives.
        let perRepo = model.repos.flatMap { repo in
            (model.repoReadings[repo.id]?.results ?? [])
                .filter { $0.status == .fail }
                .map {
                    FailingCheck(
                        key: "\(repo.id.uuidString).\($0.id)",
                        repoName: repo.displayName, check: $0)
                }
        }
        return global + perRepo
    }

    // MARK: - Running now

    /// The runs themselves, above the gauge that counts them.
    ///
    /// Above Workers because `2 / 2` is the *summary* of this band, and a screen
    /// that answers "what is the machine doing" with a summary and no detail is
    /// the state #303 describes. It is also the only place an **analysis** run
    /// appears outside the analysis panel: `activeRuns` is keyed by card id, and
    /// an analysis has none.
    ///
    /// It computes nothing, like every other band here. Which runs, in what
    /// order and how many is `RunningNow`'s, the last line is `AppModel`'s, and
    /// Cancel goes to `model.cancelRun` — the one funnel every stop travels,
    /// whether it started here, in a card's menu or over MCP.
    @ViewBuilder
    private var runningBand: some View {
        let running = model.runningNow
        band("Running now") {
            if running.isEmpty {
                // Said plainly rather than by drawing nothing: an empty band and
                // a band that failed to load look identical.
                Text("Nothing is running.")
                    .font(Type.prose)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(running.shown) { run in
                    RunningStrip(
                        run: run,
                        lastLine: model.lastLine(of: run),
                        context: run.context(repoName: model.repo(id: run.repoID)?.displayName),
                        cancel: { Task { await model.cancelRun(id: run.id) } }
                    )
                    // `.contain`, not `.combine`: this row carries a button, and
                    // combining it into one element is what makes Cancel
                    // unreachable to a screen reader.
                    .accessibilityElement(children: .contain)
                }
                if let note = running.note {
                    Text(note)
                        .font(Type.prose)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: - Workers

    private var workersBand: some View {
        band("Workers") {
            HStack(spacing: 14) {
                gauge(
                    "Writers", used: model.occupancy.writers, cap: model.limits.maxConcurrent)
                gauge(
                    "Analyses", used: model.occupancy.analyses,
                    cap: model.limits.maxConcurrentAnalyses)
                Spacer()
                Button("Change the limits") { model.showConsoleFace(.preflight) }
                    .controlSize(.small)
            }
        }
    }

    private func gauge(_ title: String, used: Int, cap: Int) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            ConsoleLabel(text: title)
            Fact(text: "\(used) / \(cap)", tint: used > 0 ? Palette.armed : Palette.quiet)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title): \(used) of \(cap) busy")
    }

    // MARK: - Queue

    private var queueBand: some View {
        band("Waiting") {
            HStack(spacing: 8) {
                Text(queueSentence)
                    .font(Type.prose)
                    .foregroundStyle(model.isQueuePaused ? Palette.refused : .secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                if model.isQueuePaused {
                    Button("Resume") { Task { await model.resumeQueue() } }
                        .controlSize(.small)
                } else {
                    Button("Pause") { Task { await model.pauseQueue() } }
                        .controlSize(.small)
                        .disabled(model.queue.isEmpty && model.occupancy.writers == 0)
                }
                Button("Discard all") { Task { await model.drainQueue() } }
                    .controlSize(.small)
                    .disabled(model.queue.isEmpty)
            }

            ForEach(model.queue) { queued in
                queueRow(queued)
            }
        }
    }

    private var queueSentence: String {
        if model.isQueuePaused {
            return model.queue.isEmpty
                ? "The queue is paused. Runs already going will finish."
                : "Paused — \(model.queue.count) held. Runs already going will finish."
        }
        if model.queue.isEmpty { return "Nothing is waiting." }
        return "\(model.queue.count) waiting to start."
    }

    /// The row names the rule holding it, because a queue that has stopped
    /// moving with no reason given reads as a broken scheduler (#58).
    private func queueRow(_ queued: QueuedRun) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text("\(queued.position)")
                .font(Type.factSmall)
                .foregroundStyle(.tertiary)
                .frame(width: 18, alignment: .trailing)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Fact(text: queued.repoName, tint: Palette.quiet, small: true)
                    ConsoleLabel(text: queued.kind.skillName, tint: .secondary)
                    Spacer(minLength: 0)
                }
                if let title = queued.cardTitle {
                    Text(title).font(Type.prose).fixedSize(horizontal: false, vertical: true)
                }
                Text(queued.refusal.sentence)
                    .font(Type.prose)
                    .foregroundStyle(Palette.attention)
                    .fixedSize(horizontal: false, vertical: true)
            }
            // How long it has waited. Held forty minutes by a merge, a run read
            // exactly like one queued a moment ago — the field was filled and
            // drawn nowhere, so the queue had no sense of time at all.
            Text(Elapsed.age(of: queued.queuedAt))
                .font(Type.factSmall)
                .foregroundStyle(.secondary)
            if queued.position > 1 {
                Button("Move to front") {
                    Task { await model.promoteQueued(runID: queued.runID) }
                }
                .controlSize(.small)
            }
            // Between "move it up" and "throw the queue away" there was nothing,
            // so one stuck entry cost every other waiting run.
            Button("Cancel") {
                Task { await model.cancelQueued(runID: queued.runID) }
            }
            .controlSize(.small)
        }
        .padding(8)
        .background(Surface.recess)
        .clipShape(RoundedRectangle(cornerRadius: Metric.cardRadius))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(queued.position). \(queued.repoName), \(queued.kind.skillName), waiting \(Elapsed.age(of: queued.queuedAt)). \(queued.refusal.sentence)"
        )
    }

    // MARK: - Spending

    private var spendingBand: some View {
        band("Spending") {
            HStack(alignment: .top, spacing: 20) {
                amount("Today", model.todayFigure)
                VStack(alignment: .leading, spacing: 2) {
                    ConsoleLabel(text: "Ceiling")
                    Text(ceilingSentence)
                        .font(Type.prose)
                        .foregroundStyle(model.isOverDailyCeiling ? Palette.refused : .secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Button("Set a ceiling") { model.showConsoleFace(.preflight) }
                    .controlSize(.small)
            }
            byKindRow
        }
    }

    /// What today's money went on, under the total it adds up to.
    ///
    /// `spendByKind` was written, documented and tested and called by nothing
    /// outside tests (#308), while the analysis panel started up to eight runs
    /// from one button and no screen said what that costs against filing one
    /// issue. This is that query, reaching a reader.
    ///
    /// Every kind, always, in one order: a column that appears and disappears as
    /// work moves is one nobody can glance at. Each figure states its own
    /// caveats through `amount`, which is where the "at least" wording already
    /// lives — the split must not read as a smaller, complete bill than the
    /// total above it.
    private var byKindRow: some View {
        HStack(alignment: .top, spacing: 20) {
            ForEach(model.todayByKind, id: \.kind) { entry in
                amount(entry.kind.skillName, entry.figure, isColumn: true)
            }
            Spacer(minLength: 0)
        }
    }

    /// Shows the sentence, not only the number: a total that is a floor must not
    /// present itself as complete (#57).
    ///
    /// Takes the `SpendFigure` rather than the `Spend`, because `Spend` can only
    /// answer the narrower question. Asking `isComplete` of it kept this caveat
    /// silent through every analysis — the figure read near zero exactly while
    /// the spending was happening, and landed on the total afterwards.
    /// `isColumn` is what one figure in a **row** of them can afford, and it was
    /// decided by looking rather than by reasoning: rendered, the four skills'
    /// `sentence()`s wrapped to three amber lines each and were taller than
    /// every band above them together.
    ///
    /// So a column carries `amountMark` — the `+` `AnalysisSpend` already uses
    /// for the same claim — plus its run count, which is the denominator a
    /// skill's figure is meaningless without: `$4.10` across two merges and
    /// across forty analyses are different facts. ⛔ The sentence is not dropped,
    /// it **moves**: to `help` and to the spoken label, both below. A lone figure
    /// like the day's total has the room and keeps it on screen.
    @ViewBuilder
    private func amount(
        _ title: String, _ figure: SpendFigure, isColumn: Bool = false
    ) -> some View {
        let figureStack = VStack(alignment: .leading, spacing: 2) {
            ConsoleLabel(text: title)
            Fact(text: isColumn ? figure.amountMark() : figure.amount(), tint: .primary)
            if isColumn {
                Fact(text: figure.spend.runsSentence, tint: Palette.quiet, small: true)
            } else if !figure.isComplete {
                Text(figure.sentence())
                    .font(Type.factSmall)
                    .foregroundStyle(Palette.attention)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            isColumn
                ? "\(title): \(figure.sentence()), over \(figure.spend.runsSentence)"
                : "\(title): \(figure.sentence())")

        // Branched rather than `.help(isColumn ? … : "")`: what an empty help
        // string does is unmeasured here, and a figure that already spells its
        // caveat out on screen has nothing to add in a tooltip anyway.
        if isColumn {
            figureStack.help(figure.sentence())
        } else {
            figureStack
        }
    }

    private var ceilingSentence: String {
        switch (model.ceiling.perRunUSD, model.ceiling.perDayUSD) {
        case (nil, nil):
            "None. A drag can spend without limit."
        case (let run?, nil):
            "\(MoneyFormat.usd(run)) per run, no daily limit."
        case (nil, let day?):
            model.isOverDailyCeiling
                ? "\(MoneyFormat.usd(day)) a day — reached. Queued runs are held."
                : "\(MoneyFormat.usd(day)) a day."
        case (let run?, let day?):
            model.isOverDailyCeiling
                ? "\(MoneyFormat.usd(run)) per run, \(MoneyFormat.usd(day)) a day — reached."
                : "\(MoneyFormat.usd(run)) per run, \(MoneyFormat.usd(day)) a day."
        }
    }

    // MARK: - Auto-dev

    /// Immediately above Up next, and the adjacency is the argument.
    ///
    /// Up next is the ranking of moves Elliot *could* make; auto-dev is one
    /// fixed set of them being made. Both read the world `rankNextSteps` ranks,
    /// so two orders stacked in one window read as one unless the top one says
    /// it is not the same order — which is what `AutoDevBand.caption` says.
    ///
    /// **Permanent, never conditional** — unlike `preflightBand` above, and the
    /// difference is not taste. Preflight is a *state* nobody has to remember;
    /// a session's outcome is a **record**, and the record it has to carry is
    /// the failure: `Column.naturalNext` is `nil` for `.done`, so a card whose
    /// merge failed — which stays in Done with a `lastError` — is structurally
    /// absent from `UpNextBand` below. A conditional band would render a session
    /// that failed everywhere exactly like a session that never happened. The
    /// template is `model.lastSyncSummary` on Repositories, which stays after
    /// the sweep.
    ///
    /// It computes nothing: `AutoDevBand.of` is total and decides every
    /// sentence, `AutoDevBand.repoName` decides which repository the session is
    /// about, and this renders what they return.
    private var autoDevBand: some View {
        let rendering = AutoDevBand.of(
            session: model.autoDev, tally: model.autoDevTally,
            repoName: AutoDevBand.repoName(
                session: model.autoDev, selectedRepoID: model.selectedRepoID, repos: model.repos),
            hasLiveRun: model.autoDevHasLiveRun)
        return band("Auto-dev") {
            Text(rendering.headline)
                .font(Type.prose)
                .foregroundStyle(rendering.tone.tint)
                .fixedSize(horizontal: false, vertical: true)

            Text(AutoDevBand.caption)
                .font(Type.prose)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            // The queue band's shape above: the sentence that says what the
            // controls do, then the controls. The sentence is not decoration —
            // a title has no room to say that Stop cancels the run already
            // going, and the queue's own Pause cannot do that at all.
            HStack(alignment: .top, spacing: 8) {
                Text(rendering.runNote)
                    .font(Type.prose)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                ForEach(rendering.controls, id: \.self) { control in
                    Button(AutoDevBand.title(control)) { act(control) }
                        .controlSize(.small)
                        .help(AutoDevBand.explains(control))
                        .accessibilityHint(AutoDevBand.explains(control))
                }
            }

            ForEach(model.autoDevEngagements) { engagement in
                engagementRow(engagement)
            }

            startRow
        }
    }

    /// One engaged card, in `queueRow`'s shape: what it is, and the rule that
    /// decided it. The reason is the row's point — a report that says a card is
    /// blocked without saying why sends the reader nowhere.
    private func engagementRow(_ engagement: AutoDevEngagement) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: engagement.disposition.icon)
                .font(.system(size: 10))
                .foregroundStyle(engagement.disposition.tint)
                .frame(width: 18)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(engagementTitle(engagement))
                    .font(Type.prose)
                    .fixedSize(horizontal: false, vertical: true)
                Text(engagement.reason)
                    .font(Type.prose)
                    .foregroundStyle(engagement.disposition.tint)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            Fact(text: "\(engagement.attempts)", tint: Palette.quiet, small: true)
                .help("Attempts on this card")
        }
        .padding(8)
        .background(Surface.recess)
        .clipShape(RoundedRectangle(cornerRadius: Metric.cardRadius))
        .accessibilityElement(children: .combine)
    }

    /// A deleted card still has a row: the session engaged it, and dropping the
    /// row would make the report quietly shorter than the session it describes.
    private func engagementTitle(_ engagement: AutoDevEngagement) -> String {
        model.card(id: engagement.cardID)?.displayTitle ?? "A card that is no longer on the board"
    }

    /// Start, how many cards it engages, and — when it cannot start — why.
    ///
    /// ⛔ Deliberately **not** in a toolbar, the one region `board_screenshot`
    /// renders blank, and it never claims the Return key. The analysis panel was
    /// refused a default action for claiming up to eight unattended runs; this
    /// claims more, and merges. `DefaultAction.denied` carries the record and
    /// `DefaultActionTests` enforces it.
    ///
    /// The refusal is *stated beside* a disabled Start rather than hidden — the
    /// same arrangement `AnalysisPanelView` reached after #151: a control you
    /// cannot press has to say what would let you press it.
    private var startRow: some View {
        @Bindable var model = model
        return HStack(spacing: 8) {
            Stepper(value: $model.autoDevCardLimit, in: 1...10) {
                Text(
                    "\(model.autoDevCardLimit) "
                        + (model.autoDevCardLimit == 1 ? "card" : "cards")
                )
                .font(Type.prose)
            }
            .fixedSize()

            Button("Start auto-dev") { Task { await model.startAutoDev() } }
                .controlSize(.small)
                .disabled(model.autoDevRefusal != nil)

            if let refusal = model.autoDevRefusal {
                Text(refusal)
                    .font(Type.prose)
                    .foregroundStyle(Palette.refused)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }

    private func act(_ control: AutoDevBand.Control) {
        Task {
            switch control {
            case .pause: await model.pauseAutoDev()
            case .resume: await model.resumeAutoDev()
            case .stop: await model.stopAutoDev()
            }
        }
    }

    // MARK: - Up next

    /// The ranking, drawn once, and able to act.
    ///
    /// ⛔ **This band held a second drawing of it until #304**, and the two
    /// differed in exactly the way that matters: `NextStepsView`'s rows were
    /// buttons through `model.move(cardID:to:)` and carried
    /// `.disabled(consequence.isRefused)`; these were inert `HStack`s that read
    /// `isRefused` for a *colour* and offered nothing. *"See all N"* then opened
    /// the other drawing purely to hand back the affordance the reader was
    /// already looking at — and counted `N` off the unfiltered board while
    /// opening a screen the repository picker had narrowed, so with a filter set
    /// "See all 12" opened a list of four.
    ///
    /// `UpNextBand` is that one drawing. Everything this screen contributes is
    /// the `ConsoleLabel` below; the band draws no title of its own.
    private var upNextBand: some View {
        band("Up next") { UpNextBand() }
    }

    // MARK: - Chrome

    private func band(
        _ title: String, @ViewBuilder content: () -> some View
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ConsoleLabel(text: title)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
