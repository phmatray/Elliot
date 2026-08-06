import ElliotModel
import SwiftUI

/// How a card got to the column it is in.
///
/// Mirrors `DetailPanelView.provenance` at the top of the Issue pane: that block
/// says what GitHub holds, this one says what the board did. Every move has been
/// recorded since migration v3 — `commitMove` writes a `MoveAudit` inside the
/// same transaction that moves the card — and until #101 the only part of it
/// anyone could read was a single sentence in the header, for one kind of move,
/// about one column.
///
/// It judges nothing. The rows come from `MoveHistory.rows`, which is pure and
/// tested; this only places them.
struct MoveHistoryBlock: View {
    let card: Card

    @Environment(AppModel.self) private var model

    private var audits: [MoveAudit] { model.historyByCard[card.id] ?? [] }

    private var rows: [MoveHistoryRow] {
        MoveHistory.rows(audits: audits, runs: model.runsByCard[card.id] ?? [])
    }

    var body: some View {
        // A card that has never moved has nothing to say, and an empty
        // captioned box reads as broken rather than as empty — `RunsPane`'s
        // empty state is the same lesson. So the block is absent, not blank.
        if !rows.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                ConsoleLabel(text: "How it got here")
                ForEach(rows) { row in
                    line(row)
                }
                if MoveHistory.isCapped(count: audits.count) {
                    // A list read at its limit may be missing older moves.
                    // Saying so costs one quiet line; presenting a truncated
                    // list as complete is the failure this project keeps
                    // finding in other guises.
                    Text("Showing the most recent \(MoveHistory.auditLimit) moves; there may be more.")
                        .font(Type.prose)
                        .foregroundStyle(.tertiary)
                        .padding(.top, 2)
                }
            }
        }
    }

    private func line(_ row: MoveHistoryRow) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            // The two columns, not just the destination: a card that went
            // In Review → In Progress, rendered as "In Progress", tells the
            // reader the opposite of what happened.
            Fact(text: "\(row.from.displayName) → \(row.to.displayName)", tint: .primary)
            Text(Elapsed.age(of: row.at))
                .font(Type.prose)
                .foregroundStyle(.tertiary)
                .help(row.at.formatted(date: .abbreviated, time: .shortened))
            Text(row.origin)
                .font(Type.prose)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            if let run = row.run {
                runFact(run)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(BoardAccessibility.historyRowLabel(
            from: row.from.displayName, to: row.to.displayName,
            age: Elapsed.age(of: row.at), origin: row.origin,
            run: run(run: row.run)))
    }

    /// The skill this move started, when the run is in the loaded window.
    ///
    /// When it is not, the row still says a run started — it just cannot name
    /// it, and it says *that* rather than falling silent. `runsByCard` holds 20
    /// runs against 100 audits, so this is reachable, and a silent row would
    /// claim the move started nothing. The unnamed form is drawn in the demoted
    /// face for the reason the verdict block demotes an agent's prose: it is
    /// less than a fact, and it must not look like one.
    @ViewBuilder
    private func runFact(_ ref: MoveHistoryRow.RunRef) -> some View {
        if let name = ref.skillName {
            Fact(text: name, tint: Palette.quiet, small: true)
        } else {
            Text("started a run")
                .font(Type.hearsay)
                .foregroundStyle(.tertiary)
        }
    }

    /// What the accessibility sentence says about the run, in the same two
    /// registers the visible row uses.
    private func run(run ref: MoveHistoryRow.RunRef?) -> String? {
        guard let ref else { return nil }
        return ref.skillName ?? "a run this panel cannot name"
    }
}
