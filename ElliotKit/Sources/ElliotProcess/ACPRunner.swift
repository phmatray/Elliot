import ACP
import ACPModel
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
    /// `AgentRun.start` throws `AgentInvocationError.unmappableAllowedTools` **before it
    /// constructs an `AgentSession`**, so a refusal spawns nothing. (This line named
    /// `AgentSession.start` until Task 7 wrote the throw site; no such method has ever existed.)
    /// `RunScheduler.start`'s existing `catch` already turns it into a failed run with an
    /// Elliot-authored sentence, and Preflight gains a row (Task 16) so the operator meets it
    /// before a drag rather than after.
    public var extraAllowedTools: [String]
    public var extraDirectories: [String]
    /// `--max-budget-usd` is gone with the CLI; the ceiling is rebuilt on live `usage_update` +
    /// `session/cancel`, in `AgentRun.start`'s notification consumer. `nil` means no ceiling —
    /// the default.
    ///
    /// ⚠️ **A brake, not a guarantee — say so wherever this is read.** `RunUsage.costUSD` is
    /// intermittent, and re-deriving that from the recordings rather than repeating it made it
    /// worse than "intermittent": across the four transcripts in `Fixtures/acp/turn-*.json`, cost
    /// is reported **exactly once per turn, on the last `usage_update` before the `session/prompt`
    /// response** — 4 cost-bearing frames out of 42, at element 31 of 34, 17 of 20, 18 of 21 and
    /// 99 of 102, each one immediately preceding the reply. This comment said "absent from the
    /// first nine frames and present on the tenth", which was `turn-edit-bash.json` alone and read
    /// as *late in the turn* where the recording says *as the turn ends*.
    ///
    /// ⛔ **So on the evidence that exists this cannot stop a turn in flight, and must not be
    /// written up as if it could.** The spend between reports is unbounded and the one report
    /// arrives when there is nothing left to stop. What the ceiling buys is the **verdict** —
    /// `AgentRun.maxBudgetStopReason` and `isError`, which Task 15 folds to `.failed` — so a run
    /// that overspent is marked as such instead of reading as a success. The `session/cancel` it
    /// sends is real, and `theBrakeAsksTheAgentToStop` pins that Elliot sends it; it is simply
    /// unlikely, on these four recordings, to arrive before the turn has ended on its own. That is
    /// also the honest reading of the 13-of-15 empty-stderr measurement recorded on that test:
    /// `fake-acp.py` replying in the same breath as the cost frame is not an artefact of the
    /// double, it is the recorded ordering.
    ///
    /// ⚠️ **Unmeasured**: whether a turn longer or costlier than these four reports cost mid-flight.
    /// Four recordings of one adapter version is what exists, and a fifth could change this.
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

/// What a run has to say for itself once it is over.
///
/// ⚠️ Task 9 owns this type and finishes it; it is declared here because `AgentUpdate.finished`
/// cannot name a type that does not exist. `sessionResumeFailed` is Task 13's and carries its
/// default so that either task's call sites keep compiling across the other.
public struct AgentRunOutcome: Sendable {
    /// The adapter process's exit code.
    ///
    /// ⚠️ **A crash, and nothing else.** Under `claude -p`, 143 meant a SIGTERM Elliot had sent
    /// and `wasTerminated` was Elliot's own flag, so cancellation was readable straight off the
    /// process — `RunScheduler.swift:1031` is literally `if outcome.wasTerminated { return
    /// .cancelled }`. Under ACP a cancelled run's Node child is killed **after** the protocol has
    /// already said what happened, so `RunState.cancelled` comes from `stopReason` (Task 15) and
    /// this number only describes a process that died. A clean turn from an agent that then exits
    /// nonzero is still a clean turn.
    ///
    /// ⚠️ **The unmeasured case is the one where the backstop fires before any `stopReason`
    /// arrives** — Elliot asked to cancel and the agent never got to answer, which is exactly what
    /// `ACPRunnerTests.cancelIsTwoPhase` drives. `summary` is `nil` then, and Task 15 must fold
    /// that to `.cancelled` **if Elliot asked for the cancellation** and to `.failed` otherwise.
    /// That distinction is carried by `RunScheduler`'s own knowledge — it writes `.cancelling`
    /// before calling `cancel()` — and **not** inferred from this number: the design's risk 1
    /// leaves long-held connections unmeasured, and from the outside a killed adapter is
    /// indistinguishable from a crashed one.
    public var exitCode: Int32
    /// `nil` when the response never arrived — the run died mid-turn.
    public var summary: TurnSummary?
    /// The id the **agent** chose at `session/new`, `nil` if the handshake never got that far.
    public var agentSessionID: String?
    /// Where a failed `npx` resolution, a Node stack trace or a missing `CLAUDE_CODE_EXECUTABLE`
    /// lands.
    public var stderr: String
    public var sessionResumeFailed: Bool

    public init(
        exitCode: Int32,
        summary: TurnSummary?,
        agentSessionID: String?,
        stderr: String,
        sessionResumeFailed: Bool = false
    ) {
        self.exitCode = exitCode
        self.summary = summary
        self.agentSessionID = agentSessionID
        self.stderr = stderr
        self.sessionResumeFailed = sessionResumeFailed
    }
}

