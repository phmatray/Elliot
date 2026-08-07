import Foundation
import Testing

@testable import ElliotModel

/// What Elliot is willing to interrupt a person for.
///
/// Most of these tests are **negatives**, and that is the shape of the feature:
/// a notification channel is only worth having while it is worth reading, and
/// every event that posts when it should not is a step towards a channel people
/// dismiss without looking. So the rules that matter most are the ones about
/// staying quiet — your own gestures, a cancelled run, a muted category, a
/// board that is already on screen.
///
/// The other rule under test here is that a notification never quotes the
/// agent. `verifiedOutcome` is what `gh` established; `resultText` is what the
/// agent said it did. A banner has room for one sentence, and it has to be the
/// first one.
@Suite("Notification policy")
struct NotificationPolicyTests {

    // MARK: - Fixtures

    private let repo = Repo(
        id: UUID(), path: "/tmp/elliot", nameWithOwner: "phmatray/Elliot",
        displayName: "Elliot", isEnabled: true
    )

    private func card(
        title: String = "Stream the run log", column: Column = .inProgress, pr: Int? = nil
    ) -> Card {
        Card(
            id: UUID(), repoID: repo.id, title: title, column: column, orderIndex: 1,
            issueNumber: 12, prNumber: pr,
            columnEnteredAt: .distantPast, createdAt: .distantPast, updatedAt: .distantPast
        )
    }

    private func run(
        _ state: RunState, outcome: VerifiedOutcome? = nil, resultText: String? = nil
    ) -> SkillRun {
        var run = SkillRun(
            id: UUID(), cardID: UUID(), repoID: repo.id, kind: .implementIssue,
            prompt: "/x", cwd: "/tmp", state: state,
            logPath: "/tmp/a.ndjson", stderrPath: "/tmp/a.stderr",
            verifiedOutcome: outcome, createdAt: .distantPast
        )
        run.resultText = resultText
        return run
    }

    private func decide(
        _ event: NotificationEvent,
        preferences: NotificationPreferences = .default,
        appIsActive: Bool = false
    ) -> BoardNotification? {
        notification(for: event, preferences: preferences, appIsActive: appIsActive)
    }

    // MARK: - 1. The negatives

    @Test("The master switch silences everything, whatever happened")
    func masterSwitchSilencesEverything() {
        let off = NotificationPreferences(isEnabled: false, muted: [])
        let events: [NotificationEvent] = [
            .runFinished(run: run(.succeeded, outcome: .merged(commitSHA: "abc1234", number: nil, url: nil, branch: nil)), card: card(), repo: repo),
            .runFinished(run: run(.failed), card: card(), repo: repo),
            .runStalled(run: run(.stalled), card: card(), repo: repo),
            .systemMove(
                audit: MoveAudit(cardID: UUID(), from: .inProgress, to: .inReview,
                                 origin: .system(reason: .prBecameReady), at: .distantPast),
                card: card(pr: 7), repo: repo
            ),
            .analysisFinished(analysisID: UUID(), repo: repo, proposalCount: 3),
        ]
        for event in events {
            #expect(decide(event, preferences: off) == nil)
        }
    }

    @Test("A muted category posts nothing, and does not silence its neighbours")
    func mutedCategoryIsSilent() {
        let noLanded = NotificationPreferences(isEnabled: true, muted: [.landed])
        let landed = NotificationEvent.runFinished(
            run: run(.succeeded, outcome: .issueCreated(number: 12, url: "u")), card: card(), repo: repo
        )
        #expect(decide(landed, preferences: noLanded) == nil)

        // The neighbour still gets through, or muting one switch would be a
        // master switch wearing a disguise.
        let needsYou = NotificationEvent.runFinished(run: run(.failed), card: card(), repo: repo)
        #expect(decide(needsYou, preferences: noLanded) != nil)
    }

