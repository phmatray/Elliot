import ElliotIPC
import ElliotModel
import ElliotStore
import Foundation
import MCP

/// The MCP face of the board.
///
/// Every mutating tool goes through `BoardService` in the running app, so an
/// agent moving a card and a person dragging one are the same act, decided by
/// the same rule engine. This type holds no rules of its own: it publishes the
/// tools in `Tools/` and routes calls to them. The single piece of judgement
/// the layer is allowed — ranking what to do next — is `rankNextSteps`, which
/// is pure and lives in `ElliotModel` where the app reads it from too.
public struct ElliotMCPServer: Sendable {
    private let bridge: any BridgeProviding

    /// Takes the protocol, not `AppBridge`, so the tools can be driven by a
    /// double. The default keeps `ElliotMCPServer()` meaning what it always did.
    public init(bridge: any BridgeProviding = AppBridge()) {
        self.bridge = bridge
    }

    /// Every tool the helper serves. Adding one is adding a file and a line
    /// here — the list and the dispatch table cannot drift apart, because the
    /// second is derived from the first.
    ///
    /// Ordered as a model should reach for them: the question first, the
    /// inventory next, then the acts.
    private static let registry: [any BoardTool] = [
        NextTool(),
        ListCardsTool(),
        GetCardTool(),
        ListReposTool(),
        CreateCardTool(),
        UpdateCardTool(),
        MoveCardTool(),
        ListRunsTool(),
        AwaitRunTool(),
        CancelRunTool(),
        AnalyzeRepoTool(),
        ListProposalsTool(),
        AcceptProposalsTool(),
        RejectProposalsTool(),
    ]

    public static let tools: [Tool] = registry.map(\.tool)

    /// `uniqueKeysWithValues` on purpose: two tools claiming one name should
    /// stop the helper, not shadow one of them into being unreachable.
    ///
    /// It stops it at the first *use* of this static, though — the first
    /// tools/list or tools/call, so startup in practice. This comment used to
    /// say "build time", which is a guarantee nothing here provides; a comment
    /// claiming one becomes the evidence every later reader relies on. What
    /// does catch a duplicate before startup is
    /// `ToolSurfaceTests.toolNamesAreUnique`, which asserts these same names
    /// are distinct without ever touching this dictionary.
    private static let byName: [String: any BoardTool] = Dictionary(
        uniqueKeysWithValues: registry.map { ($0.name, $0) }
    )

    // MARK: - Dispatch

    public func call(name: String, arguments: [String: Value]?) async -> CallTool.Result {
        guard let tool = Self.byName[name] else {
            return .failure(code: "unknown_tool", message: "No such tool: \(name)")
        }
        do {
            return try await tool.call(arguments ?? [:], bridge: bridge)
        } catch let failure as ToolFailure {
            return .failure(code: failure.code, message: failure.message, hint: failure.hint)
        } catch {
            // Catches a failure to serialise the answer too. That used to reach
            // the agent as `{}` under `isError: false` — a valid-looking empty
            // answer, which is worse than an error because it gets believed.
            return .failure(code: "internal_error", message: error.localizedDescription)
        }
    }
}

// MARK: - Resources

public extension ElliotMCPServer {
    /// `elliot://run/{id}/log` — the durable NDJSON transcript of one run.
    ///
    /// The path is derived from the run id rather than read from
    /// `RunDTO.logPath`, which is what lets a log be fetched without first
    /// resolving the run. That is the same bargain `StoreLocation` already
    /// strikes for the database and the socket: two processes agree on a path by
    /// computing it, never by passing it. `BoardService` writes exactly
    /// `StoreLocation.runLogURL(runID:)`, and if that ever stops being true this
    /// resource reads the wrong file in silence.
    static let runLogScheme = "elliot://run/"
    static let cardScheme = "elliot://card/"

    /// A run can emit tens of megabytes. Past this we serve the tail, on a line
    /// boundary so it is still NDJSON, and say so in `_meta`. When one event is
    /// longer than the tail there is no boundary to find, and `_meta` says that
    /// too — `line_boundary: false`.
    static let logTailLimit = 256 * 1024

