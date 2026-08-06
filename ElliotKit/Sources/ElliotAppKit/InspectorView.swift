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

    /// No empty state on purpose: the board only builds this view when a card
    /// is selected, so there is no reachable "nothing selected" case. One
    /// existed briefly, while `.inspector()` kept the panel open across a
    /// deselect — reverted with it in #52.
    var body: some View {
        if let card = model.selectedCard {
            content(for: card)
                .background(Color(nsColor: .windowBackgroundColor))
                .task(id: card.id) {
                    editor.end()
                    saveError = nil
                    await model.refreshRuns(cardID: card.id)
                }
        }
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
                        // Above everything else: it is the only thing on this
                        // panel that is waiting on the reader, and the one act
                        // in the product that cannot be undone.
                        if let pending = model.pendingFollowUps, pending.cardID == card.id {
                            MergeConfirmation(pending: pending)
                        }
                        nextStep(card)
                        IssuePane(card: card)
                        provenance(card)
                        RunsPane(card: card)
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
                    .background(consequence.isRefused
                        ? Surface.washFaint(consequence.tint)
                        : Surface.wash(consequence.tint))
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

    // MARK: - Story and body
    //
    // Both now live in `IssuePane`, and the reason is a bug rather than a
    // tidy-up: the two sections that stood here were joined by an `else if`, so
    // a card carrying a story *and* a body showed only the story. They are not
    // alternatives — one is what Elliot was told, the other is what GitHub
    // holds — and `IssuePane.sections(for:document:)` now decides that as data
    // a test can read.

    // MARK: - Runs
    //
    // Now `RunsPane`, and for a reason of the same shape: `RunRow` rendered the
    // whole log as one `Text` per line at 11pt monospace, so the agent's prose
    // and what `gh` established were set in the same face — the one distinction
    // the app is built on, unmade on screen. `RunsPane` draws a view per
    // `RunLogRow` and carries the verdict block.

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
