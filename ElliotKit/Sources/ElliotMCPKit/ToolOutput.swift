import ElliotIPC
import ElliotModel
import ElliotStore
import Foundation
import MCP

// MARK: - Results
//
// Every tool answers with a JSON text block, `isError` telling the agent whether
// to trust it, so a reply can be parsed without knowing which tool it came from.
//
// ⚠️ **One JSON block, not necessarily one block.** `board_screenshot` answers
// with an image block *and* the JSON, because a description of a window is not a
// look at one. This paragraph used to claim every result was a single text
// block, and that stopped being true the moment the screenshot tool landed — a
// comment asserting a guarantee nothing provides is what #28 was filed for, so
// it is corrected here rather than left for the next reader to trust.
//
// What still holds, and what a reader can rely on: **exactly one text block, and
// it is JSON.** `ScreenshotTool` builds its own result for that reason — the
// constructors below are the single-block path.

extension CallTool.Result {
    /// Throws rather than degrading. A tool result that failed to serialise used
    /// to reach the agent as `{}` with `isError: false` — a valid-looking empty
    /// answer, which is worse than an error because it gets believed. The throw
    /// is caught once, in `ElliotMCPServer.call`, and rendered as
    /// `internal_error`.
    static func ok(_ fields: [String: Value]) throws -> CallTool.Result {
        let text = try json(fields)
        return CallTool.Result(
            content: [.text(text: text, annotations: nil, _meta: nil)],
            isError: false
        )
    }

    /// The one non-throwing constructor, on purpose: this is the last stop,
    /// including for a failure to encode. Strings only, so the encode below
    /// cannot realistically fail — and if it somehow does, the constant still
    /// carries `isError`.
    static func failure(code: String, message: String, hint: String? = nil) -> CallTool.Result {
        var fields = ["error": code, "message": message]
        if let hint { fields["hint"] = hint }
        let text = (try? WireCodec.encoder.encode(fields))
            .flatMap { String(data: $0, encoding: .utf8) }
            ?? #"{"error":"internal_error","message":"Elliot could not serialise its own error."}"#
        return CallTool.Result(
            content: [.text(text: text, annotations: nil, _meta: nil)],
            isError: true
        )
    }

    /// Renders a read, and says where the answer came from.
    ///
    /// This is the one place `source` is set and the one place the snapshot
    /// sentence is attached, so a tool contributes only the fields that are its
    /// own and cannot label a snapshot `live` by forgetting a line. Before it,
    /// each read tool wrote both by hand on each of its two branches.
    ///
    /// The snapshot note is **prepended** to whatever note the body already set,
    /// never assigned over it: `board_list_cards` and `board_list_runs` attach a
    /// page note too, and an implementation that assigned would drop "Showing 2
    /// of 5" while every other tool went on looking correct. It goes first
    /// because it qualifies everything after it.
    static func render(
        _ outcome: BridgeOutcome,
        _ body: (ElliotPayload) throws -> [String: Value]?
    ) throws -> CallTool.Result {
        try render(outcome.response) { payload in
            guard var fields = try body(payload) else { return nil }
            fields["source"] = .string(outcome.source)
            if let reason = outcome.snapshotReason {
                var note = ToolOutput.offlineNote(reason)
                if let own = fields["note"]?.stringValue { note += " " + own }
                fields["note"] = .string(note)
            }
            return fields
        }
    }

    /// Renders a response from the running app. A failure keeps the app's own
    /// code, message and hint: the helper never rewords a refusal it did not
    /// decide.
    ///
    /// Still here for the write tools, which have one path by construction —
    /// a write never falls back, so there is no source to report.
    static func render(
        _ response: ElliotResponse,
        _ body: (ElliotPayload) throws -> [String: Value]?
    ) throws -> CallTool.Result {
        switch response {
        case .failure(let code, let message, let hint):
            return .failure(code: code.rawValue, message: message, hint: hint)
        case .ok(let payload):
            guard let fields = try body(payload) else {
                return .failure(
                    code: "internal_error",
                    message: "Elliot answered with a payload this tool does not know how to read.",
                    hint: "The app and this helper are probably different builds."
                )
            }
            return try ok(fields)
        }
    }

    /// Internal rather than private: `ScreenshotTool` assembles a two-block
    /// result and still has to encode its JSON block the same way, through the
    /// wire codec, so dates and numbers read identically across the surface.
    static func json(_ fields: [String: Value]) throws -> String {
        let data = try WireCodec.encoder.encode(Value.object(fields))
        guard let text = String(data: data, encoding: .utf8) else {
            throw ToolFailure(code: "internal_error", message: "Tool result was not valid UTF-8.")
        }
        return text
    }
}

extension Value {
    /// A wire DTO as an MCP value, through the wire codec — so what an agent
    /// reads over MCP is byte-for-byte what the IPC socket carries, dates
    /// included. A bare `JSONEncoder` would send a run whose `startedAt` is a
    /// float since 2001, which is a date no model reads correctly.
    ///
    /// Throws rather than answering `.null`: a field that silently became null
    /// shipped under `isError: false` and read as "this card has no story".
    static func encoding(_ value: some Encodable) throws -> Value {
        let data = try WireCodec.encoder.encode(value)
        return try WireCodec.decoder.decode(Value.self, from: data)
    }
}

