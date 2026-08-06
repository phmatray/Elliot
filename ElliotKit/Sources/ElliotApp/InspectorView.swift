import ElliotEngine
import ElliotModel
import SwiftUI

/// The selected card, beside the board rather than on top of it.
///
/// This was a fixed 620×520 modal sheet, which meant the log — the thing you
/// open when a run went wrong — was read through a 180-point window while the
/// board it belongs to was covered up. A run takes minutes; watching one should
/// not blindfold the board.
struct InspectorView: View {
    @Environment(AppModel.self) private var model

    @State private var editor = CardEditor()
    @State private var saveError: String?

    var body: some View {
        Group {
            if let card = model.selectedCard {
                content(for: card)
                    .task(id: card.id) {
                        editor.end()
                        saveError = nil
                        await model.refreshRuns(cardID: card.id)
                    }
            } else {
                // The panel stays open across a deselect now — closing it is
                // the user's own gesture and nothing else's. So it needs
                // something to say when there is nothing selected; rendering
                // nothing leaves an unexplained blank column.
                noSelection
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var noSelection: some View {
        VStack(spacing: 6) {
            Image(systemName: "square.dashed")
                .font(.system(size: 22))
                .foregroundStyle(.tertiary)
            Text("No card selected")
                .font(Type.cardTitle)
                .foregroundStyle(.secondary)
            Text("Pick a card to see its story, what it did on GitHub, and its runs.")
                .font(Type.prose)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }

    private func content(for card: Card) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            header(card)
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if editor.isEditing {
                        CardFieldsEditor(draft: $editor.draft)
                        if let saveError {
                            Text(saveError).font(Type.prose).foregroundStyle(Palette.refused)
                        }
                    } else {
                        nextStep(card)
                        story(card)
                        provenance(card)
                        runs(card)
                    }
                }
                .padding(14)
            }

            if editor.isEditing {
                Divider()
                editorActions(card)
            }
        }
    }

    // MARK: - Header

