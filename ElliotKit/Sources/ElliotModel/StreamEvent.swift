import Foundation

/// One decoded line of `claude -p --output-format stream-json` output.
///
/// Deliberately shallow. Only `type`, `subtype`, `session_id`, `is_error` and
/// `result` are treated as contract; everything else is best-effort. Any line
/// that does not fit becomes `.unknown` or `.malformed` — both of which are
/// still displayed and still written to the run log. Decoding never throws and
/// never drops a line, so a schema change in a future Claude Code release
/// degrades the UI instead of breaking the runner.
public enum StreamEvent: Sendable, Hashable {
    /// The first event of a run. `slashCommands` is the definitive list of what
    /// this session can dispatch, so preflight can assert the three skills are
    /// present rather than assume it.
    case systemInit(SystemInit)
    /// Any other `type: "system"` line — there are 40+ subtypes and they come
    /// and go between releases, so they are kept as a subtype plus raw payload.
    case system(subtype: String, raw: Data)
    case assistantText(String)
    case assistantToolUse(name: String, id: String, inputPreview: String)
    case toolResult(toolUseID: String, isError: Bool, preview: String)
    /// Token-level deltas, only present with `--include-partial-messages`.
    case partial(text: String)
    case result(RunResult)
    case unknown(type: String, raw: Data)
    case malformed(raw: Data, error: String)
}

public struct SystemInit: Sendable, Hashable, Codable {
    public var sessionID: String
    public var cwd: String?
    public var model: String?
    public var permissionMode: String?
    public var tools: [String]
    public var slashCommands: [String]
    public var claudeCodeVersion: String?
    public var mcpServers: [MCPServerStatus]

    public struct MCPServerStatus: Sendable, Hashable, Codable {
        public var name: String
        public var status: String?
    }
}

/// A tool call that was refused. A run can finish `subtype: "success"` with a
/// non-empty list here — the agent sees a denial as a tool error and often
/// carries on around it — so a runner that only checks `isError` would call
/// such a run green.
public struct PermissionDenial: Sendable, Hashable, Codable {
    public var toolName: String
    public var toolUseID: String?

    public init(toolName: String, toolUseID: String? = nil) {
        self.toolName = toolName
        self.toolUseID = toolUseID
    }
}

/// The terminal `type: "result"` event: the same object `--output-format json`
/// would return on its own.
public struct RunResult: Sendable, Hashable, Codable {
    public var subtype: String
    public var isError: Bool
    public var text: String?
    public var numTurns: Int?
    public var durationMS: Int?
    public var totalCostUSD: Double?
    public var sessionID: String?
    public var stopReason: String?
    /// Absent when a local slash command bypassed the model loop entirely.
    public var terminalReason: String?
    public var permissionDenials: [PermissionDenial]
    public var errors: [String]

    public init(
        subtype: String,
        isError: Bool,
        text: String? = nil,
        numTurns: Int? = nil,
        durationMS: Int? = nil,
        totalCostUSD: Double? = nil,
        sessionID: String? = nil,
        stopReason: String? = nil,
        terminalReason: String? = nil,
        permissionDenials: [PermissionDenial] = [],
        errors: [String] = []
    ) {
        self.subtype = subtype
        self.isError = isError
        self.text = text
        self.numTurns = numTurns
        self.durationMS = durationMS
        self.totalCostUSD = totalCostUSD
        self.sessionID = sessionID
        self.stopReason = stopReason
        self.terminalReason = terminalReason
        self.permissionDenials = permissionDenials
        self.errors = errors
    }

    /// `subtype` values that mean the run stopped on a configured ceiling
    /// rather than crashing. Worth separating in the UI.
    public static let budgetSubtypes: Set<String> = [
        "error_max_turns", "error_max_budget_usd", "error_max_structured_output_retries",
    ]

    /// A run only counts as clean if it neither errored **nor** was refused a
    /// tool along the way.
    public var isClean: Bool { !isError && permissionDenials.isEmpty }

    public var hitABudgetCeiling: Bool { Self.budgetSubtypes.contains(subtype) }
}

// MARK: - Decoding

public enum StreamEventDecoder {
    /// Decodes one NDJSON line. Total: every input maps to some event.
    public static func decode(line: Data) -> StreamEvent? {
        let trimmed = line.trimmingTrailingNewline()
        // A blank or whitespace-only line carries nothing; it is not an error.
        guard trimmed.contains(where: { !$0.isASCIIWhitespace }) else { return nil }

        guard
            let object = try? JSONSerialization.jsonObject(with: trimmed),
            let dict = object as? [String: Any]
        else {
            return .malformed(raw: trimmed, error: "not a JSON object")
        }
        guard let type = dict["type"] as? String else {
            return .malformed(raw: trimmed, error: "missing \"type\"")
        }

        switch type {
        case "system":
            let subtype = dict["subtype"] as? String ?? ""
            if subtype == "init" { return .systemInit(decodeInit(dict)) }
            return .system(subtype: subtype, raw: trimmed)

        case "assistant", "user":
            return decodeMessage(dict, raw: trimmed)

        case "stream_event":
            if let text = partialText(dict) { return .partial(text: text) }
            return .unknown(type: type, raw: trimmed)

        case "result":
            return .result(decodeResult(dict))

        default:
            return .unknown(type: type, raw: trimmed)
        }
    }

