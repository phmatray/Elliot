import Foundation
import Testing

@testable import ElliotModel

@Suite("GH payloads")
struct GHPayloadsTests {

    private func issue(state: String?) -> GHIssue {
        GHIssue(number: 1, title: "x", url: "https://github.com/o/r/issues/1", state: state)
    }

    @Test("An issue's open state is read case-insensitively", arguments: [
        ("OPEN", true), ("open", true), ("Open", true),
        ("CLOSED", false), ("closed", false),
    ])
    func isOpenIsCaseInsensitive(state: String, expected: Bool) {
        #expect(issue(state: state).isOpen == expected)
    }

    @Test("An issue with no state at all defaults to open")
    func isOpenDefaultsWhenStateIsMissing() {
        #expect(issue(state: nil).isOpen)
    }
}
