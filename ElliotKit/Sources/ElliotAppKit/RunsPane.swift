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

    /// The typed rows of one run, capped at the tail the panel can show.
    ///
    /// The cap is on rows rather than on events so a tool call and the result
    /// nested under it cannot be separated by it.
    nonisolated static func rows(of run: SkillRun, events: [StreamEvent]) -> [RunLogRow] {
        Array(RunLog.rows(from: events, denials: denials(of: run, in: events)).suffix(300))
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
            Text(run.state.label)
                .font(Type.prose)
                .foregroundStyle(run.state.tint)

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

    // MARK: The log

    private var logView: some View {
        @Bindable var model = model
        let all = rows
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
    }

    private func emptyNote(_ nothingAtAll: Bool) -> String {
        nothingAtAll
            ? "Nothing in this log — it may have been cleaned up."
            : "Nothing matches this filter."
    }

    /// The live tail while it runs; the file on disk once it has finished.
    ///
    /// Both go through the same fold, so a run does not change appearance the
    /// moment it ends — the tail used to be readable lines and the file on disk
    /// raw NDJSON, which made the log look like a different artefact depending
    /// on when you opened it.
    private var rows: [RunLogRow] {
        RunsPane.rows(of: run, events: live.isEmpty ? diskEvents : live)
    }

    /// `decodeAll` rather than `decode`: an assistant turn that carries prose
    /// *and* a tool call is two rows, and the one-event form would silently keep
    /// only the first.
    private var diskEvents: [StreamEvent] {
        guard let text = try? String(contentsOfFile: run.logPath, encoding: .utf8) else { return [] }
        return text
            .split(separator: "\n")
            .flatMap { StreamEventDecoder.decodeAll(line: Data($0.utf8)) }
    }
}

// MARK: - The verdict

/// What the agent said, and what `gh` established, one above the other.
///
/// This is the app's whole epistemology drawn as two rows. The claim is set in
/// `Type.hearsay` — demoted, italic, proportional — and is never parsed for a
/// number. The receipt is set in the fact face and takes its tint **and** its
/// icon from `VerifiedOutcome.receipt`, verbatim.
///
/// ⚠️ That last sentence is the whole reason to be careful here. A fixed
/// verified tint on the `gh` side would paint "Not merged — the branch is
/// behind" green, in the one block built to stop exactly that. The tint is read
/// from the outcome, never chosen here.
struct VerdictBlock: View {
    var run: SkillRun

    var body: some View {
        let verdict = RunVerdict.of(run)
        let receipt = Self.receipt(for: run)

        if verdict.itSaid != nil || receipt != nil {
            VStack(alignment: .leading, spacing: 0) {
                if let said = verdict.itSaid {
                    row(caption: "it said", ground: Surface.recessFaint) {
                        Text(said)
                            .font(Type.hearsay)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("It said, \(said)")
                }

                if let receipt {
                    if verdict.itSaid != nil {
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
