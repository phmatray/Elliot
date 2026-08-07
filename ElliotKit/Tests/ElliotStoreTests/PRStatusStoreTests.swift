import ElliotModel
import Foundation
import Testing

@testable import ElliotStore

private let readAt = Date(timeIntervalSince1970: 1_700_000_000)

private func makeRepo() -> Repo {
    Repo(path: "/tmp/repo-\(UUID().uuidString)", nameWithOwner: "phmatray/Elliot", displayName: "Elliot")
}

private func makeStatus(
    repoID: UUID,
    prNumber: Int = 52,
    headRefOid: String = "a1b2c3",
    mergeStateStatus: String = "CLEAN",
    checks: [GHMergeStatus.StatusCheck] = [
        GHMergeStatus.StatusCheck(name: "build", conclusion: "SUCCESS", status: "COMPLETED"),
    ]
) -> PRStatus {
    PRStatus(
        repoID: repoID,
        prNumber: prNumber,
        headRefOid: headRefOid,
        checkedAt: readAt,
        rawMergeStateStatus: mergeStateStatus,
        rawMergeable: "MERGEABLE",
        rawReviewDecision: "",
        checks: checks
    )
}

@Suite("PR status store")
struct PRStatusStoreTests {

    @Test("A status round-trips, checks included")
    func roundTrip() async throws {
        let store = try BoardStore.inMemory()
        let repo = makeRepo()
        try await store.saveRepo(repo)

        let status = makeStatus(repoID: repo.id, checks: [
            GHMergeStatus.StatusCheck(name: "build", conclusion: "SUCCESS", status: "COMPLETED"),
            GHMergeStatus.StatusCheck(context: "ci/legacy", state: "PENDING"),
        ])
        try await store.savePRStatus(status)

        let loaded = try await store.prStatus(repoID: repo.id, prNumber: 52)
        #expect(loaded == status)
        // The array is a JSON column; losing it would leave the CI facet
        // permanently reading `.noChecks`, which is a *worse* lie than nil.
        #expect(loaded?.checks.count == 2)
        #expect(loaded?.checks.last?.isPending == true)
    }

    @Test("Saving the same pull request twice replaces rather than duplicating")
    func saveIsAnUpsert() async throws {
        let store = try BoardStore.inMemory()
        let repo = makeRepo()
        try await store.saveRepo(repo)

        try await store.savePRStatus(makeStatus(repoID: repo.id, mergeStateStatus: "CLEAN"))
        try await store.savePRStatus(
            makeStatus(repoID: repo.id, headRefOid: "9999", mergeStateStatus: "DIRTY"))

        let all = try await store.prStatuses(repoID: repo.id)
        #expect(all.count == 1)
        #expect(all.first?.rawMergeStateStatus == "DIRTY")
        #expect(all.first?.headRefOid == "9999")
    }

    @Test("An unread pull request has no row, and that is nil rather than an empty verdict")
    func missingRowIsNil() async throws {
        let store = try BoardStore.inMemory()
        let repo = makeRepo()
        try await store.saveRepo(repo)
        #expect(try await store.prStatus(repoID: repo.id, prNumber: 999) == nil)
    }

    @Test("Two pull requests in one repository are kept apart")
    func rowsAreKeyedByPullRequest() async throws {
        let store = try BoardStore.inMemory()
        let repo = makeRepo()
        try await store.saveRepo(repo)

        try await store.savePRStatus(makeStatus(repoID: repo.id, prNumber: 52))
        try await store.savePRStatus(
            makeStatus(repoID: repo.id, prNumber: 53, mergeStateStatus: "DIRTY"))

        #expect(try await store.prStatuses(repoID: repo.id).count == 2)
        #expect(try await store.prStatus(repoID: repo.id, prNumber: 53)?
            .rawMergeStateStatus == "DIRTY")
    }

    @Test("The same pull request number in two repositories does not collide")
    func rowsAreKeyedByRepositoryToo() async throws {
        let store = try BoardStore.inMemory()
        let one = makeRepo(), two = makeRepo()
        try await store.saveRepo(one)
        try await store.saveRepo(two)

        try await store.savePRStatus(makeStatus(repoID: one.id, headRefOid: "aaa"))
        try await store.savePRStatus(makeStatus(repoID: two.id, headRefOid: "bbb"))

        #expect(try await store.prStatus(repoID: one.id, prNumber: 52)?.headRefOid == "aaa")
        #expect(try await store.prStatus(repoID: two.id, prNumber: 52)?.headRefOid == "bbb")
    }

    @Test("Removing a repository takes its statuses with it")
    func cascadesWithTheRepository() async throws {
        let store = try BoardStore.inMemory()
        let repo = makeRepo()
        try await store.saveRepo(repo)
        try await store.savePRStatus(makeStatus(repoID: repo.id))

        try await store.deleteRepo(id: repo.id)
        #expect(try await store.prStatuses(repoID: repo.id).isEmpty)
    }

    @Test("A raw value nobody anticipated survives the round trip as itself")
    func unknownRawValuesArePreserved() async throws {
        let store = try BoardStore.inMemory()
        let repo = makeRepo()
        try await store.saveRepo(repo)

        // The whole reason these columns are strings: a value GitHub ships
        // tomorrow must reach the reader intact, to be rendered as "not known"
        // rather than to fail a decode and take the row with it.
        try await store.savePRStatus(makeStatus(repoID: repo.id, mergeStateStatus: "SOMETHING_NEW"))
        let loaded = try await store.prStatus(repoID: repo.id, prNumber: 52)
        #expect(loaded?.rawMergeStateStatus == "SOMETHING_NEW")
        #expect(loaded?.resolved(now: readAt, currentHeadOid: "a1b2c3").merge == .unknown)
    }
}
