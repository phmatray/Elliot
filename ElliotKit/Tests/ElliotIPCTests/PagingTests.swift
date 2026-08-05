import ElliotModel
import Foundation
import Testing

@testable import ElliotIPC

private func cardDTO(_ title: String = "Run log") -> CardDTO {
    CardDTO(id: UUID(), title: title, column: "backlog", repo: "phmatray/Elliot")
}

@Suite("Paging")
struct PagingTests {

    @Test("A limit of nothing means the default, not none")
    func nonPositiveLimitFallsBackToTheDefault() {
        #expect(ElliotPaging.clamp(0, default: 100, max: 500) == (100, nil))
        #expect(ElliotPaging.clamp(-1, default: 100, max: 500) == (100, nil))
    }

    @Test("A limit over the cap is clamped, and says what was asked for")
    func capIsReported() {
        #expect(ElliotPaging.clamp(50, default: 100, max: 500) == (50, nil))
        #expect(ElliotPaging.clamp(500, default: 100, max: 500) == (500, nil))
        #expect(ElliotPaging.clamp(900, default: 100, max: 500) == (500, 900))
    }

    @Test("A page cannot be built without saying whether it was cut")
    func truncationIsDerived() {
        // Derived at construction rather than passed in: a short list with no
        // count is indistinguishable from a complete one, and this is the only
        // way no producer can forget.
        #expect(!CardPage(cards: [cardDTO()], total: 1, limit: 100).truncated)
        #expect(CardPage(cards: [cardDTO()], total: 340, limit: 1).truncated)
        #expect(!RunPage(runs: [], total: 0, limit: 20).truncated)
        #expect(NextPage(items: [], total: 3, limit: 0, readyCount: 1).truncated)
    }

    @Test("readyCount counts every candidate, not just the rows returned")
    func readyCountSpansAllCandidates() {
        let page = NextPage(items: [], total: 12, limit: 10, readyCount: 4)
        #expect(page.readyCount == 4)
        #expect(page.total == 12)
    }

    @Test("Only awaitRun is allowed to be slow, and the socket outlives its window")
    func awaitOutlivesTheServerWindow() {
        // Get these backwards and the client hangs up on an answer already on
        // its way, which the caller reads as a dead app.
        #expect(ElliotRequest.listCards(repo: nil, column: nil, limit: 10).socketTimeout
            == ElliotTimeouts.request)

        let requested = 60
        let awaiting = ElliotRequest.awaitRun(id: UUID(), timeoutSeconds: requested)
        #expect(awaiting.socketTimeout > Double(requested))

        // Asking for more than the ceiling is clamped, not refused — and the
        // socket is still sized off the clamped number.
        let greedy = ElliotRequest.awaitRun(id: UUID(), timeoutSeconds: 9_999)
        #expect(greedy.socketTimeout
            == Double(ElliotTimeouts.awaitMaxSeconds) + ElliotTimeouts.awaitGrace)
        #expect(ElliotTimeouts.clampAwaitSeconds(0) == ElliotTimeouts.awaitDefaultSeconds)
    }
}
