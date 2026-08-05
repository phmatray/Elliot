import ElliotEngine
import ElliotModel
import SwiftUI

/// One window that starts as a form and becomes a review list.
///
/// Deliberately not two sheets: once the runs are going, the proposals appear
/// under them angle by angle. Splitting them would hide the thing that makes
/// one run per angle worth paying for — the quick wins are triable while the
/// bugs angle is still reading.
struct AnalysisWindow: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var angles: Set<AnalysisAngle> = [.bugs, .quickWins]
    @State private var instructions = ""
    @State private var maxStories = 8
    @State private var selection: Set<UUID> = []
    @State private var editing: StoryProposal?
    @State private var past: [Analysis] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            Divider()

            if model.activeAnalysisID == nil {
                setup
            } else {
                running
            }

            if let note = model.analysisNote {
                Text(note).font(.callout).foregroundStyle(.secondary)
            }

            Divider()
            footer
        }
        .padding(16)
        .frame(width: 720, height: 640)
        .sheet(item: $editing) { proposal in
            ProposalEditor(proposal: proposal)
        }
        .task { past = await model.recentAnalyses() }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Analyze \(repoName)").font(.title2.bold())
            Spacer()
            if !past.isEmpty, model.activeAnalysisID == nil {
                Menu("Past analyses") {
                    ForEach(past) { analysis in
                        Button(label(for: analysis)) { model.openAnalysis(id: analysis.id) }
                    }
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
        }
    }

    private var repoName: String {
        model.repos.first { $0.id == model.selectedRepoID }?.displayName ?? "…"
    }

    private func label(for analysis: Analysis) -> String {
        let when = analysis.createdAt.formatted(date: .abbreviated, time: .shortened)
        let lenses = analysis.angles.map(\.symbol).joined()
        return "\(when)  \(lenses)"
    }

    // MARK: - Setup

    private var setup: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Each angle is its own run. Pick the ones you want — they cost a full read of the repository each.")
                    .font(.callout)
                    .foregroundStyle(.secondary)

                ForEach(AnalysisAngle.allCases, id: \.self) { angle in
                    Toggle(isOn: binding(for: angle)) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(angle.symbol)  \(angle.title)")
                            Text(angle.briefing)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }

                Stepper("At most \(maxStories) stories per angle", value: $maxStories, in: 1...30)

                VStack(alignment: .leading, spacing: 4) {
                    Text("Anything else to steer it").font(.caption.bold())
                    TextEditor(text: $instructions)
                        .font(.body)
                        .frame(height: 70)
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(.separator))
                }
            }
        }
    }

    private func binding(for angle: AnalysisAngle) -> Binding<Bool> {
        Binding(
            get: { angles.contains(angle) },
            // Not a ternary: `Set.insert` returns a tuple and `.remove`
            // returns `Element?`, so the two branches don't unify.
            set: { on in
                if on { angles.insert(angle) } else { angles.remove(angle) }
            }
        )
    }

    // MARK: - Running and reviewing

    private var running: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(model.analysisRuns) { run in
                runRow(run)
            }

            Divider()
            proposalList
        }
    }

    private func runRow(_ run: SkillRun) -> some View {
        HStack(spacing: 8) {
            Text(run.analysisAngle?.symbol ?? "•")
            Text(run.analysisAngle?.title ?? "run").frame(width: 110, alignment: .leading)
            if run.state.isTerminal {
                Text(run.state.rawValue).font(.caption).foregroundStyle(.secondary)
            } else {
                ProgressView().controlSize(.small)
            }
            if let report = run.analysisReport {
                Text("\(report.kept) kept").font(.caption).foregroundStyle(.secondary)
                if !report.dropped.isEmpty {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .help(report.dropped.joined(separator: "\n"))
                }
                if report.harvestSource == .resultText {
                    Text("recovered from the reply")
                        .font(.caption).foregroundStyle(.orange)
                        .help("No artifact was written; the stories were salvaged from the closing message.")
                }
                treeBadge(report)
            }
            Spacer()
            if !run.state.isTerminal {
                Button("Cancel") { Task { await model.cancelRun(id: run.id) } }
                    .buttonStyle(.borderless)
                    .font(.caption)
            }
        }
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
            Label("edited the repo", systemImage: "exclamationmark.octagon")
                .font(.caption)
                .foregroundStyle(.red)
                .help(report.workingTreeDiff ?? "")
        case false:
            EmptyView()
        case nil:
            Image(systemName: "questionmark.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
                .help("""
                    Elliot quit before this run's sentinel could compare the \
                    working tree, so whether it changed anything is unknown.
                    """)
        }
    }

    private var proposalList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 10) {
                ForEach(AnalysisAngle.allCases, id: \.self) { angle in
                    let group = model.proposals.filter { $0.angle == angle && $0.status == .proposed }
                    if !group.isEmpty {
                        Text("\(angle.symbol)  \(angle.title.uppercased())  (\(group.count))")
                            .font(.caption.bold())
                            .foregroundStyle(.secondary)
                        ForEach(group) { proposal in
                            row(proposal)
                        }
                    }
                }
                if model.proposals.allSatisfy({ $0.status != .proposed }), !model.analysisRuns.isEmpty {
                    Text(model.runningAngles.isEmpty
                        ? "Nothing left to decide."
                        : "Waiting on \(model.runningAngles.map(\.title).joined(separator: ", "))…")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .padding(.top, 8)
                }
            }
        }
    }

    private func row(_ proposal: StoryProposal) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Toggle("", isOn: Binding(
                get: { selection.contains(proposal.id) },
                // Same shape mismatch as the angle toggles above: `.insert`
                // and `.remove` return different types, so this cannot be a
                // ternary.
                set: { on in
                    if on { selection.insert(proposal.id) } else { selection.remove(proposal.id) }
                }
            ))
            .labelsHidden()

            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(proposal.title).font(.body.weight(.medium))
                    Text(proposal.effort.rawValue)
                        .font(.caption2)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Color.secondary.opacity(0.15))
                        .clipShape(Capsule())
                    Spacer()
                    Button("Edit") { editing = proposal }
                        .buttonStyle(.borderless).font(.caption)
                }
                Text(proposal.story.narrative).font(.caption).foregroundStyle(.secondary)

                if !proposal.story.acceptanceCriteria.isEmpty {
                    Text("✓ \(proposal.story.acceptanceCriteria.count) criteria")
                        .font(.caption2).foregroundStyle(.secondary)
                        .help(proposal.story.acceptanceCriteria.joined(separator: "\n"))
                }
                if !proposal.rationale.isEmpty {
                    Text(proposal.rationale).font(.caption2).foregroundStyle(.secondary)
                }

                HStack(spacing: 6) {
                    ForEach(proposal.evidence, id: \.self) { evidence in
                        // Struck through when the file is not there: the
                        // fastest way to see a story that was invented.
                        Text(evidence.display)
                            .font(.caption2.monospaced())
                            .strikethrough(!evidence.exists)
                            // Anchored to `Color`, not `.secondary`'s
                            // `HierarchicalShapeStyle`: the ternary needs one
                            // concrete type for both branches, and `.red` only
                            // resolves to one when `Color` is the type being
                            // inferred.
                            .foregroundStyle(evidence.exists ? Color.secondary : Color.red)
                            .help(evidence.exists ? "" : "This file is not in the repository.")
                    }
                }
                if let hint = proposal.duplicateOf?.label {
                    Label(hint, systemImage: "exclamationmark.triangle")
                        .font(.caption2).foregroundStyle(.orange)
                }
            }
        }
        .padding(8)
        .background(Color.secondary.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            if model.activeAnalysisID != nil {
                Text("\(selection.count) selected").font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Close", role: .cancel) {
                model.closeAnalysis()
                dismiss()
            }
            if model.activeAnalysisID == nil {
                Button("Start") {
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
            } else {
                Button("Reject") {
                    let ids = Array(selection)
                    selection = []
                    Task { await model.rejectProposals(ids: ids) }
                }
                .disabled(selection.isEmpty)

                Button("→ Backlog (\(selection.count))") {
                    let ids = Array(selection)
                    selection = []
                    Task { await model.acceptProposals(ids: ids) }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(selection.isEmpty)
            }
        }
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

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Edit proposal").font(.title2.bold())

            TextField("Board label", text: $draft.title).textFieldStyle(.roundedBorder)
            LabeledContent("As a") {
                TextField("developer", text: $draft.story.role).textFieldStyle(.roundedBorder)
            }
            LabeledContent("I want") {
                TextField("", text: $draft.story.want).textFieldStyle(.roundedBorder)
            }
            LabeledContent("So that") {
                TextField("", text: $draft.story.benefit).textFieldStyle(.roundedBorder)
            }

            Text("Acceptance criteria").font(.caption.bold()).padding(.top, 4)
            ForEach(criteria.indices, id: \.self) { index in
                HStack {
                    TextField("…", text: Binding(
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
                }
            }
            Button("Add criterion", systemImage: "plus") { criteria.append("") }
                .buttonStyle(.borderless).font(.caption)

            Spacer()
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
        }
        .padding(16)
        .frame(width: 560, height: 520)
    }
}
