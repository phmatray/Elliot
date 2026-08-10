import Foundation
import Testing

/// Whoever presses Merge must hand `confirmMerge` the origin the merge was
/// *armed* with, never a literal.
///
/// ⛔ **This gate exists because its absence was measured, not guessed.**
/// `confirmMerge` gained an `origin` parameter so a merge an auto-dev session
/// arranged would stop being written into `moveAudit` as `.userDrag` and
/// rendered by `MoveOrigin.historyLabel` as **"Dragged"**. Three tests in
/// `AppModelTests` pin the model half — the arming carries the origin, and the
/// audit records the one `confirmMerge` was given. Not one of them can see the
/// **button**, and the button is the only production caller there is.
///
/// Measured on this branch: replacing `origin: pending.origin` in
/// `Sheets.swift` with `origin: .userDrag` left **684 tests in 77 suites
/// passing**. The parameter was threaded, the audit test still proved
/// `confirmMerge` honours what it is handed, and the feature was defeated in
/// one word at the only place that calls it. That is the shape `CaretAnchorTests`
/// was written for: everything either side of the step is green, and the step
/// itself has no test.
///
/// A source gate rather than a behavioural one because `swift test` cannot press
/// a button, and CLAUDE.md records that on this machine an agent's shell is
/// refused both the Accessibility and Screen Recording grants that a synthetic
/// press would need. The idiom is `DefaultActionTests`', `CaretAnchorTests`' and
/// `AnalysisPanelViewSourceTests`', for the reason CLAUDE.md gives: *a gate that
/// is not a test is a gate nobody re-runs.*
@Suite("The merge confirmation's origin")
struct MergeOriginSourceTests {

    /// The view targets, found from this file rather than from the working
    /// directory — `swift test` promises nothing about the latter.
    ///
    /// `ElliotApp` is covered for `DefaultActionTests`' reason: it is an
    /// `executableTarget`, so `swift test` cannot import it, and a `confirmMerge`
    /// call added to a `Scene` or a `Commands` menu item would be unguarded
    /// while the suite stayed green. Reading source *text* makes an
    /// un-importable target checkable — a path, not a dependency.
    private static let targets: [(name: String, url: URL)] = {
        let sources = URL(filePath: #filePath)
            .deletingLastPathComponent()  // …/Tests/ElliotAppKitTests
            .deletingLastPathComponent()  // …/Tests
            .deletingLastPathComponent()  // …/ElliotKit
            .appending(path: "Sources")
        return [
            (name: "ElliotAppKit", url: sources.appending(path: "ElliotAppKit")),
            (name: "ElliotApp", url: sources.appending(path: "ElliotApp")),
        ]
    }()

    /// The line with any `//` comment cut away, so a *mention* of a token cannot
    /// be read as a use of it.
    ///
    /// ⚠️ **Load-bearing.** `AppModel.confirmMerge`, `AppModel.PendingMerge` and
    /// this very file all discuss `origin: .userDrag` at length — describing the
    /// defect is how the fix is explained — so a gate matching raw text would
    /// fail on the explanation of the rule it enforces, and the obvious way to
    /// make it pass would be to delete the explanation. CLAUDE.md records the
    /// same hazard from #186: a string gate over prose *"can tell neither a
    /// claim from a mention nor a live claim from a quoted one"*. Cutting at
    /// `//` tells them apart for these targets, where no string literal contains
    /// one.
    private static func code(_ line: String) -> String {
        guard let comment = line.range(of: "//") else { return line }
        return String(line[line.startIndex..<comment.lowerBound])
    }

    /// Every Swift file of every covered target, comments already stripped.
    ///
    /// ⚠️ A target that contributes **no** files is a failure, not an empty
    /// walk: a renamed directory would otherwise silently reduce this gate to
    /// nothing while every test still passed — the shape this repository keeps
    /// paying for, where an instrument that stopped working reads as a clean
    /// result.
    private static func sources() throws -> [(path: String, code: String)] {
        var found: [(path: String, code: String)] = []
        for target in targets {
            let names = try FileManager.default
                .contentsOfDirectory(atPath: target.url.path(percentEncoded: false))
                .filter { $0.hasSuffix(".swift") }
                .sorted()
            #expect(
                !names.isEmpty,
                Comment(
                    rawValue:
                        "\(target.name) contributed no files to the merge-origin gate. Its "
                        + "directory is \(target.url.path(percentEncoded: false)) — has the target "
                        + "moved or been renamed?"))
            for name in names {
                let text = try String(
                    contentsOf: target.url.appending(path: name), encoding: .utf8)
                found.append(
                    (
                        path: "\(target.name)/\(name)",
                        code: text.components(separatedBy: "\n").map(code).joined(separator: "\n")
                    ))
            }
        }
        return found
    }

