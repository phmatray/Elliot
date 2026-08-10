import ElliotModel
import ElliotProcess
import ElliotStore
import Foundation
import Testing

@testable import ElliotEngine

/// The one reader of a stored pull-request reading, and the one parameter that
/// is allowed to differ between its two callers.
///
/// `BoardService` may be about to merge to a default branch on github.com;
/// `MCPRequestHandler.prStatusDTO` is drawing a picture for an agent. Passing
/// `nil` for `currentHeadOid` turns the sha rule off and leaves
/// `PRStatus.maximumAge` — 600 s — as the only protection, while `PRWatcher`
/// backs off to ~300 s ± 20 %. That is enough for a picture and not enough for
/// a merge, so the difference is a parameter rather than two implementations.
@Suite("PR verdict reader")
struct PRVerdictReaderTests {

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

    /// The head `Fixtures/gh/prs-head-oid.json` reports for pull request 7.
    private static let liveHead = "b7c1f0aa5d2e4c9188ff0e6a2d3b4c5d6e7f8091"

    private func client(
        prs: String = "prs-head-oid.json", mode: String = "ok", argvOut: String? = nil
    ) -> GHClient {
        var environment = ["FAKE_GH_MODE": mode, "FAKE_GH_PRS": Paths.fixture(prs)]
        if let argvOut { environment["FAKE_GH_ARGV_OUT"] = argvOut }
        return GHClient(config: ToolConfig(
            claudePath: "", ghPath: Paths.fakeGH, gitPath: "", environment: environment))
    }

