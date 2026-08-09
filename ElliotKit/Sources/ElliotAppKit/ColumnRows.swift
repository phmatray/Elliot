import ElliotModel
import Foundation

/// How a column arranges the cards it was given.
///
/// A closed enum rather than three optional parameters, because the three are
/// **alternatives** and the column already chooses between them in a fixed
/// order: Done is a dated log, an all-repositories board is grouped, and
/// everything else is a plain run of cards. Written as `groups: [CardGroup]?`
/// plus `log: ShippingLog?` the builder would have a fourth state — both, or
/// neither — that no column can be in and every reader would have to guess at.
enum ColumnLayout: Equatable, Sendable {
    /// Every card in `orderIndex` order, one after another.
    case flat([Card])
    /// One foldable heading per repository, which is what the picker's "All
    /// repositories" turns a column into.
    case byRepository([CardGroup])
    /// One foldable heading per day, plus a horizon that draws nothing at all
    /// past it. Done only.
    case byDay(ShippingLog)
}

/// What identifies a row of a column's list.
///
/// Three id spaces in one list — a repository, a day, a card — so a single
/// `UUID` cannot address them. A case per kind cannot collide and cannot be
/// mistyped, which a string key ("repo-\(id)") could be.
enum ColumnRowID: Hashable, Sendable {
    case repository(UUID)
    case day(Date)
    case card(UUID)
}

/// One row of a column's list, in the order the column draws it.
enum ColumnRow: Identifiable, Equatable, Sendable {
    /// A repository's heading. `folded` is whether it is *drawn* folded, which
    /// is not always what the reader asked for — see `ColumnRows.build`.
    case repository(CardGroup, folded: Bool)
    /// A day's heading in Done, with the same distinction.
    case day(ShipDay, folded: Bool)
    case card(Card)

    var id: ColumnRowID {
        switch self {
        case .repository(let group, _): .repository(group.repoID)
        case .day(let day, _): .day(day.start)
        case .card(let card): .card(card.id)
        }
    }
}

/// Everything a column draws, in the order it draws it — and nothing else.
///
/// It exists because the column drew one list and the keyboard walked another.
/// `stepCard` and `stepColumn` read `model.cards(in:)`, which knows nothing
/// about a folded repository group, nothing about Done's seven-day horizon, and
/// nothing about the fact that a grouped column draws its cards in *repository*
/// order while `cards(in:)` returns them in `orderIndex` order. So ↓ moved the
/// selection to cards that were not on screen, and to cards that were on screen
/// somewhere other than under the one just left — and ⌘→ would then advance a
/// card the reader could not see, which from In Review is the one act that
/// cannot be taken back (#278).
///
/// The fix is not a guard on the keyboard. It is that there is now **one list**:
/// `ColumnView` draws these rows and `BoardView` steps through `cards`, so the
/// two cannot disagree about what is on screen. A fourth kind of heading, or a
/// second horizon, is added here once and both halves follow.
struct ColumnRows: Equatable, Sendable {
    var rows: [ColumnRow] = []

    /// Finished cards Done's horizon left out entirely — the archive footer's
    /// number, and `0` for every other column.
    var olderCount: Int = 0

    /// The cards the reader can actually see, in the order they are drawn.
    ///
    /// This is what the arrow keys walk. Computed rather than stored so there
    /// is no second thing to keep in step with `rows`; the columns are short and
    /// this is one pass over an array the caller has already built.
    var cards: [Card] {
        rows.compactMap {
            guard case .card(let card) = $0 else { return nil }
            return card
        }
    }

    /// Whether this column is drawing that card right now.
    ///
    /// `nil` is `false`, deliberately: "nothing is selected" and "the selection
    /// is drawn" are different answers, and collapsing them is what would let a
    /// scroll fire for a card that does not exist.
    func draws(_ cardID: UUID?) -> Bool {
        guard let cardID else { return false }
        return rows.contains { $0.id == .card(cardID) }
    }
}

extension ColumnRows {

