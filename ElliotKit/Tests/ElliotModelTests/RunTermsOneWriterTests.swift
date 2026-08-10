import Foundation
import Testing

@testable import ElliotModel

/// `RunTermsEdit.applied(to:)` is the only place a `Repo`'s run terms are
/// assigned, and this reads the source to keep it that way.
///
/// The invariant is not stylistic. Both fields have been columns since v1 with
/// **no writer at all**, which is how a documented safety knob came to have no
/// handle for the whole life of the project; the fix is worth little if the next
/// screen that wants to change a mode assigns the field directly and skips
/// ``ExtraAllowedTools/normalise(_:)`` on the way. A second writer would not
/// fail anything — it would simply store `[""]`, and `--allowedTools ""` is a
/// thing only a run discovers.
///
/// This is the shape `CardOutcome` is held in one layer over, where the same
/// discipline is enforced by grep across three engine files. A gate that is not
/// a test is a gate nobody re-runs.
@Suite("Run terms have one writer")
struct RunTermsOneWriterTests {

    private static let sources = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // ElliotModelTests
        .deletingLastPathComponent()   // Tests
        .deletingLastPathComponent()   // ElliotKit
        .appendingPathComponent("Sources")

    /// Assignments to the two fields **through a member access**, as
    /// `(file, line)` — `x.permissionMode = …`, never a bare
    /// `permissionMode = …`.
    ///
    /// ⚠️ The leading dot is load-bearing and was not in the first draft, which
    /// failed naming `RepoDTO(repo:)`: an initialiser may omit `self.`, so
    /// `permissionMode = repo.permissionMode.rawValue` reads exactly like a
    /// second writer while being the opposite — a *read* of a repository into a
    /// wire value. A matcher that cannot tell the two apart would have to be
    /// silenced with an exclusion list, and an exclusion list is where a real
    /// second writer eventually gets added.
    ///
    /// This also excludes `ClaudeInvocation`, which carries a `permissionMode`
    /// of its own and assigns it in its own initialiser.
    ///
    /// Comment lines are stripped for the reason `DefaultActionTests` strips
    /// them: this file and `RunTerms.swift` both discuss the assignment at
    /// length, and prose about a gate must not be able to trip it.
    private static func assignments() throws -> [(file: String, line: String)] {
        var found: [(file: String, line: String)] = []
        var walked = 0
        let enumerator = FileManager.default.enumerator(atPath: sources.path)
        while let entry = enumerator?.nextObject() as? String {
            guard entry.hasSuffix(".swift") else { continue }
            walked += 1
            let text = try String(
                contentsOf: sources.appendingPathComponent(entry), encoding: .utf8
            )
            for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
                let line = raw.trimmingCharacters(in: .whitespaces)
                guard !line.hasPrefix("//"), !line.hasPrefix("///") else { continue }
                guard line.contains(".permissionMode =") || line.contains(".extraAllowedTools =")
                else { continue }
                guard !line.hasPrefix("self.") else { continue }
                found.append((file: entry, line: line))
            }
        }
        // An empty walk is a broken instrument reading as a clean result — the
        // failure this repository keeps paying for. A renamed directory must
        // fail here rather than silently checking nothing.
        #expect(walked > 50, "walked only \(walked) files; the source path is wrong")
        return found
    }

    @Test("Only `RunTermsEdit.applied(to:)` assigns a repository's run terms")
    func oneWriter() throws {
        let offenders = try Self.assignments().filter {
            !$0.file.hasSuffix("ElliotModel/RunTerms.swift")
        }
        let named = offenders.map { "\($0.file): \($0.line)" }.joined(separator: " · ")
        #expect(
            offenders.isEmpty,
            Comment(rawValue: "a second writer skips normalising: \(named)")
        )
    }

    /// The positive control. Without it the test above passes just as happily
    /// when the matcher has stopped matching anything at all — which is the
    /// failure mode of every gate in this file's family.
    @Test("The gate can still see the writer it permits")
    func theGateStillFindsTheOneWriter() throws {
        let permitted = try Self.assignments().filter {
            $0.file.hasSuffix("ElliotModel/RunTerms.swift")
        }
        #expect(permitted.count == 2, "found \(permitted.count) assignments in RunTerms.swift")
    }
}
