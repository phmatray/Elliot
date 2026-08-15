import ElliotModel
import Foundation
import Testing

@testable import ElliotProcess

@Suite("Agent invocation")
struct AgentInvocationTests {
    @Test("every permission mode maps to a value the adapter advertises")
    func modesMapToAdvertisedValues() {
        // Measured from Fixtures/acp/session-new-commands.json: the `mode` config option's
        // advertised values are exactly these six. `manual` is the only name that differs — the
        // adapter calls it "default" and describes it as "Standard behavior, prompts for dangerous
        // operations", which is what `manual` means.
        #expect(AgentInvocation.configValue(for: .manual) == "default")
        #expect(AgentInvocation.configValue(for: .acceptEdits) == "acceptEdits")
        #expect(AgentInvocation.configValue(for: .auto) == "auto")
        #expect(AgentInvocation.configValue(for: .dontAsk) == "dontAsk")
        #expect(AgentInvocation.configValue(for: .plan) == "plan")
        #expect(AgentInvocation.configValue(for: .bypassPermissions) == "bypassPermissions")
        // A seventh mode must be a compile error here, not a silent default: the switch in
        // `configValue` is exhaustive with no `default`, exactly as
        // `PermissionMode.appraisal(repo:)` is.
        #expect(PermissionMode.allCases.count == 6)
    }

    @Test("the displayed argv is the process Elliot actually spawns")
    func displayArgvIsTheRealSpawn() {
        let invocation = AgentInvocation(
            runID: UUID(),
            prompt: "do the thing",
            cwd: "/tmp/repo",
            permissionMode: .bypassPermissions,
            extraAllowedTools: [],
            extraDirectories: [],
            maxBudgetUSD: nil,
            resumeFromAgentSession: nil
        )
        let agent = ACPAgentProcess(
            executable: "/opt/homebrew/bin/npx",
            arguments: ["--yes", "@agentclientprotocol/claude-agent-acp"],
            cwd: "/tmp", environment: [:])
        let argv = invocation.displayArgv(agent: agent)
        #expect(argv == ["/opt/homebrew/bin/npx", "--yes", "@agentclientprotocol/claude-agent-acp"])
    }
}
