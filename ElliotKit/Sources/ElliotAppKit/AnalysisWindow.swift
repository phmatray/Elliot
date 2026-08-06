import ElliotEngine
import ElliotModel
import SwiftUI

/// One window that starts as a form and becomes a review list.
///
/// Deliberately not two sheets: once the runs are going, the proposals appear
/// under them angle by angle. Splitting them would hide the thing that makes
/// one run per angle worth paying for — the quick wins are triable while the
/// bugs angle is still reading.
///
/// The lens strip is the same object in both states: the tiles you arm become
/// the row you watch. That is what makes the single window legible rather than
/// merely economical.
///
/// The board's rule carries over here. Evidence is set in the fact face because
/// it was read off the repository, and `isGrounded` — every cited file actually
/// present — is this feature's `verifiedOutcome`: the difference between a
/// story that was found and one that was written.
/// `public` only because `ElliotApp` names it in a `Scene`. Everything else in
/// this target stays internal — the tests reach it with `@testable`, and a
/// library that exports its whole surface has stopped being a boundary.
public struct AnalysisWindow: View {
    public init() {}

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var angles: Set<AnalysisAngle> = [.bugs, .quickWins]
    @State private var instructions = ""
    @State private var maxStories = 8
    @State private var selection: Set<UUID> = []
    @State private var editing: StoryProposal?
    @State private var past: [Analysis] = []
    /// `nil` until the reader opens or closes the strip themselves.
    @State private var lensesExpanded: Bool?

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()

            if model.activeAnalysisID == nil {
                setup
            } else {
                review
            }

