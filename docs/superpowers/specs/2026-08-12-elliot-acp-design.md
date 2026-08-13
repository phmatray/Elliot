# Replacing `claude -p` with the Agent Client Protocol

**Date:** 2026-08-12 · **Status:** design, approved section by section · **Scope:** see §9 — one
change, but with a separable first stage

Every factual claim below is tagged. **[M]** was measured on this machine on 2026-08-12 and the
command is given. **[S]** is read from the ACP specification. **UNMEASURED** means a recon pass or a
probe explicitly could not establish it — those words are carried forward rather than resolved by
inference, because a guessed field name is worse than a gap.

---

## 1. Why

Elliot executes work by spawning `claude -p --output-format stream-json` and reading NDJSON off its
stdout. That wire is a CLI's output format, not a contract: `StreamEvent.swift` says so in its own
header — decoding *"never throws and never drops a line, so a schema change in a future Claude Code
release degrades the UI instead of breaking the runner."*

The driver for this change is **not** agent-agnosticism and **not** robustness. It is that the board
should show what the agent is actually doing. Today a card renders a tool call as a JSON blob
truncated to 200 characters, and discards thinking entirely (`default: continue` in `decodeMessage`).
ACP carries the same run as structured tool calls with `kind`, real status transitions, absolute file
`locations`, and `{type:"diff", path, oldText, newText}` content — a diff the card can show *before
the write lands*.

**Elliot as an IDE** is the goal. ACP is the transport that makes it possible.

### The three decisions that bound this design

1. **Unattended stays unattended.** Moving a card remains the act of execution. Elliot answers
   permissions by policy; there is **no** answering UI in this scope. What is gained is display.
2. **Agent-agnosticism is an explicit non-goal.** ACP is the transport to Claude Code specifically.
   `_meta.claudeCode.*` may be read freely; Preflight keeps checking Claude Code plugins;
   `MethodPack.plugin` is unchanged.
3. **Direct replacement, not a backend abstraction.** There is no `AgentBackend` protocol and no
   parity window. The seam is already three lines of `RunScheduler` [M], so an abstraction would cost
   more than it protects. The risk this accepts is named in §8.

---

## 2. What was measured, and what it overturned

Four findings changed the design after the initial analysis. All are reproducible with the scripts
noted; the raw transcripts are committed under `Fixtures/acp/`.

### 2.1 `bypassPermissions` works — the unattended premise survives

Adapter issue [#585](https://github.com/agentclientprotocol/claude-agent-acp/issues/585) reports
permission prompts appearing with bypassPermissions enabled. **It did not reproduce.** [M]

Driving a full turn (`Read` → `Edit` → `Bash`) after
`session/set_config_option {configId:"mode", value:"bypassPermissions"}`:

```
===== PERMISSION REQUESTS =====
count = 0  (mode was 'bypassPermissions')
stopReason: "end_turn"   ·   turn wall-clock: 9.1s
```

`current_mode_update` confirmed `currentModeId: "bypassPermissions"`. Zero `session/request_permission`
arrived. ⚠️ One turn, one adapter version, one machine — this is evidence, not a guarantee, and #585
remains open.

### 2.2 The plugin skills are advertised — and one was driven end to end [M] 2026-08-13

`ai-migration-kit:create-issue`, `implement-issue` and `merge-pr` all appear in
`available_commands_update`, alongside all 11 `ai-migration-kit:*` commands (123 commands total)
[M]. Issue #580 (*"Any Plan when to support `/plugin` slash command"*, opened 2026-04-21, zero
replies) concerns plugin **management**, not plugin **skills**.

**Advertised is not invoked, so it was driven.** `create-issue` files a real GitHub issue and
`implement-issue` writes code and opens a PR, so neither is safe to fire blind; `get-repo-profile`
reads the repository and writes `.claude/skills/repo-profile.md`, which costs nothing in a scratch
checkout. `Scripts/probe/acp_turn.py` sent `/ai-migration-kit:get-repo-profile` as the prompt, at
`bypassPermissions`, against a throwaway `git init` checkout with no `origin` (`/tmp/elliot-acp-skill`,
one commit). Transcript: `Fixtures/acp/turn-skill-invocation.json`.

```
stopReason: "end_turn"   ·   turn wall-clock: 78.5s   ·   permission requests: 0
11 tool_call creations (6 Bash / 3 Read / 1 Write / 1 Edit)
42 tool_call_update frames on those same 11 ids (24 Bash / 9 Read / 5 Edit / 4 Write)
```

`.claude/skills/repo-profile.md` exists afterwards, 6.0 KB, and its content is not boilerplate — it
is a real read of the scratch repo (correctly reports no remote, no build system, no CI, the
`probe <probe@local>` commit identity mismatch) with `<!-- TODO -->` markers exactly where the skill's
own discipline says to leave one rather than guess.