/// One thing a live run has to say, as it says it. The successor to `RunUpdate`.
public enum AgentUpdate: Sendable {
    case started(pid: Int32)
    case event(RunEvent)
    /// No output for longer than the idle window. The run is still alive; the user decides
    /// whether to keep waiting.
    case stalled(since: Date)
    /// Output again, after a silence that had already been announced.
    case resumed
    case finished(AgentRunOutcome)
}

extension AgentUpdate {
    /// The one place a silence notice becomes an update.
    ///
    /// Both announcing sites — the output mirror and the idle watchdog — go through this, so the
    /// two directions cannot be wired up differently. The switch is exhaustive with no `default`,
    /// so a third direction added to `RunSilence` is a compile error here rather than a notice
    /// that reaches one site and not the other, which is the shape of the defect `RunSilence`
    /// exists to end. `RunUpdate.announcing` states the same rule for the CLI runner; the two are
    /// the same three lines because they are one *decision* rendered into two enums, and the
    /// older one dies when Task 18 deletes `ClaudeRunner.swift`.
    static func announcing(_ notice: RunSilence, lastOutput: Date) -> AgentUpdate {
        switch notice {
        case .wentQuiet: .stalled(since: lastOutput)
        case .startedTalkingAgain: .resumed
        }
    }
}

/// One live ACP turn: the handshake, the prompt, the notifications it streams, and the raw log.
///
/// The successor to `ClaudeRun`, and deliberately the same shape where the shape was right — the
/// `Locked(IdleWatch(…))`, the `bufferingNewest(512)` update stream, the idle poll at
/// `min(idleTimeout, .seconds(30))`, and no wall-clock kill, because `merge-pr` waiting hours on
/// CI is legitimate and silence is the useful signal.
///
/// Three things differ, and each is a consequence of ACP being a conversation rather than a
/// command:
/// 1. The log has **three** writers, not one: the raw stdout mirror plus Elliot's own
///    `elliot/session` and `elliot/terminal` records. `AgentLog.Writer` is what keeps them from
///    interleaving mid-frame — its doc comment carries the argument.
/// 2. `start` is synchronous and the handshake is not, so the turn runs in a `Task` and every
///    failure it can meet arrives as `.finished` with a `nil` summary rather than as a `throw`.
///    The one exception is the refusal below, which happens before anything is spawned.
/// 3. The session is an owner with a lifetime (#381). Every exit path ends it; a path that
///    returned without doing so would leak a `bypassPermissions` agent into a real checkout.
public final class AgentRun: Sendable {
    /// `internal` rather than `private`, the way `AgentSession.transport` is: production reaches
    /// the agent through `cancel()` and needs nothing else, and the one other reader is
    /// `ACPRunnerTests`, which arms a deadline able to end this agent from outside. It needs one
    /// because every `Client` request this run makes reaches `sendRequest(…, timeout: nil)`,
    /// which no `withTimeout` can bound — see `armKiller`'s doc comment
    /// (`Tests/TestSupport/ArmedKiller.swift`).
    let session: AgentSession

    public let updates: AsyncStream<AgentUpdate>

    /// What `SkillRun.argv` is stamped with. ⚠️ The same three tokens for every run — see
    /// `AgentInvocation.displayArgv` for why that is a recorded loss rather than a tidier record.
    public let argv: [String]

    /// Synchronous, which is the whole reason `AgentSession.processIdentifier` is `nonisolated`.
    public var processIdentifier: Int32 { session.processIdentifier }

    /// This run's cancel grace. The static below is the default, exactly as `defaultIdleTimeout`
    /// is for `idleTimeout` — a test that drives a real cancel needs a short one, and ten seconds
    /// of sleeping would otherwise be paid on every `swift test`.
    private let cancelGrace: Duration

    /// The two things `cancel()` needs that do not exist yet when an `AgentRun` is handed back.
    ///
    /// `start` returns the moment the child is spawned; the handshake and the turn happen in a
    /// `Task` afterwards, so neither of these can be a stored value settled in `init`. A `Locked`
    /// rather than an actor because both writers are already inside one — the turn task and
    /// `cancel()` — and neither needs to await the other.
    private struct CancelState: Sendable {
        /// Written the instant `session/new` returns, and **before** the `.session` event is
        /// yielded, so an observer that has seen that event knows a cancel will name a session.
        /// `nil` means the handshake never got that far, which `cancel()` treats as "nothing to
        /// ask" rather than "ask anyway".
        var sessionId: SessionId?
        /// The armed backstop, held so the turn task can stand it down when the agent answers
        /// inside the window.
        var deadline: Task<Void, Never>?
    }
    private let cancelState: Locked<CancelState>

