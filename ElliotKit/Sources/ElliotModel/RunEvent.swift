import Foundation

/// One thing that happened during a run, as the board understands it.
///
/// The successor to `StreamEvent`, which decoded a line of `claude -p --output-format
/// stream-json` — a CLI's output format, not a contract. This decodes the Agent Client
/// Protocol, and carries three things stream-json threw away: the agent's thinking (discarded
/// by `StreamEventDecoder.decodeMessage`'s `default: continue`), a plan, and live usage against
/// one terminal cost number.
///
/// `.unreadable` preserves `StreamEvent`'s totality: a line that cannot be understood degrades
/// to one row instead of breaking the runner.
///
/// ⚠️ **`RunEventMapper` cannot produce it, and that is not where it comes from.** The mapper
/// takes an already-decoded `SessionUpdateNotification`, and `ACPModel.SessionUpdate.init(from:)`
/// **throws** `DecodingError` on an unrecognised `sessionUpdate` string (`ACPModel/Updates.swift`,
/// the `default:` arm) — so by the time the mapper is called, the interesting failure has already
/// happened one layer out. The producer is **Task 7's notification consumer**, which wraps the
/// decode in `do`/`catch` and yields `.unreadable(raw:error:)` rather than dropping the line.
/// Without that `catch` this case is dead code and this comment is a claim nothing implements.
public enum RunEvent: Sendable, Hashable {
    case session(RunSessionInfo)
    case agentText(String)
    /// NEW. Discarded entirely today.
    case agentThought(String)
    /// Creation **and** update: both are patches. See `ToolCallPatch`.
    case toolCall(ToolCallPatch)
    /// NEW.
    case plan([PlanStep])
    /// NEW — live, against one terminal number today.
    case usage(RunUsage)
    case modeChanged(String)
    case unreadable(raw: Data, error: String?)
}

/// What the handshake established, before the first turn.
///
/// ⚠️ `SystemInit`'s `tools` and `mcpServers` have no ACP source and are therefore **absent
/// rather than invented**: the adapter advertises neither at `session/new`. Advertised slash
/// commands arrive later, as their own notification, and are Preflight's business rather than
/// the log's.
///
/// Named `RunSessionInfo` rather than `SessionInfo` for the same reason `RunUsage` below is not
/// `Usage`: `RunEventMapper.swift` (Task 4) imports both this module and `ACPModel`, and
/// `ACPModel.SessionInfo` (`Vendor/swift-acp/ACPModel/Session.swift:160`) already exists — a
/// session-**listing** entry (`sessionId`, `cwd`, `additionalDirectories`, `title`,
/// `updatedAt`), which is a different thing from this handshake summary. Measured rather than
/// assumed: a file in `ElliotProcess` importing both and writing `SessionInfo` unqualified
/// fails to build with `'SessionInfo' is ambiguous for type lookup in this context`. That is a
/// loud failure rather than a silent one, but it is a `public` name Tasks 3, 4, 7 and 12
/// consume, so it costs one line here and a fan-out of qualifications later.
public struct RunSessionInfo: Sendable, Hashable, Codable {
    /// The id the **agent** chose, returned by `session/new`. Not `SkillRun.id`: under
    /// `claude -p` Elliot passed `--session-id` and the two were one value; under ACP the agent
    /// names its own session, which is why `SkillRun.agentSessionID` exists (Task 12).
    public var agentSessionID: String
    public var agentName: String?
    public var agentVersion: String?
    public var cwd: String
    public var model: String?
    public var mode: String?

    public init(
        agentSessionID: String, agentName: String? = nil, agentVersion: String? = nil,
        cwd: String, model: String? = nil, mode: String? = nil
    ) {
        self.agentSessionID = agentSessionID
        self.agentName = agentName
        self.agentVersion = agentVersion
        self.cwd = cwd
        self.model = model
        self.mode = mode
    }
}

