import ElliotModel
import SwiftUI

/// What a move would do, in the words of the person about to make it.
///
/// The board's whole claim is that a gesture here has consequences — one drop
/// files an issue, another merges a pull request into a default branch on
/// github.com. That was previously a hover tooltip on a small icon. It is now
/// the column's own caption, and it is read from `evaluateMove`, the same pure
/// function `BoardService` commits with. The board cannot promise one thing and
/// do another.
struct Consequence {
    /// One line, active voice, saying exactly what happens.
    var summary: String
    /// The same act in the present tense, for after the gesture is made.
    ///
    /// A control keeps its name through the whole flow: the column that
    /// promised "Files a GitHub issue." should report "Filing the issue…", not
    /// the generic "Started a run." that named none of the three.
    var running: String
    var tint: Color
    /// Refused moves are stated but not offered.
    var isRefused: Bool
    /// Merging is the only move that cannot be undone from here.
    var isIrreversible: Bool

    init(
        summary: String,
        running: String = "",
        tint: Color,
        isRefused: Bool = false,
        isIrreversible: Bool = false
    ) {
        self.summary = summary
        self.running = running
        self.tint = tint
        self.isRefused = isRefused
        self.isIrreversible = isIrreversible
    }

    /// A move that starts nothing still moves the card — say so rather than
    /// leaving the column blank, which reads as "not allowed".
    static let inert = Consequence(summary: "Moves the card. Nothing runs.", tint: Palette.inert)

    static func of(_ outcome: MoveOutcome) -> Consequence {
        switch outcome {
        case .action(let action):
            switch action {
            case .createIssue:
                Consequence(
                    summary: "Files a GitHub issue.",
                    running: "Filing the issue…",
                    tint: Palette.armed
                )
            case .implementIssue(let issue):
                Consequence(
                    summary: "Implements #\(issue) and opens a pull request.",
                    running: "Implementing #\(issue)…",
                    tint: Palette.armed
                )
            case .mergePR(let pr, _):
                Consequence(
                    summary: "Merges PR \(pr).",
                    running: "Merging PR \(pr)…",
                    tint: Palette.irreversible,
                    isIrreversible: true
                )
            }

        case .needsInput(.followUps(let pr)):
            // Truthful about the extra step rather than hiding it: the sheet
            // appears first, and only then does the merge run.
            Consequence(
                summary: "Asks for follow-ups, then merges PR \(pr).",
                running: "Merging PR \(pr)…",
                tint: Palette.irreversible,
                isIrreversible: true
            )

        case .noAction:
            .inert

        case .blocked(let block):
            Consequence(summary: Self.reason(block), tint: Palette.refused, isRefused: true)
        }
    }

    /// Short enough for a column caption, and always names the gap rather than
    /// the rule. "No issue yet" tells you what to go get; "invalid transition"
    /// does not.
    static func reason(_ block: MoveBlock) -> String {
        switch block {
        case .sameColumn: "Already here."
        case .emptyIdea: "Nothing written down to file yet."
        case .incompleteStory: "Story needs a role, a want and a benefit."
        case .missingIssueNumber: "No issue yet — file it in To Do first."
        case .missingPRNumber: "No pull request yet — implement it first."
        case .repoDisabled: "This repository is switched off in Preflight."
        // Deliberately not the same sentence as `.repoDisabled`. One is a switch
        // the reader threw and un-throws; this is a diagnosis Elliot made and
        // the repair is elsewhere. Collapsing them would send someone to look
        // for a switch that is already on.
        case .repoBlocked: "Preflight is failing here — repair it before moving cards."
        case .runAlreadyInFlight: "A run is already working on this card."
        case .notVerifiedGreen(let reason):
            "Not a verified green — " + Self.notGreenGap(reason)
        case .systemOwnedTransition:
            "Elliot fills this column itself; it is not a move to make from here."
        }
    }

