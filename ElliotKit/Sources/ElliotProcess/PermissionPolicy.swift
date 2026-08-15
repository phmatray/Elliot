import ACP
import ACPModel
import ElliotModel

/// Answers ACP permission requests by policy — the design's first bounding decision: "unattended
/// stays unattended. Elliot answers permissions by policy; there is **no** answering UI in this
/// scope." Measured, `bypassPermissions` sends zero `session/request_permission` across a full
/// turn — but that is one turn, one adapter version, one machine: evidence, not a guarantee, and
/// #585 remains open. A client with no delegate falls into `ClientDelegate`'s default, which
/// throws `ClientError.invalidResponse`, so an unanswered request would hang the turn until the
/// idle window and then read as a stalled agent rather than what it actually was. This exists so
/// a conformant adapter that DOES ask gets a real answer instead of a hang.
public final class PermissionPolicy: ClientDelegate, Sendable {
    private let mode: PermissionMode

    /// ⛔ Mutable state on a `Sendable` final class is a compile error as a bare stored property
    /// under `swiftLanguageModes: [.v6]`. `Locked`, not an `actor`: `ClientDelegate`'s
    /// requirements are `async throws` methods on an `AnyObject & Sendable`, and `Client` holds
    /// the delegate `weak` (`Client.swift:59`) — so the run has to retain this policy itself for
    /// its whole lifetime regardless of which one is chosen here.
    private let declined: Locked<[String]>

    public init(mode: PermissionMode) {
        self.mode = mode
        declined = Locked([])
    }

    /// Tool names this policy declined, in the order it declined them.
    ///
    /// **Not** folded into `RunState` — `nonExecutionKind` is the signal
    /// `RunState.completedWithDenials` reads (Task 15); this is a second, independent record of
    /// something the design says should not happen at all under `bypassPermissions`. Its value is
    /// that if #585 ever does reproduce here, the log names it instead of the run merely looking
    /// slow.
    ///
    /// ⛔ **That last sentence is a claim about a caller, so here is the caller: `AgentRun.start`
    /// reads this once the turn's transport has exited and writes any non-empty result as an
    /// `elliot/refusals` line (`AgentLog.refusalsLine`).** It shipped for one commit with no
    /// reader at all — appended to, then released with the policy when the turn's `Task` closure
    /// ended — while this comment already promised the log named it. A ledger with no reader is a
    /// counter nobody reads; a ledger with no reader *under a comment saying otherwise* also stops
    /// the next person looking for the diagnostic that is not there.
    public func refusals() -> [String] {
        declined.value
    }

    /// Picks, from the request's own `options`, the first whose `kind` matches this mode's own
    /// priority — `allow_always` then `allow_once` at `bypassPermissions`; `reject_once` then
    /// `reject_always` otherwise. If no option of the needed kind exists, this **declines**: it
    /// never falls back to "the first option", which is how a policy would silently allow
    /// something it was never actually asked about.
    ///
    /// A `switch` over every `PermissionMode` case, no `default`: a seventh mode is a compile
    /// error here rather than a silent default into whichever arm someone wrote first — the same
    /// discipline `AgentInvocation.configValue(for:)` and `PermissionMode.appraisal(repo:)` use.
    public func handlePermissionRequest(
        request: RequestPermissionRequest
    ) async throws -> RequestPermissionResponse {
        let desiredKinds: [PermissionDecision]
        switch mode {
        case .bypassPermissions:
            desiredKinds = [.allowAlways, .allowOnce]
        case .manual, .acceptEdits, .auto, .dontAsk, .plan:
            desiredKinds = [.rejectOnce, .rejectAlways]
        }

        for kind in desiredKinds {
            guard let option = request.options.first(where: { $0.kind == kind.rawValue }) else {
                continue
            }
            // Granting is silent; declining — even a genuine, option-backed decline — is
            // recorded, because it is the tool call that did not run.
            if mode != .bypassPermissions {
                record(request)
            }
            return RequestPermissionResponse(outcome: PermissionOutcome(optionId: option.optionId))
        }

        // No option of the needed kind exists at all: decline rather than guess at one.
        record(request)
        return RequestPermissionResponse(outcome: PermissionOutcome(cancelled: true))
    }

    /// `_meta.claudeCode.toolName` is the real name, the title is the adapter's own prose and the
    /// id is a correlation token — the same fallback order `AgentRun.summary`'s denial naming
    /// already uses for the identical trio of fields.
    private func record(_ request: RequestPermissionRequest) {
        let name =
            RunEventMapper.toolName(in: request.toolCall._meta)
            ?? request.toolCall.title
            ?? request.toolCall.toolCallId
        declined.withLock { $0.append(name) }
    }
}