    /// Asks the run to stop, then makes sure it has.
    ///
    /// **Two phases, and the second is not optional.** `session/cancel` asks the agent to stop: it
    /// answers whatever client requests are in flight and ends the turn with
    /// `stopReason: "cancelled"`, which is the word `RunState.cancelled` is read off (Task 15).
    /// What it does **not** do is end the Node child — so `end()` still has to, and Task 1's
    /// SIGTERM→SIGKILL escalation is what does it. Under `claude -p` cancelling was one act, a
    /// SIGTERM; splitting it is what buys a cancelled run a verdict instead of only a corpse.
    ///
    /// Fire-and-forget, because `RunScheduler.cancel` is: it writes `.cancelling` and calls this,
    /// and the terminal update is what finishes the job. Making this `async` would change that
    /// call site's shape for nothing, so both phases live in `requestCancel`, below. Safe to call
    /// after the run has already finished — `end()` is idempotent.
    ///
    /// The mechanism is `requestCancel(session:cancelGrace:cancelState:)`, a `static` free
    /// function rather than a second body on this method: the spend brake in `start`'s `Task`
    /// needs to reach it before an `AgentRun` exists to call it on — `session`, `cancelGrace` and
    /// `cancelState` are locals there long before the value this method lives on is constructed
    /// and returned. One mechanism, two callers, rather than the brake growing its own copy of a
    /// sequence this file already spends a paragraph explaining how not to get wrong.
    public func cancel() {
        Self.requestCancel(session: session, cancelGrace: cancelGrace, cancelState: cancelState)
    }

    /// The two-phase ask-then-kill sequence `cancel()` performs — see its doc comment for why
    /// this is a free function and not inlined there.
    private static func requestCancel(
        session: AgentSession, cancelGrace: Duration, cancelState: Locked<CancelState>
    ) {
        let client = session.client
        let grace = cancelGrace
        let sessionId = cancelState.withLock { $0.sessionId }

        // ⛔ **A detached deadline, not a race.** The obvious shape — `sendPrompt` beside a sleep
        // in a task group — cannot work, and fails in the one case this method exists for.
        // `sendPrompt` reaches `sendRequest(…, timeout: nil)`, which suspends on a bare
        // `withCheckedThrowingContinuation` observing no cancellation, and a structured scope
        // cannot exit while a child of it is still running; `cancelAll()` asks and does not evict.
        // The group would never return and the kill below would never be reached. It is the same
        // trap `Client.terminate()` documents one layer down and `armKiller` one layer up.
        //
        // ⚠️ It cannot be written as a `withCheckedContinuation` here either:
        // `DrainDuplicationTests.pipeHandlingIsNotDuplicated` refuses that shape anywhere in
        // `Sources/ElliotProcess` outside the sanctioned `ACPTransport.swift` pair.
        let deadline = Task {
            if let sessionId {
                // ⚠️ **Swallowed deliberately, and this is not a missing error path.**
                // `sendCancelNotification` is `async throws` and can fail two ways, both of them
                // "the agent is already beyond asking":
                //
                // 1. `ProcessError.stdinClosed`, from the write itself — `ACPTransport.send` →
                //    `ChildProcess.writeStdin` on a stdin that `ACPTransport.close()` has already
                //    closed. **This is the common one on the brake's path**, and it is what this
                //    comment used to miss: measured with a `do`/`catch` at this site, 19 of 20
                //    `MODE=ok` samples threw it while the child was still running.
                // 2. `ClientError.processNotRunning`, from its first statement — `guard await
                //    transport.isConnected`, and `ACPTransport.isConnected` is `child.isRunning`,
                //    so this is the agent having actually exited or crashed. Not once in those 20
                //    samples; `stdinClosed` gets there first, because closing stdin precedes the
                //    child noticing.
                //
                // ⛔ It is **not** `CancellationError`, however this task is cancelled: nothing
                // between here and the write observes cancellation. `brake()`'s ⚠️ carries that
                // measurement and the correction it replaced.
                //
                // On the live path — the one an operator cancelling an in-flight run takes — the
                // notification is delivered, which is what `cancelIsTwoPhase`'s stderr receipt
                // pins. Nothing is reported on any of these paths: the phase below kills the child
                // regardless, and a cancel that could not be delivered to an agent already gone is
                // not a failure of cancellation. Handling it would turn a successful cancel into a
                // failed one.
                try? await client.sendCancelNotification(sessionId: sessionId)

                // ⛔ `do`/`catch`, never `try? await Task.sleep(…)`: `try?` swallows
                // `CancellationError` and falls straight through, so standing this deadline down
                // would **trigger** the kill instead of cancelling it. That is #380's killer bug,
                // and `armKiller`'s doc comment records that it took two wrong attempts to see.
                do {
                    try await Task.sleep(for: grace)
                } catch {
                    return  // the turn answered inside the window; its own path ends the session
                }
            }
            // The backstop, and the only phase that is unconditional. Reached immediately when
            // there is no session id: nothing has been asked, so there is nothing to wait for —
            // and the commonest reason a run has none is a handshake that is itself wedged, which
            // is exactly when an operator reaches for cancel.
            await session.end()
        }
        cancelState.withLock { $0.deadline = deadline }
    }

    private init(
        session: AgentSession,
        updates: AsyncStream<AgentUpdate>,
        argv: [String],
        cancelGrace: Duration,
        cancelState: Locked<CancelState>
    ) {
        self.session = session
        self.updates = updates
        self.argv = argv
        self.cancelGrace = cancelGrace
        self.cancelState = cancelState
    }

