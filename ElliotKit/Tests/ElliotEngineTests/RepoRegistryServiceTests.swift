import ElliotModel
import ElliotProcess
import ElliotStore
import Foundation
import Testing

@testable import ElliotEngine

/// The repository root, from this file's own location, so the tests use the same
/// `Scripts/` and `Fixtures/` a human would from a terminal.
private enum Paths {
    static let repoRoot: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // ElliotEngineTests
        .deletingLastPathComponent()   // Tests
        .deletingLastPathComponent()   // ElliotKit
        .deletingLastPathComponent()   // repo root

    static let fakeGH = repoRoot.appendingPathComponent("Scripts/fake-gh.sh").path

    static func fixture(_ name: String) -> String {
        repoRoot.appendingPathComponent("Fixtures/gh/\(name)").path
    }
}

/// `Scripts/fake-gh.sh` rather than a real `gh`: the suite must not reach the
/// network or need a token, and the real subprocess, the real argv and the real
/// JSON decode all stay under test.
///
/// ⚠️ This pointed at **`/usr/bin/true`** until #148, and the comment here said
/// the tests exercised an *empty* listing. They did not. `/usr/bin/true` exits 0
/// printing nothing, and nothing is not `[]` — the decode threw, `repos(owner:)`
/// threw, and every one of these tests was quietly running the **failed**-listing
/// path while claiming to run the empty one. That is the same
/// missing-answer-read-as-an-empty-one confusion this issue is about, one layer
/// down, sitting inside the test that pinned the behaviour.
///
/// `repoInfo` is still unanswerable — the fake exits 64 for `repo view` — so the
/// registration tests keep falling back to what the path itself says, which is
/// the branch they exercise. The difference is that an unexpected call now fails
/// loudly instead of returning something that decodes to nothing.
private func testConfig(_ environment: [String: String] = [:]) -> ToolConfig {
    ToolConfig(
        claudePath: "/usr/bin/true", ghPath: Paths.fakeGH, gitPath: "/usr/bin/true",
        environment: environment.merging(["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]) { a, _ in a }
    )
}

private func makeTree() -> String {
    FileManager.default.temporaryDirectory.appendingPathComponent("tree-\(UUID().uuidString)").path
}

private func makeClone(_ path: String) throws {
    try FileManager.default.createDirectory(atPath: path + "/.git", withIntermediateDirectories: true)
}

@Suite("Repo registry service", .serialized)
struct RepoRegistryServiceTests {

    @Test("Registering writes the repo with its visibility; forgetting removes it and leaves the disk alone")
    func registerAndForget() async throws {
        let root = makeTree(), path = root + "/phmatray/private/Koine"
        try makeClone(path)
        defer { try? FileManager.default.removeItem(atPath: root) }

        let layout = RepoTreeLayout(root: root, owners: ["phmatray"])
        let store = try BoardStore.inMemory()
        let service = RepoRegistryService(store: store, config: testConfig())

        #expect(await service.apply(.register(path: path), layout: layout).succeeded)
        let saved = try await store.repo(path: path)
        #expect(saved?.visibility == .private)
        #expect(saved?.displayName == "Koine")

        #expect(await service.apply(.forget(repoID: saved!.id), layout: layout).succeeded)
        #expect(try await store.repo(path: path) == nil)
        #expect(
            FileManager.default.fileExists(atPath: path + "/.git"),
            "forget never touches the disk")
    }

    @Test("Moving relocates the clone and repoints the registration in the same step")
    func moveRepointsTheRegistration() async throws {
        let root = makeTree()
        let from = root + "/phmatray/public/Koine", to = root + "/phmatray/private/Koine"
        try makeClone(from)
        defer { try? FileManager.default.removeItem(atPath: root) }

        let layout = RepoTreeLayout(root: root, owners: ["phmatray"])
        let store = try BoardStore.inMemory()
        try await store.saveRepo(
            Repo(
                path: from, nameWithOwner: "phmatray/Koine",
                displayName: "Koine", visibility: .public))
        let service = RepoRegistryService(store: store, config: testConfig())

        #expect(await service.apply(.move(from: from, to: to), layout: layout).succeeded)
        #expect(FileManager.default.fileExists(atPath: to + "/.git"))
        #expect(try await store.repo(path: from) == nil, "the store never points at a moved-away path")
        #expect(try await store.repo(path: to)?.visibility == .private)
    }

    /// The rewrite of `rowsSurviveAnUnreachableGitHub`, and it keeps that test's
    /// first claim exactly: a clone the remote leg could not confirm must still
    /// be listed, because dropping it would read exactly like a repository that
    /// is fine.
    ///
    /// What it no longer claims is the second half. It asserted `.notRegistered`
    /// and a `Register` button on an unreachable GitHub, and that was the
    /// behaviour #148 is about — pinned, and therefore protected, by a passing
    /// test. It was pinned by accident twice over: `ghPath` was `/usr/bin/true`,
    /// whose empty stdout is a **decode failure**, not an empty listing, so the
    /// test was never describing the input its comment named.
    @Test("A clone GitHub could not be asked about still gets a row, and is offered nothing")
    func rowsSurviveAnUnreachableGitHub() async throws {
        let root = makeTree()
        let path = root + "/phmatray/private/Koine"
        try makeClone(path)
        defer { try? FileManager.default.removeItem(atPath: root) }

        let layout = RepoTreeLayout(root: root, owners: ["phmatray"])
        let store = try BoardStore.inMemory()
        let service = RepoRegistryService(
            store: store, config: testConfig(["FAKE_GH_MODE": "fail"]))

        let page = await service.rows(layout: layout)
        #expect(page.rows.count == 1)
        #expect(page.rows.first?.nameWithOwner == "phmatray/Koine")
        #expect(page.rows.first?.issue == .notChecked)
        #expect(
            page.rows.first?.fixes.isEmpty == true,
            "Register asks `gh repo view` for the default branch — during this outage it would guess")

        // Criterion 1: the owner and the error, not merely the absence of rows.
        #expect(page.listingFailures.map(\.owner) == ["phmatray"])
        #expect(page.listingFailures.first?.reason.isEmpty == false)
    }

    /// The control the suite did not have, and could not have had while `ghPath`
    /// was `/usr/bin/true`: GitHub answered, and answered with nothing. That is
    /// the one input `Register` is grounded in, and it is unchanged.
    @Test("A listing that arrived empty still offers registration, and reports no failure")
    func anEmptyListingIsNotAFailedOne() async throws {
        let root = makeTree()
        let path = root + "/phmatray/private/Koine"
        try makeClone(path)
        defer { try? FileManager.default.removeItem(atPath: root) }

        let layout = RepoTreeLayout(root: root, owners: ["phmatray"])
        let store = try BoardStore.inMemory()
        let service = RepoRegistryService(store: store, config: testConfig())

        let page = await service.rows(layout: layout)
        #expect(page.rows.count == 1)
        #expect(page.rows.first?.issue == .notRegistered)
        #expect(page.rows.first?.fixes == [.register(path: path)])
        #expect(page.listingFailures.isEmpty)
    }

    /// Criterion 5, and the reason `FAKE_GH_FAIL_OWNER` exists: `rows` shares one
    /// `GHClient` across its fan-out, so a blanket `FAKE_GH_MODE=fail` can only
    /// show that *everything* failed. The claim worth testing is that one owner's
    /// rate limit costs that owner's verdicts and nothing else.
    @Test("One owner's failed listing leaves the other owner's rows and fixes intact")
    func aFailedOwnerDoesNotCostAHealthyOne() async throws {
        let root = makeTree()
        try makeClone(root + "/phmatray/private/Koine")
        try makeClone(root + "/Atypical-Consulting/private/alpha")
        defer { try? FileManager.default.removeItem(atPath: root) }

        let layout = RepoTreeLayout(root: root, owners: ["phmatray", "Atypical-Consulting"])
        let store = try BoardStore.inMemory()
        let service = RepoRegistryService(
            store: store,
            config: testConfig([
                "FAKE_GH_REPOS": Paths.fixture("repos-phmatray.json"),
                "FAKE_GH_FAIL_OWNER": "Atypical-Consulting",
            ]))

        let page = await service.rows(layout: layout)
        #expect(page.listingFailures.map(\.owner) == ["Atypical-Consulting"])

        // The healthy owner: GitHub answered about it, so the row and its button
        // are exactly what they would be with nothing wrong anywhere.
        let healthy = page.rows.first { $0.id == "phmatray/Koine" }
        #expect(healthy?.issue == .notRegistered)
        #expect(healthy?.fixes == [.register(path: root + "/phmatray/private/Koine")])

        // The failed one: on disk, and nothing known about it.
        let unchecked = page.rows.first { $0.id == "Atypical-Consulting/alpha" }
        #expect(unchecked?.issue == .notChecked)
        #expect(unchecked?.fixes.isEmpty == true)
        #expect(unchecked?.detail.contains("Atypical-Consulting") == true)
    }

    @Test("A failing fix reports its reason and changes nothing")
    func failureIsPerRow() async throws {
        let store = try BoardStore.inMemory()
        let service = RepoRegistryService(store: store, config: testConfig())
        let outcome = await service.apply(
            .register(path: "/nope/\(UUID().uuidString)"), layout: .portfolio)
        #expect(!outcome.succeeded)
        #expect(!outcome.detail.isEmpty)
        #expect(try await store.repos().isEmpty)
    }
}
