import ElliotModel
import SwiftUI

/// The runs of one card: what each one did, and what came of it.
///
/// Two things make this a pane rather than a list. First, the log is folded
/// into `RunLogRow`s and drawn a view per kind, so a call and its result are
/// one row and a successful result is visible at all. Second — and this is the
/// point of the change — every finished run carries a **verdict block** that
/// puts the agent's closing prose and what `gh` established side by side, in
/// two faces that cannot be confused.
struct RunsPane: View {
    @Environment(AppModel.self) private var model
    let card: Card

    var body: some View {
        let runs = model.runsByCard[card.id] ?? []

        VStack(alignment: .leading, spacing: 8) {
            if runs.isEmpty {
                emptyState
            } else {
                HStack(spacing: 6) {
                    ConsoleLabel(text: "Runs")
                    Fact(text: "\(runs.count)", tint: Palette.quiet, small: true)
                }
                // The read is `store.runs(cardID:limit:)` and the count above is
                // what it returned — not how many the card has. Read at the cap
                // it is a floor, and saying so costs one quiet line.
                //
                // `MoveHistory.isCapped` rather than `>=` written out again: the
                // predicate is the same one the move list uses, `limit:` is its
                // parameter, and one implementation is the point.
                if MoveHistory.isCapped(count: runs.count, limit: AppModel.runWindow) {
                    Text("Showing the most recent \(AppModel.runWindow) runs; there may be more.")
                        .font(Type.prose)
                        .foregroundStyle(.tertiary)
                }
                ForEach(runs) { run in
                    RunBox(run: run, live: model.liveLog[run.id] ?? [])
                }
            }
        }
    }

    /// At three spans this pane is half the panel. Drawn blank it reads as
    /// broken rather than as "nothing has run yet" — the same failure an empty
    /// column had before it grew `ColumnView.dropHint`.
    ///
    /// The sentence is `RunsPane.emptyState(column:outcome:)`'s, and the
    /// outcome handed to it is `model.preview` — the same call the next-step
    /// button and every column caption make. So this cannot promise a run the
    /// rule engine would refuse.
    private var emptyState: some View {
        let next = card.column.naturalNext
        let copy = RunsPane.emptyState(
            column: card.column,
            outcome: next.map { model.preview(card, to: $0) }
        )

        return ContentUnavailableView(
            copy.title, systemImage: "play.slash", description: Text(copy.message)
        )
        .frame(maxWidth: .infinity)
    }
}

// MARK: - The fold, as pure functions

extension RunsPane {

    /// What the pane says when nothing has ever run against this card.
    ///
    /// **Derived, never tabulated.** There is no `switch` over the five columns
    /// here, and there must not be: the answer to "what would produce a run"
    /// already exists twice over — `Column.naturalNext` says where the card
    /// goes next, and `Consequence.of` says what arriving there does — and both
    /// are read from `evaluateMove`, the pure function `BoardService` actually
    /// commits with. A hand-written "move it to To Do to file an issue" would
    /// be a third copy of the transition matrix, and it would go on promising a
    /// run for a card whose repository is switched off in Preflight.
    ///
    /// The four sentences it can produce are four *different states*, not four
    /// phrasings:
    ///
    /// - a move that starts something — the reader is told which move and, in
    ///   the column caption's own words, what it starts;
    /// - a move that is refused — the caption already names the gap rather than
    ///   the rule ("No issue yet — file it in To Do first"), so it is repeated
    ///   verbatim instead of being softened;
    /// - a move that is permitted and starts nothing, which is In Progress →
    ///   In Review alone. Saying only "nothing runs" would leave a reader with
    ///   no idea what does, so the destination's own `standingRule` finishes
    ///   it: Elliot fills that column itself;
    /// - no move at all, which is Done. "Nothing has run *yet*" would be a
    ///   promise, so Done gets its own title as well as its own sentence.
    ///
    /// ⚠️ **Which branch is taken is decided by `naturalNext`, never by
    /// `outcome`.** They were one `guard` for about ten minutes, and that
    /// version answered "Backlog is the end of the board" to a `nil` outcome —
    /// a flatly false sentence, reachable by a caller that simply had nothing
    /// to preview. The terminal sentence is now only reachable for a column
    /// that really is terminal, and a missing outcome gets a sentence that
    /// claims nothing about what the move would do.
    nonisolated static func emptyState(
        column: ElliotModel.Column, outcome: MoveOutcome?
    ) -> (title: String, message: String) {
        guard let next = column.naturalNext else {
            return (
                "No runs recorded",
                "\(column.displayName) is the end of the board — nothing runs from here."
            )
        }

        let title = "Nothing has run yet"

        guard let outcome else {
            // Not reachable from the panel, which previews every move it has.
            // Kept honest rather than clever: it names the move and promises
            // nothing about it.
            return (title, "Its first run would come from moving it to \(next.displayName).")
        }

        let consequence = Consequence.of(outcome)

        if consequence.isRefused {
            return (title, "Moving it to \(next.displayName) is refused. \(consequence.summary)")
        }
        if case .noAction = outcome {
            return (title, "Nothing runs on the way to \(next.displayName). \(next.standingRule)")
        }
        return (
            title,
            "Move it to \(next.displayName) to start the first run. \(consequence.summary)"
        )
    }

