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

    /// The body of `private func pump() async {` up to the next declaration.
    private func pumpBody() -> String {
        let code = Self.code
        guard let begin = code.range(of: "private func pump() async {"),
              let end = code.range(of: "\n    public func queueSnapshot() async -> [QueuedRun] {")
        else { return "" }
        return String(code[begin.upperBound..<end.lowerBound])
    }

    /// A containment check *before* the read is a shortcut; the one that carries
    /// the invariant has to sit after it. `drain` and `cancel` both take their id
    /// out of `pending` synchronously and only then suspend to mark the row
    /// `.cancelled`, so a pump whose read landed in that window resumes holding a
    /// stale `.queued` value.
    ///
    /// This is the deterministic half, for the same reason Task 5 exists at all:
    /// the behavioural evidence destroys itself. If the defect fires, `start`
    /// saves `.running` over the `.cancelled` row, so the very state a test would
    /// assert on is gone by the time it could look.
    @Test("pump re-checks the queue after the read that suspends it")
    func pumpRechecksContainmentAfterTheRead() {
        let body = pumpBody()
        #expect(!body.isEmpty, "pump() not found — this test's parser needs updating, not deleting")
        guard let read = body.range(of: "await store.run(") else {
            Issue.record("pump no longer reads the run — parser needs updating, not deleting")
            return
        }
        #expect(
            body[read.upperBound...].contains("pending.contains(runID)"),
            """
            `pump` decides on a run without re-checking that it is still in the \
            queue after the read that suspended it. `drain` and `cancel` remove \
            their id from `pending` and only then suspend to mark the row \
            `.cancelled`, so this pump can be holding a stale `.queued` value — \
            starting it spawns a `claude` for a run the user just discarded, and \
            `start` then writes `.running` over the `.cancelled` row so the \
            cancellation disappears too. For `merge-pr` that is a merge to `main` \
            after being told to stop.
            """
        )
    }

    @Test("pump does not assign the whole pending array")
    func pumpDoesNotRebuildTheQueue() {
        let body = pumpBody()
        #expect(!body.isEmpty, "pump() not found — this test's parser needs updating, not deleting")
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
