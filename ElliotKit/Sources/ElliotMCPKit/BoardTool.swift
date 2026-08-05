import ElliotIPC
import ElliotModel
import Foundation
import MCP

/// One MCP tool: the declaration agents read, and the code that answers a call
/// to it.
///
/// A tool holds no state and reaches the board only through the bridge, which
/// is what keeps the rule engine the single decider — one file per tool makes
/// that cheap to check, since a tool that tried to do more would have to grow a
/// dependency this protocol never hands it.
protocol BoardTool: Sendable {
    /// What `tools/list` publishes. Its `name` is also the dispatch key.
    var tool: Tool { get }

    /// Answers one call. Arguments arrive exactly as the agent sent them:
    /// checking them is each tool's own job.
    ///
    /// A thrown `ToolFailure` is rendered by the dispatch as an error *result*,
    /// never as a transport failure — an agent that named a column that does
    /// not exist must read a refusal it can branch on, not a broken connection.
    ///
    /// `any BridgeProviding` and not the concrete `AppBridge`: every branch
    /// worth pinning here — an unknown repository refused, `activeRunID` filled
    /// from a snapshot, an answer said to be cut — lives on the offline path,
    /// which by definition never runs on a machine where Elliot is up. Without
    /// the existential those branches can only be reached by killing the app.
    func call(_ args: [String: Value], bridge: any BridgeProviding) async throws -> CallTool.Result
}

extension BoardTool {
    var name: String { tool.name }
}

/// A refusal with a code the agent can branch on, thrown from anywhere inside a
/// tool and rendered once by `ElliotMCPServer.call`.
///
/// Thrown rather than returned so an argument check buried in a helper does not
/// have to thread a result back out through every caller — the path where that
/// threading gets skipped is the path where a bad argument is silently
/// tolerated.
struct ToolFailure: Error {
    var code: String
    var message: String
    var hint: String?
}

// MARK: - Arguments
//
// Every decoder here has the same contract: the value the caller wrote,
// nothing, or a refusal — never a fourth answer invented to keep going. An
// argument the server quietly re-interprets produces a plausible reply to a
// question nobody asked, which is worse than an error because it gets believed.

extension [String: Value] {
    /// A column argument, or nothing — never a third answer.
    ///
    /// `column: "in-progress"` used to mean "every column", so a typo came back
    /// as a page of the whole board under `isError: false`: the request the
    /// caller made and the request the board answered were different, and
    /// nothing said so.
    func column(_ key: String) throws -> Column? {
        guard let raw = self[key], !raw.isNull else { return nil }
        guard let column = raw.stringValue.flatMap(Column.init(rawValue:)) else {
            throw ToolFailure(
                code: "bad_argument",
                message: "\(key) must be one of: "
                    + "\(Column.allCases.map(\.rawValue).joined(separator: ", "))."
            )
        }
        return column
    }

    /// A number the caller wrote, or nothing.
    ///
    /// `limit: "10"` answered with the default page is the same defect as a
    /// silent truncation. A round `10.0` is accepted because it *is* ten — that
    /// is a client's JSON formatting, not a different number.
    func integer(_ key: String) throws -> Int? {
        guard let raw = self[key], !raw.isNull else { return nil }
        if let value = raw.intValue { return value }
        if let value = raw.doubleValue, value == value.rounded(), value.magnitude < 1e15 {
            return Int(value)
        }
        throw ToolFailure(code: "bad_argument", message: "\(key) must be an integer.")
    }

    /// A page size the caller wrote, or nothing.
    ///
    /// A limit below one is refused rather than read as "you decide".
    /// Downstream it would become the default page, so `limit: remaining - seen`
    /// going negative — the arithmetic slip that produces it — would answer a
    /// hundred rows under `isError: false`, with `limit` and `truncated`
    /// describing a page nobody asked for and nothing saying the argument was
    /// discarded.
    func limit() throws -> Int? {
        guard let value = try integer("limit") else { return nil }
        guard value > 0 else {
            throw ToolFailure(
                code: "bad_argument",
                message: "limit must be at least 1. Omit it for this server's default page."
            )
        }
        return value
    }

    func uuid(_ key: String) throws -> UUID {
        guard let id = self[key]?.stringValue.flatMap(UUID.init(uuidString:)) else {
            throw ToolFailure(code: "bad_argument", message: "\(key) must be a UUID.")
        }
        return id
    }

    /// An id the caller may omit — but a malformed one is still refused.
    /// Reading `card_id: "nope"` as "no filter" would answer with every run on
    /// the board.
    func optionalUUID(_ key: String) throws -> UUID? {
        guard let raw = self[key]?.stringValue else { return nil }
        guard let id = UUID(uuidString: raw) else {
            throw ToolFailure(code: "bad_argument", message: "\(key) must be a UUID.")
        }
        return id
    }

    /// The story fields, or nothing when the caller sent none of them — so an
    /// update that only renames a card does not blank the story it never
    /// mentioned.
    func story() -> ElliotRequest.StoryInput? {
        let role = self["role"]?.stringValue ?? ""
        let want = self["want"]?.stringValue ?? ""
        let benefit = self["benefit"]?.stringValue ?? ""
        guard !role.isEmpty || !want.isEmpty || !benefit.isEmpty else { return nil }
        return .init(
            role: role, want: want, benefit: benefit,
            acceptanceCriteria: self["acceptance_criteria"]?.arrayValue?
                .compactMap(\.stringValue) ?? []
        )
    }
}
