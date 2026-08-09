import Foundation
import Testing

@testable import ElliotModel

@Suite("Value weights")
struct ValueWeightsTests {

    /// The weights are data, in the shape of `AnalysisAngle.briefing`: adding a
    /// lens stays a case and a number, and nothing else in the package branches
    /// on which lens a card came through. A lens with no weight would compile
    /// only if somebody wrote a `default`, which is the thing this shape exists
    /// to make impossible.
    @Test("Every lens carries a weight, and the range is real", arguments: AnalysisAngle.allCases)
    func everyAngleIsWeighted(angle: AnalysisAngle) {
        #expect(angle.valueWeight > 0)
        #expect(angle.valueWeight <= 1)
    }

    @Test("The lenses are not all worth the same, or the weight says nothing")
    func anglesAreDistinguished() {
        let weights = AnalysisAngle.allCases.map(\.valueWeight)
        #expect(Set(weights).count > 1)
    }

    /// A card written by hand carries no lens, and burying it under every
    /// machine-found card is the failure `CardValue.neverAppraised` exists to
    /// prevent, arriving one field over. So the unlensed weight sits strictly
    /// inside the range rather than at the bottom of it.
    @Test("A card that came through no lens is neither promoted nor buried")
    func unlensedSitsInsideTheRange() throws {
        let weights = AnalysisAngle.allCases.map(\.valueWeight)
        let lowest = try #require(weights.min())
        let highest = try #require(weights.max())
        #expect(AnalysisAngle.unlensedWeight > lowest)
        #expect(AnalysisAngle.unlensedWeight < highest)
        #expect(!AnalysisAngle.unlensedCode.isEmpty)
        // Non-empty is not enough. Set `unlensedCode` to `"bugs"` and every
        // other assertion still passes, while a hand-written card becomes
        // indistinguishable from a bugs card **in its own explanation** — the
        // one place the score is supposed to be taken apart.
        #expect(!AnalysisAngle.allCases.map(\.rawValue).contains(AnalysisAngle.unlensedCode))
    }

    /// Cheaper is worth more, and that ordering is the only thing the numbers
    /// themselves have to guarantee.
    @Test("A smaller effort outranks a larger one")
    func effortIsOrdered() {
        #expect(Effort.small.valueWeight > Effort.medium.valueWeight)
        #expect(Effort.medium.valueWeight > Effort.large.valueWeight)
        // Unreachable from `CardValue.of` — an unstated effort is refused, not
        // scored — and zero so that a future caller that scores it anyway gets
        // an obviously wrong answer rather than a plausible one.
        #expect(Effort.unstated.valueWeight == 0)
    }

    @Test("A grounded citation outranks a missing one, and an absent one scores nothing")
    func groundingIsOrdered() {
        #expect(Grounding.grounded.valueWeight > Grounding.missing(count: 1).valueWeight)
        #expect(Grounding.missing(count: 1).valueWeight > 0)
        #expect(Grounding.notCited.valueWeight == 0)
    }
}

private let then = Date(timeIntervalSince1970: 1_700_000_000)

private func appraised(
    id: UUID = UUID(),
    title: String = "Bound the await",
    angle: AnalysisAngle? = .bugs,
    effort: Effort? = .small,
    evidence: [Evidence]? = [Evidence(path: "Sources/A.swift", line: 1, exists: true)],
    appraisedAt: Date? = then,
    createdAt: Date = then
) -> Card {
    Card(
        id: id, repoID: UUID(), title: title, angle: angle,
        columnEnteredAt: createdAt, createdAt: createdAt, updatedAt: createdAt,
        effort: effort, evidence: evidence, appraisedAt: appraisedAt
    )
}

/// Ids the id tie-break can actually be *read* against: `first` sorts below
/// `second` by `uuidString`, so the expected order is a fact rather than a coin
/// toss between two random UUIDs.
private let first = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
private let second = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!

@Suite("Card value")
struct CardValueTests {

    /// The third state, and the reason `appraisedAt` is a column of its own.
    /// Without it, "nobody has ever appraised this card" and "this card was
    /// appraised and had no signal" are the same value.
    @Test("A card nothing has read is never appraised, not a zero")
    func nothingReadIsNeverAppraised() {
        #expect(CardValue.of(appraised(appraisedAt: nil, createdAt: then)) == .neverAppraised)
        // Even when the other two happen to be filled: the timestamp is the one
        // that says a reading happened, and content alone cannot say it.
        let odd = appraised(effort: .small, evidence: [], appraisedAt: nil)
        #expect(CardValue.of(odd) == .neverAppraised)
    }

