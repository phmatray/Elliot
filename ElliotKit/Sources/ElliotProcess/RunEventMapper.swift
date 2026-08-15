import ACP
import ACPModel
import ElliotModel
import Foundation

/// The ACP wire onto Elliot's own event model.
///
/// This file is the only place in the package that reads `_meta.claudeCode`. Agent-agnosticism
/// is an explicit non-goal of this design, so that is a decision rather than a leak — but
/// keeping it to one file is what makes the dependency countable if the decision ever changes.
public enum RunEventMapper {
    /// One notification to zero or more events.
    ///
    /// ⛔ The `switch` is exhaustive over `SessionUpdate`'s thirteen cases with **no
    /// `default`**, and six of them map to `[]` **by name**. That is not the same act as
    /// `StreamEventDecoder.decodeMessage`'s `default: continue`, which is what silently threw
    /// away every thinking block: an arm that returns `[]` is a decision a reader can see, and a
    /// fourteenth case added upstream is a compile error here rather than a silent drop.
    ///
    /// ⚠️ All six are pinned — two from transcript bytes by
    /// `silentFramesWithATranscriptProduceNothing`, four from hand-built bytes by
    /// `silentFramesWithoutATranscriptProduceNothing`, with
    /// `onlyTheAgentsHalfOfAChunkIsRendered` as the control that a silent arm is silent by
    /// decision rather than by having nothing to say. This sentence claimed as much while
    /// **one** of the six was pinned and the other five were held by the exhaustive `switch`
    /// alone; a review measured five arms rewritten to emit events with the whole suite still
    /// green. Naming the tests is what makes the claim checkable rather than reassuring.
    public static func events(from notification: SessionUpdateNotification) -> [RunEvent] {
        switch notification.update {
        case .agentMessageChunk(let block):
            return text(of: block).map { [.agentText($0)] } ?? []
        case .agentThoughtChunk(let block):
            return text(of: block).map { [.agentThought($0)] } ?? []
        case .toolCall(let call):
            return [.toolCall(patch(creation: call))]
        case .toolCallUpdate(let call):
            return [.toolCall(patch(update: call))]
        case .plan(let plan):
            return [.plan(plan.entries.map(step(from:)))]
        case .usageUpdate(let usage):
            return [.usage(RunUsage(used: usage.used, size: usage.size, costUSD: usage.cost?.amount))]
        case .currentModeUpdate(let mode):
            return [.modeChanged(mode)]

        // Deliberately nothing, each for its own reason:
        case .userMessageChunk:
            // Elliot wrote it. Echoing the prompt back into the run's own log would present
            // Elliot's words in the agent's stream.
            return []
        case .availableCommandsUpdate:
            // Which slash commands exist is Preflight's question, asked once per machine, not a
            // line in one run's log.
            return []
        case .planUpdate, .planRemoved:
            // Draft-plan editing. Unmeasured against this adapter — no transcript committed for
            // this design contains one — so nothing is rendered rather than a shape guessed.
            return []
        case .configOptionUpdate:
            // The echo of a `session/set_config_option` Elliot itself sent.
            return []
        case .sessionInfoUpdate:
            // A title and a timestamp for a session list Elliot does not have.
            return []
        }
    }

    /// A `tool_call` frame **is** the first patch.
    ///
    /// ⛔ `ToolCallUpdate.content` is non-optional upstream and decodes to `[]` when the key is
    /// absent (`ACPModel/Updates.swift:334`), while `ToolCallUpdateDetails.content` is
    /// `[ToolCallContent]?` (`:376`). Both go through `mapped(_:)` below, which collapses
    /// "absent" and "empty" to `nil` — because under `merging`'s `next.content ?? content` an
    /// empty array is not "no news", it is an **erasure** of the diff an earlier frame
    /// established. That asymmetry between the two upstream types is exactly the trap
    /// `ToolCallPatch` exists to flatten, and applying the guard to only one of them — which is
    /// what this plan did in its first draft — reintroduces the bug on the side that carries
    /// the diffs.
    static func patch(creation call: ToolCallUpdate) -> ToolCallPatch {
        ToolCallPatch(
            id: call.toolCallId,
            title: call.title,
            kind: call.kind.map { ToolCallKind(rawValue: $0.rawValue) },
            status: call.status.flatMap { ToolCallStatus(rawValue: $0.rawValue) },
            locations: locations(call.locations),
            content: mapped(call.content),
            claudeToolName: toolName(in: call._meta),
            nonExecutionKind: nonExecutionKind(in: call._meta)
        )
    }

    static func patch(update call: ToolCallUpdateDetails) -> ToolCallPatch {
        ToolCallPatch(
            id: call.toolCallId,
            title: call.title,
            kind: call.kind.map { ToolCallKind(rawValue: $0.rawValue) },
            status: call.status.flatMap { ToolCallStatus(rawValue: $0.rawValue) },
            locations: locations(call.locations),
            content: mapped(call.content),
            claudeToolName: toolName(in: call._meta),
            nonExecutionKind: nonExecutionKind(in: call._meta)
        )
    }

