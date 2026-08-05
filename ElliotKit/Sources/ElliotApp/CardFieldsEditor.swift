import ElliotModel
import SwiftUI

/// The fields of a backlog item, shared by the sheet that creates one and the
/// sheet that corrects one. One field set, one validation rule — `CardDraft`
/// holds both.
struct CardFieldsEditor: View {
    @Binding var draft: CardDraft

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField("Board label", text: $draft.title)
                .textFieldStyle(.roundedBorder)

            Picker("", selection: $draft.isStory) {
                Text("User story").tag(true)
                Text("Plain note").tag(false)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            if draft.isStory {
                storyFields
            } else {
                TextEditor(text: $draft.note)
                    .font(.body)
                    .frame(height: 140)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(.separator))
            }

            if draft.isStory, let story = draft.story, !story.narrative.isEmpty {
                GroupBox("What create-issue will receive") {
                    Text(story.issueBody)
                        .font(.caption)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
            }
        }
    }

    private var storyFields: some View {
        VStack(alignment: .leading, spacing: 8) {
            LabeledContent("As a") {
                TextField("developer", text: $draft.role).textFieldStyle(.roundedBorder)
            }
            LabeledContent("I want") {
                TextField("to see the run log inside the card", text: $draft.want)
                    .textFieldStyle(.roundedBorder)
            }
            LabeledContent("So that") {
                TextField("I can diagnose without opening a terminal", text: $draft.benefit)
                    .textFieldStyle(.roundedBorder)
            }

            Text("Acceptance criteria").font(.caption.bold()).padding(.top, 4)
            ForEach(draft.criteria.indices, id: \.self) { index in
                HStack {
                    TextField("…", text: Binding(
                        get: { draft.criteria.indices.contains(index) ? draft.criteria[index] : "" },
                        set: { if draft.criteria.indices.contains(index) { draft.criteria[index] = $0 } }
                    ))
                    .textFieldStyle(.roundedBorder)
                    Button {
                        draft.criteria.remove(at: index)
                        if draft.criteria.isEmpty { draft.criteria = [""] }
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.borderless)
                }
            }
            Button("Add criterion", systemImage: "plus") { draft.criteria.append("") }
                .buttonStyle(.borderless)
                .font(.caption)
        }
    }
}
