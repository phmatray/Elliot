import Foundation

public enum RunState: String, Codable, CaseIterable, Sendable, Hashable {
    case queued
    case running
    case cancelling
    case succeeded
    /// Finished without error but was refused at least one tool along the way.
    case completedWithDenials
    case failed
    case cancelled
    /// No output for longer than the idle timeout. Still alive; the user
    /// decides whether to keep waiting.
    case stalled
    case timedOut

    public var isTerminal: Bool {
        switch self {
        case .queued, .running, .cancelling, .stalled: false
        case .succeeded, .completedWithDenials, .failed, .cancelled, .timedOut: true
        }
    }

    /// A run in one of these states holds its card: no further move is allowed.
    public var isActive: Bool { !isTerminal }

    /// Still worth offering a stop to. A run already winding down is not —
    /// `cancelling` means the SIGTERM has gone out, so a second Cancel changes
    /// nothing and reads as a button that does not work.
    public var isCancellable: Bool { isActive && self != .cancelling }
}

/// What `gh` says actually happened, as opposed to what the agent said.
public enum VerifiedOutcome: Codable, Sendable, Hashable {
    case issueCreated(number: Int, url: String)
    /// `create-issue` found the idea already covered and skipped it. A real
    /// success, not a failure — the card just has no new issue.
    case noIssueCreated(reason: String)
    case prOpen(number: Int, url: String, isDraft: Bool, branch: String)
    /// The pull request's own identity rides along with the conclusion so
    /// `CardOutcome.applied` can record *which* pull request finished the card.
    /// A card first sighted after its pull request already merged never sees a
    /// `.prOpen`, so this is the only chance to learn the three fields.
    ///
    /// All three are optional because `Verifier.verifyMergePR` reaches this
    /// through `GHMergeStatus`, which carries a URL but no number or branch of
    /// its own — forcing them non-optional would buy a second `gh` call on a
    /// path that does not need one. `applied` writes each only when non-`nil`,
    /// so a `nil` never clears a field the card already has.
    ///
    /// ⛔ Deliberately no default values: every producer must name what it
    /// holds, and the build is what finds the ones that were dropping it.
    case merged(commitSHA: String?, number: Int?, url: String?, branch: String?)
    case notMerged(reason: String)
    case closedUnmerged(number: Int?, url: String?, branch: String?)
    case unverified(reason: String)
}

/// One invocation of `claude -p`.
public struct SkillRun: Identifiable, Codable, Sendable, Hashable {
    /// Also passed as `--session-id`, so the CLI transcript path is known
    /// before the process emits anything.
    public var id: UUID
    /// The card this run works on. `nil` for an analysis run, which has no card
    /// — exactly one of `cardID` and `analysisID` is set.
    public var cardID: UUID?
    public var repoID: UUID
    /// The analysis this run belongs to, when it is one.
    public var analysisID: UUID?
    /// Which lens this run reads through. On the run rather than only on the
    /// analysis because the window lists runs by angle, and because the
    /// scheduler's dedupe key is `(repoID, angle)`.
    public var analysisAngle: AnalysisAngle?
    public var kind: SkillKind
    /// The exact `-p` argument.
    public var prompt: String
    /// The full argv, kept so a run can be reproduced by hand.
    public var argv: [String]
    public var cwd: String
    /// The last attempt that actually created a session.
    ///
    /// Unchanged when the predecessor was refused, advanced when it ran.
    /// Anything vaguer makes the chain unreadable after two failures: if a
    /// refused fork moved this pointer, the second failure would name a session
    /// that never existed and the window a resumed run is verified over would
    /// have no first attempt to anchor on.
    ///
    /// Next to `cwd` because the two are read together — Claude Code keeps a
    /// session's transcript under a slug of the directory it ran in, so a fork
    /// launched from anywhere else finds nothing.
    ///
    /// ⚠️ `Optional`, and not because a predecessor is rare. A non-optional
    /// `UUID` here would be decoded with `decode(_:forKey:)` rather than
    /// `decodeIfPresent` — a default value does not change that — and would
    /// throw `keyNotFound` on every run recorded before v13, in exactly the
    /// window `BoardStore.openReadOnly` exists to serve. `MigrationsTests`
    /// pins it.
    public var resumedFrom: UUID?
    public var state: RunState
    public var startedAt: Date?
    public var endedAt: Date?
    public var exitCode: Int32?
    public var logPath: String
    public var stderrPath: String
    /// The run's closing text. Display only — never parsed for issue or PR
    /// numbers.
    ///
    /// ⛔ `private(set)`, together with `resultSource` below: the two are one
    /// fact and setting them apart is the defect. It was a plain `var`, four
    /// writers assigned it, and only one of those four was storing the agent's
    /// prose — the other three stored stderr or a sentence Elliot had written,
    /// and the panel captioned all four "IT SAID" (#288). `setClosing(_:)` is
    /// the only way in, and it cannot be called without naming a source.
    public private(set) var resultText: String?
    /// Whose words `resultText` is. `nil` for a run that finished before this
    /// column existed — see `ClosingRemark.source`, which is where that absence
    /// is reasoned about and where it degrades.
    public private(set) var resultSource: RunResultSource?
    public var totalCostUSD: Double?
    public var numTurns: Int?
    public var permissionDenials: [String]
    public var verifiedOutcome: VerifiedOutcome?
    /// What an analysis run had to say about itself: where the stories were
    /// harvested from, what was dropped, and whether the working tree moved.
    /// `nil` for a card run.
    public var analysisReport: AnalysisRunReport?
    public var createdAt: Date