**A plausible file is not proof by itself — the improvisation hypothesis has to be built and then
broken.** The model knows `get-repo-profile`'s *name and description* from `available_commands_update`
whether or not the skill's body ever loaded, and that description already states the output path.
A guessed cache path is likewise not far-fetched from a model that has this plugin in its training
data. What is not guessable is the skill's own **private control flow**, and the transcript's six
Bash/three Read calls reproduce it exactly, in the documented order, first try, with SKILL.md
(`~/.claude/plugins/cache/ai-migration-kit-marketplace/ai-migration-kit/1.10.0/skills/get-repo-profile/SKILL.md`)
never once Read:

| step | SKILL.md says | transcript shows |
|---|---|---|
| 1 | run `repo-profile.sh show` | `bash ".../repo-profile.sh" show; echo "EXIT=$?"` → `rawOutput: "NO_PROFILE\nEXIT=3"` |
| 2 | on exit 3 (`NO_PROFILE`), Read `references/generating.md` | Read `.../get-repo-profile/references/generating.md` |
| 3 | run `repo-profile.sh detect` | `bash ".../repo-profile.sh" detect; echo "EXIT=$?"` |
| 4 | fill `references/profile-template.md` | Read `.../get-repo-profile/references/profile-template.md` |
| 5 | write `.claude/skills/repo-profile.md` | `Write /private/tmp/elliot-acp-skill/.claude/skills/repo-profile.md` |
| — | *(not documented, but consistent with "report what you wrote")* | re-runs `repo-profile.sh show` to confirm readback, then one `Edit` on the same file |

`NO_PROFILE` and the exit-3 sentinel belong to `repo-profile.sh` alone — nowhere in its own
description, and not part of the two `references/*.md` filenames or the branch that reads them on
that exact code. Reproducing four private names and a private exit code, in the documented sequence,
without ever reading the instructions that name them, is not the shape of an improvisation. **The
skill ran end to end over ACP.** [M]

⚠️ **No `tool_call` in this transcript ever carries `_meta.claudeCode.toolName == "Skill"`.** So the
brief's original litmus test (grep for `toolName == "Skill"`) would have reported a false negative on
a skill that plainly ran. Reading the adapter's own source rather than the wire alone (the same move
§5.4 makes below): `shouldEmitToolCall(toolName)` in `acp-agent.js` only ever suppresses `TodoWrite`
and the four `Task*` tools — there is no `"Skill"` case anywhere in the adapter, so the adapter is not
filtering one out. The absence is therefore a fact about the Claude Code CLI's own handling of a
`/plugin:skill` slash command, not about ACP: the CLI appears to expand the command into ordinary
context before the model's turn starts, rather than emitting a `Skill`-named `tool_use` the SDK would
carry through. **Why** is inferred from source, not measured on the wire — the working evidence for
"the skill ran" is the control-flow table above and the file it produced, never the absence of a
tool-call name.

⚠️ `acp_turn.py` dumps only messages **received** from the adapter; the outgoing `session/prompt` is
not in either transcript. So the committed artefact alone cannot distinguish "sent `/name` as a slash
command" from "sent natural language that happened to auto-load the same skill" — that distinction is
known only from the probe's own source (`ACP_PROMPT='/ai-migration-kit:get-repo-profile'`), not from
`Fixtures/acp/turn-skill-invocation.json` in isolation.

### 2.3 Cost and token accounting are richer than the spec promises

The spec makes `usage_update.cost` a `MAY` and states there is no per-turn token accounting at all —
it is an open RFD [S]. The adapter provides both [M]:

```json
{"sessionUpdate":"usage_update","used":37355,"size":1000000,
 "cost":{"amount":0.2855775,"currency":"USD"}}
```

and, on the `session/prompt` response, a field the protocol does not define:

```json
"usage":{"inputTokens":8,"outputTokens":387,
         "cachedReadTokens":118845,"cachedWriteTokens":21644,"totalTokens":140884}
```

Elliot has none of this today — `total_cost_usd` is a single terminal number. Live `usage_update`
plus `session/cancel` also makes a per-run spend brake **rebuildable**, where the loss of
`--max-budget-usd` had been assessed as unrecoverable.

⚠️ `cost` was absent from the first nine `usage_update` frames and present on the last. Treat it as
intermittent, not as arriving on every frame.

### 2.4 MCP inheritance survives — and so does the recursion hazard

Issue #883 reports that MCP servers passed to `session/new` never reach the model. That was **not**
tested (the probe passed `mcpServers: []`). What *was* tested is whether a session with an empty list
still sees the operator's globally-registered servers. It does [M] — the agent listed
`mcp__codebase-memory-mcp__*`, `mcp__plugin_context7_context7__*`, and named `elliot` among servers
still connecting.