    /// The tools this run was refused, from whichever half of the run knows yet.
    ///
    /// The stream is asked first, and it is asked for a reason: `SkillRun`'s own
    /// `permissionDenials` is written by `RunScheduler.finish`, which only runs
    /// once the child has exited. A run still in flight has already *emitted*
    /// its `result` line — denials and all — and a pane that read only the
    /// record would show a refusal several seconds after it was knowable, or
    /// not at all for a log read straight off disk.
    ///
    /// It is the same list either way: `finish` fills the record from
    /// `result.permissionDenials.map(\.toolName)`. Preferring one source rather
    /// than merging both is what stops a finished run drawing every refusal
    /// twice.
    nonisolated static func denials(of run: SkillRun, in events: [StreamEvent]) -> [String] {
        for case .result(let result) in events {
            return result.permissionDenials.map(\.toolName)
        }
        return run.permissionDenials
    }

    /// How many rows of one log the panel will draw.
    nonisolated static let logRowLimit = 300

    /// The rows the panel can show, and how many older ones that left out.
    ///
    /// The count is the whole reason this is a type rather than an array. The
    /// cap used to be a bare `.suffix(300)`, so the head of a long log was
    /// simply absent and nothing said so — and the log whose head goes missing
    /// is exactly the `merge-pr` run that waited hours on CI. One pane over,
    /// `MoveHistoryBlock` already refuses to present a truncated list as a
    /// complete one; this is the same claim about the same panel.
    struct LogWindow: Sendable, Hashable {
        /// The newest rows, at most `logRowLimit` of them.
        var rows: [RunLogRow]
        /// How many older rows the cap left behind. `0` means the log is whole.
        var dropped: Int
    }

    /// Keeps the newest `limit` rows and counts what that dropped.
    ///
    /// ⚠️ The cap is on **rows** rather than on events, and that has to stay
    /// true: `RunLog.rows` has already attached each `tool_result` to its
    /// `tool_use` by id, so a row *is* the pair and no boundary can fall
    /// between them. Counting events here would reintroduce exactly that split.
    nonisolated static func trimmed(_ rows: [RunLogRow], limit: Int = logRowLimit) -> LogWindow {
        guard rows.count > limit else { return LogWindow(rows: rows, dropped: 0) }
        return LogWindow(rows: Array(rows.suffix(limit)), dropped: rows.count - limit)
    }

    /// The typed rows of one run, capped at the tail the panel can show.
    nonisolated static func rows(of run: SkillRun, events: [StreamEvent]) -> LogWindow {
        trimmed(RunLog.rows(from: events, denials: denials(of: run, in: events)))
    }

    /// What one run says about its own clock: how long ago, and how long for.
    ///
    /// Every field here already exists — the duration is drawn today, but only
    /// inside the expanded log's terminal line — so this surfaces a fact rather
    /// than inventing one.
    ///
    /// ⚠️ **`createdAt` is never presented as a finish time.** A queued run has
    /// no `endedAt` and may have no `startedAt`, so the age falls back through
    /// the three stamps in order and `help` names *which one it read*. A single
    /// "Finished …" tooltip over a queued run would be a claim about a run that
    /// has not started.
    nonisolated static func timing(
        of run: SkillRun, at now: Date = .now
    ) -> (age: String, duration: String?, help: String) {
        let (stamp, verb) =
            if let ended = run.endedAt { (ended, "Finished") }
            else if let started = run.startedAt { (started, "Started") }
            else { (run.createdAt, "Queued") }

        // Only a run with both ends has a duration. A run still going has a
        // length, but it is the strip's stopwatch, not this box's fact.
        let duration =
            if let started = run.startedAt, let ended = run.endedAt {
                Elapsed.short(from: started, to: ended)
            } else {
                String?.none
            }

        return (
            age: Elapsed.age(of: stamp, at: now),
            duration: duration,
            help: "\(verb) \(stamp.formatted(date: .abbreviated, time: .shortened))"
        )
    }

