import MCP

/// One MCP tool: the declaration agents read, and the code that answers a call
/// to it.
///
/// A tool holds no state and reaches the board only through `AppBridge`, which
/// is what keeps the rule engine the single decider — one file per tool makes
/// that cheap to check, since a tool that tried to do more would have to grow a
/// dependency this protocol never hands it.
protocol BoardTool: Sendable {
    /// What `tools/list` publishes. Its `name` is also the dispatch key.
    var tool: Tool { get }

    /// Answers one call. Arguments arrive exactly as the agent sent them:
    /// checking them is each tool's own job, and a bad one is an error *result*
    /// — a thrown error would reach the agent as a bare transport failure.
    func call(_ args: [String: Value], bridge: AppBridge) async throws -> CallTool.Result
}

extension BoardTool {
    var name: String { tool.name }
}