⛔ **This overturns an inference, in the direction that matters.** The analysis had reasoned that
ACP's explicit `mcpServers` list *replaces* inheritance, making `PermissionMode.appraisal`'s
justification obsolete — that cap exists because *"an appraisal inherits the operator's MCP
configuration, so its agent can see the `elliot` server and call `board_move_card`."* Measured,
inheritance still happens and explicit supply is **additive**. The hazard is unchanged and the cap
must stay.

---

## 3. The dependency: vendored, surgically

There is no official Swift SDK for ACP. Three community libraries exist; the only credible one is
[`wiedymi/swift-acp`](https://github.com/wiedymi/swift-acp) (MIT, 29 ★), built for a native macOS
worktree-and-agent manager.

**Provenance to vendor:** commit `9498537769d1309b6519fbb87d0c22fcf9317f3e`, 2026-07-22,
*"Fix ACP subprocess message handling"*, MIT © 2025 wiedymi. Its only tag is `v0.1.0` while its
README instructs `from: "1.0.0"` — a requirement that cannot resolve against its own tags [M], which
is one reason a version range is not an option.

### 3.1 The measurement that decides the shape

Two different questions, two different answers:

| Question | Result |
|---|---|
| Does it work as a **5.9 dependency** consumed from a `6.3.1` / `.v6` package? | ✅ clean build from scratch, **0 errors, 0 warnings**, 56 steps, 6.9 s [M] |
| Do its own sources compile **under `.v6`**? | ⛔ **33 errors** [M] |

A dependency compiles in its own language mode, so the first result means its types *cross* an
isolation boundary safely — not that they were ever strict-concurrency checked. Vendoring folds the
sources into our language mode, so the second number is the one that applies.

The 33 errors are concentrated and mechanical, in **three files**:

- **20 ×** `type 'T' does not conform to the 'Sendable' protocol` — unconstrained generics in
  `Client.swift`, chiefly `withRequestTimeout<T>` passing `T` through a `withThrowingTaskGroup`.
  Adding `T: Sendable` is the correct fix, not a concession: this is a real hole, and the probe found
  it independently before the compiler named it.
- **12 ×** `static property is not concurrency-safe because it is nonisolated global shared mutable
  state` — in `Logger.swift` and `ShellEnvironment.swift`, **both of which we delete**.
- 1 × the resulting `emit-module` failure.

### 3.2 `_meta` survives, which is what decision 2 rests on

Reading `_meta.claudeCode.toolName` off tool calls is how the card keeps rendering `Read` / `Edit` /
`Bash`. Measured against the library's decoder [M]:

```
_meta.claudeCode.toolName        : Read
_meta.claudeCode.nested.deep     : true
_meta.claudeCode.list            : 1,2,3
perm toolCall …toolName          : Bash
round-trip toolName              : Read
```

Nested objects, arrays, the permission request's copy, and a full encode/decode round trip.

### 3.3 ⛔ What must be cut, and why it is not optional

The library contains **three** places that spawn a process:

| File | What it duplicates |
|---|---|
| `ACP/Internal/ProcessManager.swift` | `ChildProcess` — `terminationHandler`, `killpg` SIGTERM→SIGKILL |
| `ACP/Transport/StdioTransport.swift` | `ChildProcess`, a third time |
| `ACP/Utilities/ShellEnvironment.swift` | `LoginShellEnvironment.capture()` |

`ChildProcess`'s header states it is the only thing that starts a child, drains its pipes and
publishes its exit — and #146 recorded what happens when that mechanism is written twice: eight
byte-identical comment lines across two spawners, and three defects each fixed in one file only.
Vendoring these verbatim reintroduces that defect **behind a vendor boundary**, where nobody looks.

`ShellEnvironment` is worse than a duplicate. It calls `process.waitUntilExit()` — the one thing this
repository's production rule forbids (`3b1c226`/#18: it spins a run loop waiting for a notification a
concurrently-spawned sibling can consume first) — and its own comment admits a race: *"On main
thread, returns immediately with potentially incomplete environment."* Elliot's capture is hard-won:
`/bin/zsh -lic`, 47 PATH entries, and the #188 measurement showing an injected shim arrives and still
loses on order.

### 3.4 The vendoring manifest

Source tree: 10 648 lines, 45 files, 4 modules.

| Module / path | Keep? | Rationale |
|---|---|---|
| `ACPModel` (15 files) | ✅ | The wire types. The expensive part, and pure data. |
| `ACP` protocol layer — `Client`, `RequestRouter`, `Message`, `Requests`, `Responses`, `Updates`, `Permission`, `Tool`, `Content`, `Session`, `Capabilities`, `Errors` | ✅ | Request/response correlation and notification dispatch. |
| `ACP/Internal/ProcessManager`, `ProcessRegistry`, `Transport/StdioTransport` | ⛔ | Replaced by a `Transport` sitting on `ChildProcess`. |
| `ACP/Utilities/ShellEnvironment` | ⛔ | `LoginShellEnvironment`. See §3.3. |
| `ACP/Utilities/Logger` | ✅ **keep, repointed** | Measured after this document was first written: `Client.swift` references it, so cutting it breaks the file this whole stage is about. Its statics are made immutable and its subsystem moves from `com.acp` to `dev.phmatray.elliot`, which serves the stated intent — one logging story — at no cost. |
| `ACP/Agent/` (2 files) | ⛔ | We are a client, not an agent. |
| `ACPHTTP` (2), `ACPRegistry` (3) | ⛔ | WebSocket transport and agent discovery — out of scope. |

