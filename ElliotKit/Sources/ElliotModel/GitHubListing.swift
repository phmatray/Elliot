import Foundation

/// One owner's listing that did not arrive, and why.
///
/// The reason is kept where `RepoScan` keeps only a count, and the difference is
/// not an inconsistency: a repository row that will not decode has nothing
/// safely readable on it, so `RepoScan` can honestly say no more than "there
/// were this many". A listing that failed *does* have something readable — the
/// error `GHClient` threw, which `ProcessError.failed` already renders as
/// `"gh exited 1: <stderr>"`. That sentence is the whole of what the page owes
/// the reader, so it travels with the failure rather than being re-derived.
public struct OwnerListingFailure: Sendable, Hashable {
    public var owner: String
    public var reason: String

    public init(owner: String, reason: String) {
        self.owner = owner
        self.reason = reason
    }
}

/// What one pass over the configured owners produced: the repositories that were
/// listed, and the owners whose listing failed.
///
/// The sibling of `RepoScan(repos:unreadable:)` — same target, same reason, one
/// source across (GitHub rather than the store). Both exist because the caller
/// downstream cannot tell "nothing came back" from "nothing is there" once the
/// failure has been flattened into an empty array, and both readings are
/// plausible enough that a reader will pick one.
///
/// `failures` defaults to empty because constructing a listing with nothing
/// wrong is a legitimate thing to write. `RepoReconciler.rows` deliberately does
/// **not** default *its* listing parameter: a caller that forgot the failures
/// there would silently re-assert that everything is fine, which is the defect.
public struct GitHubListing: Sendable, Hashable {
    public var repos: [GHRepoSummary]
    public var failures: [OwnerListingFailure]

    public init(repos: [GHRepoSummary], failures: [OwnerListingFailure] = []) {
        self.repos = repos
        self.failures = failures
    }

    /// This owner's failure, if its listing is missing rather than empty.
    ///
    /// Asked per owner, not per pass: one owner's rate limit must not cost a
    /// second owner its verdicts, which is the same partial-failure rule #131
    /// established for the board.
    public func failure(for owner: String) -> OwnerListingFailure? {
        failures.first { $0.owner == owner }
    }

    /// The same question, when only the answer's existence matters. Defined in
    /// terms of `failure(for:)` rather than beside it, so "which owners failed"
    /// is decided once — two lookups written separately are two chances for a
    /// row to be excused while the banner still names it, or the reverse.
    public func listingFailed(for owner: String) -> Bool {
        failure(for: owner) != nil
    }
}
