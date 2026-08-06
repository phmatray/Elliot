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
        case .runAlreadyInFlight: "A run is already working on this card."
        }
    }
}

extension MoveOrigin {
    /// Who put the card here, when the answer is "not you".
    ///
    /// In Review is the only column Elliot fills by itself, and a card that
    /// appeared there explained nothing about how it arrived. Display copy, not
    /// a rule: the decision was `PRWatcher`'s and is already recorded.
    var arrivalNote: String? {
        guard case .system(let reason) = self else { return nil }
        switch reason {
        case .prBecameReady: return "Elliot moved this here — the pull request went ready."
        case .prMergedExternally: return "Elliot moved this here — it was merged on GitHub."
        case .reconciliation: return "Elliot moved this here — recovered after a restart."
        case .githubImport: return "Elliot placed this here — imported from GitHub."
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