    /// What VoiceOver is told when the filter changes — one announcement, and it
    /// carries the number, because "tools" alone does not say whether the log
    /// went quiet or the filter did.
    nonisolated static func announcement(
        _ filter: RunLogFilter, shown: Int, of total: Int
    ) -> String {
        "\(filter.rawValue), \(shown) of \(total) lines"
    }
}

// MARK: - One run

/// A single run: its state, its verdict, and its log.
struct RunBox: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let run: SkillRun
    let live: [StreamEvent]

    /// `nil` means "the reader has not said", which is not the same as "closed".
    /// A run in flight opens its own log — it is the thing you selected the card
    /// to watch — and stays however the reader last left it once they touch it.
    @State private var expandedOverride: Bool?

    /// The finished log, read from disk once per `LogSource` rather than once
    /// per render. See `logView`'s `.task(id:)`.
    ///
    /// `nil` is "not read yet", which is not "empty" — the read is asynchronous
    /// now, so for the first frame after the box opens there is a difference
    /// between the two, and `emptyNote` has to be able to tell them apart.
    @State private var diskRows: RunsPane.LogWindow?

    /// Closed by default, and closed rather than absent: a story prompt runs to
    /// hundreds of lines, so this is a thing you go and look at, not a thing the
    /// panel puts in front of you.
    @State private var showsInputs = false

    private var expanded: Bool { expandedOverride ?? run.state.isActive }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            // Two rows rather than one: at the panel's width a long state name
            // ("Finished, tools refused") and a cost cannot share a line without
            // one of them wrapping mid-phrase.
            HStack(spacing: 6) {
                Image(systemName: run.state.icon)
                    .font(Type.fact)
                    .foregroundStyle(run.state.tint)
                    .accessibilityHidden(true)
                Text(run.kind.skillName).font(Type.fact).foregroundStyle(.primary)
                Spacer()
                if let cost = run.totalCostUSD {
                    Fact(text: MoneyFormat.usd(cost), tint: Palette.quiet, small: true)
                        .help("What this run cost")
                }
            }
            // The state name keeps this row to itself and the clock is pushed to
            // the trailing edge, because the two long strings on this box —
            // "Finished, tools refused" and a duration — must never queue up
            // behind one another. That is the same constraint that made the
            // header two rows in the first place.
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(run.state.label)
                    .font(Type.prose)
                    .foregroundStyle(run.state.tint)
                Spacer(minLength: 4)
                let clock = RunsPane.timing(of: run)
                Fact(text: clock.age, tint: Palette.quiet, small: true)
                    .help(clock.help)
                if let duration = clock.duration {
                    Fact(text: "took \(duration)", tint: Palette.quiet, small: true)
                }
            }

            VerdictBlock(run: run)

            if !run.permissionDenials.isEmpty {
                // A run can end "success" having been refused a tool and
                // silently worked around the gap. Named here as well as in the
                // log, because the log is a disclosure and this is not.
                Label(
                    "Refused tools: \(run.permissionDenials.joined(separator: ", "))",
                    systemImage: "lock.slash"
                )
                .font(Type.prose)
                .foregroundStyle(Palette.attention)
                .fixedSize(horizontal: false, vertical: true)
            }

            inputs

            HStack(spacing: 8) {
                Button(expanded ? "Hide log" : "Show log") { expandedOverride = !expanded }
                    .controlSize(.small)
                if run.state.isCancellable {
                    Button("Cancel run") { Task { await model.cancelRun(id: run.id) } }
                        .controlSize(.small)
                }
                Spacer()
                Button {
                    NSWorkspace.shared.selectFile(run.logPath, inFileViewerRootedAtPath: "")
                } label: {
                    Image(systemName: "folder").font(Type.factSmall)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Reveal the full log in the Finder")
                .accessibilityLabel("Reveal the full log in the Finder")
            }

            if expanded { logView }
        }
        .padding(9)
        .background(Surface.recess)
        .clipShape(RoundedRectangle(cornerRadius: Metric.cardRadius))
    }

    // MARK: What it was sent

    /// The exact `-p` argument and the full argv, which `SkillRun` documents as
    /// "kept so a run can be reproduced by hand" and which nothing rendered.
    ///
    /// The editor shows "What create-issue will receive" while a story is still
    /// being written, and then that visibility ends the moment the card freezes
    /// — so for `implement-issue` and `merge-pr`, the two runs that write code
    /// and merge it, a reader could never see what was actually asked, nor that
    /// the run carried `--permission-mode bypassPermissions`.
    ///
    /// ⛔ **`Text(verbatim:)`, and no syntax colouring.** A prompt carrying
    /// `#123` or `%@` through `LocalizedStringKey` is the locale bug
    /// `MergeConfirmation` and `paneTitle` both document, and
    /// `CodeTokenKind.tint` spends `armed` and `verified` on tokens strictly
    /// inside a fence — letting that escape into a run box would put `armed`
    /// beside a Cancel button.
    private var inputs: some View {
        DisclosureGroup(isExpanded: $showsInputs) {
            VStack(alignment: .leading, spacing: 6) {
                ScrollView {
                    Text(verbatim: run.prompt)
                        .font(Type.log)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(6)
                }
                // Bounded rather than free-growing: a story prompt is hundreds
                // of lines, and letting it run would push the log — the thing
                // the box is for — off the pane's own ScrollView.
                .frame(maxHeight: 160)
                .background(Surface.well)
                .clipShape(RoundedRectangle(cornerRadius: Metric.nestedRadius))

                Text(verbatim: run.argv.joined(separator: " "))
                    .font(Type.factSmall)
                    .foregroundStyle(Palette.quiet)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, 6)
        } label: {
            Text("What it was sent")
                .font(Type.prose)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: The log

    private var logView: some View {
        @Bindable var model = model
        let window = rows
        let all = window.rows
        let shown = RunLog.filter(all, by: model.logFilter)

        return VStack(alignment: .leading, spacing: 4) {
            Picker("Log filter", selection: $model.logFilter) {
                ForEach(RunLogFilter.allCases, id: \.self) { filter in
                    Text(filter.rawValue).tag(filter)
                }
            }
            .pickerStyle(.segmented)
            .controlSize(.small)
            .labelsHidden()
            .accessibilityLabel("Log filter")
            .accessibilityValue(
                RunsPane.announcement(model.logFilter, shown: shown.count, of: all.count)
            )
            .onChange(of: model.logFilter) { _, filter in
                AccessibilityNotification.Announcement(
                    RunsPane.announcement(
                        filter,
                        shown: RunLog.filter(all, by: filter).count,
                        of: all.count
                    )
                )
                .post()
            }

            // Outside the ScrollView on purpose. It is a *head* note about rows
            // that are gone, and the log scrolls itself to the bottom on every
            // appended line — inside, the one line saying the head is missing
            // would be the first thing scrolled out of sight.
            if window.dropped > 0 {
                Text("\(window.dropped) earlier rows are not shown — the full log is on disk.")
                    .font(Type.prose)
                    .foregroundStyle(Palette.quiet)
                    .fixedSize(horizontal: false, vertical: true)
            }

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 1) {
                        if shown.isEmpty {
                            Text(emptyNote(all.isEmpty))
                                .font(Type.prose)
                                .foregroundStyle(Palette.quiet)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        // By offset, not by `RunLogRow.id`: two identical
                        // refusals of the same tool share an id, and `ForEach`
                        // would collapse them into one row.
                        ForEach(Array(shown.enumerated()), id: \.offset) { index, row in
                            LogRowView(row: row).id(index)
                        }
                    }
                    .padding(6)
                }
                .frame(height: 260)
                .onChange(of: shown.count) {
                    // A live tail that does not follow is a log you have to
                    // chase with the scrollbar. Gated: this is the panel you
                    // open to read a run the app documents as lasting hours,
                    // and it animated on every appended line.
                    withAnimation(reduceMotion ? nil : .default) {
                        proxy.scrollTo(shown.count - 1, anchor: .bottom)
                    }
                }
            }
            .background(Surface.well)
            .clipShape(RoundedRectangle(cornerRadius: Metric.nestedRadius))

            Text(run.logPath)
                .font(Type.factSmall)
                .foregroundStyle(Palette.quiet)
                .textSelection(.enabled)
                .lineLimit(1)
                .truncationMode(.head)
        }
        // Once per (run, expansion), not once per render. `body` is evaluated
        // for reasons that have nothing to do with this box — a selection
        // elsewhere, a window resize, a run's cost arriving — and a finished
        // `merge-pr` log is not small.
        .task(id: LogSource(runID: run.id, state: run.state, hasLiveTail: !live.isEmpty)) {
            await loadDiskRows()
        }
    }

    /// Three states rather than two. The file is read asynchronously now, so a
    /// log nobody has looked at yet also has no rows — and telling the reader it
    /// "may have been cleaned up" would be a claim about a file that has not
    /// been opened.
    private func emptyNote(_ nothingAtAll: Bool) -> String {
        if live.isEmpty, diskRows == nil { return "Reading the log…" }
        return nothingAtAll
            ? "Nothing in this log — it may have been cleaned up."
            : "Nothing matches this filter."
    }

    /// The live tail while it runs; the file on disk once it has finished.
    ///
    /// Both go through the same fold, so a run does not change appearance the
    /// moment it ends — the tail used to be readable lines and the file on disk
    /// raw NDJSON, which made the log look like a different artefact depending
    /// on when you opened it.
    ///
    /// The live half is folded here, in `body`, and stays that way on purpose:
    /// it is at most the 300 events `AppModel` caps the tail at, it is already
    /// in memory, and it has to be re-read to be live at all. Only the disk half
    /// is held, because only the disk half is a file read.
    private var rows: RunsPane.LogWindow {
        live.isEmpty
            ? (diskRows ?? RunsPane.LogWindow(rows: [], dropped: 0))
            : RunsPane.rows(of: run, events: live)
    }

    /// Reads the log off the main actor and folds it, once per `LogSource`.
    ///
    /// `Task.detached` rather than a plain `await`: this view is main-actor
    /// isolated, so an inherited task would do the blocking read *on* the main
    /// thread — moving the stall out of `body` and leaving it in the same place
    /// it hurts.
    private func loadDiskRows() async {
        guard live.isEmpty else {
            // Nothing to read: `rows` is taking the live tail. Dropped rather
            // than kept, so a run that starts talking cannot hold a stale file
            // in memory behind the tail that replaced it.
            diskRows = nil
            return
        }
        let run = run
        let loaded = await Task.detached(priority: .userInitiated) {
            RunsPane.rows(of: run, events: RunBox.diskEvents(at: run.logPath))
        }.value
        guard !Task.isCancelled else { return }
        diskRows = loaded
    }

    /// `decodeAll` rather than `decode`: an assistant turn that carries prose
    /// *and* a tool call is two rows, and the one-event form would silently keep
    /// only the first.
    ///
    /// `nonisolated` because `View` is `@preconcurrency @MainActor`: a static
    /// member of a conforming type is inferred main-actor isolated, and calling
    /// it from a detached task would compile to nothing and trap at run time.
    nonisolated static func diskEvents(at path: String) -> [StreamEvent] {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return [] }
        return text
            .split(separator: "\n")
            .flatMap { StreamEventDecoder.decodeAll(line: Data($0.utf8)) }
    }
}

