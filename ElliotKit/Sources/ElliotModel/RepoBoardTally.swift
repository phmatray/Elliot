import Foundation

/// What is on the board for one repository, as of one pass.
///
/// One value rather than three fields on `RepoRow`, because the three arrive
/// together or not at all: a row that showed cards but not runs would be
/// describing two different moments, and the page's whole job is to be one
/// answer taken at one time.
///
/// Its **optionality** on `RepoRow` is the rule, not a rendering condition.
/// `nil` means *this is not a row Elliot drives, so there are no figures*;
/// `.some` means *these are the figures, and a zero here is a measured zero*.
/// Rendering `0` on every row would say "nothing on the board" about a fork
/// that has never had a board — the shape `.unlisted` and `.notChecked` exist
/// to refuse one verdict up.
public struct RepoBoardTally: Codable, Sendable, Hashable {
    public var cards: Int
    public var runsInFlight: Int
    public var spendToday: Spend
    /// Why this repository's cards may be stale — `gh`'s own words, the string
    /// the board's banner shows. Session state, not the store's, which is why
    /// it is written in by the digest rather than read from the database with
    /// the rest: `ImportSessionState` lives on `AppModel` so a failure outlives
    /// `status`, and nothing persists it.
    public var refreshFailure: String?

    public init(
        cards: Int, runsInFlight: Int, spendToday: Spend, refreshFailure: String? = nil
    ) {
        self.cards = cards
        self.runsInFlight = runsInFlight
        self.spendToday = spendToday
        self.refreshFailure = refreshFailure
    }

    /// A repository Elliot drives that has nothing on its board yet.
    ///
    /// Not the same value as `nil`, and the difference is the point: the store's
    /// `GROUP BY` returns no row at all for a repository with no cards, and the
    /// digest turns that absence into this. "None" and "not ours" are different
    /// answers before they are different pixels.
    public static let empty = RepoBoardTally(cards: 0, runsInFlight: 0, spendToday: .nothing)
}

/// Attaches board figures to the rows entitled to them, and to no others.
///
/// A second pass over `RepoReconciler.rows`, never a fourth argument to it: the
/// reconciler answers "where does this repository belong and is it there", it
/// is called before the git probe, and folding a SQLite aggregate into that
/// pass would put it on the same critical path as the `gh repo list` fan-out
/// for no reason. It also could not carry the refresh failure, which is not the
/// store's to give — so the failure would need a second pass regardless, and
/// the entitlement rule would end up written in two places.
public enum RepoBoardDigest {

    /// Total, and independent of what it is handed: a row that is not entitled
    /// comes back with `board == nil` **whatever the dictionaries hold**, and an
    /// entitled one comes back with `.empty` rather than `nil` when the store
    /// never mentioned it. Those two sentences are criteria 4 and 3.
    ///
    /// `refreshFailure` is written in from `failures` afterwards rather than
    /// being looked up only for repositories the store returned, so a failure
    /// recorded for a repository with nothing on its board still reaches its
    /// row. `no cards` beside *"could not be refreshed"* is not a
    /// contradiction; it is the two facts the page owes the reader.
    public static func decorate(
        _ rows: [RepoRow],
        tallies: [UUID: RepoBoardTally],
        failures: [UUID: String]
    ) -> [RepoRow] {
        rows.map { row in
            var decorated = row
            guard row.showsBoardFigures, let repoID = row.repoID else {
                decorated.board = nil
                return decorated
            }
            var tally = tallies[repoID] ?? .empty
            // Assigned rather than merged, so a failure that has since cleared
            // leaves no mark: this is the read that must agree with the board's
            // banner, and the banner shows what `importSession` holds *now*.
            tally.refreshFailure = failures[repoID]
            decorated.board = tally
            return decorated
        }
    }
}
