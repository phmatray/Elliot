import ACP
import ACPModel
import Foundation

/// What one handshake with the ACP adapter established — and, just as carefully, what it did not.
///
/// Every field is separately absent, because the three questions Preflight asks are separately
/// answerable: *did anything spawn*, *what does it call itself*, *what does it offer*. An adapter
/// that answers `initialize` and then dies still told Elliot its version, and a row that threw that
/// away because the next call failed would be reporting less than was measured.
///
/// ⛔ `commands` is `nil` for *never established* and `[]` for *the adapter advertises none*, and
/// the two must not be collapsed. `PreflightService` renders the first as a `.warn` naming the
/// cause and the second as a finding — the two-valued answer to a three-valued question is this
/// codebase's most-catalogued defect shape, and `isBlocking([])` is the instance it cost the most.
public struct AdapterProbe: Sendable, Hashable {
    /// `initialize`'s `agentInfo.name`, nil when it never answered.
    public var agentName: String?
    public var agentVersion: String?
    /// The slash commands the adapter advertised, in the order it named them.
    public var commands: [String]?
    /// Why the probe stopped where it did. `nil` means everything it set out to read arrived.
    public var failure: Failure?

    /// ⚠️ Two cases, because they are two different verdicts on screen. A deadline that expired is
    /// a `.warn` — *"the adapter did not answer within N seconds"* is a true statement about
    /// Elliot's patience, not a finding about the adapter. A refusal or a crash is a `.fail`, and
    /// its text is the agent's or the system's own, verbatim: Elliot paraphrasing a JSON-RPC error
    /// is Elliot inventing one.
    public enum Failure: Sendable, Hashable {
        case silent(Duration)
        case error(String)
    }

    public init(
        agentName: String? = nil,
        agentVersion: String? = nil,
        commands: [String]? = nil,
        failure: Failure? = nil
    ) {
        self.agentName = agentName
        self.agentVersion = agentVersion
        self.commands = commands
        self.failure = failure
    }

    /// Whether `initialize` answered at all — the one question `agentName` alone cannot settle,
    /// since `agentInfo` is optional on the wire and an adapter may answer without naming itself.
    public var answered: Bool { agentName != nil || agentVersion != nil }
}

/// Spawns the ACP adapter, asks it who it is and what it offers, and ends it.
///
/// ⛔ **A real handshake, not a resolution probe, and the choice is forced rather than tasteful.**
/// `npx --no-install <pkg> --version` answers *is it installed*; the two rows this feeds claim to
/// show the identity the adapter reports **for itself** and the commands it **advertises**, and no
/// package-directory check can produce either string. Preflight is the screen whose whole job is to
/// be believed, so it asks.
///
/// ⛔ **And it must reach `session/new`.** Measured on `Fixtures/acp/session-new-commands.json`,
/// `available_commands_update` is a *notification that arrives after the `session/new` response* —
/// message index 2 of 3, carrying 123 commands. An `initialize`-only handshake can never see it, so
/// "read the commands" and "open a session" are one decision.
///
/// **Cost, measured rather than asserted** (this machine, 2026-08-16, Node v26.7.0, npx 11.19.0,
/// `Scripts/probe/acp_preflight_cost.py`, spawn → `available_commands_update`):
///
/// | | npx resolve | total |
/// |---|---|---|
/// | warm | 1.18 s to `initialize` | **2.41 s** |
/// | cold (`rm -rf "$(npm config get cache)/_npx"`) | 5.64 s to `initialize` | **8.72 s** |
///
/// That is paid **once per launch**: `globalChecks` has exactly one caller, `AppModel.start()`, and
/// nothing re-runs it (Preflight's *Check* button calls `refreshRepoChecks`, which does not). So no
/// cache is kept — a cached figure would have to say when it was taken, and a value nobody asks for
/// twice does not earn that machinery.
///
/// ⚠️ **What is unmeasured is the offline case.** `npx --yes` on a cold cache resolves over the
/// network; what it does with no network has not been measured here, which is precisely why the
/// deadline below exists rather than being sized against a known worst case.
public enum AdapterHandshake {
    /// How long the adapter has to answer before Elliot ends it.
    ///
    /// ⛔ **The deadline ends the agent — `AgentSession.end()` — it is not a `withTimeout`.** Every
    /// `Client` request reaches `sendRequest(…, timeout: nil)` and suspends on a bare
    /// `withCheckedThrowingContinuation` that observes no cancellation, so the only thing that ends
    /// one is killing the child. That is the same trap `AgentRun.requestCancel` documents one file
    /// over and `armKiller` one layer up. A Preflight sweep that never finished would be worse than
    /// any sentence it could print.
    ///
    /// Thirty seconds because the measured cold path is 8.72 s and a slower link is nobody's fault;
    /// bounded because this runs before the app has finished starting.
    public static let deadline: Duration = .seconds(30)

