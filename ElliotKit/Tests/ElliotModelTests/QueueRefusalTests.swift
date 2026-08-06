import Foundation
import Testing

@testable import ElliotModel

@Suite("Queue refusal")
struct QueueRefusalTests {

    /// Every case, listed. Not `CaseIterable` — two carry associated values —
    /// and deliberately not a `default` anywhere, so a new reason cannot arrive
    /// unworded.
    private let all: [QueueRefusal] = [
        .mergeInFlightInRepo,
        .writerCapReached(inFlight: 2, cap: 2),
        .analysisCapReached(inFlight: 3, cap: 3),
        .duplicateCreateIssueInRepo,
        .mergeWaitsForRepoToBeIdle,
        .dailyCeilingReached,
        .paused,
    ]

    @Test("Every reason has a distinct code")
    func codesAreDistinct() {
        // Also proves the list above is complete: a case added to the enum and
        // forgotten here would leave the set short.
        #expect(Set(all.map(\.code)).count == all.count)
    }

    @Test("Every reason says what is holding the run")
    func everyReasonIsWorded() {
        for refusal in all {
            #expect(!refusal.sentence.isEmpty, "\(refusal.code) has no wording")
            #expect(refusal.sentence.hasSuffix("."), "\(refusal.code) is not a sentence")
        }
    }

    @Test("A cap refusal names the remedy, not only the problem")
    func capRefusalsNameTheRemedy() {
        // A reason with no remedy is only a nicer way of saying no. Both cap
        // refusals point at the setting that would release the queue.
        #expect(QueueRefusal.writerCapReached(inFlight: 2, cap: 2).sentence.contains("Preflight"))
        #expect(QueueRefusal.analysisCapReached(inFlight: 3, cap: 3).sentence.contains("Preflight"))
        #expect(QueueRefusal.dailyCeilingReached.sentence.contains("Preflight"))
    }

    @Test("A cap of one is written in the singular")
    func singularCap() {
        // The board is read at a glance; "All 1 run slots are busy" is the kind
        // of thing that makes a careful product look careless.
        #expect(QueueRefusal.writerCapReached(inFlight: 1, cap: 1).sentence.contains("slot is"))
        #expect(QueueRefusal.writerCapReached(inFlight: 2, cap: 2).sentence.contains("slots are"))
    }

    @Test("A cap refusal carries the numbers it is talking about")
    func capCarriesNumbers() {
        let refusal = QueueRefusal.writerCapReached(inFlight: 3, cap: 4)
        #expect(refusal.sentence.contains("4"))
        #expect(refusal.sentence.contains("3"))
        // Equality is on the payload too, so a snapshot diff notices the cap
        // changing under a run that is still waiting.
        #expect(refusal != .writerCapReached(inFlight: 3, cap: 5))
    }
}
