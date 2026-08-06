import ElliotModel
import Foundation
import Testing

@testable import ElliotStore

@Suite("Scheduler limits — persistence")
struct SchedulerLimitsStoreTests {

    @Test("An untouched store has no limits, so the caller applies the default")
    func absentIsNil() async throws {
        let store = try BoardStore.inMemory()
        // `nil`, not `.default`. The distinction is the whole reason this
        // returns an optional: "never chosen" and "chosen to be the default"
        // are the same behaviour today and need not stay that way.
        #expect(try await store.limits() == nil)
    }

    @Test("Limits round-trip through the store")
    func roundTrip() async throws {
        let store = try BoardStore.inMemory()
        let limits = SchedulerLimits(maxConcurrent: 6, maxConcurrentAnalyses: 2)
        try await store.saveLimits(limits)
        #expect(try await store.limits() == limits)
    }

    @Test("Saving twice updates rather than failing on the key")
    func saveIsAnUpsert() async throws {
        let store = try BoardStore.inMemory()
        try await store.saveLimits(SchedulerLimits(maxConcurrent: 2, maxConcurrentAnalyses: 3))
        try await store.saveLimits(SchedulerLimits(maxConcurrent: 5, maxConcurrentAnalyses: 1))
        #expect(try await store.limits()?.maxConcurrent == 5)
        #expect(try await store.limits()?.maxConcurrentAnalyses == 1)
    }

    @Test("The limits and the layout do not share a key")
    func settingsAreIndependent() async throws {
        // Both go into the same `setting` table, and the read/write pair was
        // deduplicated into one generic helper when the limits were added. A
        // copy-paste that reused `layoutKey` would make each write erase the
        // other, and neither test alone would notice.
        let store = try BoardStore.inMemory()
        let layout = RepoTreeLayout(root: "/tmp/repos", owners: ["phmatray"])
        try await store.saveLayout(layout)
        try await store.saveLimits(SchedulerLimits(maxConcurrent: 7, maxConcurrentAnalyses: 4))

        #expect(try await store.layout() == layout)
        #expect(try await store.limits()?.maxConcurrent == 7)
    }
}
