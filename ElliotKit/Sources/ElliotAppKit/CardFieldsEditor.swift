import ElliotModel
import SwiftUI

/// The fields of a backlog item, shared by the sheet that creates one, the
/// inspector that corrects one, and the row that corrects a proposal. One field
/// set, one validation rule — `CardDraft` holds both.
struct CardFieldsEditor: View {
    /// What is being edited, which decides whether a note is even an option.
    ///
    /// Not a boolean trap: the distinction is real. A *card* may be a plain
    /// note, so it gets the picker and both branches. A *proposal* is always a
    /// story — `StoryProposal` carries a `UserStory` and has nowhere to put a
    /// note — so offering the picker there would offer a mode that silently
    /// discards what was typed. The pin that makes `.story` safe is not here
    /// but in `CardDraft(proposal:)`, where `swift test` can hold it.
    enum Kind {
        /// Board label, story/note picker, whichever branch is selected, preview.
        case card
        /// Board label, story fields, preview. No picker, no note.
        case story
    }

    @Binding var draft: CardDraft
    /// Defaulted, so the card sheet and the detail inspector are unchanged.
    var kind: Kind = .card

    /// One answer to "is this a story", read by every site that asks.
    ///
    /// It was briefly three — the fields keyed on `kind`, the preview on
    /// `draft.isStory`, and `isValid` on `draft.isStory` again — which is the
    /// defect this whole view exists to remove, reintroduced one level up. A
    /// `.story` editor whose draft said otherwise would render the story
    /// fields, hide the preview, and weaken Save to "the label is non-blank".
    private var isStory: Bool { kind == .story || draft.isStory }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                ConsoleLabel(text: "Board label")
                TextField("Short name for the card", text: $draft.title)
                    .textFieldStyle(.roundedBorder)
            }

            if kind == .card {
                Picker("", selection: $draft.isStory) {
                    Text("User story").tag(true)
                    Text("Plain note").tag(false)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            // In `.story` the note branch is unreachable by construction rather
            // than merely unselected: there is no picker to reach it with, and
            // the draft was seeded with `isStory` pinned.
            if isStory {
                storyFields
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    ConsoleLabel(text: "Note")
                    TextEditor(text: $draft.note)
                        .font(Type.bodyProse)
                        .scrollContentBackground(.hidden)
                        .padding(4)
                        .frame(height: 130)
                        .background(Color(nsColor: .textBackgroundColor))
                        .clipShape(RoundedRectangle(cornerRadius: Metric.cardRadius))
                        .overlay(RoundedRectangle(cornerRadius: Metric.cardRadius)
                            .strokeBorder(.separator))
                }
            }

            // Only once the story is complete. `role` is seeded with
            // "developer", so a narrative exists from the first keystroke and
            // this box used to open on "As a developer, I want ." — a broken
            // sentence presented as what the skill would be sent.
            if isStory, let story = draft.story, story.isComplete {
                VStack(alignment: .leading, spacing: 4) {
                    ConsoleLabel(text: "What create-issue will receive")
                    Text(story.issueBody)
                        .font(Type.fact)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .padding(8)
                        .background(Surface.recess)
                        .clipShape(RoundedRectangle(cornerRadius: Metric.cardRadius))
                }
            }
        }
        // The third site that asks "is this a story" is `CardDraft.isValid`,
        // and it is in another module — a view cannot make it kind-aware. So
        // `.story` makes the *draft* agree instead of answering around it:
        // without this, a caller handing `.story` a note-mode draft would get
        // an editable story whose Save gate had silently weakened to "the
        // label is non-blank". `ProposalEditor` already seeds through
        // `CardDraft(proposal:)`, which pins it; this is what keeps the next
        // caller from having to know that.
        .onAppear { if kind == .story { draft.isStory = true } }
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
