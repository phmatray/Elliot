import Foundation
import Testing

@testable import ElliotModel

/// A dismissal, as the reader sees it — and the ordering that decides what the
/// list says.
///
/// `dismissedExternal` has carried `dismissedAt` since v5 and nothing has ever
/// read it: `BoardStore.dismissals` maps the rows down to a `Set<ExternalRef>`
/// because its one caller is the importer, which needs only the keys. These are
/// the rules for the *other* caller, the one that has to draw a list a person
/// can act on, and they are here rather than in a view because an ordering
/// decided in a `body` is a rule nothing can prove.
@Suite("Dismissed items")
struct DismissedItemTests {

    private static let repoA = UUID(uuidString: "AAAAAAAA-0000-0000-0000-000000000001")!
    private static let repoB = UUID(uuidString: "BBBBBBBB-0000-0000-0000-000000000002")!
    private static let epoch = Date(timeIntervalSince1970: 1_754_000_000)

    private static func item(
        _ kind: ExternalKind, _ number: Int, at offset: TimeInterval, in repoID: UUID = repoA
    ) -> DismissedItem {
        DismissedItem(
            repoID: repoID, ref: ExternalRef(kind: kind, number: number),
            dismissedAt: epoch.addingTimeInterval(offset))
    }

    // MARK: - 1. A number here is an identifier, not a quantity

    /// The `MergeConfirmation` trap, one screen over. `Text` takes a
    /// `LocalizedStringKey`, which group-separates an interpolated `Int` — that
    /// is how PR 1234 rendered as *"Merge PR 1.234"*. Asserted as a literal so a
    /// label built with a locale-aware formatter fails here rather than on a
    /// European machine.
    @Test("A ref's label is a plain identifier, never group-separated")
    func labelIsAnIdentifierNotAQuantity() {
        #expect(ExternalRef(kind: .issue, number: 4).label == "Issue #4")
        #expect(ExternalRef(kind: .pullRequest, number: 7).label == "PR #7")
        #expect(ExternalRef(kind: .pullRequest, number: 1234).label == "PR #1234")
        #expect(ExternalRef(kind: .issue, number: 1_000_000).label == "Issue #1000000")
    }

    /// The primary key, spelled — stable across a reload, unlike an array index,
    /// and distinct for the two rows a card carrying both an issue and a pull
    /// request writes.
    @Test("An item's id is its row's primary key, and the pair a card writes are two ids")
    func idIsThePrimaryKeySpelled() {
        let issue = Self.item(.issue, 102, at: 0)
        let pr = Self.item(.pullRequest, 102, at: 0)
        #expect(issue.id != pr.id, "same number, different kind: two rows, two ids")
        #expect(issue.id == Self.item(.issue, 102, at: 500).id, "the date is not part of the key")
        #expect(Self.item(.issue, 102, at: 0, in: Self.repoB).id != issue.id)
    }

    // MARK: - 2. Ordering

    @Test("Rows are newest first")
    func rowsAreNewestFirst() {
        let rows = DismissalDigest.rows(
            [
                Self.item(.issue, 1, at: 0),
                Self.item(.issue, 2, at: 200),
                Self.item(.issue, 3, at: 100),
            ], repoID: nil)
        #expect(rows.map(\.ref.number) == [2, 3, 1])
    }

