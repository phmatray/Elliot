import ElliotEngine
import ElliotModel
import Foundation
import Testing

@testable import ElliotAppKit

/// A driver that answers from memory.
///
/// An `actor` for the same reason `InertLauncher` in `AppModelTests` is one:
/// `AutoDevDriving` is `Sendable`, and the real conformer (PR4's
/// `AutoDevService`) is an actor too. It records what it was asked so a test
/// can tell "the command reached the driver" from "the model changed its own
/// mind".
private actor FakeAutoDev: AutoDevDriving {
    private var session: AutoDevSession?
    private var rows: [AutoDevEngagement] = []
    /// What `start` was asked for, so a test can tell "the command reached the
    /// driver" from "the model changed its own mind".
    private(set) var startedWith: (repoID: UUID, selection: AutoDevSelection)?
    /// Whether `stop` was called — the one command that must also cancel the
    /// run already going.
    private(set) var stopped = false

    private let cards: [UUID]
    private let failsToStart: Bool

    init(cards: [UUID], failsToStart: Bool = false) {
        self.cards = cards
        self.failsToStart = failsToStart
    }

    struct Refused: Error, LocalizedError {
        var errorDescription: String? { "The driver refused." }
    }

    func start(repoID: UUID, selection: AutoDevSelection) async throws -> AutoDevSession {
        startedWith = (repoID, selection)
        if failsToStart { throw Refused() }
        // The fake does not rank: ranking is PR2's pure function, exercised by
        // PR2's own suite and by PR4's conformer. Here `.automatic` means "take
        // the first `limit`", which is enough to prove the command travelled.
        let engaged: [UUID] = switch selection {
        case .automatic(let limit): Array(cards.prefix(limit))
        case .explicit(let ids): ids
        }
        let made = AutoDevSession(
            repoID: repoID, engagedCardIDs: engaged,
            maxAttemptsPerCard: 3, patience: 900,
            startedAt: Date(timeIntervalSince1970: 1_770_000_000)
        )
        session = made
        rows = made.engagedCardIDs.map {
            AutoDevEngagement(
                sessionID: made.id, cardID: $0, attempts: 1, disposition: .engaged,
                reason: "Waiting for the pull request to open.",
                updatedAt: Date(timeIntervalSince1970: 1_770_000_000))
        }
        return made
    }

    func pause(sessionID: UUID) async -> AutoDevSession? { transition(to: .paused) }
    func resume(sessionID: UUID) async -> AutoDevSession? { transition(to: .running) }

    func stop(sessionID: UUID) async -> AutoDevSession? {
        stopped = true
        return transition(to: .finished)
    }

    func engagements(sessionID: UUID) async -> [AutoDevEngagement] { rows }

    /// Marks the first row merged, so a test can watch the tally move.
    func settleFirstAsMerged() {
        guard !rows.isEmpty else { return }
        rows[0].disposition = .merged
        rows[0].reason = "gh says the pull request was merged."
    }

    /// A session this driver never started — so every command answers `nil`,
    /// which is the whole subject of ``AutoDevStateTests/aCommandThatDoesNotLandSaysSo()``.
    private func transition(to state: AutoDevSession.State) -> AutoDevSession? {
        session?.state = state
        return session
    }
}

/// What `AppModel` holds about an auto-dev session, and what it refuses.
///
/// `@MainActor` on the suite rather than on each test: `AppModel` is main-actor
/// isolated, so every touch of it needs the hop.
@MainActor
@Suite("Auto-dev state")
struct AutoDevStateTests {

    private let epoch = Date(timeIntervalSince1970: 1_770_000_000)

    private func repo(
        _ name: String, enabled: Bool = true, preflight: PreflightState? = nil
    ) -> Repo {
        Repo(
            path: "/tmp/\(name)", nameWithOwner: "phmatray/\(name)",
            defaultBranch: "main", displayName: name,
            isEnabled: enabled, preflight: preflight
        )
    }

    private func card(_ title: String, repoID: UUID, order: Double) -> Card {
        Card(
            repoID: repoID, title: title, column: .backlog, orderIndex: order,
            columnEnteredAt: epoch, createdAt: epoch, updatedAt: epoch
        )
    }