    /// How many `gh pr list` invocations reached the fake so far.
    ///
    /// The shape is `PRWatcherStatusTests.prViewCalls()`'s, one subcommand over:
    /// `FAKE_GH_ARGV_OUT` dumps one argument per line, so a `pr list` is the
    /// literal line "list" immediately after a line "pr". Adjacency, not a bare
    /// count of "list" — `--state` values and fixture paths are lines too.
    private func listCalls(in path: String) -> Int {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return 0 }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        return zip(lines, lines.dropFirst()).count { $0 == "pr" && $1 == "list" }
    }

    private func seeded(headRefOid: String) async throws -> (BoardStore, Repo) {
        let store = try BoardStore.inMemory()
        let repo = Repo(
            path: "/tmp/elliot-\(UUID().uuidString)",
            nameWithOwner: "phmatray/Elliot", displayName: "Elliot")
        try await store.saveRepo(repo)
        try await store.savePRStatus(PRStatus(
            repoID: repo.id, prNumber: 7, headRefOid: headRefOid, checkedAt: Date(),
            rawMergeStateStatus: "CLEAN", rawMergeable: "MERGEABLE", rawReviewDecision: "APPROVED",
            checks: [
                GHMergeStatus.StatusCheck(
                    name: "build-and-test", conclusion: "SUCCESS", status: "COMPLETED"),
            ]))
        return (store, repo)
    }

    @Test("A reading taken on the commit gh reports is fresh, and mergeable")
    func headAgreesAndTheReadingStands() async throws {
        let (store, repo) = try await seeded(headRefOid: Self.liveHead)
        let reader = PRVerdictReader(store: store, gh: client())

        // `try #require(try await …)` — the inner `try` written out, which is
        // this suite's neighbours' idiom for a throwing async call inside the
        // macro (`PRWatcherStatusTests:121`, `OfflineParityTests:95`).
        let reading = try #require(
            try await reader.reading(repo: repo, prNumber: 7, now: Date(), head: .establish))
        #expect(!reading.resolved.isStale)
        #expect(reading.resolved.isMergeableUnattended)
    }

    @Test("A reading about a commit that is no longer the head is stale under .establish")
    func movedHeadIsStale() async throws {
        // The whole reason `nil` is not good enough. The row is minutes old, so
        // the age rule says nothing at all; only the sha rule can catch it, and
        // only `.establish` asks the question.
        let (store, repo) = try await seeded(headRefOid: "0000000000000000000000000000000000000000")
        let reader = PRVerdictReader(store: store, gh: client())
        let now = Date()

        let establish = try #require(
            try await reader.reading(repo: repo, prNumber: 7, now: now, head: .establish))
        #expect(establish.resolved.isStale)
        #expect(!establish.resolved.isMergeableUnattended)

        let ageAlone = try #require(
            try await reader.reading(repo: repo, prNumber: 7, now: now, head: .ageAlone))
        #expect(!ageAlone.resolved.isStale, "the display policy must be unchanged")
    }

    @Test("A head that cannot be established refuses rather than falling back")
    func unreachableGHRefusesUnderEstablish() async throws {
        // Fail closed. Falling back to `currentHeadOid: nil` here would answer
        // "fresh and green" out of an inability to look, which is the shape of
        // every false green this repository has written down.
        let (store, repo) = try await seeded(headRefOid: Self.liveHead)
        let reader = PRVerdictReader(store: store, gh: client(mode: "fail"))

        // Resolved before the assertion rather than inside it: `#expect`'s
        // message autoclosure cannot carry an `await`, and a bare "nil was not
        // nil" says nothing about which policy produced it.
        let refused = try await reader.reading(
            repo: repo, prNumber: 7, now: Date(), head: .establish)
        #expect(refused == nil, "an unreachable gh authorised a merge")

        // …and the display policy still answers, because it never asked. It is
        // also the control on the throw: an unreachable `gh` must be a `nil`,
        // never an error, or this line would not be reached at all.
        let drawn = try await reader.reading(repo: repo, prNumber: 7, now: Date(), head: .ageAlone)
        #expect(drawn != nil, "the display policy went to the network")
    }

    @Test("A reader with no gh client at all refuses every establish")
    func noClientRefuses() async throws {
        // The headless construction — a handler built by a test, a board built
        // without one. It must not be able to authorise a merge.
        let (store, repo) = try await seeded(headRefOid: Self.liveHead)
        let reader = PRVerdictReader(store: store, gh: nil)

        let refused = try await reader.reading(
            repo: repo, prNumber: 7, now: Date(), head: .establish)
        #expect(refused == nil, "a reader with no gh authorised a merge")
    }

    @Test("One gh listing serves a window, and the next merge takes a fresh one")
    func theHeadListingIsCachedForItsWindow() async throws {
        // `listingTTL` sits on the merge path, so it is a number that decides
        // how old a head may be when a pull request is merged with nobody
        // watching — and without this it would be a constant nobody had ever
        // seen behave. The clock is injected, so nothing here sleeps and nothing
        // measures an elapsed duration.
        let argv = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("argv-\(UUID().uuidString).txt").path
        let (store, repo) = try await seeded(headRefOid: Self.liveHead)
        let reader = PRVerdictReader(store: store, gh: client(argvOut: argv))
        // Anchored on the seeded row's own moment rather than on an epoch
        // constant: all three reads then sit inside `PRStatus.maximumAge`, so a
        // staleness rule cannot quietly become the thing being measured.
        let start = Date()

        _ = try await reader.reading(repo: repo, prNumber: 7, now: start, head: .establish)
        _ = try await reader.reading(
            repo: repo, prNumber: 7,
            now: start.addingTimeInterval(PRVerdictReader.listingTTL - 1), head: .establish)
        #expect(listCalls(in: argv) == 1, "a read inside the window went to gh a second time")

        _ = try await reader.reading(
            repo: repo, prNumber: 7,
            now: start.addingTimeInterval(PRVerdictReader.listingTTL), head: .establish)
        #expect(listCalls(in: argv) == 2, "the window never expired")
    }

    @Test("A pull request with no stored reading answers nothing, under either policy")
    func noStoredRowAnswersNothing() async throws {
        let (store, repo) = try await seeded(headRefOid: Self.liveHead)
        let reader = PRVerdictReader(store: store, gh: client())

        let establish = try await reader.reading(
            repo: repo, prNumber: 99, now: Date(), head: .establish)
        let ageAlone = try await reader.reading(
            repo: repo, prNumber: 99, now: Date(), head: .ageAlone)
        #expect(establish == nil)
        #expect(ageAlone == nil)
    }
}