    /// How long a run may say nothing before the silence is announced.
    public static let defaultIdleTimeout: Duration = .seconds(20 * 60)

    /// How long a cancelled agent has to answer before its child is killed anyway.
    ///
    /// Ten seconds because the graceful phase is bookkeeping — the agent answering its in-flight
    /// client requests and returning a stop reason — not the turn's remaining work. ⚠️ It is **not**
    /// a second idle window and must not grow into one: there is deliberately no wall-clock kill
    /// for a live turn, since `merge-pr` waiting hours on CI is legitimate. This window only opens
    /// once somebody has asked the run to stop.
    public static let cancelGrace: Duration = .seconds(10)

    /// The stop reason Elliot writes over the agent's own when `AgentInvocation.maxBudgetUSD` is
    /// crossed. Deliberately not a case of `ACPModel.StopReason` — that type is vendored and
    /// describes what the *agent* can say; this is what *Elliot* decided, and `TurnSummary
    /// .stopReason`'s doc comment already allows for "or an unrecognised string" so a brake needs
    /// no case of its own. A named constant rather than the literal repeated at every reader —
    /// Task 15's `state(for:)` is the next one.
    public static let maxBudgetStopReason = "elliot/max_budget"

    public static func start(
        invocation: AgentInvocation,
        agent: ACPAgentProcess,
        logURL: URL,
        idleTimeout: Duration = AgentRun.defaultIdleTimeout,
        cancelGrace: Duration = AgentRun.cancelGrace
    ) throws -> AgentRun {
        // ⛔ Before anything is spawned. A refusal that started an agent and threw afterwards
        // would still have run one, at `bypassPermissions`, inside a real checkout.
        guard invocation.extraAllowedTools.isEmpty else {
            throw AgentInvocationError.unmappableAllowedTools(invocation.extraAllowedTools)
        }

        // The durable sink is a file, not the database: the UI stream is bounded and may drop,
        // this never does.
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        let writer = AgentLog.Writer(try FileHandle(forWritingTo: logURL))

        // One box, not two. The clock reading and the announce latch are a single decision — "is
        // this the byte that ends an announced silence?" cannot be answered by either half alone.
        let idleWatch = Locked(IdleWatch(lastOutput: Date()))

        // A local, not a stored property set later: the turn task below is created before the
        // `AgentRun` exists, and it is one of the two writers.
        let cancelState = Locked(CancelState())

        var continuation: AsyncStream<AgentUpdate>.Continuation!
        let updates = AsyncStream<AgentUpdate>(bufferingPolicy: .bufferingNewest(512)) {
            continuation = $0
        }
        let updateContinuation = continuation!

        let session: AgentSession
        do {
            session = try AgentSession(agent, stdoutMirror: { chunk in
                // Both of these happen under `ChildProcess`'s drain lock, which is the point: a
                // mirror that deferred either could write into a file already closed, or announce
                // a recovery into a stream the final drain has already finished.
                writer.mirror(chunk)
                let announcement = idleWatch.withLock { watch -> AgentUpdate? in
                    guard let notice = watch.sawOutput(at: Date()) else { return nil }
                    return .announcing(notice, lastOutput: watch.lastOutput)
                }
                if let announcement { updateContinuation.yield(announcement) }
            })
        } catch {
            // Nothing is running and nothing will write, but the handle is already open, so it is
            // this path's to close.
            writer.close()
            throw error
        }

        // ⚠️ Yielded here rather than after the handshake, which is where the plan's step list put
        // it. The pid exists from the spawn, and a handshake that fails — an `npx` that cannot
        // resolve the adapter, a Node that dies on start — would otherwise leave the run with no
        // pid ever reported, so nothing could show it or kill it. `ClaudeRun.start` yields at the
        // same moment, for the same reason.
        updateContinuation.yield(.started(pid: session.processIdentifier))

        let client = session.client
        let transport = session.transport

        // Unattended stays unattended (#381's first bounding decision): there is no answering UI,
        // so this is the only answer any `session/request_permission` gets. Declared here, outside
        // the `Task` below, and captured by it for the run's whole lifetime — `Client.delegate` is
        // held `weak` (`Client.swift:59`), so a policy that were only a local *inside* that closure
        // would still work, but declaring it here matches every other per-run value this function
        // hands the closure (`writer`, `idleWatch`) rather than being the one exception.
        let policy = PermissionPolicy(mode: invocation.permissionMode)

        Task {
            // What the notification consumer has folded, read once that consumer has finished.
            let seen = Locked(TurnState())

            // Watch for silence. `min` leaves the shipped twenty-minute window polling exactly as
            // it did, and stops a shorter one — the only way a test reaches this loop at all —
            // being announced up to thirty seconds after it was crossed.
            let idleTask = Task {
                let interval = min(idleTimeout, .seconds(30))
                while !Task.isCancelled {
                    try? await Task.sleep(for: interval)
                    guard !Task.isCancelled else { break }
                    let announcement = idleWatch.withLock { watch -> AgentUpdate? in
                        guard let notice = watch.tick(now: Date(), idleTimeout: idleTimeout)
                        else { return nil }
                        return .announcing(notice, lastOutput: watch.lastOutput)
                    }
                    if let announcement { updateContinuation.yield(announcement) }
                }
            }

            var consumer: Task<Void, Never>?
            var agentSessionID: String?
            var response: SessionPromptResponse?

            // The per-run spend ceiling (Task 11): written only from the notification consumer
            // below, and read again after `await consumer?.value` has returned, to decide the
            // summary. That barrier is what makes the later read safe in spirit as well as in
            // the lock — by the time anyone reads it for the summary, the only writer has
            // finished.
            let brakedByElliot = Locked(false)

            // `maxBudgetUSD`'s doc comment carries the caveat this keeps: a brake, not a
            // guarantee, because `RunUsage.costUSD` is intermittent and this can only fire on a
            // frame that reports one. Idempotent on the flag rather than on `requestCancel`
            // itself — a second crossing must not re-ask an agent that has already been asked to
            // stop, which would arm a second grace deadline that silently replaces the first in
            // `cancelState`.
            //
            // ⚠️ **A third caveat: on a turn that ends in the same breath, the ask is written
            // into a pipe the turn's own teardown has already closed.** `requestCancel`'s phase 1
            // — `sendCancelNotification` — reaches `ACPTransport.send` →
            // `ChildProcess.writeStdin`, and the turn task below runs `await session.end()` →
            // `Client.terminate()` → `ACPTransport.close()` → `closeStdin()` as soon as
            // `sendPrompt` returns. The write then finds `stdinState == .closed` and throws
            // `ProcessError.stdinClosed`, which phase 1's `try?` swallows: no `session/cancel` is
            // written and nothing reports that none was.
            //
            // ⛔ **It is not a `CancellationError`, and this comment said it was.** The hygiene
            // line below does cancel the deadline task, but nothing on the path from there to the
            // write observes cancellation — `Client` is an actor, `sendCancelNotification` awaits
            // only actor hops plus `transport.send`, and that bottoms out in a bare
            // `withCheckedThrowingContinuation`. Instrumented with a `do`/`catch` and a
            // `Task.isCancelled` reading at this exact site: under `MODE=ok`, **19 of 20 samples
            // threw `ProcessError.stdinClosed`** and 1 sent successfully; `Task.isCancelled` was
            // **false in 19 of 20**, and the single sample where it was *true* still threw
            // `stdinClosed` rather than `CancellationError`. Under `MODE=deaf-after-fixture`, 5 of
            // 5 sent successfully, never cancelled. The throw is not `processNotRunning` either:
            // `sendCancelNotification`'s own `guard await transport.isConnected` passed every
            // time, because the child is still alive — it is only its stdin that has gone.
            //
            // The loss is **benign** — that shape is a turn that had already ended, and cancelling
            // an ended turn buys nothing — but it is why `theBrakeAsksTheAgentToStop` pins the ask
            // under `MODE=deaf-after-fixture`, where the turn stays open, rather than under a
            // scenario where the absence would look like flakiness.
            //
            // ⛔ Hoisting phase 1 out of the deadline task does **not** recover it, and the
            // corrected mechanism is why: what beats the write is stdin closing, not the task
            // being cancelled, so the same write would meet the same closed pipe wherever it was
            // issued from. Recovering the ask would mean ordering it *ahead of* teardown — a
            // synchronisation between two tasks that nothing here builds and nothing has measured.
            // And read `requestCancel`'s own ⛔ before restructuring anyway: that objection is
            // structural (the task-group shape deadlocks) and stands on its own evidence,
            // independent of this one.
            func brake() {
                let already = brakedByElliot.withLock { flag -> Bool in
                    let was = flag
                    flag = true
                    return was
                }
                guard !already else { return }
                Self.requestCancel(session: session, cancelGrace: cancelGrace, cancelState: cancelState)
            }

            do {
                // Set before the handshake even starts — well ahead of the one requirement,
                // "before `sendPrompt`" — so no byte has gone to the child when it returns.
                //
                // ⚠️ That is the honest bound, and it is weaker than "nothing can race it", which
                // is what this comment said until review. `Client.setDelegate` assigns its own
                // `weak var delegate` synchronously but forwards to `requestRouter` inside an
                // unstructured `Task` (`Vendor/swift-acp/ACP/Client.swift:192-196`) — and the
                // router's copy is the one that actually dispatches `session/request_permission`
                // (`RequestRouter.swift:235-247`). So the ordering rests on that `Task` running
                // before the first inbound request, which needs a full round trip through a
                // spawned child and several awaits. **Unmeasured, not guaranteed**: no losing case
                // has been constructed, and the code is vendored and untouched here. Naming it
                // beats leaving a guarantee nothing enforces.
                await client.setDelegate(policy)

                // `fs`/`terminal` are declared **false**: they are v1-only, removed in the v2
                // draft, and this design uses neither.
                let hello = try await client.initialize(
                    protocolVersion: 1,
                    capabilities: ClientCapabilities(
                        fs: FileSystemCapabilities(readTextFile: false, writeTextFile: false),
                        terminal: false
                    )
                )

                // ⛔ `mcpServers: []` is deliberate and **not** an omission: measured, a session
                // with an empty list still sees the operator's globally-registered servers, and
                // explicit supply is *additive*. That is why `PermissionMode.appraisal`'s cap must
                // stay — an appraisal's agent can still see the `elliot` server and call
                // `board_move_card`.
                let opened = try await client.newSession(
                    workingDirectory: invocation.cwd,
                    additionalDirectories: invocation.extraDirectories,
                    mcpServers: []
                )
                agentSessionID = opened.sessionId.value
                // Before the `.session` event is yielded, and before the `set_config_option` that
                // follows: from here on a `cancel()` can name a session to the agent rather than
                // going straight to the backstop. An observer that has seen `.session` has
                // therefore already seen this write.
                cancelState.withLock { $0.sessionId = opened.sessionId }

                // ⚠️ Written the instant `session/new` returns, and **before**
                // `session/set_config_option` — so it is the first `method`-bearing line in the
                // log, ahead of the `current_mode_update` the adapter emits while answering that
                // call. `mode` is therefore what Elliot is *about to* set rather than something
                // already confirmed, and that is honest: the very next statement is the set, and a
                // set that fails aborts the turn before any prompt is sent. What the field records
                // is the mode this run was started under.
                let info = RunSessionInfo(
                    agentSessionID: opened.sessionId.value,
                    agentName: hello.agentInfo?.name,
                    agentVersion: hello.agentInfo?.version,
                    cwd: invocation.cwd,
                    model: Self.model(in: opened),
                    mode: AgentInvocation.configValue(for: invocation.permissionMode)
                )
                writer.record(AgentLog.sessionLine(info))
                updateContinuation.yield(.event(.session(info)))

                // ⚠️ `client.notifications` is a single-consumer `AsyncStream`. Exactly one task
                // may iterate it, ever — `MessagesSingleConsumerTests` states the same rule one
                // layer down for `transport.messages`. Started before the first call that makes
                // the adapter say anything; it would be safe later too, since that stream buffers
                // unboundedly, but arriving live is the point of streaming it at all.
                consumer = Task {
                    for await notification in await client.notifications {
                        guard notification.method == "session/update" else { continue }
                        let raw = (try? JSONEncoder().encode(notification.params)) ?? Data()
                        var events: [RunEvent]
                        do {
                            let note = try JSONDecoder().decode(
                                SessionUpdateNotification.self, from: raw)
                            events = RunEventMapper.events(from: note)
                        } catch {
                            // ⛔ This `catch` is the only thing in the package that can produce
                            // `RunEvent.unreadable`. `ACPModel.SessionUpdate.init(from:)` throws
                            // `DecodingError` on a `sessionUpdate` string this build has never
                            // seen (`ACPModel/Updates.swift`, the `default:` arm), so without it
                            // the line is dropped in silence, that case is unreachable from
                            // anywhere in the package, and `RunEvent`'s own totality claim — "a
                            // schema change in a future adapter release degrades one row instead
                            // of breaking the runner" — is a claim nothing implements.
                            events = [.unreadable(raw: raw, error: String(describing: error))]
                        }
                        for event in events {
                            seen.withLock { $0.fold(event) }
                            // Task 11's brake: `if let ceiling …, let spent …, spent >= ceiling`,
                            // stated once here rather than inside `brake()` itself, because the
                            // condition is what varies per event and the action is what does not.
                            if case .usage(let usage) = event,
                                let ceiling = invocation.maxBudgetUSD,
                                let spent = usage.costUSD,
                                spent >= ceiling
                            {
                                brake()
                            }
                            updateContinuation.yield(.event(event))
                        }
                    }
                }

                _ = try await client.setConfigOption(
                    sessionId: opened.sessionId,
                    configId: SessionConfigId("mode"),
                    value: SessionConfigValueId(
                        AgentInvocation.configValue(for: invocation.permissionMode))
                )

                // The prompt is already fully rendered by `SlashCommandBuilder` and stored
                // verbatim on `SkillRun.prompt`; nothing here re-renders it.
                //
                // ⚠️ Whether the adapter honours a `/plugin:skill` slash command sent as one
                // opaque text block is established for **one** skill — `get-repo-profile`, which
                // ran end to end at `bypassPermissions` and reproduced four private names and a
                // private exit code from `repo-profile.sh` without ever reading the instructions
                // that name them. `create-issue`, `implement-issue` and `merge-pr` are
                // deliberately unprobed, because their failure mode is not harmless.
                response = try await client.sendPrompt(
                    sessionId: opened.sessionId,
                    content: [.text(TextContent(text: invocation.prompt))]
                )
            } catch {
                // ⚠️ No terminal line: the absence **is** the fact, and it is what lets a run that
                // died mid-turn be told apart from one that ended. `summary` stays nil, `exitCode`
                // carries the adapter's, and `stderr` carries whatever it managed to say.
            }

            // ⚠️ **Hygiene, not a guarantee — and measured as such.** Deleting this line leaves
            // the whole suite green, because everything it could affect is already idempotent:
            // a deadline left armed simply ends a session that has ended. What it buys is that the
            // sleeping `Task` — which captures `session`, and through it the transport, the
            // `ChildProcess` and the `Process` — is released now rather than up to `cancelGrace`
            // later. That graph being held past its owner's life is #381's entire subject, so
            // holding it for ten seconds after every cancel is the wrong direction even when it
            // changes no behaviour. Do not read it as the thing that stops a double-kill; `end()`
            // is. Nothing is lost when `cancel()` has not stored a deadline yet, for the same
            // reason.
            cancelState.withLock { $0.deadline }?.cancel()

            // The session is the owner; a path that returned without ending it is the leak #381
            // exists to close. Idempotent, so `cancel()` having got here first costs nothing.
            await session.end()
            let exitCode = await transport.waitForExit()

            // ⛔ **The terminal line is written after this barrier, not on the prompt response.**
            // Everything it summarises — the closing prose, the last `usage_update`, every
            // `nonExecutionKind` — reaches this process through the notification consumer, and
            // that consumer is a separate task. `sendPrompt` returns when `Client` handles the
            // *response*; the notifications that preceded it are by then in the stream's buffer,
            // but nothing orders the consumer's draining of them against this task's resumption.
            // Assembling the summary at the response would therefore report the last frame's
            // usage only sometimes — and the fixture's `usage_update` is the frame immediately
            // before the reply, which makes that the ordinary case rather than a corner of it.
            // `Client.terminate()` finishes the notification stream, so the `end()` above is what
            // makes this `await` a real barrier rather than a hope.
            await consumer?.value
            idleTask.cancel()

            // ⛔ **The reader that makes `PermissionPolicy.refusals()` worth recording.** Without
            // this the ledger was appended to and then released with the policy when this closure
            // ended — a counter nobody reads, under a doc comment promising that "the log names
            // it". Read here rather than during the turn because the transport has exited and the
            // session is ended, so no further request can arrive to change it.
            //
            // Written **before** the terminal line, not after: `elliot/terminal` is what a
            // backwards scan looks for (`AgentLog.lastSummary`, Task 9) and what
            // `aTurnStreamsAndLogs` pins as the log's last method, so appending after it would put
            // a line between that scan and the summary it is hunting.
            //
            // Written independently of `response`, unlike the terminal line: a turn that died
            // mid-flight still refused whatever it refused, and that path writes no terminal line
            // at all — which is precisely the run where "the agent just looked slow" needs an
            // answer.
            let refused = policy.refusals()
            if !refused.isEmpty {
                writer.record(AgentLog.refusalsLine(refused))
            }

            var summary: TurnSummary?
            if let response {
                let assembled = Self.summary(
                    response: response,
                    seen: seen.value,
                    truncationEvents: transport.truncationEvents(),
                    braked: brakedByElliot.value
                )
                writer.record(AgentLog.terminalLine(assembled))
                summary = assembled
            }

            // ⛔ **The one close, and it is here for a reason that does not transfer from
            // `ClaudeRun`.** That runner had a single writer under the drain lock and closed once
            // `waitForExit()` had returned; this one also writes `elliot/terminal`, the line the
            // whole of Task 9 exists to guarantee. A close that won the race against it would
            // leave `AgentLog.lastSummary` answering `nil` with nothing saying why — and **the
            // caller would never notice**, because `summary` above comes from memory, so the
            // outcome yielded below would carry the verdict the file had just lost. That silence
            // is the whole hazard: what breaks is the archive, the one reader that has no memory
            // to fall back on. (An earlier draft said `RunScheduler.finish` would degrade on every
            // run; it reads the outcome, not the log — `AgentLog.lastSummary`'s doc comment
            // records why the two are deliberately not the same value.)
            // So: after the terminal record has been written (or deliberately not written, above)
            // **and** after `waitForExit()` has returned. Nothing else closes it.
            writer.close()

            updateContinuation.yield(.finished(AgentRunOutcome(
                exitCode: exitCode,
                summary: summary,
                agentSessionID: agentSessionID,
                stderr: await session.collectedStderr()
            )))
            updateContinuation.finish()
        }

        return AgentRun(
            session: session,
            updates: updates,
            argv: invocation.displayArgv(agent: agent),
            cancelGrace: cancelGrace,
            cancelState: cancelState
        )
    }

