import ElliotModel
import ElliotStore
import Foundation

public struct MoveProposal: Sendable {
    public var card: Card
    public var from: ElliotModel.Column
    public var to: ElliotModel.Column
    public var orderIndex: Double
    public var outcome: MoveOutcome
    public var origin: MoveOrigin
}

public enum MoveResult: Sendable, Equatable {
    case moved(runID: UUID?)
    case blocked(MoveBlock)
    case needsInput(NeedsInput)
}

public enum BoardError: Error, LocalizedError {
    case cardNotFound(UUID)
    case repoNotFound(UUID)

    public var errorDescription: String? {
        switch self {
        case .cardNotFound(let id): "No card with id \(id)."
        case .repoNotFound(let id): "No repository with id \(id)."
        }
    }
}

/// The only thing in Elliot that changes a card's column.
///
/// A drag and an MCP `board_move_card` call reach exactly these two methods, so
/// the two paths cannot drift: there is one rule engine and one place that runs
/// it. Everything else — the UI, the MCP helper, the PR watcher — only supplies
/// an origin.
public actor BoardService: SystemMoving {
    private let store: BoardStore
    private let launcher: any RunLaunching

    public init(store: BoardStore, launcher: any RunLaunching) {
        self.store = store
        self.launcher = launcher
    }

    /// Works out what a move would mean, without changing anything.
    public func proposeMove(
        cardID: UUID,
        to column: ElliotModel.Column,
        origin: MoveOrigin,
        followUps: [String]? = nil,
        orderIndex: Double? = nil
    ) async throws -> MoveProposal {
        guard let card = try await store.card(id: cardID) else { throw BoardError.cardNotFound(cardID) }
        guard let repo = try await store.repo(id: card.repoID) else {
            throw BoardError.repoNotFound(card.repoID)
        }

        let activeRun = try await store.activeRun(cardID: cardID)
        let context = MoveContext(
            repoIsEnabled: repo.isEnabled,
            activeRunID: activeRun?.id,
            allowSideEffects: origin.allowsSideEffects,
            providedFollowUps: followUps
        )
        let outcome = evaluateMove(from: card.column, to: column, card: card, context: context)
        let index: Double
        if let orderIndex {
            index = orderIndex
        } else {
            index = try await store.nextOrderIndex(repoID: card.repoID, column: column)
        }

        return MoveProposal(
            card: card, from: card.column, to: column,
            orderIndex: index, outcome: outcome, origin: origin
        )
    }

    /// Applies a proposal. Blocked and input-needing proposals are returned
    /// unchanged rather than forced through.
    @discardableResult
    public func commitMove(_ proposal: MoveProposal) async throws -> MoveResult {
        switch proposal.outcome {
        case .blocked(let block):
            return .blocked(block)

        case .needsInput(let need):
            return .needsInput(need)

        case .noAction:
            try await store.commitMove(
                card: proposal.card, to: proposal.to, orderIndex: proposal.orderIndex,
                origin: proposal.origin, run: nil
            )
            return .moved(runID: nil)

        case .action(let action):
            let run = try await makeRun(for: action, card: proposal.card)
            // One transaction for the card, the run and the audit. The
            // scheduler is handed the id only after it commits, so a crash in
            // between leaves a queued run for the launch sweep rather than a
            // card that moved with nothing behind it.
            try await store.commitMove(
                card: proposal.card, to: proposal.to, orderIndex: proposal.orderIndex,
                origin: proposal.origin, run: run
            )
            await launcher.launch(runID: run.id)
            return .moved(runID: run.id)
        }
    }

    /// Propose and commit in one step — what the MCP tool and simple drags use.
    @discardableResult
    public func move(
        cardID: UUID,
        to column: ElliotModel.Column,
        origin: MoveOrigin,
        followUps: [String]? = nil,
        orderIndex: Double? = nil
    ) async throws -> MoveResult {
        let proposal = try await proposeMove(
            cardID: cardID, to: column, origin: origin,
            followUps: followUps, orderIndex: orderIndex
        )
        return try await commitMove(proposal)
    }

    private func makeRun(for action: TriggerAction, card: Card) async throws -> SkillRun {
        guard let repo = try await store.repo(id: card.repoID) else {
            throw BoardError.repoNotFound(card.repoID)
        }
        let runID = UUID()
        return SkillRun(
            id: runID,
            cardID: card.id,
            repoID: card.repoID,
            kind: action.kind,
            prompt: SlashCommandBuilder.prompt(for: action),
            cwd: repo.path,
            logPath: StoreLocation.runLogURL(runID: runID).path,
            stderrPath: StoreLocation.runStderrURL(runID: runID).path,
            createdAt: Date()
        )
    }

    // MARK: - Cards

    public func createCard(
        repoID: UUID,
        title: String,
        body: String = "",
        story: UserStory? = nil,
        column: ElliotModel.Column = .backlog
    ) async throws -> Card {
        guard try await store.repo(id: repoID) != nil else { throw BoardError.repoNotFound(repoID) }
        let now = Date()
        let card = Card(
            repoID: repoID,
            title: title,
            body: body,
            story: story,
            column: column,
            orderIndex: try await store.nextOrderIndex(repoID: repoID, column: column),
            columnEnteredAt: now,
            createdAt: now,
            updatedAt: now
        )
        try await store.saveCard(card)
        return card
    }

    public func updateCard(_ card: Card) async throws {
        try await store.saveCard(card)
    }

    public func deleteCard(id: UUID) async throws {
        try await store.deleteCard(id: id)
    }

    /// Reorders a card inside its own column without going near the rule engine
    /// — an inert move by construction.
    public func reorder(cardID: UUID, between previous: Double?, and next: Double?) async throws {
        guard var card = try await store.card(id: cardID) else { throw BoardError.cardNotFound(cardID) }
        card.orderIndex = switch (previous, next) {
        case (let p?, let n?): (p + n) / 2
        case (let p?, nil): p + 1024
        case (nil, let n?): n - 1024
        case (nil, nil): 0
        }
        try await store.saveCard(card)
    }

    public func cancelRun(id: UUID) async {
        await launcher.cancel(runID: id)
    }

    // MARK: - SystemMoving

    /// A move Elliot decided on its own — a PR going ready, a merge noticed on
    /// github.com, the launch sweep. The rule engine maps these to `.noAction`,
    /// so nothing is triggered by them.
    public func applySystemMove(
        cardID: UUID,
        to column: ElliotModel.Column,
        reason: MoveOrigin.SystemReason
    ) async {
        guard let proposal = try? await proposeMove(
            cardID: cardID, to: column, origin: .system(reason: reason)
        ) else { return }
        _ = try? await commitMove(proposal)
    }
}
