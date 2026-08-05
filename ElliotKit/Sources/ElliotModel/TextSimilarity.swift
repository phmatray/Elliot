import Foundation

/// How close two short human titles are.
///
/// Used in two places that must agree: recovering an issue by title when a run
/// log yielded no URL, and hinting that a proposed story is already on the
/// board. Two implementations of one heuristic would diverge, and the second
/// one would diverge silently.
public enum TextSimilarity {
    /// The score at and above which two titles are treated as the same thing.
    public static let duplicateThreshold = 0.6

    /// Words worth comparing. Anything three characters or shorter is dropped:
    /// "the", "a", "to" match everything and mean nothing.
    public static func tokens(_ text: String) -> Set<String> {
        Set(
            text.lowercased()
                .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
                .map(String.init)
                .filter { $0.count > 2 }
        )
    }

    /// How much of the wanted vocabulary a candidate covers.
    ///
    /// Deliberately asymmetric: a long candidate that contains every wanted word
    /// scores 1.0. "Add a dark mode toggle to the board" *is* "dark mode toggle".
    public static func overlap(_ wanted: Set<String>, _ candidate: Set<String>) -> Double {
        guard !wanted.isEmpty else { return 0 }
        return Double(wanted.intersection(candidate).count) / Double(wanted.count)
    }

    /// The best candidate above the threshold, or nothing.
    public static func bestMatch(
        for text: String,
        among candidates: [String],
        threshold: Double = duplicateThreshold
    ) -> (index: Int, score: Double)? {
        let wanted = tokens(text)
        guard !wanted.isEmpty else { return nil }
        return candidates
            .enumerated()
            .map { (index: $0.offset, score: overlap(wanted, tokens($0.element))) }
            .filter { $0.score >= threshold }
            .max { $0.score < $1.score }
    }
}