    /// What the turn has said so far, folded as it arrives.
    ///
    /// Mutated only by the notification consumer and read only after that consumer has finished,
    /// which is what makes a plain value behind a lock enough.
    private struct TurnState: Sendable {
        var text = ""
        var lastUsage: RunUsage?
        /// The last cost anyone reported, which is **not** the last frame's: cost is intermittent,
        /// so taking the last frame's could report `nil` for a turn that really did cost money.
        /// `TurnSummary.usage` states the rule; this is the half that observes it.
        ///
        /// ⚠️ **Defensive, not load-bearing — corrected after re-deriving the measurement it used
        /// to cite.** This said "absent from nine frames and present on the tenth, so taking the
        /// last frame's *would* report nil". In all four recorded transcripts the cost-bearing
        /// frame **is** the last `usage_update` of the turn (`AgentInvocation.maxBudgetUSD` carries
        /// the indices), so that failure has never been observed and this fallback is inert on
        /// every recording we hold. Kept anyway: nothing in the protocol orders those frames, one
        /// `usage_update` after the cost frame would lose the figure, and the cost is what a person
        /// reads. ⛔ But it is not evidence of an ordering anybody has seen, and citing it as such
        /// is what this edit is undoing.
        var lastCostUSD: Double?
        /// Every tool call, every frame of it already merged, plus the order they were first seen
        /// in — because `denials` is a list a person reads, and dictionary order is not an order.
        var calls: [String: ToolCallPatch] = [:]
        var callOrder: [String] = []
        /// Every `nonExecutionKind` seen, denial or not — recorded, never discarded, so an
        /// unmeasured value can be found and measured rather than silently folded.
        var nonExecutionKinds: [NonExecutionKind] = []

