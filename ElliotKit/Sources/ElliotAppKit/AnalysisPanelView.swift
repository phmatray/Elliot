import ElliotEngine
import ElliotModel
import SwiftUI

/// The analysis, as the board's leading slot: one panel that starts as a form
/// and becomes a review list.
///
/// Deliberately not two sheets: once the runs are going, the proposals appear
/// under them angle by angle. Splitting them would hide the thing that makes
/// one run per angle worth paying for — the quick wins are triable while the
/// bugs angle is still reading.
///
/// The lens strip is the same object in both states: the tiles you arm become
/// the row you watch. That is what makes the single surface legible rather than
/// merely economical.
///
/// It was a `Window` scene until #151, and a modal sheet before that — both of
/// which cover the board this screen exists to fill. Accepting a proposal makes
/// a card in Backlog, which is now the column immediately to this panel's
/// right, so the one gesture the screen is *for* has a visible effect.
///
/// The board's rule carries over here. Evidence is set in the fact face because
/// it was read off the repository, and `isGrounded` — every cited file actually
/// present — is this feature's `verifiedOutcome`: the difference between a
/// story that was found and one that was written.
///
/// ⚠️ **There is no `@Environment(\.dismiss)` here, deliberately.** In a panel it
/// resolves to the enclosing window — the board — so the old `Close` button
/// would close the application's main window. Hiding is
/// `model.showingAnalysisPanel = false`; ending the session is `Finish`, and
/// those are two different acts (see ``AppModel/showingAnalysisPanel``).
///
/// ⚠️ **The container does not clip, and must not** — the same rule
/// `DetailPanelView` carries. The shadow that says this panel floats above the
/// columns sits outside these bounds.
struct AnalysisPanelView: View {
    /// The board's column width, passed in rather than measured here.
    ///
    /// The panel is measured in columns, so it needs the same number the columns
    /// were laid out with. A second `GeometryReader` inside the one that already
    /// answered that question would be a second answer to it.
    let columnWidth: CGFloat

    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    // ⚠️ The setup form, the triage selection **and the open editor** live on
    // `AppModel`, not here: hiding the panel removes it from the row and
    // destroys every `@State` in it, which would make the hide lossy in exactly
    // the way this feature says it is not. See ``AppModel/analysisAngles``.
    //
    // `editingID` used to be here, and its draft was `@State` inside
    // `ProposalEditor` — so the promise held for the two pieces named in the
    // comment above and was false for the one the reader had actually typed
    // into (#291). Both now travel as one ``ProposalEdit`` on the session.
    @State private var past: [Analysis] = []
    /// `nil` until the reader opens or closes the strip themselves.
    @State private var lensesExpanded: Bool?