    /// One rule for both frame shapes: absent, empty, or nothing renderable in it all mean
    /// **this frame said nothing about content**.
    ///
    /// The third case is the one that is easy to miss: `content(_:)` is a `compactMap`, and
    /// `text(of:)` yields nothing for an image, an audio, a `resource_link` or a blob resource
    /// block — **four** kinds, enumerated there rather than summarised here — so a non-empty
    /// frame can still map to `[]`. Written the same way as `locations(_:)` directly below, for
    /// the same reason.
    static func mapped(_ raw: [ToolCallContent]?) -> [ToolContent]? {
        guard let raw, !raw.isEmpty else { return nil }
        let mapped = content(raw)
        return mapped.isEmpty ? nil : mapped
    }

    /// `ToolLocation.path` is optional upstream; a location with no path carries nothing, so it
    /// is dropped rather than stored as an empty string. An all-empty array becomes `nil`, for
    /// the same reason `content` does.
    static func locations(_ raw: [ToolLocation]?) -> [FileLocation]? {
        guard let raw else { return nil }
        let mapped = raw.compactMap { location -> FileLocation? in
            guard let path = location.path, !path.isEmpty else { return nil }
            return FileLocation(path: path, line: location.line)
        }
        return mapped.isEmpty ? nil : mapped
    }

    static func content(_ raw: [ToolCallContent]) -> [ToolContent] {
        raw.compactMap { item in
            switch item {
            case .content(let block):
                return text(of: block).map { ToolContent.text($0) }
            case .diff(let diff):
                return .diff(path: diff.path, oldText: diff.oldText, newText: diff.newText)
            case .terminal(let terminal):
                return .terminal(id: terminal.terminalId)
            }
        }
    }

    static func step(from entry: PlanEntry) -> PlanStep {
        PlanStep(
            content: entry.content,
            status: PlanStepStatus(rawValue: entry.status.rawValue) ?? .pending,
            priority: entry.priority.rawValue
        )
    }

    /// The one place a `ContentBlock` becomes a string — for agent prose, for thinking, and for
    /// tool content alike.
    ///
    /// ⛔ An exhaustive `switch` over all **five** cases of `ContentBlock`
    /// (`ACPModel/Content.swift:37`), for the reason the `SessionUpdate` switch above is one: a
    /// sixth case added upstream must be a compile error here rather than a silent drop. It was
    /// `if case .text(let text) = block` until a review of this task — a `default:` in all but
    /// syntax — and its doc comment named two of the four cases it was swallowing, which is
    /// exactly how `.resource` went unnoticed.
    ///
    /// ⛔ **`.resource` is read, not dropped.** `ContentBlock.resource` wraps an
    /// `EmbeddedResourceType`, whose `.text` case carries a plain `String`
    /// (`Content.swift:220`) — real prose, the same shape a text block carries. Discarding it
    /// would be the silent drop `StreamEventDecoder.decodeMessage`'s `default: continue`
    /// performed on every thinking block, which is the harm `RunEvent`'s own header holds up as
    /// the reason ACP was adopted; and it would be worse here than for tool content, because
    /// `text(of:) ?? []` on a message chunk yields **no event at all**, not even `.unreadable`.
    /// Nothing is invented: the string is read off the wire, never composed. A `.blob` resource
    /// carries no text and yields `nil`.
    ///
    /// `.image`, `.audio` and `.resourceLink` are real absences rather than errors, so they map
    /// to `nil` and the caller drops the event. A `resource_link` is named rather than rendered
    /// on purpose: it carries a `uri` and a `name` and no body, so showing it would mean
    /// *composing* a line out of two fields — the guess the `planUpdate` arm above declines to
    /// make.
    ///
    /// ⚠️ All four of those decisions are unmeasured against this adapter. Counted across the
    /// five committed transcripts, every one of the **53** content blocks on the wire is a text
    /// block — 32 message chunks and 21 tool content blocks, and not one image, audio,
    /// resource_link or resource. They are pinned by hand-built bytes for that reason, not
    /// despite it.
    static func text(of block: ContentBlock) -> String? {
        switch block {
        case .text(let text):
            return text.text.isEmpty ? nil : text.text
        case .resource(let resource):
            guard let text = resource.resource.text, !text.isEmpty else { return nil }
            return text
        case .image, .audio, .resourceLink:
            return nil
        }
    }

    /// `_meta.claudeCode.toolName`.
    public static func toolName(in meta: [String: AnyCodable]?) -> String? {
        claudeCode(meta)?["toolName"] as? String
    }

    /// `_meta.claudeCode.nonExecutionKind`.
    ///
    /// Read as an arbitrary `String` rather than matched against a closed set, because the
    /// adapter's own comment calls it an open set that ships new kinds ahead of schema updates.
    /// `NonExecutionKind` keeps whatever arrives, and folds by value.
    public static func nonExecutionKind(in meta: [String: AnyCodable]?) -> NonExecutionKind? {
        (claudeCode(meta)?["nonExecutionKind"] as? String).map(NonExecutionKind.init)
    }

    /// `AnyCodable.value` decodes a nested object to `[String: any Sendable]`, so one cast gets
    /// the whole sub-tree. Measured through the vendored decoder: nested objects, arrays and a
    /// full encode/decode round trip all survive.
    private static func claudeCode(_ meta: [String: AnyCodable]?) -> [String: any Sendable]? {
        meta?["claudeCode"]?.value as? [String: any Sendable]
    }
}