    /// A model with one selected repository and three Backlog cards.
    private func seeded(
        enabled: Bool = true, preflight: PreflightState? = nil
    ) -> (AppModel, Repo, [Card]) {
        let subject = repo("Elliot", enabled: enabled, preflight: preflight)
        let cards = [
            card("one", repoID: subject.id, order: 1),
            card("two", repoID: subject.id, order: 2),
            card("three", repoID: subject.id, order: 3),
        ]
        let model = AppModel()
        model.testOnlySeed(repos: [subject], cards: cards)
        model.selectedRepoID = subject.id
        return (model, subject, cards)
    }

    // MARK: - Refusals

    /// The #151 shape: the gate is on the **act**, stated in a sentence, not a
    /// control that cannot be switched off. Until PR4 lands there is no driver,
    /// and the band has to say that rather than look broken.
    @Test("With no driver attached, the refusal says so and Start does nothing")
    func noDriverIsARefusal() async {
        let (model, _, _) = seeded()
        #expect(model.autoDevRefusal == "Auto-dev is not wired into this build yet.")

        await model.startAutoDev()

        #expect(model.autoDev == nil)
        #expect(model.autoDevEngagedCardIDs.isEmpty)
    }

    /// ⚠️ **Seeds `Repo(preflight: .failing)`, the persisted verdict, and not a
    /// reading.** `testOnlySeedChecks` writes `repoReadings` only — its own doc
    /// comment says so — while every live gate in this app decides on
    /// `Repo.preflightVerdict`: `blockedBadge` guards on
    /// `!repo.preflightVerdict.allowsMoves`, and `AnalysisRefusal.decide` hands
    /// the rule `subject.preflightVerdict`. A test seeding the reading asserts a
    /// gate nothing consults.
    ///
    /// The consequence is worth naming rather than hiding: a repository that has
    /// been *read* as failing but whose verdict has not been persisted yet does
    /// **not** refuse here. That is the shipped behaviour of every other gate —
    /// and using the reading instead would be strictly worse, because
    /// `PreflightReading.verdict(of: nil)` is `.notChecked`, which admits.
    @Test("A repository Preflight has refused cannot be driven")
    func blockedRepositoryIsRefused() async {
        let (model, _, cards) = seeded(preflight: .failing)
        let driver = FakeAutoDev(cards: cards.map(\.id))
        model.testOnlyAttachAutoDev(driver)

        #expect(model.autoDevRefusal?.contains("Preflight") == true)
        // The delegation, not merely the word: this sentence belongs to
        // `UnattendedStartRefusal` and is read off it rather than restated.
        #expect(model.autoDevRefusal == UnattendedStartRefusal.preflightBlocked.sentence)

        await model.startAutoDev()

        #expect(model.autoDev == nil)
        // ⛔ The gate is on the **act**, not on the control's visibility: the
        // driver must not have been asked at all. `autoDev == nil` alone would
        // also hold for a start that ran and whose answer was dropped.
        #expect(await driver.startedWith == nil)
    }

    @Test("A switched-off repository is refused in the board's own words")
    func disabledRepositoryIsRefused() async {
        let (model, _, cards) = seeded(enabled: false)
        let driver = FakeAutoDev(cards: cards.map(\.id))
        model.testOnlyAttachAutoDev(driver)

        #expect(model.autoDevRefusal == Consequence.reason(.repoDisabled))

        await model.startAutoDev()

        #expect(model.autoDev == nil)
        #expect(await driver.startedWith == nil)
    }

    /// ⚠️ **The admitting arm, named on purpose.** `UnattendedStartRefusal` lets
    /// `notChecked` through — blocking would freeze the board for the first
    /// seconds of every launch — so a repository nobody has swept is driveable.
    /// Without this the suite would pin only refusals, and a `guard` that refused
    /// everything would pass every one of them.
    @Test("A repository nobody has swept is not refused")
    func notCheckedDoesNotRefuse() async {
        let (model, _, cards) = seeded(preflight: nil)
        model.testOnlyAttachAutoDev(FakeAutoDev(cards: cards.map(\.id)))

        #expect(model.autoDevRefusal == nil)
    }

    @Test("No repository picked is a refusal, not a silent no-op")
    func noRepositoryIsARefusal() async {
        let (model, _, cards) = seeded()
        model.testOnlyAttachAutoDev(FakeAutoDev(cards: cards.map(\.id)))
        model.selectedRepoID = nil
        #expect(model.autoDevRefusal == "Pick a single repository to drive.")
    }

    // MARK: - Starting