    /// The rule, pure: no model, no clock, no view.
    ///
    /// ⛔ **A fold never hides the selected card, and it does so without
    /// mutating anything.** A heading the reader folded is drawn *open* while it
    /// holds the selection, and folds again the moment the selection leaves — so
    /// the reader's intent is kept in the fold set exactly as they left it,
    /// while the invariant the keyboard depends on ("a selected card is a drawn
    /// card") holds by construction.
    ///
    /// The alternative considered and rejected was auto-expansion: an
    /// `onChange` that *removes* the group from the fold set when the selection
    /// enters it. That destroys what the reader asked for to satisfy a rule they
    /// never asked about, and it needs a side effect on a path — `body` — that
    /// may not have one. This is the same answer expressed as a rendering rule,
    /// which costs nothing and forgets nothing.
    ///
    /// Its one visible consequence is that pressing a heading that holds the
    /// selection would appear to do nothing, so the two toggles in `ColumnView`
    /// give up the selection as they fold. That is stated there, at the act.
    static func build(
        _ layout: ColumnLayout,
        foldedRepoIDs: Set<UUID>,
        foldedDays: Set<Date>,
        selection: UUID?
    ) -> ColumnRows {
        switch layout {
        case .flat(let cards):
            return ColumnRows(rows: cards.map(ColumnRow.card))

        case .byRepository(let groups):
            var rows: [ColumnRow] = []
            for group in groups {
                let folded = drawsFolded(
                    asked: foldedRepoIDs.contains(group.repoID),
                    over: group.cards, selection: selection)
                rows.append(.repository(group, folded: folded))
                if !folded { rows.append(contentsOf: group.cards.map(ColumnRow.card)) }
            }
            return ColumnRows(rows: rows)

        case .byDay(let log):
            var rows: [ColumnRow] = []
            for day in log.days {
                let folded = drawsFolded(
                    asked: foldedDays.contains(day.start),
                    over: day.cards, selection: selection)
                rows.append(.day(day, folded: folded))
                if !folded { rows.append(contentsOf: day.cards.map(ColumnRow.card)) }
            }
            return ColumnRows(rows: rows, olderCount: log.olderCount)
        }
    }

    /// Whether a heading is *drawn* folded, given what the reader asked for.
    private static func drawsFolded(asked: Bool, over cards: [Card], selection: UUID?) -> Bool {
        guard asked, let selection else { return asked }
        return !cards.contains { $0.id == selection }
    }

    /// What is still selected once these cards are folded away — the other side
    /// of the rule above, and the reason it can stay a rendering rule.
    ///
    /// Because a fold that would hide the selection is drawn open instead,
    /// pressing that heading would otherwise appear to do nothing at all. So the
    /// selection is given up **at the act**: the fold then means what it says,
    /// and "a selected card is a drawn card" is never momentarily false.
    ///
    /// Out here rather than inline in the two toggles for the reason this whole
    /// file exists — a rule written twice is a rule that drifts, and this one is
    /// written once for a repository heading and a day heading alike.
    static func selection(_ selection: UUID?, survivingFoldOf cards: [Card]) -> UUID? {
        guard let selection, !cards.contains(where: { $0.id == selection }) else { return nil }
        return selection
    }
}

extension ColumnRows {

    /// The same rule, asked of the board.
    ///
    /// One place assembles the inputs, so the renderer and the keyboard cannot
    /// pick different ones — which is how a column came to draw by repository
    /// name while the arrows walked `orderIndex`. The fold sets are the two
    /// halves the app genuinely holds apart: days are `AppModel.collapsedDays`
    /// (shared with the Archive, which folds the same days), repositories are
    /// the board's own state, per column, because folding a repository in
    /// Backlog must not fold it in To Do.
    ///
    /// The Done branch is taken first, exactly as the column's own `body` took
    /// it: nesting days inside repositories would give one column two levels of
    /// heading where every other has one.
    @MainActor
    static func of(
        _ column: ElliotModel.Column, model: AppModel, foldedRepoIDs: Set<UUID>
    ) -> ColumnRows {
        build(
            layout(column, model: model),
            foldedRepoIDs: foldedRepoIDs,
            foldedDays: model.collapsedDays,
            selection: model.selectedCardID
        )
    }

    @MainActor
    private static func layout(_ column: ElliotModel.Column, model: AppModel) -> ColumnLayout {
        // `doneLog()` filters this column itself, so asking for the cards first
        // and discarding them would be the filter and the sort run twice.
        if column == .done { return .byDay(model.doneLog()) }
        let cards = model.cards(in: column)
        guard model.selectedRepoID == nil else { return .flat(cards) }
        return .byRepository(groupByRepo(cards, repos: model.repos))
    }
}
