import Foundation
import Testing

@testable import ElliotModel

private func gh(_ nameWithOwner: String) -> GHRepoSummary {
    GHRepoSummary(nameWithOwner: nameWithOwner, visibility: "PRIVATE")
}

/// What one pass over the owners produced, and — the half that did not exist —
/// which of them never answered.
///
/// The sibling of `RepoScanTests`' claim one layer down: an empty answer and a
/// missing one are different inputs, and a value that cannot tell them apart
/// makes every reader of it guess.
@Suite("GitHub listing")
struct GitHubListingTests {

    @Test("A failed owner is named; the owner beside it is not")
    func failureIsPerOwner() {
        let listing = GitHubListing(
            repos: [gh("Atypical-Consulting/alpha")],
            failures: [OwnerListingFailure(owner: "phmatray", reason: "gh exited 1: no network")])
        #expect(listing.listingFailed(for: "phmatray"))
        #expect(!listing.listingFailed(for: "Atypical-Consulting"))
    }

    /// The default that makes "nothing went wrong" writable, and the reason
    /// `RepoReconciler.rows` refuses the same default: constructing a listing
    /// with no failures is a legitimate statement, passing one by omission is not.
    @Test("A listing built without failures reports none, for any owner")
    func noFailuresIsTheDefault() {
        let listing = GitHubListing(repos: [gh("phmatray/Koine")])
        #expect(!listing.listingFailed(for: "phmatray"))
        #expect(!listing.listingFailed(for: "Atypical-Consulting"))
        #expect(listing.failures.isEmpty)
    }

    /// An owner that failed is *not* an owner with no repositories: the second
    /// is what the discarded `try? … ?? []` used to say, and the whole defect.
    @Test("A failed owner is not the same value as an owner with nothing")
    func failureIsNotEmptiness() {
        let failed = GitHubListing(
            repos: [], failures: [OwnerListingFailure(owner: "phmatray", reason: "gh exited 1")])
        let empty = GitHubListing(repos: [])
        #expect(failed != empty)
    }
}
