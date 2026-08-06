import ElliotModel
import SwiftUI

/// What Elliot thinks should happen next, in order.
///
/// This list already existed. `rankNextSteps` is pure, tested, and served to
/// agents over MCP as `board_next`; the human got five columns and rebuilt the
/// order in their head at every glance. The app computed the answer and gave it
/// only to the robot.
///
/// The view reads. It ranks nothing, sorts nothing and words nothing of its own:
/// the order is `rankNextSteps`', and each row's sentence comes from
/// `Consequence.of`, which is what the column headers already say. A second
/// wording here would drift from the board it is describing.
///
/// Self-contained so the Operations screen (#69) can compose it.
///
/// `public` only because `ElliotApp` names it in a `Scene`.
public struct NextStepsView: View {
    public init() {}

    @Environment(AppModel.self) private var model

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if model.nextSteps.isEmpty {
                ContentUnavailableView(
                    "Nothing waiting", systemImage: "checkmark.circle",
                    description: Text(
                        "Every card is either finished or somewhere Elliot cannot advance on its own.")
                )
                .frame(maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 6) {
                        ForEach(Array(model.nextSteps.enumerated()), id: \.element.card.id) {
                            index, step in
                            row(step, position: index + 1)
                        }
                    }
                    .padding(10)
                }
            }
        }
        .navigationTitle("Up next")
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 3) {
            ConsoleLabel(text: "Up next")
            Text(summary)
                .font(Type.prose)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
    }

    /// Ready first is the whole ordering, so the count that matters is how many
    /// are actually actionable — not how many rows there are.
    private var summary: String {
        let ready = model.nextSteps.filter(\.isReady).count
        let total = model.nextSteps.count
        if total == 0 { return "The board has nothing Elliot can advance." }
        if ready == 0 {
            return "\(total) card\(total == 1 ? "" : "s") waiting, none ready to move yet."
        }
        return "\(ready) of \(total) ready to move. The same order `board_next` gives an agent."
    }

    private func row(_ step: NextStep, position: Int) -> some View {
        let consequence = Consequence.of(step.outcome)
        return Button {
            // The same funnel a drag uses. No shortcut around `BoardService`.
            Task { await model.move(cardID: step.card.id, to: step.to) }
        } label: {
            HStack(alignment: .top, spacing: 8) {
                Text("\(position)")
                    .font(Type.factSmall)
                    .foregroundStyle(.tertiary)
                    .frame(width: 18, alignment: .trailing)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Fact(text: step.repoName, tint: Palette.quiet, small: true)
                        ConsoleLabel(text: step.card.column.displayName, tint: .secondary)
                        Spacer(minLength: 0)
                    }
                    Text(step.card.displayTitle)
                        .font(Type.rowTitle)
                        .fixedSize(horizontal: false, vertical: true)
                    Label {
                        Text(consequence.summary)
                    } icon: {
                        Image(systemName: consequence.isRefused ? "hand.raised.fill" : "arrow.right")
                    }
                    .font(Type.prose)
                    .foregroundStyle(consequence.isRefused ? Palette.refused : consequence.tint)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
            .background(Surface.wash(consequence.tint).opacity(consequence.isRefused ? 0.5 : 1))
            .clipShape(RoundedRectangle(cornerRadius: Metric.cardRadius))
            .overlay {
                RoundedRectangle(cornerRadius: Metric.cardRadius)
                    .strokeBorder(Surface.washBorder(consequence.tint), lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
        .disabled(consequence.isRefused)
        .help(consequence.summary)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(position). \(step.repoName), \(step.card.displayTitle). \(consequence.summary)")
    }
}