        /// Exhaustive over `RunEvent` with no `default`: a case added to the wire's event model
        /// has to be decided about here rather than fall silently into whichever arm somebody
        /// wrote first.
        mutating func fold(_ event: RunEvent) {
            switch event {
            case .agentText(let chunk):
                text += chunk
            case .usage(let usage):
                lastUsage = usage
                if let cost = usage.costUSD { lastCostUSD = cost }
            case .toolCall(let patch):
                if let existing = calls[patch.id] {
                    calls[patch.id] = existing.merging(patch)
                } else {
                    calls[patch.id] = patch
                    callOrder.append(patch.id)
                }
                if let kind = patch.nonExecutionKind { nonExecutionKinds.append(kind) }

            // Deliberately nothing, each for its own reason:
            case .session:
                // Elliot wrote it, and it is already the log's first record.
                break
            case .agentThought:
                // Thinking is a row in the log; it is not part of what the turn amounted to.
                break
            case .plan:
                // A draft, superseded by whatever the agent actually did.
                break
            case .modeChanged:
                // The echo of a `session/set_config_option` Elliot itself sent.
                break
            case .unreadable:
                // Already its own row. Folding it would mean guessing what it said.
                break
            }
        }
    }

    private static func summary(
        response: SessionPromptResponse, seen: TurnState, truncationEvents: Int, braked: Bool
    ) -> TurnSummary {
        var usage = seen.lastUsage
        // `used`/`size` from the last frame, because a stale context figure is simply wrong;
        // `costUSD` the last non-nil one. `TurnSummary.usage`'s doc comment is the authority, and
        // `RunLog.rows(from:denials:summary:)` applies the identical rule when it recovers a
        // summary that never carried one.
        if usage != nil { usage!.costUSD = usage!.costUSD ?? seen.lastCostUSD }

        let denials = seen.callOrder.compactMap { id -> String? in
            guard let call = seen.calls[id], call.nonExecutionKind?.isDenial == true else {
                return nil
            }
            // `_meta.claudeCode.toolName` is the real name (`Bash`, `Edit`); the title is the
            // adapter's prose and the id is a correlation token, so those are fallbacks in that
            // order rather than alternatives.
            return call.claudeToolName ?? call.title ?? call.id
        }

        return TurnSummary(
            // ⛔ **`braked` overrides both fields, whatever the response said — Task 11's whole
            // point.** Two real collisions, not a hypothetical: `brake()` itself calls
            // `requestCancel`, which sends `session/cancel` and can make a real agent answer
            // `stopReason: "cancelled"` — Elliot's own spend ceiling misreported as a user
            // cancellation, on a card whose run cost more than it was allowed to. And
            // `fake-acp.py` (like a real adapter can) writes every fixture frame and then
            // immediately replies, so `end_turn` can arrive after the brake has already decided.
            // Without the override here, which stopReason a test observes depends on which of
            // those two racing writes the notification consumer happened to have processed first
            // — intermittent, not merely wrong.
            stopReason: braked ? Self.maxBudgetStopReason : response.stopReason.rawValue,
            text: seen.text.isEmpty ? nil : seen.text,
            usage: usage,
            // ⚠️ Not the protocol's: ACP defines no per-turn token accounting at all, and the
            // adapter provides it anyway. Every field of it is optional for that reason — it may
            // vanish without an ACP version bump.
            inputTokens: response.usage?.inputTokens,
            outputTokens: response.usage?.outputTokens,
            totalTokens: response.usage?.totalTokens,
            denials: denials,
            nonExecutionKinds: seen.nonExecutionKinds,
            truncationEvents: truncationEvents,
            isError: braked ? true : response.stopReason == .refusal
        )
    }

    /// The model this session runs under, from whichever place the agent chose to say it.
    ///
    /// `models` is the protocol's field; the adapter Elliot actually talks to does not send it —
    /// measured on `Fixtures/acp/session-new-commands.json`, which carries the model as a
    /// `configOptions` entry with id `model` instead. Reading only the first would leave this
    /// field permanently `nil` against the one agent this design targets.
    private static func model(in response: NewSessionResponse) -> String? {
        if let current = response.models?.currentModelId { return current }
        guard
            let option = response.configOptions?.first(where: { $0.id.value == "model" }),
            case .select(let select) = option.kind
        else { return nil }
        return select.currentValue.value
    }
}
