import Foundation
import Testing

@testable import ElliotProcess

/// A captured payload is only a contract while the capture and the request name
/// the same fields. A field the client stops asking for arrives as `nil`, which
/// decodes perfectly — and `isCode` would then read `false` for the entire
/// portfolio, putting three axes out of scope everywhere with no error anywhere.
@Suite("The repo-list field set is pinned")
struct GHClientFieldsTests {

    @Test("Every field the standards subsystem depends on is requested")
    func requiredFieldsArePresent() {
        for field in ["nameWithOwner", "visibility", "defaultBranchRef", "isFork",
                      "isArchived", "url", "primaryLanguage", "isEmpty"] {
            #expect(GHClient.repoListFields.contains(field), "missing \(field)")
        }
    }
}
