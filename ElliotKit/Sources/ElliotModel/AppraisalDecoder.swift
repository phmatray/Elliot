import Foundation

/// Turns whatever an appraisal run wrote into two signals, or into nothing.
///
/// The contract is `ProposalDecoder`'s: **never throws, never drops silently.**
/// What differs is the shape of failure. A proposal that cannot be read costs
/// one story out of twelve, and `ProposalDecoder` falls back to a fenced block
/// in the closing message to save the rest. There is deliberately **no such
/// entry point here**: an appraisal lands in a card field an unattended ranking
/// later sorts on, so prose salvaged from a chat message would become a
/// measurement. Leaving the card unappraised and saying so is the better
/// answer, and it is the only one this type can give.
public enum AppraisalDecoder {

    /// What the run said about one card.
    public struct Appraisal: Sendable, Hashable {
        public var effort: Effort
        /// Raw citations, exactly as written. Resolving them against the
        /// repository — including the containment check — is
        /// `EvidenceResolver`'s job, because that needs a file system and this
        /// stays pure.
        public var evidence: [String]

        public init(effort: Effort, evidence: [String]) {
            self.effort = effort
            self.evidence = evidence
        }
    }

    /// The whole of what an artifact yielded.
    ///
    /// `appraisal` is optional and `Effort` is not: "the run said nothing
    /// usable" and "the run said it could not tell" are different facts, and
    /// collapsing them is the mistake `AnalysisRunReport.workingTreeChanged`
    /// exists one type away to prevent. `.unstated` is the second; `nil` here is
    /// the first.
    public struct Reading: Sendable, Hashable {
        public var appraisal: Appraisal?
        /// Why each discarded thing was discarded. Shown, never swallowed.
        public var dropped: [String]

        public init(appraisal: Appraisal? = nil, dropped: [String] = []) {
            self.appraisal = appraisal
            self.dropped = dropped
        }
    }

    public static func decode(artifact data: Data) -> Reading {
        guard !data.isEmpty else {
            return Reading(dropped: ["The artifact was empty."])
        }
        guard let raw = try? JSONSerialization.jsonObject(with: data) else {
            return Reading(dropped: ["The artifact was not valid JSON."])
        }
        guard let object = raw as? [String: Any] else {
            return Reading(dropped: ["The artifact was not a JSON object."])
        }

        let rawEffort = object["effort"]
        let rawEvidence = object["evidence"]
        guard rawEffort != nil || rawEvidence != nil else {
            return Reading(
                dropped: ["The artifact carried neither an effort nor any evidence."]
            )
        }

        var dropped: [String] = []

        // `Effort.parse`, with no `?? .medium` anywhere near it. Folding silence
        // onto a size is a kindness for a display badge and an invention for an
        // input to an unattended ranking — the joint constraint this file
        // carries, pinned by `AppraisalDecoderTests.unstatedIsNotMedium`.
        let effort = Effort.parse((rawEffort as? String) ?? "")

        var evidence: [String] = []
        switch rawEvidence {
        case nil:
            break
        case let list as [Any]:
            for (index, element) in list.enumerated() {
                guard let citation = element as? String else {
                    dropped.append("Citation \(index + 1) was not a string.")
                    continue
                }
                let trimmed = citation.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else {
                    dropped.append("Citation \(index + 1) was blank.")
                    continue
                }
                evidence.append(trimmed)
            }
        default:
            // The effort survives: one malformed field must not cost the other.
            dropped.append("The evidence was not a list, so it was discarded.")
        }

        return Reading(
            appraisal: Appraisal(effort: effort, evidence: evidence),
            dropped: dropped
        )
    }
}