    @Test("With the board in front of you, only the things that need you get through")
    func frontmostSuppressesTheInformationalOnes() {
        // The subtle rule, and the reason the policy takes `appIsActive` as a
        // value: the board already shows a landed run, so a banner about it is
        // a second copy of something you are looking at.
        let landed = NotificationEvent.runFinished(
            run: run(.succeeded, outcome: .merged(commitSHA: "abc1234", number: nil, url: nil, branch: nil)), card: card(), repo: repo
        )
        #expect(decide(landed, appIsActive: true) == nil)
        #expect(decide(landed, appIsActive: false) != nil)

        // A stalled run is easy to miss even on screen — it is the absence of
        // something happening.
        let stalled = NotificationEvent.runStalled(run: run(.stalled), card: card(), repo: repo)
        #expect(decide(stalled, appIsActive: true) != nil)
        #expect(decide(stalled, appIsActive: true)?.category == .needsYou)
    }

    @Test("A run that has not finished is not a finish")
    func nonTerminalRunsPostNothing() {
        for state in [RunState.queued, .running, .cancelling, .stalled] {
            let event = NotificationEvent.runFinished(run: run(state), card: card(), repo: repo)
            #expect(decide(event) == nil, "\(state.rawValue) posted a finish notification")
        }
    }

    @Test("A run you cancelled says nothing — you were there")
    func cancelledRunPostsNothing() {
        #expect(decide(.runFinished(run: run(.cancelled), card: card(), repo: repo)) == nil)
    }

    @Test("A move you made is not the board moving itself")
    func userOriginMovesPostNothing() {
        // The load-bearing negative for criterion 1. A drag and a
        // `board_move_card` are gestures someone made and watched happen.
        for origin in [MoveOrigin.userDrag, .mcp(client: "claude-code")] {
            let audit = MoveAudit(
                cardID: UUID(), from: .todo, to: .inProgress, origin: origin, at: .distantPast
            )
            let event = NotificationEvent.systemMove(audit: audit, card: card(), repo: repo)
            #expect(decide(event) == nil, "\(origin) posted a notification")
        }
    }

    @Test("The two system reasons that describe launch-time truth stay quiet")
    func launchTimeSystemReasonsPostNothing() {
        // Both happen with the window in front of you, and describe what was
        // already true rather than something that just happened.
        for reason in [MoveOrigin.SystemReason.reconciliation, .githubImport] {
            let audit = MoveAudit(
                cardID: UUID(), from: .todo, to: .inReview,
                origin: .system(reason: reason), at: .distantPast
            )
            let event = NotificationEvent.systemMove(audit: audit, card: card(pr: 7), repo: repo)
            #expect(decide(event) == nil, "\(reason.rawValue) posted a notification")
        }
    }

    // MARK: - 2. The positives

    @Test("A run that landed says what gh established, in the panel's own words")
    func landedUsesTheReceipt() {
        let outcome = VerifiedOutcome.issueCreated(number: 12, url: "https://example.com/12")
        let event = NotificationEvent.runFinished(
            run: run(.succeeded, outcome: outcome), card: card(title: "File it"), repo: repo
        )
        let posted = try! #require(decide(event))

        #expect(posted.category == .landed)
        #expect(posted.title == "phmatray/Elliot")
        // The same sentence the detail panel draws — one fact, one wording.
        #expect(posted.body.contains(outcome.receiptText))
        #expect(posted.body.contains("File it"))
        #expect(!posted.playsSound, "an informational notification that pinged would train its dismissal")
    }

    @Test("A run that verified nothing admits it, and never quotes the agent")
    func unverifiedNeverQuotesTheAgent() {
        // Criterion 2, and the sharpest test in this file. The agent's prose is
        // deliberately a distinctive, plausible-sounding claim: if the body ever
        // starts coming from `resultText`, this is the line that fails.
        let prose = "I successfully merged the pull request and cleaned up the branch."
        let event = NotificationEvent.runFinished(
            run: run(.succeeded, outcome: nil, resultText: prose), card: card(), repo: repo
        )
        let posted = try! #require(decide(event))

        #expect(posted.category == .landed)
        #expect(posted.body.contains(unverifiedText))
        #expect(!posted.body.contains(prose))
        #expect(!posted.body.contains("merged"), "the agent's claim reached the body")
    }

