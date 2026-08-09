import ElliotModel
import ElliotProcess
import ElliotStore
import Foundation

/// What `gh` established about a pull request, resolved against the clock and —
/// when it matters — against the pull request's real head.
///
/// **One implementation, two callers**: `BoardService`, which may be about to
/// merge, and `MCPRequestHandler.prStatusDTO`, which is drawing a picture. Both
/// live in `ElliotEngine`, so the reason `OfflineResponder` keeps its own copy —
/// `ElliotMCPKit` imports neither this target nor `ElliotProcess`, so the helper
/// can hold no copy of the rules — does not apply *between these two*. A third
/// hand-written `resolved(now: Date(), currentHeadOid: nil)` inside one module
/// would be a rule written twice for no reason at all.
///
/// **The one difference that is real stays a parameter.** `resolved` treats a
/// `nil` head as "the sha rule is off", which leaves `PRStatus.maximumAge` — 600
/// seconds — as the only protection, while `PRWatcher` backs off to ~300 s ± 20
/// %. For a picture that is fine and cheap. For a merge it is not: the reading
/// may be about a commit nobody is reviewing any more.
public actor PRVerdictReader {

    /// What to do about the pull request's current head.
    public enum HeadPolicy: Sendable {
        /// Ask `gh`, and answer nothing at all if it cannot be asked.
        ///
        /// The policy for anything that may merge. Failing closed matters more
        /// than failing usefully here: a head we could not read cannot prove the
        /// stored reading is about the commit under review, and "I could not
        /// look" rendered as "nothing to report" is the shape of every false
        /// green this repository has written down.
        case establish
        /// Do not go to the network; let the age rule stand alone.
        ///
        /// A read that draws a card must not spend a `gh pr list` per card, and
        /// `PRWatcher` already re-reads whenever the head moves. This is exactly
        /// what `prStatusDTO` did by hand, and what `OfflineResponder` — which
        /// can reach neither `gh` nor the network — does one target over, which
        /// is what keeps `OfflineParityTests` comparing like with like.
        case ageAlone
    }

    /// The stored row and its resolution, together.
    ///
    /// Both, because `PRStatusDTO(_:resolved:)` needs both and reading the row
    /// twice for one answer is how two callers come to disagree about which
    /// row they meant.
    public struct Reading: Sendable, Hashable {
        public var status: PRStatus
        public var resolved: ResolvedPRStatus

        public init(status: PRStatus, resolved: ResolvedPRStatus) {
            self.status = status
            self.resolved = resolved
        }
    }

    private struct Listing {
        var headsByNumber: [Int: String]
        var readAt: Date
    }

    /// How long one `gh pr list` answer is reused across the cards of a
    /// repository.
    ///
    /// Strictly under `PRStatus.refreshInterval` (300 s), for the same reason
    /// that one is strictly under `maximumAge` (600 s): the cheap rule must
    /// never be the one that decides. A page of cards costs one listing;
    /// a merge taken thirty seconds later costs another.
    public static let listingTTL: TimeInterval = 30

    private let store: BoardStore
    private let gh: GHClient?
    private var listings: [UUID: Listing] = [:]

    /// `gh` is optional because a headless construction genuinely has none — the
    /// same shape, and the same reason, as `MCPRequestHandler.capture`. With
    /// none, `.establish` answers nothing, which refuses a merge rather than
    /// granting one.
    public init(store: BoardStore, gh: GHClient?) {
        self.store = store
        self.gh = gh
    }

    /// - Throws: whatever the store throws. Deliberately **not** `try?`: a
    ///   database that cannot be read is not a pull request with nothing on it,
    ///   and `prStatusDTO` propagated that difference before this reader
    ///   existed. The only failure answered with `nil` is `gh` being
    ///   unreachable, below, and only under `.establish`.
    public func reading(
        repo: Repo, prNumber: Int, now: Date, head policy: HeadPolicy
    ) async throws -> Reading? {
        guard let status = try await store.prStatus(repoID: repo.id, prNumber: prNumber)
        else { return nil }

        switch policy {
        case .ageAlone:
            return Reading(status: status, resolved: status.resolved(now: now, currentHeadOid: nil))
        case .establish:
            guard let head = await currentHead(repo: repo, prNumber: prNumber, now: now)
            else { return nil }
            return Reading(status: status, resolved: status.resolved(now: now, currentHeadOid: head))
        }
    }

    /// The head as of the `gh pr list` `PRWatcher` already performs — the same
    /// listing, the same fields, and `headRefOid` riding along on it as a cheap
    /// scalar rather than a call per pull request.
    private func currentHead(repo: Repo, prNumber: Int, now: Date) async -> String? {
        if let cached = listings[repo.id],
           now.timeIntervalSince(cached.readAt) < Self.listingTTL {
            return cached.headsByNumber[prNumber]
        }
        guard let gh, let prs = try? await gh.pullRequests(repo: repo.nameWithOwner) else {
            // Not cached: a failure must not be remembered as an answer.
            return nil
        }
        var heads: [Int: String] = [:]
        for pr in prs where pr.headRefOid != nil {
            heads[pr.number] = pr.headRefOid
        }
        listings[repo.id] = Listing(headsByNumber: heads, readAt: now)
        return heads[prNumber]
    }
}