/// What makes the log on disk worth reading again.
///
/// The identity `.task` is keyed on. Expansion is not in it because the log
/// view does not exist while the box is collapsed, so appearing *is* the
/// expansion. What is in it are the two things that change what a read would
/// return: the run ending, and a live tail arriving or emptying — the tail is
/// what the disk read is an alternative to.
private struct LogSource: Equatable {
    var runID: SkillRun.ID
    var state: RunState
    var hasLiveTail: Bool
}

// MARK: - The verdict

/// What the run said for itself, and what `gh` established, one above the
/// other.
///
/// This is the app's whole epistemology drawn as two rows. A *claim* is set in
/// `Type.hearsay` — demoted, italic, proportional — and is never parsed for a
/// number. The receipt is set in the fact face and takes its tint **and** its
/// icon from `VerifiedOutcome.receipt`, verbatim.
///
/// ⚠️ That last sentence is the whole reason to be careful here. A fixed
/// verified tint on the `gh` side would paint "Not merged — the branch is
/// behind" green, in the one block built to stop exactly that. The tint is read
/// from the outcome, never chosen here.
///
/// ⛔ And the top row is only a claim when the text is one. A run that died
/// before its terminal event stores stderr, and a run Elliot could not start
/// stores a sentence Elliot wrote; both were captioned "IT SAID" and demoted
/// into italic, which inverted the rule inside the block built to show it
/// (#288). Which tier a text belongs to is decided by `ClosingRemark` in
/// `ElliotModel` — `swift test` cannot see a caption drawn in a view, so a
/// caption chosen here is a caption nothing checks.
struct VerdictBlock: View {
    var run: SkillRun

