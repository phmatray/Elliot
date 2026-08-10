import ElliotModel
import ElliotStore
import Foundation

/// Turns a finished appraisal run into three fields on its card.
///
/// The appraisal counterpart of `Verifier`, and the sibling of
/// `ProposalHarvester` — it answers the same question in a place where `gh`
/// cannot: what did this run actually produce? There is no external authority on
/// how much work a card is, so the artifact is the fact: a file the run was told
/// to write, read from disk.
///
/// ⛔ **The artifact or nothing.** `ProposalHarvester` falls back to a fenced
/// JSON block in the closing message, and that is right for it — a proposal
/// lands in a review queue a person reads. An appraisal lands in a card field an
/// unattended ranking later sorts on, so prose recovered from a chat message
/// would become a measurement with no way to tell it from one. Leaving the card
/// unappraised and saying so in the report is the better answer, and this type
/// has no code path to any other.
public struct AppraisalHarvester: Sendable {
    private let store: BoardStore

    public init(store: BoardStore) {
        self.store = store
    }

    /// Reads the artifact, resolves its citations, and writes the three fields.
    ///
    /// The report is an `AnalysisRunReport` because that is the shape of "what a
    /// read-only run has to say about itself" — where it harvested from, what it
    /// dropped, and the tri-state answer of the git sentinel, which the
    /// scheduler folds in afterwards. Renaming the type or the column would be a
    /// migration; widening what it means is free and true.
    public func harvest(run: SkillRun, repo: Repo, artifactURL: URL) async -> AnalysisRunReport {
        guard let cardID = run.cardID else {
            return AnalysisRunReport(
                harvestSource: .none,
                dropped: ["This appraisal run carries no card, so there is nothing to write to."]
            )
        }

        // Existence is checked before the read, and the read itself uses
        // `do`/`catch` rather than `try?` — for the reason `RunScheduler.start`
        // reads its repo that way (the `do`/`catch` around
        // `store.repo(id: run.repoID)`; this said *"around line 437"*, which is
        // a blank doc line, so the pointer is now the code rather than a
        // number):
        // "no artifact was written" and "the artifact could not be read" are
        // different facts. `try?` would collapse them into one `nil`, and a
        // permissions error or a directory left at the artifact path would be
        // reported as the file simply being absent — the exact swallow
        // Philippe ruled against.
        guard FileManager.default.fileExists(atPath: artifactURL.path) else {
            return AnalysisRunReport(
                harvestSource: .none,
                dropped: ["No artifact was written at \(artifactURL.path)."]
            )
        }

        let data: Data
        do {
            data = try Data(contentsOf: artifactURL)
        } catch {
            return AnalysisRunReport(
                harvestSource: .none,
                dropped: [
                    "The artifact at \(artifactURL.path) could not be read: \(error.localizedDescription)"
                ]
            )
        }

        let reading = AppraisalDecoder.decode(artifact: data)
        guard let appraisal = reading.appraisal else {
            return AnalysisRunReport(
                harvestSource: .none, kept: 0, dropped: reading.dropped
            )
        }

        let evidence = EvidenceResolver.resolve(appraisal.evidence, repoPath: repo.path)

        do {
            // Written even when the run said `.unstated` and cited nothing.
            // `appraisedAt` is the third state: without it, "nobody has read
            // this card" and "this card was read and carries no signal" are the
            // same value, and the ranking one PR over cannot tell the two apart.
            let written = try await store.applyAppraisal(
                cardID: cardID, effort: appraisal.effort, evidence: evidence, at: Date()
            )
            guard written != nil else {
                return AnalysisRunReport(
                    harvestSource: .none, kept: 0,
                    dropped: reading.dropped
                        + ["The card this appraisal belonged to could not be found."]
                )
            }
        } catch {
            return AnalysisRunReport(
                harvestSource: .none, kept: 0,
                dropped: reading.dropped
                    + ["The appraisal could not be saved: \(error.localizedDescription)"]
            )
        }

        return AnalysisRunReport(
            harvestSource: .artifact, kept: 1, dropped: reading.dropped
        )
    }
}
