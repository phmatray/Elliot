import Foundation

/// A backlog item in user-story form.
///
/// Kept as three separate fields rather than one blob of prose, because the
/// parts are what make the format useful: they can be validated, rendered
/// consistently into an issue, and — the reason this is structured at all —
/// *generated* from a repository later without having to parse prose back apart.
public struct UserStory: Codable, Sendable, Hashable {
    /// Who the story is for. "developer", "maintainer", "utilisateur"…
    public var role: String
    /// The capability wanted, phrased as an action.
    public var want: String
    /// The outcome that makes the capability worth building.
    public var benefit: String
    /// What has to be true for the story to be considered done.
    public var acceptanceCriteria: [String]

    public init(role: String, want: String, benefit: String, acceptanceCriteria: [String] = []) {
        self.role = role
        self.want = want
        self.benefit = benefit
        self.acceptanceCriteria = acceptanceCriteria
    }

    /// A story is usable once all three parts are filled. Acceptance criteria
    /// are encouraged but not required — `create-issue` derives its own plan.
    public var isComplete: Bool {
        ![role, want, benefit].contains { $0.trimmed().isEmpty }
    }

    /// The story as one sentence: "As a X, I want Y, so that Z."
    ///
    /// English frame regardless of the language of the parts, because it lands
    /// in a GitHub issue alongside English labels, PR titles and commit
    /// conventions. The user's own words are passed through untouched.
    public var narrative: String {
        let r = role.trimmed(), w = want.trimmed(), b = benefit.trimmed()
        guard !r.isEmpty || !w.isEmpty || !b.isEmpty else { return "" }
        var s = "As a \(r), I want \(w)"
        if !b.isEmpty { s += ", so that \(b)" }
        return s.hasSuffix(".") ? s : s + "."
    }

    /// A short board label. Falls back through the parts so a half-written
    /// story still shows something recognisable on the card.
    public var shortTitle: String {
        let w = want.trimmed()
        guard w.isEmpty else { return w.firstCharacterUppercased() }
        let b = benefit.trimmed()
        return b.isEmpty ? role.trimmed() : b.firstCharacterUppercased()
    }

    /// What the card shows under its label.
    ///
    /// Not the narrative: the board label already restates the `want` clause
    /// — `Card.displayTitle` falls back to `shortTitle`, which *is* the want —
    /// so a card that shows the narrative spends both its lines re-reading its
    /// own title through 23 fixed characters of "As a developer, I want …" and
    /// truncates away the benefit, the one clause nothing else on the card
    /// carries. The full narrative stays in the inspector, where there is room
    /// for it.
    public var cardSummary: String {
        let b = benefit.trimmed()
        guard b.isEmpty else { return "So that " + b }
        return want.trimmed().firstCharacterUppercased()
    }

    /// Narrative plus criteria, as the free text `create-issue` reads.
    public var issueBody: String {
        guard !acceptanceCriteria.isEmpty else { return narrative }
        let criteria = acceptanceCriteria
            .map { $0.trimmed() }
            .filter { !$0.isEmpty }
        guard !criteria.isEmpty else { return narrative }
        return narrative + " Acceptance criteria: " + criteria.enumerated()
            .map { "\($0.offset + 1)) \($0.element)" }
            .joined(separator: " ")
    }
}

extension String {
    func trimmed() -> String {
        trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func firstCharacterUppercased() -> String {
        guard let first else { return self }
        return first.uppercased() + dropFirst()
    }
}
