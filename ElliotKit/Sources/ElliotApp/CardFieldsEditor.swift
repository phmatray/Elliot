import ElliotModel
import SwiftUI

/// The fields of a backlog item, shared by the sheet that creates one and the
/// inspector that corrects one. One field set, one validation rule —
/// `CardDraft` holds both.
struct CardFieldsEditor: View {
    @Binding var draft: CardDraft

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                ConsoleLabel(text: "Board label")
                TextField("Short name for the card", text: $draft.title)
                    .textFieldStyle(.roundedBorder)
            }

            Picker("", selection: $draft.isStory) {
                Text("User story").tag(true)
                Text("Plain note").tag(false)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            if draft.isStory {
                storyFields
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    ConsoleLabel(text: "Note")
                    TextEditor(text: $draft.note)
                        .font(.system(size: 12))
                        .scrollContentBackground(.hidden)
                        .padding(4)
                        .frame(height: 130)
                        .background(Color(nsColor: .textBackgroundColor))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator))
                }
            }

            // Only once the story is complete. `role` is seeded with
            // "developer", so a narrative exists from the first keystroke and
            // this box used to open on "As a developer, I want ." — a broken
            // sentence presented as what the skill would be sent.
            if draft.isStory, let story = draft.story, story.isComplete {
                VStack(alignment: .leading, spacing: 4) {
                    ConsoleLabel(text: "What create-issue will receive")
                    Text(story.issueBody)
                        .font(Type.fact)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .padding(8)
                        .background(Color.secondary.opacity(0.08))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                }
            }
        }
    }

    private var storyFields: some View {
        VStack(alignment: .leading, spacing: 8) {
            field("As a", placeholder: "developer", text: $draft.role)
            field("I want", placeholder: "to see the run log inside the card", text: $draft.want)
            field("So that", placeholder: "I can diagnose without opening a terminal", text: $draft.benefit)

            ConsoleLabel(text: "Acceptance criteria").padding(.top, 4)
            ForEach(draft.criteria.indices, id: \.self) { index in
                HStack(spacing: 6) {
                    TextField("What has to be true when it is done", text: Binding(
                        get: { draft.criteria.indices.contains(index) ? draft.criteria[index] : "" },
                        set: { if draft.criteria.indices.contains(index) { draft.criteria[index] = $0 } }
                    ))
                    .textFieldStyle(.roundedBorder)
                    Button {
                        draft.removeCriterion(at: index)
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Remove criterion \(index + 1)")
                }
            }
            Button("Add criterion", systemImage: "plus") { draft.criteria.append("") }
                .buttonStyle(.borderless)
                .controlSize(.small)
        }
    }

    private func field(_ label: String, placeholder: String, text: Binding<String>) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .font(Type.prose)
                .foregroundStyle(.secondary)
                .frame(width: 52, alignment: .trailing)
            TextField(placeholder, text: text)
                .textFieldStyle(.roundedBorder)
        }
    }
}
