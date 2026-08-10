import ElliotModel
import ElliotProcess
import ElliotStore
import Foundation

public enum AppraisalError: Error, LocalizedError, Equatable {
    case cardNotFound(UUID)
    case repoNotFound(UUID)
    /// Preflight, or the repository's own switch, refuses this start.
    ///
    /// Carrying the ``UnattendedStartRefusal`` rather than a pre-rendered
    /// string, exactly as `AnalysisError.repoRefused` does: the sentence is the
    /// rule's, decided once in `ElliotModel`, so a caller that wants to name the
    /// remedy can do it without re-deciding the refusal.
    case repoRefused(UnattendedStartRefusal)
    /// Something already holds this card — another skill, or an earlier
    /// appraisal. Refused rather than queued: two appraisals of one card would
    /// each write the other's fields over.
    case cardAlreadyHeld(UUID)

    public var errorDescription: String? {
        switch self {
        case .cardNotFound(let id): "No card with id \(id)."
        case .repoNotFound(let id): "No repository with id \(id)."
        case .repoRefused(let refusal): refusal.sentence
        case .cardAlreadyHeld:
            "A run is already working on this card; its appraisal has to wait for it."
        }
    }
}

/// Starts the read-only run that fills a card in.
///
/// It fills in; it never ranks. What the two signals are *worth* is a pure
/// function over them, one PR away, and a service that both produced and
/// weighed them would be a service whose ranking could not be re-derived.
///
/// ⛔ **This is the only unattended agent in Elliot that starts outside the
/// funnel.** An appraisal run passes through no move: no `evaluateMove`, no
/// `MoveOrigin.allowsSideEffects`, no repository preflight on the transition. So
/// the guard is built here, explicitly, out of the same
/// `UnattendedStartRefusal` the analysis path and the board's own tooltip read.
///
/// Shaped on `AnalysisService` deliberately, down to the order of its steps:
/// resolve, refuse, create the artifact directory, build the prompt, claim,
/// launch. Two services that start unattended agents should not do it two
/// different ways.
public actor AppraisalService {
    private let store: BoardStore
    private let launcher: any RunLaunching
    /// Preflight's verdict, asked live at every start.
    ///
    /// No default anywhere, deliberately — the same decision `AnalysisService`
    /// records for its own gate. A defaulted gate compiles at every
    /// construction site and catches none of them; this way each one states its
    /// answer, and a test that wants no sweep says ``OpenGate`` out loud.
    private let gate: any RepoGating

    public init(store: BoardStore, launcher: any RunLaunching, gate: any RepoGating) {
        self.store = store
        self.launcher = launcher
        self.gate = gate
    }

    /// Starts one appraisal for one card.
    ///
    /// **One run per card**, which is the design and not a convenience.
    /// `skillRun`'s CHECK is a XOR — `("cardID" IS NULL) <> ("analysisID" IS
    /// NULL)` — so a run carrying a card satisfies the schema exactly as written
    /// and needs no migration. It also buys the ownership the card's new columns
    /// rest on: `activeRun(cardID:)` answers with this run for its whole life,
    /// so `BoardService.proposeMove` refuses a move while it goes, and
    /// `claimCardForRun` refuses a second appraisal. The claim **is** the
    /// deduplication; there is no separate in-flight set to drift from it.
    ///
    /// The cost is N runs for N cards rather than one. It is bounded by the
    /// read-only lane, which is where they belong anyway.
    @discardableResult
    public func appraise(cardID: UUID) async throws -> SkillRun {
        guard let card = try await store.card(id: cardID) else {
            throw AppraisalError.cardNotFound(cardID)
        }
        guard let repo = try await store.repo(id: card.repoID) else {
            throw AppraisalError.repoNotFound(card.repoID)
        }

        // ⛔ **The one rule, asked at the act, by its second caller.**
        //
        // Asked live, before anything is written: a run committed and then
        // refused would leave a queued row for the launch sweep to revive.
        //
        // ⚠️ **`gate.verdict(for:)` answers a three-valued `PreflightState`, and
        // this call site does not collapse it.** The rule decides what
        // `notChecked` means — it lets it through, for the reasons
        // `PreflightState` writes out — and it decides it in one place. A
        // `Bool` here would be `PreflightService.isBlocking` restored: *nobody
        // looked* and *asked and clear* spelled the same way.
        //
        // ⚠️ The gate is asked even for a repository the reader switched off,
        // which costs a sweep the rule will then ignore. The alternative is for
        // this caller to know that the switch is asked first — and a second copy
        // of the rule's ordering is exactly what `UnattendedStartRefusal`
        // removed. `disabledWinsOverBlocked` pins the order that makes the
        // saving tempting.
        if let refusal = UnattendedStartRefusal.refusal(
            repo: repo, preflight: await gate.verdict(for: repo)
        ) {
            throw AppraisalError.repoRefused(refusal)
        }

        let runID = UUID()
        let artifact = StoreLocation.appraisalArtifactURL(runID: runID)
        // Created up front so the agent has somewhere to write, and so
        // `--add-dir` points at a directory that exists — the same reason
        // `AnalysisService.start` creates its own.
        //
        // `try?` and not a `throw`: `withIntermediateDirectories: true` already
        // succeeds when the directory is there, so the only failures left are a
        // read-only or full disk — and those do not become an indistinguishable
        // answer downstream. `AppraisalHarvester` checks the artifact's
        // existence separately and reports *"No artifact was written at
        // \<path>"*, naming the path, which is the honest account of this
        // failure and one no card field is written from.
        try? FileManager.default.createDirectory(
            at: artifact.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )

        let run = SkillRun.card(
            id: runID,
            cardID: card.id,
            repoID: repo.id,
            kind: .appraiseCards,
            prompt: AppraisalPromptBuilder.prompt(
                cardTitle: card.displayTitle,
                // `Card.ideaText` and not the story: the fallback from story to
                // note to title already exists there, and a second copy of it
                // would be a second answer to "what does this card say".
                cardText: card.ideaText,
                repoNameWithOwner: repo.nameWithOwner,
                outputPath: artifact.path
            ),
            cwd: repo.path,
            logPath: StoreLocation.runLogURL(runID: runID).path,
            stderrPath: StoreLocation.runStderrURL(runID: runID).path,
            createdAt: Date()
        )

        // The compare-and-set, not a check followed by an insert. This actor is
        // reentrant, so a check that spanned the `await`s above could be passed
        // by two calls before either wrote.
        //
        // ⛔ **Losing the claim is a named refusal, never `nil` and never a
        // second run.** `claimCardForRun` answers `false` for exactly one
        // reason — an active run already holds this card — so the caller learns
        // *what* stopped it. Swallowing it would put an appraisal alongside the
        // writer whose card fields it is about to overwrite.
        guard try await store.claimCardForRun(run) else {
            throw AppraisalError.cardAlreadyHeld(cardID)
        }
        await launcher.launch(runID: run.id)
        return run
    }
}
