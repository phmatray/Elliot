import Foundation
import Testing

@testable import ElliotModel

@Suite("Card grouping")
struct CardGroupingTests {
    private let epoch = Date(timeIntervalSince1970: 1_770_000_000)

    private func repo(_ name: String) -> Repo {
        Repo(
            path: "/tmp/\(name)", nameWithOwner: "phmatray/\(name)",
            defaultBranch: "main", displayName: name
        )
    }

    private func card(_ title: String, repoID: UUID, order: Double = 0) -> Card {
        Card(
            repoID: repoID, title: title, column: .todo, orderIndex: order,
            columnEnteredAt: epoch, createdAt: epoch, updatedAt: epoch
        )
    }

    @Test("Nothing groups into nothing")
    func emptyIsEmpty() {
        #expect(groupByRepo([], repos: [repo("Elliot")]).isEmpty)
    }

    @Test("Groups come back sorted by repository name")
    func sortedByName() {
        // Not by insertion order, which follows `orderIndex` and would make the
        // groups jump about as cards move between columns. The same board must
        // read the same way twice.
        let z = repo("Zebra")
        let a = repo("Alpha")
        let m = repo("Middle")
        let groups = groupByRepo(
            [card("1", repoID: z.id), card("2", repoID: a.id), card("3", repoID: m.id)],
            repos: [z, a, m]
        )
        #expect(groups.map(\.repoName) == ["Alpha", "Middle", "Zebra"])
    }

    @Test("Cards keep the order they arrived in, within their group")
    func cardOrderIsPreserved() {
        // The caller has already sorted by `orderIndex`; regrouping must not
        // undo that, or a drag-to-reorder would appear to have no effect.
        let a = repo("Elliot")
        let cards = [
            card("first", repoID: a.id, order: 1),
            card("second", repoID: a.id, order: 2),
            card("third", repoID: a.id, order: 3),
        ]
        #expect(groupByRepo(cards, repos: [a])[0].cards.map(\.title) == ["first", "second", "third"])
    }

    @Test("Every card lands in exactly one group, and none is lost")
    func nothingIsLost() {
        let a = repo("Elliot")
        let b = repo("Lyrics")
        let cards = [
            card("a1", repoID: a.id), card("b1", repoID: b.id),
            card("a2", repoID: a.id), card("b2", repoID: b.id),
        ]
        let groups = groupByRepo(cards, repos: [a, b])
        #expect(groups.count == 2)
        #expect(groups.flatMap(\.cards).count == cards.count)
        #expect(Set(groups.flatMap(\.cards).map(\.id)) == Set(cards.map(\.id)))
    }

    @Test("A card whose repository is gone keeps its own group, and is named")
    func orphansAreNamedNotMerged() {
        // Deliberately not folded into one bucket called "?": two orphans from
        // different repositories are two different things, and a card you can
        // see but not place beats a card that quietly disappeared.
        let a = repo("Elliot")
        let ghostA = UUID()
        let ghostB = UUID()
        let groups = groupByRepo(
            [card("kept", repoID: a.id), card("x", repoID: ghostA), card("y", repoID: ghostB)],
            repos: [a]
        )
        #expect(groups.count == 3)
        #expect(groups.filter { $0.repoName == "Unknown repository" }.count == 2)
        #expect(groups.flatMap(\.cards).count == 3)
    }

    @Test("Two repositories sharing a display name stay apart")
    func sameNameDoesNotCollapse() {
        // `displayName` is the last path component, so `a/Elliot` and `b/Elliot`
        // are perfectly possible. Grouping is by id; the tie-break only decides
        // which of the two is drawn first, and does so deterministically.
        let one = repo("Elliot")
        let two = repo("Elliot")
        let groups = groupByRepo(
            [card("1", repoID: one.id), card("2", repoID: two.id)], repos: [one, two]
        )
        #expect(groups.count == 2)
        let again = groupByRepo(
            [card("2", repoID: two.id), card("1", repoID: one.id)], repos: [one, two]
        )
        #expect(groups.map(\.repoID) == again.map(\.repoID))
    }

    @Test("Sorting is human, not ASCII")
    func humanSort() {
        // `localizedStandardCompare`, so "elliot" does not sort after "Zebra"
        // the way a byte comparison would put every lower-case name last.
        let lower = repo("elliot")
        let upper = repo("Zebra")
        let groups = groupByRepo(
            [card("1", repoID: upper.id), card("2", repoID: lower.id)], repos: [lower, upper]
        )
        #expect(groups.map(\.repoName) == ["elliot", "Zebra"])
    }
}