            Divider()
            footer
        }
        // A window, not a modal sheet: this screen starts up to six concurrent
        // runs and then watches them for minutes. The note that used to live
        // above the footer is now *in* it — inserting a row between the list
        // and the buttons moved the buttons out from under the cursor that had
        // just pressed one.
        .frame(minWidth: 760, idealWidth: 900, minHeight: 560, idealHeight: 760)
        .sheet(item: $editing) { proposal in
            ProposalEditor(proposal: proposal)
        }
        .task { past = await model.recentAnalyses() }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Analyse \(repoName)").font(Type.sheetTitle)
                Text(model.activeAnalysisID == nil
                    ? "Read this repository through several lenses and propose stories for the backlog."
                    : "Accept what you want on the board. Nothing here is a card until you do.")
                    .font(Type.prose)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if !past.isEmpty, model.activeAnalysisID == nil {
                Menu {
                    ForEach(past) { analysis in
                        Button(label(for: analysis)) { model.openAnalysis(id: analysis.id) }
                    }
                } label: {
                    Label("Earlier analyses", systemImage: "clock.arrow.circlepath")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
        }
        .padding(16)
    }

    private var repoName: String { repo?.displayName ?? "…" }
    private var repo: Repo? { model.repos.first { $0.id == model.selectedRepoID } }

    /// Says what the analysis looked at and what came back, rather than a date
    /// beside a row of emoji.
    private func label(for analysis: Analysis) -> String {
        let when = analysis.createdAt.formatted(date: .abbreviated, time: .shortened)
        let lenses = analysis.angles.map(\.title).joined(separator: ", ")
        return "\(when) — \(lenses)"
    }

    // MARK: - Setup

    private var setup: some View {
        ScrollView {
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
                            LensTile(angle: angle, isOn: angles.contains(angle)) {
                                if angles.contains(angle) { angles.remove(angle) } else { angles.insert(angle) }
                            }
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 6) {
                    ConsoleLabel(text: "Limit")
                    Stepper(value: $maxStories, in: 1...30) {
                        Text("Keep at most \(maxStories) stories from each lens")
                            .font(Type.bodyProse)
                    }
                    .fixedSize()
                }

                VStack(alignment: .leading, spacing: 6) {
                    ConsoleLabel(text: "Extra instructions")
                    Text("Folded into every lens's prompt. Leave it empty unless you want to steer them.")
                        .font(Type.prose)
                        .foregroundStyle(.secondary)
                    TextEditor(text: $instructions)
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

    private var review: some View {
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
                    lensesExpanded = !isLensStripOpen
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: isLensStripOpen ? "chevron.down" : "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.secondary)
                        ConsoleLabel(text: "Lenses")
                        if !isLensStripOpen { lensSummary }
                        Spacer()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if isLensStripOpen {
                    ForEach(model.analysisRuns) { run in
                        LensRunRow(run: run, repoPath: repo?.path)
                    }
                }
            }
            .padding(16)

            Divider()
            proposalList
        }
    }

    /// Open while anything is still reading, closed once it is all in — unless
    /// the reader has said otherwise, which then sticks.
    private var isLensStripOpen: Bool {
        lensesExpanded ?? !model.analysisRuns.allSatisfy { $0.state.isTerminal }
    }

    /// What the collapsed strip still has to say.
    ///
    /// Every alarm survives the collapse. A run that edited the repository is
    /// exactly the thing that must not become invisible because the panel it
    /// lived in was tidied away.
    @ViewBuilder
    private var lensSummary: some View {
        let reports = model.analysisRuns.compactMap(\.analysisReport)
        let kept = reports.reduce(0) { $0 + $1.kept }
        let dropped = reports.reduce(0) { $0 + $1.dropped.count }
        let edited = reports.filter { $0.workingTreeChanged == true }.count
        let recovered = reports.filter { $0.harvestSource == .resultText }.count

        HStack(spacing: 8) {
            Fact(text: "\(model.analysisRuns.count) lenses", small: true)
            Fact(text: "\(kept) kept", tint: Palette.verified, small: true)
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

    private var proposed: [StoryProposal] {
        model.proposals.filter { $0.status == .proposed }
    }

    private var proposalList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 14) {
                if proposed.isEmpty {
                    emptyReview
                } else {
                    selectionBar
                    ForEach(AnalysisAngle.allCases, id: \.self) { angle in
                        let group = proposed.filter { $0.angle == angle }
                        if !group.isEmpty {
                            angleSection(angle, group)
                        }
                    }
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            // Accepting or rejecting a row made it vanish instantly, so a list
            // of twelve became a list of eleven with no sign of which one went.
            .animation(reduceMotion ? nil : .snappy(duration: 0.2), value: proposed.map(\.id))
        }
    }

    private func angleSection(_ angle: AnalysisAngle, _ group: [StoryProposal]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(angle.symbol)
                ConsoleLabel(text: angle.title, tint: .primary)
                Fact(text: "\(group.count)", tint: Palette.quiet, small: true)
                Spacer()
                Button(allSelected(group) ? "Clear" : "Select all") {
                    let ids = group.map(\.id)
                    if allSelected(group) {
                        ids.forEach { selection.remove($0) }
                    } else {
                        selection.formUnion(ids)
                    }
                }
                // No accent: choosing rows starts nothing and merges nothing.
                // The five accents mean consequence, and spending three of them
                // on triage controls is what made them stop reading as one.
                .buttonStyle(.plain)
                .font(Type.prose)
            }

            ForEach(group) { proposal in
                ProposalRow(
                    proposal: proposal,
                    isSelected: selection.contains(proposal.id),
                    repoPath: repo?.path,
                    toggle: {
                        if selection.contains(proposal.id) {
                            selection.remove(proposal.id)
                        } else {
                            selection.insert(proposal.id)
                        }
                    },
                    edit: { editing = proposal },
                    accept: { Task { await model.acceptProposals(ids: [proposal.id]) } },
                    reject: { Task { await model.rejectProposals(ids: [proposal.id]) } }
                )
            }
        }
    }

    private func allSelected(_ group: [StoryProposal]) -> Bool {
        !group.isEmpty && group.allSatisfy { selection.contains($0.id) }
    }

    /// Grounding is the one objective fact available about an opinion, so it is
    /// the one bulk selection worth offering.
    private var selectionBar: some View {
        HStack(spacing: 10) {
            Fact(text: "\(selection.count) of \(proposed.count) selected", small: true)
            Spacer()
            let grounded = proposed.filter(\.isGrounded).map(\.id)
            Button("Select the \(grounded.count) grounded") {
                selection = Set(grounded)
            }
            .buttonStyle(.plain)
            .font(Type.prose)
            .disabled(grounded.isEmpty)

            Button("Clear") { selection = [] }
                .buttonStyle(.plain)
                .font(Type.prose)
                .disabled(selection.isEmpty)
        }
    }

    @ViewBuilder
    private var emptyReview: some View {
        let waiting = model.runningAngles
        VStack(alignment: .leading, spacing: 6) {
            if waiting.isEmpty {
                Label("Nothing left to decide.", systemImage: "checkmark.circle")
                    .font(Type.cardTitle)
                Text("Every proposal has been accepted or rejected. Close this window and the accepted ones are waiting in Backlog.")
                    .font(Type.prose)
                    .foregroundStyle(.secondary)
            } else {
                Label(
                    "Reading — \(waiting.map(\.title).joined(separator: ", "))",
                    systemImage: "hourglass"
                )
                .font(Type.cardTitle)
                Text("Proposals appear here lens by lens, as each run finishes. You can accept the first ones while the rest are still reading.")
                    .font(Type.prose)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 20)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 10) {
            if model.activeAnalysisID == nil {
                // The same promise the board's columns make: say what the
                // gesture will do before it is made. Each lens is a full read
                // of the repository, and that is what the button is spending.
                Label(startConsequence, systemImage: "bolt.fill")
                    .font(Type.prose)
                    .foregroundStyle(angles.isEmpty ? Palette.refused : Palette.armed)
            } else if !selection.isEmpty {
                // A count of your own clicks is not a consequence, so it
                // carries no accent.
                Fact(text: "\(selection.count) selected")
            } else if let note = model.analysisNote {
                Label(note, systemImage: "info.circle")
                    .font(Type.prose)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .id(note)
                    .transition(.opacity)
            }

            Spacer()

            Button("Close", role: .cancel) {
                model.closeAnalysis()
                dismiss()
            }

            if model.activeAnalysisID == nil {
                Button("Start \(angles.count) run\(angles.count == 1 ? "" : "s")") {
                    guard let repoID = model.selectedRepoID else { return }
                    Task {
                        await model.startAnalysis(
                            repoID: repoID,
                            angles: AnalysisAngle.allCases.filter(angles.contains),
                            instructions: instructions,
                            maxStories: maxStories
                        )
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(angles.isEmpty || model.selectedRepoID == nil)
                // The one genuinely armed control on this screen — it starts N
                // unattended runs — and it was the only one with no tint, while
                // six inert triage buttons had one each.
                .tint(Palette.armed)
            } else {
                // Editing was reachable by hover and by context menu, neither
                // of which a keyboard can open on macOS.
                Button("Edit…") {
                    editing = proposed.first { selection.contains($0.id) }
                }
                .disabled(selection.count != 1)

                Button(selection.isEmpty ? "Reject" : "Reject \(selection.count)") {
                    let ids = Array(selection)
                    selection = []
                    Task { await model.rejectProposals(ids: ids) }
                }
                .disabled(selection.isEmpty)

                // One verb per act. The row buttons, the context menu and this
                // all say "Accept"; "Add to Backlog" was a third name for it.
                Button(selection.isEmpty ? "Accept" : "Accept \(selection.count)") {
                    let ids = Array(selection)
                    selection = []
                    Task { await model.acceptProposals(ids: ids) }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(selection.isEmpty)
            }
        }
        .padding(16)
        .animation(.snappy(duration: 0.18), value: model.analysisNote)
    }

    private var startConsequence: String {
        switch angles.count {
        case 0: "Pick at least one lens."
        case 1: "Reads the repository once."
        default: "Reads the repository \(angles.count) times — one run per lens."
        }
    }
}

// MARK: - A lens, before it runs

/// An angle as something you arm, not a row in a settings list. The six lenses
/// are what this feature *is*; a column of checkboxes says otherwise.
struct LensTile: View {
    let angle: AnalysisAngle
    let isOn: Bool
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(angle.symbol)
                    Text(angle.title).font(Type.rowTitle)
                    Spacer()
                    Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 12))
                        .foregroundStyle(isOn ? Palette.armed : Color.secondary.opacity(0.5))
                }
                Text(angle.briefing)
                    .font(Type.prose)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isOn ? Surface.wash(Palette.armed) : Surface.recess)
            .clipShape(RoundedRectangle(cornerRadius: Metric.panelRadius))
            .overlay {
                RoundedRectangle(cornerRadius: Metric.panelRadius)
                    .strokeBorder(isOn
                        ? Surface.washBorder(Palette.armed)
                        : Color(nsColor: .separatorColor))
            }
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isOn ? [.isButton, .isSelected] : .isButton)
        .accessibilityLabel("\(angle.title). \(angle.briefing)")
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

