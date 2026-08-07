import ElliotModel
import ElliotProcess
import Foundation
import TestSupport
import Testing

@testable import ElliotEngine

/// Preflight's checks, and the fixes they may now carry.
///
/// Until #170 a `CheckResult` could only *describe* a remedy, in `fixHint`
/// prose, while the Repositories page had had actionable rows since #12
/// (`RepoFix` + `RepoRegistryService.apply`). Two screens, the same question —
/// *here is what is wrong, fix it* — and two different answers, only one of
/// which worked. These pin the mechanism that closes that, and the labels check
/// that is its first user.
@Suite("Preflight")
struct PreflightTests {

    // MARK: - The mechanism

    @Test("A check carries no fix unless it was given one")
    func fixesDefaultToNone() {
        // Every check that existed before #170 is constructed without this
        // argument, so the default decides whether the whole screen suddenly
        // grows buttons. It must not.
        let plain = CheckResult(
            id: "tool.git", title: "git", status: .pass, detail: "found"
        )
        #expect(plain.fixes.isEmpty)
    }

    @Test("Every check the service already produced still carries none")
    func existingChecksAreUnchanged() {
        // Asserted against a real check the service builds rather than one the
        // test made up: a default that only holds for hand-built values would
        // miss a construction site that started passing something.
        let root = PreflightService.repositoriesRootCheck(.portfolio)
        #expect(root.fixes.isEmpty)
    }

    @Test("A fix's label is the button's text, and names what it will do")
    func fixLabelsReadAsButtons() {
        let repoID = UUID()
        let create = CheckFix.createLabels(
            repoID: repoID,
            labels: [RequiredLabel(name: "bug", color: "d73a4a", description: "x")]
        )
        let seed = CheckFix.seedCard(
            repoID: repoID,
            title: "Decide a label taxonomy",
            story: UserStory(role: "maintainer", want: "a taxonomy", benefit: "labelled issues")
        )

        #expect(!create.label.isEmpty)
        #expect(!seed.label.isEmpty)
        // Two fixes on one row must not read the same, or the reader cannot tell
        // the instant one from the one that files work.
        #expect(create.label != seed.label)
        // The deterministic one says how many it will make, because "Create
        // labels" on a row that lists four of them is a button whose blast
        // radius is guesswork.
        #expect(create.label.contains("1"))
    }

    @Test("Fixes are identifiable and hashable, so a view can list them")
    func fixesAreListable() {
        let repoID = UUID()
        let a = CheckFix.createLabels(repoID: repoID, labels: [])
        let b = CheckFix.seedCard(
            repoID: repoID, title: "t",
            story: UserStory(role: "r", want: "w", benefit: "b")
        )
        #expect(a.id != b.id)
        #expect(Set([a, b]).count == 2)

        // And a `CheckResult` carrying them still hashes — the type is `Hashable`
        // and SwiftUI leans on that for the row's identity.
        let result = CheckResult(
            id: "repo.labels", title: "Labels", status: .warn, detail: "d", fixes: [a, b]
        )
        #expect(Set([result]).count == 1)
        #expect(result.fixes.count == 2)
    }
}