    private func header(_ card: Card) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top) {
                Text(card.displayTitle)
                    .font(Type.sheetTitle)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Button {
                    model.selectedCardID = nil
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close details")
            }

            HStack(spacing: 6) {
                ConsoleLabel(text: card.column.displayName, tint: card.column.railTint)
                if let repo = model.repo(for: card) {
                    Fact(text: repo.nameWithOwner, tint: Palette.quiet, small: true)
                }
                Spacer()
                Fact(text: "here \(Elapsed.age(of: card.columnEnteredAt))",
                     tint: Palette.quiet, small: true)
            }

            // In Review is the only column Elliot fills by itself, and a card
            // that turned up there explained nothing about how. The decision
            // was `PRWatcher`'s and was already recorded; this only reads it
            // back.
            if let note = arrivalNote(card) {
                Text(note)
                    .font(Type.prose)
                    .foregroundStyle(Palette.inert)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !editor.isEditing, card.issueNumber == nil {
                Button("Edit story", systemImage: "pencil") { editor.begin(from: card) }
                    .controlSize(.small)
            }
        }
        .padding(14)
    }

    /// Only for the move that actually put the card where it is now — an older
    /// audit describes a column it has since left.
    private func arrivalNote(_ card: Card) -> String? {
        guard let audit = model.lastMove[card.id], audit.to == card.column else { return nil }
        return audit.origin.arrivalNote
    }

    // MARK: - Next step

    /// The same verdict the columns show, as a button that says what it does.
    @ViewBuilder
    private func nextStep(_ card: Card) -> some View {
        if let next = card.column.naturalNext {
            let consequence = Consequence.of(model.preview(card, to: next))
            VStack(alignment: .leading, spacing: 6) {
                ConsoleLabel(text: "Next step")
                Button {
                    Task { await model.move(cardID: card.id, to: next) }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: consequence.isRefused ? "hand.raised.fill" : "arrow.right")
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Move to \(next.displayName)")
                                .font(Type.rowTitle)
                            Text(consequence.summary)
                                .font(Type.prose)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 0)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(Surface.wash(consequence.tint)
                        .opacity(consequence.isRefused ? 0.6 : 1))
                    .clipShape(RoundedRectangle(cornerRadius: Metric.cardRadius))
                    .overlay {
                        RoundedRectangle(cornerRadius: Metric.cardRadius)
                            .strokeBorder(Surface.washBorder(consequence.tint), lineWidth: 1)
                    }
                }
                .buttonStyle(.plain)
                .disabled(consequence.isRefused)
                .help(consequence.summary)
            }
        }
    }

    // MARK: - Story

    @ViewBuilder
    private func story(_ card: Card) -> some View {
        if let story = card.story {
            VStack(alignment: .leading, spacing: 6) {
                ConsoleLabel(text: "Story")
                // A point larger than the card glances at it: this is where
                // the story is read rather than recognised.
                Text(story.narrative)
                    .font(Type.bodyProse)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)

                if !story.acceptanceCriteria.isEmpty {
                    ConsoleLabel(text: "Acceptance criteria").padding(.top, 4)
                    ForEach(Array(story.acceptanceCriteria.enumerated()), id: \.offset) { index, item in
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Fact(text: "\(index + 1)", tint: Palette.quiet, small: true)
                            Text(item)
                                .font(Type.prose)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
        } else if !card.body.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                ConsoleLabel(text: "Note")
                Text(card.body)
                    .font(Type.bodyProse)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        }
    }

    // MARK: - Provenance

    /// Everything here was read back from `gh` — never parsed out of what the
    /// agent said — so it is all set in the fact face.
    @ViewBuilder
    private func provenance(_ card: Card) -> some View {
        if card.issueNumber != nil || card.prNumber != nil || card.branch != nil {
            VStack(alignment: .leading, spacing: 6) {
                ConsoleLabel(text: "On GitHub")
                if let issue = card.issueNumber {
                    row("Issue", "#\(issue)", url: card.issueURL)
                }
                if let pr = card.prNumber {
                    row("Pull request", "\(pr)", url: card.prURL)
                }
                if let branch = card.branch {
                    row("Branch", branch, url: nil)
                }
                if card.issueNumber != nil {
                    Text("The issue is the record now — edit it on GitHub, not here.")
                        .font(Type.prose)
                        .foregroundStyle(.tertiary)
                        .padding(.top, 2)
                }
            }
        }
    }

    private func row(_ label: String, _ value: String, url: String?) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(Type.prose)
                .foregroundStyle(.secondary)
                .frame(width: 84, alignment: .leading)
            Fact(text: value, tint: .primary)
                .textSelection(.enabled)
            if let url, let real = URL(string: url) {
                Button {
                    NSWorkspace.shared.open(real)
                } label: {
                    Image(systemName: "arrow.up.forward.square").font(.system(size: 10))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .accessibilityLabel("Open \(label) on GitHub")
            }
            Spacer()
        }
    }

    // MARK: - Runs

    @ViewBuilder
    private func runs(_ card: Card) -> some View {
        let runs = model.runsByCard[card.id] ?? []
        if !runs.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                ConsoleLabel(text: "Runs")
                ForEach(runs) { run in
                    RunRow(run: run, liveLines: model.liveLog[run.id] ?? [])
                }
            }
        }
    }

    // MARK: - Editing

    private func editorActions(_ card: Card) -> some View {
        HStack {
            Spacer()
            Button("Cancel", role: .cancel) { editor.end(); saveError = nil }
            Button("Save changes") { save(card, editor.draft) }
                .keyboardShortcut(.defaultAction)
                .disabled(!editor.draft.isValid)
        }
        .padding(12)
    }

    private func save(_ card: Card, _ draft: CardDraft) {
        Task {
            if await model.updateCard(id: card.id, draft: draft) {
                editor.end()
                saveError = nil
            } else {
                // Filed, or deleted, since the editor opened. Stay in edit
                // mode — the typed text is still here.
                saveError = model.status
            }
        }
    }
}

// MARK: - One run

