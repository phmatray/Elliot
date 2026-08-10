import ElliotModel
import SwiftUI

/// What this board is holding back, and the one act that undoes a single row.
///
/// Deleting a card that carries an issue or a pull request writes a suppression
/// row and `GitHubImporter.plan` skips that unit for ever. Until #334 the whole
/// of that was **write-only**: the reader got a number in the status bar —
/// `ImportSummary.sentence`'s `"3 dismissed"` — and the only thing that could
/// act on it was *Forget dismissed items*, which clears every dismissal for
/// every repository in view at once. So a reader who dismissed nine correctly
/// and one by mistake had to lose all ten and re-triage them off the board.
///
/// This view judges nothing. The rows, their order and the grouping are
/// `DismissalDigest`'s, in `ElliotModel`, and `swift test` cannot see a `body`.
///
/// ⛔ **No `.navigationTitle`**: a title set in a face propagates to the *board
/// window* and renames it — measured in both directions, and not stopped by a
/// nested `NavigationStack`. The console header names the screen.
///
/// ⛔ **No `@Environment(\.dismiss)`**: in a region inside the board window it
/// resolves to the board, so a Close button here would close the application's
/// main window. Folding is the header's ✕, or Escape.
struct DismissedView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            if model.visibleDismissals.isEmpty {
                empty
            } else {
                List {
                    ForEach(model.visibleDismissals) { group in
                        Section(name(of: group.repoID)) {
                            ForEach(group.rows) { item in
                                row(item)
                            }
                        }
                    }
                }
                .listStyle(.inset)
            }
        }
        .safeAreaInset(edge: .top) { header }
    }

    // MARK: - Header

    /// The sentence, and the bulk act beside it.
    ///
    /// *Forget dismissed items* is repeated here rather than moved: the toolbar
    /// menu keeps it (criterion 4), and both call the same `clearDismissals()`.
    /// One funnel, two doors — the alternative is a screen that lists the rows
    /// and cannot perform the act the reader came from.
    private var header: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                // Names what the list holds, not the face — `RepositoriesView`'s
                // lead ("Repository tree" under a face titled *Repositories*)
                // rather than `NextStepsView`'s, which repeats its own title.
                // Found by looking: the console header sits directly above this
                // one, so with the title restated the screen opened onto
                // "Dismissed" over "DISMISSED".
                ConsoleLabel(text: "Held back on refresh")
                Spacer(minLength: 8)
                Button("Forget all", systemImage: "trash") {
                    Task { await model.clearDismissals() }
                }
                .controlSize(.small)
                .disabled(model.visibleDismissals.isEmpty)
                .help("Forget every dismissal in view, so the next refresh brings them all back")
            }
            Text(summary)
                .font(Type.prose)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(.bar)
    }

    /// ⚠️ Built as a `String` and handed to `Text` as a variable. A count is a
    /// genuine quantity, so grouping it would be harmless here — but the same
    /// sentence carries `label`s that are **identifiers**, and `Text`'s
    /// `LocalizedStringKey` overload cannot tell the two apart. Keeping every
    /// number in this file out of a literal interpolation is the rule that has
    /// no exceptions to remember (`MergeConfirmation`, `Sheets.swift`).
    private var summary: String {
        let count = model.visibleDismissals.reduce(0) { $0 + $1.rows.count }
        guard count > 0 else { return "" }
        let noun = count == 1 ? "item" : "items"
        return "\(count) \(noun) the next refresh will skip. Restore one to let it come back; "
            + "a card that carried both an issue and its pull request left two rows, "
            + "and the item stays hidden until both are restored."
    }

    // MARK: - Rows

    /// A repository's name, or its id when the registration is gone.
    ///
    /// The row survives its repository only for as long as the observation takes
    /// to deliver — `ON DELETE CASCADE` removes these rows with the repository —
    /// so this is the honest label for one frame rather than a state to design
    /// for.
    private func name(of repoID: UUID) -> String {
        model.repos.first { $0.id == repoID }?.displayName ?? repoID.uuidString
    }

    private func row(_ item: DismissedItem) -> some View {
        HStack(spacing: 10) {
            // `Fact`: the number came from GitHub, not from Elliot, so it is set
            // in the quoted face like every other external identifier.
            Fact(text: item.ref.label)
            Text(item.dismissedAt.formatted(date: .abbreviated, time: .shortened))
                .font(Type.factSmall)
                .foregroundStyle(Palette.quiet)
            Spacer(minLength: 8)
            Button("Restore") {
                Task { await model.restoreDismissal(item) }
            }
            .controlSize(.small)
            // ⛔ No `.keyboardShortcut(.defaultAction)`. `DefaultAction` lists
            // the three sanctioned claimants, and none of them is here: Return
            // belongs to a control that commits text the reader has typed, and
            // this row commits nothing of the reader's.
            .help("Stop skipping \(item.ref.label); the next refresh may bring it back")
        }
        // One element, so a screen reader meets a sentence rather than a fact,
        // a date and a verb in a row.
        .accessibilityElement(children: .combine)
        .accessibilityLabel(spoken(item))
    }

    /// ⚠️ A sentence, not the row read left to right. "Issue #4 3 Aug at 09:12
    /// Restore" is three fragments; this says what the row *is*.
    private func spoken(_ item: DismissedItem) -> String {
        "\(item.ref.label), dismissed "
            + item.dismissedAt.formatted(date: .abbreviated, time: .shortened)
    }

    // MARK: - Empty

    /// Says what a dismissal *is*, not merely that there are none.
    ///
    /// The face is reachable from the View menu at zero — the status-bar figure
    /// is absent when there is nothing to count — so this state is the one a
    /// reader arrives in deliberately, asking what the screen would have shown.
    /// "Nothing here" would answer a question they did not ask.
    private var empty: some View {
        ContentUnavailableView(
            "Nothing is being held back", systemImage: "eye",
            description: Text(
                model.selectedRepoID == nil
                    ? "Deleting a card that carries an issue or a pull request tells Elliot to "
                        + "stop importing it. Those suppressions would be listed here, and each "
                        + "one could be restored on its own."
                    : "Nothing is suppressed in this repository. Deleting a card that carries an "
                        + "issue or a pull request would add it here, and it could be restored "
                        + "without touching the others."
            )
        )
        .frame(maxHeight: .infinity)
    }
}
