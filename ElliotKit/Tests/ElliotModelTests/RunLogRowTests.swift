import Foundation
import Testing

@testable import ElliotModel

/// Fixtures live at the repository root, not in a resource bundle: the same
/// files are replayed by hand through `Scripts/fake-claude.sh` when reproducing
/// a run that rendered badly.
private enum FixturePaths {
    static let root: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // ElliotModelTests
        .deletingLastPathComponent()   // Tests
        .deletingLastPathComponent()   // ElliotKit
        .deletingLastPathComponent()   // repo root

    static func streamJSON(_ name: String) -> Data {
        (try? Data(contentsOf: root.appendingPathComponent("Fixtures/stream-json/\(name)"))) ?? Data()
    }
}

/// Decodes a whole fixture the way the runner does: line by line, through
/// `StreamEventDecoder`.
///
/// The classifier is never fed hand-built `StreamEvent` values. Hand-building
/// them would let the fold agree with a decoder that never ran, and the two
/// would drift the first time the wire format moved.
private func events(_ fixture: String) -> [StreamEvent] {
    let data = FixturePaths.streamJSON(fixture)
    return data
        .split(separator: 0x0A, omittingEmptySubsequences: false)
        .flatMap { StreamEventDecoder.decodeAll(line: Data($0)) }
}

// MARK: - Reading rows back

private func toolRows(_ rows: [RunLogRow]) -> [(name: String, id: String, outcome: ToolOutcome?)] {
    rows.compactMap {
        guard case .toolUse(let name, let id, _, let outcome) = $0 else { return nil }
        return (name, id, outcome)
    }
}

private func outcome(of id: String, in rows: [RunLogRow]) -> ToolOutcome?? {
    toolRows(rows).first { $0.id == id }.map { $0.outcome }
}

private func orphans(_ rows: [RunLogRow]) -> [ToolOutcome] {
    rows.compactMap {
        guard case .orphanResult(let outcome) = $0 else { return nil }
        return outcome
    }
}

private func kinds(_ rows: [RunLogRow]) -> [String] {
    rows.map {
        switch $0 {
        case .session: "session"
        case .agentText: "text"
        case .toolUse: "tool"
        case .denial: "denial"
        case .orphanResult: "orphan"
        case .terminal: "terminal"
        case .unreadable: "unreadable"
        }
    }
}

@Suite("run log rows")
struct RunLogRowTests {

    // MARK: The fixtures are actually being read

    @Test("Every fixture decodes to a non-empty stream")
    func fixturesLoad() {
        for name in ["interleaved-tools", "orphan-result", "failing-tool", "garbage-line"] {
            let decoded = events("\(name).ndjson")
            #expect(!decoded.isEmpty, "Fixtures/stream-json/\(name).ndjson decoded to nothing")
        }
    }

    // MARK: The log is a tree

    @Test("A result folds onto its tool use by id, not by arrival order")
    func resultsFoldByID() {
        // Two Reads are issued in one assistant turn, and the fixture returns
        // tu_b's result *before* tu_a's. Arrival order would swap the two.
        let decoded = events("interleaved-tools.ndjson")
        let calls = decoded.compactMap { event -> String? in
            if case .assistantToolUse(_, let id, _) = event { return id }
            return nil
        }
        let results = decoded.compactMap { event -> String? in
            if case .toolResult(let id, _, _) = event { return id }
            return nil
        }
        // The premise of this test, asserted rather than assumed.
        #expect(calls == ["tu_a", "tu_b", "tu_c"])
        #expect(results == ["tu_b", "tu_a"])

        let rows = RunLog.rows(from: decoded)
        #expect(outcome(of: "tu_a", in: rows)??.preview == "contents of A")
        #expect(outcome(of: "tu_b", in: rows)??.preview == "contents of B")
        #expect(orphans(rows).isEmpty)
    }

    @Test("A tool use with no result yet is still in flight")
    func toolUseWithoutResult() {
        let rows = RunLog.rows(from: events("interleaved-tools.ndjson"))
        let flight = toolRows(rows).first { $0.id == "tu_c" }
        #expect(flight?.name == "Bash")
        #expect(flight?.outcome == nil)
        // …and it is not mistaken for a failure.
        #expect(RunLog.filter(rows, by: .errors).isEmpty)
    }

    @Test("A result whose tool use never arrived becomes its own row")
    func orphanResultGetsARow() {
        let rows = RunLog.rows(from: events("orphan-result.ndjson"))
        let stray = orphans(rows)
        #expect(stray.count == 2)
        #expect(stray.first?.isError == false)
        #expect(stray.first?.preview == "resumed from an earlier session")
        #expect(stray.last?.isError == true)
        // Dropping it would have left a shorter log that looked complete.
        #expect(toolRows(rows).isEmpty)
        #expect(kinds(rows) == ["session", "orphan", "text", "orphan", "terminal"])
    }

