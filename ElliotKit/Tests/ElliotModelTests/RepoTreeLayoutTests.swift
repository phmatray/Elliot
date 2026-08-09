import Foundation
import Testing

@testable import ElliotModel

@Suite("Repo tree layout")
struct RepoTreeLayoutTests {
    let layout = RepoTreeLayout(root: "/Users/p/Repositories", owners: ["phmatray", "Atypical-Consulting"])

    @Test("An expected path is owner, then visibility, then bare name")
    func expectedPath() {
        #expect(
            layout.expectedPath(nameWithOwner: "phmatray/Koine", visibility: .private)
                == "/Users/p/Repositories/phmatray/private/Koine")
        #expect(
            layout.expectedPath(nameWithOwner: "Atypical-Consulting/og-engine", visibility: .public)
                == "/Users/p/Repositories/Atypical-Consulting/public/og-engine")
    }

    @Test("An unconfigured owner, or a name without one, has no expected path")
    func unknownOwner() {
        #expect(layout.expectedPath(nameWithOwner: "torvalds/linux", visibility: .public) == nil)
        #expect(layout.expectedPath(nameWithOwner: "no-slash", visibility: .public) == nil)
    }

    @Test("A path parses back into its slot")
    func slotRoundTrip() {
        #expect(
            layout.slot(forPath: "/Users/p/Repositories/phmatray/private/Koine")
                == RepoSlot(owner: "phmatray", visibility: .private, name: "Koine"))
    }

    @Test("Everything outside owner/visibility/name is out of scope, not misplaced")
    func outOfScope() {
        for path in [
            "/Users/p/Repositories/_worktrees/Elliot",
            "/Users/p/Repositories/_local-only/Yendor",
            "/Users/p/Repositories/customers/netimpex/api",
            "/Users/p/Repositories/repo-audit",
            "/Users/p/Repositories/phmatray/Koine",  // no visibility folder
            "/Users/p/Repositories/phmatray/archived/Koine",  // not a visibility folder
            "/Users/p/Repositories/phmatray/private/Koine/nested",  // too deep
            "/elsewhere/phmatray/private/Koine",  // outside the root
        ] {
            #expect(layout.slot(forPath: path) == nil, "\(path) must not parse")
        }
    }

    @Test("A trailing slash on the root does not change the answer")
    func rootNormalisation() {
        let slashed = RepoTreeLayout(root: "/Users/p/Repositories/", owners: ["phmatray"])
        #expect(
            slashed.slot(forPath: "/Users/p/Repositories/phmatray/public/lenia")
                == RepoSlot(owner: "phmatray", visibility: .public, name: "lenia"))
    }

    @Test("gh's INTERNAL visibility is filed as private")
    func internalIsPrivate() {
        #expect(RepoVisibility(ghVisibility: "PUBLIC") == .public)
        #expect(RepoVisibility(ghVisibility: "INTERNAL") == .private)
        #expect(RepoVisibility(ghVisibility: "PRIVATE") == .private)
    }

    // MARK: - One owner, once (#191)

    /// The writer-side guarantee every reader now leans on.
    ///
    /// `RepoRegistryService` fans out one task per element, so a duplicate made
    /// the same `gh repo list` call twice and, on failure, produced two banner
    /// rows carrying **one id** — undefined in SwiftUI — under a sentence that
    /// counted attempts while saying "owners".
    @Test("A duplicated owner is collapsed, and the first occurrence keeps its place")
    func duplicateOwnersCollapse() {
        let layout = RepoTreeLayout(
            root: "/Users/p/Repositories",
            owners: ["phmatray", "Atypical-Consulting", "phmatray"])

        #expect(layout.owners == ["phmatray", "Atypical-Consulting"])
        // Order is not incidental: the banner reads top to bottom and
        // `ownerDirectories()` is enumerated in this order.
        #expect(layout.ownerDirectories().count == 4)
    }

    /// Exact, and the same rule the three readers use. GitHub handles are
    /// case-insensitive and that argues the other way; it loses because `owners`
    /// names **directories**, and APFS can be formatted case-sensitive — where
    /// a merged pair would resolve to a path that does not exist.
    @Test("Two spellings of one handle stay two owners, because they are two directories")
    func casingIsNotMerged() {
        let layout = RepoTreeLayout(root: "/Users/p/Repositories", owners: ["phmatray", "PhMatray"])
        #expect(layout.owners == ["phmatray", "PhMatray"])
        // The readers agree, which is the property that matters more than the
        // choice itself: a writer that merged these while `slot(forPath:)` kept
        // them apart is the writer/reader split #191 exists to close.
        #expect(layout.slot(forPath: "/Users/p/Repositories/PhMatray/public/x")?.owner == "PhMatray")
        #expect(layout.expectedPath(nameWithOwner: "PhMatray/x", visibility: .public) != nil)
    }

    /// ⚠️ Decoding is the path that carries a **legacy** duplicate — one stored
    /// before the rule existed. A value read back must normalise exactly like
    /// one built in code, and it must not throw at a reader who did nothing.
    @Test("A stored layout holding a duplicate decodes to a deduplicated value")
    func decodingDeduplicates() throws {
        let stored = #"{"root":"/Users/p/Repositories","owners":["phmatray","phmatray"]}"#
        let decoded = try JSONDecoder().decode(RepoTreeLayout.self, from: Data(stored.utf8))

        #expect(decoded.owners == ["phmatray"])
        // And the root goes through the same normalisation on the way in, which
        // is the other half of "decoding is a second construction path".
        #expect(decoded.root == "/Users/p/Repositories")
    }

    @Test("A layout round-trips through Codable unchanged")
    func roundTrips() throws {
        let encoded = try JSONEncoder().encode(layout)
        #expect(try JSONDecoder().decode(RepoTreeLayout.self, from: encoded) == layout)
    }
}
