import ElliotModel
import Foundation
import Testing

@testable import ElliotStore

private let epoch = Date(timeIntervalSince1970: 1_700_000_000)

private func makeRepo(_ name: String = "Elliot") -> Repo {
    Repo(
        path: "/tmp/repo-\(UUID().uuidString)",
        nameWithOwner: "phmatray/\(name)",
        displayName: name
    )
}

private func doneCard(
    _ title: String,
    repoID: UUID,
    body: String = "",
    column: Column = .done,
    daysAgo: Double = 0,
    issue: Int? = nil,
    pr: Int? = nil
) -> Card {
    let at = epoch.addingTimeInterval(-daysAgo * 86_400)
    return Card(
        repoID: repoID,
        title: title,
        body: body,
        column: column,
        issueNumber: issue,
        prNumber: pr,
        columnEnteredAt: at,
        createdAt: at,
        updatedAt: at
    )
}

/// The archive's read side: the whole finished history, newest first, paged
/// and searchable.
///
/// Asserted against a real database rather than a fake, for the reason the
/// neighbouring suites give: the question is what SQLite returns for the order
/// and the filter each one asks for, and a fake would only echo the arguments
/// back.
@Suite("Done history")
struct DoneHistoryTests {

    @Test("Newest first, and paging neither repeats nor skips a row")
    func paging() async throws {
        let store = try BoardStore.inMemory()
        let repo = makeRepo()
        try await store.saveRepo(repo)
        for index in 0..<5 {
            try await store.saveCard(
                doneCard("card \(index)", repoID: repo.id, daysAgo: Double(4 - index))
            )
        }

        let first = try await store.doneCards(limit: 2, offset: 0)
        let second = try await store.doneCards(limit: 2, offset: 2)
        let third = try await store.doneCards(limit: 2, offset: 4)

        #expect(first.map(\.title) == ["card 4", "card 3"])
        #expect(second.map(\.title) == ["card 2", "card 1"])
        #expect(third.map(\.title) == ["card 0"])
        #expect(try await store.doneCardCount() == 5)

        // The union of the pages is the whole set, with nothing seen twice.
        let paged = first + second + third
        #expect(Set(paged.map(\.id)).count == 5)
    }

    @Test("Only finished cards are in the history")
    func onlyDone() async throws {
        let store = try BoardStore.inMemory()
        let repo = makeRepo()
        try await store.saveRepo(repo)
        try await store.saveCard(doneCard("shipped", repoID: repo.id))
        try await store.saveCard(doneCard("in flight", repoID: repo.id, column: .inReview))
        try await store.saveCard(doneCard("waiting", repoID: repo.id, column: .backlog))

        #expect(try await store.doneCardCount() == 1)
        #expect(try await store.doneCards(limit: 10).map(\.title) == ["shipped"])
    }

    @Test("Search matches the title and the body, case-insensitively")
    func searchMatchesTitleAndBody() async throws {
        let store = try BoardStore.inMemory()
        let repo = makeRepo()
        try await store.saveRepo(repo)
        try await store.saveCard(doneCard("Ship the log", repoID: repo.id))
        try await store.saveCard(doneCard("Unrelated", repoID: repo.id, body: "mentions the LOG here"))
        try await store.saveCard(doneCard("Nothing to see", repoID: repo.id))

        #expect(try await store.doneCardCount(search: "log") == 2)
        #expect(try await store.doneCardCount(search: "LOG") == 2)
        #expect(try await store.doneCardCount(search: "nothing at all") == 0)
    }

    /// The reason the query uses `instr` rather than `LIKE`: with `LIKE` these
    /// two characters are wildcards, and a search box that treats `%` as "match
    /// everything" turns a typo into a result set. There is no escape clause to
    /// get wrong because there is no pattern language.
    @Test("A percent sign and an underscore are searched for, not treated as wildcards")
    func metacharactersAreLiteral() async throws {
        let store = try BoardStore.inMemory()
        let repo = makeRepo()
        try await store.saveRepo(repo)
        try await store.saveCard(doneCard("100% done", repoID: repo.id))
        try await store.saveCard(doneCard("snake_case name", repoID: repo.id))
        try await store.saveCard(doneCard("plain", repoID: repo.id))

        #expect(try await store.doneCardCount(search: "%") == 1)
        #expect(try await store.doneCardCount(search: "_") == 1)
        // Had `_` been a wildcard this would match all three.
        #expect(try await store.doneCardCount(search: "p_ain") == 0)
    }

