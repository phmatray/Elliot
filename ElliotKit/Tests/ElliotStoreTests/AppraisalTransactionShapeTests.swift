import Foundation
import Testing

/// `AppraisalStoreTests.concurrentAppraisalsNeverSettleOnAMixedTriple` fires a
/// crowd of `applyAppraisal` calls at one card and checks the settled row is
/// never a mix of two calls' fields. Measured while fixing this suite: that
/// race is not capable of failing, whether or not `applyAppraisal` is
/// transactional. Splitting `applyAppraisal` into a `reader.read`, a real
/// suspension, and a separate `requireWriter().write` — and driving the
/// concurrent test against that broken version, including a variant with an
/// explicit 20ms sleep placed after the read to force every task's read to
/// land before any task's write — never produced a mixed triple, across eight
/// runs. The reason is structural, not a scheduling accident that a slower
/// machine might still hit: every call, split or not, always assembles its
/// own effort/evidence/appraisedAt into one local `Card` value before it ever
/// reaches `.update(db)`, and `.update(db)` persists that whole value in a
/// single `UPDATE` statement. Two concurrent calls can only ever race to be
/// the *last* commit — never interleave field by field — so whichever one
/// lands is, by construction, whole. A race test built on that property is
/// asserting something that was never at risk.
///
/// So the race test earns its place for a narrower reason — it is a real,
/// if weaker, guarantee that concurrent appraisal traffic cannot corrupt a
/// card into an inconsistent state — and the actual one-transaction claim
/// needs the idiom `RunSchedulerShapeTests` already uses for the same
/// situation: reading the source, and failing naming the invariant that
/// moved.
///
/// What "one transaction" cashes out to, mechanically, in this codebase: the
/// fetch and the persist happen inside the *same* `requireWriter().write`
/// closure, with no `await` between them (GRDB's `write` closure is
/// synchronous — `(Database) throws -> T` — so there is nowhere inside it for
/// another writer to interpose even if one wanted to). A version that fetches
/// through `reader.read` first and persists through a later, separate
/// `requireWriter().write` satisfies none of that, and this suite is what
/// would catch it if it came back.
@Suite("BoardStore.applyAppraisal — the shape the race test cannot see")
struct AppraisalTransactionShapeTests {

    private static let source: String = {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // ElliotStoreTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // ElliotKit
            .appendingPathComponent("Sources/ElliotStore/BoardStore.swift")
        return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }()

    /// The source with `//` line comments removed, so a doc comment describing
    /// the invariant (this file's own included) cannot trip — or satisfy — a
    /// gate that is supposed to measure code. `RunSchedulerShapeTests` carries
    /// the same guard for the same reason.
    private static let code: String = {
        source
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> String in
                guard let marker = line.range(of: "//") else { return String(line) }
                return String(line[..<marker.lowerBound])
            }
            .joined(separator: "\n")
    }()

    /// The body of `public func applyAppraisal(...) async throws -> Card? {`
    /// up to the next declaration at the same indentation.
    ///
    /// The signature spans three lines, so this anchors on the parameter list
    /// rather than the `func` keyword, and closes on the next `public func` at
    /// four-space indentation rather than balancing braces — the same choice
    /// `RunSchedulerShapeTests` makes, and for the same reason: it is exact
    /// enough for one file with a stable neighbour, and brace-balancing text
    /// this way risks miscounting a brace inside a string or a closure.
    private func applyAppraisalBody() -> String {
        let code = Self.code
        guard let begin = code.range(
            of: "cardID: UUID, effort: Effort, evidence: [Evidence], at: Date"
        ) else { return "" }
        let rest = code[begin.upperBound...]
        guard let end = rest.range(of: "\n    public func backfillCardAngles") else {
            return String(rest)
        }
        return String(rest[..<end.lowerBound])
    }

    @Test("The read and the write share one requireWriter().write closure")
    func fetchAndPersistShareOneWriteClosure() {
        let body = applyAppraisalBody()
        #expect(
            !body.isEmpty,
            "applyAppraisal's signature line moved or was reworded — this test's parser needs updating, not deleting"
        )

        // Not `reader.read` anywhere: a version that fetches through the
        // reader before ever reaching the writer has already left the
        // transaction it means to be inside.
        #expect(
            !body.contains("reader.read"),
            """
            applyAppraisal reads through `reader.read`, outside the write \
            transaction. The card it fetches can be stale by the time the write \
            lands — this is the split this suite exists to catch.
            """
        )

        guard let writeCall = body.range(of: "requireWriter().write") else {
            Issue.record("applyAppraisal no longer calls requireWriter().write — parser needs updating, not deleting")
            return
        }
        guard let fetch = body.range(of: "Card.fetchOne(") else {
            Issue.record("applyAppraisal no longer fetches the card by id — parser needs updating, not deleting")
            return
        }
        #expect(
            writeCall.lowerBound < fetch.lowerBound,
            """
            applyAppraisal fetches the card before opening the write transaction. \
            The fetch has to happen *inside* `requireWriter().write { db in ... }`, \
            not before it, or the value it mutates can already be behind the \
            database by the time it is persisted.
            """
        )

        guard let update = body.range(of: ".update(db)") else {
            Issue.record("applyAppraisal no longer calls .update(db) — parser needs updating, not deleting")
            return
        }
        let betweenFetchAndWrite = body[fetch.upperBound..<update.lowerBound]
        #expect(
            !betweenFetchAndWrite.contains("await"),
            """
            There is an `await` between the fetch and the `.update(db)` that persists \
            it. GRDB's `write` closure is synchronous precisely so nothing can suspend \
            between reading a row and writing it back — an `await` in between means the \
            two are no longer one transaction, whatever closure they are nested in.
            """
        )
    }
}