    @Test("A tool use ordering survives the fold")
    func rowOrderFollowsTheStream() {
        let rows = RunLog.rows(from: events("interleaved-tools.ndjson"))
        #expect(kinds(rows) == ["session", "text", "tool", "tool", "tool", "terminal"])
        #expect(toolRows(rows).map(\.id) == ["tu_a", "tu_b", "tu_c"])
    }

    // MARK: What survives the fold, and what does not

    @Test("system and partial lines are dropped; garbage survives as unreadable")
    func unreadableLinesSurvive() {
        let decoded = events("garbage-line.ndjson")
        // The fixture really does contain the four line kinds this asserts on.
        #expect(decoded.contains { if case .system = $0 { true } else { false } })
        #expect(decoded.contains { if case .partial = $0 { true } else { false } })
        #expect(decoded.contains { if case .malformed = $0 { true } else { false } })
        #expect(decoded.contains { if case .unknown = $0 { true } else { false } })

        let rows = RunLog.rows(from: decoded)
        #expect(kinds(rows) == ["session", "unreadable", "unreadable", "text", "terminal"])

        let texts = rows.compactMap { row -> String? in
            guard case .unreadable(let text) = row else { return nil }
            return text
        }
        #expect(texts.first == "this line is not JSON at all")
        #expect(texts.last?.contains("telemetry_v2") == true)
    }

    @Test("Denials are synthesised, and land before the terminal row")
    func denialsAreSynthesised() {
        let decoded = events("failing-tool.ndjson")
        // Nothing in the stream decodes to a denial — the row can only come
        // from the run.
        #expect(RunLog.rows(from: decoded).allSatisfy { if case .denial = $0 { false } else { true } })

        let rows = RunLog.rows(from: decoded, denials: ["WebFetch"])
        #expect(kinds(rows) == ["session", "text", "tool", "tool", "denial", "terminal"])
    }

    @Test("Denials still appear when the run has no terminal row")
    func denialsWithoutATerminalRow() {
        let truncated = events("failing-tool.ndjson").filter {
            if case .result = $0 { return false }
            return true
        }
        let rows = RunLog.rows(from: truncated, denials: ["WebFetch", "Bash"])
        #expect(kinds(rows) == ["session", "text", "tool", "tool", "denial", "denial"])
    }

    // MARK: Filters

    @Test("The tools filter keeps tool rows and nothing else")
    func toolsFilter() {
        let rows = RunLog.rows(from: events("failing-tool.ndjson"), denials: ["WebFetch"])
        #expect(kinds(RunLog.filter(rows, by: .tools)) == ["tool", "tool"])
        #expect(RunLog.filter(rows, by: .all).count == rows.count)
    }

