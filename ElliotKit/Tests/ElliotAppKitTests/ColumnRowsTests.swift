import ElliotModel
import Foundation
import Testing

@testable import ElliotAppKit

/// What a column *draws*, which until #278 was a claim only the screen could
/// hold.
///
/// The defect was not a wrong answer anywhere — it was two answers. `ColumnView`
/// drew a folded group as a heading and nothing else, drew Done under a
/// seven-day horizon, and drew an all-repositories column in repository order;
/// `BoardView.stepCard` walked `model.cards(in:)`, which does none of those
/// three. So ↓ moved the selection onto cards that were not on screen, and ⌘→
/// would then advance one — from In Review that is the merge, the single act
/// that cannot be taken back.
///
/// Where the rows sit is still layout and still unverifiable here (#47, #50,
/// #52, #53). What is verifiable is that there is now one list, and these are
/// its rules.
@MainActor
@Suite("Column rows")
struct ColumnRowsTests {

    // MARK: - Fixtures

    private let epoch = Date(timeIntervalSince1970: 1_770_000_000)

    private func repo(_ name: String) -> Repo {
        Repo(
            path: "/tmp/\(name)", nameWithOwner: "phmatray/\(name)",
            defaultBranch: "main", displayName: name
        )
    }

    private func card(
        _ title: String, repoID: UUID, column: ElliotModel.Column = .backlog, order: Double = 0
    ) -> Card {
        Card(
            repoID: repoID, title: title, column: column, orderIndex: order,
            columnEnteredAt: epoch, createdAt: epoch, updatedAt: epoch
        )
    }

    private func titles(_ rows: ColumnRows) -> [String] { rows.cards.map(\.title) }

    // MARK: - The plain column

    @Test("A plain column draws its cards, in the order it was handed them")
    func flat() {
        let elliot = repo("Elliot")
        let cards = [
            card("first", repoID: elliot.id, order: 0),
            card("second", repoID: elliot.id, order: 1),
        ]
        let rows = ColumnRows.build(
            .flat(cards), foldedRepoIDs: [], foldedDays: [], selection: nil)

        #expect(rows.rows.count == 2)
        #expect(titles(rows) == ["first", "second"])
        #expect(rows.olderCount == 0)
    }

    // MARK: - Repository groups

    @Test("A folded repository draws its heading and nothing under it")
    func foldedGroupDrawsNoCards() {
        let elliot = repo("Elliot")
        let group = CardGroup(
            repoID: elliot.id, repoName: "Elliot",
            cards: [card("hidden", repoID: elliot.id)]
        )
        let rows = ColumnRows.build(
            .byRepository([group]), foldedRepoIDs: [elliot.id], foldedDays: [], selection: nil)

        #expect(rows.rows == [.repository(group, folded: true)])
        #expect(rows.cards.isEmpty)
    }

    /// The rule the whole issue is named for, and the reason it is a *rendering*
    /// rule rather than an `onChange` that empties the fold set: the reader's
    /// intent survives untouched, and comes back the moment it can be honoured.
    @Test("A fold never hides the selected card, and returns when the selection leaves")
    func foldYieldsToTheSelection() {
        let elliot = repo("Elliot")
        let selected = card("selected", repoID: elliot.id)
        let other = card("other", repoID: elliot.id, order: 1)
        let group = CardGroup(repoID: elliot.id, repoName: "Elliot", cards: [selected, other])

        let holding = ColumnRows.build(
            .byRepository([group]), foldedRepoIDs: [elliot.id], foldedDays: [],
            selection: selected.id)
        #expect(holding.rows.first == .repository(group, folded: false))
        #expect(titles(holding) == ["selected", "other"])
        #expect(holding.draws(selected.id))

        // Same fold set, selection moved away: folded again, with nothing having
        // been written anywhere.
        let released = ColumnRows.build(
            .byRepository([group]), foldedRepoIDs: [elliot.id], foldedDays: [],
            selection: UUID())
        #expect(released.rows == [.repository(group, folded: true)])
    }

    /// The half of #278 nobody reported, and the one the keyboard felt on every
    /// press: an all-repositories column draws by repository name while
    /// `cards(in:)` returns `orderIndex` order, so ↓ moved the selection to a
    /// card that was on screen *somewhere other than under the one just left*.
    @Test("A grouped column draws in repository order, not in orderIndex order")
    func groupedOrderIsNotCardOrder() {
        let zeta = repo("Zeta")
        let alpha = repo("Alpha")
        let inOrderIndexOrder = [
            card("zeta card", repoID: zeta.id, order: 0),
            card("alpha card", repoID: alpha.id, order: 1),
        ]
        let rows = ColumnRows.build(
            .byRepository(groupByRepo(inOrderIndexOrder, repos: [zeta, alpha])),
            foldedRepoIDs: [], foldedDays: [], selection: nil)

        #expect(titles(rows) == ["alpha card", "zeta card"])
        #expect(titles(rows) != inOrderIndexOrder.map(\.title))
    }

    // MARK: - Done