/// One frame of one tool call.
///
/// ⛔ **`nil` means absent from this frame. It never means cleared.** Measured on
/// `Fixtures/acp/turn-edit-bash.json`: the `Edit` call arrives as six frames on one id, and the
/// last carries `status: "completed"` and nothing else at all — no title, no kind, no
/// locations, no content. A fold that *replaces* leaves the finished card blank.
///
/// This is also why a `tool_call` and a `tool_call_update` collapse into one case rather than
/// two. A `tool_call` **is** the first patch: it arrives with `rawInput: {}` and a generic
/// title (`"Edit"`) and is refined afterwards. Two cases would invite exactly the
/// replace-versus-merge confusion this comment exists to prevent.
public struct ToolCallPatch: Sendable, Hashable, Codable {
    /// The only field the spec guarantees on every frame.
    public var id: String
    public var title: String?
    public var kind: ToolCallKind?
    public var status: ToolCallStatus?
    public var locations: [FileLocation]?
    public var content: [ToolContent]?
    /// `_meta.claudeCode.toolName` — `Read` / `Edit` / `Bash`. Agent-agnosticism is an explicit
    /// non-goal, so reading the adapter's `_meta` is sanctioned rather than tolerated.
    public var claudeToolName: String?
    /// `_meta.claudeCode.nonExecutionKind`, when the frame carries one.
    ///
    /// ⚠️ Not in the protocol, and absent from the SDK's `.d.ts` too. The adapter forwards it
    /// verbatim from a `tool_result_meta` sidecar the Claude Code CLI (≥ 2.1.216) emits, and
    /// the adapter's own comment calls it an open set that ships new kinds ahead of schema
    /// updates. Recorded raw; folded by value in `NonExecutionKind.isDenial`.
    public var nonExecutionKind: NonExecutionKind?

    public init(
        id: String, title: String? = nil, kind: ToolCallKind? = nil,
        status: ToolCallStatus? = nil, locations: [FileLocation]? = nil,
        content: [ToolContent]? = nil, claudeToolName: String? = nil,
        nonExecutionKind: NonExecutionKind? = nil
    ) {
        self.id = id
        self.title = title
        self.kind = kind
        self.status = status
        self.locations = locations
        self.content = content
        self.claudeToolName = claudeToolName
        self.nonExecutionKind = nonExecutionKind
    }

    /// Folds a later frame onto this one, field by field, as `next ?? self` — so a field the
    /// later frame omitted keeps the value an earlier one established.
    ///
    /// ⛔ Do not "simplify" this to `return next`. That is the defect, and it is invisible in
    /// any test whose last frame happens to be complete.
    ///
    /// A mismatched id returns `self` untouched. `content` and `locations` **replace** when
    /// present rather than append, because ACP resends the whole array whenever it changes.
    public func merging(_ next: ToolCallPatch) -> ToolCallPatch {
        guard next.id == id else { return self }
        return ToolCallPatch(
            id: id,
            title: next.title ?? title,
            kind: next.kind ?? kind,
            status: next.status ?? status,
            locations: next.locations ?? locations,
            content: next.content ?? content,
            claudeToolName: next.claudeToolName ?? claudeToolName,
            nonExecutionKind: next.nonExecutionKind ?? nonExecutionKind
        )
    }
}

/// ACP's tool kinds, re-declared here because `ElliotModel` has no dependencies and cannot see
/// `ACPModel.ToolKind`. `.unrecognised` keeps the totality rule: a kind shipped tomorrow
/// degrades one glyph rather than dropping the row.
public enum ToolCallKind: Sendable, Hashable, Codable {
    case read, edit, delete, move, search, execute, think, fetch
    case switchMode, plan, exitPlanMode, other
    case unrecognised(String)

    public init(rawValue: String) {
        switch rawValue {
        case "read": self = .read
        case "edit": self = .edit
        case "delete": self = .delete
        case "move": self = .move
        case "search": self = .search
        case "execute": self = .execute
        case "think": self = .think
        case "fetch": self = .fetch
        case "switch_mode": self = .switchMode
        case "plan": self = .plan
        case "exit_plan_mode": self = .exitPlanMode
        case "other": self = .other
        default: self = .unrecognised(rawValue)
        }
    }

    public var rawValue: String {
        switch self {
        case .read: "read"
        case .edit: "edit"
        case .delete: "delete"
        case .move: "move"
        case .search: "search"
        case .execute: "execute"
        case .think: "think"
        case .fetch: "fetch"
        case .switchMode: "switch_mode"
        case .plan: "plan"
        case .exitPlanMode: "exit_plan_mode"
        case .other: "other"
        case .unrecognised(let raw): raw
        }
    }

