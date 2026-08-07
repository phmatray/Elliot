import ElliotModel
import Foundation
import Testing

@testable import ElliotAppKit

/// What the Done column *decides*, which is the horizon and what it hides.
///
/// Where the day headers sit is layout, and this project has paid four times
/// for treating a green suite as a statement about the screen (#47, #50, #52,
/// #53). The on-screen pass is the other half of this task's proof.
@MainActor
@Suite("Done column")
struct DoneColumnTests {

    private static let utc: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func repo(_ name: String) -> Repo {
        Repo(
            path: "/tmp/\(name)", nameWithOwner: "phmatray/\(name)",
            defaultBranch: "main", displayName: name
        )
    }

    private func card(
        _ title: String, repoID: UUID, column: ElliotModel.Column = .done, daysAgo: Double = 0
    ) -> Card {
        let at = now.addingTimeInterval(-daysAgo * 86_400)
        return Card(
            repoID: repoID, title: title, column: column,
            columnEnteredAt: at, createdAt: at, updatedAt: at
        )
    }

    private func model(repos: [Repo], cards: [Card]) -> AppModel {
        let model = AppModel()
        model.testOnlySeed(repos: repos, cards: cards)
        return model
    }

    @Test("The done log honours the horizon and still reports the full total")
    func horizonAndTotal() {
        let elliot = repo("Elliot")
        let model = model(
            repos: [elliot],
            cards: [
                card("fresh", repoID: elliot.id, daysAgo: 0),
                card("ancient", repoID: elliot.id, daysAgo: 40),
            ]
        )

        let log = model.doneLog(now: now, calendar: Self.utc)
        #expect(log.days.count == 1)
        #expect(log.olderCount == 1)
        // The caption reads this. A board saying "Done, 1 card" while two
        // exist would be under-reporting itself to the one reader who cannot
        // scroll to check.
        #expect(log.totalCount == 2)
    }

    @Test("Only finished cards enter the log")
    func onlyDone() {
        let elliot = repo("Elliot")
        let model = model(
            repos: [elliot],
            cards: [
                card("wip", repoID: elliot.id, column: .inReview),
                card("queued", repoID: elliot.id, column: .todo),
                card("shipped", repoID: elliot.id, column: .done),
            ]
        )
        let log = model.doneLog(now: now, calendar: Self.utc)
        #expect(log.totalCount == 1)
        #expect(log.days.first?.cards.first?.title == "shipped")
    }

    /// Built on `cards(in:)` rather than on `cards`, so the repository picker
    /// is applied in exactly one place. A second filter here is how the board
    /// and the column would come to disagree about what "All repositories"
    /// means.
    @Test("The repository picker still applies")
    func honoursRepoFilter() {
        let elliot = repo("Elliot")
        let other = repo("Koine")
        let model = model(
            repos: [elliot, other],
            cards: [
                card("mine", repoID: elliot.id),
                card("theirs", repoID: other.id),
            ]
        )
        #expect(model.doneLog(now: now, calendar: Self.utc).totalCount == 2)

        model.selectedRepoID = elliot.id
        let scoped = model.doneLog(now: now, calendar: Self.utc)
        #expect(scoped.totalCount == 1)
        #expect(scoped.days.first?.cards.first?.title == "mine")
    }

    /// The visible footer is terse — "37 older · Open Archive". This is the
    /// sentence read aloud, and it follows the same singular rule as the column
    /// caption and the group header, for the reason recorded on those two.
    @Test("The footer counts what the horizon hid, and says nothing when it hid nothing")
    func footerWording() {
        #expect(BoardAccessibility.olderFooter(count: 37) == "37 older cards. Open Archive.")
        #expect(BoardAccessibility.olderFooter(count: 1) == "1 older card. Open Archive.")
    }

    /// Not "0 older cards" — an empty string, because the footer is not drawn
    /// at all. A label announcing a control that is not there is worse than no
    /// label.
    @Test("Nothing hidden is no sentence at all")
    func footerSilentWhenNothingHidden() {
        #expect(BoardAccessibility.olderFooter(count: 0).isEmpty)
    }

    @Test("An empty Done is an empty log, and draws no archive footer")
    func emptyDone() {
        let elliot = repo("Elliot")
        let model = model(repos: [elliot], cards: [card("wip", repoID: elliot.id, column: .todo)])
        let log = model.doneLog(now: now, calendar: Self.utc)
        #expect(log.days.isEmpty)
        #expect(log.olderCount == 0)
    }
}