    @Test("A folded day draws its heading, and the horizon's count survives it")
    func foldedDay() {
        let elliot = repo("Elliot")
        let day = ShipDay(
            start: epoch, label: .today, cards: [card("shipped", repoID: elliot.id, column: .done)])
        let log = ShippingLog(days: [day], olderCount: 37, totalCount: 38)

        let open = ColumnRows.build(
            .byDay(log), foldedRepoIDs: [], foldedDays: [], selection: nil)
        #expect(titles(open) == ["shipped"])
        #expect(open.olderCount == 37)

        let folded = ColumnRows.build(
            .byDay(log), foldedRepoIDs: [], foldedDays: [epoch], selection: nil)
        #expect(folded.rows == [.day(day, folded: true)])
        #expect(folded.cards.isEmpty)
        // The archive footer is not part of the fold: what the horizon left out
        // is still left out, and still says so.
        #expect(folded.olderCount == 37)
    }

    @Test("A day the selection is in stays open, exactly as a repository does")
    func foldedDayYieldsToTheSelection() {
        let elliot = repo("Elliot")
        let selected = card("shipped", repoID: elliot.id, column: .done)
        let day = ShipDay(start: epoch, label: .today, cards: [selected])
        let rows = ColumnRows.build(
            .byDay(ShippingLog(days: [day], olderCount: 0, totalCount: 1)),
            foldedRepoIDs: [], foldedDays: [epoch], selection: selected.id)

        #expect(rows.rows.first == .day(day, folded: false))
        #expect(rows.draws(selected.id))
    }

    // MARK: - Drawing, and being drawn

    @Test("Nothing selected is not the same question as a card being drawn")
    func drawsNothing() {
        let elliot = repo("Elliot")
        let rows = ColumnRows.build(
            .flat([card("only", repoID: elliot.id)]),
            foldedRepoIDs: [], foldedDays: [], selection: nil)

        #expect(!rows.draws(nil))
        #expect(!rows.draws(UUID()))
        #expect(rows.draws(rows.cards[0].id))
    }

    @Test("Every row is identified by its own kind, so a heading cannot shadow a card")
    func rowIdentity() {
        let elliot = repo("Elliot")
        let one = card("one", repoID: elliot.id)
        let group = CardGroup(repoID: elliot.id, repoName: "Elliot", cards: [one])
        let rows = ColumnRows.build(
            .byRepository([group]), foldedRepoIDs: [], foldedDays: [], selection: nil)

        #expect(rows.rows.map(\.id) == [.repository(elliot.id), .card(one.id)])
        #expect(Set(rows.rows.map(\.id)).count == rows.rows.count)
    }

    // MARK: - The board's own assembly

    /// One place picks the layout, so the renderer and the keyboard cannot pick
    /// different ones — which is the whole of the fix.
    @Test("All repositories groups the column; one repository does not")
    func layoutFollowsThePicker() {
        let elliot = repo("Elliot")
        let koine = repo("Koine")
        let model = AppModel()
        model.testOnlySeed(
            repos: [elliot, koine],
            cards: [
                card("elliot story", repoID: elliot.id, order: 0),
                card("koine story", repoID: koine.id, order: 1),
            ]
        )

        let grouped = ColumnRows.of(.backlog, model: model, foldedRepoIDs: [])
        #expect(grouped.rows.count == 4)  // two headings, two cards
        #expect(titles(grouped) == ["elliot story", "koine story"])

        model.selectedRepoID = koine.id
        let single = ColumnRows.of(.backlog, model: model, foldedRepoIDs: [])
        #expect(single.rows.count == 1)
        #expect(titles(single) == ["koine story"])
    }

    @Test("The board reads the fold sets the app actually holds")
    func foldSetsComeFromWhereTheyLive() {
        let elliot = repo("Elliot")
        let model = AppModel()
        model.testOnlySeed(repos: [elliot], cards: [card("story", repoID: elliot.id)])

        #expect(ColumnRows.of(.backlog, model: model, foldedRepoIDs: []).cards.count == 1)
        // Repository folds are the board's, passed in per column.
        #expect(ColumnRows.of(.backlog, model: model, foldedRepoIDs: [elliot.id]).cards.isEmpty)
    }

    /// Done's cards past the horizon are drawn *nowhere* — not folded away, not
    /// under a heading. The arrows must not reach them either, and this is the
    /// only one of the three cases that no fold set can express.
    @Test("Done's horizon is not in the list the arrows walk")
    func horizonIsNotWalked() {
        let elliot = repo("Elliot")
        let now = Date()
        func shipped(_ title: String, daysAgo: Double) -> Card {
            let at = now.addingTimeInterval(-daysAgo * 86_400)
            return Card(
                repoID: elliot.id, title: title, column: .done,
                columnEnteredAt: at, createdAt: at, updatedAt: at)
        }
        let model = AppModel()
        model.testOnlySeed(
            repos: [elliot],
            cards: [shipped("fresh", daysAgo: 0), shipped("ancient", daysAgo: 40)])

        let rows = ColumnRows.of(.done, model: model, foldedRepoIDs: [])
        #expect(titles(rows) == ["fresh"])
        #expect(rows.olderCount == 1)
        // And the column still holds both, which is what its caption reports.
        #expect(model.cards(in: .done).count == 2)
    }