    /// Every `confirmMerge(…)` argument list in the covered targets, by
    /// paren-balancing from the call.
    ///
    /// ⚠️ Balanced on parentheses alone, which is honest here only because no
    /// argument to this call is a string literal containing one — the arguments
    /// are a card id, a `[String]` local and an origin. A call taking a literal
    /// sentence would need the scanner to know about quotes.
    ///
    /// ⚠️ The **declaration** is skipped, and it is not a detail: the first run
    /// of this gate read `func confirmMerge(cardID: UUID, followUps: [String],
    /// origin: MoveOrigin)` as a call site and failed on the signature — which
    /// would have been "fixed" by loosening the assertion, quietly costing the
    /// gate the only call it exists to check.
    private static func confirmMergeCalls() throws -> [(path: String, arguments: String)] {
        var calls: [(path: String, arguments: String)] = []
        for file in try sources() {
            var search = file.code.startIndex
            while let hit = file.code.range(of: "confirmMerge(", range: search..<file.code.endIndex) {
                guard !file.code[file.code.startIndex..<hit.lowerBound].hasSuffix("func ") else {
                    search = hit.upperBound
                    continue
                }
                var depth = 0
                var index = file.code.index(before: hit.upperBound)  // the "("
                let open = hit.upperBound
                while index < file.code.endIndex {
                    if file.code[index] == "(" { depth += 1 }
                    if file.code[index] == ")" {
                        depth -= 1
                        if depth == 0 {
                            calls.append((path: file.path, arguments: String(file.code[open..<index])))
                            break
                        }
                    }
                    index = file.code.index(after: index)
                }
                search = hit.upperBound
            }
        }
        return calls
    }

    /// Whitespace runs collapsed to one space.
    ///
    /// ⚠️ Without this the gate is brittle in a way that would eventually be
    /// read as the defect rather than as the instrument: this call sits at 88
    /// columns, and a rename that pushed it past 110 would be re-wrapped by hand
    /// onto `origin:` / `pending.origin` — turning a correct call into a
    /// failure, whose obvious "fix" is to delete the assertion.
    private static func flat(_ arguments: String) -> String {
        arguments.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    @Test("Every caller of confirmMerge passes the armed origin, not a literal")
    func theButtonForwardsTheArmedOrigin() throws {
        let calls = try Self.confirmMergeCalls()
            .map { (path: $0.path, arguments: Self.flat($0.arguments)) }

        // A negative needs its positive witness. With no call found, every claim
        // below is vacuously true and this suite goes green having read nothing
        // — which is precisely the failure it is here to prevent, one level up.
        #expect(
            !calls.isEmpty,
            """
            no call to confirmMerge was found under Sources/ElliotAppKit or Sources/ElliotApp. \
            Either the merge confirmation has been renamed or restructured, or this gate is \
            reading the wrong directory — in both cases it has silently stopped guarding anything.
            """)
        #expect(
            calls.contains { $0.path == "ElliotAppKit/Sheets.swift" },
            Comment(
                rawValue:
                    "the Merge button in Sheets.swift no longer calls confirmMerge. Found instead: "
                    + "\(calls.map(\.path).joined(separator: ", "))"))

        for call in calls {
            #expect(
                call.arguments.contains("origin: pending.origin"),
                Comment(
                    rawValue:
                        "\(call.path) calls confirmMerge without forwarding the armed origin. "
                        + "PendingMerge carries who asked for the merge from armPendingMerge to "
                        + "this button; anything else here is the button asserting an identity it "
                        + "does not have, and moveAudit records that assertion permanently. "
                        + "Arguments read: \(call.arguments)"
                ))

            // The sharper half. `origin: .userDrag` is what this used to say and
            // is the regression that leaves every other test green; `.mcp`,
            // `.autoDev` and `.system` are the same mistake wearing a different
            // case name — a confirmation that names its own origin is lying
            // about the one act the product calls irreversible.
            #expect(
                !call.arguments.contains("origin: ."),
                Comment(
                    rawValue:
                        "\(call.path) hands confirmMerge a MoveOrigin literal. The confirmation is "
                        + "a button, not an actor: whoever armed the merge is who made it, and "
                        + "that is what MoveOrigin.historyLabel prints in the card's move history. "
                        + "If a new caller here genuinely is the actor, say so where the merge is "
                        + "armed — armPendingMerge(cardID:prNumber:origin:) — and let it travel on "
                        + "PendingMerge as it already does. "
                        + "Arguments read: \(call.arguments)"
                ))
        }
    }
}