    private static func decodeInit(_ dict: [String: Any]) -> SystemInit {
        let servers = (dict["mcp_servers"] as? [[String: Any]] ?? []).map {
            SystemInit.MCPServerStatus(
                name: $0["name"] as? String ?? "",
                status: $0["status"] as? String
            )
        }
        return SystemInit(
            sessionID: dict["session_id"] as? String ?? "",
            cwd: dict["cwd"] as? String,
            model: dict["model"] as? String,
            permissionMode: dict["permissionMode"] as? String,
            tools: dict["tools"] as? [String] ?? [],
            slashCommands: dict["slash_commands"] as? [String] ?? [],
            claudeCodeVersion: dict["claude_code_version"] as? String,
            mcpServers: servers
        )
    }

    private static func decodeResult(_ dict: [String: Any]) -> RunResult {
        let denials = (dict["permission_denials"] as? [[String: Any]] ?? []).map {
            PermissionDenial(
                toolName: $0["tool_name"] as? String ?? "",
                toolUseID: $0["tool_use_id"] as? String
            )
        }
        return RunResult(
            subtype: dict["subtype"] as? String ?? "",
            isError: dict["is_error"] as? Bool ?? false,
            text: dict["result"] as? String,
            numTurns: dict["num_turns"] as? Int,
            durationMS: dict["duration_ms"] as? Int,
            totalCostUSD: dict["total_cost_usd"] as? Double,
            sessionID: dict["session_id"] as? String,
            stopReason: dict["stop_reason"] as? String,
            terminalReason: dict["terminal_reason"] as? String,
            permissionDenials: denials,
            errors: dict["errors"] as? [String] ?? []
        )
    }

    /// Pulls the first meaningful block out of an assistant/user message.
    private static func decodeMessage(_ dict: [String: Any], raw: Data) -> StreamEvent {
        guard
            let message = dict["message"] as? [String: Any],
            let content = message["content"] as? [[String: Any]]
        else {
            return .unknown(type: dict["type"] as? String ?? "", raw: raw)
        }

        for block in content {
            switch block["type"] as? String {
            case "text":
                if let text = block["text"] as? String, !text.isEmpty {
                    return .assistantText(text)
                }
            case "tool_use":
                return .assistantToolUse(
                    name: block["name"] as? String ?? "",
                    id: block["id"] as? String ?? "",
                    inputPreview: preview(of: block["input"])
                )
            case "tool_result":
                return .toolResult(
                    toolUseID: block["tool_use_id"] as? String ?? "",
                    isError: block["is_error"] as? Bool ?? false,
                    preview: preview(of: block["content"])
                )
            default:
                continue
            }
        }
        return .unknown(type: dict["type"] as? String ?? "", raw: raw)
    }

    private static func partialText(_ dict: [String: Any]) -> String? {
        guard
            let event = dict["event"] as? [String: Any],
            let delta = event["delta"] as? [String: Any],
            let text = delta["text"] as? String,
            !text.isEmpty
        else { return nil }
        return text
    }

    /// A short, single-line rendering of an arbitrary JSON value, for the log UI.
    static func preview(of value: Any?, limit: Int = 200) -> String {
        let text: String
        switch value {
        case let s as String:
            text = s
        case .some(let v):
            if let data = try? JSONSerialization.data(withJSONObject: v),
               let s = String(data: data, encoding: .utf8) {
                text = s
            } else {
                text = String(describing: v)
            }
        case nil:
            return ""
        }
        let flat = text.collapsedToSingleLine()
        guard flat.count > limit else { return flat }
        return flat.prefix(limit) + "…"
    }
}

extension UInt8 {
    /// Space, tab, CR, LF, vertical tab, form feed.
    var isASCIIWhitespace: Bool {
        self == 0x20 || (self >= 0x09 && self <= 0x0D)
    }
}

extension Data {
    func trimmingTrailingNewline() -> Data {
        var end = endIndex
        while end > startIndex, self[index(before: end)] == 0x0A || self[index(before: end)] == 0x0D {
            end = index(before: end)
        }
        return subdata(in: startIndex..<end)
    }
}
