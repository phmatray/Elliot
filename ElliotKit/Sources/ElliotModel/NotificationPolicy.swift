import Foundation

/// Something Elliot noticed that a person might want to know about.
///
/// Four cases, and all four are *facts already established* rather than
/// gestures anyone made. There is deliberately no `.runStarted`, no
/// `.cardMoved`, no `.moveRefused`: you were there for those, and a
/// notification about your own last action is noise that teaches people to
/// dismiss the channel.
public enum NotificationEvent: Sendable {
    /// A run reached some terminal state. Which one decides everything.
    case runFinished(run: SkillRun, card: Card, repo: Repo)
    /// A run has emitted nothing for the idle timeout. Still alive.
    case runStalled(run: SkillRun, card: Card, repo: Repo)
    /// The board advanced a card with no gesture from anyone.
    case systemMove(audit: MoveAudit, card: Card, repo: Repo)
    case analysisFinished(analysisID: UUID, repo: Repo, proposalCount: Int)
}

/// Whether an event is worth interrupting a human for, and what it should say.
///
/// Pure: no `Date()`, no `Bundle`, no notification centre, no I/O. That is the
/// whole point — what is worth an interruption is a product rule that will be
/// argued about and changed, and in this repository a rule that cannot be
/// tested is a rule that is not enforced. The app maps its three streams into
/// `NotificationEvent`, calls this, and posts whatever comes back; it holds no
/// judgement of its own.
///
/// `appIsActive` is passed in rather than read, for the same reason
/// `preferences` is: "suppressed while you are looking at the board, except
/// when it needs you" is the one genuinely subtle rule here, and passing both
/// as values makes it two lines of test instead of something you can only check
/// by launching the app and looking away.
///
/// ### The body never quotes the agent
///
/// A notification is an assertion about what happened, so it is built from what
/// `gh` established — `verifiedOutcome`, through `receiptText` — and never from
/// `resultText`, which is the agent's own account of its own work. A run that
/// succeeded with nothing verified says exactly that. This is the same rule the
/// detail panel draws in two type faces, applied where there is only room for
/// one sentence.
public func notification(
    for event: NotificationEvent,
    preferences: NotificationPreferences,
    appIsActive: Bool
) -> BoardNotification? {
    guard let draft = draftNotification(for: event) else { return nil }
    guard preferences.allows(draft.category) else { return nil }
    // On screen, the board already says it — except for the things that need a
    // person, which are easy to miss even with the window in front of you.
    guard !appIsActive || draft.category == .needsYou else { return nil }
    return draft
}

// MARK: - What each event would say, before anyone asks whether to say it

/// Deliberately separate from the two gates above, so "what would this event
/// say" and "may we say it" cannot be confused for each other — and so adding
/// an event cannot accidentally add a way past the preference check.
private func draftNotification(for event: NotificationEvent) -> BoardNotification? {
    switch event {
    case .runFinished(let run, let card, let repo):
        return finishedNotification(run: run, card: card, repo: repo)

    case .runStalled(_, let card, let repo):
        return BoardNotification(
            identifier: identifier(for: card),
            threadIdentifier: identifier(for: repo),
            category: .needsYou,
            title: repo.nameWithOwner,
            body: "\(card.displayTitle) has gone quiet — no output for a while.",
            playsSound: true,
            cardID: card.id,
            repoID: repo.id
        )

    case .systemMove(let audit, let card, let repo):
        return systemMoveNotification(audit: audit, card: card, repo: repo)

    case .analysisFinished(let analysisID, let repo, let proposalCount):
        return BoardNotification(
            identifier: "analysis.\(analysisID.uuidString)",
            threadIdentifier: identifier(for: repo),
            category: .analysisReady,
            title: repo.nameWithOwner,
            // Zero is a finding, not silence. An analysis that quietly posted
            // nothing is indistinguishable from one that crashed.
            body: proposalCount == 0
                ? "Analysis finished and proposed nothing."
                : "Analysis finished — \(proposalCount) proposal\(proposalCount == 1 ? "" : "s") to review.",
            playsSound: false,
            cardID: nil,
            repoID: repo.id
        )
    }
}

