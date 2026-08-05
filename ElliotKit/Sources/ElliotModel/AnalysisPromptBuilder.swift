import Foundation

/// The prompt Elliot sends to read a repository through one lens.
///
/// Unlike the three lifecycle skills, this is **not** a slash command: there is
/// no `analyze-repo` skill in the plugin. Elliot owns this prompt and versions
/// it, which is why it is here — pure, and covered by tests that assert the one
/// thing the harvest cannot survive being wrong about.
public enum AnalysisPromptBuilder {
    /// How the artifact path is announced. Both the property test and
    /// `Scripts/fake-claude.sh` find the path by this exact marker.
    public static let outputMarker = "ELLIOT_OUTPUT="

    /// Enough context to recognise a duplicate, not so much that the list
    /// crowds out the briefing.
    public static let maxExistingTitles = 80

    public static func prompt(
        angle: AnalysisAngle,
        repoNameWithOwner: String,
        outputPath: String,
        existingTitles: [String],
        maxStories: Int,
        extraInstructions: String = "",
        githubTitlesAvailable: Bool = true
    ) -> String {
        var sections: [String] = []

        sections.append("""
            You are reading the repository \(repoNameWithOwner) for Elliot, a \
            Kanban board that turns proposals into GitHub issues.

            Read the code. Do not modify it: make no edits, no commits, no \
            branches, no formatting runs. The single file below is the only one \
            you may write.
            """)

        sections.append("What to look for:\n\n\(angle.briefing)")

        sections.append("""
            Write your findings as JSON to this exact path, and print nothing \
            else in your reply:

            \(outputMarker)\(outputPath)

            The file must contain a JSON array of at most \(maxStories) objects:

            [
              {
                "title": "Add --json to the preflight CLI",
                "role": "developer",
                "want": "preflight results as machine-readable JSON",
                "benefit": "I can fail a CI job on a broken setup",
                "acceptance_criteria": [
                  "`elliot preflight --json` prints one object per check",
                  "the exit code is non-zero when any check fails"
                ],
                "rationale": "The checks already exist and are only rendered \
            for humans, so this is rendering rather than new logic.",
                "evidence": ["Sources/ElliotEngine/PreflightService.swift:31"],
                "effort": "small"
              }
            ]

            Rules:
            - `role`, `want` and `benefit` are the three parts of a user story. \
            All three are required; a story missing one is discarded.
            - `evidence` must cite at least one real file, as a path relative to \
            the repository root, optionally with a line number after a colon. A \
            story that cites nothing is discarded — it cannot be judged.
            - `effort` is one of small, medium, large.
            - Return fewer than \(maxStories) rather than padding the list.
            """)

        let titles = Array(existingTitles.prefix(maxExistingTitles))
        if !titles.isEmpty {
            var section = """
                Already on the board or already filed — do not propose these again:

                \(titles.map { "- \($0)" }.joined(separator: "\n"))
                """
            if !githubTitlesAvailable {
                // Saying the check was partial is better than letting the model
                // assume this list is the whole picture.
                section += "\n\nGitHub could not be reached, so this list covers "
                    + "the board only and may be missing open issues."
            }
            sections.append(section)
        } else if !githubTitlesAvailable {
            sections.append(
                "GitHub could not be reached and the board is empty, so no "
                + "duplicate check was possible."
            )
        }

        let extra = extraInstructions.trimmed()
        if !extra.isEmpty {
            sections.append("Additional instructions from the person asking:\n\n\(extra)")
        }

        return sections.joined(separator: "\n\n")
    }

    /// The artifact path a prompt announces. The runtime counterpart of the
    /// property test, and the same thing the fake `claude` does in shell.
    public static func outputPath(in prompt: String) -> String? {
        guard let range = prompt.range(of: outputMarker) else { return nil }
        let tail = prompt[range.upperBound...].prefix { !$0.isWhitespace }
        return tail.isEmpty ? nil : String(tail)
    }
}
