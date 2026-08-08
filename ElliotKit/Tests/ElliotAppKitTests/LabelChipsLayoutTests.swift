import ElliotModel
import SwiftUI
import Testing

@testable import ElliotAppKit

/// That the chips actually lay out, driven through a **real layout pass**.
///
/// `FlowRow` is a hand-written `Layout`, which is the one kind of view code in
/// this package that can be wrong in total silence: a `sizeThatFits` that
/// answers zero draws nothing at all, and every arithmetic function around it
/// stays green. This project has paid for exactly that shape four times over —
/// `.inspector()` in #47/#50/#52/#53 and, closer to home, #159, where every
/// pure function `PanelLayoutTests` pins was correct and the decoration still
/// never appeared because the step between them had no measurement.
///
/// `ImageRenderer` gives a layout pass with no window, no store and no running
/// app, which is what makes this a `swift test` claim rather than a note asking
/// the next reader to look. It is **not** a substitute for someone looking: it
/// proves the chips occupy space and wrap, not that they are legible or in the
/// right place on screen.
@MainActor
@Suite("Label chips lay out")
struct LabelChipsLayoutTests {

    /// The rendered size of a view, out of a real pass.
    private func size(of view: some View, width: CGFloat) -> CGSize {
        let renderer = ImageRenderer(content: view.frame(width: width))
        return renderer.nsImage?.size ?? .zero
    }

    @Test("Chips occupy space rather than collapsing to nothing")
    func chipsHaveSize() {
        let rendered = size(
            of: LabelChips(names: ["bug", "documentation"], isMissing: { _ in false }),
            width: 300
        )
        #expect(rendered.width > 0)
        #expect(rendered.height > 0, "a FlowRow answering zero height draws nothing at all")
    }

    /// The reason `FlowRow` exists rather than an `HStack`: a card can ask for
    /// more labels than a two-span panel is wide, and an `HStack` would push
    /// them off the edge silently.
    @Test("More chips than fit on one line make the row taller")
    func chipsWrap() {
        let isMissing: (String) -> Bool = { _ in false }
        let one = size(of: LabelChips(names: ["bug"], isMissing: isMissing), width: 140)
        let many = size(
            of: LabelChips(
                names: ["bug", "documentation", "enhancement", "question", "good first issue"],
                isMissing: isMissing
            ),
            width: 140
        )
        #expect(many.height > one.height, "five chips in a 140pt row must wrap onto more lines")
    }

    /// A chip wider than the row it is in must still get a row, not send the
    /// layout round for ever looking for one it fits in.
    @Test("A chip wider than the whole row still lays out")
    func oversizedChipTerminates() {
        let rendered = size(
            of: LabelChips(
                names: [String(repeating: "very-long-label-", count: 8)],
                isMissing: { _ in false }
            ),
            width: 60
        )
        #expect(rendered.height > 0)
    }

    /// Marking a missing label must not cost it its space — the mark is an
    /// icon, a strike-through and a border, and a chip that vanished when
    /// marked would *hide* exactly the label criterion 6 exists to show.
    @Test("A label the repository lacks is drawn, not dropped")
    func missingChipsStillDraw() {
        let present = size(of: LabelChips(names: ["bug"], isMissing: { _ in false }), width: 300)
        let missing = size(of: LabelChips(names: ["bug"], isMissing: { _ in true }), width: 300)
        #expect(missing.height > 0)
        #expect(missing.width >= present.width, "the warning mark is added, never substituted")
    }

    /// The editor's own field, through the same pass — including the branch
    /// nobody would think to open by hand: a repository nothing is known about,
    /// where the picker has nothing to offer and the explanation carries the
    /// whole meaning.
    @Test("The editor's label field renders in all three states")
    func editorFieldRenders() {
        let states: [(String, RepositoryLabels, [String])] = [
            ("a repository that answered", .known(["bug", "documentation"]), ["bug"]),
            ("a repository with no labels", .known([]), ["bug"]),
            ("a repository nobody could reach", .unavailable, ["bug"]),
            ("a repository nobody has asked about yet", .notAsked, ["bug"]),
            ("nothing chosen yet", .known(["bug"]), []),
        ]
        for (name, repositoryLabels, chosen) in states {
            var draft = CardDraft(
                title: "Run log", role: "developer", want: "the log", benefit: "no terminal",
                labels: chosen
            )
            let field = CardFieldsEditor(
                draft: Binding(get: { draft }, set: { draft = $0 }),
                repositoryLabels: repositoryLabels
            )
            let rendered = size(of: field, width: 360)
            #expect(rendered.height > 0, "the editor drew nothing for \(name)")
        }
    }
}
