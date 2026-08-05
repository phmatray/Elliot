import ElliotIPC
import ElliotModel
import ElliotStore
import Foundation
import MCP

/// The MCP face of the board.
///
/// Every mutating tool goes through `BoardService` in the running app, so an
/// agent moving a card and a person dragging one are the same act, decided by
/// the same rule engine. This type holds no rules of its own. The single piece
/// of judgement it is allowed — ranking what to do next — is `rankNextSteps`,
/// which is pure and lives in `ElliotModel` where the app reads it from too.
public struct ElliotMCPServer: Sendable {
    private let bridge: any BridgeProviding

    /// Takes the protocol, not `AppBridge`, so the tools can be driven by a
    /// double. The default keeps `ElliotMCPServer()` meaning what it always did.
    public init(bridge: any BridgeProviding = AppBridge()) {
        self.bridge = bridge
    }

    // MARK: - Tools
    //
    // Ordered as a model should reach for them: the question first, the
    // inventory next, then the acts. Descriptions are the only documentation an
    // agent ever reads, so they say what the tool costs and what it will not do,
    // not just what it is called.

    public static let tools: [Tool] = [
        Tool(
            name: "board_next",
            description: """
                What to do next on the Elliot board, ranked. Reach for this before \
                board_list_cards: that one returns cards and leaves the rules to you, \
                this one answers "which card should I act on, and what happens if I do".

                Each item names the single column the card goes to next, the skill that \
                move would trigger (create-issue, implement-issue, merge-pr), and whether \
                moving it right now would actually start that work — with the same \
                `blockCode` board_move_card would return if it were refused. Ready items \
                come first, then the cards nearest to done, because finishing work already \
                in flight beats starting more.

                Blocked cards are listed too, with their reason: "nothing is ready and here \
                is why" is an answer, an empty list is not. `readyCount` counts every ready \
                candidate, not only the ones on this page. Cards in `done` are not \
                candidates and are not counted.

                A ready inReview→done item means the merge will proceed with **no follow-up \
                issues filed**; pass `follow_ups` to board_move_card if you want some. \
                Reads only — nothing here moves a card.
                """,
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "repo": .object([
                        "type": .string("string"),
                        "description": .string(
                            "Repository as owner/name, or its absolute path. Omit for the whole board."
                        ),
                    ]),
                    "limit": .object([
                        "type": .string("integer"),
                        "default": .int(ElliotPaging.nextLimitDefault),
                        "description": .string(
                            "How many ranked items to return. Capped at \(ElliotPaging.nextLimitMax); the answer says so when the cap applied."
                        ),
                    ]),
                ]),
            ]),
            annotations: .init(
                title: "What to do next",
                readOnlyHint: true,
                // Reads Elliot's own database. Nothing outside this machine is
                // consulted, and no run is started.
                openWorldHint: false
            )
        ),
        Tool(
            name: "board_list_cards",
            description: """
                List Elliot board cards. Optionally filter by repository (owner/name or \
                absolute path) and by column (backlog, todo, inProgress, inReview, done). \
                Returns each card's story, issue and pull-request numbers when it has them.

                `activeRunID` is present exactly when a run is holding the card, which is \
                why a move would be refused; absent means no run holds it.

                The answer is a page, not a list: `total` counts everything the filter \
                matched, `truncated` says the rest were left out, and `limit_capped_from` \
                appears when you asked for more than the server will send. Ordered by \
                repository, then board column, then position within the column — stable \
                across calls, so "the first ten" means the same ten twice.

                An unknown repository is refused with `repo_not_found` and the known names, \
                never silently widened to the whole board.
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
                    "limit": .object([
                        "type": .string("integer"),
                        "default": .int(ElliotPaging.cardLimitDefault),
                        "description": .string(
                            "Capped at \(ElliotPaging.cardLimitMax). Filter by repo or column rather than raising it."
                        ),
                    ]),
                ]),
            ]),
            annotations: .init(title: "List board cards", readOnlyHint: true, openWorldHint: false)
        ),
        Tool(
            name: "board_get_card",
            description: """
                Fetch one Elliot card by id, with its story, issue, pull request, last error \
                and the id of the run holding it, if any.
                """,
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "card_id": .object(["type": .string("string"), "description": .string("Card UUID.")]),
                ]),
                "required": .array([.string("card_id")]),
            ]),
            annotations: .init(title: "Get a card", readOnlyHint: true, openWorldHint: false)
        ),
        Tool(
            name: "board_list_repos",
            description: """
                List the repositories Elliot is registered to drive: owner/name, local path, \
                default branch, whether the repository is enabled, and the \
                `claude --permission-mode` its runs get.

                Call this before board_create_card instead of guessing a name — an \
                unrecognised repository is refused. Read `permissionMode` before you move a \
                card in a repository for the first time: `bypassPermissions` means runs \
                there accept every tool call without asking anyone, which is what makes \
                moving a card an execution primitive rather than bookkeeping. A disabled \
                repository still holds cards but refuses every move that would trigger work.
                """,
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([:]),
            ]),
            annotations: .init(title: "List repositories", readOnlyHint: true, openWorldHint: false)
        ),
        Tool(
            name: "board_create_card",
            description: """
                Create a card in the Elliot backlog. The backlog holds user stories, so \
                prefer supplying role / want / benefit and acceptance criteria separately \
                rather than prose in `title`. Creating a card runs nothing on its own — \
                moving it to `todo` is what files a GitHub issue.

                Pass `idempotency_key` — any stable string you can derive again from the \
                same idea — and a retry after a timeout returns the card you already made \
                instead of a second one. The answer says `already_existed: true` when that \
                happened. Without a key, two calls make two cards.

                The key is unique across the **whole board**, not per repository. Derive it \
                from the repository as well as the idea, or a sweep filing "add-license" in \
                twenty repositories will create one card and report the other nineteen as \
                already existing. Check the `repo` on the card that comes back.

                There is no delete. A card created with the wrong text is corrected with \
                board_update_card, and a card that turned out to be a bad idea is left in \
                the backlog.
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
                    "idempotency_key": .object([
                        "type": .string("string"),
                        "description": .string(
                            "Stable key that makes this call safe to retry. Reusing it returns the existing card."
                        ),
                    ]),
                ]),
                "required": .array([.string("repo"), .string("title")]),
            ]),
            annotations: .init(
                title: "Create a card",
                readOnlyHint: false,
                // Adds a row and starts nothing.
                destructiveHint: false,
                // Only with an idempotency_key, and the caller chooses whether
                // to send one — so the honest static answer is "no".
                idempotentHint: false,
                openWorldHint: false
            )
        ),
        Tool(
            name: "board_update_card",
            description: """
                Correct a card's label, note or story. This is the only way to fix a card \
                that was created with the wrong text — there is no delete, deliberately: a \
                card is the board's only link to an issue or pull request that exists on \
                github.com.

                Replaces the fields it is given rather than patching them, so send the whole \
                story, not the one line you want changed. Omitting `role` / `want` / \
                `benefit` entirely clears the story and leaves the card a plain note.

                Refused with `card_already_filed` once the card carries an issue number: \
                from that moment the GitHub issue is the record and it is edited there. That \
                refusal is permanent — it is not `read_only`, and retrying later will not \
                change it.
                """,
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "card_id": .object(["type": .string("string")]),
                    "title": .object([
                        "type": .string("string"),
                        "description": .string("Short board label. Required: it is a replacement, not a patch."),
                    ]),
                    "role": .object(["type": .string("string")]),
                    "want": .object(["type": .string("string")]),
                    "benefit": .object(["type": .string("string")]),
                    "acceptance_criteria": .object([
                        "type": .string("array"),
                        "items": .object(["type": .string("string")]),
                    ]),
                    "body": .object([
                        "type": .string("string"),
                        "description": .string("Free-text note. Omit to clear it."),
                    ]),
                ]),
                "required": .array([.string("card_id"), .string("title")]),
            ]),
            annotations: .init(
                title: "Correct a card",
                readOnlyHint: false,
                // Overwrites text that nothing keeps a copy of.
                destructiveHint: true,
                idempotentHint: true,
                openWorldHint: false
            )
        ),
        Tool(
            name: "board_move_card",
            description: """
                Move a card to another column. This is how work is driven, and it is not \
                bookkeeping: three transitions spawn an unattended agent inside the \
                repository's working tree.

                  backlog → todo        files a GitHub issue (create-issue)
                  todo → inProgress     writes code on a new branch and opens a pull \
                request (implement-issue)
                  inReview → done       squash-merges that pull request, deletes its branch, \
                tears down its worktree, and files every entry of `follow_ups` as a new \
                issue (merge-pr)

                Blast radius: those agents run as `claude --permission-mode \
                bypassPermissions` in most repositories — they edit files, commit, push and \
                call `gh` without asking anyone, in the real checkout on this machine. \
                inReview → done writes to the repository's default branch on github.com and \
                nothing here can undo it. Check board_list_repos for the permission mode \
                before you move a card in a repository you have not driven before.

                Returns as soon as the run is queued, not when it finishes; runs take \
                minutes to tens of minutes. Follow it with board_await_run using the \
                returned `run_id`, and judge the result by `verifiedOutcome`, never by the \
                agent's prose. Every other transition simply repositions the card and runs \
                nothing.
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
            annotations: .init(
                title: "Move a card",
                readOnlyHint: false,
                // Merges, deletes branches and removes worktrees. Understating
                // this was the single worst thing about version 1 of this tool.
                destructiveHint: true,
                // A second call is a second move, and can be a second run.
                idempotentHint: false,
                // Reaches github.com.
                openWorldHint: true
            )
        ),
        Tool(
            name: "board_list_runs",
            description: """
                List skill runs, most recent first: state, verified outcome, exit code, \
                cost, and where the log is.

                Read `verifiedOutcome` — that is what `gh` established. `state: succeeded` \
                is compatible with `no_issue_created`, `not_merged` and `unverified`: the \
                agent finished cleanly and nothing was created or merged. `resultText` is \
                the agent's own account of its work; it is display text, not a fact, and \
                must never be parsed for issue or pull-request numbers.

                `isTerminal: false` means the run is still going, and `pollAfterSeconds` \
                says how long to wait before looking again — but prefer board_await_run, \
                which waits server-side and answers the moment the run ends. Terminal \
                states: succeeded, completedWithDenials, failed, cancelled, timedOut. \
                `stalled` is **not** terminal: the run has emitted nothing for a while and \
                is still alive, and it is yours to decide whether to keep waiting or \
                board_cancel_run it.

                `logPath` is a file of NDJSON — one Claude Code stream-json event per line, \
                exactly as the CLI emitted it. The same content is readable as the resource \
                `elliot://run/{id}/log`. `stderrPath` is where the process's stderr went.

                The answer is a page: `total`, `truncated` and `limit_capped_from` say \
                whether you are seeing everything.
                """,
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "card_id": .object([
                        "type": .string("string"),
                        "description": .string("Only runs for this card. Omit for every card."),
                    ]),
                    "limit": .object([
                        "type": .string("integer"),
                        "default": .int(ElliotPaging.runLimitDefault),
                        "description": .string("Capped at \(ElliotPaging.runLimitMax)."),
                    ]),
                ]),
            ]),
            annotations: .init(title: "List runs", readOnlyHint: true, openWorldHint: false)
        ),
        Tool(
            name: "board_await_run",
            description: """
                Wait for a run to reach a terminal state, then return it. This is the right \
                way to follow a move: the wait happens server-side, so one call replaces a \
                poll loop that would otherwise burn a round trip every few seconds for as \
                long as the run takes.

                `timeout_seconds` defaults to \(ElliotTimeouts.awaitDefaultSeconds) and is \
                capped at \(ElliotTimeouts.awaitMaxSeconds); asking for more is clamped, not \
                refused. **A timeout is not an error.** You get the run in whatever state it \
                is in, with `isTerminal: false` and a `pollAfterSeconds` hint — call again \
                to keep waiting. So check `isTerminal` before you believe the run is over, \
                and then read `verifiedOutcome` for what it actually achieved.

                Changes nothing, but it does need Elliot running, and starts it if it is not.
                """,
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "run_id": .object([
                        "type": .string("string"),
                        "description": .string("Run UUID, as returned by board_move_card."),
                    ]),
                    "timeout_seconds": .object([
                        "type": .string("integer"),
                        "default": .int(ElliotTimeouts.awaitDefaultSeconds),
                        "description": .string(
                            "How long to hold the wait. Capped at \(ElliotTimeouts.awaitMaxSeconds)."
                        ),
                    ]),
                ]),
                "required": .array([.string("run_id")]),
            ]),
            annotations: .init(
                title: "Wait for a run",
                // It writes nothing, but it is not free: it holds a connection,
                // and it will launch Elliot if Elliot is down.
                readOnlyHint: false,
                destructiveHint: false,
                idempotentHint: true,
                openWorldHint: false
            )
        ),
        Tool(
            name: "board_cancel_run",
            description: """
                Stop a run that is going nowhere. The run is signalled, not killed on the \
                spot: it passes through `cancelling` before `cancelled`, and the answer \
                tells you which of the two it had reached.

                Cancelling is destructive by nature. An implement-issue stopped halfway \
                leaves its branch and its worktree behind; a merge-pr stopped halfway may \
                already have merged. Read `verifiedOutcome` on the returned run to find out \
                what it managed to do before it was stopped, and expect to clean up by hand.

                The usual reason is a `stalled` run you are done waiting for. A run that is \
                already terminal is returned unchanged.
                """,
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "run_id": .object(["type": .string("string")]),
                ]),
                "required": .array([.string("run_id")]),
            ]),
            annotations: .init(
                title: "Cancel a run",
                readOnlyHint: false,
                // Half-done work stays half-done.
                destructiveHint: true,
                idempotentHint: true,
                // The run it stops is mid-conversation with github.com.
                openWorldHint: true
            )
        ),
    ]

    // MARK: - Dispatch

    public func call(name: String, arguments: [String: Value]?) async -> CallTool.Result {
        let args = arguments ?? [:]
        do {
            switch name {
            case "board_next": return try await next(args)
            case "board_list_cards": return try await listCards(args)
            case "board_get_card": return try await getCard(args)
            case "board_list_repos": return try await listRepos(args)
            case "board_create_card": return try await createCard(args)
            case "board_update_card": return try await updateCard(args)
            case "board_move_card": return try await moveCard(args)
            case "board_list_runs": return try await listRuns(args)
            case "board_await_run": return try await awaitRun(args)
            case "board_cancel_run": return try await cancelRun(args)
            default:
                return Self.error(code: "unknown_tool", message: "No such tool: \(name)")
            }
        } catch let failure as ToolFailure {
            return Self.error(code: failure.code, message: failure.message, hint: failure.hint)
        } catch {
            return Self.error(code: "internal_error", message: error.localizedDescription)
        }
    }

    // MARK: - Reads

    private func listCards(_ args: [String: Value]) async throws -> CallTool.Result {
        let repo = args["repo"]?.stringValue
        let column = try Self.column(args, "column")
        // The caller's own number goes on the wire. Clamping it here first would
        // hand the app a limit that never exceeds its cap, and `limitCappedFrom`
        // would come back nil for every request — a silent cap, which is the
        // same defect as a silent truncation.
        let requested = try Self.limit(args) ?? 0

        switch await bridge.read(.listCards(repo: repo, column: column, limit: requested)) {
        case .live(let response):
            return try Self.render(response) { payload in
                guard case .cards(let page) = payload else { return nil }
                var fields = Self.pageFields(
                    total: page.total, limit: page.limit,
                    truncated: page.truncated, cappedFrom: page.limitCappedFrom
                )
                fields["cards"] = try Self.encode(page.cards)
                fields["source"] = .string("live")
                Self.attachNote(&fields, Self.pageNote(
                    shown: page.cards.count, total: page.total,
                    truncated: page.truncated, limit: page.limit, cappedFrom: page.limitCappedFrom
                ))
                return fields
            }

        case .offline(let store):
            let (limit, cappedFrom) = ElliotPaging.clamp(
                requested,
                default: ElliotPaging.cardLimitDefault,
                max: ElliotPaging.cardLimitMax
            )
            let repos = try await store.repos()
            // `.all` and "you named a repository I do not know" are different
            // values, not one nil. Collapsing them is what made a typo return
            // the whole board as a success.
            let filter = try Self.repoFilter(repo, in: repos)
            let cards = try await store.cards(repoID: filter.repoID, column: column, limit: limit)
            let total = try await store.cardCount(repoID: filter.repoID, column: column)
            let active = try await store.activeRuns(cardIDs: cards.map(\.id))
            let names = Self.namesByID(repos)
            let page = CardPage(
                cards: cards.map { card in
                    CardDTO(
                        card: card,
                        repoName: names[card.repoID] ?? "?",
                        activeRunID: active[card.id]?.id
                    )
                },
                total: total,
                limit: limit,
                limitCappedFrom: cappedFrom
            )
            var fields = Self.pageFields(
                total: page.total, limit: page.limit,
                truncated: page.truncated, cappedFrom: page.limitCappedFrom
            )
            fields["cards"] = try Self.encode(page.cards)
            fields["source"] = .string("offline-db")
            Self.attachNote(
                &fields,
                Self.offlineNote,
                Self.pageNote(
                    shown: page.cards.count, total: page.total,
                    truncated: page.truncated, limit: page.limit, cappedFrom: page.limitCappedFrom
                )
            )
            return try Self.ok(fields)
        }
    }

    private func getCard(_ args: [String: Value]) async throws -> CallTool.Result {
        let id = try Self.uuid(args, "card_id")
        switch await bridge.read(.getCard(id: id)) {
        case .live(let response):
            return try Self.render(response) { payload in
                guard case .card(let card) = payload else { return nil }
                return ["card": try Self.encode(card), "source": .string("live")]
            }
        case .offline(let store):
            guard let card = try await store.card(id: id) else {
                return Self.error(code: "card_not_found", message: "No card with id \(id).")
            }
            let repoName = try await store.repo(id: card.repoID)?.nameWithOwner ?? "?"
            // Filled, not skipped: absent means "no run holds this card", so a
            // snapshot that left it nil would report every held card as movable.
            let activeRunID = try await store.activeRun(cardID: id)?.id
            let dto = CardDTO(card: card, repoName: repoName, activeRunID: activeRunID)
            var fields: [String: Value] = [
                "card": try Self.encode(dto),
                "source": .string("offline-db"),
            ]
            Self.attachNote(&fields, Self.offlineNote)
            return try Self.ok(fields)
        }
    }

    private func listRepos(_: [String: Value]) async throws -> CallTool.Result {
        switch await bridge.read(.listRepos) {
        case .live(let response):
            return try Self.render(response) { payload in
                guard case .repos(let repos) = payload else { return nil }
                return [
                    "repos": try Self.encode(repos),
                    "total": .int(repos.count),
                    "source": .string("live"),
                ]
            }
        case .offline(let store):
            let repos = try await store.repos().map { RepoDTO(repo: $0) }
            var fields: [String: Value] = [
                "repos": try Self.encode(repos),
                "total": .int(repos.count),
                "source": .string("offline-db"),
            ]
            Self.attachNote(&fields, Self.offlineNote)
            return try Self.ok(fields)
        }
    }

    private func listRuns(_ args: [String: Value]) async throws -> CallTool.Result {
        let cardID = try Self.optionalUUID(args, "card_id")
        let requested = try Self.limit(args) ?? 0

        switch await bridge.read(.listRuns(cardID: cardID, limit: requested)) {
        case .live(let response):
            return try Self.render(response) { payload in
                guard case .runs(let page) = payload else { return nil }
                var fields = Self.pageFields(
                    total: page.total, limit: page.limit,
                    truncated: page.truncated, cappedFrom: page.limitCappedFrom
                )
                fields["runs"] = try Self.encode(page.runs)
                fields["source"] = .string("live")
                Self.attachNote(&fields, Self.pageNote(
                    shown: page.runs.count, total: page.total,
                    truncated: page.truncated, limit: page.limit, cappedFrom: page.limitCappedFrom
                ))
                return fields
            }

        case .offline(let store):
            // The same refusal the running app makes, for the same reason: "this
            // card has no runs" and "there is no such card" are different
            // answers, and only one of them means keep waiting. Filtering on an
            // id that matches nothing answers the first when the truth is the
            // second — which is finding 3 again, one tool over.
            if let cardID, try await store.card(id: cardID) == nil {
                throw ToolFailure(
                    code: ElliotErrorCode.cardNotFound.rawValue,
                    message: "No card with id \(cardID).",
                    hint: "board_list_cards lists the cards this board holds."
                )
            }
            let (limit, cappedFrom) = ElliotPaging.clamp(
                requested,
                default: ElliotPaging.runLimitDefault,
                max: ElliotPaging.runLimitMax
            )
            let runs = try await store.runs(cardID: cardID, limit: limit).map { RunDTO(run: $0) }
            let total = try await store.runCount(cardID: cardID)
            let page = RunPage(runs: runs, total: total, limit: limit, limitCappedFrom: cappedFrom)
            var fields = Self.pageFields(
                total: page.total, limit: page.limit,
                truncated: page.truncated, cappedFrom: page.limitCappedFrom
            )
            fields["runs"] = try Self.encode(page.runs)
            fields["source"] = .string("offline-db")
            Self.attachNote(
                &fields,
                Self.offlineNote,
                Self.pageNote(
                    shown: page.runs.count, total: page.total,
                    truncated: page.truncated, limit: page.limit, cappedFrom: page.limitCappedFrom
                )
            )
            return try Self.ok(fields)
        }
    }

    private func next(_ args: [String: Value]) async throws -> CallTool.Result {
        let repo = args["repo"]?.stringValue
        let requested = try Self.limit(args) ?? 0

        switch await bridge.read(.next(repo: repo, limit: requested)) {
        case .live(let response):
            return try Self.render(response) { payload in
                guard case .next(let page) = payload else { return nil }
                return try Self.nextFields(page, source: "live", extraNote: nil)
            }
        case .offline(let store):
            let (limit, cappedFrom) = ElliotPaging.clamp(
                requested,
                default: ElliotPaging.nextLimitDefault,
                max: ElliotPaging.nextLimitMax
            )
            let page = try await Self.offlineNextPage(
                store: store, repo: repo, limit: limit, cappedFrom: cappedFrom
            )
            let fields = try Self.nextFields(page, source: "offline-db", extraNote: Self.offlineNote)
            return try Self.ok(fields)
        }
    }

    // MARK: - Writes
    //
    // A write is never served from the database. Moving a card without firing
    // its rule is the bug this architecture exists to prevent, so these go over
    // the socket or they fail.

    private func createCard(_ args: [String: Value]) async throws -> CallTool.Result {
        guard let repo = args["repo"]?.stringValue, let title = args["title"]?.stringValue else {
            return Self.error(code: "bad_argument", message: "repo and title are required.")
        }

        // `""` is what a client templating an optional field sends, and it means
        // "no key". Passed through it would be a key like any other, and since
        // the unique index counts an empty string as a value it would collide
        // with the next one. The board also normalises it; a bad argument should
        // not reach that far.
        let key = args["idempotency_key"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }

        let response = await bridge.write(.createCard(
            repo: repo,
            title: title,
            body: args["body"]?.stringValue ?? "",
            story: Self.story(args),
            column: try Self.column(args, "column") ?? .backlog,
            idempotencyKey: key
        ))
        return try Self.render(response) { payload in
            guard case .created(let created) = payload else { return nil }
            var fields: [String: Value] = [
                "card": try Self.encode(created.card),
                "already_existed": .bool(created.alreadyExisted),
            ]
            if created.alreadyExisted {
                // The repository is named rather than left to be diffed out of
                // the card. A key reused across repositories answers with the
                // card it made in the *first* one, and a sweep that does not
                // notice reports nineteen no-ops as nineteen successes. Said
                // this way rather than as a comparison because `repo` may have
                // been given as a checkout path, and only the board knows that
                // the two name one repository.
                Self.attachNote(
                    &fields,
                    "A card with this idempotency_key already existed in \(created.card.repo); "
                        + "nothing was created. The key is unique board-wide, so check that is "
                        + "the repository you meant."
                )
            }
            return fields
        }
    }

    private func updateCard(_ args: [String: Value]) async throws -> CallTool.Result {
        let id = try Self.uuid(args, "card_id")
        guard let title = args["title"]?.stringValue else {
            return Self.error(
                code: "bad_argument",
                message: "title is required: this replaces the card's text rather than patching it."
            )
        }
        let response = await bridge.write(.updateCard(
            id: id,
            title: title,
            body: args["body"]?.stringValue ?? "",
            story: Self.story(args)
        ))
        return try Self.render(response) { payload in
            guard case .card(let card) = payload else { return nil }
            return ["card": try Self.encode(card)]
        }
    }

    private func moveCard(_ args: [String: Value]) async throws -> CallTool.Result {
        let id = try Self.uuid(args, "card_id")
        guard let to = try Self.column(args, "to") else {
            return Self.error(
                code: "bad_argument",
                message: "`to` is required, and must be one of: "
                    + "\(Column.allCases.map(\.rawValue).joined(separator: ", "))."
            )
        }
        // An omitted list means "no follow-ups", not "ask me" — the UI is the
        // only caller that gets to be asked.
        let followUps = args["follow_ups"]?.arrayValue?.compactMap(\.stringValue) ?? []

        let response = await bridge.write(.moveCard(id: id, to: to, followUps: followUps))
        return try Self.render(response) { payload in
            guard case .moved(let move) = payload else { return nil }
            var fields: [String: Value] = [
                "card_id": .string(move.cardID.uuidString),
                "from": .string(move.from),
                "to": .string(move.to),
                "summary": .string(move.summary),
            ]
            if let runID = move.runID { fields["run_id"] = .string(runID.uuidString) }
            if let triggered = move.triggered { fields["triggered"] = .string(triggered) }
            if let poll = move.pollAfterSeconds { fields["poll_after_seconds"] = .int(poll) }
            Self.attachNote(&fields, move.runID.map { runID in
                "The run is queued, not finished. Call board_await_run with run_id "
                    + "\(runID.uuidString) and read verifiedOutcome when it returns."
            })
            return fields
        }
    }

    private func awaitRun(_ args: [String: Value]) async throws -> CallTool.Result {
        let id = try Self.uuid(args, "run_id")
        let seconds = try Self.integer(args, "timeout_seconds") ?? ElliotTimeouts.awaitDefaultSeconds

        let response = await bridge.write(.awaitRun(id: id, timeoutSeconds: seconds))
        return try Self.render(response) { payload in
            guard case .run(let run) = payload else { return nil }
            var fields: [String: Value] = ["run": try Self.encode(run)]
            if !run.isTerminal {
                Self.attachNote(
                    &fields,
                    "The wait window closed before the run did. This is not a failure:",
                    "call board_await_run again with the same run_id to keep waiting."
                )
            }
            return fields
        }
    }

    private func cancelRun(_ args: [String: Value]) async throws -> CallTool.Result {
        let id = try Self.uuid(args, "run_id")
        let response = await bridge.write(.cancelRun(id: id))
        return try Self.render(response) { payload in
            guard case .run(let run) = payload else { return nil }
            var fields: [String: Value] = ["run": try Self.encode(run)]
            if !run.isTerminal {
                Self.attachNote(
                    &fields,
                    "Signalled, not stopped yet — the run is in \(run.state).",
                    "Call board_await_run to see where it lands."
                )
            }
            return fields
        }
    }

    // MARK: - Arguments

    private static func story(_ args: [String: Value]) -> ElliotRequest.StoryInput? {
        let role = args["role"]?.stringValue ?? ""
        let want = args["want"]?.stringValue ?? ""
        let benefit = args["benefit"]?.stringValue ?? ""
        guard !role.isEmpty || !want.isEmpty || !benefit.isEmpty else { return nil }
        return .init(
            role: role, want: want, benefit: benefit,
            acceptanceCriteria: args["acceptance_criteria"]?.arrayValue?
                .compactMap(\.stringValue) ?? []
        )
    }

    /// A column argument, or nothing — never a third answer.
    ///
    /// `column: "in-progress"` used to mean "every column", so a typo came back
    /// as a page of the whole board under `isError: false`. That is finding 3
    /// one argument down: the request the caller made and the request the board
    /// answered were different, and nothing said so.
    private static func column(_ args: [String: Value], _ key: String) throws -> Column? {
        guard let raw = args[key], !raw.isNull else { return nil }
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
    /// silent truncation: a plausible answer to a question nobody asked. A
    /// round `10.0` is accepted because it *is* ten — that is a client's JSON
    /// formatting, not a different number.
    private static func integer(_ args: [String: Value], _ key: String) throws -> Int? {
        guard let raw = args[key], !raw.isNull else { return nil }
        if let value = raw.intValue { return value }
        if let value = raw.doubleValue, value == value.rounded(), value.magnitude < 1e15 {
            return Int(value)
        }
        throw ToolFailure(code: "bad_argument", message: "\(key) must be an integer.")
    }

    /// A page size the caller wrote, or nothing.
    ///
    /// A limit below one is refused rather than read as "you decide". Downstream
    /// it would become the default page, so `limit: remaining - seen` going
    /// negative — the arithmetic slip that produces it — would answer a hundred
    /// rows under `isError: false`, with `limit` and `truncated` describing a
    /// page nobody asked for and nothing saying the argument was discarded.
    /// `limit: "10"` is already refused one line up; this is the same defect
    /// with a number in it.
    private static func limit(_ args: [String: Value]) throws -> Int? {
        guard let value = try integer(args, "limit") else { return nil }
        guard value > 0 else {
            throw ToolFailure(
                code: "bad_argument",
                message: "limit must be at least 1. Omit it for this server's default page."
            )
        }
        return value
    }

    private static func uuid(_ args: [String: Value], _ key: String) throws -> UUID {
        guard let id = args[key]?.stringValue.flatMap(UUID.init(uuidString:)) else {
            throw ToolFailure(code: "bad_argument", message: "\(key) must be a UUID.")
        }
        return id
    }

    private static func optionalUUID(_ args: [String: Value], _ key: String) throws -> UUID? {
        guard let raw = args[key]?.stringValue else { return nil }
        guard let id = UUID(uuidString: raw) else {
            throw ToolFailure(code: "bad_argument", message: "\(key) must be a UUID.")
        }
        return id
    }

    /// Either "no filter" or one resolved repository — never a nil that means
    /// both. The live handler refuses an unknown name; the offline path has to
    /// refuse it the same way or a typo reads as the whole board.
    private enum RepoFilter {
        case all
        case only(UUID)

        var repoID: UUID? {
            if case .only(let id) = self { return id }
            return nil
        }
    }

    private static func repoFilter(_ name: String?, in repos: [Repo]) throws -> RepoFilter {
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

    private static func namesByID(_ repos: [Repo]) -> [UUID: String] {
        Dictionary(uniqueKeysWithValues: repos.map { ($0.id, $0.nameWithOwner) })
    }

    // MARK: - What to do next, from a snapshot
    //
    // Nothing here decides or phrases anything. The candidates come from
    // `nextCandidates`, the order from `rankNextSteps`, each item from
    // `NextDTO(step:rank:activeRunID:)` — all three shared with the app, which
    // reaches them through BoardService and MCPRequestHandler. This module still
    // imports neither, so the helper holds no copy of the rules; what it shares
    // is pure and lives below both of them. Every place this file previously
    // wrote its own version of one of the three, the two answers diverged.

    private static func offlineNextPage(
        store: BoardStore,
        repo: String?,
        limit: Int,
        cappedFrom: Int?
    ) async throws -> NextPage {
        let repos = try await store.repos()
        let filter = try repoFilter(repo, in: repos)
        let cards = try await store.cards(repoID: filter.repoID)
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

    // MARK: - Rendering

    private static func nextFields(
        _ page: NextPage,
        source: String,
        extraNote: String?
    ) throws -> [String: Value] {
        var fields = pageFields(
            total: page.total, limit: page.limit,
            truncated: page.truncated, cappedFrom: page.limitCappedFrom
        )
        fields["items"] = try encode(page.items)
        fields["ready_count"] = .int(page.readyCount)
        fields["source"] = .string(source)
        // "Nothing is ready" is a finding, not an empty result. Said out loud so
        // an agent does not read a page of blocked cards as a page it mis-asked for.
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

    private static func pageFields(
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

    /// A cut answer and a complete one must not look alike, and neither must a
    /// limit the caller asked for and a limit the server imposed.
    private static func pageNote(
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

    private static let offlineNote =
        "Elliot is not running; this is a snapshot of its database. "
            + "A card held by a run still reports activeRunID, but no run is making progress "
            + "while Elliot is down, so any state other than a terminal one is frozen rather than live."

    private static func attachNote(_ fields: inout [String: Value], _ parts: String?...) {
        let text = parts.compactMap { $0 }.joined(separator: " ")
        if !text.isEmpty { fields["note"] = .string(text) }
    }

    private static func render(
        _ response: ElliotResponse,
        _ body: (ElliotPayload) throws -> [String: Value]?
    ) throws -> CallTool.Result {
        switch response {
        case .failure(let code, let message, let hint):
            return error(code: code.rawValue, message: message, hint: hint)
        case .ok(let payload):
            guard let fields = try body(payload) else {
                return error(
                    code: "internal_error",
                    message: "Elliot answered with a payload this tool does not know how to read.",
                    hint: "The app and this helper are probably different builds."
                )
            }
            return try ok(fields)
        }
    }

    /// Throws rather than degrading. A tool result that failed to serialise used
    /// to reach the agent as `{}` with `isError: false` — a valid-looking empty
    /// answer, which is worse than an error because it gets believed.
    static func ok(_ fields: [String: Value]) throws -> CallTool.Result {
        let text = try json(fields)
        return CallTool.Result(
            content: [.text(text: text, annotations: nil, _meta: nil)],
            isError: false
        )
    }

    static func error(code: String, message: String, hint: String? = nil) -> CallTool.Result {
        // Deliberately not throwing: this is the last stop, including for a
        // failure to encode. Strings only, so the encode below cannot realistically
        // fail — and if it somehow does, the constant still carries `isError`.
        var fields = ["error": code, "message": message]
        if let hint { fields["hint"] = hint }
        let text = (try? WireCodec.encoder.encode(fields))
            .flatMap { String(data: $0, encoding: .utf8) }
            ?? #"{"error":"internal_error","message":"Elliot could not serialise its own error."}"#
        return CallTool.Result(content: [.text(text: text, annotations: nil, _meta: nil)], isError: true)
    }

    private static func json(_ fields: [String: Value]) throws -> String {
        let data = try WireCodec.encoder.encode(Value.object(fields))
        guard let text = String(data: data, encoding: .utf8) else {
            throw ToolFailure(code: "internal_error", message: "Tool result was not valid UTF-8.")
        }
        return text
    }

    /// `WireCodec.encoder` and not a bare `JSONEncoder`: dates go out ISO 8601
    /// on the wire, and a run whose `startedAt` arrives as a float since 2001 is
    /// a date no model will read correctly.
    private static func encode(_ value: some Encodable) throws -> Value {
        let data = try WireCodec.encoder.encode(value)
        return try WireCodec.decoder.decode(Value.self, from: data)
    }
}

/// A refusal with a code the agent can branch on, thrown from anywhere in a tool
/// and rendered once in `call()`.
struct ToolFailure: Error {
    var code: String
    var message: String
    var hint: String?
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
        case .offline(let store):
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
        case .offline(let store):
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
