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

    /// What the pane says when `sections` admits nothing.
    ///
    /// The pane cannot be *absent* the way `MoveHistoryBlock` is — it is half
    /// the panel — so it needs the sentence `RunsPane` grew for the same reason:
    /// drawn blank across two or three column-widths it reads as broken rather
    /// than as "nothing has been written".
    ///
    /// Two states, and `issueNumber` is what separates them: an issue that is
    /// filed and whose body GitHub holds is empty is a *finished* state and must
    /// not be told to go and write one.
    ///
    /// ⚠️ **Derived, never tabulated** — the same rule as
    /// `RunsPane.emptyState`. Where it names a move it reaches it through
    /// `Column.naturalNext` and `Consequence.of`, so it cannot promise a run for
    /// a card whose repository Preflight has switched off, and it cannot become
    /// a third copy of the transition matrix.
    nonisolated static func emptyState(
        for card: Card, outcome: MoveOutcome?
    ) -> (title: String, message: String) {
        if let number = card.issueNumber {
            return (
                "Nothing in the issue body",
                "Issue #\(number) is filed, and the body GitHub holds for it is empty."
            )
        }

        let title = "Nothing written yet"

        guard let next = card.column.naturalNext else {
            return (
                title,
                "No story, and no issue body. \(card.column.displayName) is the end of the board."
            )
        }
        guard let outcome else {
            // Not reachable from the panel, which previews every move it has.
            return (title, "Edit the story here, or move it to \(next.displayName).")
        }

        let consequence = Consequence.of(outcome)
        if consequence.isRefused {
            return (
                title,
                "Moving it to \(next.displayName) is refused. \(consequence.summary)"
            )
        }
        if case .noAction = outcome {
            return (
                title,
                "Nothing files an issue on the way to \(next.displayName). \(next.standingRule)"
            )
        }
        return (
            title,
            "Write the story here, then move it to \(next.displayName). \(consequence.summary)"
        )
    }

    var body: some View {
        let document = model.issueDocument(for: card)
        let context = MarkdownContext(repo: model.repo(for: card))
        let sections = Self.sections(for: card, document: document)

        VStack(alignment: .leading, spacing: 16) {
            if sections.isEmpty {
                emptyState
            } else {
                ForEach(Array(sections.enumerated()), id: \.offset) { _, section in
                    switch section {
                    case .story(let story):
                        storySection(story, context: context)
                    case .body(let blocks):
                        bodySection(blocks, context: context)
                    }
                }
            }
        }
    }

    /// The outcome handed to `emptyState` is `model.preview` — the same call the
    /// next-step button and every column caption make — so the sentence and the
    /// button cannot disagree about what a move would do.
    private var emptyState: some View {
        let next = card.column.naturalNext
        let copy = IssuePane.emptyState(
            for: card,
            outcome: next.map { model.preview(card, to: $0) }
        )

        return ContentUnavailableView(
            copy.title, systemImage: "text.page.slash", description: Text(copy.message)
        )
        .frame(maxWidth: .infinity)
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
