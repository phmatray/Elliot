import Foundation
import Testing

@testable import ElliotModel

@Suite("Scheduler limits")
struct SchedulerLimitsTests {

    @Test("The default is what shipped before the limits were configurable")
    func defaultMatchesTheOldConstants() {
        // These were `maxConcurrent: Int = 2` and `maxConcurrentAnalyses: Int = 3`
        // on `RunScheduler.init`. An existing store has no saved value, so this
        // is what it gets — the change must be invisible until someone uses it.
        #expect(SchedulerLimits.default.maxConcurrent == 2)
        #expect(SchedulerLimits.default.maxConcurrentAnalyses == 3)
    }

    @Test("A limit below one is clamped, not refused")
    func zeroClampsToOne() {
        // Refusing would leave the stored value at whatever it was while the
        // caller believed it had changed. Clamping is the honest reading of
        // "as few as possible".
        let limits = SchedulerLimits(maxConcurrent: 0, maxConcurrentAnalyses: -4)
        #expect(limits.maxConcurrent == 1)
        #expect(limits.maxConcurrentAnalyses == 1)
    }

    @Test("A limit above the ceiling is clamped")
    func aboveCeilingClamps() {
        let limits = SchedulerLimits(maxConcurrent: 9_999, maxConcurrentAnalyses: 13)
        #expect(limits.maxConcurrent == SchedulerLimits.ceiling)
        #expect(limits.maxConcurrentAnalyses == SchedulerLimits.ceiling)
    }

    @Test("A value inside the range is left alone")
    func inRangeIsUntouched() {
        let limits = SchedulerLimits(maxConcurrent: 4, maxConcurrentAnalyses: 6)
        #expect(limits.maxConcurrent == 4)
        #expect(limits.maxConcurrentAnalyses == 6)
    }

    @Test("The two limits are independent")
    func limitsDoNotBleed() {
        // Written because the UI builds a whole new value to change one field,
        // and a copy that dropped the other would be invisible in the stepper.
        let limits = SchedulerLimits(maxConcurrent: 7, maxConcurrentAnalyses: 1)
        #expect(limits.maxConcurrent == 7)
        #expect(limits.maxConcurrentAnalyses == 1)
    }

    @Test("Limits survive a round trip through JSON")
    func codableRoundTrip() throws {
        // They are persisted into the `setting` table as JSON, so this is the
        // format on disk, not an incidental conformance.
        let original = SchedulerLimits(maxConcurrent: 5, maxConcurrentAnalyses: 2)
        let data = try JSONEncoder().encode(original)
        #expect(try JSONDecoder().decode(SchedulerLimits.self, from: data) == original)
    }

    @Test("A decoded out-of-range value is clamped too")
    func decodingClamps() throws {
        // The store is a file: it can hold anything an older build, a bad merge
        // or a hand edit put there. Decoding must not be the one path that
        // bypasses the clamp — `maxConcurrent: 400` would admit 400 `claude`
        // processes.
        let data = Data(#"{"maxConcurrent":400,"maxConcurrentAnalyses":0}"#.utf8)
        let decoded = try JSONDecoder().decode(SchedulerLimits.self, from: data)
        #expect(decoded.maxConcurrent == SchedulerLimits.ceiling)
        #expect(decoded.maxConcurrentAnalyses == 1)
    }
}
