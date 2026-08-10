import ElliotModel
import SwiftUI

/// What Elliot thinks should happen next, in order — and the one place on the
/// Operations screen where a gesture does work.
///
/// This list already existed. `rankNextSteps` is pure, tested, and served to
/// agents over MCP as `board_next`; the human got five columns and rebuilt the
/// order in their head at every glance. The app computed the answer and gave it
/// only to the robot.
///
/// The view reads. It ranks nothing, sorts nothing and words nothing of its own:
/// the order is `rankNextSteps`', each row's sentence comes from
/// `Consequence.of`, which is what the column headers already say, and how much
/// of the list a folded band draws is `NextStepsWindow.band(expanded:)`'s. A
/// second wording — or a second prefix — here would drift from the board it is
/// describing.
///
/// ⛔ **It was a `NextStepsView`, a screen of its own, until #304 — and the whole
/// point of this file is that it is not one any more.** The same ranking was
/// drawn twice: this list's rows called `model.move(cardID:to:)`, the Operations
/// band's rows were inert `HStack`s, and *"See all N"* existed only to carry a
/// reader from the drawing that could not act to the one that could. Two
/// drawings of one ranking is two places for `.disabled(consequence.isRefused)`
/// to be true, and it was already only true in one of them. `UpNextBandSourceTests`
/// is the gate that keeps it at one.
///
/// **It draws no title of its own.** `OperationsView.band(_:)` supplies the
/// `ConsoleLabel`, and the console header above supplies the screen's name. A
/// header here would be the third *"Up next"* on one screen.
struct UpNextBand: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        let window = model.nextStepsView
        let band = window.band(expanded: model.nextStepsExpanded)
        return VStack(alignment: .leading, spacing: 8) {
            Text(summary)
                .font(Type.prose)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            filters($model)
            if window.steps.isEmpty {
                // A sentence, like every other band's empty state — not a
                // `ContentUnavailableView`, which claims a whole screen and
                // would push the five bands above it out of one glance. What it
                // said is kept; only its furniture is dropped.
                Text(emptyMessage)
                    .font(Type.prose)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                // `LazyVStack` and no `ScrollView`: `OperationsView` already
                // scrolls, and a scroll view inside a scroll view gives the
                // reader two of them fighting over one gesture.
                LazyVStack(spacing: 6) {
                    ForEach(Array(band.shown.enumerated()), id: \.element.card.id) {
                        index, step in
                        row(step, position: index + 1)
                    }
                }
                // `canFold`, never `isFolded`: an expanded band whose ranking has
                // since shrunk holds nothing back, and offering "Show fewer"
                // there is a control that does nothing.
                if band.canFold {
                    disclosure(band)
                }
                if window.isCapped {
                    Text(cappedNote(window))
                        .font(Type.factSmall)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
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

    /// The rest of the list, one press away and in this band.
    ///
    /// ⛔ **It replaced a button that opened a second window** (#304), and the
    /// count is the reason that shape could not simply be kept honest: *"See all
    /// N"* counted `AppModel.nextSteps` — the whole board — and opened a screen
    /// rendering `nextStepsView`, which the repository picker and the blocked
    /// toggle above have already narrowed. `band.folded` is counted off the rows
    /// this very band would reveal, so the number and the reveal cannot disagree.
    ///
    /// No `.keyboardShortcut(.defaultAction)`, and not merely because pressing it
    /// is harmless: this band sits in the board window beside `DetailPanelView`'s
    /// Save, and `DefaultAction` names the three controls Return belongs to.
    private func disclosure(_ band: NextStepsBand) -> some View {
        Button(band.isFolded ? "Show \(band.folded) more" : "Show fewer") {
            model.nextStepsExpanded.toggle()
        }
        .controlSize(.small)
        .accessibilityHint(
            band.isFolded
                ? "Unfolds the rest of the ranking in this band"
                : "Folds the ranking back to its first \(NextStepsWindow.bandLimit)")
    }

    /// A cap that does not announce itself reads as a board with nothing more
    /// on it.
    ///
    /// ⚠️ A different fact from the disclosure above, deliberately worded apart.
    /// These rows are gone from the ranking — the reader's own toggle or the
    /// blocked cap removed them — and no press of *Show more* brings them back.
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
        // ⛔ **Load-bearing, and the half the Operations band never had.** A row
        // the rules refuse must not be pressable: pressing one is a real move
        // through `BoardService`, and three of the five transitions start an
        // unattended `claude -p` at `bypassPermissions` inside a real checkout.
        // The refusal is still *stated* — that is `consequence.summary` above,
        // in `Palette.refused` — it is simply not offered.
        .disabled(consequence.isRefused)
        .help(consequence.summary)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(position). \(step.repoName), \(step.card.displayTitle). \(consequence.summary)")
    }
}
