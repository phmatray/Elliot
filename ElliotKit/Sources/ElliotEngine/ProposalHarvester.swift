import ElliotModel
import ElliotProcess
import ElliotStore
import Foundation

/// Turns a finished analysis run into proposals.
///
/// This is the analysis counterpart of `Verifier`, and it answers the same
/// question in a place where `gh` cannot: what did this run actually produce?
/// There is no external authority on whether a story is a good idea, so the
/// artifact is the fact — a file the run was told to write, read from disk,
/// rather than a paragraph read out of its closing message.
public struct ProposalHarvester: Sendable {
    private let store: BoardStore
    private let gh: GHClient

    public init(store: BoardStore, gh: GHClient) {
        self.store = store
        self.gh = gh
    }

    public func harvest(
        run: SkillRun,
        analysis: Analysis,
        repo: Repo,
        artifactURL: URL
    ) async -> AnalysisRunReport {
        let (harvest, source) = read(artifactURL: artifactURL, run: run, cap: analysis.maxStoriesPerAngle)

        guard !harvest.stories.isEmpty else {
            return AnalysisRunReport(harvestSource: source, kept: 0, dropped: harvest.dropped)
        }

        // A run tied to an analysis should always carry the angle it was
        // launched under. If it doesn't, `analysis.angles.first` is a guess —
        // not necessarily the lens this run actually read through — so the
        // guess is recorded rather than let the proposals land under a wrong
        // angle with nothing to say why.
        let angle = run.analysisAngle ?? analysis.angles.first ?? .bugs
        var dropped = harvest.dropped
        if run.analysisAngle == nil {
            dropped.append("Run had no recorded angle; defaulted to \(angle).")
        }

        let existing = await existingTitles(repo: repo, analysisID: analysis.id)
        let now = Date()
        let proposals = harvest.stories.map { story in
            StoryProposal(
                analysisID: analysis.id,
                runID: run.id,
                repoID: repo.id,
                angle: angle,
                title: story.title.trimmingCharacters(in: .whitespacesAndNewlines),
                story: story.story,
                rationale: story.rationale.trimmingCharacters(in: .whitespacesAndNewlines),
                evidence: EvidenceResolver.resolve(story.evidence, repoPath: repo.path),
                effort: Effort.parse(story.effort),
                duplicateOf: hint(for: story.title, among: existing),
                createdAt: now
            )
        }

        do {
            try await store.saveProposals(proposals)
        } catch {
            return AnalysisRunReport(
                harvestSource: source,
                kept: 0,
                dropped: dropped + ["The proposals could not be saved: \(error.localizedDescription)"]
            )
        }

        return AnalysisRunReport(
            harvestSource: source, kept: proposals.count, dropped: dropped
        )
    }

    // MARK: - Reading

    /// The artifact first; the closing message only if there is no artifact to
    /// read. Which one answered is recorded, because "the model wrote the file"
    /// and "the model talked and we salvaged it" are different situations.
    private func read(
        artifactURL: URL, run: SkillRun, cap: Int
    ) -> (ProposalDecoder.Harvest, AnalysisRunReport.HarvestSource) {
        if let data = try? Data(contentsOf: artifactURL), !data.isEmpty {
            let harvest = ProposalDecoder.decode(artifact: data, maxStories: cap)
            if !harvest.stories.isEmpty { return (harvest, .artifact) }

            // The file was there and useless. Try the message, but keep the
            // artifact's complaints so the reader sees both failures.
            let fallback = ProposalDecoder.decode(resultText: run.resultText ?? "", maxStories: cap)
            if !fallback.stories.isEmpty {
                return (
                    ProposalDecoder.Harvest(
                        stories: fallback.stories, dropped: harvest.dropped + fallback.dropped
                    ),
                    .resultText
                )
            }
            return (
                ProposalDecoder.Harvest(dropped: harvest.dropped + fallback.dropped), .none
            )
        }

        let fallback = ProposalDecoder.decode(resultText: run.resultText ?? "", maxStories: cap)
        let dropped = ["No artifact was written at \(artifactURL.path)."] + fallback.dropped
        if fallback.stories.isEmpty {
            return (ProposalDecoder.Harvest(dropped: dropped), .none)
        }
        return (ProposalDecoder.Harvest(stories: fallback.stories, dropped: dropped), .resultText)
    }

    // MARK: - Duplicates

    /// Everything a new story could already be: a card, an open issue, and the
    /// proposals its **sibling lenses** have already landed in this analysis.
    ///
    /// ⚠️ **Order is the tie-break, and it is deliberate.**
    /// `TextSimilarity.bestMatch` keeps the *first* of equally-scoring
    /// candidates, so cards and open issues come before siblings: "this is
    /// already on the board" is a stronger thing to tell the reader than "the
    /// Bugs lens said something similar", and at an equal score they should get
    /// the stronger one.
    private func existingTitles(repo: Repo, analysisID: UUID) async -> [DuplicateHint] {
        var hints: [DuplicateHint] = []
        for card in (try? await store.cards(repoID: repo.id)) ?? [] {
            let title = card.displayTitle
            if !title.isEmpty { hints.append(.card(id: card.id, title: title)) }
        }
        // gh is best-effort here: a duplicate hint is a courtesy, and losing it
        // must not lose the proposals.
        for issue in (try? await gh.issues(repo: repo.nameWithOwner, limit: 100)) ?? []
        where issue.isOpen {
            hints.append(.issue(number: issue.number, title: issue.title))
        }
        // The other lenses of this same analysis. Runs land independently, so
        // this is whatever has been harvested *before* now — which is what
        // makes the hint one-directional and why the label says "already
        // proposed" rather than pairing the two rows (#295).
        //
        // ⛔ **Self-matching is impossible by construction, not by a filter.**
        // This run's own proposals are saved further down `harvest`, after the
        // hints are scored, so they are not in the store yet. Reordering those
        // two steps would make every story a duplicate of itself.
        //
        // Every status, not only `.proposed`: a sibling the reader has already
        // rejected is exactly the case where knowing they have seen this text
        // before is worth most.
        for sibling in (try? await store.proposals(analysisID: analysisID)) ?? []
        where !sibling.title.isEmpty {
            hints.append(
                .proposal(id: sibling.id, title: sibling.title, angle: sibling.angle))
        }
        return hints
    }

    private func hint(for title: String, among candidates: [DuplicateHint]) -> DuplicateHint? {
        let titles = candidates.map { hint -> String in
            switch hint {
            case .card(_, let title): title
            case .issue(_, let title): title
            case .proposal(_, let title, _): title
            }
        }
        guard let match = TextSimilarity.bestMatch(for: title, among: titles) else { return nil }
        return candidates[match.index]
    }
}
