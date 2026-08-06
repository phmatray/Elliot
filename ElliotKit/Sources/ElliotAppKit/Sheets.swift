import ElliotEngine
import ElliotModel
import SwiftUI

/// Writing a backlog item. The three story fields are the point: the backlog
/// holds user stories, and keeping the parts separate is what will let a skill
/// generate them from a repository later.
///
/// A window rather than the fixed 580x580 sheet this was. The sheet had already
/// grown an internal `ScrollView` because at three or four acceptance criteria —
/// the documented normal path — it pushed its own buttons off the bottom, and a
/// macOS sheet cannot be resized. The scroll view stays, because a long story
/// should scroll rather than force the window taller than the screen; what has
/// gone is the ceiling it was fighting.
///
/// `public` only because `ElliotApp` names it in a `Scene`.
public struct NewCardWindow: View {
    public init() {}

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var draft = CardDraft()

    /// Read from the model rather than passed in: a `Window` scene cannot be
    /// handed a parameter the way a sheet's closure could.
    private var repoID: UUID? { model.newCardRepoID ?? model.defaultRepoIDForNewCard }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("New story").font(Type.sheetTitle)
                        Text(repoName.map { "Filed against \($0) when you move it to To Do." }
                            ?? "Nothing runs yet — moving it to To Do files the issue.")
                            .font(Type.prose)
                            .foregroundStyle(.secondary)
                    }

                    CardFieldsEditor(draft: $draft)
                }
                .padding(18)
            }

            Divider()

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button("Add to backlog") { add() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(repoID == nil || !draft.isValid)
            }
            .padding(18)
        }
        .frame(minWidth: 460, minHeight: 420)
        .navigationTitle("New story")
    }

    private var repoName: String? {
        model.repos.first { $0.id == repoID }?.displayName
    }

    private func add() {
        guard let repoID else { return }
        Task {
            await model.createCard(
                repoID: repoID, title: draft.title, story: draft.story, body: draft.body
            )
            dismiss()
        }
    }
}

/// Asked once, right before a merge: `merge-pr` files whatever is listed here
/// as issues after it lands.
struct FollowUpSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    let pending: AppModel.PendingMerge
    @State private var items: [String] = [""]

    /// The follow-ups scroll; the merge button does not.
    ///
    /// This is the sheet that carries the one irreversible act in the product,
    /// and "Add another" used to push that button out of its own window.
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Image(systemName: "flame.fill").foregroundStyle(Palette.irreversible)
                    Text("Merge pull request \(pending.prNumber)").font(Type.sheetTitle)
                }
                Text("This merges into the repository's default branch on github.com and cannot be undone from Elliot.")
                    .font(Type.prose)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(18)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ConsoleLabel(text: "Follow-ups")
                    Text("Each line becomes a new issue after the merge lands. Leave it empty if there are none.")
                        .font(Type.prose)
                        .foregroundStyle(.secondary)

                    ForEach(items.indices, id: \.self) { index in
                        HStack(spacing: 6) {
                            TextField("What still needs doing…", text: Binding(
                                get: { items.indices.contains(index) ? items[index] : "" },
                                set: { if items.indices.contains(index) { items[index] = $0 } }
                            ))
                            .textFieldStyle(.roundedBorder)
                            Button {
                                items.remove(at: index)
                                if items.isEmpty { items = [""] }
                            } label: {
                                Image(systemName: "minus.circle")
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel("Remove follow-up \(index + 1)")
                        }
                    }
                    Button("Add another", systemImage: "plus") { items.append("") }
                        .buttonStyle(.borderless)
                        .controlSize(.small)
                }
                .padding(18)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Divider()

            HStack {
                Text(followUpSentence)
                    .font(Type.prose)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button("Merge PR \(pending.prNumber)") {
                    Task {
                        await model.confirmMerge(cardID: pending.cardID, followUps: cleaned)
                        dismiss()
                    }
                }
                .keyboardShortcut(.defaultAction)
                .tint(Palette.irreversible)
            }
            .padding(18)
        }
        .frame(width: 540, height: 440)
    }

    /// Restates the ordering the section above promises: the issues are filed
    /// *after* the merge lands, not instead of it.
    private var followUpSentence: String {
        switch cleaned.count {
        case 0: "No follow-ups will be filed."
        case 1: "1 issue will be filed after the merge."
        default: "\(cleaned.count) issues will be filed after the merge."
        }
    }

    private var cleaned: [String] {
        items
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}