    public init(
        id: UUID = UUID(),
        cardID: UUID?,
        repoID: UUID,
        analysisID: UUID? = nil,
        analysisAngle: AnalysisAngle? = nil,
        kind: SkillKind,
        prompt: String,
        argv: [String] = [],
        cwd: String,
        resumedFrom: UUID? = nil,
        state: RunState = .queued,
        startedAt: Date? = nil,
        endedAt: Date? = nil,
        exitCode: Int32? = nil,
        logPath: String,
        stderrPath: String,
        closing: ClosingRemark? = nil,
        totalCostUSD: Double? = nil,
        numTurns: Int? = nil,
        permissionDenials: [String] = [],
        verifiedOutcome: VerifiedOutcome? = nil,
        analysisReport: AnalysisRunReport? = nil,
        createdAt: Date
    ) {
        self.id = id
        self.cardID = cardID
        self.repoID = repoID
        self.analysisID = analysisID
        self.analysisAngle = analysisAngle
        self.kind = kind
        self.prompt = prompt
        self.argv = argv
        self.cwd = cwd
        self.resumedFrom = resumedFrom
        self.state = state
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.exitCode = exitCode
        self.logPath = logPath
        self.stderrPath = stderrPath
        resultText = closing?.text
        resultSource = closing?.source
        self.totalCostUSD = totalCostUSD
        self.numTurns = numTurns
        self.permissionDenials = permissionDenials
        self.verifiedOutcome = verifiedOutcome
        self.analysisReport = analysisReport
        self.createdAt = createdAt
    }
}

public extension SkillRun {
    var isAnalysis: Bool { kind == .analyzeRepo }
}

public extension SkillRun {
    /// The closing text and its attribution, put back together.
    ///
    /// The pair is stored as two columns because that is what an additive
    /// migration can do to a table already in the field, and read as one value
    /// because they are one fact. A row saved before `resultSource` existed
    /// comes back `.unattributed`, which is an absence of a record rather than
    /// a claim about what the text is.
    var closing: ClosingRemark? {
        guard let resultText else { return nil }
        guard let resultSource else { return .unattributed(resultText) }
        return ClosingRemark(text: resultText, source: resultSource)
    }

    /// The one write path for what a run has to say for itself.
    ///
    /// ⛔ There is deliberately no way to set the text alone. Four writers used
    /// to assign `resultText` directly and only one of them held the agent's
    /// prose; the panel believed all four (#288). A fifth writer now has to
    /// answer *whose words are these* before the code compiles, which is the
    /// difference between a rule and a convention.
    mutating func setClosing(_ remark: ClosingRemark?) {
        resultText = remark?.text
        resultSource = remark?.source
    }
}

public extension SkillRun {
    /// A run that works on a card. `analysisID` and `analysisAngle` are always
    /// nil — the obvious way to build a card run without the two fields that
    /// only make sense for the other kind ever coming apart from each other.
    static func card(
        id: UUID = UUID(),
        cardID: UUID,
        repoID: UUID,
        kind: SkillKind,
        prompt: String,
        argv: [String] = [],
        cwd: String,
        resumedFrom: UUID? = nil,
        state: RunState = .queued,
        startedAt: Date? = nil,
        endedAt: Date? = nil,
        exitCode: Int32? = nil,
        logPath: String,
        stderrPath: String,
        closing: ClosingRemark? = nil,
        totalCostUSD: Double? = nil,
        numTurns: Int? = nil,
        permissionDenials: [String] = [],
        verifiedOutcome: VerifiedOutcome? = nil,
        createdAt: Date
    ) -> SkillRun {
        SkillRun(
            id: id, cardID: cardID, repoID: repoID, analysisID: nil, analysisAngle: nil,
            kind: kind, prompt: prompt, argv: argv, cwd: cwd, resumedFrom: resumedFrom,
            state: state,
            startedAt: startedAt, endedAt: endedAt, exitCode: exitCode,
            logPath: logPath, stderrPath: stderrPath, closing: closing,
            totalCostUSD: totalCostUSD, numTurns: numTurns, permissionDenials: permissionDenials,
            verifiedOutcome: verifiedOutcome, analysisReport: nil, createdAt: createdAt
        )
    }