struct ProposalRow: View {
    let proposal: StoryProposal
    let isSelected: Bool
    let repoPath: String?
    let toggle: () -> Void
    let edit: () -> Void
    let accept: () -> Void
    let reject: () -> Void

    @State private var hovering = false
    @State private var showingCriteria = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Toggle("", isOn: Binding(get: { isSelected }, set: { _ in toggle() }))
                .labelsHidden()
                .accessibilityLabel("Select \(proposal.title)")

            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(proposal.title)
                        .font(Type.cardTitle)
                        .fixedSize(horizontal: false, vertical: true)
                    EffortChip(effort: proposal.effort)
                    Spacer(minLength: 0)
                    if hovering {
                        Button("Edit", action: edit)
                            .buttonStyle(.plain)
                            .font(Type.prose)
                        Button("Reject", action: reject)
                            .buttonStyle(.plain)
                            .font(Type.prose)
                        Button("Accept", action: accept)
                            .buttonStyle(.plain)
                            .font(Type.prose)
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
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isSelected ? Surface.wash(Palette.armed) : Surface.recess)
        .clipShape(RoundedRectangle(cornerRadius: Metric.cardRadius))
        .overlay {
            RoundedRectangle(cornerRadius: Metric.cardRadius)
                .strokeBorder(isSelected ? Surface.washBorder(Palette.armed) : Color.clear)
        }
        .transition(.opacity.combined(with: .scale(scale: 0.98)))
        .onHover { hovering = $0 }
        // The row's three actions appear on hover, which is fine for a pointer
        // and nothing at all for a keyboard or VoiceOver. The context menu is
        // the conventional discoverable path; the accessibility actions are the
        // reachable one. Hover alone would repeat the defect the board's cards
        // already had.
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
    }

    private var groundingLabel: String {
        if proposal.isGrounded { return "Grounded — every cited file exists" }
        let missing = proposal.evidence.filter { !$0.exists }.count
        return missing == 1
            ? "1 cited file is not in the repository"
            : "\(missing) cited files are not in the repository"
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
    @Environment(\.dismiss) private var dismiss

    @State private var draft: StoryProposal
    @State private var criteria: [String]

    init(proposal: StoryProposal) {
        _draft = State(initialValue: proposal)
        _criteria = State(initialValue: proposal.story.acceptanceCriteria.isEmpty
            ? [""]
            : proposal.story.acceptanceCriteria)
    }

    /// The fields scroll; the title and the buttons do not. A lens that returns
    /// eight acceptance criteria opened this sheet already overflowing, with
    /// Save below the bottom edge and no way to resize a macOS sheet.
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

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    VStack(alignment: .leading, spacing: 4) {
                        ConsoleLabel(text: "Board label")
                        TextField("Short name for the card", text: $draft.title)
                            .textFieldStyle(.roundedBorder)
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        field("As a", placeholder: "developer", text: $draft.story.role)
                        field("I want", placeholder: "to see the run log inside the card", text: $draft.story.want)
                        field("So that", placeholder: "I can diagnose without opening a terminal", text: $draft.story.benefit)
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        ConsoleLabel(text: "Acceptance criteria")
                        ForEach(criteria.indices, id: \.self) { index in
                            HStack(spacing: 6) {
                                TextField("What has to be true when it is done", text: Binding(
                                    get: { criteria.indices.contains(index) ? criteria[index] : "" },
                                    set: { if criteria.indices.contains(index) { criteria[index] = $0 } }
                                ))
                                .textFieldStyle(.roundedBorder)
                                Button {
                                    criteria.remove(at: index)
                                    if criteria.isEmpty { criteria = [""] }
                                } label: {
                                    Image(systemName: "minus.circle")
                                }
                                .buttonStyle(.borderless)
                                .accessibilityLabel("Remove criterion \(index + 1)")
                            }
                        }
                        Button("Add criterion", systemImage: "plus") { criteria.append("") }
                            .buttonStyle(.borderless)
                            .controlSize(.small)
                    }

                    if !draft.evidence.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            ConsoleLabel(text: "Evidence")
                            Text(draft.evidence.map(\.display).joined(separator: "   "))
                                .font(Type.factSmall)
                                .foregroundStyle(.tertiary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .padding(18)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Divider()

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button("Save") {
                    var edited = draft
                    edited.story.acceptanceCriteria = criteria
                        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                        .filter { !$0.isEmpty }
                    Task {
                        await model.updateProposal(edited)
                        dismiss()
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!draft.story.isComplete || draft.title.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(18)
        }
        .frame(width: 580, height: 560)
    }

    private func field(_ label: String, placeholder: String, text: Binding<String>) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .font(Type.prose)
                .foregroundStyle(.secondary)
                .frame(width: 52, alignment: .trailing)
            TextField(placeholder, text: text)
                .textFieldStyle(.roundedBorder)
        }
    }
}
