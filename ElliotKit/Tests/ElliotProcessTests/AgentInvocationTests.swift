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

    @Test("the displayed argv carries nothing that varies per run")
    func theDisplayedArgvCarriesNothingPerRun() {
        // Not a virtue — a measured loss, argued at length on `displayArgv`. Under `claude -p`,
        // `SkillRun.argv` was the only per-run record of the permission mode a run spawned under;
        // two invocations differing in every field this type carries now render the same three
        // tokens. Pinned here so the next reader meets it as a measurement rather than rediscover
        // it from a Runs pane that stopped answering — and so that "fixing" it by appending
        // non-argv tokens fails a test that names where the record actually belongs.
        let agent = ACPAgentProcess(
            executable: "/opt/homebrew/bin/npx",
            arguments: ["--yes", "@agentclientprotocol/claude-agent-acp"],
            cwd: "/tmp", environment: [:])
        // `extraAllowedTools` is `[]` in both because a non-empty value never reaches a spawn: it
        // is refused before `AgentSession` is constructed.
        let permissive = AgentInvocation(
            runID: UUID(),
            prompt: "implement issue 47",
            cwd: "/tmp/repo-a",
            permissionMode: .bypassPermissions,
            extraAllowedTools: [],
            extraDirectories: ["/tmp/repo-a/appraisal"],
            maxBudgetUSD: 4,
            resumeFromAgentSession: "sess-01H"
        )
        let restrained = AgentInvocation(
            runID: UUID(),
            prompt: "merge pr 12",
            cwd: "/tmp/repo-b",
            permissionMode: .plan,
            extraAllowedTools: [],
            extraDirectories: [],
            maxBudgetUSD: nil,
            resumeFromAgentSession: nil
        )
        #expect(permissive.displayArgv(agent: agent) == restrained.displayArgv(agent: agent))
    }

    @Test("the refusal names the tools it could not grant, and where to clear them")
    func theRefusalReadsAsASentence() {
        let error: any Error = AgentInvocationError.unmappableAllowedTools([
            "Bash(git push:*)", "WebFetch",
        ])
        // `localizedDescription` on an existential, not the case's payload: this is the exact
        // call `RunScheduler.swift:773` makes — `setClosing(.elliot(error.localizedDescription))`
        // — so it is the string an operator meets on the failed run. Measured without
        // `LocalizedError`: "The operation couldn't be completed. (ElliotProcess
        // .AgentInvocationError error 0.)" — neither pattern, no reason, no remedy.
        let sentence = error.localizedDescription
        #expect(sentence.contains("Bash(git push:*)"))
        #expect(sentence.contains("WebFetch"))
        #expect(sentence.contains("Run terms"))
        // The type name is what Foundation's fallback embeds, and it is locale-independent —
        // unlike "couldn't be completed", which is translated and would pin the wrong thing.
        #expect(!sentence.contains("AgentInvocationError"))
    }
}