    /// How long `available_commands_update` has to arrive once a session exists.
    ///
    /// ⚠️ **A second, shorter window, and not a duplicate of the deadline above.** The commands
    /// arrive as a *notification*, so there is no response to wait on and nothing to time out: an
    /// adapter that simply never sends one is silent in a way that looks identical to one still
    /// thinking. Without this, that adapter would cost the whole thirty seconds — on every launch,
    /// for a row that has already established the identity it came for.
    ///
    /// Two seconds because the notification is not slow, it is immediate: measured at **0.00 s**
    /// after the `session/new` response on both a warm resolve and a cold one
    /// (`Scripts/probe/acp_preflight_cost.py`, 2026-08-16). What this buys is a bound, not a race.
    ///
    /// ⛔ Enforced the same way as the deadline — by **ending the agent**, which finishes
    /// `Client.notifications` — rather than by cancelling the consumer. Nothing here relies on a
    /// suspended `for await` observing cancellation.
    public static let commandsWindow: Duration = .seconds(2)

    /// Never throws: every failure is a sentence for a row.
    public static func probe(
        agent: ACPAgentProcess,
        deadline: Duration = AdapterHandshake.deadline,
        commandsWindow: Duration = AdapterHandshake.commandsWindow
    ) async -> AdapterProbe {
        // ⛔ Refuse before spawning, and in the same words the run path uses. An empty executable
        // is `AppModel` recording that `resolveAdapter()` threw, and `ChildProcess`'s own refusal
        // names a blank path — which is the whole reason `adapterNotResolved` exists.
        guard !agent.executable.isEmpty else {
            return AdapterProbe(
                failure: .error(AgentInvocationError.adapterNotResolved.localizedDescription))
        }

        let session: AgentSession
        do {
            session = try AgentSession(agent)
        } catch {
            return AdapterProbe(failure: .error(error.localizedDescription))
        }

        // Whether the deadline is what stopped us, read after the fact: an `initialize` killed by
        // the deadline throws `connectionClosed`, and reporting that as the adapter's own error
        // would blame it for Elliot's impatience.
        let expired = Locked(false)
        let killer = Task {
            do {
                try await Task.sleep(for: deadline)
            } catch {
                return  // stood down: the handshake finished inside the window
            }
            expired.withLock { $0 = true }
            await session.end()
        }

        let client = session.client
        // ⚠️ `client.notifications` is a single-consumer `AsyncStream` — exactly one task may ever
        // iterate it. Started before the call that makes the adapter say anything, and it returns
        // on the first `available_commands_update` or when the stream finishes, which
        // `Client.terminate()` does. So `await consumer.value` below cannot outlast `session.end()`.
        let seen = Locked<[String]?>(nil)
        let consumer = Task {
            for await notification in await client.notifications {
                guard notification.method == "session/update" else { continue }
                let raw = (try? JSONEncoder().encode(notification.params)) ?? Data()
                guard
                    let note = try? JSONDecoder().decode(SessionUpdateNotification.self, from: raw),
                    case .availableCommandsUpdate(let commands) = note.update
                else { continue }
                seen.withLock { $0 = commands.map(\.name) }
                return
            }
        }

        var probe = AdapterProbe()
        // Declared out here so every exit path can stand it down, including the ones that never
        // reach the assignment.
        var quiet: Task<Void, Never>?
        do {
            // `fs`/`terminal` false, exactly as `AgentRun.start` declares them: v1-only, removed
            // in the v2 draft, and this handshake uses neither.
            let hello = try await client.initialize(
                protocolVersion: 1,
                capabilities: ClientCapabilities(
                    fs: FileSystemCapabilities(readTextFile: false, writeTextFile: false),
                    terminal: false
                )
            )
            probe.agentName = hello.agentInfo?.name
            probe.agentVersion = hello.agentInfo?.version

            // ⛔ `session/new`, and **no `session/prompt`**. Opening a session is what makes the
            // adapter advertise its commands; prompting is what would make it *do* something, in a
            // directory, at whatever permission mode — on the screen whose job is to look.
            _ = try await client.newSession(
                workingDirectory: agent.cwd, additionalDirectories: [], mcpServers: [])
            // Armed only now: before a session exists there is nothing that could advertise
            // anything, so the window would be measuring the wrong silence.
            quiet = Task {
                do {
                    try await Task.sleep(for: commandsWindow)
                } catch {
                    return  // the notification arrived, or the outer deadline got there first
                }
                await session.end()
            }
            await consumer.value
        } catch {
            probe.failure = .error(error.localizedDescription)
        }

        quiet?.cancel()
        killer.cancel()
        // Ends the child on every path — including the one where `initialize` threw with the agent
        // still alive — and finishes the notification stream, which is what makes the wait below a
        // barrier rather than a hope.
        await session.end()
        await consumer.value

        probe.commands = seen.value
        if expired.value {
            // Whatever the failing call said, the cause was Elliot ending the agent. Overwrites an
            // `.error` deliberately: `connectionClosed` describes the symptom, this names the cause.
            probe.failure = .silent(deadline)
        } else if probe.failure == nil, probe.commands == nil {
            // The session opened and the window closed with nothing in it. Not the deadline, and
            // not an error anyone reported — so it is said plainly rather than dressed as either.
            probe.failure = .error(
                "The adapter opened a session and advertised no commands within "
                    + "\(commandsWindow.components.seconds) seconds.")
        }
        return probe
    }
}
