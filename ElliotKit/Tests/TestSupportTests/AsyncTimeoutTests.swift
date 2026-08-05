import Testing
import TestSupport

@Suite("Async timeout")
struct AsyncTimeoutTests {
    @Test("A fast operation returns its value")
    func fastOperationSucceeds() async throws {
        let value = try await withTimeout(.seconds(2)) { 42 }
        #expect(value == 42)
    }

    @Test("A slow operation throws rather than waiting forever")
    func slowOperationTimesOut() async {
        await #expect(throws: TimedOut.self) {
            try await withTimeout(.milliseconds(100)) {
                try await Task.sleep(for: .seconds(60))
                return 0
            }
        }
    }
}
