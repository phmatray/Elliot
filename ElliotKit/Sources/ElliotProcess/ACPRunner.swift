import ElliotModel
import Foundation

/// Everything needed to run one turn. Zero flags — `ClaudeInvocation.arguments()` rendered eight of
/// them and that whole function is gone: `cwd` and `extraDirectories` become `session/new`'s
/// `workingDirectory` and `additionalDirectories`, `permissionMode` becomes a
/// `session/set_config_option`, and `prompt` becomes the turn itself.
public struct AgentInvocation: Sendable {
    /// ⚠️ No longer the agent's session id. Under `claude -p` it doubled as `--session-id`, so
    /// `SkillRun.id == sessionID` and the CLI's transcript path was known before the process
    /// emitted a byte. ACP's agent names its own session, returned by `session/new` — which is why
    /// `SkillRun.agentSessionID` exists. `StoreLocation.runLogURL(runID:)` is unaffected: that path
    /// is keyed on the id Elliot owns.
    public var runID: UUID
    public var prompt: String
    public var cwd: String
    public var permissionMode: PermissionMode
    /// ⛔ There is no ACP mapping, and this is refused rather than dropped. Measured on
    /// `Fixtures/acp/session-new-commands.json`, the adapter advertises five config options —
    /// `mode`, `model`, `effort`, `fast`, `agent` — and **none of them for allowed tools**.
    /// Silently dropping the grant would make an agent meet a refusal for a tool the operator had
    /// explicitly allowed, with nothing on screen saying why; silently widening would be worse.
    /// `AgentSession.start` throws `AgentInvocationError.unmappableAllowedTools`, which
    /// `RunScheduler.start`'s existing `catch` already turns into a failed run with an
    /// Elliot-authored sentence, and Preflight gains a row (Task 16) so the operator meets it
    /// before a drag rather than after.
    public var extraAllowedTools: [String]
    public var extraDirectories: [String]
    /// `--max-budget-usd` is gone with the CLI, and the ceiling is rebuilt on live `usage_update` +
    /// `session/cancel` (Task 11). `nil` means no ceiling — the default.
    public var maxBudgetUSD: Double?
    /// The **agent's** session id to fork from, not a `SkillRun.id`.
    ///
    /// A `String`, not a `UUID`: it is the id the previous run's **agent** chose. `RunScheduler`
    /// reads it off the predecessor row's `agentSessionID` (Task 13).
    public var resumeFromAgentSession: String?

    public init(
        runID: UUID,
        prompt: String,
        cwd: String,
        permissionMode: PermissionMode,
        extraAllowedTools: [String],
        extraDirectories: [String],
        maxBudgetUSD: Double?,
        resumeFromAgentSession: String?
    ) {
        self.runID = runID
        self.prompt = prompt
        self.cwd = cwd
        self.permissionMode = permissionMode
        self.extraAllowedTools = extraAllowedTools
        self.extraDirectories = extraDirectories
        self.maxBudgetUSD = maxBudgetUSD
        self.resumeFromAgentSession = resumeFromAgentSession
    }

    /// The adapter's own vocabulary for `permissionMode`.
    ///
    /// A `switch` over every case, no `default`: a seventh mode is a compile error here rather than
    /// a silent default into whichever arm someone wrote first — exactly
    /// `PermissionMode.appraisal(repo:)`'s own discipline. Measured on
    /// `Fixtures/acp/session-new-commands.json`'s `mode` config option: the adapter's six advertised
    /// values are `auto`, `default`, `acceptEdits`, `plan`, `dontAsk`, `bypassPermissions`. `manual`
    /// is the only name that differs — the adapter calls it "default" and describes it as "Standard
    /// behavior, prompts for dangerous operations", which is what `manual` means.
    public static func configValue(for mode: PermissionMode) -> String {
        switch mode {
        case .manual: "default"
        case .acceptEdits: "acceptEdits"
        case .auto: "auto"
        case .dontAsk: "dontAsk"
        case .plan: "plan"
        case .bypassPermissions: "bypassPermissions"
        }
    }

    /// What `SkillRun.argv` is stamped with, for the Runs pane.
    ///
    /// The process Elliot actually spawns is `npx`, with the adapter package as an argument — this
    /// invocation carries no flags of its own, so there is nothing of *this* type to render.
    public func displayArgv(agent: ACPAgentProcess) -> [String] {
        [agent.executable] + agent.arguments
    }
}

public enum AgentInvocationError: Error, Sendable {
    case unmappableAllowedTools([String])
}