    @Test("The errors filter admits failures, denials and an unclean terminal — and nothing else")
    func errorsFilterAdmitsExactlyTheFourKinds() {
        let rows = RunLog.rows(from: events("failing-tool.ndjson"), denials: ["WebFetch"])
        let errors = RunLog.filter(rows, by: .errors)

        // The inclusion…
        #expect(kinds(errors) == ["tool", "denial", "terminal"])
        #expect(toolRows(errors).map(\.id) == ["tu_test"])
        if case .terminal(let result) = errors.last {
            // Not clean because a tool was refused, even though is_error is
            // false — exactly the run this app refuses to call green.
            #expect(!result.isClean)
            #expect(!result.isError)
        } else {
            Issue.record("expected the terminal row to survive the errors filter")
        }

        // …and the exclusion, which is the half that is easy to leave untested.
        #expect(!kinds(errors).contains("session"))
        #expect(!kinds(errors).contains("text"))
        #expect(!toolRows(errors).map(\.id).contains("tu_build"))   // it succeeded
        #expect(!kinds(RunLog.filter(RunLog.rows(from: events("garbage-line.ndjson")), by: .errors))
            .contains("unreadable"))
    }

    @Test("The errors filter admits an orphan result that errored, and only that one")
    func errorsFilterAndOrphans() {
        let rows = RunLog.rows(from: events("orphan-result.ndjson"))
        let errors = RunLog.filter(rows, by: .errors)
        #expect(kinds(errors) == ["orphan"])
        #expect(orphans(errors).count == 1)
        #expect(orphans(errors).first?.isError == true)
        #expect(orphans(errors).first?.preview == "the earlier tool call is not in this log")
    }

    @Test("A clean terminal row is not an error")
    func cleanTerminalIsNotAnError() {
        let rows = RunLog.rows(from: events("interleaved-tools.ndjson"))
        #expect(kinds(rows).contains("terminal"))
        #expect(RunLog.filter(rows, by: .errors).isEmpty)
    }

    // MARK: Row identity

    @Test("Rows carry distinct identities")
    func rowIdentity() {
        let rows = RunLog.rows(from: events("failing-tool.ndjson"), denials: ["WebFetch"])
        #expect(Set(rows.map(\.id)).count == rows.count)
        // The identity of a tool row is anchored on the tool_use id, so a
        // result arriving later does not renumber the row under the cursor.
        let before = RunLog.rows(from: events("interleaved-tools.ndjson").filter {
            if case .toolResult = $0 { return false }
            return true
        })
        let after = RunLog.rows(from: events("interleaved-tools.ndjson"))
        let idOf = { (rows: [RunLogRow]) in
            rows.first { if case .toolUse(_, "tu_a", _, _) = $0 { true } else { false } }?.id
        }
        #expect(idOf(before) != nil)
        #expect(idOf(before) == idOf(after))
    }

    // MARK: The claim and the fact

    /// A run whose `resultText` claims a number while `gh` established nothing.
    private func claimingRun(_ outcome: VerifiedOutcome?) -> SkillRun {
        SkillRun.card(
            cardID: UUID(),
            repoID: UUID(),
            kind: .createIssue,
            prompt: "story",
            cwd: "/repo",
            state: .succeeded,
            logPath: "/tmp/run.ndjson",
            stderrPath: "/tmp/run.err",
            resultText: "Filed issue #47",
            verifiedOutcome: outcome,
            createdAt: Date(timeIntervalSince1970: 0)
        )
    }

    @Test("An agent's claim of '#47' cannot reach the gh side")
    func proseNeverLeaksIntoTheFact() {
        let verdict = RunVerdict.of(claimingRun(.unverified(reason: "no issue URL in the log")))

        #expect(verdict.itSaid == "Filed issue #47")
        #expect(verdict.ghSays == "Unverified — no issue URL in the log")
        // The assertion this whole type exists for: whatever the agent wrote,
        // no digit of it appears on the side that reports what `gh` found.
        #expect(verdict.ghSays?.contains(where: \.isNumber) == false)
    }

    @Test("The gh side carries the number when gh is the one that found it")
    func factSideCarriesVerifiedNumbers() {
        let verdict = RunVerdict.of(
            claimingRun(.issueCreated(number: 61, url: "https://github.com/phmatray/Elliot/issues/61"))
        )
        // Same claim as above, and now the fact side says 61 — because the
        // outcome says so, not because the prose does.
        #expect(verdict.itSaid == "Filed issue #47")
        #expect(verdict.ghSays == "Opened issue #61")
    }

    @Test("A run gh never verified has no fact side at all")
    func noOutcomeMeansNoFact() {
        let verdict = RunVerdict.of(claimingRun(nil))
        #expect(verdict.itSaid == "Filed issue #47")
        #expect(verdict.ghSays == nil)
    }

    @Test("A run that said nothing has no claim side")
    func emptyProseIsNoClaim() {
        var run = claimingRun(.closedUnmerged)
        run.resultText = "   \n "
        #expect(RunVerdict.of(run).itSaid == nil)
        run.resultText = nil
        #expect(RunVerdict.of(run).itSaid == nil)
        #expect(RunVerdict.of(run).ghSays == "Closed without merging")
    }

    @Test("Every outcome renders one receipt line")
    func receiptTextCoversEveryOutcome() {
        let cases: [(VerifiedOutcome, String)] = [
            (.issueCreated(number: 47, url: "u"), "Opened issue #47"),
            (.noIssueCreated(reason: "already covered by #12"), "No issue — already covered by #12"),
            (.prOpen(number: 72, url: "u", isDraft: true, branch: "feat/72-x"), "Draft PR 72 on feat/72-x"),
            (.prOpen(number: 72, url: "u", isDraft: false, branch: "feat/72-x"), "PR 72 on feat/72-x"),
            (.merged(commitSHA: "0123456789abcdef"), "Merged as 0123456"),
            (.merged(commitSHA: nil), "Merged"),
            (.notMerged(reason: "CI is red"), "Not merged — CI is red"),
            (.closedUnmerged, "Closed without merging"),
            (.unverified(reason: "no PR in the log"), "Unverified — no PR in the log"),
        ]
        for (outcome, expected) in cases {
            #expect(outcome.receiptText == expected)
        }
    }
}
