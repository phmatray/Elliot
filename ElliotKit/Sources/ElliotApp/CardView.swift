import ElliotModel
import SwiftUI

struct CardView: View {
    @Environment(AppModel.self) private var model
    let card: Card
    @State private var showingDetail = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top) {
                Text(card.displayTitle)
                    .font(.body.weight(.medium))
                    .lineLimit(2)
                Spacer(minLength: 4)
                if let run = activeRun {
                    ProgressView()
                        .controlSize(.small)
                        .help("Run \(run.kind.rawValue) is \(run.state.rawValue)")
                }
            }

            if let story = card.story {
                Text(story.narrative)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }

            HStack(spacing: 6) {
                if let issue = card.issueNumber {
                    Badge(text: "#\(issue)", systemImage: "circle.dashed", url: card.issueURL)
                }
                if let pr = card.prNumber {
                    Badge(text: "PR \(pr)", systemImage: "arrow.triangle.pull", url: card.prURL)
                }
                if model.repo(for: card).map({ model.isBlocked($0) }) == true {
                    Badge(text: "blocked", systemImage: "exclamationmark.triangle", tint: .orange)
                }
                Spacer()
                if model.selectedRepoID == nil, let repo = model.repo(for: card) {
                    Text(repo.displayName)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }

            if let error = card.lastError {
                Text(error)
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .lineLimit(2)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(.separator, lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onTapGesture { showingDetail = true }
        .contextMenu {
            if let run = activeRun {
                Button("Cancel run", systemImage: "stop.circle") {
                    Task { await model.cancelRun(id: run.id) }
                }
            }
            if let url = card.issueURL {
                Button("Open issue", systemImage: "safari") { open(url) }
            }
            if let url = card.prURL {
                Button("Open pull request", systemImage: "safari") { open(url) }
            }
            Divider()
            Button("Delete card", systemImage: "trash", role: .destructive) {
                Task { await model.deleteCard(id: card.id) }
            }
        }
        .sheet(isPresented: $showingDetail) {
            CardDetailView(card: card)
        }
        .task(id: card.id) { await model.refreshRuns(cardID: card.id) }
    }

    private var activeRun: SkillRun? {
        model.runsByCard[card.id]?.first { $0.state.isActive }
    }

    private func open(_ string: String) {
        guard let url = URL(string: string) else { return }
        NSWorkspace.shared.open(url)
    }
}

struct Badge: View {
    var text: String
    var systemImage: String
    var url: String?
    var tint: Color = .secondary

    var body: some View {
        Label(text, systemImage: systemImage)
            .font(.caption2)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(tint.opacity(0.12))
            .foregroundStyle(tint)
            .clipShape(Capsule())
            .onTapGesture {
                guard let url, let real = URL(string: url) else { return }
                NSWorkspace.shared.open(real)
            }
    }
}

struct CardDetailView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let card: Card

    @State private var draft: CardDraft?
    @State private var saveError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // `Binding($draft)` rather than a hand-rolled get/set: a getter that
            // closed over the unwrapped local would keep reporting the value as
            // it was when the body was last evaluated, so two mutations in one
            // action would lose the first.
            if let editable = Binding($draft) {
                Text("Editing").font(.title2.bold())
                CardFieldsEditor(draft: editable)
                if let saveError {
                    Text(saveError).font(.caption).foregroundStyle(.orange)
                }
            } else {
                readOnly
            }

            Spacer()
            HStack {
                if draft == nil, card.issueNumber == nil {
                    Button("Edit", systemImage: "pencil") { draft = CardDraft(card: card) }
                }
                Spacer()
                if let draft {
                    Button("Cancel", role: .cancel) { self.draft = nil; saveError = nil }
                    Button("Save") { save(draft) }
                        .keyboardShortcut(.defaultAction)
                        .disabled(!draft.isValid)
                } else {
                    Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(16)
        .frame(width: 620, height: 520)
        .task { await model.refreshRuns(cardID: card.id) }
    }

    @ViewBuilder
    private var readOnly: some View {
        Text(card.displayTitle).font(.title2.bold())

        if let issue = card.issueNumber {
            // The card stops being the record the moment the issue exists;
            // editing here would quietly diverge from what is on github.com.
            Text("Filed as #\(issue) — edit it on GitHub. From here on the issue is the record.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }

        if let story = card.story {
            GroupBox("User story") {
                VStack(alignment: .leading, spacing: 4) {
                    Text(story.narrative)
                    if !story.acceptanceCriteria.isEmpty {
                        Text("Acceptance criteria").font(.caption.bold()).padding(.top, 4)
                        ForEach(Array(story.acceptanceCriteria.enumerated()), id: \.offset) { index, item in
                            Text("\(index + 1). \(item)").font(.caption)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else if !card.body.isEmpty {
            GroupBox("Note") {
                Text(card.body).frame(maxWidth: .infinity, alignment: .leading)
            }
        }

        let runs = model.runsByCard[card.id] ?? []
        if !runs.isEmpty {
            GroupBox("Runs") {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(runs) { run in
                        RunRow(run: run, liveLines: model.liveLog[run.id] ?? [])
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func save(_ draft: CardDraft) {
        Task {
            if await model.updateCard(id: card.id, draft: draft) {
                self.draft = nil
                saveError = nil
            } else {
                // Filed, or deleted, between opening the sheet and saving.
                // Stay in edit mode — the typed text is still here.
                saveError = model.status
            }
        }
    }
}

struct RunRow: View {
    @Environment(AppModel.self) private var model
    let run: SkillRun
    let liveLines: [String]
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: icon).foregroundStyle(tint)
                Text(run.kind.rawValue).font(.callout.weight(.medium))
                Text(run.state.rawValue).font(.caption).foregroundStyle(.secondary)
                if let cost = run.totalCostUSD {
                    Text(String(format: "$%.4f", cost))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
                Spacer()
                if run.state.isActive {
                    Button("Cancel") { Task { await model.cancelRun(id: run.id) } }
                        .controlSize(.small)
                }
                Button(expanded ? "Hide log" : "Show log") { expanded.toggle() }
                    .controlSize(.small)
            }

            if !run.permissionDenials.isEmpty {
                // A run can end "success" having been refused a tool and
                // silently worked around the gap.
                Text("Refused tools: \(run.permissionDenials.joined(separator: ", "))")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }

            if expanded {
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(logLines.enumerated()), id: \.offset) { _, line in
                            Text(line)
                                .font(.caption.monospaced())
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                        }
                    }
                }
                .frame(height: 180)
                .background(Color.secondary.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                Text(run.logPath).font(.caption2).foregroundStyle(.tertiary).textSelection(.enabled)
            }
        }
    }

    /// The live tail while it runs; the file on disk once it has finished.
    private var logLines: [String] {
        if !liveLines.isEmpty { return liveLines }
        guard let text = try? String(contentsOfFile: run.logPath, encoding: .utf8) else {
            return ["(no log)"]
        }
        return text.split(separator: "\n").suffix(300).map { String($0.prefix(400)) }
    }

    private var icon: String {
        switch run.state {
        case .queued: "clock"
        case .running, .cancelling: "play.circle"
        case .stalled: "hourglass"
        case .succeeded: "checkmark.circle"
        case .completedWithDenials: "exclamationmark.circle"
        case .failed, .timedOut: "xmark.circle"
        case .cancelled: "stop.circle"
        }
    }

    private var tint: Color {
        switch run.state {
        case .succeeded: .green
        case .failed, .timedOut: .red
        case .completedWithDenials, .stalled: .orange
        default: .secondary
        }
    }
}
