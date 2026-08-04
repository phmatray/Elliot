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

    @State private var title = ""
    @State private var role = "developer"
    @State private var want = ""
    @State private var benefit = ""
    @State private var criteria: [String] = [""]
    @State private var note = ""
    @State private var asStory = true

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("New backlog item").font(.title2.bold())

            TextField("Board label", text: $title)
                .textFieldStyle(.roundedBorder)

            Picker("", selection: $asStory) {
                Text("User story").tag(true)
                Text("Plain note").tag(false)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            if asStory {
                storyFields
            } else {
                TextEditor(text: $note)
                    .font(.body)
                    .frame(height: 140)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(.separator))
            }

            if asStory, !previewStory.narrative.isEmpty {
                GroupBox("What create-issue will receive") {
                    Text(previewStory.issueBody)
                        .font(.caption)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
            }

            Spacer()
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button("Add") { add() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canAdd)
            }
        }
        .padding(16)
        .frame(width: 560, height: 560)
    }

    private var storyFields: some View {
        VStack(alignment: .leading, spacing: 8) {
            LabeledContent("As a") {
                TextField("developer", text: $role).textFieldStyle(.roundedBorder)
            }
            LabeledContent("I want") {
                TextField("to see the run log inside the card", text: $want)
                    .textFieldStyle(.roundedBorder)
            }
            LabeledContent("So that") {
                TextField("I can diagnose without opening a terminal", text: $benefit)
                    .textFieldStyle(.roundedBorder)
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
                .buttonStyle(.borderless)
                .font(.caption)
        }
    }

    private var previewStory: UserStory {
        UserStory(
            role: role, want: want, benefit: benefit,
            acceptanceCriteria: criteria.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        )
    }

    private var canAdd: Bool {
        guard repoID != nil, !title.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        // A half-written story would be refused at the first drag anyway; say
        // so here rather than there.
        return asStory ? previewStory.isComplete : true
    }

    private func add() {
        guard let repoID else { return }
        let story = asStory ? previewStory : nil
        Task {
            await model.createCard(
                repoID: repoID, title: title, story: story, body: asStory ? "" : note
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