    static var resourceTemplates: [Resource.Template] {
        [
            Resource.Template(
                uriTemplate: "elliot://run/{id}/log",
                name: "run-log",
                title: "Run log (NDJSON)",
                description: """
                    Everything one skill run emitted: NDJSON, one Claude Code stream-json \
                    event per line, exactly as the CLI wrote it. This is the durable record \
                    — the live UI stream is bounded and may drop lines, this never does. \
                    Read it when a run failed and `verifiedOutcome` does not explain why. \
                    Large logs are served tail-first; `_meta.truncated` says when that \
                    happened. `{id}` is a run UUID, as returned by board_move_card or \
                    board_list_runs.
                    """,
                mimeType: "application/x-ndjson"
            ),
            Resource.Template(
                uriTemplate: "elliot://card/{id}",
                name: "card",
                title: "Board card",
                description: """
                    One board card as JSON — the same shape board_get_card returns, story, \
                    issue, pull request and holding run included. Useful for pinning a card \
                    into context and re-reading it later.
                    """,
                mimeType: "application/json"
            ),
        ]
    }

    /// Lists the logs that exist right now, most recent run first.
    ///
    /// Bounded on purpose. Cards are not listed here: `elliot://card/{id}` is a
    /// template, and enumerating the board as resources would only duplicate
    /// board_list_cards with a worse shape.
    func listResources() async throws -> ListResources.Result {
        let runs: [RunDTO]
        switch await bridge.read(.listRuns(cardID: nil, limit: ElliotPaging.runLimitDefault)) {
        case .live(let response):
            switch response {
            case .ok(.runs(let page)):
                runs = page.runs
            // An empty list here would read as "there are no logs", which is a
            // different statement from "I could not find out".
            case .failure(let code, let message, _):
                throw MCPError.internalError("Elliot refused the run list (\(code.rawValue)): \(message)")
            default:
                throw MCPError.internalError("Elliot answered listRuns with an unexpected payload.")
            }
        case .offline(let store, _):
            runs = try await store.runs(limit: ElliotPaging.runLimitDefault).map { RunDTO(run: $0) }
        }
        return ListResources.Result(resources: runs.map(Self.logResource))
    }

    func readResource(uri: String) async throws -> ReadResource.Result {
        if let id = Self.runID(fromLogURI: uri) {
            return ReadResource.Result(contents: [try Self.readRunLog(id: id, uri: uri)])
        }
        if let id = Self.cardID(fromURI: uri) {
            return ReadResource.Result(contents: [try await readCard(id: id, uri: uri)])
        }
        throw MCPError.invalidParams(
            "Unknown resource \"\(uri)\". Elliot serves elliot://run/{id}/log and elliot://card/{id}."
        )
    }

    private static func logResource(_ run: RunDTO) -> Resource {
        Resource(
            name: run.id.uuidString,
            uri: "\(runLogScheme)\(run.id.uuidString)/log",
            title: "\(run.kind) · \(run.state)",
            description: "NDJSON transcript of the \(run.kind) run started for card \(run.cardID).",
            mimeType: "application/x-ndjson"
        )
    }

    private static func runID(fromLogURI uri: String) -> UUID? {
        guard uri.hasPrefix(runLogScheme), uri.hasSuffix("/log") else { return nil }
        let middle = uri.dropFirst(runLogScheme.count).dropLast("/log".count)
        return UUID(uuidString: String(middle))
    }

    private static func cardID(fromURI uri: String) -> UUID? {
        guard uri.hasPrefix(cardScheme) else { return nil }
        return UUID(uuidString: String(uri.dropFirst(cardScheme.count)))
    }

