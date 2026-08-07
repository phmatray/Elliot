import ElliotModel
import ElliotProcess
import ElliotStore
import Foundation

/// Notices what happens to a pull request outside Elliot.
///
/// Polls **per repository**, not per card: one `gh pr list` covers every card
/// in flight there. Webhooks would need a public endpoint, and
/// `gh pr checks --watch` blocks a process per pull request; a handful of calls
/// a minute against a 5000/hour budget is the cheaper answer.
public actor PRWatcher {
    private let store: BoardStore
    private let gh: GHClient
    private weak var mover: (any SystemMoving)?

    private var task: Task<Void, Never>?
    private var quietRounds = 0

    /// Fast while something is running — the card should reach In Review the
    /// moment implement-issue flips its PR ready.
    private let busyInterval: Duration = .seconds(15)
    private let idleInterval: Duration = .seconds(60)
    private let maxInterval: Duration = .seconds(300)

    public init(store: BoardStore, gh: GHClient, mover: any SystemMoving) {
        self.store = store
        self.gh = gh
        self.mover = mover
    }

    public func start() {
        guard task == nil else { return }
        task = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let interval = await self.tick()
                try? await Task.sleep(for: interval)
            }
        }
    }

    public func stop() {
        task?.cancel()
        task = nil
    }

    /// One sweep. Returns how long to wait before the next.
    @discardableResult
    func tick() async -> Duration {
        guard let repos = try? await store.repos() else { return idleInterval }
        var sawChange = false
        var anyRunning = false

        for repo in repos where repo.isEnabled {
            let cards = (try? await store.cards(repoID: repo.id))?
                .filter { $0.column == .inProgress || $0.column == .inReview } ?? []
            guard !cards.isEmpty else { continue }

            if let runs = try? await store.runs(repoID: repo.id, limit: 20),
               runs.contains(where: { $0.state.isActive }) {
                anyRunning = true
            }

            guard let prs = try? await gh.pullRequests(repo: repo.nameWithOwner, limit: 100) else {
                continue
            }
            var movedHere = false
            for card in cards where await reconcile(card: card, against: prs) {
                sawChange = true
                movedHere = true
            }
            // Re-read rather than reuse `cards` when this repository's cards
            // moved: `reconcile` above may have just promoted one. With the
            // stale snapshot a card that reached In Review this very tick was
            // skipped until the next one — up to ~6 minutes once the quiet
            // backoff has widened — and a card promoted *out* of it still spent
            // a call and wrote a row for a pull request already merged.
            //
            // Local rather than the accumulating `sawChange`: that one is true
            // as soon as *any* repository moved, and would re-read every
            // repository after it for nothing.
            let settled = movedHere ? (try? await store.cards(repoID: repo.id)) ?? cards : cards
            await refreshStatuses(repo: repo, cards: settled, prs: prs)
        }

        if sawChange || anyRunning {
            quietRounds = 0
            return anyRunning ? jittered(busyInterval) : jittered(idleInterval)
        }
        quietRounds += 1
        // Back off once nothing has moved for a while.
        let backoff = min(
            idleInterval.components.seconds << min(quietRounds / 30, 3),
            maxInterval.components.seconds
        )
        return jittered(.seconds(backoff))
    }

    /// Applies whatever the pull request says about this card. Returns whether
    /// anything changed.
    ///
    /// It used to re-derive the three conclusions — open, merged, closed
    /// unmerged — straight from the `GHPullRequest`, which is why this was the
    /// site that drifted without looking like a fourth copy of a switch that
    /// lives elsewhere. It states them in the verifier's vocabulary now, and
    /// what they do to a card is decided once, in `ElliotModel`.
    ///
    /// Internal rather than private so the tests can drive one sighting at a
    /// time, the way `tick()` is.
    func reconcile(card: Card, against prs: [GHPullRequest]) async -> Bool {
        let match: GHPullRequest? = if let number = card.prNumber {
            prs.first { $0.number == number }
        } else if let issue = card.issueNumber {
            PRMatcher.bestMatch(among: prs, issue: issue)
        } else {
            nil
        }
        guard let pr = match else { return false }

        let result = pr.verifiedOutcome.applied(to: card, attribution: .live)
        guard result.changed else { return false }

        try? await store.saveCard(result.card)
        if let move = result.move {
            await mover?.applySystemMove(cardID: card.id, to: move.column, reason: move.reason)
        }
        return true
    }

    /// Reads what GitHub says about the pull requests the board is *waiting* on.
    ///
    /// **In Review only, deliberately.** A card in In Progress has a draft pull
    /// request that `implement-issue` is still writing, so a red check there is
    /// a transient state the run is already handling. The information only
    /// changes a decision once the card has stopped moving on its own.
    ///
    /// The listing above already carries `headRefOid`, so most ticks answer
    /// "nothing has changed" without spending a call — see
    /// `PRStatus.needsRefresh`. What this does **not** do is touch the card:
    /// card fields are decided in one place, `VerifiedOutcome.applied(to:)`, and
    /// a poller that wrote one would be the second write path that invariant
    /// exists to prevent.
    private func refreshStatuses(repo: Repo, cards: [Card], prs: [GHPullRequest]) async {
        let now = Date()
        for card in cards where card.column == .inReview {
            guard let number = card.prNumber else { continue }
            let currentHead = prs.first { $0.number == number }?.headRefOid
            let stored = try? await store.prStatus(repoID: repo.id, prNumber: number)
            guard PRStatus.needsRefresh(stored: stored ?? nil, currentHeadOid: currentHead, now: now)
            else { continue }

            // A failed read writes nothing and erases nothing: the previous row
            // stands and ages out on its own, which reports "not established"
            // rather than inventing either a pass or a failure.
            guard let status = try? await gh.mergeStatus(repo: repo.nameWithOwner, number: number)
            else { continue }
            try? await store.savePRStatus(
                status.prStatus(repoID: repo.id, prNumber: number, checkedAt: now))
        }
    }

    /// ±20%, so several repos do not fall into lockstep.
    private func jittered(_ base: Duration) -> Duration {
        let seconds = Double(base.components.seconds)
        return .seconds(seconds * Double.random(in: 0.8...1.2))
    }
}
