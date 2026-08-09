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
        @Bindable var model = model
        let window = model.nextStepsView
        return VStack(alignment: .leading, spacing: 0) {
            header
            filters($model)
            Divider()
            if window.steps.isEmpty {
                ContentUnavailableView(
                    "Nothing waiting", systemImage: "checkmark.circle",
                    description: Text(emptyMessage)
                )
                .frame(maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 6) {
                        ForEach(Array(window.steps.enumerated()), id: \.element.card.id) {
                            index, step in
                            row(step, position: index + 1)
                        }
                        if window.isCapped {
                            Text(cappedNote(window))
                                .font(Type.factSmall)
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.top, 2)
                        }
                    }
                    .padding(10)
                }
            }
        }
        // No `.navigationTitle`: this is a console face now, and a title set
        // here propagates to the *board window* and renames it — measured, and
        // not stopped by a nested NavigationStack nor by an ancestor re-asserting
        // the board's own. The console header names the screen.
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
    ///
    /// ⚠️ Counts the **filtered** set and says so, because "3 of 4 ready to
    /// move" over one repository is a different claim from the same words over
    /// the board — and the reader who set the filter is the one most likely to
    /// forget it is set.
    private var summary: String {
        let steps = model.nextStepsView.steps
        let ready = steps.filter(\.isReady).count
        let total = steps.count + model.nextStepsView.hiddenBlocked
        let scope = model.nextStepsRepoFilterName.map { " in \($0)" } ?? ""
        if total == 0 {
            return scope.isEmpty
                ? "The board has nothing Elliot can advance."
                : "Nothing Elliot can advance\(scope)."
        }
        if ready == 0 {
            return "\(total) card\(total == 1 ? "" : "s") waiting\(scope), none ready to move yet."
        }
        let order = scope.isEmpty ? " The same order `board_next` gives an agent." : ""
        return "\(ready) of \(total) ready to move\(scope).\(order)"
    }

    /// The two choices `board_next` has always given an agent.
    private func filters(_ model: Bindable<AppModel>) -> some View {
        HStack(spacing: 10) {
            Picker("Repository", selection: model.nextStepsRepoFilter) {
                Text("All repositories").tag(UUID?.none)
                ForEach(self.model.nextStepsRepoChoices) { repo in
                    Text(repo.nameWithOwner).tag(UUID?.some(repo.id))
                }
            }
            .labelsHidden()
            .frame(maxWidth: 260)
            Toggle("Show blocked", isOn: model.nextStepsShowsBlocked)
                .toggleStyle(.checkbox)
                .help("Blocked cards are ones a move would refuse. They sort last either way.")
            Spacer(minLength: 0)
        }
        .controlSize(.small)
        .padding(.horizontal, 14)
        .padding(.bottom, 10)
    }

    /// Why the list is empty — three different facts that look identical.
    private var emptyMessage: String {
        if let name = model.nextStepsRepoFilterName {
            return "Nothing in \(name) that Elliot can advance. Choose All repositories to see the rest of the board."
        }
        if model.nextStepsRepoFilter != nil {
            return "The chosen repository is no longer on the board. Choose All repositories to see it again."
        }
        if !model.nextStepsShowsBlocked && model.nextStepsView.hiddenBlocked > 0 {
            return
                "Nothing is ready to move. Show blocked to see the \(model.nextStepsView.hiddenBlocked) card\(model.nextStepsView.hiddenBlocked == 1 ? "" : "s") waiting on something."
        }
        return "Every card is either finished or somewhere Elliot cannot advance on its own."
    }

    /// A cap that does not announce itself reads as a board with nothing more
    /// on it.
    private func cappedNote(_ window: NextStepsWindow) -> String {
        let n = window.hiddenBlocked
        let cards = "\(n) blocked card\(n == 1 ? "" : "s")"
        return model.nextStepsShowsBlocked
            ? "\(cards) not shown — the blocked tail stops at \(NextStepsWindow.blockedLimit)."
            : "\(cards) hidden. Turn on Show blocked to see \(n == 1 ? "it" : "them")."
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
