import ElliotModel
import ElliotStore
import Foundation
import Testing

@testable import ElliotAppKit

/// What the card and the panel are allowed to say, and what they must not.
///
/// `swift test` cannot see layout, so these assert the *decisions* — which cards
/// get a mark, which sign, and that the view asks the model rather than
/// re-deriving the precedence order. Where things sit on screen is task 7's job,
/// and no test can take it.
@MainActor
@Suite("PR status presentation")
struct PRStatusPresentationTests {

    private func seeded(
        column: ElliotModel.Column = .inReview,
        prNumber: Int? = 52,
        mergeStateStatus: String = "DIRTY",
        mergeable: String = "CONFLICTING",
        reviewDecision: String = "",
        checks: [GHMergeStatus.StatusCheck] = [
            GHMergeStatus.StatusCheck(name: "build", conclusion: "SUCCESS", status: "COMPLETED"),
        ],
        checkedAt: Date = Date(),
        storeTheStatus: Bool = true
    ) async throws -> (AppModel, Card) {
        let store = try BoardStore.inMemory()
        let repo = Repo(
            path: "/tmp/elliot-\(UUID().uuidString)",
            nameWithOwner: "phmatray/Elliot", displayName: "Elliot")
        try await store.saveRepo(repo)

        let now = Date()
        let card = Card(
            repoID: repo.id, title: "Merge me", column: column, orderIndex: 0,
            issueNumber: 7, prNumber: prNumber,
            columnEnteredAt: now, createdAt: now, updatedAt: now)
        try await store.saveCard(card)

        if storeTheStatus, let prNumber {
            try await store.savePRStatus(PRStatus(
                repoID: repo.id, prNumber: prNumber, headRefOid: "a1b2c3d4e5f6",
                checkedAt: checkedAt,
                rawMergeStateStatus: mergeStateStatus, rawMergeable: mergeable,
                rawReviewDecision: reviewDecision, checks: checks))
        }

        let model = AppModel()
        model.testOnlySeed(repos: [repo], cards: [card])
        model.testOnlySeedStore(store)
        await model.refreshPRStatuses()
        return (model, card)
    }

    // MARK: - Which cards get a mark

    @Test("A waiting card with a conflict gets the conflict sign")
    func conflictedCardIsMarked() async throws {
        let (model, card) = try await seeded()
        let resolved = try #require(model.prStatus(for: card))
        #expect(resolved.sign == .conflict)
        #expect(resolved.merge == .conflict)
        // The facets stay apart: the passing check is not swallowed by the sign.
        #expect(resolved.ci == .passing(1))
    }

    @Test("A card nothing has read draws nothing — an unestablished all-clear is the bug")
    func unreadCardDrawsNothing() async throws {
        let (model, card) = try await seeded(storeTheStatus: false)
        #expect(model.prStatus(for: card) == nil)
    }

    @Test(
        "Only In Review is carried into the model",
        arguments: [ElliotModel.Column.backlog, .todo, .inProgress, .done])
    func onlyInReviewIsCarried(column: ElliotModel.Column) async throws {
        let (model, card) = try await seeded(column: column)
        #expect(model.prStatus(for: card) == nil)
        #expect(model.prStatuses.isEmpty)
    }

    @Test("A card with no pull request number carries nothing")
    func noPullRequestCarriesNothing() async throws {
        let (model, card) = try await seeded(prNumber: nil)
        #expect(model.prStatus(for: card) == nil)
    }

    // MARK: - What the sign is allowed to be

    @Test("Nothing wrong means no mark at all, which is not the same as unknown")
    func healthyCardHasNoSign() async throws {
        let (model, card) = try await seeded(mergeStateStatus: "CLEAN", mergeable: "MERGEABLE")
        let resolved = try #require(model.prStatus(for: card))
        #expect(resolved.sign == nil)
    }

    @Test("Nobody having reviewed never produces a mark")
    func noReviewNeverMarks() async throws {
        // On a solo repository this is every pull request. A mark here would
        // light up the whole board for ever.
        let (model, card) = try await seeded(
            mergeStateStatus: "CLEAN", mergeable: "MERGEABLE", reviewDecision: "")
        #expect(model.prStatus(for: card)?.sign == nil)
    }

    @Test("A pull request nothing has judged says so")
    func noBuildIsSaid() async throws {
        let (model, card) = try await seeded(
            mergeStateStatus: "CLEAN", mergeable: "MERGEABLE", checks: [])
        let resolved = try #require(model.prStatus(for: card))
        #expect(resolved.ci == .noChecks)
        #expect(resolved.sign == .noBuild)
    }