    private static func readRunLog(id: UUID, uri: String) throws -> Resource.Content {
        let url = StoreLocation.runLogURL(runID: id)
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else {
            throw MCPError.invalidParams(
                "No log file for run \(id). Either the run id is wrong, or the run was queued "
                    + "and has not emitted anything yet."
            )
        }

        let truncated = data.count > logTailLimit
        var slice = truncated ? data.suffix(logTailLimit) : data
        // Start on a line boundary, or the first record is half an event and the
        // whole thing stops being NDJSON.
        var onLineBoundary = true
        if truncated {
            if let newline = slice.firstIndex(of: 0x0A) {
                slice = slice[slice.index(after: newline)...]
            } else {
                // One event longer than the whole tail — a large file read, a
                // long tool result. There is no boundary to start on, so the
                // fragment is served and said to be a fragment: an agent told
                // only `truncated` would read a JSON parse error on line 1 as a
                // corrupt log rather than a clipped one.
                onLineBoundary = false
            }
        }
        let text = String(decoding: slice, as: UTF8.self)

        return .text(
            text,
            uri: uri,
            mimeType: "application/x-ndjson",
            _meta: Metadata(additionalFields: [
                "truncated": .bool(truncated),
                "line_boundary": .bool(onLineBoundary),
                "total_bytes": .int(data.count),
                "served_bytes": .int(slice.count),
            ])
        )
    }

    private func readCard(id: UUID, uri: String) async throws -> Resource.Content {
        let dto: CardDTO
        switch await bridge.read(.getCard(id: id)) {
        case .live(let response):
            switch response {
            case .ok(.card(let card)):
                dto = card
            case .failure(_, let message, _):
                throw MCPError.invalidParams(message)
            default:
                throw MCPError.internalError("Elliot answered getCard with an unexpected payload.")
            }
        case .offline(let store, _):
            guard let card = try await store.card(id: id) else {
                throw MCPError.invalidParams("No card with id \(id).")
            }
            let repoName = try await store.repo(id: card.repoID)?.nameWithOwner ?? "?"
            let activeRunID = try await store.activeRun(cardID: id)?.id
            dto = CardDTO(card: card, repoName: repoName, activeRunID: activeRunID)
        }
        let data = try WireCodec.encoder.encode(dto)
        return .text(String(decoding: data, as: UTF8.self), uri: uri, mimeType: "application/json")
    }
}

// MARK: - Wiring

public extension ElliotMCPServer {
    /// What the client is told about this server before it reads a single tool.
    ///
    /// Both versions, on purpose. `version` is the build that is answering and
    /// is what a bug report needs; the wire number is what explains a
    /// `protocol_mismatch` when a stale helper meets a newer app.
    static var instructions: String {
        """
        Elliot drives GitHub work from a five-column board: backlog → todo → inProgress → \
        inReview → done. Moving a card is the act of execution — three of those transitions \
        start an unattended Claude Code agent inside a real checkout on this machine, and \
        one of them merges to a default branch on github.com.

        Start with board_next: it says which card to act on and what moving it would run. \
        Judge every run by `verifiedOutcome`, which is what `gh` established, never by the \
        agent's own prose in `resultText`.

        Helper build \(ElliotBuild.version), wire protocol \(elliotProtocolVersion).
        """
    }

    /// Builds the MCP server and attaches the handlers.
    ///
    /// `ElliotBuild.version` and not a literal: a hardcoded "1.0.0" made every
    /// build of the helper indistinguishable from every other, so a client
    /// talking to a stale helper had nothing it could report.
    func makeServer() async -> Server {
        let server = Server(
            name: "elliot",
            version: ElliotBuild.version,
            instructions: Self.instructions,
            capabilities: .init(
                // No subscriptions: a run log grows continuously and a
                // notification per line would be a firehose nobody asked for.
                resources: .init(subscribe: false, listChanged: false),
                tools: .init(listChanged: false)
            )
        )
        await server.withMethodHandler(ListTools.self) { _ in
            ListTools.Result(tools: Self.tools)
        }
        await server.withMethodHandler(CallTool.self) { params in
            await call(name: params.name, arguments: params.arguments)
        }
        await server.withMethodHandler(ListResources.self) { _ in
            try await listResources()
        }
        await server.withMethodHandler(ListResourceTemplates.self) { _ in
            ListResourceTemplates.Result(templates: Self.resourceTemplates)
        }
        await server.withMethodHandler(ReadResource.self) { params in
            try await readResource(uri: params.uri)
        }
        return server
    }
}