    /// A run that reads a repository through one angle. `cardID` is always nil
    /// and `kind` is always `.analyzeRepo` — there is no other kind an analysis
    /// run can have, so it is not a parameter here.
    static func analysis(
        id: UUID = UUID(),
        repoID: UUID,
        analysisID: UUID,
        analysisAngle: AnalysisAngle,
        prompt: String,
        argv: [String] = [],
        cwd: String,
        state: RunState = .queued,
        startedAt: Date? = nil,
        endedAt: Date? = nil,
        exitCode: Int32? = nil,
        logPath: String,
        stderrPath: String,
        closing: ClosingRemark? = nil,
        totalCostUSD: Double? = nil,
        numTurns: Int? = nil,
        permissionDenials: [String] = [],
        analysisReport: AnalysisRunReport? = nil,
        createdAt: Date
    ) -> SkillRun {
        SkillRun(
            id: id, cardID: nil, repoID: repoID, analysisID: analysisID, analysisAngle: analysisAngle,
            kind: .analyzeRepo, prompt: prompt, argv: argv, cwd: cwd, state: state,
            startedAt: startedAt, endedAt: endedAt, exitCode: exitCode,
            logPath: logPath, stderrPath: stderrPath, closing: closing,
            totalCostUSD: totalCostUSD, numTurns: numTurns, permissionDenials: permissionDenials,
            verifiedOutcome: nil, analysisReport: analysisReport, createdAt: createdAt
        )
    }
}

/// Why a card changed column. Recorded for every move, including the ones that
/// trigger nothing, so the board's history is explainable after the fact.
public enum MoveOrigin: Codable, Sendable, Hashable {
    case userDrag
    case mcp(client: String)
    case system(reason: SystemReason)
    /// A move an auto-dev session made on its own, with nobody watching.
    ///
    /// It carries the session so the trail can be read back per session — a
    /// board that recorded only "the board did it" could not tell one night's
    /// run from the next.
    ///
    /// **Persisted, and there is no downgrade path.** `moveAudit.origin` is a
    /// JSON column (`Migrations.swift`, the v1 schema) written through the
    /// synthesised `Codable`, so this case is additive for reading rows an older
    /// build wrote, and unreadable by an older build that meets a row this one
    /// wrote. It does **not** travel the IPC wire: `ElliotRequest.moveCard`
    /// carries `(id, to, followUps)`, `MoveDTO` carries no origin, and
    /// `MCPRequestHandler.moveCard` hardcodes `.mcp(client:)` — so this change
    /// does not bump `elliotProtocolVersion`.
    ///
    /// ⚠️ This said "`elliotProtocolVersion` stays 6" until the branch was
    /// merged with `origin/main`, where it is **7**. The claim that mattered —
    /// no bump — was right; the number was read off a base twenty-three commits
    /// behind, which is the same mistake, one field over, as the premise this
    /// whole branch was planned on. A version written down beside the code that
    /// does not change it is a number nothing keeps true: say *this does not
    /// bump it*, and let `Protocol.swift` hold the value.
    case autoDev(sessionID: UUID)

    public enum SystemReason: String, Codable, Sendable, Hashable {
        case prBecameReady
        case prMergedExternally
        case reconciliation
        /// A column set by adopting what GitHub already said. Like every system
        /// reason it maps to `.noAction`, so importing fires no skill.
        case githubImport
    }

    /// System moves react to reality rather than changing it, so they must
    /// never fire a skill.
    ///
    /// **Exhaustive, with no `default:` and no `if case`.** It was
    /// `if case .system = self { return false }; return true`, and that shape
    /// hands `true` to every case added after it — silently, on the single
    /// property that decides whether an unattended `claude -p` starts at
    /// `bypassPermissions` inside a real checkout. A switch makes the next case
    /// a compile error instead of a gift.
    public var allowsSideEffects: Bool {
        switch self {
        case .userDrag, .mcp, .autoDev: true
        case .system: false
        }
    }
}

public struct MoveAudit: Identifiable, Codable, Sendable, Hashable {
    public var id: UUID
    public var cardID: UUID
    public var from: Column
    public var to: Column
    public var origin: MoveOrigin
    public var runID: UUID?
    public var at: Date

    public init(
        id: UUID = UUID(),
        cardID: UUID,
        from: Column,
        to: Column,
        origin: MoveOrigin,
        runID: UUID? = nil,
        at: Date
    ) {
        self.id = id
        self.cardID = cardID
        self.from = from
        self.to = to
        self.origin = origin
        self.runID = runID
        self.at = at
    }
}