    /// The verdict is decided on content, never on the column: a card that was
    /// read and cited nothing is refused, and it is refused for the reason it
    /// actually has.
    @Test("A card that cites nothing is ungradeable, not badly ranked")
    func uncitedIsUngradeable() {
        #expect(CardValue.of(appraised(evidence: [])) == .ungradeable(grounding: .notCited))
        #expect(CardValue.of(appraised(evidence: nil)) == .ungradeable(grounding: .notCited))
    }

    /// The other trigger. A `.grounded` payload on an `.ungradeable` can only
    /// mean the effort was the problem, because the grounding was checked first
    /// and was fine — which is what lets one sentence say the truth about two
    /// different causes.
    @Test("A card whose effort was never stated is ungradeable, and says so")
    func unstatedEffortIsUngradeable() {
        let card = appraised(effort: .unstated)
        #expect(CardValue.of(card) == .ungradeable(grounding: .grounded))
        #expect(CardValue.of(card).summary.contains("effort"))
        #expect(CardValue.of(appraised(effort: nil)) == .ungradeable(grounding: .grounded))

        let uncited = appraised(evidence: [])
        #expect(CardValue.of(uncited).summary.contains("cited"))
    }

    /// Citations that do not check out lower the score; they do not disqualify.
    /// A story whose files moved may still be right, and refusing it outright
    /// would make a rename look like an invention.
    @Test("Missing files are ranked lower, not refused")
    func missingFilesAreRankedLower() throws {
        let grounded = appraised()
        let broken = appraised(
            evidence: [Evidence(path: "Sources/Nowhere.swift", line: 9, exists: false)]
        )

        let high = try #require(CardValue.of(grounded).rankable)
        let low = try #require(CardValue.of(broken).rankable)
        #expect(high > low)
    }

    /// The score *is* the sum of what is listed, so the number and its reason
    /// cannot drift: a weight that is not in `because` is not in the score.
    @Test("A ranked card explains its own number")
    func scoreIsTheSumOfItsSignals() throws {
        guard case .ranked(let score, let because) = CardValue.of(appraised()) else {
            Issue.record("a fully appraised card must rank")
            return
        }
        #expect(because.count == 3)
        #expect(abs(score - because.reduce(0) { $0 + $1.weight }) < 0.000_001)
        #expect(because.map(\.name).contains("bugs"))
        #expect(because.map(\.name).contains("small"))
        #expect(because.map(\.name).contains("grounded"))
        #expect(because.allSatisfy { !$0.name.isEmpty })
    }

    @Test("A card with no lens still ranks, under a name of its own")
    func unlensedCardStillRanks() throws {
        guard case .ranked(_, let because) = CardValue.of(appraised(angle: nil)) else {
            Issue.record("a hand-written card that was appraised must still rank")
            return
        }
        #expect(because.map(\.name).contains(AnalysisAngle.unlensedCode))
    }

    /// The one consumed input no other assertion constrains: `scoreIsTheSumOfItsSignals`
    /// checks the sum against `because` and the names, never a number;
    /// `unlensedCardStillRanks` checks only the name `noLens`;
    /// `missingFilesAreRankedLower` varies grounding and `refusalsNeverJoinTheOrder`
    /// varies effort. Replace the lens weight in `of(_:)` with any constant and
    /// every other test in this file still passes — and that weight is the one
    /// that orders eight lenses in a queue nobody is watching.
    @Test("The lens weight actually orders the score, not just its name")
    func lensWeightOrdersTheScore() throws {
        let highLens = appraised(angle: .bugs)
        let lowLens = appraised(angle: .bestPractices)

        let high = try #require(CardValue.of(highLens).rankable)
        let low = try #require(CardValue.of(lowLens).rankable)
        #expect(high > low)
    }

    // MARK: - What may never enter a comparator

    /// The claim this whole type exists for. A sort has to put an absence
    /// *somewhere*, and both places are wrong: at the bottom, auto-dev never
    /// engages a hand-written card; at the top, it engages first what nobody has
    /// measured. So an absence is refused by name and never given a position.
    @Test("Neither ungradeable nor never-appraised carries a number a sort could use")
    func absenceHasNoNumber() {
        #expect(CardValue.neverAppraised.rankable == nil)
        #expect(CardValue.ungradeable(grounding: .notCited).rankable == nil)
        #expect(CardValue.ungradeable(grounding: .grounded).rankable == nil)
        #expect(CardValue.ungradeable(grounding: .missing(count: 2)).rankable == nil)
    }

