import Foundation

/// One repository's cards inside a column.
public struct CardGroup: Sendable, Equatable, Identifiable {
    public var id: UUID { repoID }
    public var repoID: UUID
    public var repoName: String
    public var cards: [Card]

    public init(repoID: UUID, repoName: String, cards: [Card]) {
        self.repoID = repoID
        self.repoName = repoName
        self.cards = cards
    }
}

/// Splits a column's cards by repository, for the all-repositories view.
///
/// `cards(in:)` filters to one repository or does not filter at all, so "All
/// repositories" poured every card from every repository into five columns with
/// nothing but a small repository name to tell them apart. On a control room
/// pointed at several hundred repositories, the mode with the most value was the
/// one that degraded fastest.
///
/// Here rather than in `ColumnView` because `ElliotApp` had no test target when
/// this rule was needed, and because it is a rule: an ordering and a fallback,
/// both of which have a right answer that a view cannot be asked to prove.
public func groupByRepo(_ cards: [Card], repos: [Repo]) -> [CardGroup] {
    let names = Dictionary(repos.map { ($0.id, $0.displayName) }, uniquingKeysWith: { first, _ in first })

    var order: [UUID] = []
    var byRepo: [UUID: [Card]] = [:]
    for card in cards {
        if byRepo[card.repoID] == nil { order.append(card.repoID) }
        byRepo[card.repoID, default: []].append(card)
    }

    return
        order
        .map { repoID in
            CardGroup(
                repoID: repoID,
                // A card whose repository has been removed keeps its group
                // rather than vanishing into one called "?" alongside every
                // other orphan. `nextCandidates` drops such a card on purpose —
                // it has no checkout to run in — but the board still holds it,
                // and a card you can see and cannot place is better than a card
                // that quietly disappeared.
                repoName: names[repoID] ?? "Unknown repository",
                cards: byRepo[repoID] ?? []
            )
        }
        // By name, so the same board reads the same way twice. The insertion
        // order above is only there to collect; it follows `orderIndex`, which
        // would make groups jump about as cards move between columns.
        .sorted { lhs, rhs in
            lhs.repoName == rhs.repoName
                ? lhs.repoID.uuidString < rhs.repoID.uuidString
                : lhs.repoName.localizedStandardCompare(rhs.repoName) == .orderedAscending
        }
}
