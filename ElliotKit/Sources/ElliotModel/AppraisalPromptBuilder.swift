import Foundation

/// The prompt Elliot sends to appraise one card.
///
/// Like the analysis prompt and unlike the three lifecycle skills, this is
/// **not** a slash command: there is no `appraise-cards` skill in any plugin.
/// Elliot owns this text and versions it, which is why it lives here — pure, and
/// covered by tests for the one thing the harvest cannot survive being wrong
/// about.
///
/// It asks for two signals and nothing else. It never asks the run to rank, to
/// compare cards, or to say what should be worked on: that judgement is a pure
/// function over the fields this fills in, and a model ranking here would rank
/// on what it happened to read rather than on what the board knows.
public enum AppraisalPromptBuilder {
    /// Deliberately `AnalysisPromptBuilder`'s marker rather than a second one.
    ///
    /// `AnalysisPromptBuilder.outputPath(in:)` is the parser, and
    /// `Scripts/fake-claude.sh` greps for the same string in shell. A private
    /// marker here would need a second parser, a second grep, and would still
    /// have to hold the same invariant.
    public static var outputMarker: String { AnalysisPromptBuilder.outputMarker }

    /// Enough places to judge the size; few enough that the list reads as
    /// evidence rather than as a directory listing.
    public static let maxEvidence = 5

    /// Builds the prompt for one card.
    ///
    /// - Parameters:
    ///   - cardTitle: What the board shows. May be empty.
    ///   - cardText: The card's own words — `Card.ideaText`, which is the story
    ///     plus its acceptance criteria, or the note for a card that is not a
    ///     story. Assembled by the caller, so this builder holds no second copy
    ///     of that fallback.
    ///   - repoNameWithOwner: Repository identifier, e.g. "phmatray/Elliot".
    ///   - outputPath: Absolute path the artifact is written to; the prompt
    ///     announces this. May contain spaces.
    ///   - maxEvidence: The most citations to ask for.
    public static func prompt(
        cardTitle: String,
        cardText: String,
        repoNameWithOwner: String,
        outputPath: String,
        maxEvidence: Int = AppraisalPromptBuilder.maxEvidence
    ) -> String {
        var sections: [String] = []

        sections.append("""
            You are appraising one card on Elliot's board, for the repository \
            \(repoNameWithOwner).

            Read the code. Do not modify it: make no edits, no commits, no \
            branches, no formatting runs. The single file below is the only one \
            you may write.
            """)

        let title = sanitized(cardTitle)
        let text = sanitized(cardText)
        var card = "The card:"
        if !title.isEmpty { card += "\n\n\(title)" }
        if !text.isEmpty { card += "\n\n\(text)" }
        if title.isEmpty, text.isEmpty {
            // Said out loud rather than left as an empty heading. A run asked to
            // appraise a blank card should answer "unstated", and it can only do
            // that if it knows the blankness is the input rather than a mistake.
            card += "\n\nThis card carries no words. Appraise what you can, and "
                + "say so by answering \"unstated\"."
        }
        sections.append(card)

        sections.append("""
            Answer two questions about it, and nothing else:

            - how much work it is, and
            - which files in this repository that work would touch.

            Write your answer as JSON to this exact path, and print nothing else \
            in your reply:

            \(outputMarker)\(outputPath)

            The file must contain a single JSON object:

            {
              "effort": "small",
              "evidence": [
                "ElliotKit/Sources/ElliotEngine/RunScheduler.swift:212",
                "ElliotKit/Tests/ElliotEngineTests/SchedulerLimitsAdmissionTests.swift"
              ]
            }

            Rules:
            - `effort` is one of small, medium, large, or unstated. Write \
            "unstated" when you cannot tell — do not guess a size. A guess is \
            worse than a gap here: once it is written down, nothing downstream \
            can tell the two apart.
            - `evidence` cites at most \(maxEvidence) real files, as paths \
            relative to the repository root, optionally with a line number after \
            a colon. Cite only files you have opened. An empty list is a valid \
            answer and means you found nothing to point at.
            - Do not rank this card, compare it with anything, or say whether it \
            should be done. You are filling in two facts, not deciding.
            """)

        return sections.joined(separator: "\n\n")
    }

    /// Strips the marker out of anything the reader wrote.
    ///
    /// A card title is user text and can hold anything, including a line copied
    /// out of an earlier prompt. Two markers would make `outputPath(in:)` answer
    /// with the first one it finds, which is not the file the harvester reads.
    private static func sanitized(_ text: String) -> String {
        text.replacingOccurrences(of: outputMarker, with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