    /// The gap named for each `NotGreenReason`, in the board's own words.
    ///
    /// Written separately from `MoveBlockText`'s wire phrasing on purpose —
    /// `RefusalWordingTests.theTwoWordingsStayApart` holds the two apart, and a
    /// shared helper here would collapse them back into one sentence read
    /// twice. The `.sign` case is the one exception: both voices quote
    /// `PRSign.summary` verbatim, because that sentence is already written
    /// once, well, in `ElliotModel` — a second phrasing of it here would be the
    /// second table of sentences this file's own tests refuse.
    private static func notGreenGap(_ reason: NotGreenReason) -> String {
        switch reason {
        case .noReading:
            "nothing has been read about this pull request."
        case .sign(let sign):
            sign.summary
        case .notClean(let state):
            "GitHub does not call this clean (\(state.code))."
        case .noBuildVerdict:
            "everything that passed is an analyser, not a build."
        }
    }
}

extension MoveOrigin {
    /// Who put the card here, when the answer is "not you".
    ///
    /// In Review is the only column Elliot fills by itself, and a card that
    /// appeared there explained nothing about how it arrived. Display copy, not
    /// a rule: the decision was `PRWatcher`'s and is already recorded.
    ///
    /// Exhaustive since auto-dev. The old `guard case .system` would have
    /// swallowed the new case and left a card that an unattended session moved
    /// explaining nothing at all about how it got there — which is the one
    /// column caption a reader who was not in the room actually needs.
    var arrivalNote: String? {
        switch self {
        case .userDrag, .mcp:
            return nil
        case .autoDev:
            return "Elliot moved this here — an unattended session is advancing this card."
        case .system(let reason):
            switch reason {
            case .prBecameReady: return "Elliot moved this here — the pull request went ready."
            case .prMergedExternally: return "Elliot moved this here — it was merged on GitHub."
            case .reconciliation: return "Elliot moved this here — recovered after a restart."
            case .githubImport: return "Elliot placed this here — imported from GitHub."
            }
        }
    }

    /// One field of a history row: a fragment, never a sentence.
    ///
    /// A **different function** from `arrivalNote`, returning a **different
    /// register**, and that is the whole of criterion 4 in #101. The header
    /// keeps saying "Elliot moved this here — the pull request went ready."; the
    /// row says "Elliot: the pull request went ready" as one column of a
    /// tabular line. Nothing is said twice because the two never produce the
    /// same words — asserted in `MoveHistoryTests`, in both substring
    /// directions, rather than left to whoever edits this next.
    ///
    /// Dropping the newest audit from the list would have been the other way to
    /// satisfy "not repeated", and it would have produced a history whose most
    /// recent entry is missing: a history that lies, for a cosmetic reason.
    var historyLabel: String {
        switch self {
        case .userDrag:
            return "Dragged"
        case .mcp(let client):
            // Before #101 this was always the literal "mcp"; an empty name is
            // still reachable from an older row, and must not leave a dangling
            // separator pointing at nothing.
            return client.isEmpty ? "MCP" : "MCP · \(client)"
        case .autoDev:
            // The session id is deliberately not rendered: this is one column of
            // a tabular line, and a UUID there would push the rest off the
            // panel. PR5's report band is where a session is named.
            return "Auto-dev"
        case .system(let reason):
            return "Elliot: \(reason.historyPhrase)"
        }
    }
}

extension MoveOrigin.SystemReason {
    /// The reason as a fragment, to sit after "Elliot:" in a history row.
    ///
    /// No `default:` — a fifth reason must fail to compile here rather than
    /// reach the panel as a blank field. That is the real guard on totality;
    /// the list in `MoveHistoryTests` is only its witness.
    var historyPhrase: String {
        switch self {
        case .prBecameReady: "the pull request went ready"
        case .prMergedExternally: "merged on GitHub"
        case .reconciliation: "recovered after a restart"
        case .githubImport: "imported from GitHub"
        }
    }
}

extension ElliotModel.Column {
    /// The column's standing rule, shown when no card is selected. Describes
    /// the column rather than any particular card.
    var standingRule: String {
        switch self {
        case .backlog: "Stories wait here. Nothing runs."
        case .todo: "Arriving files a GitHub issue."
        case .inProgress: "Arriving implements the issue and opens a pull request."
        case .inReview: "Elliot moves cards here itself when the pull request goes ready."
        case .done: "Arriving merges the pull request."
        }
    }

    /// What arriving costs, at rest. Not a left-to-right gradient: In Review
    /// fires nothing, and colouring it as a step up from In Progress would be
    /// prettier and untrue.
    var railTint: Color {
        switch self {
        case .backlog, .inReview: Palette.inert
        case .todo, .inProgress: Palette.armed
        case .done: Palette.irreversible
        }
    }

