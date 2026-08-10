import Foundation
import Testing
import TestSupport

/// `argumentValues(after:in:)` replaced three `argv[i + 1]` sites that would
/// have killed the test binary rather than failed. The trailing-flag case below
/// is the one that used to trap, so it is the one this suite exists for.
@Suite("Argument values")
struct ArgumentValuesTests {

    @Test("Every occurrence yields the element that follows it, in argv order")
    func everyOccurrenceIsReturned() {
        // Order as well as membership: the `--add-dir` assertions read the
        // checkout first and the artifact directory second, so a helper that
        // sorted or de-duplicated would make that comparison stop meaning
        // anything. Pinned by this one `==` — a companion `!= ["/b", "/a"]`
        // cannot fail once this passes, and an assertion that cannot fail is
        // what this suite exists to remove.
        let argv = ["claude", "--add-dir", "/a", "-p", "story", "--add-dir", "/b"]
        #expect(argumentValues(after: "--add-dir", in: argv) == ["/a", "/b"])
    }

    @Test("A single occurrence yields one value, not the whole tail")
    func oneOccurrenceYieldsOneValue() {
        #expect(
            argumentValues(after: "--permission-mode", in: [
                "claude", "--permission-mode", "acceptEdits", "-p", "story",
            ]) == ["acceptEdits"])
    }

    @Test("A flag in the last position is named, not dropped and not a trap")
    func aTrailingFlagIsNamed() {
        // `argv[index + 1]` here is `Fatal error: Index out of range`, which
        // takes the process down and prints no summary line — so this case is
        // the whole point of the function.
        let marker = missingValueMarker(for: "--add-dir")
        #expect(argumentValues(after: "--add-dir", in: ["claude", "--add-dir"]) == [marker])

        // ⛔ And it is a marker rather than an omission. Dropping it would swap
        // the trap for a *silent substitution*: this argv would then compare
        // equal to one carrying a single `--add-dir /a`, so an assertion would
        // pass over a spawn that really did carry a second, value-less flag.
        #expect(
            argumentValues(after: "--add-dir", in: ["claude", "--add-dir", "/a", "--add-dir"])
                == ["/a", marker])
        #expect(
            argumentValues(after: "--add-dir", in: ["claude", "--add-dir", "/a", "--add-dir"])
                != ["/a"])
    }

    @Test("The marker cannot be mistaken for a value a spawn could carry")
    func theMarkerIsNotAPlausibleValue() {
        // It has to lose against every real argv element, or it would reinstate
        // the silence it exists to break.
        let marker = missingValueMarker(for: "--add-dir")
        #expect(marker.contains("--add-dir"))
        #expect(marker != "--add-dir")
        #expect(marker.hasPrefix("<") && marker.hasSuffix(">"))
    }

    @Test("An absent flag yields nothing")
    func anAbsentFlagIsEmpty() {
        #expect(argumentValues(after: "--add-dir", in: ["claude", "-p", "story"]).isEmpty)
        #expect(argumentValues(after: "--add-dir", in: []).isEmpty)
    }

    @Test("Only whole elements match")
    func onlyWholeElementsMatch() {
        // Documented rather than supported: nothing in this package emits the
        // `--flag=value` shape, and half-handling it would let an assertion
        // pass against argv the spawner could never produce.
        #expect(argumentValues(after: "--add-dir", in: ["--add-dir=/a", "/b"]).isEmpty)
    }
}
