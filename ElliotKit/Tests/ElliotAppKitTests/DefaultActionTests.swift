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
/// **It covers `Sources/ElliotAppKit` and `Sources/ElliotApp`** — both targets
/// that can put a control on screen (#251).
///
/// `ElliotApp` used to be outside it, and that was the gap worth closing rather
/// than merely stating. It is an `executableTarget`, so `swift test` cannot
/// import it — `Package.swift` records what that costs: *"anything left in here
/// is unreachable from `swift test`, which is how `.inspector()` shipped three
/// times without anyone seeing it work."* Its 300-plus lines of `Scene` and
/// `Commands` include `NewStoryMenuItem` and `OpenWindowButtons`, so a claim
/// added there was unguarded and the suite would have stayed green.
///
/// ⚠️ **Nothing had to be imported to close it.** This gate reads source *text*,
/// so a second target is a path, not a dependency — the one property that makes
/// an un-importable target checkable at all. `DefaultAction.claimants` stays the
/// single list both targets are checked against.
@Suite("Default action")
struct DefaultActionTests {

    private static let targets: [(name: String, url: URL)] = {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // ElliotAppKitTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // ElliotKit
            .appendingPathComponent("Sources")
        return [
            (name: "ElliotAppKit", url: sources.appendingPathComponent("ElliotAppKit")),
            (name: "ElliotApp", url: sources.appendingPathComponent("ElliotApp")),
        ]
    }()

    /// A line with its comment forms stripped, so a gate about code cannot be
    /// tripped — or satisfied — by prose describing it. Several files now
    /// discuss `.keyboardShortcut(.defaultAction)` at length in comments,
    /// including the one that removed a claim; without this they would each read
    /// as a claimant.
    private static func isCode(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return !trimmed.hasPrefix("//") && !trimmed.isEmpty
    }

    /// Every Swift file of every covered target, as `(target, file)`.
    ///
    /// ⚠️ A target that lists **no** files is a failure, not an empty walk: a
    /// renamed directory would otherwise silently reduce this gate's coverage
    /// while every test still passed — the shape this repository keeps paying
    /// for, where an instrument that stopped working reads as a clean result.
    private static func swiftFiles() throws -> [(target: String, file: String)] {
        var found: [(target: String, file: String)] = []
        for target in targets {
            let files = try FileManager.default
                .contentsOfDirectory(atPath: target.url.path)
                .filter { $0.hasSuffix(".swift") }
                .sorted()
            #expect(
                !files.isEmpty,
                Comment(
                    rawValue:
                        "\(target.name) contributed no files to the default-action gate. "
                        + "Its directory is \(target.url.path) — has the target moved or been renamed?"
                ))
            found += files.map { (target: target.name, file: $0) }
        }
        return found
    }

    private static func lines(of file: String, in target: String) throws -> [String] {
        guard let url = targets.first(where: { $0.name == target })?.url else { return [] }
        return try String(contentsOf: url.appendingPathComponent(file), encoding: .utf8)
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
    private static func claims() throws -> [(
        target: String, file: String, line: Int, label: String
    )] {
        var found: [(target: String, file: String, line: Int, label: String)] = []

        for entry in try swiftFiles() {
            let (target, file) = (entry.target, entry.file)
            let body = try lines(of: file, in: target)
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
                        \(target)/\(file):\(index + 1) claims Return but this gate cannot tell \
                        which control it belongs to. Either the button's label is not a literal, \
                        or it is more than 40 lines above. Give the control a literal label \
                        and list it in `DefaultAction.claimants` with what it commits.
                        """
                    )
                    continue
                }
                found.append((target, file, index + 1, label))
            }
        }
        return found
    }

    /// ⛔ **The covered-target list is itself gated, and that was found by
    /// break-testing rather than by design.**
    ///
    /// Deleting `ElliotApp` from `targets` left the whole suite green: every
    /// other test here asks *"is what we walked sanctioned"*, and none of them
    /// can notice that less was walked. Removing coverage is exactly the edit
    /// nobody would flag in review, since it deletes a line rather than adding
    /// a claim — the same shape as #251 itself, one level up.
    ///
    /// The criterion is mechanical rather than a second hand-written list: a
    /// target that imports SwiftUI can put a control on screen, and every such
    /// target must be walked. Adding a new UI target therefore fails here until
    /// it is covered, instead of quietly starting out unguarded the way
    /// `ElliotApp` did.
    @Test("Every target that can draw a control is walked")
    func coverageIsComplete() throws {
        let sources = Self.targets[0].url.deletingLastPathComponent()
        let drawing = try FileManager.default
            .contentsOfDirectory(atPath: sources.path)
            .filter { name in
                var isDirectory: ObjCBool = false
                let path = sources.appendingPathComponent(name).path
                guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
                    isDirectory.boolValue
                else { return false }
                let files = (try? FileManager.default.contentsOfDirectory(atPath: path)) ?? []
                return files.contains { file in
                    guard file.hasSuffix(".swift") else { return false }
                    let source = try? String(
                        contentsOf: sources.appendingPathComponent(name).appendingPathComponent(file),
                        encoding: .utf8)
                    return source?.contains("import SwiftUI") ?? false
                }
            }

        let covered = Set(Self.targets.map(\.name))
        let uncovered = Set(drawing).subtracting(covered)
        #expect(
            uncovered.isEmpty,
            Comment(
                rawValue:
                    "\(uncovered.sorted().joined(separator: ", ")) import SwiftUI and are not "
                    + "walked by this gate, so a `.keyboardShortcut(.defaultAction)` added there "
                    + "would go unnoticed. Add them to `targets`."))
        // And the list must not name a target that no longer draws anything —
        // a stale entry is a claim of coverage that buys nothing.
        #expect(covered.subtracting(Set(drawing)).isEmpty)
    }

    @Test("Every default action belongs to a control DefaultAction sanctions")
    func everyClaimIsSanctioned() throws {
        let sanctioned = DefaultAction.sanctionedLabels

        for claim in try Self.claims() {
            #expect(
                sanctioned.contains(claim.label),
                """
                \(claim.target)/\(claim.file):\(claim.line) — "\(claim.label)" claims Return, and \
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
            ElliotAppKit and ElliotApp contain \(claims.count) default actions between \
            them and `DefaultAction` lists \(DefaultAction.expectedClaimCount). Found at: \
            \(claims.map { "\($0.target)/\($0.file):\($0.line) (\($0.label))" }
                .joined(separator: ", ")).
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