    public init(from decoder: Decoder) throws {
        self.init(rawValue: try decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public enum ToolCallStatus: String, Sendable, Hashable, Codable {
    case pending
    case inProgress = "in_progress"
    case completed
    case failed
}

public struct FileLocation: Sendable, Hashable, Codable {
    /// Absolute. `ACPModel.ToolLocation.path` is optional; a location with no path carries
    /// nothing, so `RunEventMapper` drops it rather than storing an empty string.
    public var path: String
    /// 1-based.
    public var line: Int?

    public init(path: String, line: Int? = nil) {
        self.path = path
        self.line = line
    }
}

/// What a tool call has produced so far.
///
/// `.diff` is the reason this whole change exists: a card can show the edit **before the write
/// lands**.
public enum ToolContent: Sendable, Hashable, Codable {
    case text(String)
    case diff(path: String, oldText: String?, newText: String)
    case terminal(id: String)
}

public enum PlanStepStatus: String, Sendable, Hashable, Codable {
    case pending
    case inProgress = "in_progress"
    case completed
    case cancelled
}

public struct PlanStep: Sendable, Hashable, Codable {
    public var content: String
    public var status: PlanStepStatus
    public var priority: String?

    public init(content: String, status: PlanStepStatus, priority: String? = nil) {
        self.content = content
        self.status = status
        self.priority = priority
    }
}

/// Live context usage and, intermittently, spend.
///
/// ⚠️ `costUSD` is **not** on every frame. Measured across the four `Fixtures/acp/turn-*.json`
/// recordings: it appears on **4 of 42 `usage_update` frames — once per turn, on that turn's last
/// one**, immediately before the `session/prompt` response. Anything reading it must treat absence
/// as "not reported yet", never as zero. (This said "absent from the first nine frames and present
/// on the last", which was one of the four recordings generalised to "a turn"; the instruction was
/// unaffected, the figure was not. `AgentInvocation.maxBudgetUSD` carries the full re-derivation.)
///
/// Named `RunUsage` rather than `Usage` because `RunEventMapper.swift` imports both this module
/// and `ACPModel`, whose `Usage` is the per-turn token report on the prompt response — a
/// different thing entirely.
public struct RunUsage: Sendable, Hashable, Codable {
    /// Context tokens used.
    public var used: Int
    /// Context window size.
    public var size: Int
    public var costUSD: Double?

    public init(used: Int, size: Int, costUSD: Double? = nil) {
        self.used = used
        self.size = size
        self.costUSD = costUSD
    }
}

/// Why a tool call did not execute — `_meta.claudeCode.nonExecutionKind`.
///
/// ⛔ **Folded by value, never by presence.** Presence was the design's first frozen rule and it
/// was wrong: `interrupted` and `cancelled` are exactly what a **cancelled** run produces on
/// its in-flight tool calls, and cancelling is Elliot's most common deliberate action. Folding
/// on presence would mark every cancelled run as one that "was refused a tool and quietly
/// worked around the gap", destroying the distinction `RunState.completedWithDenials` exists to
/// draw. `user-rejected` is a third non-denial: a human declining interactively, and no human
/// is present in an unattended flow.
///
/// An unrecognised value is **UNMEASURED**, and reads as *not* a denial. The adapter's own list
/// already contains three values for which a denial default is provably wrong, so an unknown
/// fourth is a call for a fact, not a place to guess one. It is still recorded, so the log can
/// name it and somebody can go and measure it.
public enum NonExecutionKind: Sendable, Hashable, Codable {
    case permissionRule
    case interrupted
    case cancelled
    case userRejected
    case unrecognised(String)

    public init(_ rawValue: String) {
        switch rawValue {
        case "permission-rule": self = .permissionRule
        case "interrupted": self = .interrupted
        case "cancelled": self = .cancelled
        case "user-rejected": self = .userRejected
        default: self = .unrecognised(rawValue)
        }
    }

    public var rawValue: String {
        switch self {
        case .permissionRule: "permission-rule"
        case .interrupted: "interrupted"
        case .cancelled: "cancelled"
        case .userRejected: "user-rejected"
        case .unrecognised(let raw): raw
        }
    }

    /// The one value measured against the mechanism Elliot actually ships — a `PreToolUse` hook
    /// block, provoked and recorded at `Fixtures/acp/turn-refusal.json`. `allowedTools` and
    /// non-`bypassPermissions` mode denials are the same policy layer: unmeasured, but not a
    /// new mechanism.
    public var isDenial: Bool {
        if case .permissionRule = self { return true }
        return false
    }

    public init(from decoder: Decoder) throws {
        self.init(try decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}
