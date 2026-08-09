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
/// One screen, not four features. Three bands, each the visible half of work
/// already landed and tested:
///
/// - **Up next** — `rankNextSteps` (#67), the order `board_next` gives an agent.
/// - **Workers** — the caps (#56) and the queue with its reasons (#58) and its
///   commands (#59).
/// - **Spending** — the aggregates (#61) against the ceiling (#57).
///
/// It computes nothing. Every number here was decided by the engine or the
/// store, and a second opinion in this file would be a fifth place for the
/// board's rules to live.
///
/// `public` only because `ElliotApp` names it in a `Scene`.
public struct OperationsView: View {
    public init() {}

    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                preflightBand
                runningBand
                workersBand
                queueBand
                spendingBand
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
                Button("Open Preflight") { openWindow(id: "preflight") }
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
    /// The repository name is not decoration. `repoChecks` is keyed by
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

        let perRepo = model.repos.flatMap { repo in
            (model.repoChecks[repo.id] ?? [])
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
                Button("Change the limits") { openWindow(id: "preflight") }
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
                Button("Set a ceiling") { openWindow(id: "preflight") }
                    .controlSize(.small)
            }
        }
    }

    /// Shows the sentence, not only the number: a total that is a floor must not
    /// present itself as complete (#57).
    ///
    /// Takes the `SpendFigure` rather than the `Spend`, because `Spend` can only
    /// answer the narrower question. Asking `isComplete` of it kept this caveat
    /// silent through every analysis — the figure read near zero exactly while
    /// the spending was happening, and landed on the total afterwards.
    private func amount(_ title: String, _ figure: SpendFigure) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            ConsoleLabel(text: title)
            Fact(text: figure.amount(), tint: .primary)
            if !figure.isComplete {
                Text(figure.sentence())
                    .font(Type.factSmall)
                    .foregroundStyle(Palette.attention)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title): \(figure.sentence())")
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

    // MARK: - Up next

    /// The first three, and a way to the rest. The whole list is `NextStepsView`
    /// and has its own window; repeating it here in full would make this screen
    /// a scroll rather than a summary.
    private var upNextBand: some View {
        band("Up next") {
            let steps = model.nextSteps
            if steps.isEmpty {
                Text("Nothing Elliot can advance on its own.")
                    .font(Type.prose)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(Array(steps.prefix(3).enumerated()), id: \.element.card.id) { index, step in
                    let consequence = Consequence.of(step.outcome)
                    HStack(alignment: .top, spacing: 8) {
                        Text("\(index + 1)")
                            .font(Type.factSmall)
                            .foregroundStyle(.tertiary)
                            .frame(width: 18, alignment: .trailing)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 2) {
                            Fact(text: step.repoName, tint: Palette.quiet, small: true)
                            Text(step.card.displayTitle)
                                .font(Type.prose)
                                .fixedSize(horizontal: false, vertical: true)
                            Text(consequence.summary)
                                .font(Type.prose)
                                .foregroundStyle(
                                    consequence.isRefused ? Palette.refused : consequence.tint
                                )
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 0)
                    }
                    .accessibilityElement(children: .combine)
                }
                Button("See all \(steps.count)") { openWindow(id: "nextSteps") }
                    .controlSize(.small)
            }
        }
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