    /// The open editor's draft, bound through the model.
    ///
    /// The `get`'s fallback is never rendered: the editor is built only inside
    /// `model.analysisEdit?.proposalID == proposal.id`, so a nil edit means
    /// there is no editor on screen. The `set` writes nothing when the edit is
    /// gone, which is the right answer for a keystroke that lands after the
    /// proposal was decided elsewhere.
    private var editDraftBinding: Binding<CardDraft> {
        Binding(
            get: { model.analysisEdit?.draft ?? CardDraft() },
            set: { model.analysisEdit?.draft = $0 }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()

            if let session = model.analysis {
                review(session)
            } else {
                setup
            }

            Divider()
            footer
        }
        // Measured in board columns, like the detail panel, so it reads as being
        // *of* the row rather than a window that happens to be nearby. The note
        // that used to live above the footer is now *in* it — inserting a row
        // between the list and the buttons moved the buttons out from under the
        // cursor that had just pressed one.
        .frame(width: PanelLayout.panelWidth(columnWidth: columnWidth, spans: model.analysisSpans))
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Color(nsColor: .windowBackgroundColor), in: outline)
        .overlay {
            outline.strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1)
        }
        .overlay(alignment: .trailing) {
            @Bindable var model = model
            PanelResizeHandle(
                spans: $model.analysisSpans,
                columnWidth: columnWidth,
                // Pinned at the row's leading edge, so its outer edge is always
                // the trailing one and "drag right" is always "wider".
                opensLeft: false,
                help: "Drag to make the analysis two or three columns wide",
                label: "Analysis width"
            )
        }
        // The same elevation the detail panel has: this floats above the columns
        // it is placed beside, and that is what says it is not one of them.
        .shadow(
            color: .black.opacity(Metric.panelElevation.opacity),
            radius: Metric.panelElevation.radius,
            y: Metric.panelElevation.y
        )
        .accessibilityElement(children: .contain)
        // Applied here rather than from the board: `accessibilityLabel` resolves
        // innermost-first, so an outer one would be silently inert.
        // ⚠️ The **undecided** count, whichever group is on screen. This
        // announces what there is left to decide; a number that followed the
        // picker would say "3 proposals" while sitting on a tab where none of
        // them can be acted on (#331).
        .accessibilityLabel(
            BoardAccessibility.analysisPanelLabel(
                repoName: repo?.displayName,
                proposalCount: model.analysis.map { undecided($0).count }
            )
        )
        // Keyed, because without an `id:` this ran once when the panel first
        // appeared and never again — so *Earlier analyses* listed whatever
        // repository happened to be picked at that instant, permanently, and
        // no later change could correct it (#213).
        .task(id: model.analysisRepoID) {
            past = await model.recentAnalyses()
            // ⚠️ **Re-read, not read once.** The whole value of a busy seal is
            // that it is current: a lens that finishes while the reader sits on
            // this form would otherwise stay marked until the panel is closed,
            // telling them to wait for a run that has ended — a stale hint is
            // worse than none, because there is nothing on screen to disbelieve.
            // Nothing pushes here: an analysis started over MCP, or one left
            // running by the last session, is exactly the case the seal is for,
            // and neither passes through this model. Cancelled with the view,
            // which is what hiding the panel does.
            while !Task.isCancelled {
                // Only setup draws the tiles. While a session is open the answer
                // is on screen already, in the lens strip.
                if model.analysis == nil { await model.refreshBusyLenses() }
                try? await Task.sleep(for: .seconds(5))
            }
        }
        // ⚠️ A proposal can be accepted or rejected over MCP — or by this
        // panel's own footer — while the editor is hidden. Re-applying a draft
        // over a decided proposal is worse than losing it: an accepted one
        // already has a Backlog card carrying its text, so a save would rewrite
        // the proposal that card came from.
        //
        // Keyed on the open ids rather than run from `body`: a view that
        // mutated the model while rendering it is a different bug.
        .onChange(of: openProposalIDs, initial: true) { _, ids in
            model.dropStaleAnalysisEdit(openProposalIDs: ids)
        }
    }

    /// The proposals still open for decision.
    ///
    /// ⚠️ Deliberately **not** the rows the list is currently showing. An edit
    /// is only ever valid on an undecided proposal, so switching the picker to
    /// *Accepted* must not read as "the proposal you were editing was decided
    /// elsewhere" and drop a draft that is still perfectly good (#331).
    private var openProposalIDs: Set<UUID> {
        Set((model.analysis.map(undecided) ?? []).map(\.id))
    }

    /// The panel's silhouette, used as a background fill and as a border — never
    /// as a clip. See the ⚠️ on the type.
    private var outline: RoundedRectangle {
        RoundedRectangle(cornerRadius: Metric.panelRadius)
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Analyse \(repoName)").font(Type.sheetTitle)
                Text(model.analysis == nil
                    ? "Read this repository through several lenses and propose stories for the backlog."
                    : "Accept what you want on the board. Nothing here is a card until you do.")
                    .font(Type.prose)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if !past.isEmpty, model.analysis == nil {
                Menu {
                    ForEach(past) { analysis in
                        Button(label(for: analysis)) { model.openAnalysis(analysis) }
                    }
                } label: {
                    Label("Earlier analyses", systemImage: "clock.arrow.circlepath")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }

            // Hides the panel. It does **not** end the session: the runs keep
            // going and the observation keeps landing proposals, so re-showing
            // finds everything that arrived meanwhile. `Finish`, in the footer,
            // is the other act.
            Button {
                model.showingAnalysisPanel = false
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
            .help("Hide the analysis. Runs in flight keep going and proposals keep arriving.")
            .accessibilityLabel("Hide the analysis")
        }
        .padding(16)
    }

    private var repoName: String { repo?.displayName ?? "…" }

    /// Which repository this panel is about — the header, the run rows, the
    /// evidence links and the Start button all resolve through here.
    ///
    /// ⛔ **Not `selectedRepoID`.** That is the board's toolbar picker, which
    /// the reader can move while this panel is open, and it says nothing about
    /// which repository the open analysis read. `AppModel.analysisRepo` answers
    /// from the session while there is one and from the picker only in setup;
    /// `AnalysisPanelViewSourceTests` fails if the picker comes back into this
    /// file (#213).
    private var repo: Repo? { model.analysisRepo }

    /// Says what the analysis looked at and what came back, rather than a date
    /// beside a row of emoji.
    private func label(for analysis: Analysis) -> String {
        let when = analysis.createdAt.formatted(date: .abbreviated, time: .shortened)
        let lenses = analysis.angles.map(\.title).joined(separator: ", ")
        return "\(when) — \(lenses)"
    }

    // MARK: - Setup

    private var setup: some View {
        // The Stepper and the TextEditor write back, and what they write to now
        // lives on the model so it survives the panel being hidden.
        @Bindable var model = model
        return ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 8) {
                    ConsoleLabel(text: "Lenses")
                    Text("Each lens is its own run, and each run reads the whole repository.")
                        .font(Type.prose)
                        .foregroundStyle(.secondary)

                    LazyVGrid(
                        columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)],
                        spacing: 10
                    ) {
                        ForEach(AnalysisAngle.allCases, id: \.self) { angle in
                            LensTile(
                                angle: angle,
                                isOn: model.analysisAngles.contains(angle),
                                // Scoped to the panel's repository by the model,
                                // so this view cannot hold the mismatch it would
                                // otherwise be free to draw (#213's axis).
                                busy: model.lensBusy(angle)
                            ) {
                                if model.analysisAngles.contains(angle) { model.analysisAngles.remove(angle) } else { model.analysisAngles.insert(angle) }
                            }
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 6) {
                    ConsoleLabel(text: "Limit")
                    Stepper(value: $model.analysisMaxStories, in: 1...30) {
                        Text("Keep at most \(model.analysisMaxStories) stories from each lens")
                            .font(Type.bodyProse)
                    }
                    .fixedSize()
                }

                VStack(alignment: .leading, spacing: 6) {
                    ConsoleLabel(text: "Extra instructions")
                    Text("Folded into every lens's prompt. Leave it empty unless you want to steer them.")
                        .font(Type.prose)
                        .foregroundStyle(.secondary)
                    TextEditor(text: $model.analysisInstructions)
                        .font(Type.bodyProse)
                        .scrollContentBackground(.hidden)
                        .padding(4)
                        .frame(height: 68)
                        .background(Color(nsColor: .textBackgroundColor))
                        .clipShape(RoundedRectangle(cornerRadius: Metric.cardRadius))
                        .overlay(RoundedRectangle(cornerRadius: Metric.cardRadius)
                            .strokeBorder(.separator))
                }
            }
            .padding(16)
        }
    }

    // MARK: - Review

    private func review(_ session: AnalysisSession) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            // Pinned: this is the status of the thing you are waiting on, and
            // it must not scroll away under the proposals it is producing.
            //
            // It also steps aside once there is nothing left to wait for. While
            // runs are in flight the strip is the screen's subject; afterwards
            // the subject is triage, and four finished lenses would otherwise
            // hold half the window to say so.
            VStack(alignment: .leading, spacing: 8) {
                Button {
                    lensesExpanded = !isLensStripOpen(session)
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: isLensStripOpen(session) ? "chevron.down" : "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.secondary)
                        ConsoleLabel(text: "Lenses")
                        if !isLensStripOpen(session) { lensSummary(session) }
                        Spacer()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if isLensStripOpen(session) {
                    ForEach(session.runs) { run in
                        LensRunRow(run: run, repoPath: repo?.path)
                    }
                }
            }
            .padding(16)

            Divider()
            proposalList(session)
        }
    }

    /// Open while anything is still reading, closed once it is all in — unless
    /// the reader has said otherwise, which then sticks.
    private func isLensStripOpen(_ session: AnalysisSession) -> Bool {
        lensesExpanded ?? !session.runs.allSatisfy { $0.state.isTerminal }
    }

    /// What the collapsed strip still has to say.
    ///
    /// Every alarm survives the collapse. A run that edited the repository is
    /// exactly the thing that must not become invisible because the panel it
    /// lived in was tidied away.
    @ViewBuilder
    private func lensSummary(_ session: AnalysisSession) -> some View {
        let reports = session.runs.compactMap(\.analysisReport)
        let kept = reports.reduce(0) { $0 + $1.kept }
        let dropped = reports.reduce(0) { $0 + $1.dropped.count }
        let edited = reports.filter { $0.workingTreeChanged == true }.count
        let recovered = reports.filter { $0.harvestSource == .resultText }.count

        HStack(spacing: 8) {
            Fact(text: "\(session.runs.count) lenses", small: true)
            Fact(text: "\(kept) kept", tint: Palette.verified, small: true)
            // The number the setup footer promised, surviving the collapse the
            // reader spends the whole triage inside. `Palette.quiet` is
            // greyscale and spends none of the five consequence accents —
            // `armed` here would give a sixth meaning to the colour that means
            // "this starts an agent".
            if let spend = AnalysisSpend.of(session.runs) {
                Fact(text: AnalysisSpend.label(spend), tint: Palette.quiet, small: true)
                    .help(AnalysisSpend.help(spend))
            }
            if dropped > 0 {
                Fact(text: "\(dropped) dropped", tint: Palette.attention, small: true)
            }
            if recovered > 0 {
                Fact(text: "\(recovered) recovered", tint: Palette.attention, small: true)
            }
            if edited > 0 {
                Label(
                    edited == 1 ? "1 edited the repository" : "\(edited) edited the repository",
                    systemImage: "exclamationmark.octagon.fill"
                )
                .font(Type.factSmall)
                .foregroundStyle(Palette.refused)
            }
        }
    }

    /// The rows the list is showing: one of the three groups, chosen by the
    /// session's own picker.
    ///
    /// The observation this session is fed by fetches **every** status — its
    /// query is built with `status: nil` — so all three groups have always been
    /// in memory and nothing on screen could reach two of them (#331). This is a
    /// reading that was thrown away one layer from the screen; no store, engine
    /// or wire change was involved in getting it back.
    private func rows(_ session: AnalysisSession) -> [StoryProposal] {
        ProposalReview.group(session.proposals, session.review)
    }

    /// The undecided group, whatever the picker is showing.
    ///
    /// Three things still mean *what is left to decide* rather than *what is on
    /// screen*: the panel's accessibility label, the editor's staleness check,
    /// and the footer's Edit… button.
    private func undecided(_ session: AnalysisSession) -> [StoryProposal] {
        ProposalReview.group(session.proposals, .proposed)
    }

    private func proposalList(_ session: AnalysisSession) -> some View {
        let rows = self.rows(session)
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 14) {
                // ⛔ **A sibling of the `if` below, never inside its `else`.**
                // This is where #292's rejected disclosure went, and its
                // argument came with it: the state the decided groups exist for
                // is *"I rejected the wrong one"*, and rejecting the last open
                // proposal empties the triage list — so a picker rendered only
                // when the current group has rows would vanish in precisely the
                // case that needs it most, while looking perfectly correct in
                // every case anyone would think to try. `swift test` cannot see
                // a view, so nothing would have failed.
                reviewPicker(session)

                if rows.isEmpty {
                    emptyReview(session)
                } else {
                    // Proposed only, and that is not an oversight: the bar
                    // stages rows for the footer's Accept and Reject, and
                    // neither verb means anything for a row already decided.
                    let isTriage = session.review == .proposed
                    if isTriage { selectionBar(rows) }
                    ForEach(AnalysisAngle.allCases, id: \.self) { angle in
                        let group = rows.filter { $0.angle == angle }
                        if !group.isEmpty {
                            angleSection(angle, group, isTriage: isTriage)
                        }
                    }
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            // Accepting or rejecting a row made it vanish instantly, so a list
            // of twelve became a list of eleven with no sign of which one went.
            .animation(reduceMotion ? nil : .snappy(duration: 0.2), value: rows.map(\.id))
        }
    }

    /// Which group the list is showing, with all three counts visible without
    /// switching.
    ///
    /// The counts are `ProposalReview.counts`, which emits **every** case
    /// including zero — a tab that disappeared when its group emptied would be
    /// one more surface unable to tell "nothing was rejected" from "nobody
    /// looked", which is the ambiguity this whole reading closes.
    private func reviewPicker(_ session: AnalysisSession) -> some View {
        @Bindable var model = model
        let counts = ProposalReview.counts(session.proposals)
        return Picker("Show", selection: $model.analysisReview) {
            ForEach(ProposalStatus.allCases, id: \.self) { group in
                Text("\(group.reviewTitle) \(counts[group] ?? 0)").tag(group)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .accessibilityLabel("Which proposals to show")
        .help(
            "The analysis keeps everything it found. Rejecting marks a proposal rather than "
                + "deleting it, and accepting one names the card it became.")
    }

    /// What a row may be asked to do, decided by the one thing that knows:
    /// the proposal's own status.
    ///
    /// **Exhaustive, with no `default`** — the reason `RunState.isUnderway`
    /// gives. A fourth status would otherwise inherit whichever answer the
    /// shorter spelling happened to give, and here that answer decides whether
    /// a row carries an *Accept* button.
    private func actions(for proposal: StoryProposal) -> ProposalRowActions {
        switch proposal.status {
        case .proposed:
            return .decide(
                isSelected: model.analysisSelection.contains(proposal.id),
                toggle: {
                    if model.analysisSelection.contains(proposal.id) {
                        model.analysisSelection.remove(proposal.id)
                    } else {
                        model.analysisSelection.insert(proposal.id)
                    }
                },
                edit: { model.beginEditingProposal(proposal) },
                accept: { Task { await model.acceptProposals(ids: [proposal.id]) } },
                reject: { Task { await model.rejectProposals(ids: [proposal.id]) } }
            )
        case .accepted:
            // Resolved through `AppModel.card(id:)`, which searches the
            // **unfiltered** cards — so a card in a repository the board's
            // toolbar picker has filtered out still resolves and still gets
            // named. A nil card is a real state and is not "not accepted";
            // `ProposalReview.cardLabel` is where that is decided.
            return .accepted(
                ProposalReview.cardLabel(
                    for: proposal, card: model.card(id: proposal.acceptedCardID)))
        case .rejected:
            // The rule is the model's; this only asks it. The store's
            // conditional UPDATE is the fact — see `StoryProposal.isRestorable`,
            // and the note that reports the disagreement when there is one.
            return proposal.isRestorable
                ? .restore({ Task { await model.restoreProposals(ids: [proposal.id]) } })
                : .settled
        }
    }

    /// One lens's rows inside whichever group is on screen.
    ///
    /// `isTriage` is passed rather than re-derived from the rows: the rows are
    /// already the group the picker chose, and a section that asked them again
    /// what status they are would be the narrowing this reading exists to
    /// remove, one function further in.
    private func angleSection(
        _ angle: AnalysisAngle, _ group: [StoryProposal], isTriage: Bool
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(angle.symbol)
                ConsoleLabel(text: angle.title, tint: .primary)
                // Heads the rows below it, so it counts the group it heads —
                // which is the one counter of the four that the picker moves.
                // The lens strip's `N kept` counts the harvest and never this.
                Fact(text: "\(group.count)", tint: Palette.quiet, small: true)
                Spacer()
                // Selecting stages rows for the footer's Accept / Reject, so it
                // is offered only where those verbs mean something.
                if isTriage {
                    Button(allSelected(group) ? "Clear" : "Select all") {
                        let ids = group.map(\.id)
                        if allSelected(group) {
                            ids.forEach { model.analysisSelection.remove($0) }
                        } else {
                            model.analysisSelection.formUnion(ids)
                        }
                    }
                    // No accent: choosing rows starts nothing and merges
                    // nothing. The five accents mean consequence, and spending
                    // three of them on triage controls is what made them stop
                    // reading as one.
                    .buttonStyle(.plain)
                    .font(Type.prose)
                }
            }

            ForEach(group) { proposal in
                // The row grows into a form rather than being covered by one.
                // This list is walked to triage up to thirty proposals, and a
                // sheet covered the very thing being sorted.
                if model.analysisEdit?.proposalID == proposal.id {
                    // The draft is bound through the model, so hiding the panel
                    // and re-showing it lands back on this editor with every
                    // character intact. `@Bindable` gives the binding; the
                    // force-unwrap-free path is the model's own optional
                    // projection.
                    ProposalEditor(
                        proposal: proposal,
                        draft: editDraftBinding,
                        done: { model.endEditingProposal() }
                    )
                    .id(proposal.id)
                } else {
                    ProposalRow(
                        proposal: proposal, actions: actions(for: proposal), repoPath: repo?.path)
                }
            }
        }
    }

    private func allSelected(_ group: [StoryProposal]) -> Bool {
        !group.isEmpty && group.allSatisfy { model.analysisSelection.contains($0.id) }
    }

    /// The two bulk selections worth offering, and they are the two objective
    /// things known about an opinion: whether the files it cites are there, and
    /// whether its text already exists somewhere.
    ///
    /// ⛔ **Both *select*; neither decides.** The flagged rows are a courtesy —
    /// `StoryProposal.duplicateOf` says in as many words that skipping a
    /// near-duplicate is the reader's call — so a one-click *Reject the
    /// duplicates* would turn a hint into a refusal, on a score
    /// (`TextSimilarity`, threshold 0.6) that has no business making that
    /// decision. Selecting puts the whole set one click from the footer's
    /// Reject **and** one click from its Accept, with the rows still on screen.
    private func selectionBar(_ proposed: [StoryProposal]) -> some View {
        HStack(spacing: 10) {
            Fact(text: "\(model.analysisSelection.count) of \(proposed.count) selected", small: true)
            Spacer()
            let grounded = proposed.filter(\.isGrounded).map(\.id)
            Button("Select the \(grounded.count) grounded") {
                model.analysisSelection = Set(grounded)
            }
            .buttonStyle(.plain)
            .font(Type.prose)
            .disabled(grounded.isEmpty)

            let flagged = proposed.filter(\.looksDuplicated).map(\.id)
            Button("Select the \(flagged.count) flagged") {
                model.analysisSelection = Set(flagged)
            }
            .buttonStyle(.plain)
            .font(Type.prose)
            .disabled(flagged.isEmpty)
            .help(
                "Selects every proposal that looks like a card, an open issue, or a story another "
                    + "lens already proposed. Selecting is not deciding — Accept and Reject are "
                    + "still yours.")

            Button("Clear") { model.analysisSelection = [] }
                .buttonStyle(.plain)
                .font(Type.prose)
                .disabled(model.analysisSelection.isEmpty)
        }
    }

    /// What an empty group means — decided in `ElliotModel`, rendered here.
    ///
    /// ⚠️ **`harvested` is the runs' own `kept` total, never `rows.count`.**
    /// That is the whole of this reading's *so that*: a list of zero undecided
    /// rows is the same list whether the lens found nothing or you decided
    /// everything, and only the harvest can tell the two apart. This slot used
    /// to assert *"Every proposal has been accepted or rejected"* in both cases,
    /// two inches under a lens strip reading `0 kept` (#331).
    private func emptyReview(_ session: AnalysisSession) -> some View {
        let message = ProposalReview.emptyMessage(
            for: session.review,
            harvested: session.runs.compactMap(\.analysisReport).reduce(0) { $0 + $1.kept },
            running: model.runningAngles.map(\.title)
        )
        return VStack(alignment: .leading, spacing: 6) {
            Label(message.title, systemImage: message.symbol)
                .font(Type.cardTitle)
            Text(message.detail)
                .font(Type.prose)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 20)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 10) {
            if model.analysis == nil {
                // Three things this slot has to say — why Start is refused, why
                // the last Start did not happen, and what the next one will
                // spend — and one value deciding between them.
                //
                // It was a chain of `if`s here until #138, which is how a failed
                // start came to be written into a session that does not exist
                // in setup: the branch that could have shown it sat below one
                // keyed on exactly the state a failed start leaves behind, and
                // no test can enter a view body to notice. `swift test` holds
                // the decision now; this renders it.
                let message = AnalysisFooterMessage.setup(
                    angleCount: model.analysisAngles.count,
                    clashing: model.clashingLenses,
                    failure: model.startFailure,
                    refusal: model.analysisRefusal
                )
                Label(message.text, systemImage: message.symbol)
                    .font(Type.prose)
                    .foregroundStyle(message.tone.tint)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    // The clamp is right — this slot is one line of a footer —
                    // but the failures that land here are
                    // `error.localizedDescription` from a thrown start, the
                    // longest strings the slot ever shows and the ones whose
                    // tail carries the actionable part. Without this the tail is
                    // *unreadable*: it reaches `os_log`, and as of 2026-08-07
                    // nothing from this subsystem comes back out of `log show`
                    // at any level. Deferred deliberately in #216; this is it.
                    //
                    // `message.text` verbatim. A second wording here would be a
                    // second thing to keep in agreement with the value that
                    // decides the sentence — which is why `AnalysisFooterMessage`
                    // gains no member for it.
                    .help(message.text)
                    // A second identical failure must transition rather than
                    // look like the first one never went away.
                    .id(message.text)
                    // Driven by the `.animation(reduceMotion ? nil : …)` at the
                    // foot of this footer, which is keyed on the failure as well
                    // as the note. Reduce motion switches it off there, once.
                    .transition(.opacity)
            } else if !model.analysisSelection.isEmpty {
                // A count of your own clicks is not a consequence, so it
                // carries no accent.
                Fact(text: "\(model.analysisSelection.count) selected")
            } else if let note = model.analysis?.note {
                Label(note, systemImage: "info.circle")
                    .font(Type.prose)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    // Same clamp, same loss, same remedy. Criterion 2: the note
                    // is not a lesser string — "Rejected 12 proposals." is short,
                    // but a note carrying a store error is not.
                    .help(note)
                    .id(note)
                    // Driven by the `.animation(reduceMotion ? nil : …, value:
                    // fadingMessages)` at the foot of this footer, which carries
                    // the very value that makes the note appear and go. Reduce
                    // motion switches it off there, once.
                    .transition(.opacity)
            }

            Spacer()

            // Only while a session exists: with nothing started there is nothing
            // to finish, and the ✕ in the header is how you put the panel away.
            //
            // This is the *other* act — it drops the session and returns the
            // panel to the lens picker. The runs themselves belong to the
            // scheduler; cancelling one is still the per-lens Cancel button.
            if model.analysis != nil {
                Button("Finish") { model.closeAnalysis() }
                    .help(
                        "End this analysis and return to the lens picker. "
                            + "Undecided proposals stay in the store.")
            }

            if model.analysis == nil {
                Button("Start \(model.analysisAngles.count) run\(model.analysisAngles.count == 1 ? "" : "s")") {
                    // In this branch `model.analysis` is nil, so this *is* the
                    // picker — read through the one property anyway, so a later
                    // edit cannot split the answer in two again.
                    guard let repoID = model.analysisRepoID else { return }
                    Task {
                        await model.startAnalysis(
                            repoID: repoID,
                            // The same ordered list the footer names in its
                            // clash sentence and the service refuses on, read
                            // through one property so the three cannot disagree
                            // about which lens comes first.
                            angles: model.armedAngles,
                            instructions: model.analysisInstructions,
                            maxStories: model.analysisMaxStories
                        )
                    }
                }
                // ⛔ No `.keyboardShortcut(.defaultAction)`, and its absence is
                // the point. As a `Window` scene Return was scoped to this
                // screen; as a panel it shares the board window with
                // `DetailPanelView`'s own default action, and Return would have
                // two claimants with nothing in the code deciding between them.
                // The claimant here spawns up to eight unattended runs, so it is
                // the one that must not be reachable by a key pressed anywhere
                // in the window.
                //
                // ⚠️ This ⛔ is about **Start**, not about the panel. The panel
                // does carry a default action — `ProposalEditor`'s Save, which
                // commits text the reader typed and is sanctioned by
                // `DefaultAction.claimants`. CLAUDE.md read this comment as
                // "the analysis panel carries no `.defaultAction`" and stated it
                // that way, which was false, and false in the direction that
                // made the Return problem look already solved. The rule and its
                // gate now live in `DefaultAction` / `DefaultActionTests`
                // rather than in a comment two files away from what it governs.
                .disabled(model.analysisAngles.isEmpty || model.analysisRefusal != nil)
                // The one genuinely armed control on this screen — it starts N
                // unattended runs — and it was the only one with no tint, while
                // six inert triage buttons had one each.
                .tint(Palette.armed)
            } else {
                // Editing was reachable by hover and by context menu, neither
                // of which a keyboard can open on macOS.
                Button("Edit…") {
                    guard
                        let proposal = (model.analysis.map(undecided) ?? [])
                            .first(where: { model.analysisSelection.contains($0.id) })
                    else { return }
                    model.beginEditingProposal(proposal)
                }
                .disabled(model.analysisSelection.count != 1)

                Button(model.analysisSelection.isEmpty ? "Reject" : "Reject \(model.analysisSelection.count)") {
                    let ids = Array(model.analysisSelection)
                    model.analysisSelection = []
                    Task { await model.rejectProposals(ids: ids) }
                }
                .disabled(model.analysisSelection.isEmpty)

                // One verb per act. The row buttons, the context menu and this
                // all say "Accept"; "Add to Backlog" was a third name for it.
                Button(model.analysisSelection.isEmpty ? "Accept" : "Accept \(model.analysisSelection.count)") {
                    let ids = Array(model.analysisSelection)
                    model.analysisSelection = []
                    Task { await model.acceptProposals(ids: ids) }
                }
                // Same reason as Start above: this panel no longer owns a window,
                // so a window-wide default action is not what it is any more.
                .disabled(model.analysisSelection.isEmpty)
            }
        }
        .padding(16)
        .animation(reduceMotion ? nil : .snappy(duration: 0.18), value: fadingMessages)
    }

    /// Both messages this footer can fade, in one value: the note that belongs
    /// to an analysis, and the failure that belongs to a start which never
    /// produced one. Keyed on the note alone, a failure appearing or clearing
    /// was the one change in this footer that snapped.
    ///
    /// A property rather than an inline array so the `.animation` above stays
    /// on one line — `BoardAccessibilityTests` reads the line the gate stands
    /// on, and a call split across four of them hides `reduceMotion` from it.
    private var fadingMessages: [String?] { [model.analysis?.note, model.startFailure] }
}

