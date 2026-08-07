import Foundation
import Testing

@testable import ElliotModel

@Suite("Label policy")
struct LabelPolicyTests {
    private let policy = [
        RequiredLabel(name: "bug", color: "d73a4a", description: "Something isn't working"),
        RequiredLabel(name: "enhancement", color: "a2eeef", description: "New feature or request"),
    ]

    @Test("A repository with none of them is missing all of them")
    func nothingPresent() {
        #expect(LabelPolicy.missing(required: policy, present: []) == policy)
    }

    @Test("A repository with all of them is missing none")
    func everythingPresent() {
        #expect(
            LabelPolicy.missing(required: policy, present: ["bug", "enhancement", "wontfix"])
                .isEmpty
        )
    }

    @Test("A label that differs only in case is present, not missing")
    func caseInsensitive() {
        // GitHub compares label names case-insensitively and refuses a second
        // casing of one that exists. A policy that "created" `Bug` beside `bug`
        // would fail on every repository that already had one — and reporting it
        // as missing is a finding about a label that is right there.
        #expect(LabelPolicy.missing(required: policy, present: ["BUG", "Enhancement"]).isEmpty)
        #expect(LabelPolicy.missing(required: policy, present: ["Bug"]).map(\.name) == ["enhancement"])
    }

    @Test("The missing ones keep the policy's order, so the button's list is stable")
    func orderIsThePolicys() {
        // Two calls against the same repository must list them the same way, or
        // a reader watching the row cannot tell a change from a reshuffle.
        let missing = LabelPolicy.missing(required: policy, present: [])
        #expect(missing.map(\.name) == ["bug", "enhancement"])
        #expect(
            LabelPolicy.missing(required: policy, present: ["enhancement"]).map(\.name) == ["bug"]
        )
    }

    @Test("Every default label is one gh label create will accept")
    func defaultsAreWellFormed() {
        #expect(!LabelPolicy.default.isEmpty)
        for label in LabelPolicy.default {
            // Six hex digits, no leading `#`: that is exactly what
            // `gh label create --color` takes, and a `#` is rejected.
            #expect(label.color.count == 6, "\(label.name) has colour \(label.color)")
            #expect(
                label.color.allSatisfy { $0.isHexDigit },
                "\(label.name) has a non-hex colour: \(label.color)"
            )
            #expect(!label.name.isEmpty)
            #expect(!label.description.isEmpty, "\(label.name) has no description")
        }
    }

    @Test("The default policy is a floor this repository already meets")
    func defaultIsAFloorNobodyArguesWith() {
        // The mechanism is the point of #170, not the taxonomy. Starting from
        // the four stock type labels means the check ships green everywhere it
        // is already true, and a disagreement about *which* labels to require is
        // a separate conversation from whether Elliot should check at all.
        #expect(
            Set(LabelPolicy.default.map(\.name))
                == ["bug", "enhancement", "documentation", "question"]
        )
    }

    @Test("No two required labels claim the same name")
    func namesAreUnique() {
        // A duplicate would be created twice, and the second create would be
        // swallowed as an already-exists no-op — a silent oddity in a list a
        // human reads.
        let names = LabelPolicy.default.map { $0.name.lowercased() }
        #expect(Set(names).count == names.count, "duplicate in \(names.sorted())")
    }
}