struct RunRow: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let run: SkillRun
    let liveLines: [String]
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            // Two rows rather than one: at the inspector's width a long state
            // name ("Finished, tools refused") and a cost cannot share a line
            // without one of them wrapping mid-phrase.
            HStack(spacing: 6) {
                Image(systemName: run.state.icon)
                    .font(.system(size: 11))
                    .foregroundStyle(run.state.tint)
                Text(run.kind.skillName).font(Type.fact).foregroundStyle(.primary)
                Spacer()
                if let cost = run.totalCostUSD {
                    Fact(text: String(format: "$%.4f", cost), tint: Palette.quiet, small: true)
                        .help("What this run cost")
                }
            }
            Text(run.state.label)
                .font(Type.prose)
                .foregroundStyle(run.state.tint)

            // The verdict `gh` returned. The app's rule is to judge a run by
            // this and never by `resultText`; showing only the state name and
            // the prose made that impossible to follow.
            if let outcome = run.verifiedOutcome {
                let receipt = outcome.receipt
                Label {
                    Text(receipt.text).font(Type.fact)
                } icon: {
                    Image(systemName: receipt.icon).font(.system(size: 10))
                }
                .foregroundStyle(receipt.tint)
                .fixedSize(horizontal: false, vertical: true)
            } else if run.state.isTerminal {
                Label("Nothing verified for this run", systemImage: "questionmark.circle")
                    .font(Type.prose)
                    .foregroundStyle(Palette.attention)
            }

            if !run.permissionDenials.isEmpty {
                // A run can end "success" having been refused a tool and
                // silently worked around the gap.
                Label(
                    "Refused tools: \(run.permissionDenials.joined(separator: ", "))",
                    systemImage: "lock.slash"
                )
                .font(Type.prose)
                .foregroundStyle(Palette.attention)
                .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 8) {
                Button(expanded ? "Hide log" : "Show log") { expanded.toggle() }
                    .controlSize(.small)
                if run.state.isCancellable {
                    Button("Cancel run") { Task { await model.cancelRun(id: run.id) } }
                        .controlSize(.small)
                }
                Spacer()
                Button {
                    NSWorkspace.shared.selectFile(run.logPath, inFileViewerRootedAtPath: "")
                } label: {
                    Image(systemName: "folder").font(.system(size: 10))
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

    private var logView: some View {
        VStack(alignment: .leading, spacing: 4) {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 1) {
                        ForEach(Array(logLines.enumerated()), id: \.offset) { index, line in
                            Text(line)
                                .font(Type.log)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                                .id(index)
                        }
                    }
                    .padding(6)
                }
                .frame(height: 260)
                .onChange(of: logLines.count) {
                    // A live tail that does not follow is a log you have to
                    // chase with the scrollbar.
                    // Gated: this is the panel you open to read a run the app
                    // documents as lasting hours, and it animated on every
                    // appended line.
                    withAnimation(reduceMotion ? nil : .default) {
                        proxy.scrollTo(logLines.count - 1, anchor: .bottom)
                    }
                }
            }
            .background(Color(nsColor: .textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: Metric.nestedRadius))

            Text(run.logPath)
                .font(Type.factSmall)
                .foregroundStyle(.tertiary)
                .textSelection(.enabled)
                .lineLimit(1)
                .truncationMode(.head)
        }
    }

    /// The live tail while it runs; the file on disk once it has finished.
    ///
    /// Both go through `AppModel.describe`, so a run does not change
    /// appearance the moment it ends — the tail used to be readable lines and
    /// the file on disk raw NDJSON, which made the log look like a different
    /// artefact depending on when you opened it.
    private var logLines: [String] {
        if !liveLines.isEmpty { return liveLines }
        guard let text = try? String(contentsOfFile: run.logPath, encoding: .utf8) else {
            return ["(no log on disk — it may have been cleaned up)"]
        }
        let rendered = text
            .split(separator: "\n")
            .compactMap { line -> String? in
                guard let event = StreamEventDecoder.decode(line: Data(line.utf8)) else {
                    // Not a stream event: show it as written rather than
                    // dropping it. A line the decoder cannot read is exactly
                    // the line worth seeing.
                    return String(line.prefix(400))
                }
                return AppModel.describe(event)
            }
        return rendered.isEmpty ? ["(log is empty)"] : Array(rendered.suffix(300))
    }
}