extension AnalysisFooterMessage.Tone {
    /// The accent, decided here rather than in the value.
    ///
    /// `AnalysisFooterMessage` holds no `Color`, so its tests assert the
    /// decision rather than a colour — and a value that cannot name a colour
    /// cannot be where a sixth consequence accent arrives. These two are the
    /// existing ones; `BrandColorTests` pins the five.
    var tint: Color {
        switch self {
        case .armed: Palette.armed
        case .refused: Palette.refused
        }
    }
}

// MARK: - A lens, before it runs

/// An angle as something you arm, not a row in a settings list. The eight
/// lenses are what this feature *is*; a column of checkboxes says otherwise.
///
/// ⛔ **A busy tile is still tickable, and never `.disabled`.** #151 removed a
/// `.disabled` from the Analyse toggle on the argument that a control you cannot
/// switch off is worse than one that opens onto an explanation, and a lens you
/// cannot untick is that trap one screen in — the reader's whole remedy for a
/// clash is to untick it. It is worse here than there, too: `busy` is a snapshot
/// and can be wrong, so a disabled tile would be a control taken away on the
/// strength of a hint. `AnalysisPanelViewSourceTests` fails if a `.disabled`
/// comes back.
struct LensTile: View {
    let angle: AnalysisAngle
    let isOn: Bool
    /// How far along a run already holding this lens is, or `nil` when it is
    /// free. See ``BusyLenses`` — a reading, not a fact.
    let busy: LensBusy?
    let toggle: () -> Void