    var body: some View {
        let verdict = RunVerdict.of(run)
        let receipt = Self.receipt(for: run)

        if verdict.closing != nil || receipt != nil {
            VStack(alignment: .leading, spacing: 0) {
                if let closing = verdict.closing {
                    let style = Self.style(for: closing)
                    row(caption: closing.caption, ground: style.ground) {
                        Text(closing.text)
                            .font(style.font)
                            .foregroundStyle(style.tint)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("\(closing.spokenLead), \(closing.text)")
                }

                if let receipt {
                    if verdict.closing != nil {
                        Rectangle()
                            .fill(Surface.hairline)
                            .frame(height: 1)
                            .accessibilityHidden(true)
                    }
                    row(caption: "gh says", ground: Surface.washFaint(receipt.tint)) {
                        HStack(alignment: .firstTextBaseline, spacing: 4) {
                            Image(systemName: receipt.icon)
                                .font(Type.factSmall)
                                .foregroundStyle(receipt.tint)
                                .accessibilityHidden(true)
                            // `verdict.ghSays` and not `receipt.text`: the two
                            // are the same sentence — `RunVerdict` reads
                            // `receiptText` — and rendering the half that the
                            // test in `RunLogRowTests` asserts on is what keeps
                            // the assertion about this block.
                            Fact(text: verdict.ghSays ?? receipt.text, tint: receipt.tint)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("gh says, \(verdict.ghSays ?? receipt.text)")
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: Metric.nestedRadius))
            .overlay {
                RoundedRectangle(cornerRadius: Metric.nestedRadius)
                    .strokeBorder(Surface.hairline, lineWidth: 1)
            }
        }
    }

    private func row<Content: View>(
        caption: String, ground: Color, @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(caption.uppercased())
                .font(Type.labelSmall)
                .tracking(0.6)
                .foregroundStyle(Palette.quiet)
                .frame(width: 52, alignment: .leading)
            content()
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(ground)
    }

    /// How the top row is drawn, decided from the attribution and nothing else.
    ///
    /// `static` and `nonisolated` for the reason `receipt(for:)` is: it is the
    /// only part of this view a test can hold, and the mapping is exactly what
    /// #288 got wrong. Two tiers, not three — `ClosingRemark.isHearsay` is the
    /// model's answer and this spends no fourth colour on the difference
    /// between stderr and Elliot's own note, which the caption already carries.
    ///
    /// `Palette.refused` is "a move was refused, or a run failed", which is the
    /// only way either fact-tier source is ever produced: both mean the agent
    /// never got to its terminal event.
    nonisolated static func style(
        for closing: ClosingRemark
    ) -> (font: Font, tint: Color, ground: Color) {
        closing.isHearsay
            ? (Type.hearsay, .secondary, Surface.recessFaint)
            : (Type.fact, Palette.refused, Surface.washFaint(Palette.refused))
    }

    /// What the `gh` side draws, or `nil` while there is nothing to say yet.
    ///
    /// The verified case is `VerifiedOutcome.receipt` **unchanged** — text, tint
    /// and icon — so a `.notMerged` or `.unverified` run is not green here and
    /// cannot become green by an edit to this file.
    ///
    /// A run that ended with nothing verified gets its own line rather than an
    /// empty half-block: a missing receipt is a fact about the run, and the one
    /// the board's rule cares about most.
    nonisolated static func receipt(for run: SkillRun) -> (text: String, tint: Color, icon: String)? {
        if let outcome = run.verifiedOutcome { return outcome.receipt }
        guard run.state.isTerminal else { return nil }
        return ("Nothing verified for this run", Palette.attention, "questionmark.circle")
    }
}
