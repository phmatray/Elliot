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
    ///
    /// `static`, not `private`, since #196: `interval(...)` below is a pure
    /// static function and needs to read them without an instance.
    static let busyInterval: Duration = .seconds(15)
    static let idleInterval: Duration = .seconds(60)
    static let maxInterval: Duration = .seconds(300)

    /// Told once per sweep, unconditionally. A card waiting on CI has no run to
    /// finish and no move to make, so without this nothing would ever wake its
    /// session — a round is a handful of local reads and is idempotent by
    /// contract, so a tick that changed nothing just costs a no-op.
    ///
    /// `weak`, the shape `mover` above and `RunScheduler.roundTrigger` already
    /// use: the registrant owns the watcher (directly or through `AppModel`),
    /// so a strong reference back would be a cycle neither could ever break.
    private weak var roundTrigger: (any RoundTriggering)?

    /// Whether anything unattended is going on right now.
    ///
    /// A closure and not a protocol: it is one boolean with one caller, and a
    /// test needs `{ true }` rather than a double. Unlike `roundTrigger` this
    /// has **no `weak` to save it** — a closure capture is strong by default —
    /// so whoever installs one must capture `[weak self]` (or whatever it
    /// actually needs), never the watcher itself or anything that owns it: a
    /// strong capture of either would be exactly the retain cycle
    /// `roundTrigger`'s `weak` exists to avoid, moved one property down and
    /// hidden inside a closure instead of visible on the type.
    private var sessionProbe: (@Sendable () async -> Bool)?

    /// Told when this sweep refreshed the reading behind a merge that is already
    /// queued — the one admission rule the scheduler cannot release by itself.
    ///
    /// ⛔ **Not the same thing as `roundTrigger`, and one is not a substitute for
    /// the other.** A round asks a *session* what it wants to move next; it
    /// re-reads the queue but never drains it, so a merge already sitting in that
    /// queue under `.mergeVerdictNotEstablished` was never reconsidered by
    /// anything, and the refusal's own sentence promised it would be. That is why
    /// this is wired to the queue rather than folded into the round: a merge a
    /// human dragged is held by the same rule and there may be no session at all.
    ///
    /// `weak`, for the reason `roundTrigger` and `mover` are.
    private weak var queue: (any QueueReconsidering)?

    public init(store: BoardStore, gh: GHClient, mover: any SystemMoving) {
        self.store = store
        self.gh = gh
        self.mover = mover
    }

    public func setRoundTrigger(_ trigger: any RoundTriggering) {
        roundTrigger = trigger
    }

    public func setQueueReconsidering(_ queue: any QueueReconsidering) {
        self.queue = queue
    }

    public func setSessionProbe(_ probe: @escaping @Sendable () async -> Bool) {
        sessionProbe = probe
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
        guard let repos = try? await store.repos() else { return Self.idleInterval }
        var sawChange = false
        var anyRunning = false
        var refreshedAHeldMerge = false

        for repo in repos where repo.isEnabled {
            let all = (try? await store.cards(repoID: repo.id)) ?? []
            // A card whose merge is queued has already left In Review —
            // `commitMove` moves it to Done *before* the run — so its reading
            // would stop being refreshed at the exact moment admission starts
            // demanding a current one. One query per repository per tick.
            // `activeRuns` includes `.queued`: `RunState.isActive` is
            // `!isTerminal`, and `.queued` is not terminal.
            let mergePending = Set(
                ((try? await store.activeRuns(cardIDs: all.map(\.id))) ?? [:])
                    .filter { $0.value.kind == .mergePR }
                    .keys)
            let watched = all.filter { $0.column == .inProgress || $0.column == .inReview }
            guard !watched.isEmpty || !mergePending.isEmpty else { continue }

            if let runs = try? await store.runs(repoID: repo.id, limit: 20),
               runs.contains(where: { $0.state.isActive }) {
                anyRunning = true
            }

            guard let prs = try? await gh.pullRequests(repo: repo.nameWithOwner, limit: 100) else {
                continue
            }
            var movedHere = false
            for card in watched where await reconcile(card: card, against: prs) {
                sawChange = true
                movedHere = true
            }
            // Re-read rather than reuse the snapshot when this repository's
            // cards moved: `reconcile` above may have just promoted one. With
            // the stale snapshot a card that reached In Review this very tick
            // was skipped until the next one — up to ~6 minutes once the quiet
            // backoff has widened — and a card promoted *out* of it still
            // spent a call and wrote a row for a pull request already merged.
            //
            // Local rather than the accumulating `sawChange`: that one is true
            // as soon as *any* repository moved, and would re-read every
            // repository after it for nothing.
            let settled = movedHere ? (try? await store.cards(repoID: repo.id)) ?? all : all
            if await refreshStatuses(
                repo: repo, cards: settled, alsoRead: mergePending, prs: prs) {
                refreshedAHeldMerge = true
            }
        }

        // ⛔ Before the round, and before the backoff is chosen. A merge held for
        // a stale reading is released by *this* write and by nothing else, so the
        // drain belongs in the same sweep — and ahead of `triggerRound()` so the
        // session's round reads a queue that has already reconsidered rather than
        // one still showing the refusal that has just stopped applying.
        //
        // Conditional, unlike the round below: a round is a handful of local
        // reads over a session's own rows, while a drain reads the store once per
        // pending run and can spawn a `claude`. Asking on every tick regardless
        // would be harmless but it would also stop saying anything — the flag is
        // the record that a *specific* fact changed.
        if refreshedAHeldMerge {
            await queue?.reconsiderQueue()
        }

        if sawChange || anyRunning {
            quietRounds = 0
        } else {
            quietRounds += 1
        }

        // Unconditional: a round is a handful of local reads and is idempotent
        // by contract, so a tick that changed nothing costs a no-op — and a
        // session whose only card is waiting on CI has no other event at all
        // that would ever wake it.
        await roundTrigger?.triggerRound()

        let sessionRunning = await sessionProbe?() ?? false
        return jittered(
            Self.interval(
                sawChange: sawChange, anyRunning: anyRunning,
                sessionRunning: sessionRunning, quietRounds: quietRounds))
    }

    /// How long to wait before the next sweep, before jitter.
    ///
    /// Pure and static so the rule is testable without a clock: `tick()`
    /// measures, this decides, and `jittered` still wraps whatever comes back
    /// — several repositories must not fall into lockstep.
    ///
    /// `sessionRunning` caps the window at `idleInterval`. Under an unattended
    /// session "nothing moved" is the *normal* state — the cards are waiting
    /// on CI — so the quiet backoff would otherwise put the watcher to sleep
    /// for five minutes exactly when it is working.
    ///
    /// For `sessionRunning: false` this returns exactly what the inline
    /// formula it replaced returned, for every input — pinned by
    /// `PRWatcherForSessionsTests.pinsTheWideningFormula`.
    static func interval(
        sawChange: Bool, anyRunning: Bool, sessionRunning: Bool, quietRounds: Int
    ) -> Duration {
        if sawChange || anyRunning {
            return anyRunning ? busyInterval : idleInterval
        }
        let widened = min(
            idleInterval.components.seconds << min(quietRounds / 30, 3),
            maxInterval.components.seconds
        )
        let ceiling = sessionRunning
            ? idleInterval.components.seconds : maxInterval.components.seconds
        return .seconds(min(widened, ceiling))
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
        // The recorded pull request wins: it is the one this card is about, and
        // re-matching by issue could pull a finished card onto an unrelated
        // later pull request.
        //
        // The exception is a pull request closed *without merging* while the
        // card is still in flight. That is not the end of the story — someone
        // opens a replacement for the same issue — and since #139 the abandoned
        // number gets written onto the card so the panel can link to it. Match
        // on the number alone and that write would pin the card to a dead pull
        // request for ever, invisible to `PRMatcher`, never leaving In Progress.
        // Buying the panel a link at the cost of the card is not a trade worth
        // making; `bestMatch` prefers the most recent, so the replacement wins.
        let recorded = card.prNumber.flatMap { number in prs.first { $0.number == number } }
        let match: GHPullRequest? = if card.prNumber != nil {
            if recorded?.isClosedUnmerged == true, card.column != .done, let issue = card.issueNumber {
                PRMatcher.bestMatch(among: prs, issue: issue) ?? recorded
            } else {
                recorded
            }
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
    /// **In Review, and any card whose merge is queued or running.** The first
    /// half is the original rule and its reason stands: a card in In Progress
    /// has a draft pull request that `implement-issue` is still writing, so a
    /// red check there is a transient state the run is already handling.
    ///
    /// The second half exists because `BoardService.commitMove` puts a card in
    /// Done *before* its merge run, so the instant a merge is queued this would
    /// stop refreshing it — while admission refuses a merge whose green has
    /// aged past `PRStatus.maximumAge`. Without it that refusal is permanent,
    /// and a repository an unattended session keeps busy never merges anything.
    ///
    /// The listing above already carries `headRefOid`, so most ticks answer
    /// "nothing has changed" without spending a call — see
    /// `PRStatus.needsRefresh`. What this does **not** do is touch the card:
    /// card fields are decided in one place, `VerifiedOutcome.applied(to:)`, and
    /// a poller that wrote one would be the second write path that invariant
    /// exists to prevent.
    ///
    /// Returns whether a row was written for a card in `alsoRead` — that is, for
    /// a card whose merge is *already queued*. That is the second half of this
    /// method's reason for existing: refreshing the reading is what lifts
    /// `.mergeVerdictNotEstablished`, and admission is only asked again when
    /// something drains the queue. `tick()` turns this answer into exactly one
    /// `reconsiderQueue()`. Refreshing the reading and never re-asking is the
    /// half-fix that shipped: the guard was correct and unreachable-from.
    ///
    /// The In Review half deliberately does **not** count. Those cards have no
    /// queued run to release; a drain for them would be a drain for a fact that
    /// holds nothing.
    private func refreshStatuses(
        repo: Repo, cards: [Card], alsoRead: Set<UUID>, prs: [GHPullRequest]
    ) async -> Bool {
        let now = Date()
        var refreshedAHeldMerge = false
        for card in cards where card.column == .inReview || alsoRead.contains(card.id) {
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
            // After the write, never before it: a read that failed at the guard
            // above changed nothing, and reporting it would ask the queue to
            // reconsider a rule that still holds.
            if alsoRead.contains(card.id) { refreshedAHeldMerge = true }
        }
        return refreshedAHeldMerge
    }

    /// ±20%, so several repos do not fall into lockstep.
    private func jittered(_ base: Duration) -> Duration {
        let seconds = Double(base.components.seconds)
        return .seconds(seconds * Double.random(in: 0.8...1.2))
    }
}