private func finishedNotification(run: SkillRun, card: Card, repo: Repo) -> BoardNotification? {
    // Exhaustive, with no `default:`, so a new `RunState` is a compile error
    // here rather than a state that silently notifies nobody.
    switch run.state {
    case .queued, .running, .cancelling, .stalled:
        // Not a finish. `.stalled` has its own event, and reaching this case
        // means a caller mislabelled one.
        return nil

    case .cancelled:
        // You cancelled it. Telling you that you did is the definition of noise.
        return nil

    case .failed, .timedOut, .completedWithDenials:
        return BoardNotification(
            identifier: identifier(for: card),
            threadIdentifier: identifier(for: repo),
            category: .needsYou,
            title: repo.nameWithOwner,
            body: "\(card.displayTitle) — \(failureText(run.state)).",
            playsSound: true,
            cardID: card.id,
            repoID: repo.id
        )

    case .succeeded:
        return BoardNotification(
            identifier: identifier(for: card),
            threadIdentifier: identifier(for: repo),
            category: .landed,
            title: repo.nameWithOwner,
            // `receiptText` or an admission — never `run.resultText`.
            body: "\(card.displayTitle) — \(run.verifiedOutcome?.receiptText ?? unverifiedText)",
            playsSound: false,
            cardID: card.id,
            repoID: repo.id
        )
    }
}

private func systemMoveNotification(
    audit: MoveAudit, card: Card, repo: Repo
) -> BoardNotification? {
    // Exhaustive over `MoveOrigin`, with no `default:`. It was
    // `guard case .system … else { return nil }`, and under that shape a new
    // origin falls straight through to silence. Silence is the right answer for
    // a gesture somebody made and watched happen; it is the worst possible
    // answer for a session running with nobody in the room, which is exactly
    // the origin that arrived next.
    let body: String
    switch audit.origin {
    case .userDrag, .mcp:
        // A drag and a `board_move_card` are gestures someone made and watched.
        return nil

    case .autoDev:
        // Named by the column reached rather than by the act, because the acts
        // are already named elsewhere and the thing a reader who walked away
        // wants is how far it got.
        body = "\(prLabel(card)) — an auto-dev session moved it to \(audit.to.displayName)."

    case .system(let reason):
        switch reason {
        case .prBecameReady:
            body = "\(prLabel(card)) is ready — moved to In Review."
        case .prMergedExternally:
            body = "\(prLabel(card)) was merged — moved to Done."
        case .reconciliation, .githubImport:
            // Both happen at launch, with the window in front of you, and
            // describe what was already true rather than something that just
            // happened.
            return nil
        }
    }

    return BoardNotification(
        identifier: identifier(for: card),
        threadIdentifier: identifier(for: repo),
        category: .boardMovedItself,
        title: repo.nameWithOwner,
        body: body,
        playsSound: false,
        cardID: card.id,
        repoID: repo.id
    )
}

// MARK: - Wording

/// What a run that succeeded but verified nothing is allowed to claim.
///
/// Its own constant so a test can assert the body *is* this, rather than
/// asserting the absence of a `resultText` fixture and hoping.
let unverifiedText = "finished, but nothing could be verified."

private func failureText(_ state: RunState) -> String {
    switch state {
    case .failed: "the run failed"
    case .timedOut: "the run timed out"
    case .completedWithDenials: "finished, but was refused a tool"
    case .queued, .running, .cancelling, .stalled, .cancelled, .succeeded:
        // Unreachable from `finishedNotification`, and spelled out rather than
        // defaulted so a new state cannot land here silently.
        "the run needs you"
    }
}

/// A pull request the card knows about, or the card itself when it does not.
private func prLabel(_ card: Card) -> String {
    card.prNumber.map { "PR #\($0)" } ?? card.displayTitle
}

/// Per *card*, not per event: macOS replaces a notification reusing an
/// identifier, so a card that progresses twice leaves one current claim rather
/// than two, one of them stale.
private func identifier(for card: Card) -> String { "card.\(card.id.uuidString)" }
private func identifier(for repo: Repo) -> String { "repo.\(repo.id.uuidString)" }
