import Foundation
import Testing

/// The three files that react to a verified outcome. Named rather than globbed:
/// the claim is about these three, and a new file in the target is not
/// automatically one of them. At file scope so `@Test(arguments:)` can reach it.
private let watchedFiles = ["RunScheduler.swift", "Reconciler.swift", "PRWatcher.swift"]

/// Guards that a card's fields are decided in exactly one place.
///
/// `VerifiedOutcome.applied(to:attribution:)` says what a verified outcome does
/// to a card — the fields, the `lastError`, and the move it implies — and returns
/// all three in one `CardOutcome`. `RunScheduler.apply`, `Reconciler.apply` and
/// `PRWatcher.reconcile` save and move; they do not judge.
///
/// This reads source text rather than behaviour, which is unusual and is the
/// point — the idiom is `DrainDuplicationTests`, and the reason is the same. The
/// defect it guards against is not a wrong answer, it is a *second writer* of a
/// right one, and a second writer agrees with the first right up until one of
/// them is corrected. That already happened here: three hand-written switches
/// drifted until #135, and the same run produced a clean card through
/// `RunScheduler` and a card still showing a failed run's banner through
/// `Reconciler`.
///
/// Until now the rule was held by a sentence in CLAUDE.md that calls itself
/// "enforced by grep", and nothing ran the grep. PR2 is the right moment to fix
/// that: `effort` and `evidence` join the protected set at exactly the point an
/// unattended agent becomes a writer of card fields.
@Suite("Card field writers")
struct CardFieldWritersTests {

    private static let sources: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // ElliotEngineTests
        .deletingLastPathComponent()   // Tests
        .deletingLastPathComponent()   // ElliotKit
        .appendingPathComponent("Sources/ElliotEngine")

    /// Exactly the set the design names. `appraisedAt` is deliberately not here
    /// yet: PR6 widens the set when the appraisal harvester becomes its writer,
    /// and widening it early would make this gate assert something no code in
    /// the package is trying to do.
    private static let fields = [
        "issueNumber", "issueURL", "prNumber", "prURL", "branch", "lastError",
        "effort", "evidence",
    ]

    private static func read(_ name: String) throws -> [String] {
        try String(contentsOf: sources.appendingPathComponent(name), encoding: .utf8)
            .components(separatedBy: "\n")
    }

    /// A line with its comment forms stripped, so a gate about code cannot be
    /// tripped — or satisfied — by prose describing it. `RunScheduler.swift`
    /// mentions `branch` and `lastError` in three doc comments today.
    private static func isCode(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return !trimmed.hasPrefix("//") && !trimmed.isEmpty
    }

    @Test("No poller writes a card field of its own")
    func cardFieldsAreDecidedInOnePlace() throws {
        var offenders: [String] = []

        for file in watchedFiles {
            for (index, line) in try Self.read(file).enumerated() where Self.isCode(line) {
                for field in Self.fields where line.contains("\(field) = ") {
                    offenders.append("\(file):\(index + 1) assigns `\(field)`")
                }
            }
        }

        #expect(
            offenders.isEmpty,
            """
            A card field is written outside `VerifiedOutcome.applied(to:)`, which is the \
            only thing allowed to decide one:
            \(offenders.joined(separator: "\n"))
            If this is a local variable that merely shares a name with a card field, rename \
            the local rather than deleting the gate.
            """
        )
    }

    /// The gate is worth nothing if the files it names are not the files that
    /// exist: a rename would turn it into a test that reads nothing and passes,
    /// which is the failure mode every source-reading gate has.
    @Test("Each watched file is there to be read", arguments: watchedFiles)
    func watchedFilesExist(name: String) throws {
        let lines = try Self.read(name)
        #expect(!lines.isEmpty)
    }
}
