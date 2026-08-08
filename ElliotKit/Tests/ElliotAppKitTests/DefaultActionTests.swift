import Foundation
import Testing

@testable import ElliotAppKit

/// Guards that Return belongs to exactly the controls `DefaultAction` sanctions.
///
/// This reads source text rather than behaviour, for the same reason
/// `DrainDuplicationTests` does: the defect is not a wrong answer, it is a
/// *second claimant*. No behavioural test can see it — `swift test` cannot press
/// a key, and CLAUDE.md records that on this machine an agent's shell gets
/// `-1719` from `osascript` and `could not create image from display` from
/// `screencapture`, so the keystroke that would prove it needs a person.
///
/// What is checkable is the shape, and the shape is what went wrong: two
/// controls that can be on screen at the same time both claimed
/// `.keyboardShortcut(.defaultAction)`, one of them merging to a default branch
/// on github.com. Nothing failed. Nothing could have.
///
/// The gate reads `Sources/ElliotAppKit` only. `ElliotApp` is an
/// `executableTarget` and cannot be imported, which is the same blind spot that
/// let `.inspector()` ship three times — so a default action added there is
/// still unguarded, and that limit is stated here rather than left for someone
/// to discover.
@Suite("Default action")
struct DefaultActionTests {

    private static let sources: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // ElliotAppKitTests
        .deletingLastPathComponent()   // Tests
        .deletingLastPathComponent()   // ElliotKit
        .appendingPathComponent("Sources/ElliotAppKit")

    /// A line with its comment forms stripped, so a gate about code cannot be
    /// tripped — or satisfied — by prose describing it. Several files now
    /// discuss `.keyboardShortcut(.defaultAction)` at length in comments,
    /// including the one that removed a claim; without this they would each read
    /// as a claimant.
    private static func isCode(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return !trimmed.hasPrefix("//") && !trimmed.isEmpty
    }

    private static func swiftFiles() throws -> [String] {
        try FileManager.default
            .contentsOfDirectory(atPath: sources.path)
            .filter { $0.hasSuffix(".swift") }
            .sorted()
    }

    private static func lines(of file: String) throws -> [String] {
        try String(contentsOf: sources.appendingPathComponent(file), encoding: .utf8)
            .components(separatedBy: "\n")
    }

    /// The literal head of a button's label.
    ///
    /// `Button("Merge PR \(pr)")` yields `"Merge PR"` and
    /// `Button("Start \(n) run…")` yields `"Start"` — the interpolation is cut
    /// because a label carrying a live count cannot be matched whole, and the
    /// part before it is the part that names the act.
    private static func labelHead(in line: String) -> String? {
        guard let openQuote = line.range(of: "\"") else { return nil }
        let rest = line[openQuote.upperBound...]
        let end =
            rest.range(of: "\\(")?.lowerBound
            ?? rest.range(of: "\"")?.lowerBound
            ?? rest.endIndex
        let head = rest[..<end].trimmingCharacters(in: .whitespaces)
        return head.isEmpty ? nil : head
    }

    /// Every `.keyboardShortcut(.defaultAction)` in the target, attributed to the
    /// button it modifies.
    ///
    /// A claim it cannot attribute is a **failure**, not a skip: an
    /// unattributable claimant is exactly the one nobody would notice, and this
    /// suite exists because nobody noticed.
    private static func claims() throws -> [(file: String, line: Int, label: String)] {
        var found: [(file: String, line: Int, label: String)] = []

        for file in try swiftFiles() {
            let body = try lines(of: file)
            for (index, line) in body.enumerated()
            where isCode(line) && line.contains("keyboardShortcut(.defaultAction)") {
                // Walk back to the nearest `Button` that opens this modifier
                // chain. 40 lines is generous on purpose — a button's action
                // closure can be long, and a claim that falls off the end of
                // the window must fail rather than be dropped.
                var label: String?
                for back in stride(from: index, through: max(0, index - 40), by: -1)
                where body[back].contains("Button") && isCode(body[back]) {
                    label = labelHead(in: body[back])
                    break
                }
                guard let label else {
                    Issue.record(
                        """
                        \(file):\(index + 1) claims Return but this gate cannot tell which \
                        control it belongs to. Either the button's label is not a literal, \
                        or it is more than 40 lines above. Give the control a literal label \
                        and list it in `DefaultAction.claimants` with what it commits.
                        """
                    )
                    continue
                }
                found.append((file, index + 1, label))
            }
        }
        return found
    }

    @Test("Every default action belongs to a control DefaultAction sanctions")
    func everyClaimIsSanctioned() throws {
        let sanctioned = DefaultAction.sanctionedLabels

        for claim in try Self.claims() {
            #expect(
                sanctioned.contains(claim.label),
                """
                \(claim.file):\(claim.line) — "\(claim.label)" claims Return, and \
                `DefaultAction` does not sanction it. The rule is that \
                `.keyboardShortcut(.defaultAction)` may be claimed only by a control that \
                commits text the reader has typed. If this control does, add it to \
                `DefaultAction.claimants` saying what it commits. If it does not — if it \
                starts a run, merges, or deletes — it must be pressed, not triggered by a \
                key the reader hit somewhere else in the window.
                """
            )
        }
    }

    @Test("The controls DefaultAction denies claim nothing")
    func deniedControlsClaimNothing() throws {
        let claimed = Set(try Self.claims().map(\.label))

        for denied in DefaultAction.denied {
            #expect(
                !claimed.contains(denied.label),
                """
                "\(denied.label)" (\(denied.file)) has been given a default action back. \
                It is listed in `DefaultAction.denied` because it commits \
                \(denied.commits). Re-adding it reverses a decision — if that is intended, \
                move it to `claimants` and say in the diff what changed.
                """
            )
        }
    }

    /// The count is asserted as well as the membership, because membership alone
    /// would let a *second* "Save changes" appear in a third file and pass. The
    /// hazard is a claimant sharing the window with another, so how many exist
    /// is the number that matters.
    @Test("The number of claimants is the number DefaultAction lists")
    func claimCountMatches() throws {
        let claims = try Self.claims()
        #expect(
            claims.count == DefaultAction.expectedClaimCount,
            """
            ElliotAppKit contains \(claims.count) default actions and `DefaultAction` \
            lists \(DefaultAction.expectedClaimCount). Found at: \
            \(claims.map { "\($0.file):\($0.line) (\($0.label))" }.joined(separator: ", ")).
            """
        )
    }

    /// Each sanctioned claimant lives where `DefaultAction` says it does.
    ///
    /// Without this, moving "Save changes" into a fourth file would keep the
    /// label set and the count intact while changing which panes can contend for
    /// Return — which is the whole subject.
    @Test("Each claimant is in the file DefaultAction names")
    func claimantsAreWhereTheyAreDeclared() throws {
        let actual = Set(try Self.claims().map { "\($0.file)/\($0.label)" })
        let declared = Set(DefaultAction.claimants.map { "\($0.file)/\($0.label)" })

        #expect(
            actual == declared,
            """
            The default actions in the source and the ones `DefaultAction.claimants` \
            declares disagree.
            In source only: \(actual.subtracting(declared).sorted().joined(separator: ", ")).
            Declared only: \(declared.subtracting(actual).sorted().joined(separator: ", ")).
            """
        )
    }
}
