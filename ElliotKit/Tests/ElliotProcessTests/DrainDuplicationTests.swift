import Foundation
import Testing

/// Guards that the spawn/drain/publish mechanism exists exactly once.
///
/// These read source text rather than behaviour, which is unusual and is the
/// point: the defect #146 closed was not a wrong answer, it was a *second copy*
/// of a right one. No behavioural test can see that — the two drains agreed
/// when the copy was made, and they would have gone on agreeing right up until
/// the next fix landed in one file. Three already had (`22bb230`, `3b1c226`,
/// `36b6da6`), each in one file, and a fourth investigation (#26) was aimed at
/// one file when it opened.
///
/// So the thing worth holding is the shape, and the shape is checkable. A gate
/// that is not a test is a gate nobody re-runs. Since #21 that argument is
/// stronger rather than weaker — `ci.yml` executes `swift test` on every pull
/// request, so a guard shaped as a test is enforced on every change rather than
/// only when someone remembers to run it.
///
/// ⚠️ Not *the only* kind of guard, though: `swift-floor.yml` enforces a
/// toolchain assertion and two builds on every pull request, and none of the
/// three is a test. The claim worth making is the narrower true one above.
///
/// That sentence is worded to match CLAUDE.md § *One spawn* exactly, and the
/// reason is this suite's own subject: an argument kept in two places drifts,
/// and the halves stop agreeing long before anyone notices. Neither copy is
/// counted below — the gate reads `Sources/ElliotProcess` only — so this pair
/// is held together by hand, which is precisely the weakness the gate removes
/// there. Both halves already had to be corrected once, in #186, for claiming
/// more than was true.
@Suite("Drain duplication")
struct DrainDuplicationTests {

    private static let sources: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // ElliotProcessTests
        .deletingLastPathComponent()   // Tests
        .deletingLastPathComponent()   // ElliotKit
        .appendingPathComponent("Sources/ElliotProcess")

    private static func read(_ name: String) throws -> [String] {
        try String(contentsOf: sources.appendingPathComponent(name), encoding: .utf8)
            .components(separatedBy: "\n")
    }

    private static func swiftFiles() throws -> [String] {
        try FileManager.default
            .contentsOfDirectory(atPath: sources.path)
            .filter { $0.hasSuffix(".swift") }
            .sorted()
    }

    /// A line with its comment forms stripped, so a gate about code cannot be
    /// tripped — or satisfied — by prose describing it.
    private static func isCode(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return !trimmed.hasPrefix("//") && !trimmed.isEmpty
    }

    /// Acceptance criteria 1 and 2: the mechanism lives in one file, and neither
    /// spawner has any pipe-handling left of its own.
    @Test("Pipe handling exists only in ChildProcess")
    func pipeHandlingIsNotDuplicated() throws {
        let shapes = ["Pipe()", "readabilityHandler", "readDataToEndOfFile", "CheckedContinuation"]

        for file in try Self.swiftFiles() where file != "ChildProcess.swift" {
            let offenders = try Self.read(file).enumerated().filter { _, line in
                Self.isCode(line) && shapes.contains { line.contains($0) }
            }
            #expect(
                offenders.isEmpty,
                """
                \(file) handles a child's pipes itself — that mechanism belongs to \
                ChildProcess.swift alone: \
                \(offenders.map { "line \($0.offset + 1)" }.joined(separator: ", ")). \
                If this is a `CheckedContinuation` doing something unrelated to draining \
                a child, narrow this gate to the drain shapes rather than deleting it.
                """
            )
        }
    }

    /// The flag the whole ordering argument turns on. Two of them is two
    /// answers to "may a late handler still read a byte", and only one can be
    /// right.
    @Test("The drained flag is declared exactly once")
    func drainedIsDeclaredOnce() throws {
        var declarations: [String] = []
        for file in try Self.swiftFiles() {
            for (index, line) in try Self.read(file).enumerated()
            where Self.isCode(line) && line.contains("var drained") {
                declarations.append("\(file):\(index + 1)")
            }
        }
        #expect(declarations.count == 1, "expected one `var drained`, found \(declarations)")
    }

    /// Acceptance criterion 3, which is a regression guard rather than work:
    /// #105 already made the escalation single, and this keeps it that way.
    @Test("Only ProcessTermination signals, and the grace is written once")
    func escalationIsNotDuplicated() throws {
        var signalSites: [String] = []
        var graceDeclarations: [String] = []

        for file in try Self.swiftFiles() {
            for (index, line) in try Self.read(file).enumerated() where Self.isCode(line) {
                if line.contains("SIGKILL") || line.contains("kill(") {
                    signalSites.append("\(file):\(index + 1)")
                }
                if line.contains("hardKillGrace: Duration") || line.contains(".seconds(15)") {
                    graceDeclarations.append("\(file):\(index + 1)")
                }
            }
        }

        #expect(
            signalSites.allSatisfy { $0.hasPrefix("ProcessTermination.swift:") },
            "something outside ProcessTermination.swift signals a child: \(signalSites)"
        )
        // Asserted by count and file, never by line number: a gate that breaks
        // when a comment is added above it teaches people to edit the gate.
        // One line declares the constant *and* gives it its value, so both
        // needles land on the same line and one hit is the expected count.
        #expect(
            graceDeclarations.count == 1,
            "the hard-kill grace should be written exactly once, found \(graceDeclarations)"
        )
        #expect(
            graceDeclarations.allSatisfy { $0.hasPrefix("ProcessTermination.swift:") },
            "the hard-kill grace belongs to ProcessTermination.swift, found \(graceDeclarations)"
        )
    }

    /// The measurement that opened #146, kept runnable.
    ///
    /// Eight comment lines were byte-identical between the two spawners on
    /// `main` at `39b977e`, and they were not incidental — they were the four
    /// load-bearing arguments themselves. When the *explanation* of an invariant
    /// has been copied word for word into a second file, the invariant has been
    /// copied too. A non-zero result here names exactly which one.
    @Test("No comment is written twice across the two spawners")
    func commentsAreNotDuplicated() throws {
        func comments(_ name: String) throws -> Set<String> {
            let lines = try Self.read(name).map { $0.trimmingCharacters(in: .whitespaces) }
            return Set(lines.filter { $0.hasPrefix("//") && $0.count > 6 })
        }

        let shared = try comments("ProcessRunner.swift")
            .intersection(comments("StreamingProcess.swift"))
            .sorted()

        #expect(
            shared.isEmpty,
            """
            \(shared.count) comment line(s) are written in both spawners, which is how \
            a shared invariant announces itself:
            \(shared.joined(separator: "\n"))
            """
        )
    }
}