Vendored code lives under a directory that names its origin, its commit and its licence, and is
exempt from the hand-formatting expectation that governs the rest of the tree — it is not our code,
and `CLAUDE.md`'s ⛔ on `swift format` applies to the package either way.

---

## 4. Architecture

```
ElliotProcess/ClaudeRunner.swift    →  ACPRunner.swift
  ClaudeInvocation                       AgentInvocation    board vocabulary, zero flags
  ClaudeRun                              AgentRun           updates / cancel / pid — same shape
  ClaudeRunOutcome                       AgentRunOutcome
ElliotProcess/StreamingProcess.swift →  ACPConnection       JSON-RPC over the SAME ChildProcess
ElliotModel/StreamEvent.swift       →  RunEvent.swift
  StreamEvent                            retained, demoted: archive reader only
```

⛔ **`ChildProcess` is not touched.** ACP is JSON-RPC over a child's stdio: same spawn, same drain
lock, same SIGTERM, same SIGKILL escalation. What changes is what happens to the bytes — today a
`LineSink` splits NDJSON; tomorrow the same splitter feeds a JSON-RPC demultiplexer. This is the #146
invariant preserved *by construction* rather than by vigilance: we write one more `ChildOutputSink`,
we do not write a second spawner. The sink's methods are still called **while the drain lock is
held**, and the ACP layer inherits that hazard one level up — a notification handler that defers work
can yield into a stream already finished.

**`StreamEvent` is museumed, not deleted.** The `runs/*.jsonl` already on disk are stream-json, and
they are read by `RunsPane`, by the MCP `logPath` resource, and by crash recovery. A read-only
archive decoder is not a second mechanism: nothing writes it any more.

**What does not move at all:** `RuleEngine`, `BoardService`'s funnel, `Verifier`,
`VerifiedOutcome.applied` (the only thing that writes card fields, enforced by grep), `PRWatcher`,
`SchedulerLimits`, `RunSilence`/`IdleWatch`, `ArtifactRetention`, `BoardStore`'s columns, and all 15
MCP tools — `ElliotMCPKit` imports neither `ElliotEngine` nor `ElliotProcess`, enforced in
`Package.swift`, so the helper carries no agent coupling whatsoever.

---

## 5. The event model

### 5.1 ⛔ The patch is partial — the measured trap

Real frames from `Fixtures/acp/turn-edit-bash.json` [M]:

```
tool_call         Edit  status=pending    kind=edit   title='Edit'
tool_call_update  Edit  status=nil        kind=edit   title='Edit /…/notes.txt'
tool_call_update  Edit  status=nil        kind=nil    title=nil        content=[diff]
tool_call_update  Edit  status=completed  kind=nil    title=nil
```

`RunLogRow.rows` already folds by id — **the right shape, the wrong semantics**. A naive port that
*replaces* the row leaves the finished card with no title and no `kind`, because the last frame
carries neither. The fold must **merge**: `nil` means *absent from this frame*, never *cleared*.

This is why `tool_call` and `tool_call_update` collapse into **one** case. A `tool_call` *is* the
first patch — it arrives with `rawInput: {}` and a generic title (`"Edit"`) and is refined
afterwards. Two cases would invite exactly the replace-versus-merge confusion.

### 5.2 The type

```swift
public enum RunEvent: Sendable, Hashable {
    case session(SessionInfo)        // model, cwd, tools, commands, mode
    case agentText(String)
    case agentThought(String)        // NEW — discarded today by `default: continue`
    case toolCall(ToolCallPatch)     // creation AND update: both are patches
    case plan([PlanStep])            // NEW
    case usage(Usage)                // NEW — live, against one terminal number today
    case modeChanged(String)
    case unreadable(raw: Data, error: String?)   // today's totality, preserved
}

/// `nil` = absent from this frame. NEVER "cleared".
public struct ToolCallPatch: Sendable, Hashable {
    public var id: String                     // the only field the spec guarantees
    public var title: String?
    public var kind: ToolKind?                // read · edit · execute · …
    public var status: ToolStatus?            // pending · inProgress · completed · failed
    public var locations: [FileLocation]?     // absolute path + 1-based line
    public var content: [ToolContent]?        // .text | .diff(path, old, new) | .terminal(id)
    public var claudeToolName: String?        // _meta.claudeCode.toolName — Read/Edit/Bash
}
```

