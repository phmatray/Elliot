import Foundation

/// One thing that was read about a card, and what it contributed.
///
/// A score with no signals behind it is a number nobody can argue with, which is
/// the wrong property for something that decides where an unattended agent goes
/// next. `CardValue.ranked` carries these so the number can always be taken
/// apart.
public struct Signal: Sendable, Hashable {
    /// Stable, not prose: `"bugs"`, `"small"`, `"grounded"`. These are the same
    /// identifiers the wire already uses, so a sentence built from them does not
    /// have to be translated back.
    public var name: String
    public var weight: Double

    public init(name: String, weight: Double) {
        self.name = name
        self.weight = weight
    }
}

/// What a card is worth to a queue that runs with nobody watching.
///
/// **Not a `Double?`.** An optional invites `?? 0`, and "absence becomes the
/// lowest score" is precisely the failure `CIState.noChecks` exists to prevent
/// one type away. Here it would mean every hand-written and every imported card
/// silently sinking to the bottom of an unattended queue.
///
/// A card that is not `.ranked` is **refused, never ranked low**. A sort has to
/// put an absence somewhere, and both ends are wrong: at the bottom, auto-dev
/// never engages a card a person wrote; at the top, it engages first what
/// nothing has measured.
public enum CardValue: Sendable, Hashable {
    case ranked(score: Double, because: [Signal])
    case ungradeable(because: Grounding)
    case neverAppraised
}

public extension CardValue {
    /// What this card is worth, decided on its own signals and never on its
    /// column.
    ///
    /// `appraisedAt == nil` is asked first, and that ordering is load-bearing:
    /// it is the *third state* — nothing has ever read this card, a different
    /// answer from "it was read and there was nothing to find" — and collapsing
    /// them is exactly what the column exists to prevent. Pinned by the second
    /// case in `nothingReadIsNeverAppraised`.
    ///
    /// The two refusal guards below it, in contrast, **commute**: both return
    /// `.ungradeable(because: grounding)`, so a card that is both uncited and
    /// unstated gets the same answer whichever runs first. What is load-bearing
    /// there is narrower: only `.notCited` triggers the grounding refusal —
    /// `.missing` does not — so a `.grounded` or `.missing` payload on
    /// `.ungradeable` can only mean the effort was the problem. `summary` reads
    /// it that way, and `unstatedEffortIsUngradeable` pins it.
    static func of(_ card: Card) -> CardValue {
        guard card.appraisedAt != nil else { return .neverAppraised }

        let grounding = Grounding.of(evidence: card.evidence ?? [])
        guard grounding != .notCited else { return .ungradeable(because: grounding) }

        let effort = card.effort ?? .unstated
        guard effort != .unstated else { return .ungradeable(because: grounding) }

        let signals = [
            Signal(
                name: card.angle?.rawValue ?? AnalysisAngle.unlensedCode,
                weight: card.angle?.valueWeight ?? AnalysisAngle.unlensedWeight
            ),
            Signal(name: effort.rawValue, weight: effort.valueWeight),
            Signal(name: grounding.code, weight: grounding.valueWeight),
        ]
        // The score *is* the sum of what is listed. A weight that is not in
        // `because` is not in the score either, so the number and its reason
        // cannot drift apart.
        return .ranked(score: signals.reduce(0) { $0 + $1.weight }, because: signals)
    }

    /// The number a sort may use, and `nil` for every answer that is not a rank.
    ///
    /// The only way out of the enum on purpose: a caller that wants to order the
    /// board has to say out loud what it does with an absence, and the answer
    /// this package gives is `CardRanking`.
    var rankable: Double? {
        if case .ranked(let score, _) = self { return score }
        return nil
    }

    /// One sentence, in the vocabulary the board already speaks.
    ///
    /// Here rather than in a view for the usual reason: a sentence written in a
    /// SwiftUI body is a claim nothing can test.
    var summary: String {
        switch self {
        case .ranked(let score, let because):
            return "Ranked \(String(format: "%.2f", score)) on "
                + "\(because.map(\.name).joined(separator: ", "))."
        case .ungradeable(let grounding):
            // See `of(_:)`: the grounding is checked first, so `.grounded` here
            // can only mean the effort was the missing signal.
            switch grounding {
            case .notCited:
                return "Nothing cited a file, so there is no signal to rank this card by."
            case .grounded:
                return "The effort was never stated, so there is no signal to rank this card by."
            case .missing(let count):
                let files = count == 1 ? "one cited file is" : "\(count) cited files are"
                return "The effort was never stated, and \(files) not there."
            }
        case .neverAppraised:
            return "Nothing has measured this card."
        }
    }
}

/// Putting a board in value order — and keeping out of it everything that has no
/// place in one.
///
/// The whole point is the second list. Elsewhere a refusal would be swallowed by
/// a comparator and come back as a position, and a position is an answer this
/// package does not have.
public enum CardRanking {

    /// A card and what value has to say about it, kept together so a caller
    /// cannot sort one and report the other.
    public struct Appraised: Sendable, Hashable {
        public var card: Card
        public var value: CardValue

        public init(card: Card, value: CardValue) {
            self.card = card
            self.value = value
        }
    }

    public struct Ranking: Sendable, Hashable {
        /// Best first. Every element is `.ranked`.
        public var ranked: [Appraised]
        /// In the order they were given, **never** in value order: an absence
        /// has no place in a ranking, at either end.
        public var refused: [Appraised]

        public init(ranked: [Appraised], refused: [Appraised]) {
            self.ranked = ranked
            self.refused = refused
        }
    }

    public static func rank(_ cards: [Card]) -> Ranking {
        var scored: [(score: Double, appraised: Appraised)] = []
        var refused: [Appraised] = []

        for card in cards {
            let value = CardValue.of(card)
            let appraised = Appraised(card: card, value: value)
            // Pattern-matched rather than read through `rankable`, and that is
            // what keeps `?? 0` — "absence is the lowest score" — from ever
            // being written here.
            if case .ranked(let score, _) = value {
                scored.append((score, appraised))
            } else {
                refused.append(appraised)
            }
        }

        // Ties are broken by age and then by id, so the order is total. An
        // unstable sort over equal scores reshuffles the queue between two reads
        // of an unchanged board, which reads as the board changing its mind.
        scored.sort { left, right in
            if left.score != right.score { return left.score > right.score }
            if left.appraised.card.createdAt != right.appraised.card.createdAt {
                return left.appraised.card.createdAt < right.appraised.card.createdAt
            }
            return left.appraised.card.id.uuidString < right.appraised.card.id.uuidString
        }

        return Ranking(ranked: scored.map(\.appraised), refused: refused)
    }
}
