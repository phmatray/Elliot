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
    ///
    /// ⛔ **Which makes it the same three tokens for every run — a loss of record, not a tidier
    /// one, and it is written down here rather than discovered from a pane that quietly stopped
    /// answering.** `RunScheduler.swift:729` stamps `[toolConfig.claudePath] +
    /// invocation.arguments()` today, which carries `--permission-mode <mode>` and one `--add-dir`
    /// per extra directory; the moment Task 15 replaces that line with this function, a
    /// `bypassPermissions` `implement-issue` and a `plan` `merge-pr` are indistinguishable in the
    /// row. `SkillRun` has no `permissionMode` column — argv was the only *per-run* record of the
    /// grant — and Task 12 adds `agentSessionID` and `stopReason`, not this.
    ///
    /// `Repo.permissionMode` is not a substitute, twice over. It is the value *now*, editable from
    /// Preflight ▸ Run terms since #333, so it cannot say what a run three weeks ago spawned
    /// under; and an appraisal never used it directly — `RunScheduler.invocation` spawns one under
    /// `PermissionMode.appraisal(repo:)`, a derived value that has never had a column at all.
    /// `theDisplayedArgvCarriesNothingPerRun` pins the loss so it stays a measurement.
    ///
    /// ⚠️ **Two doc comments in code this task does not touch assert that visibility, and both are
    /// still true until Task 15 lands** — named here rather than corrected early, because a
    /// comment made false in the other direction is no better. `SkillRun.argv`
    /// (`ElliotModel/SkillRun.swift:103`) says *"the full argv, kept so a run can be reproduced by
    /// hand"*; `npx --yes @agentclientprotocol/claude-agent-acp` reproduces an adapter, not a run.
    /// `RunsPane.inputs` (`ElliotAppKit/RunsPane.swift:346-353`) gives as its whole reason for
    /// existing that otherwise, for *"implement-issue and merge-pr, the two runs that write code
    /// and merge it, a reader could never see … that the run carried `--permission-mode
    /// bypassPermissions`"*. Task 18 step 4 enumerates the doc comments this stage falsifies and
    /// **omits both**.
    ///
    /// ⛔ **Do not close the gap by returning tokens that are not argv.** A `mode=…` appended here
    /// lands in a field the pane renders as one command line and documents as runnable by hand,
    /// trading a missing fact for a false one. The fix is a per-run column beside Task 12's two,
    /// deliberately not taken here: this task writes `AgentInvocation` and its errors, and a
    /// migration added now would collide with `v17_acpSession`'s own numbering.
    public func displayArgv(agent: ACPAgentProcess) -> [String] {
        [agent.executable] + agent.arguments
    }
}

public enum AgentInvocationError: Error, LocalizedError, Sendable {
    /// The patterns that cannot be granted, in the order `Repo.extraAllowedTools` holds them.
    /// Non-empty at the only throw site: the check happens before `AgentSession` is constructed,
    /// so a refusal spawns nothing.
    case unmappableAllowedTools([String])

    /// ⛔ **`LocalizedError`, not bare `Error`, because the sentence *is* what this refusal is
    /// for.** `RunScheduler`'s spawn `catch` writes
    /// `updated.setClosing(.elliot(error.localizedDescription))` (`RunScheduler.swift:773`), and
    /// Foundation's fallback for an enum with no `errorDescription` is — measured, not assumed —
    /// `The operation couldn't be completed. (ElliotProcess.AgentInvocationError error 0.)`. That
    /// names neither the patterns nor the reason, and the `[String]` payload never leaves the
    /// type, so a repository carrying one allowed-tool pattern would fail *every* drag with a
    /// sentence nobody can act on: the exact "with nothing on screen saying why" outcome
    /// `extraAllowedTools` refuses in order to avoid. Every other error enum in this package
    /// conforms — `ProcessError`, `ArtifactProbeError`, `StoreError`, `BoardError`,
    /// `AnalysisError`, `AutoDevError`, `SocketError`, `IPCServer.StartError`.
    ///
    /// The remedy it names is the same screen Preflight's `repo.runTerms` row points at, so the
    /// operator who meets this after a drag and the one who meets it before are sent to one place.
    public var errorDescription: String? {
        switch self {
        case .unmappableAllowedTools(let tools):
            "The ACP adapter advertises no config option for allowed tools, so "
                + "\(tools.joined(separator: ", ")) cannot be granted — and dropping the grant "
                + "silently would let this run meet a refusal for a tool you had allowed. Clear "
                + "the extra allowed tools in Preflight ▸ this repository ▸ Run terms."
        }
    }
}