### 5.3 Invariants carried over unchanged

- The **log file is the lossless sink**, written under the drain lock; `updates` stays
  `bufferingNewest(512)` and deliberately lossy. Never assert an exact count on the stream — assert it
  on the log. Measured at 9/10 failures versus 0/10 when this was got wrong (#128).
- **Two tiers of truth.** `gh` is the fact, the agent's prose is hearsay rendered in demoted italic.
  `Verifier` does not change by one line.

### 5.4 A refused tool call is distinguishable — by an adapter field the spec does not define [M] 2026-08-13

Today a run is clean only when `is_error == false` **and** `permission_denials` is empty — a run
refused a tool often finishes `success` having worked around the gap. Under ACP at
`bypassPermissions`, zero permission requests arrive [M] (§2.1), so Elliot's refusal ledger would
always be empty on that signal alone and `RunState.completedWithDenials` needs a different source.

**Provoked with a real refusal**, not inferred: a `PreToolUse` hook in the scratch checkout's
`.claude/settings.json` (committed at `Fixtures/acp/refusal-hook-settings.json`) blocked every `Bash`
call (`"decision":"block"`), then `Scripts/probe/acp_turn.py` sent a prompt that forces one — *"Run
`echo hello` with the Bash tool and tell me what it printed."* Transcript:
`Fixtures/acp/turn-refusal.json`.

```
permission requests: 0   ·   stopReason: "end_turn"   ·   turn wall-clock: 9.0s
```

⛔ **The design's own guess — `stopReason: "refusal"` — did not happen.** `refusal` is a real case of
the vendored `StopReason` enum (`ElliotKit/Vendor/swift-acp/ACPModel/Session.swift:68`), but this
turn ended `end_turn`: the model accepted the block and answered the user instead of the turn itself
being refused. So `stopReason` cannot be the signal `RunState.completedWithDenials` reads.

**The Bash call's final `tool_call_update` is the signal**, and it is unambiguous:

```json
{
  "sessionUpdate": "tool_call_update", "status": "failed",
  "rawOutput": "probe: denied on purpose",
  "_meta": {"claudeCode": {"nonExecutionKind": "permission-rule"}},
  "content": [{"type": "content", "content": {"type": "text", "text": "```\nprobe: denied on purpose\n```"}}]
}
```

`nonExecutionKind` does distinguish a refusal from an ordinary tool failure — but it lives entirely
in `_meta.claudeCode`, not in the protocol. Reading the adapter's own source
(`@agentclientprotocol/claude-agent-acp@0.66.0/dist/acp-agent.js`) rather than the wire alone: it is
forwarded verbatim from a `tool_result_meta` sidecar the Claude Code CLI (≥ 2.1.216) emits on its
`user` message and the adapter's own comment calls it an **open, untyped set** — *"'user-rejected',
'permission-rule', 'interrupted', 'cancelled', … (open set: new kinds ship on the wire ahead of
schema updates, so no enum check)"* — and notes the field is *"absent from sdk.d.ts, hence
unknown-typed"*. So this is decision 2's `_meta` survival (§3.2) doing real work, and also its
sharper edge: the exact string set is not contractual, and a future CLI could add a kind Elliot has
never seen without any version bump on the ACP side.

**The contrast case was checked, not left vacuous.** Across the transcripts committed for this
design there is exactly one `status: "failed"` frame that carries a `permission-rule` refusal — so
"no ordinary tool failure carries `nonExecutionKind`" would otherwise be true only because no
ordinary failure existed anywhere to check. A second, targeted probe closes that: same scratch
checkout, no hook, prompt *"Use the Read tool to read the file
`/tmp/elliot-acp-failure/definitely-does-not-exist-abc123.txt`…"*, a genuine tool error rather than a
policy block. Transcript: `Fixtures/acp/turn-ordinary-failure.json`.

```json
{
  "sessionUpdate": "tool_call_update", "status": "failed",
  "rawOutput": "File does not exist. Note: your current working directory is /private/tmp/elliot-acp-failure.",
  "content": [{"type": "content", "content": {"type": "text", "text": "```\nFile does not exist. …\n```"}}]
}
```

No `_meta.claudeCode.nonExecutionKind` at all — `stopReason: "end_turn"`, 8.5s. [M] Both failure
shapes now measured, on the one axis that matters for the fold: `status == "failed"` alone does not
imply a refusal; `nonExecutionKind`'s *presence* is what a genuine execution error never carries.

⛔ **But the frozen rule as first written was wrong, and the evidence against it is quoted three
paragraphs up.** *"Presence of `nonExecutionKind`, not a closed enum"* folds `interrupted` and
`cancelled` into denials too — and those are exactly what a **cancelled run** produces on its
in-flight tool calls, which is Elliot's most common deliberate action (SIGTERM today,
`session/cancel` under ACP, §6). The rule as first frozen would have marked every cancelled run as
one that *"was refused a tool and quietly worked around the gap,"* destroying precisely the
distinction `RunState.completedWithDenials` exists to draw. `user-rejected` is a third
non-denial — a human declining interactively, not a policy refusing an unattended agent.