    /// Armed *and* busy: the pair that makes Start refuse the whole set. Neither
    /// half alone does, which is why this is what the tile's ground reacts to.
    private var blocksStart: Bool { isOn && busy != nil }

    var body: some View {
        Button(action: toggle) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(angle.symbol)
                    Text(angle.title).font(Type.rowTitle)
                    Spacer()
                    // ⛔ The mark stays the tick, and the busy signal goes in the
                    // body line instead. The dossier proposed replacing it with
                    // an attention seal; that costs the one thing the mark is
                    // for — *did I arm this?* — on exactly the tiles where the
                    // question matters most, because armed-and-busy is the set
                    // that blocks Start and the reader is about to go looking
                    // for it. Busy-ness is the tile's other axis, so it gets its
                    // own line rather than the same glyph.
                    Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 12))
                        .foregroundStyle(isOn ? Palette.armed : Color.secondary.opacity(0.5))
                }
                if let busy {
                    busyLine(busy)
                } else {
                    Text(angle.briefing)
                        .font(Type.prose)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(ground)
            .clipShape(RoundedRectangle(cornerRadius: Metric.panelRadius))
            .overlay {
                RoundedRectangle(cornerRadius: Metric.panelRadius)
                    .strokeBorder(border)
            }
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isOn ? [.isButton, .isSelected] : .isButton)
        // The briefing is what this said before, and it is what the tile shows
        // when the lens is free. When it is busy the reader needs the other
        // sentence, so VoiceOver gets whatever is actually on the tile.
        .accessibilityLabel(
            "\(angle.title). \(busy.map(Self.description) ?? angle.briefing)")
        .help(busy.map {
            Self.description(of: $0)
                + " Ticking it is still allowed; Start will refuse the whole set until it finishes."
        } ?? angle.briefing)
    }

    /// ⚠️ Past tense and no promise about now: this is a reading the panel took,
    /// and `AnalysisService` is what decides whether a Start goes. The footer's
    /// clash sentence carries the same hedge for the same reason.
    ///
    /// ⛔ **Two sentences, because there are two states.** Found by looking at
    /// the running app: a queued lens read *"Already reading   queued"*, which
    /// says two contradictory things in four words. The enum has the answer —
    /// this switches on it rather than treating queued as reading-without-a-clock.
    private static func description(of busy: LensBusy) -> String {
        switch busy {
        case .queued:
            "A run for this lens was already queued when the lenses were last checked."
        case .reading:
            "This lens was already reading the repository when the lenses were last checked."
        }
    }

    /// The stopwatch, for the one busy state that has started.
    ///
    /// `TimelineView` rather than a stored tick: the same mechanism
    /// `LensRunRow` uses for a run in flight, so a lens reads the same however
    /// you are watching it.
    @ViewBuilder
    private func busyLine(_ busy: LensBusy) -> some View {
        HStack(spacing: 6) {
            switch busy {
            case .reading(let since):
                Label("Already reading", systemImage: "hourglass")
                    .font(Type.prose)
                    .foregroundStyle(Palette.attention)
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Fact(text: Elapsed.short(from: since, to: context.date),
                         tint: Palette.quiet, small: true)
                }
            case .queued:
                // No stopwatch, and no second word: a queued run has not begun,
                // so inventing an elapsed time from `createdAt` would be a
                // clock on something that is not running.
                Label("Already queued", systemImage: "hourglass")
                    .font(Type.prose)
                    .foregroundStyle(Palette.attention)
            }
            Spacer(minLength: 0)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private var ground: Color {
        if blocksStart { return Surface.wash(Palette.attention) }
        return isOn ? Surface.wash(Palette.armed) : Surface.recess
    }

    private var border: Color {
        if blocksStart { return Surface.washBorder(Palette.attention) }
        return isOn ? Surface.washBorder(Palette.armed) : Color(nsColor: .separatorColor)
    }
}

