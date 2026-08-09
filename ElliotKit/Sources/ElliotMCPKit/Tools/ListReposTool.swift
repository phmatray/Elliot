import ElliotIPC
import ElliotStore
import MCP

/// Names the repositories Elliot will act in, and on what terms.
///
/// Before this existed the only way to discover a registered repository was to
/// name one that was not and read the hint off the refusal — an agent had to
/// provoke an error to learn a fact. `permissionMode` travels with each one for
/// the same reason: it is what decides whether a move is bookkeeping or an
/// unattended agent accepting every tool call, and that is not something to
/// find out afterwards.
///
/// A read, so it is served from the database snapshot when Elliot is down.
struct ListReposTool: BoardTool {
    var tool: Tool {
        Tool(
            name: "board_list_repos",
            description: """
                List the repositories Elliot is registered to drive: owner/name, local path, \
                default branch, whether the repository is enabled, and the terms its runs \
                get — the `claude --permission-mode` and any extra allowed tools.

                Call this before board_create_card instead of guessing a name — an \
                unrecognised repository is refused. Read `permissionMode` before you move a \
                card in a repository for the first time: `bypassPermissions` means runs \
                there accept every tool call without asking anyone, which is what makes \
                moving a card an execution primitive rather than bookkeeping. \
                `extraAllowedTools` is empty on a repository that allows nothing beyond \
                what the mode already does. A disabled repository still holds cards but \
                refuses every move that would trigger work.
                """,
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([:]),
            ]),
            annotations: .init(
                title: "List repositories",
                readOnlyHint: true,
                // The registry Elliot keeps locally; github.com is never asked
                // whether these repositories still exist.
                openWorldHint: false
            )
        )
    }

    func call(_: [String: Value], bridge: any BridgeProviding) async throws -> CallTool.Result {
        let outcome = await bridge.read(.listRepos)
        return try .render(outcome) { payload in
            guard case .repos(let repos) = payload else { return nil }
            return ["repos": try Value.encoding(repos), "total": .int(repos.count)]
        }
    }
}
