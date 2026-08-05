import ElliotIPC
import ElliotModel
import ElliotStore
import Foundation
import MCP

// MARK: - Results
//
// Every tool answers in the same shape — one JSON text block, `isError` telling
// the agent whether to trust it — so an agent can parse a reply without knowing
// which tool it came from.

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

    /// Renders a response from the running app. A failure keeps the app's own
    /// code, message and hint: the helper never rewords a refusal it did not
    /// decide.
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

    private static func json(_ fields: [String: Value]) throws -> String {
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
    static let offlineNote =
        "Elliot is not running; this is a snapshot of its database. "
            + "A card held by a run still reports activeRunID, but no run is making progress "
            + "while Elliot is down, so any state other than a terminal one is frozen rather than live."

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

    /// The body of a `board_next` answer, live or offline, so the two cannot
    /// drift into describing the same ranking differently.
    static func nextFields(
        _ page: NextPage,
        source: String,
        extraNote: String?
    ) throws -> [String: Value] {
        var fields = pageFields(
            total: page.total, limit: page.limit,
            truncated: page.truncated, cappedFrom: page.limitCappedFrom
        )
        fields["items"] = try Value.encoding(page.items)
        fields["ready_count"] = .int(page.readyCount)
        fields["source"] = .string(source)
        // "Nothing is ready" is a finding, not an empty result. Said out loud so
        // an agent does not read a page of blocked cards as a page it mis-asked
        // for.
        let readiness: String? = page.readyCount == 0 && page.total > 0
            ? "Nothing on the board is ready to move; each item says what it is waiting for."
            : nil
        attachNote(
            &fields,
            extraNote,
            readiness,
            pageNote(
                shown: page.items.count, total: page.total,
                truncated: page.truncated, limit: page.limit, cappedFrom: page.limitCappedFrom
            )
        )
        return fields
    }
}

// MARK: - The board, read from a snapshot
//
// Nothing here decides or phrases anything. The candidates come from
// `nextCandidates`, the order from `rankNextSteps`, each item from
// `NextDTO(step:rank:activeRunID:)` — all three shared with the app, which
// reaches them through BoardService. This module still imports neither
// ElliotEngine nor ElliotProcess, so the helper holds no copy of the rules;
// what it shares is pure and lives below both of them. Every place a tool
// previously wrote its own version of one of the three, the two answers
// diverged.

enum OfflineBoard {
    /// Either "no filter" or one resolved repository — never a nil that means
    /// both. The live handler refuses an unknown name; the offline path has to
    /// refuse it the same way or a typo reads as the whole board.
    enum RepoFilter {
        case all
        case only(UUID)

        var repoID: UUID? {
            if case .only(let id) = self { return id }
            return nil
        }
    }

    static func filter(_ name: String?, in repos: [Repo]) throws -> RepoFilter {
        guard let name else { return .all }
        guard let match = repos.first(where: { $0.nameWithOwner == name || $0.path == name }) else {
            throw ToolFailure(
                code: ElliotErrorCode.repoNotFound.rawValue,
                message: "No registered repository matches \"\(name)\".",
                hint: "Known: \(repos.map(\.nameWithOwner).joined(separator: ", "))"
            )
        }
        return .only(match.id)
    }

    static func namesByID(_ repos: [Repo]) -> [UUID: String] {
        Dictionary(uniqueKeysWithValues: repos.map { ($0.id, $0.nameWithOwner) })
    }

    /// What `board_next` answers when Elliot is down, ranked by the same pure
    /// function the app uses.
    static func nextPage(
        store: BoardStore,
        repo: String?,
        limit: Int,
        cappedFrom: Int?
    ) async throws -> NextPage {
        let repos = try await store.repos()
        let resolved = try filter(repo, in: repos)
        let cards = try await store.cards(repoID: resolved.repoID)
        let active = try await store.activeRuns(cardIDs: cards.map(\.id))

        let steps = rankNextSteps(
            nextCandidates(cards: cards, repos: repos, activeRunIDs: active.mapValues(\.id))
        )
        let shown = Array(steps.prefix(limit))
        let items = shown.indices.map { index in
            NextDTO(
                step: shown[index],
                rank: index + 1,
                activeRunID: active[shown[index].card.id]?.id
            )
        }
        return NextPage(
            items: items,
            total: steps.count,
            limit: limit,
            readyCount: steps.filter(\.isReady).count,
            limitCappedFrom: cappedFrom
        )
    }
}
