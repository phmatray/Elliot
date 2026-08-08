import Foundation

/// What forgetting a repository destroys, counted.
///
/// `repo` cascades to `card`, `skillRun`, `analysis`, `storyProposal`,
/// `prStatus`, `dismissedExternal` and — through `card` — `moveAudit`. Four of
/// those are work; the rest are readings derived from it. Only the four are
/// counted, and the message covers the others with a clause, because a sentence
/// naming seven kinds is a sentence nobody reads.
public struct ForgetImpact: Codable, Sendable, Hashable {
    public var cards: Int
    public var runs: Int
    public var analyses: Int
    public var proposals: Int

    public init(cards: Int = 0, runs: Int = 0, analyses: Int = 0, proposals: Int = 0) {
        self.cards = cards
        self.runs = runs
        self.analyses = analyses
        self.proposals = proposals
    }

    public var isEmpty: Bool {
        cards == 0 && runs == 0 && analyses == 0 && proposals == 0
    }

    /// "3 cards, 12 runs, 1 analysis and 0 proposals".
    ///
    /// Every kind is named even at zero. Dropping the zeroes reads better and
    /// costs the reader the difference between *none* and *not counted* — the
    /// ambiguity this codebase keeps having to write down elsewhere.
    public var countsSentence: String {
        let parts = [
            Self.count(cards, "card", "cards"),
            Self.count(runs, "run", "runs"),
            Self.count(analyses, "analysis", "analyses"),
            Self.count(proposals, "proposal", "proposals"),
        ]
        return parts.dropLast().joined(separator: ", ") + " and " + parts[parts.count - 1]
    }

    /// Both spellings are given rather than derived: "analysis" + "es" is wrong
    /// and "analysis" + "s" is worse, and a helper that guesses would be a
    /// third place this file has to be right about English.
    private static func count(_ n: Int, _ singular: String, _ plural: String) -> String {
        "\(n) \(n == 1 ? singular : plural)"
    }
}

/// The words both screens show. One value, so the Preflight tooltip and the
/// Repositories tooltip cannot drift apart again.
public struct ForgetPrompt: Sendable, Hashable {
    public let title: String
    public let message: String

    /// The verb, spelled once. Preflight said "Remove" and Repositories said
    /// "Forget" for the same act.
    public static let confirmLabel = "Forget"

    public init(impact: ForgetImpact, displayName: String, path: String) {
        title = "Forget \(displayName)?"
        if impact.isEmpty {
            message = "Elliot holds no cards, runs, analyses or proposals for it, so there is "
                + "nothing to lose. The clone at \(path) is left exactly as it is."
        } else {
            message = "This deletes \(impact.countsSentence), and everything Elliot recorded "
                + "about it. It cannot be undone. The clone at \(path) is left exactly as it is."
        }
    }

    /// Hover text, deliberately without counts: a tooltip fires on hover, and a
    /// database read per hover is a cost nobody asked for. What it must carry is
    /// the consequence the shipped text left out entirely.
    public static func tooltip(displayName: String) -> String {
        "Forget \(displayName) — its cards, runs, analyses and proposals go with it. "
            + "The clone on disk is untouched."
    }
}
