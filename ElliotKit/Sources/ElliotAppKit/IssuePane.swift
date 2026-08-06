import ElliotModel
import SwiftUI

/// What the card *says* — the story it was filed from, and the issue body it
/// became — rendered as components rather than as prose.
///
/// Both, when there are both. `InspectorView` used to show one or the other
/// through an `else if`, so a card carrying a locally-typed story **and** an
/// imported issue body silently dropped whichever came second. The two are
/// different things: the story is what Elliot was told, the body is what GitHub
/// now holds, and after `create-issue` has run they can diverge. A pane that
/// shows one of them cannot show that.
///
/// The choice is `sections(for:document:)` — a pure function returning values —
/// so "a card with both shows both" is a claim a test can hold. `swift test`
/// cannot see the screen; it can see this.
struct IssuePane: View {
    @Environment(AppModel.self) private var model
    let card: Card

    /// One region of the pane.
    ///
    /// Carrying its content rather than just naming it: a section that exists
    /// but has nothing in it is the empty render this type is here to prevent.
    enum Section: Hashable, Sendable {
        case story(UserStory)
        case body([IssueBlock])
    }

    /// Which regions this card has, in reading order.
    ///
    /// Both are admitted independently — there is no `else` — and each is
    /// admitted only when it has something to draw.
    ///
    /// `nonisolated` because `View` is a `@preconcurrency @MainActor` protocol,
    /// so a static member of a conforming type is inferred main-actor-isolated
    /// — and `@preconcurrency` turns calling it from elsewhere into nothing at
    /// compile time and a `SIGTRAP` at run time. This one is pure, and a test
    /// calls it off the main actor.
    nonisolated static func sections(for card: Card, document: IssueDocument) -> [Section] {
        var out: [Section] = []
        if let story = card.story, !story.narrative.isEmpty {
            out.append(.story(story))
        }
        if !document.blocks.isEmpty {
            out.append(.body(document.blocks))
        }
        return out
    }

    var body: some View {
        let document = model.issueDocument(for: card)
        let context = MarkdownContext(repo: model.repo(for: card))

        VStack(alignment: .leading, spacing: 16) {
            ForEach(Array(Self.sections(for: card, document: document).enumerated()), id: \.offset) { _, section in
                switch section {
                case .story(let story):
                    storySection(story, context: context)
                case .body(let blocks):
                    bodySection(blocks, context: context)
                }
            }
        }
    }

    // MARK: - The story Elliot was told

    /// Rendered through the same `.userStory` block the parser produces, so a
    /// story typed into the editor and a story read back out of an issue body
    /// look like the same thing — because they are.
    private func storySection(_ story: UserStory, context: MarkdownContext) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ConsoleLabel(text: "Story")
            MarkdownBlockView(
                block: .userStory(role: story.role, want: story.want, benefit: story.benefit),
                context: context
            )

            if !story.acceptanceCriteria.isEmpty {
                ConsoleLabel(text: "Acceptance criteria").padding(.top, 4)
                // Wrapped as plain runs rather than parsed: these are the app's
                // own fields, typed into `CardFieldsEditor`, not markdown. A
                // criterion that happens to contain a `#` is not a reference.
                MarkdownBlockView(
                    block: .orderedList(story.acceptanceCriteria.map { InlineText(runs: [.text($0)]) }),
                    context: context
                )
            }
        }
    }

    // MARK: - What GitHub holds

    private func bodySection(_ blocks: [IssueBlock], context: MarkdownContext) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            // "Note" is what this section was called when a card had no issue,
            // and for a card that still has none it is still the right word:
            // nothing has been filed, so there is no issue body to speak of.
            ConsoleLabel(text: card.issueNumber == nil ? "Note" : "Issue body")
            MarkdownBlockList(blocks: blocks, context: context)
        }
    }
}