    @Test("An aged-out reading reports not-established rather than its old verdict")
    func agedReadingGoesUnknown() async throws {
        let (model, card) = try await seeded(
            mergeStateStatus: "CLEAN", mergeable: "MERGEABLE",
            checkedAt: Date().addingTimeInterval(-(PRStatus.maximumAge + 60)))
        let resolved = try #require(model.prStatus(for: card))
        #expect(resolved.isStale)
        #expect(resolved.sign == .unknown)
    }

    // MARK: - A reading that lands after the card did

    @Test("A reading stored after the card settled still reaches the board")
    func readingThatLandsLaterIsPickedUp() async throws {
        // The defect this guards: `PRWatcher` writes to `prStatus` and touches
        // no card row. A board refreshing only off the card observation learns
        // about the reading never — the card reaches In Review, the refresh runs
        // and finds nothing because the `gh pr view` has not returned yet, the
        // row lands a moment later and nothing fires. The badge would simply
        // never appear, and every test that seeded the row *first* would pass.
        let store = try BoardStore.inMemory()
        let repo = Repo(
            path: "/tmp/elliot-\(UUID().uuidString)",
            nameWithOwner: "phmatray/Elliot", displayName: "Elliot")
        try await store.saveRepo(repo)
        let now = Date()
        let card = Card(
            repoID: repo.id, title: "Merge me", column: .inReview, orderIndex: 0,
            issueNumber: 7, prNumber: 52,
            columnEnteredAt: now, createdAt: now, updatedAt: now)
        try await store.saveCard(card)

        let model = AppModel()
        model.testOnlySeed(repos: [repo], cards: [card])
        model.testOnlySeedStore(store)
        await model.refreshPRStatuses()
        #expect(model.prStatus(for: card) == nil)

        // The reading lands *after* the card has settled — the watcher's order.
        try await store.savePRStatus(PRStatus(
            repoID: repo.id, prNumber: 52, headRefOid: "a1b2c3d4e5f6",
            checkedAt: Date(), rawMergeStateStatus: "DIRTY", rawMergeable: "CONFLICTING",
            rawReviewDecision: "",
            checks: [GHMergeStatus.StatusCheck(name: "build", conclusion: "SUCCESS", status: "COMPLETED")]))

        // What the observation delivers, applied through the same join.
        model.applyPRStatuses(try await store.prStatuses(repoID: repo.id))
        #expect(model.prStatus(for: card)?.sign == PRSign.conflict)
    }

    @Test("The join is by repository and pull request, not by number alone")
    func joinIsKeyedByBothHalves() async throws {
        let (model, card) = try await seeded(storeTheStatus: false)
        // A reading for PR 52 in a *different* repository must not attach.
        model.applyPRStatuses([PRStatus(
            repoID: UUID(), prNumber: 52, headRefOid: "zzz", checkedAt: Date(),
            rawMergeStateStatus: "DIRTY", rawMergeable: "CONFLICTING",
            rawReviewDecision: "", checks: [])])
        #expect(model.prStatus(for: card) == nil)
    }

    // MARK: - The view layer decides only tint and glyph

    @Test("Every sign has a glyph and a tint, and the sentence comes from the model")
    func everySignIsRenderable() {
        let signs: [PRSign] = [
            .conflict, .checksFailing(count: 1), .changesRequested, .reviewRequired,
            .mergeBlocked, .checksRunning, .noBuild, .unknown,
        ]
        for sign in signs {
            #expect(!sign.icon.isEmpty, "\(sign) has no glyph")
            // The sentence is `ElliotModel`'s, shared by the card's tooltip and
            // the panel's headline — one wording, two renderers.
            #expect(!sign.summary.isEmpty, "\(sign) has no sentence")
        }
    }

    @Test("Not knowing is drawn quietly, not as a warning")
    func unknownIsNotAlarming() {
        // A freshly-seen pull request reads UNKNOWN for one tick. Dressing that
        // as a problem would make every new card look broken.
        #expect(PRSign.unknown.tint == Palette.quiet)
        #expect(PRSign.conflict.tint == Palette.refused)
        // Nothing having judged the pull request is *not* quiet: it is the state
        // this feature exists to surface.
        #expect(PRSign.noBuild.tint == Palette.attention)
    }
}
