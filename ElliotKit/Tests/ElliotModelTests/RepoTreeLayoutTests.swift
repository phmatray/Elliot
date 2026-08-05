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
}
