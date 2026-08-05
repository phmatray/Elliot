import ElliotEngine
import ElliotModel
import SwiftUI

/// Writing a backlog item. The three story fields are the point: the backlog
/// holds user stories, and keeping the parts separate is what will let a skill
/// generate them from a repository later.
struct NewCardSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    let repoID: UUID?

    @State private var draft = CardDraft()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("New backlog item").font(.title2.bold())

            CardFieldsEditor(draft: $draft)

            Spacer()
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button("Add") { add() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(repoID == nil || !draft.isValid)
            }
        }
        .padding(16)
        .frame(width: 560, height: 560)
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

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Merge pull request \(pending.prNumber)").font(.title2.bold())
            Text("Anything listed here is filed as a new issue after the merge lands.")
                .font(.callout)
                .foregroundStyle(.secondary)

            ForEach(items.indices, id: \.self) { index in
                HStack {
                    TextField("Follow-up…", text: Binding(
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
                }
            }
            Button("Add follow-up", systemImage: "plus") { items.append("") }
                .buttonStyle(.borderless)
                .font(.caption)

            Spacer()
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button("Merge") {
                    let cleaned = items
                        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                        .filter { !$0.isEmpty }
                    Task {
                        await model.confirmMerge(cardID: pending.cardID, followUps: cleaned)
                        dismiss()
                    }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 520, height: 420)
    }
}