// MARK: - Paging and notes
//
// A cut answer and a complete one must not look alike, and neither must a limit
// the caller asked for and a limit the server imposed. These live here rather
// than in each tool so two tools cannot describe the same truncation with two
// different words.

enum ToolOutput {
    /// Why this answer is a snapshot, in the caller's terms.
    ///
    /// Takes the reason rather than assuming one: the fallback is reached both
    /// when Elliot is down and when it is up but did not answer, and the second
    /// case told as the first costs an agent a pointless launch and hides a
    /// failing socket.
    static func offlineNote(_ reason: SnapshotReason) -> String {
        let opening = switch reason {
        case .appNotRunning:
            "Elliot is not running; this is a snapshot of its database. "
        case .appUnreachable:
            "Elliot is running but did not answer this request; this is a snapshot of its database. "
        }
        return opening
            + "A card held by a run still reports activeRunID, but no run is making progress "
            + "while Elliot is unreachable, so any state other than a terminal one is frozen "
            + "rather than live."
    }

    static func pageFields(
        total: Int,
        limit: Int,
        truncated: Bool,
        cappedFrom: Int?
    ) -> [String: Value] {
        var fields: [String: Value] = [
            "total": .int(total),
            "limit": .int(limit),
            "truncated": .bool(truncated),
        ]
        if let cappedFrom { fields["limit_capped_from"] = .int(cappedFrom) }
        return fields
    }

    static func pageNote(
        shown: Int,
        total: Int,
        truncated: Bool,
        limit: Int,
        cappedFrom: Int?
    ) -> String? {
        var parts: [String] = []
        if truncated {
            parts.append(
                "Showing \(shown) of \(total); the rest were left out. "
                    + "Narrow by repo or column rather than asking for more."
            )
        }
        if let cappedFrom {
            parts.append("You asked for \(cappedFrom); this server sends at most \(limit).")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    /// Joins the notes a tool wants to attach, and attaches nothing when there
    /// is nothing to say — an empty `note` key would read as a finding.
    static func attachNote(_ fields: inout [String: Value], _ parts: String?...) {
        let text = parts.compactMap { $0 }.joined(separator: " ")
        if !text.isEmpty { fields["note"] = .string(text) }
    }

    /// The body of a proposal decision, for both `board_accept_proposals` and
    /// `board_reject_proposals`.
    ///
    /// Shared for the same reason the page fields are: `decided` and `skipped`
    /// mean one thing, and two tools phrasing the same split differently would
    /// leave an agent unable to tell whether accept and reject disagree about
    /// what happened or merely about how to say it. The summary itself comes
    /// from the app, which is the only side that knows which claims it won.
    static func decisionFields(_ decision: DecisionDTO) throws -> [String: Value] {
        var fields: [String: Value] = [
            "decided": .array(decision.decided.map { .string($0.uuidString) }),
            "summary": .string(decision.summary),
        ]
        // Omitted when empty rather than sent as `[]`: an empty list reads as a
        // finding — "these were skipped" — when there was nothing to report.
        if !decision.skipped.isEmpty {
            fields["skipped"] = .array(decision.skipped.map { .string($0.uuidString) })
        }
        if !decision.cards.isEmpty {
            fields["cards"] = try Value.encoding(decision.cards)
        }
        return fields
    }

    /// The proposal ids a decision tool was given, refusing anything that is not
    /// a UUID rather than dropping it.
    ///
    /// Silently skipping a malformed id would answer "decided 2 of 3" with no
    /// hint that the third was never a valid id in the first place — the caller
    /// reads that as a lost race and retries forever.
    static func proposalIDs(_ args: [String: Value]) throws -> [UUID] {
        let raw = args["proposal_ids"]?.arrayValue ?? []
        guard !raw.isEmpty else {
            throw ToolFailure(
                code: "bad_argument",
                message: "proposal_ids must contain at least one proposal UUID."
            )
        }
        return try raw.map { value in
            guard let id = value.stringValue.flatMap(UUID.init(uuidString:)) else {
                throw ToolFailure(
                    code: "bad_argument",
                    message: "proposal_ids must all be UUIDs.",
                    hint: "board_list_proposals returns the ids to use here."
                )
            }
            return id
        }
    }

    /// The body of a `board_next` answer, live or offline, so the two cannot
    /// drift into describing the same ranking differently.
    ///
    /// It took a `source` and an `extraNote` while the tool had two branches to
    /// tell apart. `render` sets both from the outcome now, for every tool, so
    /// what is left here is only what is particular to a ranked page.
    static func nextFields(_ page: NextPage) throws -> [String: Value] {
        var fields = pageFields(
            total: page.total, limit: page.limit,
            truncated: page.truncated, cappedFrom: page.limitCappedFrom
        )
        fields["items"] = try Value.encoding(page.items)
        fields["ready_count"] = .int(page.readyCount)
        // "Nothing is ready" is a finding, not an empty result. Said out loud so
        // an agent does not read a page of blocked cards as a page it mis-asked
        // for.
        let readiness: String? = page.readyCount == 0 && page.total > 0
            ? "Nothing on the board is ready to move; each item says what it is waiting for."
            : nil
        attachNote(
            &fields,
            readiness,
            pageNote(
                shown: page.items.count, total: page.total,
                truncated: page.truncated, limit: page.limit, cappedFrom: page.limitCappedFrom
            )
        )
        return fields
    }
}