    @Test("Ranking keeps the refusals out of the order entirely")
    func refusalsNeverJoinTheOrder() {
        let cheap = appraised(title: "Cheap and grounded", effort: .small)
        let dear = appraised(title: "Large and grounded", effort: .large)
        let silent = appraised(title: "Cited nothing", evidence: [])
        let unread = appraised(title: "Never read", appraisedAt: nil)

        let ranking = CardRanking.rank([silent, dear, unread, cheap])

        #expect(ranking.ranked.map(\.card.title) == ["Cheap and grounded", "Large and grounded"])
        #expect(ranking.ranked.allSatisfy { $0.value.rankable != nil })
        #expect(ranking.refused.map(\.card.title) == ["Cited nothing", "Never read"])
        #expect(ranking.refused.allSatisfy { $0.value.rankable == nil })
    }

    /// And the refusals keep the order they were given rather than acquiring one
    /// — which is the difference between "these cannot be ranked" and "these
    /// ranked last".
    @Test("The refused list is the caller's order, never a value order")
    func refusalsAreNotSorted() {
        let silent = appraised(title: "Cited nothing", evidence: [])
        let unread = appraised(title: "Never read", appraisedAt: nil)

        #expect(CardRanking.rank([silent, unread]).refused.map(\.card.title)
            == ["Cited nothing", "Never read"])
        #expect(CardRanking.rank([unread, silent]).refused.map(\.card.title)
            == ["Never read", "Cited nothing"])
    }

    /// Two cards that score the same must come back in the same order every
    /// time. An unstable sort here reshuffles the queue between two reads of an
    /// unchanged board, which reads as the board changing its mind.
    @Test("Equal scores are broken by age, then by id — the order is total")
    func tiesAreBrokenDeterministically() {
        let older = appraised(title: "Older", createdAt: then)
        let newer = appraised(title: "Newer", createdAt: then.addingTimeInterval(60))

        #expect(CardRanking.rank([newer, older]).ranked.map(\.card.title) == ["Older", "Newer"])
        #expect(CardRanking.rank([older, newer]).ranked.map(\.card.title) == ["Older", "Newer"])
    }

    /// And the *last* tie-break, which the test above never reaches: its two
    /// cards have different `createdAt`, so the comparator returns on age and
    /// the id line is never consulted. Replace that line with `return false` and
    /// every other test in this file still passes — while the order of two cards
    /// that are equal on both score and age becomes the order they arrived in,
    /// i.e. whatever the store's query happened to return.
    ///
    /// That is the property the doc comment calls "total": a queue nobody is
    /// watching must engage the same card whichever way the board was read.
    @Test("Cards equal on score and age are still ordered, and by id")
    func identicalAgesAreBrokenById() {
        let low = appraised(id: first, title: "Lower id", createdAt: then)
        let high = appraised(id: second, title: "Higher id", createdAt: then)

        #expect(CardRanking.rank([low, high]).ranked.map(\.card.title) == ["Lower id", "Higher id"])
        #expect(CardRanking.rank([high, low]).ranked.map(\.card.title) == ["Lower id", "Higher id"])
    }

    /// The fifth shape, and the one no other assertion reached: an unstated
    /// effort *and* citations that do not check out. It is ordinary production
    /// code — a story sized by nobody whose files have since moved — and its
    /// sentence has to say both halves.
    ///
    /// The count comes from `grounding.summary` rather than being re-derived
    /// here, so the singular and the plural are one rule. Both are asserted:
    /// a composition that dropped the pluralisation would still contain the
    /// word "cited".
    @Test("An unstated effort with broken citations says both, and counts them once")
    func unstatedEffortWithMissingFilesSaysBoth() {
        func broken(_ count: Int) -> Card {
            appraised(
                effort: .unstated,
                evidence: (1...count).map {
                    Evidence(path: "Sources/Gone\($0).swift", line: $0, exists: false)
                }
            )
        }

        let one = CardValue.of(broken(1))
        #expect(one == .ungradeable(grounding: .missing(count: 1)))
        #expect(one.summary.contains("effort"))
        #expect(one.summary.contains(Grounding.missing(count: 1).summary))
        #expect(one.summary.contains("One cited file is not there."))

        let three = CardValue.of(broken(3))
        #expect(three.summary.contains("3 cited files are not there."))
        #expect(three.summary.hasSuffix("."))
    }

    @Test("Every verdict says one sentence")
    func everyVerdictSpeaks() {
        let sentences = [
            CardValue.of(appraised()).summary,
            CardValue.of(appraised(evidence: [])).summary,
            CardValue.of(appraised(effort: .unstated)).summary,
            CardValue.of(
                appraised(
                    effort: .unstated,
                    evidence: [Evidence(path: "Sources/Gone.swift", line: 9, exists: false)]
                )
            ).summary,
            CardValue.neverAppraised.summary,
        ]
        #expect(sentences.allSatisfy { $0.hasSuffix(".") })
        #expect(Set(sentences).count == 5)
    }
}