**Decision, corrected:** `RunScheduler.state(for:)` records every `nonExecutionKind` value it sees
(for the log and the card, never discarded), and folds by *value*, not by bare presence:

- `"permission-rule"` → `RunState.completedWithDenials` — the one shape actually provoked and
  measured [M] against the actual mechanism Elliot ships (`PreToolUse` hooks; `allowedTools`/mode
  denials are the same policy layer, unmeasured but not a new mechanism).
- `"interrupted"` / `"cancelled"` → **not** a denial; these correlate with the run's own
  `stopReason: "cancelled"` (§6) and are attributed there.
- `"user-rejected"` → **not** a denial in Elliot's unattended flow (no interactive human is present
  to reject); recorded, not folded.
- any other string, including one not in the adapter's own list → **UNMEASURED**. Do not default it
  to denial: the adapter's list already contains three values for which that default is provably
  wrong, so an unknown fourth value is a call for a fact, not a place to guess one.

⚠️ **Only one refusal shape was exercised — a third-party `PreToolUse` hook block.** Elliot will also
meet a tool outside `allowedTools`, a non-`bypassPermissions` mode denying outright, `session/cancel`
arriving mid-tool-call, and an MCP tool refusing — none of these were provoked, and whether each
produces `nonExecutionKind: "permission-rule"` or a different value is **UNMEASURED**.

---

## 6. Errors and lifecycle edges

**Cancellation becomes two-phase.** Today: SIGTERM → Claude Code aborts the turn, kills its Bash
tree, runs SessionEnd hooks, exits 143. Tomorrow: `session/cancel` → the agent answers its in-flight
client requests → `stopReason: "cancelled"` → **and the Node child must still be killed**. So:
graceful cancel with a deadline, `ChildProcess.terminate()` as the backstop. `RunState.cancelled`
comes from `stopReason`; the exit code now only describes a crash.

**⛔ The terminal event is not in the log any more, and crash recovery depends on it.**
`ClaudeRun.lastResult(inLogAt:)` scans the log backwards for the terminal `result` event — that is
what lets a run whose decoder crashed still report honestly, and what `Reconciler`'s launch sweep
reads. Under ACP the `stopReason` arrives as a **response**, not a notification, so it never enters
the notification stream and never reaches the log. A run that died mid-turn would be indistinguishable
from one whose response was simply never read.

**The fix is part of the design:** Elliot writes a **synthetic terminal line** into the log when the
prompt response lands, so the log stays self-sufficient. Without it, crash recovery loses its source.

**Preflight.**

- The `claude --version` row becomes a claim about the wrong binary and is replaced by the identity
  the adapter reports for itself: `agentInfo: {name: "@agentclientprotocol/claude-agent-acp",
  version: "0.66.0"}` [M]. ⛔ The adapter resolves the CLI **vendored inside
  `@anthropic-ai/claude-agent-sdk@0.3.220`**, not the `claude` on PATH — locally 2.1.228. The skew is
  structural.
- New rows: Node ≥ 22 present (26.7.0 here [M]), `npx` reachable (11.19.0 [M]), adapter resolvable.
- The `~/.claude/plugins/cache` walk **stays** — agnosticism is a non-goal, and the skills genuinely
  live there. It is complemented, not replaced, by asserting the commands are advertised.
- ⚠️ `ELLIOT_CLAUDE_PATH` stops meaning what it means. The documented escape hatch is
  `CLAUDE_CODE_EXECUTABLE`; whether pointing it at 2.1.228 works is **UNMEASURED**.

**Persistence.** Additive columns `agentSessionID`, `stopReason`. ⛔ `@DefaultsToEmpty` or `Optional`
— a non-optional new field breaks `openReadOnly` with `keyNotFound`, because Swift's synthesised
decoder emits `decode(_:forKey:)` and ignores default values. Migrations are additive and shipped
ones are frozen; an unshipped one renumbers if another lands first.
`elliotProtocolVersion` 9 → 10, so an old helper in an old bundle fails at `hello` rather than
halfway through a move.

---

## 7. Tests

**`Scripts/fake-claude.sh` must become a responder.** It prints and exits; an ACP double must
*answer* — read JSONL on stdin, serve `initialize` / `session/new` / `session/set_config_option` /
`session/prompt`, emit `session/update` frames, and be able to issue a `session/request_permission`
back at the client. **Python under `Scripts/`**, matching the existing harness: stable path, usable
by hand from a terminal (the reason `Fixtures/` sits at the repository root), driven by
`FAKE_ACP_FIXTURE` / `_MODE` / `_READY` / `_ARGV_OUT`. The existing rules hold entire: install the
trap before anything else, and never let a child outlive its parent holding the runner's stdout pipe
open.

