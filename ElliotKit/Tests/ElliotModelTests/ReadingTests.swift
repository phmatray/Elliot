import Foundation
import Testing

@testable import ElliotModel

private let then = Date(timeIntervalSince1970: 1_700_000_000)
private let probe = Provenance(command: "gh repo list phmatray", observedAt: then)

@Suite("An observation carries why it is missing")
struct ReadingTests {

    @Test("A fresh observation yields its value")
    func freshYieldsValue() {
        let o = Reading<Int>.observed(7, probe)
        #expect((try? o.value(freshAt: then.addingTimeInterval(60), policy: .default).get()) == Optional(7))
    }

    /// The whole point of the type. A tool that cannot say "I do not know" says
    /// "0 missing" instead.
    @Test("An unavailable observation yields its reason, never a default")
    func unavailableYieldsReason() {
        let o = Reading<Int>.unavailable(.rateLimited, probe)
        guard case .failure(.rateLimited) = o.value(freshAt: then, policy: .default) else {
            Issue.record("expected .rateLimited"); return
        }
    }

    @Test("An observation older than the policy is stale, not fresh")
    func staleBeyondPolicy() {
        let o = Reading<Int>.observed(7, probe)
        let now = then.addingTimeInterval(25 * 3600)
        guard case .failure(.stale(let age)) = o.value(freshAt: now, policy: .default) else {
            Issue.record("expected .stale"); return
        }
        #expect(age == 25 * 3600)
    }

    @Test("Exactly at the boundary is still fresh")
    func boundaryIsFresh() {
        let o = Reading<Int>.observed(7, probe)
        let now = then.addingTimeInterval(24 * 3600)
        #expect((try? o.value(freshAt: now, policy: .default).get()) == Optional(7))
    }

    /// Both branches carry it: knowing *when* a failure happened is what lets a
    /// caller tell "the token expired an hour ago" from "it expired in July".
    @Test("Provenance survives on the failure branch too")
    func failureKeepsProvenance() {
        let o = Reading<Int>.unavailable(.notPermitted, probe)
        #expect(o.provenance.command == "gh repo list phmatray")
        #expect(o.provenance.observedAt == then)
    }
}
