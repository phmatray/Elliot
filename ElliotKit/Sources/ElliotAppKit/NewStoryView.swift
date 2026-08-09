import ElliotModel
import SwiftUI

/// Writing a backlog item. The three story fields are the point: the backlog
/// holds user stories, and keeping the parts separate is what will let a skill
/// generate them from a repository later.
///
/// A console face, which it reached by way of a fixed 580×580 sheet and then a
/// `Window` scene. Its own file since #313/#314, and not for tidiness: the state
/// a hide would destroy is checkable only by reading the source of the face, and
/// while this lived in `Sheets.swift` beside `MergeConfirmation` there was no
/// file that meant *this screen*. `NewStoryStateTests` reads this one and
/// `CardFieldsEditor.swift`, which together are the whole subtree.
///
/// ⛔ **No `@Environment(\.dismiss)` here, and that is the whole of what moving
/// this screen into the console changed.** It was a `Window` scene, where
/// dismissing closed that window. As a console face it resolves to the
/// *enclosing* window — the board — so Cancel would close the application's main
/// window. `AnalysisPanelView` records the identical trap, met the same way when
/// it stopped being a window in #151.
///
/// ⛔ **And no `@State`.** Everything the reader types or chooses lives on
/// `AppModel` (``AppModel/newCardDraft``, ``AppModel/newCardRepoID``), because
/// folding the console tears this view down — ⎋, the ✕, or any door in the
/// status bar. That is `analysisAngles`' lesson, and this screen holds a longer
/// piece of writing than the analysis setup ever did.
struct NewStoryView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        // The editor and the picker both write back, and what they write to
        // lives on the model so it survives the console being folded away.
        @Bindable var model = model
        return VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    header

                    CardFieldsEditor(
                        draft: $model.newCardDraft,
                        repositoryLabels: model.newCardRepo.map { model.labels(for: $0.id) }
                            ?? .notAsked
                    )
                }
                .padding(18)
            }
            // This face shares `CardFieldsEditor`, so it shows the same label
            // picker — and therefore has to fill the same list, or it would
            // offer nothing and say the repository has none. Keyed on the
            // *resolved* repository, so changing the picker above re-reads the
            // labels of what was chosen rather than of what was stored.
            .task(id: model.newCardRepo?.id) {
                if let repoID = model.newCardRepo?.id { await model.loadLabels(for: repoID) }
            }

            Divider()

            HStack(alignment: .firstTextBaseline, spacing: 12) {
                // ⛔ Rendered here rather than left to the status bar, which
                // truncates to one line at the far corner of the window. A
                // refusal belongs beside the button that was refused, and beside
                // the story it did **not** discard.
                if let refusal = model.newStoryRefusal {
                    Text(refusal)
                        .font(Type.prose)
                        .foregroundStyle(Palette.refused)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityLabel("Not filed: \(refusal)")
                }
                Spacer(minLength: 8)
                Button("Cancel", role: .cancel) { model.closeConsole() }
                Button("Add to backlog") { Task { await model.addStoryToBacklog() } }
                    // Sanctioned in `DefaultAction`: it commits a story the
                    // reader has typed, which is the whole of the rule.
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.newCardRepo == nil || !model.newCardDraft.isValid)
            }
            .padding(18)
        }
        .frame(minWidth: 460, minHeight: 420)
        // No `.navigationTitle`: this is a console face now, and a title set
        // here propagates to the *board window* and renames it (#263).
    }

    // MARK: - Header

    /// What this will become, and the one control that decides where.
    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("New story").font(Type.sheetTitle)
                Text(subtitle)
                    .font(Type.prose)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            // Only when there is something to choose between. With no
            // repositories the sentence above says why, which is more than an
            // empty picker would.
            if model.newCardRepo != nil { repositoryPicker }
        }
    }

    /// The sentence stated *"Filed against FormCraft"* as a fact while the target
    /// was `selectedRepoID ?? repos.first?.id` and no control could correct it —
    /// alphabetical luck presented as a decision (#314). It is true now because
    /// the picker beside it is what decides.
    private var subtitle: String {
        guard let repo = model.newCardRepo else {
            return "No repository is registered yet, so there is nowhere to file this."
        }
        return "Filed against \(repo.displayName) when you move it to To Do."
    }

    /// ⛔ **It belongs to this header, never to `CardFieldsEditor`.** That editor
    /// is shared with the detail panel's edit mode and the proposal editor, so a
    /// repository control inside it would let the detail panel change a card's
    /// repository — a second write path to a card's identity, which is what
    /// `BoardView.groupHeader`'s no-drop-target comment already refuses.
    ///
    /// ⚠️ **No "All repositories" row, unlike the board's toolbar picker.** There
    /// the tag means "do not filter"; here a card must land somewhere, and a
    /// picker offering a selection that cannot be filed would be offering a mode
    /// that discards what was typed — the failure `CardFieldsEditor.Kind` exists
    /// to prevent, one control over.
    ///
    /// The selection reads back through ``AppModel/newCardRepo`` rather than from
    /// ``AppModel/newCardRepoID`` directly, so the control shows the repository
    /// that will actually be used: unchosen, or chosen and since forgotten, both
    /// resolve to something real instead of leaving the picker blank.
    private var repositoryPicker: some View {
        Picker(
            "Repository",
            selection: Binding(
                get: { model.newCardRepo?.id },
                set: { model.newCardRepoID = $0 }
            )
        ) {
            ForEach(model.repos) { repo in
                Text(repo.displayName).tag(UUID?.some(repo.id))
            }
        }
        .labelsHidden()
        .frame(minWidth: 160)
        .accessibilityLabel("Repository to file this story against")
    }
}