**The fixtures are real recordings, not hand-written.** `Fixtures/acp/turn-edit-bash.json` and
`Fixtures/acp/session-new-commands.json` are verbatim transcripts of the live adapter, captured
2026-08-12. The first carries the partial-patch case of §5.1.

**The test that matters** is the merging fold, driven by the four-frame `Edit` sequence, asserting
`title` and `kind` are **still present** at the end. ⛔ Verified by breaking it — switch the merge back
to a replace and watch it go red — because a break that changes no behaviour reads as green.

**What `swift test` still cannot see is the card.** A diff appearing on screen is a layout change, and
this repository's rule is that such a change is not finished until someone has looked.
`board_screenshot window=board` works with no TCC grant.

---

## 8. Risks this design accepts

Direct replacement was chosen over a measured parity window. The risks that buys, stated plainly:

1. **Long runs are unmeasured.** `merge-pr` legitimately waits hours on CI. A held JSON-RPC connection
   over a Node child for hours is a different reliability profile from a CLI process, and the spec
   defines no keepalive. **UNMEASURED.**
2. **Concurrency is unspecified.** The analysis panel drives eight lenses in parallel. The spec states
   **no** concurrency rules — whether two `session/prompt`s may be in flight on one session is
   undefined in v1 [S]. Elliot's own scheduler limits still apply, but the mapping of runs to sessions
   and to adapter processes is a design detail the plan must settle.
3. **A new runtime dependency.** Node ≥ 22 and `npx`, plus an adapter shipping roughly every 2–3 days
   (60 releases in 4.5 months). A regression has no fallback path once `ClaudeRunner` is gone.
4. **`fs/*` and `terminal/*` are v1-only** and removed in the v2 draft [S], where the sanctioned route
   is a client-provided MCP server. This design does not use them, which limits the exposure, but the
   protocol under it is moving.
5. ~~**Skill invocation end to end is unmeasured.**~~ Resolved [M] 2026-08-13 (§2.2):
   `get-repo-profile` ran end to end over ACP in a scratch checkout. One skill, one machine — not a
   guarantee for `create-issue`/`implement-issue`/`merge-pr`, which are unprobed because their
   failure mode is not harmless, but the mechanism (slash command → ordinary tool calls, no distinct
   `Skill` tool-call marker) is now established rather than assumed.
6. **The refusal discriminator is an unversioned adapter convention, not a protocol field.** §5.4's
   `_meta.claudeCode.nonExecutionKind` is forwarded verbatim from a Claude Code CLI sidecar the
   adapter's own source calls an *"open set"* with *"no enum check."* Elliot's fold
   (`RunScheduler.state(for:)`) reads adapter behaviour that could gain a new value on a CLI upgrade
   with no ACP version bump to signal it, and only one shape of refusal
   (`PreToolUse` hook block) has been provoked. An unrecognized value is defined to read as
   UNMEASURED rather than default to denial, but that only bounds the failure mode — it does not
   remove the dependency on an interface neither Anthropic's ACP spec nor the SDK's own `.d.ts`
   documents.

---

## 9. Scope, honestly

This is a large change and it cannot ship half-done: the moment `ClaudeRunner` is deleted, the
vendored library, the transport, the runner, the event model, the fold, the card, Preflight and the
migrations must all work at once. That is the consequence of choosing direct replacement over a
parity window, and it is accepted deliberately.

But one stage **is** separable, and it should be built and merged before any Elliot type is touched:

> **Stage 0 — the wire layer, proven against the live adapter.** Vendor the library per §3.4, put the
> transport on `ChildProcess`, fix the ~32 concurrency diagnostics, and drive a real
> `claude-agent-acp` from Swift: `initialize` → `session/new` → `session/set_config_option` →
> `session/prompt` → collect `session/update` → `stopReason`. Nothing in `ElliotEngine`,
> `ElliotModel` or `ElliotAppKit` changes. It is verifiable on its own, it retires the largest
> remaining uncertainty, and it is where the two open probes belong — skill invocation end
> to end (§2.2) and what a real refusal looks like under `bypassPermissions` (§5.4).

If Stage 0 fails, nothing else was built on top of it. If it succeeds, the rest is a rewrite with a
known target.

---

## 10. Reproducing every measurement

The two ACP probes are committed under `Scripts/probe/` rather than left in a scratchpad, because a
probe whose result is kept but whose code is not is an unverifiable measurement. Both are read-only:
`acp_probe.py` sends `initialize` and `session/new` and nothing else, so it executes nothing in the
target checkout.