    @Test("Starting engages the cards and marks them")
    func startingEngages() async throws {
        let (model, subject, cards) = seeded()
        let driver = FakeAutoDev(cards: cards.map(\.id))
        model.testOnlyAttachAutoDev(driver)
        model.autoDevCardLimit = 2

        await model.startAutoDev()

        // The number the stepper holds is what the driver was asked for. A
        // model that engaged three cards while the band said two would be a
        // control that promises one thing and does another.
        let asked = await driver.startedWith
        #expect(asked?.repoID == subject.id)
        #expect(asked?.selection == .automatic(limit: 2))

        let session = try #require(model.autoDev)
        #expect(session.repoID == subject.id)
        #expect(session.state == .running)
        #expect(model.autoDevEngagedCardIDs == Set(cards.prefix(2).map(\.id)))
        #expect(model.autoDevEngagements.count == 2)
        #expect(model.autoDevTally == AutoDevTally(engaged: 2, merged: 0, blocked: 0))
    }

    @Test("A second session is refused while one is going")
    func oneSessionAtATime() async {
        let (model, _, cards) = seeded()
        model.testOnlyAttachAutoDev(FakeAutoDev(cards: cards.map(\.id)))
        await model.startAutoDev()

        #expect(model.autoDevRefusal?.contains("already going") == true)
    }

    @Test("A start that throws lands in the status line rather than vanishing")
    func failedStartIsReported() async {
        let (model, _, cards) = seeded()
        model.testOnlyAttachAutoDev(FakeAutoDev(cards: cards.map(\.id), failsToStart: true))

        await model.startAutoDev()

        #expect(model.autoDev == nil)
        #expect(model.status == "The driver refused.")
    }

    // MARK: - Pausing and stopping

    @Test("Pause holds the session; Resume puts it back")
    func pauseAndResume() async {
        let (model, _, cards) = seeded()
        model.testOnlyAttachAutoDev(FakeAutoDev(cards: cards.map(\.id)))
        await model.startAutoDev()

        await model.pauseAutoDev()
        #expect(model.autoDev?.state == .paused)

        await model.resumeAutoDev()
        #expect(model.autoDev?.state == .running)
    }

    /// The permanence claim, at the model layer. Stopping ends the session; it
    /// does **not** clear the report, and it does not unmark the cards. A card
    /// whose merge failed stays in Done, where `rankNextSteps` cannot see it —
    /// this is the only place it is still visible.
    @Test("Stopping finishes the session and keeps every row and every mark")
    func stoppingKeepsTheReport() async {
        let (model, _, cards) = seeded()
        let driver = FakeAutoDev(cards: cards.map(\.id))
        model.testOnlyAttachAutoDev(driver)
        await model.startAutoDev()
        let engaged = model.autoDevEngagedCardIDs

        await model.stopAutoDev()

        // It reached the driver: stopping is the one command that also cancels
        // the run already going, and the queue's Pause cannot do that.
        #expect(await driver.stopped)
        #expect(model.autoDev?.state == .finished)
        #expect(model.autoDevEngagements.count == 3)
        #expect(model.autoDevEngagedCardIDs == engaged, "the report keeps its cards marked")
        #expect(AutoDevBand.figureText(session: model.autoDev, tally: model.autoDevTally) != nil)
    }

    /// The other half of permanence: the report stays *until the next session*,
    /// which is exactly what `lastSyncSummary` does. A report that outlived the
    /// session after it would be two sessions rendered as one.
    @Test("Starting a new session replaces the previous report")
    func aNewSessionReplacesTheReport() async throws {
        let (model, _, cards) = seeded()
        model.testOnlyAttachAutoDev(FakeAutoDev(cards: cards.map(\.id)))
        await model.startAutoDev()
        let first = try #require(model.autoDev?.id)
        await model.stopAutoDev()
        #expect(model.autoDev?.id == first, "stopping keeps the session it finished")

        await model.startAutoDev()

        let second = try #require(model.autoDev?.id)
        #expect(second != first, "a new session is a new record, not an amendment")
        #expect(model.autoDev?.state == .running)
        #expect(model.autoDevTally == AutoDevTally(engaged: 3, merged: 0, blocked: 0))
    }

    // MARK: - A command that does not land

