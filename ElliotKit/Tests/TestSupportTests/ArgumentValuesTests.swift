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
        let argv = ["claude", "--add-dir", "/a", "-p", "story", "--add-dir", "/b"]
        #expect(argumentValues(after: "--add-dir", in: argv) == ["/a", "/b"])
        // Order, not membership: the `--add-dir` assertions read the checkout
        // first and the artifact directory second, and a helper that sorted or
        // de-duplicated would make that comparison stop meaning anything.
        #expect(argumentValues(after: "--add-dir", in: argv) != ["/b", "/a"])
    }

    @Test("A single occurrence yields one value, not the whole tail")
    func oneOccurrenceYieldsOneValue() {
        #expect(
            argumentValues(after: "--permission-mode", in: [
                "claude", "--permission-mode", "acceptEdits", "-p", "story",
            ]) == ["acceptEdits"])
    }

    @Test("A flag in the last position yields no value rather than trapping")
    func aTrailingFlagIsNotAnIndexOutOfRange() {
        // `argv[index + 1]` here is `Fatal error: Index out of range`, which
        // takes the process down and prints no summary line — so this case is
        // the whole point of the function.
        #expect(argumentValues(after: "--add-dir", in: ["claude", "--add-dir"]).isEmpty)
        // And a trailing flag does not discard the occurrences before it: the
        // assertion that follows should fail on a missing value, not on an
        // empty list that looks like the flag was never passed.
        #expect(
            argumentValues(after: "--add-dir", in: ["claude", "--add-dir", "/a", "--add-dir"])
                == ["/a"])
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