    /// Both sides have to be folded by the *same* `lower`. Folding the needle
    /// in Swift (Unicode-aware, `É → é`) against a haystack folded by SQLite
    /// (ASCII-only, `É` untouched) made an uppercase-accented title findable by
    /// no query at all — not by the accented form, not by the exact string.
    @Test("An uppercase accented title is findable, in either case")
    func accentedTitleIsFindable() async throws {
        let store = try BoardStore.inMemory()
        let repo = makeRepo()
        try await store.saveRepo(repo)
        try await store.saveCard(doneCard("ÉCRIRE la doc", repoID: repo.id))
        try await store.saveCard(doneCard("plain", repoID: repo.id))

        #expect(try await store.doneCardCount(search: "ÉCRIRE") == 1)
        #expect(try await store.doneCardCount(search: "la doc") == 1)
        // ASCII case-insensitivity still holds, which is all `lower()` promises.
        #expect(try await store.doneCardCount(search: "LA DOC") == 1)
    }

    /// The archive re-sorts each page with `shippingLog`, so the two orderings
    /// have to agree — otherwise a page of same-second cards is a middle slice
    /// of its day rather than a prefix, and later pages insert rows above ones
    /// already on screen.
    @Test("Ties page in descending id, matching the model's tie-break")
    func tieOrderMatchesTheModel() async throws {
        let store = try BoardStore.inMemory()
        let repo = makeRepo()
        try await store.saveRepo(repo)
        let ids = [
            UUID(uuidString: "00000000-0000-0000-0000-0000000000AA")!,
            UUID(uuidString: "00000000-0000-0000-0000-0000000000BB")!,
            UUID(uuidString: "00000000-0000-0000-0000-0000000000CC")!,
        ]
        for id in ids {
            var card = doneCard("tied", repoID: repo.id)
            card.id = id
            try await store.saveCard(card)
        }

        let paged = try await store.doneCards(limit: 3)
        let grouped = shippingLog(paged, now: epoch, calendar: .current, horizonDays: nil)
        #expect(paged.map(\.id) == grouped.days.flatMap(\.cards).map(\.id))
    }

    @Test("An all-digit query also matches the issue or pull request number")
    func searchByNumber() async throws {
        let store = try BoardStore.inMemory()
        let repo = makeRepo()
        try await store.saveRepo(repo)
        try await store.saveCard(doneCard("nothing in the title", repoID: repo.id, issue: 141))
        try await store.saveCard(doneCard("nor here", repoID: repo.id, pr: 154))
        try await store.saveCard(doneCard("plain", repoID: repo.id))

        #expect(try await store.doneCardCount(search: "141") == 1)
        #expect(try await store.doneCardCount(search: "154") == 1)
        #expect(try await store.doneCardCount(search: "999") == 0)
    }

    @Test("The repository filter scopes both the page and its count")
    func repoFilter() async throws {
        let store = try BoardStore.inMemory()
        let mine = makeRepo("Elliot")
        let other = makeRepo("Koine")
        try await store.saveRepo(mine)
        try await store.saveRepo(other)
        try await store.saveCard(doneCard("mine", repoID: mine.id))
        try await store.saveCard(doneCard("theirs", repoID: other.id))

        #expect(try await store.doneCardCount() == 2)
        #expect(try await store.doneCardCount(repoID: mine.id) == 1)
        #expect(try await store.doneCards(repoID: mine.id, limit: 10).map(\.title) == ["mine"])
    }

    /// The count is what tells the archive whether another page exists, so it
    /// has to answer the *same* question the page does. Counting the unfiltered
    /// table would offer a "Load more" that loads nothing.
    @Test("The count answers the same filter as the page")
    func countMatchesPage() async throws {
        let store = try BoardStore.inMemory()
        let repo = makeRepo()
        try await store.saveRepo(repo)
        for index in 0..<4 {
            try await store.saveCard(
                doneCard("log entry \(index)", repoID: repo.id, daysAgo: Double(index))
            )
        }
        try await store.saveCard(doneCard("unrelated", repoID: repo.id))

        let count = try await store.doneCardCount(search: "log entry")
        let all = try await store.doneCards(search: "log entry", limit: 100)
        #expect(count == 4)
        #expect(all.count == count)
    }

    @Test("An empty or blank search is no filter at all")
    func blankSearchIsNoFilter() async throws {
        let store = try BoardStore.inMemory()
        let repo = makeRepo()
        try await store.saveRepo(repo)
        try await store.saveCard(doneCard("a", repoID: repo.id))
        try await store.saveCard(doneCard("b", repoID: repo.id))

        #expect(try await store.doneCardCount(search: nil) == 2)
        #expect(try await store.doneCardCount(search: "") == 2)
        #expect(try await store.doneCardCount(search: "   ") == 2)
    }
}