// MARK: - A lens, while it runs

struct LensRunRow: View {
    @Environment(AppModel.self) private var model
    let run: SkillRun
    let repoPath: String?
    @State private var showingDropped = false

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Text(run.analysisAngle?.symbol ?? "•")
                Text(run.analysisAngle?.title ?? "Run")
                    .font(Type.rowTitle)
                    .frame(width: 96, alignment: .leading)

                if run.state.isTerminal {
                    Label(run.state.label, systemImage: run.state.icon)
                        .font(Type.prose)
                        .foregroundStyle(run.state.tint)
                } else {
                    ProgressView().controlSize(.small).scaleEffect(0.7).frame(width: 12, height: 12)
                    if let started = run.startedAt {
                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            Fact(text: Elapsed.short(from: started, to: context.date),
                                 tint: Palette.quiet, small: true)
                        }
                    }
                }

                if let report = run.analysisReport {
                    Fact(text: "\(report.kept) kept", tint: report.kept > 0 ? Palette.verified : .secondary)
                }

                Spacer()

                // The setup screen warns that each lens costs a full read of
                // the repository. This is that warning, settled.
                if let cost = run.totalCostUSD {
                    Fact(text: MoneyFormat.usd(cost), tint: Palette.quiet, small: true)
                }
                if !run.state.isTerminal {
                    Button("Cancel") { Task { await model.cancelRun(id: run.id) } }
                        .controlSize(.small)
                }
                // The recovery, offered exactly where the loss is visible: this
                // row is the thing that reads `0 kept`. The condition is
                // `SkillRun.offersReharvest`'s, not an inline `report.kept == 0`
                // — the rule is pure and `ReharvestRuleTests` holds it, and a
                // second spelling here would be free to disagree about the run
                // that carries no report at all (#330).
                if run.offersReharvest {
                    Button("Harvest again") { Task { await model.reharvest(runID: run.id) } }
                        .controlSize(.small)
                        .help("Re-reads the file this run already wrote. Starts nothing.")
                        .accessibilityLabel(
                            "Harvest \(run.analysisAngle?.title ?? "this lens") again "
                                + "from the file it already wrote")
                }
            }

            if let report = run.analysisReport {
                if report.harvestSource == .resultText {
                    Label(
                        "Recovered from the closing message — no artifact was written.",
                        systemImage: "arrow.uturn.down"
                    )
                    .font(Type.prose)
                    .foregroundStyle(Palette.attention)
                }

                treeBadge(report)

                // The model's own comment says these are "shown, never
                // swallowed". They were in a tooltip on a warning triangle,
                // which is neither.
                if !report.dropped.isEmpty {
                    DisclosureGroup(isExpanded: $showingDropped) {
                        VStack(alignment: .leading, spacing: 3) {
                            ForEach(Array(report.dropped.enumerated()), id: \.offset) { _, reason in
                                Text("• \(reason)")
                                    .font(Type.prose)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        .padding(.top, 2)
                    } label: {
                        Label(
                            report.dropped.count == 1
                                ? "1 story dropped"
                                : "\(report.dropped.count) stories dropped",
                            systemImage: "tray.and.arrow.down"
                        )
                        .font(Type.prose)
                        .foregroundStyle(Palette.attention)
                    }
                }
            }
        }
        .padding(9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Surface.recess)
        .clipShape(RoundedRectangle(cornerRadius: Metric.cardRadius))
    }

    /// `workingTreeChanged` is tri-state, not a plain `Bool`: `nil` means the
    /// sentinel never ran (the app died mid-run and the baseline died with
    /// it), so it must read as "unchecked", never silently as "clean". Only
    /// the confirmed-dirty case is loud — an analysis run has no business
    /// touching the repository, so that is the one worth a red badge.
    @ViewBuilder
    private func treeBadge(_ report: AnalysisRunReport) -> some View {
        switch report.workingTreeChanged {
        case true:
            VStack(alignment: .leading, spacing: 2) {
                Label("This run edited the repository", systemImage: "exclamationmark.octagon.fill")
                    .font(.system(size: 11, weight: .medium))
                if let diff = report.workingTreeDiff, !diff.isEmpty {
                    Text(diff)
                        .font(Type.factSmall)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .foregroundStyle(Palette.refused)
            .padding(6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Surface.wash(Palette.refused))
            .clipShape(RoundedRectangle(cornerRadius: Metric.nestedRadius))
        case false:
            EmptyView()
        case nil:
            Label("Whether it touched the repository is unknown — Elliot quit before the check ran.",
                  systemImage: "questionmark.circle")
                .font(Type.prose)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - A proposal

/// What a proposal row can be asked to do — and, by construction, what it
/// cannot.
///
/// ⛔ **Not four closures beside an `isRejected` flag.** A row in the *Rejected*
/// disclosure that still held an `accept` closure would compile, and the only
/// thing keeping that button off screen would be a view remembering an `if`;
/// this feature exists because a Reject 6pt from an Accept was pressed by
/// mistake, so a second way to fire the wrong one is the last thing it should
/// ship with.
///
/// The **selection** travels inside `decide` for the same reason rather than
/// sitting beside the case. `AppModel.analysisSelection` feeds the footer's
/// *Accept N* / *Reject N*, which act on proposals still open for decision, so a
/// rejected row must not be able to enter it at all — not "must not be drawn
/// with a checkbox".
enum ProposalRowActions {

    /// Still open for decision, in the triage list.
    case decide(
        isSelected: Bool,
        toggle: () -> Void,
        edit: () -> Void,
        accept: () -> Void,
        reject: () -> Void
    )

    /// Taken, and on the board. Carries the sentence naming the card it became
    /// — a `String` rather than a `Card?`, so a row cannot be handed a card and
    /// then decide for itself what an absent one means (#331).
    ///
    /// It offers **no verbs at all**, which is the point of it being its own
    /// case rather than `.settled` with different text: a card exists for this
    /// story, so Accept would make a second one and Reject would be a decision
    /// about something already decided.
    case accepted(String)

    /// Turned down, and able to come back. The one act the rejected group offers.
    case restore(() -> Void)

    /// Turned down, and *not* able to come back: it produced a Backlog card
    /// before it was rejected, so putting it on the list again is how one story
    /// grows two cards. Rendered as a stated fact rather than a disabled
    /// button — a control you cannot press says only that you cannot press it.
    /// See ``StoryProposal/isRestorable``, which is what chooses between this
    /// case and the one above.
    case settled
}

extension ProposalRowActions {
    /// Whether this row was turned down.
    ///
    /// Drives the demotion — recessed ground, struck-through title — so the
    /// list a reader is triaging and the record of what they turned down cannot
    /// be mistaken for each other at a glance.
    ///
    /// ⛔ **Exhaustive, and `.accepted` is deliberately on the other side.** It
    /// lived in `ProposalRow` as `if case .decide { false } else { true }`,
    /// which strikes through an accepted row — saying the story was thrown away
    /// while its card sits on the board. A decided row is not automatically a
    /// refused one, and that distinction arrived with the accepted group (#331).
    ///
    /// On the value rather than in the view for the reason the type's own
    /// comment gives about the closures: what a row *is* travels with what it
    /// may *do*, so a fifth case has to answer both questions at once.
    var isRefusal: Bool {
        switch self {
        case .decide, .accepted: false
        case .restore, .settled: true
        }
    }

    /// Whether this row is staged for the footer's bulk Accept / Reject.
    ///
    /// Only `.decide` can be, by construction — the selection travels *inside*
    /// that case precisely so a decided row cannot enter
    /// `AppModel.analysisSelection` at all.
    var isStaged: Bool {
        if case .decide(let isSelected, _, _, _, _) = self { return isSelected }
        return false
    }
}

struct ProposalRow: View {
    let proposal: StoryProposal
    let actions: ProposalRowActions
    let repoPath: String?

    @State private var hovering = false
    @State private var showingCriteria = false

    /// Both read off the one value that knows — see ``ProposalRowActions``.
    private var isRejected: Bool { actions.isRefusal }
    private var isSelected: Bool { actions.isStaged }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            if case .decide(_, let toggle, _, _, _) = actions {
                Toggle("", isOn: Binding(get: { isSelected }, set: { _ in toggle() }))
                    .labelsHidden()
                    .accessibilityLabel("Select \(proposal.title)")
            }

            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(proposal.title)
                        .font(Type.cardTitle)
                        .strikethrough(isRejected)
                        .foregroundStyle(isRejected ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                        .fixedSize(horizontal: false, vertical: true)
                    EffortChip(effort: proposal.effort)
                    Spacer(minLength: 0)
                    if hovering {
                        switch actions {
                        case .decide(_, _, let edit, let accept, let reject):
                            Button("Edit", action: edit)
                                .buttonStyle(.plain)
                                .font(Type.prose)
                            Button("Reject", action: reject)
                                .buttonStyle(.plain)
                                .font(Type.prose)
                            Button("Accept", action: accept)
                                .buttonStyle(.plain)
                                .font(Type.prose)
                        case .restore(let restore):
                            Button("Restore", action: restore)
                                .buttonStyle(.plain)
                                .font(Type.prose)
                        case .accepted, .settled:
                            EmptyView()
                        }
                    }
                }

                Text(proposal.story.narrative)
                    .font(Type.prose)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if !proposal.rationale.isEmpty {
                    Text(proposal.rationale)
                        .font(Type.prose)
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                // The one objective fact available about an opinion: the files
                // it points at are either there or they are not.
                if !proposal.evidence.isEmpty {
                    HStack(spacing: 5) {
                        Image(systemName: proposal.isGrounded ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(proposal.isGrounded ? Palette.verified : Palette.refused)
                            // Grounding is this feature's `verifiedOutcome` —
                            // the difference between a story that was found and
                            // one that was written. It was carried by colour
                            // alone.
                            .accessibilityLabel(groundingLabel)
                        ForEach(proposal.evidence, id: \.self) { evidence in
                            EvidenceLink(evidence: evidence, repoPath: repoPath)
                        }
                        Spacer(minLength: 0)
                    }
                } else {
                    Label("No evidence cited", systemImage: "exclamationmark.triangle.fill")
                        .font(Type.prose)
                        .foregroundStyle(Palette.refused)
                }

                // These were a tooltip. The dropped-stories list one panel up
                // is a disclosure for exactly this reason — its own comment
                // says a tooltip is neither shown nor discoverable — and these
                // are the criteria you are deciding to accept.
                if !proposal.story.acceptanceCriteria.isEmpty {
                    DisclosureGroup(isExpanded: $showingCriteria) {
                        VStack(alignment: .leading, spacing: 3) {
                            ForEach(
                                Array(proposal.story.acceptanceCriteria.enumerated()), id: \.offset
                            ) { index, item in
                                HStack(alignment: .firstTextBaseline, spacing: 6) {
                                    Fact(text: "\(index + 1)", tint: Palette.quiet, small: true)
                                    Text(item)
                                        .font(Type.prose)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                        .padding(.top, 2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    } label: {
                        Text("\(proposal.story.acceptanceCriteria.count) acceptance criteria")
                            .font(Type.factSmall)
                            .foregroundStyle(.tertiary)
                    }
                }

                if let hint = proposal.duplicateOf?.label {
                    Label(hint, systemImage: "doc.on.doc")
                        .font(Type.prose)
                        .foregroundStyle(Palette.attention)
                        .fixedSize(horizontal: false, vertical: true)
                }

                // The card this story became, named. Without it an accepted row
                // is a row with no verbs and nothing to say, which reads as the
                // list being broken rather than as the record it is — and the
                // sentence is `ProposalReview.cardLabel`'s, so the case where
                // the card cannot be found still reads as an acceptance (#331).
                if case .accepted(let cardLabel) = actions {
                    Label(cardLabel, systemImage: "tray.and.arrow.down.fill")
                        .font(Type.prose)
                        .foregroundStyle(Palette.verified)
                        .fixedSize(horizontal: false, vertical: true)
                }

                // Why this one row carries no Restore, said in words. Without
                // it the rejected group has a row that simply does nothing on
                // hover, which reads as the feature being broken rather than as
                // the refusal it is.
                if case .settled = actions {
                    Label(
                        "Already accepted — its card is on the board, so this cannot go back.",
                        systemImage: "tray.and.arrow.down.fill"
                    )
                    .font(Type.prose)
                    .foregroundStyle(Palette.attention)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(rowGround)
        .clipShape(RoundedRectangle(cornerRadius: Metric.cardRadius))
        .overlay {
            RoundedRectangle(cornerRadius: Metric.cardRadius)
                .strokeBorder(isSelected ? Surface.washBorder(Palette.armed) : Color.clear)
        }
        // Driven by the `.animation(reduceMotion ? nil : …, value:
        // proposed.map(\.id))` on the list this row sits in — accepting or
        // rejecting a proposal changes exactly that value. Reduce motion
        // switches it off there, once, for every row.
        .transition(.opacity.combined(with: .scale(scale: 0.98)))
        .onHover { hovering = $0 }
        // The row's actions appear on hover, which is fine for a pointer and
        // nothing at all for a keyboard or VoiceOver. The context menu is the
        // conventional discoverable path; the accessibility actions are the
        // reachable one. Hover alone would repeat the defect the board's cards
        // already had — and it is why Restore gets all three, not just the
        // hover button: an undo only reachable by pointer is an undo half the
        // readers of this panel do not have.
        .modifier(ProposalRowMenu(actions: actions))
    }

    /// Recessed further than the triage rows, which is the demotion made
    /// visible: `Surface.recess` is what an open proposal sits on, and
    /// `recessFaint` is the same ground one step quieter.
    private var rowGround: Color {
        if isRejected { return Surface.recessFaint }
        return isSelected ? Surface.wash(Palette.armed) : Surface.recess
    }

    private var groundingLabel: String {
        if proposal.isGrounded { return "Grounded — every cited file exists" }
        let missing = proposal.evidence.filter { !$0.exists }.count
        return missing == 1
            ? "1 cited file is not in the repository"
            : "\(missing) cited files are not in the repository"
    }
}

/// The row's keyboard- and VoiceOver-reachable acts, chosen by the same value
/// that chose its buttons.
///
/// ⚠️ **A modifier rather than three `.contextMenu`/`.accessibilityAction`
/// calls guarded by `if`s in the row's body.** `.contextMenu { }` with an empty
/// builder still installs a menu — a right-click on a settled row would open an
/// empty popover — and `.accessibilityAction` cannot be applied conditionally
/// without either this or an `AnyView`. Switching once, here, is also what makes
/// "the hover buttons and the reachable actions are the same set" a fact about
/// one value instead of an agreement between two places.
private struct ProposalRowMenu: ViewModifier {
    let actions: ProposalRowActions

    func body(content: Content) -> some View {
        switch actions {
        case .decide(_, _, let edit, let accept, let reject):
            content
                .contextMenu {
                    Button("Accept into Backlog", systemImage: "tray.and.arrow.down", action: accept)
                    Button("Edit before accepting", systemImage: "pencil", action: edit)
                    Divider()
                    Button("Reject", systemImage: "xmark", role: .destructive, action: reject)
                }
                .accessibilityElement(children: .contain)
                .accessibilityAction(named: "Accept into Backlog", accept)
                .accessibilityAction(named: "Edit before accepting", edit)
                .accessibilityAction(named: "Reject", reject)
        case .restore(let restore):
            content
                .contextMenu {
                    Button("Restore to the list", systemImage: "arrow.uturn.backward", action: restore)
                }
                .accessibilityElement(children: .contain)
                .accessibilityAction(named: "Restore to the list", restore)
        case .accepted, .settled:
            // No menu at all. See the ⚠️ above: an empty one is a popover with
            // nothing in it, which is worse than none. Both of these rows are
            // records rather than decisions.
            content.accessibilityElement(children: .contain)
        }
    }
}

struct EffortChip: View {
    let effort: Effort

    var body: some View {
        Text(effort.rawValue)
            .font(Type.factSmall)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(Surface.chipFill)
            .foregroundStyle(.secondary)
            .clipShape(Capsule())
            .help("The analysis's own guess at the size of this change")
    }
}

/// A cited file. Set in the fact face because it was read off the repository,
/// and openable — the whole reason to cite it is that the reader can go look.
struct EvidenceLink: View {
    let evidence: Evidence
    let repoPath: String?

    var body: some View {
        // Two states rather than one disabled button: a disabled control is
        // skipped by VoiceOver, so "this file does not exist" — the strongest
        // signal on the screen that a story may have been invented — was
        // carried by a strikethrough and a tooltip and nothing else.
        if evidence.exists, let repoPath {
            Button {
                let full = (repoPath as NSString).appendingPathComponent(evidence.path)
                NSWorkspace.shared.selectFile(full, inFileViewerRootedAtPath: repoPath)
            } label: {
                chip
            }
            .buttonStyle(.plain)
            .help("\(evidence.display) — click to reveal it in the Finder")
            .accessibilityLabel("\(evidence.display), present in the repository")
            .accessibilityHint("Reveals it in the Finder")
        } else {
            chip
                .help(evidence.exists
                    ? evidence.display
                    : "\(evidence.display) is not in the repository. This story may have been invented.")
                .accessibilityLabel(evidence.exists
                    ? evidence.display
                    : "\(evidence.display), not in the repository")
        }
    }

    private var chip: some View {
        Text(short)
            .font(Type.factSmall)
            .strikethrough(!evidence.exists)
            .foregroundStyle(evidence.exists ? Color.secondary : Palette.refused)
            .lineLimit(1)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(Surface.chipFill)
            .clipShape(RoundedRectangle(cornerRadius: 4))
    }

    /// The file name and line, not the whole path.
    ///
    /// Two full repository-relative paths side by side ran together into one
    /// unreadable line; the path that disambiguates them is one hover away, and
    /// the point of the citation at a glance is *which file*, not *where*.
    private var short: String {
        let name = (evidence.path as NSString).lastPathComponent
        return evidence.line.map { "\(name):\($0)" } ?? name
    }
}

/// Correcting a proposal before it becomes a card.
///
/// The point of editing here rather than after: the corrected story is what
/// reaches the board, so a nearly-right proposal is worth keeping instead of
/// rejecting and retyping.
struct ProposalEditor: View {
    @Environment(AppModel.self) private var model

    /// The one editable state. It was two — a `StoryProposal` and a separate
    /// `[String]` of criteria reconciled only inside the Save closure, which
    /// left `draft.story.acceptanceCriteria` stale for the editor's whole life.
    /// A preview rendered off that value would have shown the pre-edit story.
    ///
    /// ⛔ **A `Binding`, not `@State`, and it is seeded elsewhere.** It was
    /// `@State` built in `init`, which meant hiding the panel — `⌘⌥A`, the
    /// Analyse toggle, the header `✕` — removed `.analysis` from `boardOrder`,
    /// tore this subtree down, and took a retyped title and eight acceptance
    /// criteria with it. Silently: nothing distinguishes a draft that was lost
    /// from one that was never typed. The panel's own type comment promised the
    /// hide loses nothing, and named the two pieces of state that had been
    /// moved; this was the third (#291).
    @Binding private var draft: CardDraft
    /// What is not edited here: the proposal's rationale, evidence, effort,
    /// angle and identity. `draft.applied(to:)` puts the edits back on top.
    private let proposal: StoryProposal
    /// Called when the editor is finished with, saved or not. The list owns
    /// which row is being edited; this view only says it is done.
    private let done: () -> Void

    init(proposal: StoryProposal, draft: Binding<CardDraft>, done: @escaping () -> Void) {
        self.proposal = proposal
        self.done = done
        _draft = draft
    }

    /// Inline in the list, not over it.
    ///
    /// It has no scroll view and no fixed height any more: as a sheet it needed
    /// both, because eight acceptance criteria opened it already overflowing
    /// with Save below the bottom edge and no way to resize a macOS sheet. In
    /// the list the enclosing scroll view is the one the reader is already
    /// using, and the row is simply as tall as it needs to be.
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Edit proposal").font(Type.sheetTitle)
                Text("What you save here is what reaches the board.")
                    .font(Type.prose)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(18)

            Divider()

            VStack(alignment: .leading, spacing: 14) {
                // The card editor's fields, not a second copy of them. The
                // guarded criterion removal, the one validity rule and the
                // single `field()` helper all live over there; this row
                // renders the same controls the board's own editor does.
                CardFieldsEditor(draft: $draft, kind: .story)

                // The provenance stays here: it is the proposal's, not the
                // draft's, and it is displayed rather than edited.
                if !proposal.evidence.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        ConsoleLabel(text: "Evidence")
                        Text(proposal.evidence.map(\.display).joined(separator: "   "))
                            .font(Type.factSmall)
                            .foregroundStyle(.tertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)

            Divider()

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { done() }
                Button("Save") {
                    let edited = draft.applied(to: proposal)
                    Task {
                        // ⛔ **Closes only when the write landed.** It used to
                        // close unconditionally, so a failed save dismissed the
                        // editor exactly like a successful one and the reader's
                        // next sight was the old text — which reads as the app
                        // having forgotten rather than as a write having failed
                        // (#223). The panel's note carries the reason; the
                        // editor staying open is what makes it findable.
                        guard await model.updateProposal(edited) == nil else { return }
                        done()
                    }
                }
                .keyboardShortcut(.defaultAction)
                // The card editor's rule, not a second spelling of it. The one
                // written here trimmed on `.whitespaces` where `CardDraft`
                // trims on `.whitespacesAndNewlines`, so a title that was only
                // a newline was refused by the board and accepted here.
                .disabled(!draft.isValid)
            }
            .padding(18)
        }
        .background(Surface.recess)
        .clipShape(RoundedRectangle(cornerRadius: Metric.cardRadius))
        .overlay {
            RoundedRectangle(cornerRadius: Metric.cardRadius)
                .strokeBorder(Surface.washBorder(Palette.armed), lineWidth: 1)
        }
        // Escape cancels the edit. Without it the key would fall through to the
        // window, which is the wrong thing to close while a row is open.
        .onExitCommand { done() }
    }
}