    /// ⛔ **The three commands may not fail by silence.**
    ///
    /// A driver answering `nil` — a session it does not know, one already over,
    /// an actor that refused — used to produce no status line, no log entry and
    /// no visible change, *on the controls that stop an unattended agent*. That
    /// is this repository's own catalogue entry: a mechanism that substitutes a
    /// different answer instead of erroring, and it never says no.
    ///
    /// The fake is given a session it never started, which is exactly the shape
    /// a stale board holds after the loop has moved on.
    @Test("A command the driver does not answer says so", arguments: ["pause", "resume", "stop"])
    func aCommandThatDoesNotLandSaysSo(_ verb: String) async {
        let (model, subject, cards) = seeded()
        model.testOnlyAttachAutoDev(FakeAutoDev(cards: cards.map(\.id)))
        let orphan = AutoDevSession(
            repoID: subject.id, engagedCardIDs: cards.map(\.id), maxAttemptsPerCard: 3,
            patience: 900, startedAt: epoch)
        model.testOnlySeedAutoDev(orphan)
        let before = model.status

        await Self.send(verb, to: model)

        #expect(model.status != before, "\(verb) failed in silence")
        #expect(
            model.status.contains(verb),
            "the sentence for a refused \(verb) does not name the act: \(model.status)")
        // Nothing was adopted, so the board is exactly where it was — which is
        // what the sentence claims.
        #expect(model.autoDev?.state == .running)
    }

    @Test("A command with no session says so", arguments: ["pause", "resume", "stop"])
    func aCommandWithNoSessionSaysSo(_ verb: String) async {
        let (model, _, cards) = seeded()
        model.testOnlyAttachAutoDev(FakeAutoDev(cards: cards.map(\.id)))

        await Self.send(verb, to: model)

        #expect(model.status.contains(verb), "no sentence for \(verb) with no session")
        #expect(model.autoDev == nil)
    }

    /// ⚠️ **Three failures, three sentences.** "There is no loop in this build",
    /// "nothing has been started" and "the loop did not answer" are three
    /// different things to do about it; one sentence for all three is the
    /// two-valued answer to a three-valued question.
    @Test("A command with no driver says so, and differently", arguments: ["pause", "resume", "stop"])
    func aCommandWithNoDriverSaysSo(_ verb: String) async {
        let (model, subject, cards) = seeded()
        let orphan = AutoDevSession(
            repoID: subject.id, engagedCardIDs: cards.map(\.id), maxAttemptsPerCard: 3,
            patience: 900, startedAt: epoch)
        model.testOnlySeedAutoDev(orphan)

        await Self.send(verb, to: model)
        let noDriver = model.status

        #expect(noDriver.contains(verb), "no sentence for \(verb) with no driver")

        // The other two failures, measured against it: a shared sentence would
        // tell the reader to look for the wrong thing.
        model.testOnlyAttachAutoDev(FakeAutoDev(cards: cards.map(\.id)))
        await Self.send(verb, to: model)
        #expect(model.status != noDriver, "an absent driver and a silent one read the same")

        model.testOnlySeedAutoDev(nil)
        await Self.send(verb, to: model)
        #expect(model.status != noDriver, "an absent driver and an absent session read the same")
    }

    private static func send(_ verb: String, to model: AppModel) async {
        switch verb {
        case "pause": await model.pauseAutoDev()
        case "resume": await model.resumeAutoDev()
        case "stop": await model.stopAutoDev()
        default: Issue.record("unknown command \(verb)")
        }
    }

    // MARK: - Refreshing the rows

    @Test("Refreshing re-reads the rows and the tally follows")
    func refreshingMovesTheTally() async {
        let (model, _, cards) = seeded()
        let driver = FakeAutoDev(cards: cards.map(\.id))
        model.testOnlyAttachAutoDev(driver)
        await model.startAutoDev()
        #expect(model.autoDevTally.settled == 0)

        await driver.settleFirstAsMerged()
        await model.refreshAutoDev()

        #expect(model.autoDevTally == AutoDevTally(engaged: 2, merged: 1, blocked: 0))
    }

    /// ⚠️ **The one place silence is right, and it is right for a measured
    /// reason.** `refreshAutoDev` is a poll — the band's `.task` drives it, not a
    /// button — so reporting here would repaint the status bar with a refusal
    /// nobody asked for, on every tick, in every build that has no loop. Losing a
    /// refresh costs a hint; losing a `stop` costs a cancelled agent.
    @Test("Refreshing with nothing behind it stays quiet")
    func refreshingIsSilent() async {
        let (model, _, _) = seeded()
        let before = model.status

        await model.refreshAutoDev()

        #expect(model.status == before)
    }

    // MARK: - The mark's source of truth

    /// The mark on a card is read from the **session**, not from the rows, and
    /// not suppressed by a run. A card auto-dev is driving is *most*
    /// interesting while its run is going, which is the opposite of `stagnation`
    /// and `prSign`, both of which the strip rightly hides.
    @Test("An engaged card stays marked while a run is in flight")
    func markSurvivesARunInFlight() async {
        let (model, subject, cards) = seeded()
        model.testOnlyAttachAutoDev(FakeAutoDev(cards: cards.map(\.id)))
        await model.startAutoDev()

        var run = SkillRun(
            cardID: cards[0].id, repoID: subject.id, kind: .createIssue,
            prompt: "/ai-migration-kit:create-issue x", cwd: "/tmp",
            logPath: "/tmp/run.ndjson", stderrPath: "/tmp/run.log", createdAt: epoch
        )
        run.state = .running
        model.testOnlySeedRuns(active: [cards[0].id: run])

        #expect(model.autoDevEngagedCardIDs.contains(cards[0].id))
    }

    @Test("Seeding a session without a driver is enough to render one")
    func seedingWorksWithoutADriver() {
        let (model, subject, cards) = seeded()
        let session = AutoDevSession(
            repoID: subject.id, engagedCardIDs: cards.map(\.id), maxAttemptsPerCard: 3,
            patience: 900, startedAt: epoch, state: .finished)

        model.testOnlySeedAutoDev(
            session,
            engagements: [
                AutoDevEngagement(
                    sessionID: session.id, cardID: cards[0].id, attempts: 2,
                    disposition: .blocked, reason: "No build has judged the pull request.",
                    updatedAt: epoch)
            ])

        #expect(model.autoDev?.state == .finished)
        #expect(model.autoDevTally == AutoDevTally(engaged: 0, merged: 0, blocked: 1))
        #expect(model.autoDevEngagedCardIDs.count == 3)
    }

    // MARK: - One assignment site

    /// ⛔ **`adopt` is the only writer of the three, and it must stay the only
    /// one.**
    ///
    /// Not a style rule. `AutoDevBand` takes its noun from the **session** and
    /// its settled count from the **rows** precisely because the two can
    /// disagree — Task 3's fix round is what established that — and the design's
    /// answer is that the disagreement is *transient*, bounded by one assignment
    /// at one moment. A second writer makes it permanent, and it does so
    /// invisibly: the band still renders, the figure still renders, and they
    /// simply describe two moments.
    ///
    /// ⚠️ **No behavioural test can reach this**, which is why it is a source
    /// gate rather than an assertion: a `stopAutoDev` that also wrote
    /// `autoDev = nil` after `adopt` would leave every test above green except
    /// the ones about stopping, and a `refreshAutoDev` that assigned
    /// `autoDevEngagements` directly would leave *all* of them green. Measured by
    /// break-testing, not assumed.
    ///
    /// Reading `AppModel.swift` alone is enough, and that is a fact rather than a
    /// convenience: all three setters are `private(set)`, so no other file in the
    /// package *can* assign them.
    @Test("adopt is the only place the session, the rows and the marks are assigned")
    func adoptIsTheOnlyWriter() throws {
        let code = try HiddenFaceState.code(of: "AppModel.swift")

        // Positive witnesses: a renamed `adopt`, or a renamed property, would
        // make every claim below vacuously true and this gate would go green
        // having read nothing at all.
        #expect(
            code.contains("private func adopt("),
            "AppModel no longer declares adopt( — this gate is reading the wrong thing")
        let body = try HiddenFaceState.body(of: "private func adopt(", in: code)

        for property in ["autoDev", "autoDevEngagements", "autoDevEngagedCardIDs"] {
            let needle = "\(property) = "
            let everywhere = code.components(separatedBy: needle).count - 1
            let inAdopt = body.components(separatedBy: needle).count - 1

            #expect(
                inAdopt == 1,
                Comment(
                    rawValue: """
                        adopt assigns \(property) \(inAdopt) times, not once. This gate reads the \
                        wrong function, or the one assignment site has been split.
                        """))
            #expect(
                everywhere == inAdopt,
                Comment(
                    rawValue: """
                        \(property) is assigned \(everywhere) times in AppModel.swift and \
                        \(inAdopt) of them are inside adopt. The session, its rows and the engaged \
                        set are written together or they describe two moments: the band counts the \
                        session and the tally counts the rows, and the whole design of that split \
                        is that their disagreement lasts exactly one assignment. A second writer \
                        makes it permanent, and nothing on screen says so.
                        """))
        }
    }
}
