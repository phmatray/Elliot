import Foundation

/// Whose words a finished run's closing text is.
///
/// `SkillRun.resultText` held two different kinds of thing and said which of
/// them it was nowhere: the agent's own closing prose, and — when the process
/// died before emitting a terminal event — the bytes it left on stderr. The
/// verdict block captioned both "IT SAID" and set both in `Type.hearsay`, so a
/// diagnosis the *machine* produced was dressed as the agent's unreliable
/// account, and the reader was invited to discount the only real information a
/// failed run had left behind (#288). It is the app's central rule inverted
/// inside the one block built to make that rule visible.
///
/// Three further sites wrote a sentence **Elliot itself** had composed into the
/// same field — a repository that could not be read, a spawn that failed, a run
/// orphaned by a crash. That is the same inversion with no agent involved at
/// all: on two of the three the agent never even ran. Fixing only the stderr
/// case would have left them attributed to a speaker who never spoke, and
/// recorded rather than merely defaulted, which is worse than today.
///
/// So the distinction is made *writable* rather than merely drawn: nothing can
/// record a closing text without naming whose it is, because the only way in is
/// `SkillRun.setClosing(_:)` and the only `ClosingRemark` anything outside this
/// module can build carries a source.
public enum RunResultSource: String, Codable, Sendable, Hashable, CaseIterable {
    /// The `result` field of the terminal `stream-json` event: the agent's own
    /// account of its own work. Hearsay — displayed, never parsed.
    case agent
    /// The process's stderr, kept because the run died before saying anything.
    /// A fact: `Type.fact` is for "anything `gh`, `git` or the process itself
    /// established", and this is the third of those three.
    case stderr
    /// A sentence Elliot wrote about a run it could not start, or could not
    /// finish. A fact too, and emphatically not a claim — nobody claimed it.
    case elliot

    /// Whether the text may be believed only as a claim that something happened
    /// rather than as a report that it did.
    ///
    /// ⛔ Exhaustive, with no `default:`, for the reason
    /// `MoveOrigin.allowsSideEffects` is: a fourth source added later has to be
    /// classified here instead of inheriting an answer. Defaulting to `false`
    /// would promote a claim to a fact; defaulting to `true` would demote a
    /// diagnosis to a claim, which is the defect this type exists to end.
    public var isHearsay: Bool {
        switch self {
        case .agent: true
        case .stderr, .elliot: false
        }
    }

    /// The key column of the verdict block.
    ///
    /// Here rather than in `VerdictBlock` for the reason
    /// `VerifiedOutcome.receiptText` is here: one wording, one place, and
    /// reachable from `ElliotModelTests`, which cannot import the app layer.
    /// `swift test` cannot see a caption drawn in a view, so a caption decided
    /// in a view is a caption nothing checks.
    public var caption: String {
        switch self {
        case .agent: "it said"
        case .stderr: "stderr"
        case .elliot: "elliot"
        }
    }

    /// How the row introduces itself to VoiceOver. Spelt out, because "stderr"
    /// read aloud is not a word.
    public var spokenLead: String {
        switch self {
        case .agent: "It said"
        case .stderr: "Standard error"
        case .elliot: "Elliot"
        }
    }
}

/// What a finished run left behind, together with whose words they are.
///
/// Read-side value: a run stores the two halves in two columns, and this is
/// what they amount to when put back together. It is also the *write*
/// vocabulary — `SkillRun.setClosing(_:)` takes one — which is what makes the
/// pair impossible to set apart.
public struct ClosingRemark: Sendable, Hashable {
    public let text: String

    /// `nil` only for a run that finished before `resultSource` existed.
    ///
    /// ⚠️ It is an absence of a record, never a guess. Every such row predates
    /// #288 and genuinely cannot be attributed: most hold agent prose, some
    /// hold stderr, and nothing distinguishes them after the fact. Inferring
    /// one from a proxy — `numTurns == nil`, an exit code, a state of `failed`
    /// — is exactly what the column exists to stop, so an unattributed remark
    /// degrades to the old wording rather than claiming stderr for history it
    /// cannot know.
    public let source: RunResultSource?

    /// Attributed, and the only remark anything outside `ElliotModel` can make.
    public init(text: String, source: RunResultSource) {
        self.init(text: text, recordedSource: source)
    }

    /// ⛔ Private, and it is the whole reason `source` is an `Optional`.
    /// Unattributed is a state history is *in*, not a state anything may put a
    /// run into: a public initialiser taking `RunResultSource?` would let a
    /// writer opt out of saying whose words it was storing, which is the defect
    /// with an extra step.
    private init(text: String, recordedSource: RunResultSource?) {
        self.text = text
        self.source = recordedSource
    }

    /// A remark read back from a row written before the source was recorded.
    /// Internal: only `SkillRun.closing` has any business making one.
    static func unattributed(_ text: String) -> ClosingRemark {
        ClosingRemark(text: text, recordedSource: nil)
    }

    /// Elliot's own sentence about a run it could not start or could not
    /// finish. Named rather than spelt out at each of the three call sites, so
    /// the attribution is one decision instead of three.
    public static func elliot(_ text: String) -> ClosingRemark {
        ClosingRemark(text: text, source: .elliot)
    }

    /// What a finished process leaves to be attributed: the agent's own words
    /// when it produced any, otherwise the bytes on stderr.
    ///
    /// This preference used to be a `??` inside `RunScheduler.finish`, which
    /// put the one decision about *whose words these are* in the engine, where
    /// checking it costs a real spawn. It is a rule, so it lives here and is
    /// asserted directly. The `??` semantics are preserved exactly, empty
    /// string included: a terminal event carrying `""` is still the agent
    /// having answered, and stderr does not get to stand in for it.
    public static func of(agentText: String?, stderr: String?) -> ClosingRemark? {
        if let agentText { return ClosingRemark(text: agentText, source: .agent) }
        if let stderr { return ClosingRemark(text: stderr, source: .stderr) }
        return nil
    }

    /// The same remark with its edges taken off, or nothing at all when that
    /// leaves nothing. A run whose closing text is whitespace said nothing, and
    /// a captioned empty row is worse than no row.
    public func trimmed() -> ClosingRemark? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return ClosingRemark(text: trimmed, recordedSource: source)
    }

    /// Whether this belongs in the demoted face. An unattributed remark is
    /// treated as hearsay — the safe direction, since believing an unknown is
    /// the only mistake here that cannot be walked back.
    public var isHearsay: Bool { source?.isHearsay ?? true }

    /// The caption the verdict block prints, degrading to the old wording when
    /// nothing was recorded.
    public var caption: String { (source ?? .agent).caption }

    /// How the row introduces itself to VoiceOver, degrading the same way.
    public var spokenLead: String { (source ?? .agent).spokenLead }
}
