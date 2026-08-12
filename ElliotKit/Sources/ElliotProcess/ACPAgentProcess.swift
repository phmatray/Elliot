import Foundation

/// Everything needed to spawn one ACP agent.
///
/// A plain descriptor rather than a builder: the agent is reached by `npx`, which means the
/// executable is Node's launcher and the package is an argument, and nothing about that is worth
/// hiding behind a type that pretends otherwise.
///
/// ⚠️ The adapter resolves the Claude CLI vendored inside `@anthropic-ai/claude-agent-sdk`, not the
/// `claude` on PATH. `CLAUDE_CODE_EXECUTABLE` in `environment` is the documented escape hatch, and
/// whether pointing it at a locally installed CLI works is UNMEASURED as of 2026-08-12.
public struct ACPAgentProcess: Sendable {
    public var executable: String
    public var arguments: [String]
    public var cwd: String
    public var environment: [String: String]

    public init(
        executable: String,
        arguments: [String],
        cwd: String,
        environment: [String: String]
    ) {
        self.executable = executable
        self.arguments = arguments
        self.cwd = cwd
        self.environment = environment
    }
}
