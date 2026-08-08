import Foundation
import Testing

/// The race tests in `SchedulerConcurrentPumpTests` prove the symptom is gone
/// in the interleavings they happened to hit. They cannot prove the *rule*,
/// because whether two pumps overlap is a scheduling outcome. This one can: it
/// reads the source, the way `DrainDuplicationTests` does, and fails naming the
/// invariant that was moved.
///
/// It also carries the whole of AC 1 on its own. `pump` no longer assigning
/// `pending` is what prevents the silent drop, and no behavioural test in this
/// suite reproduces that drop — healing it needs a pump with a stale snapshot to
/// finish last, which none of the fixtures can force without a timing hook the
/// repo's testing rules forbid.
@Suite("RunScheduler — the shape the race tests cannot see")
struct RunSchedulerShapeTests {

    private static let source: String = {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // ElliotEngineTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // ElliotKit
            .appendingPathComponent("Sources/ElliotEngine/RunScheduler.swift")
        return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }()

    /// The source with `//` line comments removed, so these tests measure code
    /// and not prose.
    ///
    /// Not a refinement — without it two of the three tests below fail on the
    /// very comments that document them. `pump`'s comment quotes the line it
    /// warns against (`pending = stillPending`) so `pumpDoesNotRebuildTheQueue`
    /// would read its own explanation as the defect; `start`'s comment argues
    /// about where the `await`s are, which is what `theClaimSitsAboveTheFirstAwait`
    /// searches for. A source-shape test that a comment can turn red teaches
    /// everyone to delete the comment.
    private static let code: String = {
        source
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> String in
                guard let marker = line.range(of: "//") else { return String(line) }
                return String(line[..<marker.lowerBound])
            }
            .joined(separator: "\n")
    }()

    /// The body of `private func start(_ run: SkillRun) async {` up to the next
    /// declaration at the same indentation.
    private func startBody() -> String {
        let code = Self.code
        guard let begin = code.range(of: "private func start(_ run: SkillRun) async {") else {
            return ""
        }
        let rest = code[begin.upperBound...]
        guard let end = rest.range(of: "\n    private func ") ?? rest.range(of: "\n    static func ")
        else { return String(rest) }
        return String(rest[..<end.lowerBound])
    }

    @Test("start claims the run in inFlight before its first await")
    func theClaimSitsAboveTheFirstAwait() {
        let body = startBody()
        #expect(!body.isEmpty, "start(_:) not found — this test's parser needs updating, not deleting")

        let claim = body.range(of: "inFlight[run.id] =")
        let firstAwait = body.range(of: "await ")
        #expect(claim != nil, "start no longer writes inFlight — the double-spawn guard is gone")
        guard let claim, let firstAwait else { return }
        #expect(
            claim.lowerBound < firstAwait.lowerBound,
            """
            `start` suspends before it claims the run in `inFlight`. Two pumps can \
            then both admit the same id and both spawn a `claude` for it. The guard \
            and the assignment must stay adjacent and above every `await`.
            """
        )
    }

    @Test("start refuses a run already in flight")
    func theClaimIsGuarded() {
        #expect(
            startBody().contains("guard inFlight[run.id] == nil else { return }"),
            "start no longer refuses a run that is already in flight — a second pump can re-enter it"
        )
    }

    @Test("pump does not assign the whole pending array")
    func pumpDoesNotRebuildTheQueue() {
        let code = Self.code
        guard let begin = code.range(of: "private func pump() async {"),
              let end = code.range(of: "\n    public func queueSnapshot() async -> [QueuedRun] {")
        else {
            Issue.record("pump() not found — this test's parser needs updating, not deleting")
            return
        }
        let body = String(code[begin.upperBound..<end.lowerBound])
        #expect(
            !body.contains("pending ="),
            """
            `pump` assigns `pending` wholesale again. Every `await` in it releases \
            the actor, so the array it writes back is a view from before the \
            suspension: a run `launch` appended is dropped, and a run `drain` \
            cancelled comes back. Remove by identity instead.
            """
        )
    }
}