    /// Total, not merely descending. Two numbers dismissed in the same
    /// millisecond — which one `deleteCard` writes for a card carrying both an
    /// issue and its pull request — must not shuffle between two reads of the
    /// same table.
    @Test("A tie on the date is broken by kind then number, so the order is total")
    func tiedDatesOrderByKindThenNumber() {
        let tied = [
            Self.item(.pullRequest, 5, at: 0),
            Self.item(.issue, 9, at: 0),
            Self.item(.pullRequest, 2, at: 0),
            Self.item(.issue, 2, at: 0),
        ]
        let once = DismissalDigest.rows(tied, repoID: nil)
        #expect(once.map { "\($0.ref.kind.rawValue)#\($0.ref.number)" }
            == ["issue#2", "issue#9", "pullRequest#2", "pullRequest#5"])
        #expect(DismissalDigest.rows(tied.reversed(), repoID: nil) == once,
            "the input order reached the output: the sort is not total")
    }

    @Test("A repository id filters; nil keeps every repository")
    func rowsFollowThePicker() {
        let all = [
            Self.item(.issue, 1, at: 0, in: Self.repoA),
            Self.item(.issue, 2, at: 100, in: Self.repoB),
            Self.item(.pullRequest, 3, at: 200, in: Self.repoA),
        ]
        #expect(DismissalDigest.rows(all, repoID: nil).count == 3)
        #expect(DismissalDigest.rows(all, repoID: Self.repoA).map(\.ref.number) == [3, 1])
        #expect(DismissalDigest.rows(all, repoID: Self.repoB).map(\.ref.number) == [2])
        #expect(DismissalDigest.rows(all, repoID: UUID()).isEmpty)
    }

    // MARK: - 3. Groups

    @Test("Groups carry each repository's rows in the same order the flat list would")
    func groupsPreserveTheRowOrdering() {
        let all = [
            Self.item(.issue, 1, at: 0, in: Self.repoA),
            Self.item(.issue, 2, at: 50, in: Self.repoB),
            Self.item(.pullRequest, 3, at: 200, in: Self.repoA),
            Self.item(.issue, 4, at: 10, in: Self.repoB),
        ]
        let groups = DismissalDigest.groups(all, repoID: nil)
        #expect(groups.map(\.repoID) == [Self.repoA, Self.repoB], "newest group first")
        #expect(groups[0].rows.map(\.ref.number) == [3, 1])
        #expect(groups[1].rows.map(\.ref.number) == [2, 4])
    }

    @Test("A selected repository leaves one group, and an empty set leaves none")
    func groupsFollowThePickerToo() {
        let all = [
            Self.item(.issue, 1, at: 0, in: Self.repoA),
            Self.item(.issue, 2, at: 50, in: Self.repoB),
        ]
        #expect(DismissalDigest.groups(all, repoID: Self.repoB).map(\.repoID) == [Self.repoB])
        #expect(DismissalDigest.groups([], repoID: nil).isEmpty)
        #expect(DismissalDigest.groups(all, repoID: UUID()).isEmpty)
    }

    /// The same tie-break argument one level up: two repositories whose newest
    /// dismissal shares a timestamp must not swap places between two reads.
    @Test("Groups tied on their newest row are ordered by repository id")
    func groupsTiedOnTheirNewestRowAreStillTotal() {
        let tied = [
            Self.item(.issue, 2, at: 0, in: Self.repoB),
            Self.item(.issue, 1, at: 0, in: Self.repoA),
        ]
        #expect(DismissalDigest.groups(tied, repoID: nil).map(\.repoID) == [Self.repoA, Self.repoB])
        #expect(DismissalDigest.groups(tied.reversed(), repoID: nil).map(\.repoID)
            == [Self.repoA, Self.repoB])
    }

    // MARK: - 4. The figure

    /// Absent at zero, following the queue and the sweep: a permanent
    /// "0 dismissed" is furniture, and this strip has been pushed around by its
    /// own contents before.
    @Test("The figure is absent at zero rather than reading 0 dismissed")
    func figureIsAbsentAtZero() {
        #expect(DismissalDigest.figure(count: 0) == nil)
        #expect(DismissalDigest.figure(count: -1) == nil)
        #expect(DismissalDigest.figure(count: 1) == "1 dismissed")
        #expect(DismissalDigest.figure(count: 3) == "3 dismissed")
    }

    /// A count *is* a quantity, so grouping it would not be the `MergeConfirmation`
    /// defect — but this type is pure and locale-free by contract, and a figure
    /// that reads differently in Brussels than in London is a figure two bug
    /// reports disagree about. Pinned so nobody "improves" it into a formatter.
    @Test("The figure is built without a locale, so it reads the same everywhere")
    func figureIsLocaleFree() {
        #expect(DismissalDigest.figure(count: 1234) == "1234 dismissed")
    }
}