    // MARK: - Folding, at the act

    /// Found by break-testing: deleting the whole of `fold(away:_:)`'s effect
    /// left all 1992 tests green. The rule above says a fold that would hide the
    /// selection is drawn open instead, so without this one the chevron does
    /// **nothing at all** on exactly the group the reader is looking at — and
    /// nothing could have failed.
    @Test("Folding a heading gives up the selection it was holding")
    func selectionYieldsAtTheFold() {
        let elliot = repo("Elliot")
        let selected = card("selected", repoID: elliot.id)
        let elsewhere = card("elsewhere", repoID: elliot.id, order: 1)

        #expect(ColumnRows.selection(selected.id, survivingFoldOf: [selected]) == nil)
        // A fold somewhere else costs the reader nothing.
        #expect(ColumnRows.selection(selected.id, survivingFoldOf: [elsewhere]) == selected.id)
        #expect(ColumnRows.selection(nil, survivingFoldOf: [selected]) == nil)
    }

    // MARK: - The keyboard reads the same list

    /// A source gate, for the reason `DefaultActionTests` is one: `stepCard` and
    /// `stepColumn` are `private` inside a `View`, `swift test` cannot press a
    /// key, and CLAUDE.md records that on this machine an agent's shell is
    /// refused both `osascript` and `screencapture`. So the behaviour cannot be
    /// driven from here — but the *shape* can be read, and the shape is exactly
    /// what went wrong: a second answer to "what is in this column".
    ///
    /// Reverting either call to `model.cards(in:)` leaves every test above green
    /// and puts the defect back. This is what fails instead.
    @Test("The arrow keys walk the drawn list, never the column's own cards")
    func keyboardWalksWhatIsDrawn() throws {
        let source = try Self.boardSource()

        for name in ["stepCard", "stepColumn"] {
            let body = try #require(
                Self.body(ofFunction: name, in: source), "\(name) is no longer in BoardView.swift")
            #expect(
                body.contains("drawnCards(in:"),
                "\(name) must walk what the column draws")
            #expect(
                !body.contains("model.cards(in:"),
                "\(name) is reading the column's cards again — that is #278 restored")
        }
    }

    /// The other half of the same gap, and the one no pure function can close:
    /// that the two headings actually *call* the rule, and that neither of them
    /// reads a fold set behind its back.
    ///
    /// Reading `collapsedRepos.contains(…)` or `isDayCollapsed(…)` here is the
    /// subtler defect of the two. A heading the reader folded is drawn open
    /// while it holds the selection, so at that one heading the set and the
    /// screen disagree — a toggle written against the set folds on a press meant
    /// to unfold, and the chevron runs backwards.
    @Test("Both headings fold through the one rule, and neither reads the fold set")
    func headingsFoldThroughOneRule() throws {
        let source = try Self.boardSource()

        for name in ["groupHeader", "dayHeader"] {
            let body = try #require(
                Self.body(ofFunction: name, in: source), "\(name) is no longer in BoardView.swift")
            #expect(
                body.contains("fold(away:"),
                "\(name) must give up a selection it folds away")
            #expect(
                !body.contains("collapsedRepos.contains") && !body.contains("isDayCollapsed"),
                "\(name) is reading the fold set rather than what it is drawing")
        }

        // And that the one rule is actually applied. Checking only the two call
        // sites was the first version of this gate, and it was worthless:
        // emptying `fold(away:_:)` left every test green a second time, because
        // both headings still *called* a function that now did nothing.
        let fold = try #require(
            Self.body(ofFunction: "fold", in: source), "fold(away:_:) is no longer in BoardView.swift")
        #expect(
            fold.contains("ColumnRows.selection("),
            "fold(away:_:) no longer gives up the selection it folds away")
    }

    private static func boardSource() throws -> String {
        let board = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // ElliotAppKitTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // ElliotKit
            .appendingPathComponent("Sources/ElliotAppKit/BoardView.swift")
        return try String(contentsOf: board, encoding: .utf8)
    }

    /// A function's body, by brace matching from its `func` line.
    ///
    /// Deliberately not a line range or a marker: both move when the file is
    /// reordered, and a gate that silently matches nothing is the failure mode
    /// this whole suite is about. `#require` above turns "not found" into a
    /// named failure rather than a pass.
    private static func body(ofFunction name: String, in source: String) -> String? {
        guard let start = source.range(of: "func \(name)(") else { return nil }
        var depth = 0
        var seenBrace = false
        var body = ""
        for character in source[start.upperBound...] {
            if character == "{" {
                depth += 1
                seenBrace = true
            } else if character == "}" {
                depth -= 1
                if seenBrace && depth == 0 { return body }
            }
            if seenBrace { body.append(character) }
        }
        return nil
    }
}