    @Test("The three ways a run needs you all sound")
    func failuresNeedYouAndSound() {
        for state in [RunState.failed, .timedOut, .completedWithDenials] {
            let event = NotificationEvent.runFinished(run: run(state), card: card(), repo: repo)
            let posted = try! #require(decide(event), "\(state.rawValue) posted nothing")
            #expect(posted.category == .needsYou, "\(state.rawValue)")
            #expect(posted.playsSound, "\(state.rawValue) did not sound")
        }
    }

    @Test("A pull request that went ready, and one that was merged, each name it")
    func systemMovesNameThePullRequest() {
        let ready = MoveAudit(
            cardID: UUID(), from: .inProgress, to: .inReview,
            origin: .system(reason: .prBecameReady), at: .distantPast
        )
        let readyPosted = try! #require(
            decide(.systemMove(audit: ready, card: card(pr: 57), repo: repo))
        )
        #expect(readyPosted.category == .boardMovedItself)
        #expect(readyPosted.body.contains("PR #57"))
        #expect(readyPosted.body.contains("In Review"))
        #expect(!readyPosted.playsSound)

        let merged = MoveAudit(
            cardID: UUID(), from: .inReview, to: .done,
            origin: .system(reason: .prMergedExternally), at: .distantPast
        )
        let mergedPosted = try! #require(
            decide(.systemMove(audit: merged, card: card(pr: 57), repo: repo))
        )
        #expect(mergedPosted.body.contains("PR #57"))
        #expect(mergedPosted.body.contains("Done"))
    }

    @Test("An analysis that found nothing still says so")
    func analysisWithNoProposalsStillPosts() {
        // Silence here is indistinguishable from a crash, which is the one
        // reading that would stop someone looking.
        let none = try! #require(
            decide(.analysisFinished(analysisID: UUID(), repo: repo, proposalCount: 0))
        )
        #expect(none.category == .analysisReady)
        #expect(none.body.contains("nothing"))

        let some = try! #require(
            decide(.analysisFinished(analysisID: UUID(), repo: repo, proposalCount: 1))
        )
        #expect(some.body.contains("1 proposal"))
        #expect(!some.body.contains("1 proposals"), "the plural is not conditional")
    }

    // MARK: - 3. Identity

    @Test("One notification per card, threaded per repository")
    func identityStopsNotificationsStacking() {
        let subject = card(pr: 7)
        let landed = NotificationEvent.runFinished(
            run: run(.succeeded, outcome: .issueCreated(number: 12, url: "u")),
            card: subject, repo: repo
        )
        let moved = NotificationEvent.systemMove(
            audit: MoveAudit(cardID: subject.id, from: .inProgress, to: .inReview,
                             origin: .system(reason: .prBecameReady), at: .distantPast),
            card: subject, repo: repo
        )

        let first = try! #require(decide(landed))
        let second = try! #require(decide(moved))

        // Two different facts about one card share an identifier, so the second
        // replaces the first rather than leaving a stale claim beside it.
        #expect(first.identifier == "card.\(subject.id.uuidString)")
        #expect(second.identifier == first.identifier)
        #expect(first.body != second.body)

        #expect(first.threadIdentifier == "repo.\(repo.id.uuidString)")
        #expect(second.threadIdentifier == first.threadIdentifier)

        // An analysis is about a repository, so it must not collide with a card.
        let analysisID = UUID()
        let analysis = try! #require(
            decide(.analysisFinished(analysisID: analysisID, repo: repo, proposalCount: 2))
        )
        #expect(analysis.identifier == "analysis.\(analysisID.uuidString)")
        #expect(analysis.cardID == nil)
        #expect(analysis.threadIdentifier == first.threadIdentifier)
    }
}