```bash
# adapter identity, session/new, advertised commands  → Fixtures/acp/session-new-commands.json
ACP_CWD="$PWD" ACP_DUMP=/tmp/acp-commands.json python3 Scripts/probe/acp_probe.py

# one full turn at bypassPermissions                  → Fixtures/acp/turn-edit-bash.json
# ⛔ run this against a throwaway checkout, never a real one: it edits files.
mkdir -p /tmp/elliot-acp-sandbox && cd /tmp/elliot-acp-sandbox && git init -q
printf 'line one\nline two\nline three\n' > notes.txt
ACP_CWD=/tmp/elliot-acp-sandbox ACP_MODE=bypassPermissions \
  ACP_DUMP=/tmp/acp-turn.json \
  ACP_PROMPT='Append a fourth line saying "line four" to notes.txt, then run `wc -l notes.txt` and tell me the count. Keep it brief.' \
  python3 Scripts/probe/acp_turn.py
```

**§2.2 and §5.4's three recipes** (2026-08-13), each against its own throwaway `git init` checkout
with no `origin`, none reused across recipes because measurement 2's hook must not contaminate the
other two:

```bash
# §2.2 — a plugin skill driven end to end             → Fixtures/acp/turn-skill-invocation.json
rm -rf /tmp/elliot-acp-skill && mkdir -p /tmp/elliot-acp-skill
cd /tmp/elliot-acp-skill && git init -q && echo '# scratch' > README.md
git add -A && git -c user.email=probe@local -c user.name=probe commit -qm init
ACP_CWD=/tmp/elliot-acp-skill ACP_MODE=bypassPermissions \
  ACP_PROMPT='/ai-migration-kit:get-repo-profile' \
  ACP_DUMP=/tmp/acp-skill.json ACP_TURN_WAIT=900 \
  python3 Scripts/probe/acp_turn.py
test -f /tmp/elliot-acp-skill/.claude/skills/repo-profile.md && echo "SKILL RAN" || echo "SKILL DID NOT RUN"

# §5.4 — a real refusal, provoked by a PreToolUse hook → Fixtures/acp/turn-refusal.json
rm -rf /tmp/elliot-acp-skill2 && mkdir -p /tmp/elliot-acp-skill2/.claude
cd /tmp/elliot-acp-skill2 && git init -q && echo '# scratch' > README.md
git add -A && git -c user.email=probe@local -c user.name=probe commit -qm init
cp Fixtures/acp/refusal-hook-settings.json .claude/settings.json
ACP_CWD=/tmp/elliot-acp-skill2 ACP_MODE=bypassPermissions \
  ACP_PROMPT='Run `echo hello` with the Bash tool and tell me what it printed.' \
  ACP_DUMP=/tmp/acp-refusal.json python3 Scripts/probe/acp_turn.py

# §5.4 — the contrast case: a genuine tool failure, no hook → Fixtures/acp/turn-ordinary-failure.json
rm -rf /tmp/elliot-acp-failure && mkdir -p /tmp/elliot-acp-failure
cd /tmp/elliot-acp-failure && git init -q && echo '# scratch' > README.md
git add -A && git -c user.email=probe@local -c user.name=probe commit -qm init
ACP_CWD=/tmp/elliot-acp-failure ACP_MODE=bypassPermissions \
  ACP_PROMPT='Use the Read tool to read the file /tmp/elliot-acp-failure/definitely-does-not-exist-abc123.txt and tell me exactly what happened.' \
  ACP_DUMP=/tmp/acp-failure.json python3 Scripts/probe/acp_turn.py
```

The two Swift measurements are not committed — they build throwaway packages against a clone. To
reproduce: clone `wiedymi/swift-acp` at `9498537`, then

- **as a 5.9 dependency under our floor → 0 errors, 0 warnings.** Make a package declaring
  `// swift-tools-version: 6.3.1`, `platforms: [.macOS(.v15)]`, `swiftLanguageModes: [.v6]`, depending
  on the clone by `.package(path:)`, with a source that holds the client in an `actor` and touches it
  from `nonisolated` and `@MainActor` contexts. `rm -rf .build && swift build > log 2>&1`.
- **its own sources under `.v6` → 33 errors in 3 files.** In the clone itself, change the manifest's
  first line to `// swift-tools-version: 6.3.1`, raise the platform to `.macOS(.v15)`, add
  `swiftLanguageModes: [.v6]`. Same build command.
- **`_meta` survival** — decode a `session/update` frame carrying
  `_meta.claudeCode.{toolName,nested,list}`, a `RequestPermissionRequest` carrying the same, and
  re-encode then re-decode the first.

⚠️ Redirect as `> log 2>&1`, never `2>&1 > log` — the latter sends stderr to the *old* stdout, so
warnings never reach the file. That mistake was made once while producing this document and corrected;
the first warning count it produced was meaningless.

Toolchain: Apple Swift 6.3.3 (swiftlang-6.3.3.1.3), target arm64-apple-macosx26.0.
