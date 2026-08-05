import ElliotIPC
import ElliotModel
import ElliotStore
import Foundation
import MCP

/// The MCP face of the board.
///
/// Every mutating tool goes through `BoardService` in the running app, so an
/// agent moving a card and a person dragging one are the same act, decided by
/// the same rule engine. This type holds no rules of its own.
public struct ElliotMCPServer: Sendable {
    private let bridge: AppBridge

    public init(bridge: AppBridge = AppBridge()) {
        self.bridge = bridge
    }

    public static let tools: [Tool] = [
        Tool(
            name: "board_list_cards",
            description: """
                List Elliot board cards. Optionally filter by repository \
                (owner/name) and by column (backlog, todo, inProgress, inReview, done). \
                Returns each card's issue and pull-request numbers when it has them.
                """,
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "repo": .object([
                        "type": .string("string"),
                        "description": .string("Repository as owner/name. Omit for all repositories."),
                    ]),
                    "column": .object([
                        "type": .string("string"),
                        "enum": .array(Column.allCases.map { .string($0.rawValue) }),
                    ]),
                    "limit": .object(["type": .string("integer"), "default": .int(100)]),
                ]),
            ]),
            annotations: .init(title: "List board cards", readOnlyHint: true)
        ),
        Tool(
            name: "board_get_card",
            description: "Fetch one Elliot card by id, with its story, issue, pull request and last error.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "card_id": .object(["type": .string("string"), "description": .string("Card UUID.")]),
                ]),
                "required": .array([.string("card_id")]),
            ]),
            annotations: .init(title: "Get a card", readOnlyHint: true)
        ),
        Tool(
            name: "board_create_card",
            description: """
                Create a card in the Elliot backlog. The backlog holds user stories, so \
                prefer supplying role / want / benefit and acceptance criteria separately \
                rather than prose in `title`. Creating a card runs nothing on its own — \
                moving it to `todo` is what files a GitHub issue.
                """,
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "repo": .object([
                        "type": .string("string"),
                        "description": .string("Repository as owner/name, or an absolute path."),
                    ]),
                    "title": .object([
                        "type": .string("string"),
                        "description": .string("Short board label."),
                    ]),
                    "role": .object([
                        "type": .string("string"),
                        "description": .string("Who the story is for, e.g. \"developer\"."),
                    ]),
                    "want": .object([
                        "type": .string("string"),
                        "description": .string("The capability wanted, phrased as an action."),
                    ]),
                    "benefit": .object([
                        "type": .string("string"),
                        "description": .string("Why the capability is worth building."),
                    ]),
                    "acceptance_criteria": .object([
                        "type": .string("array"),
                        "items": .object(["type": .string("string")]),
                    ]),
                    "body": .object([
                        "type": .string("string"),
                        "description": .string("Free-text note, for a card that is not a story."),
                    ]),
                    "column": .object([
                        "type": .string("string"),
                        "enum": .array(Column.allCases.map { .string($0.rawValue) }),
                        "default": .string("backlog"),
                    ]),
                ]),
                "required": .array([.string("repo"), .string("title")]),
            ]),
            annotations: .init(title: "Create a card", readOnlyHint: false, destructiveHint: false)
        ),
        Tool(
            name: "board_move_card",
            description: """
                Move a card to another column. This is how work is driven: \
                backlog→todo files a GitHub issue, todo→inProgress implements it and \
                opens a pull request, inReview→done merges it. Those runs take minutes \
                to tens of minutes; this returns as soon as the run is queued. \
                Poll board_list_runs to follow it. Moves that do not match one of those \
                three transitions simply reposition the card.
                """,
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "card_id": .object(["type": .string("string")]),
                    "to": .object([
                        "type": .string("string"),
                        "enum": .array(Column.allCases.map { .string($0.rawValue) }),
                    ]),
                    "follow_ups": .object([
                        "type": .string("array"),
                        "items": .object(["type": .string("string")]),
                        "description": .string(
                            "Follow-up work to file as issues after a merge. Omit for none."
                        ),
                    ]),
                ]),
                "required": .array([.string("card_id"), .string("to")]),
            ]),
            annotations: .init(title: "Move a card", readOnlyHint: false, destructiveHint: false)
        ),
        Tool(
            name: "board_list_runs",
            description: """
                List skill runs, most recent first, with their state and cost. \
                Use this to follow a move that started a run.
                """,
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "card_id": .object(["type": .string("string")]),
                    "limit": .object(["type": .string("integer"), "default": .int(20)]),
                ]),
            ]),
            annotations: .init(title: "List runs", readOnlyHint: true)
        ),
        Tool(
            name: "board_analyze_repo",
            description: """
                Read a repository through one or more lenses and propose user \
                stories. Each angle is its own `claude -p` run and takes minutes; \
                this returns as soon as the runs are queued. Poll board_list_runs \
                to follow them, then board_list_proposals to read what they found. \
                Proposals are not cards: nothing reaches the board until \
                board_accept_proposals is called.
                """,
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "repo": .object([
                        "type": .string("string"),
                        "description": .string("Repository as owner/name, or an absolute path."),
                    ]),
                    "angles": .object([
                        "type": .string("array"),
                        "items": .object([
                            "type": .string("string"),
                            "enum": .array(AnalysisAngle.allCases.map { .string($0.rawValue) }),
                        ]),
                        "description": .string(
                            "One run per angle. bugs = defects; quickWins = high value for one "
                            + "sitting; features = capabilities the code is asking for; "
                            + "techDebt = structure costing something now; tests = uncovered "
                            + "invariants; docsAndDX = friction a newcomer hits."
                        ),
                    ]),
                    "max_stories": .object([
                        "type": .string("integer"),
                        "description": .string("Cap per angle, 1–30."),
                        "default": .int(8),
                    ]),
                    "instructions": .object([
                        "type": .string("string"),
                        "description": .string(
                            "Extra direction folded into every angle's prompt, e.g. "
                            + "\"concentrate on the process layer\"."
                        ),
                    ]),
                ]),
                "required": .array([.string("repo"), .string("angles")]),
            ]),
            annotations: .init(title: "Analyse a repository", readOnlyHint: false, destructiveHint: false)
        ),
        Tool(
            name: "board_list_proposals",
            description: """
                List the user stories an analysis proposed. Give either \
                analysis_id or repo. Defaults to status: proposed — the ones \
                still needing a decision; pass status to see accepted or \
                rejected ones too. `grounded` is false when a story cites a \
                file that is not there — it may still be right, but it was not \
                checkable. `duplicate_hint` flags a story that looks like \
                something already on the board or already filed.
                """,
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "analysis_id": .object(["type": .string("string")]),
                    "repo": .object(["type": .string("string")]),
                    "status": .object([
                        "type": .string("string"),
                        "enum": .array(ProposalStatus.allCases.map { .string($0.rawValue) }),
                        "default": .string("proposed"),
                    ]),
                    "limit": .object(["type": .string("integer"), "default": .int(100)]),
                ]),
            ]),
            annotations: .init(title: "List proposals", readOnlyHint: true)
        ),
        Tool(
            name: "board_accept_proposals",
            description: """
                Turn proposals into Backlog cards. This files nothing on GitHub: \
                a card in Backlog runs nothing, and moving it to `todo` is what \
                opens an issue. Proposals already accepted or rejected are \
                skipped rather than duplicated.
                """,
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "proposal_ids": .object([
                        "type": .string("array"),
                        "items": .object(["type": .string("string")]),
                    ]),
                ]),
                "required": .array([.string("proposal_ids")]),
            ]),
            annotations: .init(title: "Accept proposals", readOnlyHint: false, destructiveHint: false)
        ),
        Tool(
            name: "board_reject_proposals",
            description: """
                Mark proposals as rejected. They stay on the analysis so it still \
                reads as what it found, including what was turned down. \
                `decided` in the result means the id named a proposal that \
                exists, not that this call is what rejected it — one already \
                decided by an earlier or concurrent call is reported the same way.
                """,
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "proposal_ids": .object([
                        "type": .string("array"),
                        "items": .object(["type": .string("string")]),
                    ]),
                ]),
                "required": .array([.string("proposal_ids")]),
            ]),
            annotations: .init(title: "Reject proposals", readOnlyHint: false, destructiveHint: false)
        ),
    ]

    // MARK: - Dispatch

    public func call(name: String, arguments: [String: Value]?) async -> CallTool.Result {
        let args = arguments ?? [:]
        do {
            switch name {
            case "board_list_cards": return try await listCards(args)
            case "board_get_card": return try await getCard(args)
            case "board_create_card": return try await createCard(args)
            case "board_move_card": return try await moveCard(args)
            case "board_list_runs": return try await listRuns(args)
            case "board_analyze_repo": return try await analyzeRepo(args)
            case "board_list_proposals": return try await listProposals(args)
            case "board_accept_proposals": return try await decideProposals(args, accept: true)
            case "board_reject_proposals": return try await decideProposals(args, accept: false)
            default:
                return Self.error(code: "unknown_tool", message: "No such tool: \(name)")
            }
        } catch {
            return Self.error(code: "internal_error", message: error.localizedDescription)
        }
    }

    // MARK: - Tools

    /// Matches `repo` against the offline snapshot the same way the running
    /// app resolves it. A name that matches nothing must fail loudly: falling
    /// through to `repoID: nil` would silently drop the filter and hand back
    /// every repo's rows, in exactly the situation — Elliot not running —
    /// where the caller has the least ability to notice.
    static func repoNotFound(_ repo: String, in repos: [Repo]) -> CallTool.Result {
        error(
            code: "repo_not_found",
            message: "No registered repository matches \"\(repo)\".",
            hint: "Known: \(repos.map(\.nameWithOwner).joined(separator: ", "))"
        )
    }

    private func listCards(_ args: [String: Value]) async throws -> CallTool.Result {
        let repo = args["repo"]?.stringValue
        let column = args["column"]?.stringValue.flatMap(Column.init(rawValue:))
        let limit = args["limit"]?.intValue ?? 100

        switch bridge.read(.listCards(repo: repo, column: column, limit: limit)) {
        case .live(let response):
            return Self.render(response) { payload in
                guard case .cards(let cards) = payload else { return nil }
                return ["cards": Self.encode(cards), "source": .string("live")]
            }
        case .offline(let store):
            let repos = try await store.repos()
            let match = repo.flatMap { name in
                repos.first { $0.nameWithOwner == name || $0.path == name }
            }
            if let repo, match == nil {
                return Self.repoNotFound(repo, in: repos)
            }
            let cards = try await store.cards(repoID: match?.id, column: column).prefix(limit)
            let dtos = cards.map { card in
                CardDTO(
                    card: card,
                    repoName: repos.first { $0.id == card.repoID }?.nameWithOwner ?? "?"
                )
            }
            return Self.ok([
                "cards": Self.encode(Array(dtos)),
                // Say plainly that this is a snapshot, not the live board.
                "source": .string("offline-db"),
                "note": .string("Elliot is not running; this is a snapshot of its database."),
            ])
        }
    }

    private func getCard(_ args: [String: Value]) async throws -> CallTool.Result {
        guard let id = args["card_id"]?.stringValue.flatMap(UUID.init(uuidString:)) else {
            return Self.error(code: "bad_argument", message: "card_id must be a UUID.")
        }
        switch bridge.read(.getCard(id: id)) {
        case .live(let response):
            return Self.render(response) { payload in
                guard case .card(let card) = payload else { return nil }
                return ["card": Self.encode(card), "source": .string("live")]
            }
        case .offline(let store):
            guard let card = try await store.card(id: id) else {
                return Self.error(code: "card_not_found", message: "No card with id \(id).")
            }
            let repoName = try await store.repo(id: card.repoID)?.nameWithOwner ?? "?"
            return Self.ok([
                "card": Self.encode(CardDTO(card: card, repoName: repoName)),
                "source": .string("offline-db"),
            ])
        }
    }

    private func createCard(_ args: [String: Value]) async throws -> CallTool.Result {
        guard let repo = args["repo"]?.stringValue, let title = args["title"]?.stringValue else {
            return Self.error(code: "bad_argument", message: "repo and title are required.")
        }
        let story: ElliotRequest.StoryInput? = {
            let role = args["role"]?.stringValue ?? ""
            let want = args["want"]?.stringValue ?? ""
            let benefit = args["benefit"]?.stringValue ?? ""
            guard !role.isEmpty || !want.isEmpty || !benefit.isEmpty else { return nil }
            return .init(
                role: role, want: want, benefit: benefit,
                acceptanceCriteria: args["acceptance_criteria"]?.arrayValue?
                    .compactMap(\.stringValue) ?? []
            )
        }()

        let response = bridge.write(.createCard(
            repo: repo,
            title: title,
            body: args["body"]?.stringValue ?? "",
            story: story,
            column: args["column"]?.stringValue.flatMap(Column.init(rawValue:)) ?? .backlog
        ))
        return Self.render(response) { payload in
            guard case .card(let card) = payload else { return nil }
            return ["card": Self.encode(card)]
        }
    }

    private func moveCard(_ args: [String: Value]) async throws -> CallTool.Result {
        guard let id = args["card_id"]?.stringValue.flatMap(UUID.init(uuidString:)) else {
            return Self.error(code: "bad_argument", message: "card_id must be a UUID.")
        }
        guard let to = args["to"]?.stringValue.flatMap(Column.init(rawValue:)) else {
            return Self.error(
                code: "bad_argument",
                message: "`to` must be one of: \(Column.allCases.map(\.rawValue).joined(separator: ", "))."
            )
        }
        // An omitted list means "no follow-ups", not "ask me" — the UI is the
        // only caller that gets to be asked.
        let followUps = args["follow_ups"]?.arrayValue?.compactMap(\.stringValue) ?? []

        let response = bridge.write(.moveCard(id: id, to: to, followUps: followUps))
        return Self.render(response) { payload in
            guard case .moved(let move) = payload else { return nil }
            var fields: [String: Value] = [
                "card_id": .string(move.cardID.uuidString),
                "from": .string(move.from),
                "to": .string(move.to),
                "summary": .string(move.summary),
            ]
            if let runID = move.runID { fields["run_id"] = .string(runID.uuidString) }
            if let triggered = move.triggered { fields["triggered"] = .string(triggered) }
            return fields
        }
    }

    private func listRuns(_ args: [String: Value]) async throws -> CallTool.Result {
        let cardID = args["card_id"]?.stringValue.flatMap(UUID.init(uuidString:))
        let limit = args["limit"]?.intValue ?? 20

        switch bridge.read(.listRuns(cardID: cardID, limit: limit)) {
        case .live(let response):
            return Self.render(response) { payload in
                guard case .runs(let runs) = payload else { return nil }
                return ["runs": Self.encode(runs), "source": .string("live")]
            }
        case .offline(let store):
            let runs = try await store.runs(cardID: cardID, limit: limit).map(RunDTO.init)
            return Self.ok(["runs": Self.encode(runs), "source": .string("offline-db")])
        }
    }

    private func analyzeRepo(_ args: [String: Value]) async throws -> CallTool.Result {
        guard let repo = args["repo"]?.stringValue else {
            return Self.error(code: "bad_argument", message: "repo is required.")
        }
        let angles = args["angles"]?.arrayValue?.compactMap(\.stringValue) ?? []
        guard !angles.isEmpty else {
            return Self.error(
                code: "bad_argument",
                message: "angles must list at least one lens.",
                hint: "One of: \(AnalysisAngle.allCases.map(\.rawValue).joined(separator: ", "))."
            )
        }

        let response = bridge.write(.analyzeRepo(
            repo: repo,
            angles: angles,
            maxStories: args["max_stories"]?.intValue ?? 8,
            instructions: args["instructions"]?.stringValue ?? ""
        ))
        return Self.render(response) { payload in
            guard case .analysisStarted(let analysis) = payload else { return nil }
            return [
                "analysis_id": .string(analysis.id.uuidString),
                "repo": .string(analysis.repo),
                "runs": Self.encode(analysis.runs),
                "note": .string(
                    "Each run takes minutes. Poll board_list_runs, then "
                    + "board_list_proposals with this analysis_id."
                ),
            ]
        }
    }

    private func listProposals(_ args: [String: Value]) async throws -> CallTool.Result {
        let analysisID = args["analysis_id"]?.stringValue.flatMap(UUID.init(uuidString:))
        let repo = args["repo"]?.stringValue
        guard analysisID != nil || repo != nil else {
            return Self.error(
                code: "bad_argument", message: "Give either analysis_id or repo."
            )
        }
        // Default to what still needs deciding: an agent asking "what did the
        // analysis find" means the open ones.
        let status = args["status"]?.stringValue ?? ProposalStatus.proposed.rawValue
        let limit = args["limit"]?.intValue ?? 100

        switch bridge.read(.listProposals(
            analysisID: analysisID, repo: repo, status: status, limit: limit
        )) {
        case .live(let response):
            return Self.render(response) { payload in
                guard case .proposals(let proposals) = payload else { return nil }
                return ["proposals": Self.encode(proposals), "source": .string("live")]
            }
        case .offline(let store):
            let repos = try await store.repos()
            let match = repo.flatMap { name in
                repos.first { $0.nameWithOwner == name || $0.path == name }
            }
            if let repo, match == nil {
                return Self.repoNotFound(repo, in: repos)
            }
            let proposals = try await store.proposals(
                analysisID: analysisID,
                repoID: match?.id,
                status: ProposalStatus(rawValue: status),
                limit: limit
            )
            let dtos = proposals.map { proposal in
                ProposalDTO(
                    proposal: proposal,
                    repoName: repos.first { $0.id == proposal.repoID }?.nameWithOwner ?? "?"
                )
            }
            return Self.ok([
                "proposals": Self.encode(dtos),
                "source": .string("offline-db"),
                "note": .string("Elliot is not running; this is a snapshot of its database."),
            ])
        }
    }

    private func decideProposals(_ args: [String: Value], accept: Bool) async throws -> CallTool.Result {
        let ids = (args["proposal_ids"]?.arrayValue ?? [])
            .compactMap { $0.stringValue.flatMap(UUID.init(uuidString:)) }
        guard !ids.isEmpty else {
            return Self.error(code: "bad_argument", message: "proposal_ids must contain UUIDs.")
        }
        let response = bridge.write(
            accept ? .acceptProposals(ids: ids) : .rejectProposals(ids: ids)
        )
        return Self.render(response) { payload in
            guard case .proposalsDecided(let decision) = payload else { return nil }
            var fields: [String: Value] = [
                "decided": .array(decision.decided.map { .string($0.uuidString) }),
                "summary": .string(decision.summary),
            ]
            if !decision.skipped.isEmpty {
                fields["skipped"] = .array(decision.skipped.map { .string($0.uuidString) })
            }
            if !decision.cards.isEmpty {
                fields["cards"] = Self.encode(decision.cards)
            }
            return fields
        }
    }

    // MARK: - Rendering

    private static func render(
        _ response: ElliotResponse,
        _ body: (ElliotPayload) -> [String: Value]?
    ) -> CallTool.Result {
        switch response {
        case .failure(let code, let message, let hint):
            return error(code: code.rawValue, message: message, hint: hint)
        case .ok(let payload):
            guard let fields = body(payload) else {
                return error(code: "internal_error", message: "Unexpected response shape.")
            }
            return ok(fields)
        }
    }

    static func ok(_ fields: [String: Value]) -> CallTool.Result {
        CallTool.Result(content: [.text(text: json(fields), annotations: nil, _meta: nil)], isError: false)
    }

    static func error(code: String, message: String, hint: String? = nil) -> CallTool.Result {
        var fields: [String: Value] = ["error": .string(code), "message": .string(message)]
        if let hint { fields["hint"] = .string(hint) }
        return CallTool.Result(content: [.text(text: json(fields), annotations: nil, _meta: nil)], isError: true)
    }

    private static func json(_ fields: [String: Value]) -> String {
        guard let data = try? WireCodec.encoder.encode(Value.object(fields)),
              let text = String(data: data, encoding: .utf8)
        else { return "{}" }
        return text
    }

    private static func encode<T: Encodable>(_ value: T) -> Value {
        guard let data = try? WireCodec.encoder.encode(value),
              let decoded = try? WireCodec.decoder.decode(Value.self, from: data)
        else { return .null }
        return decoded
    }
}

// MARK: - Wiring

public extension ElliotMCPServer {
    /// Builds the MCP server and attaches the tool handlers.
    func makeServer() async -> Server {
        let server = Server(
            name: "elliot",
            version: "1.0.0",
            capabilities: .init(tools: .init(listChanged: false))
        )
        await server.withMethodHandler(ListTools.self) { _ in
            ListTools.Result(tools: Self.tools)
        }
        await server.withMethodHandler(CallTool.self) { params in
            await call(name: params.name, arguments: params.arguments)
        }
        return server
    }
}