    /// Whether arriving here can start an agent or merge a pull request.
    var isConsequential: Bool {
        switch self {
        case .backlog, .inReview: false
        case .todo, .inProgress, .done: true
        }
    }
}

extension RunState {
    var tint: Color {
        switch self {
        case .succeeded: Palette.verified
        case .failed, .timedOut: Palette.refused
        case .completedWithDenials, .stalled: Palette.attention
        case .cancelled: Palette.inert
        case .queued, .running, .cancelling: Palette.armed
        }
    }

    var icon: String {
        switch self {
        case .queued: "clock"
        case .running: "play.circle"
        case .cancelling: "stop.circle"
        case .stalled: "hourglass"
        case .succeeded: "checkmark.circle.fill"
        case .completedWithDenials: "exclamationmark.circle.fill"
        case .failed, .timedOut: "xmark.circle.fill"
        case .cancelled: "minus.circle"
        }
    }

    /// Sentence case, and phrased as what happened rather than a state name.
    ///
    /// `succeeded` says "finished without errors" rather than "Succeeded"
    /// because that is all the process told us. In `RunBox` this label sits
    /// directly above the verdict block, whose `gh` side may well read "Not
    /// merged —
    /// …": a clean exit and a successful outcome are exactly the two things
    /// this app refuses to conflate.
    var label: String {
        switch self {
        case .queued: "Queued"
        case .running: "Running"
        case .cancelling: "Cancelling"
        case .stalled: "No output"
        case .succeeded: "Finished without errors"
        case .completedWithDenials: "Finished, tools refused"
        case .failed: "Failed"
        case .cancelled: "Cancelled"
        case .timedOut: "Timed out"
        }
    }
}

extension VerifiedOutcome {
    /// What `gh` established, as opposed to what the agent said about itself.
    /// This is the app's whole epistemology, and until now it was stored and
    /// never shown.
    ///
    /// The wording is `ElliotModel`'s `receiptText`, not a second copy of it:
    /// the verdict block reads the same sentence through `RunVerdict.ghSays`,
    /// and one wording that two places render is the point. Only the tint and
    /// the icon are decided here, because only they need SwiftUI.
    var receipt: (text: String, tint: Color, icon: String) {
        switch self {
        case .issueCreated, .prOpen, .merged:
            (receiptText, Palette.verified, "checkmark.seal.fill")
        case .noIssueCreated:
            (receiptText, Palette.inert, "equal.circle")
        case .notMerged, .closedUnmerged:
            (receiptText, Palette.refused, "xmark.seal.fill")
        case .unverified:
            (receiptText, Palette.attention, "questionmark.circle.fill")
        }
    }
}

extension PRSign {
    /// The same arrangement as `VerifiedOutcome.receipt` above, and for the same
    /// reason: the *sentence* is `ElliotModel`'s `summary`, shared by the card's
    /// tooltip and the panel's headline, and only the tint and the glyph are
    /// decided here, because only they need SwiftUI.
    ///
    /// `.unknown` is drawn in the questioning face rather than a warning one. It
    /// is not bad news — it is the absence of news, and dressing it as a problem
    /// would make every freshly-seen pull request look broken for one tick.
    var tint: Color {
        switch self {
        case .conflict, .checksFailing: Palette.refused
        case .changesRequested, .reviewRequired, .mergeBlocked: Palette.attention
        case .checksRunning: Palette.inert
        // Nothing has judged this pull request. Not a failure, but not something
        // to draw quietly either — it is the state the board exists to surface.
        case .noBuild: Palette.attention
        case .unknown: Palette.quiet
        }
    }

    var icon: String {
        switch self {
        case .conflict: "arrow.trianglehead.branch"
        case .checksFailing: "xmark.octagon.fill"
        case .changesRequested: "bubble.left.and.exclamationmark.bubble.right.fill"
        case .reviewRequired: "person.crop.circle.badge.clock.fill"
        case .mergeBlocked: "lock.fill"
        case .checksRunning: "clock.fill"
        case .noBuild: "questionmark.square.dashed"
        case .unknown: "questionmark.circle"
        }
    }
}
