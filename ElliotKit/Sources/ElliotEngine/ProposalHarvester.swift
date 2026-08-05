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

        let existing = await existingTitles(repo: repo)
        let now = Date()
        let proposals = harvest.stories.map { story in
            StoryProposal(
                analysisID: analysis.id,
                runID: run.id,
                repoID: repo.id,
                angle: run.analysisAngle ?? analysis.angles.first ?? .bugs,
                title: story.title.trimmingCharacters(in: .whitespacesAndNewlines),
                story: story.story,
                rationale: story.rationale.trimmingCharacters(in: .whitespacesAndNewlines),
                evidence: resolve(story.evidence, repoPath: repo.path),
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
                dropped: harvest.dropped + ["The proposals could not be saved: \(error.localizedDescription)"]
            )
        }

        return AnalysisRunReport(
            harvestSource: source, kept: proposals.count, dropped: harvest.dropped
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

    // MARK: - Evidence

    /// Resolves each citation against the repository root.
    ///
    /// A missing file does not disqualify a proposal — it marks it, and the
    /// window strikes it through. It is the fastest signal that a story was
    /// invented rather than found.
    private func resolve(_ raw: [String], repoPath: String) -> [Evidence] {
        let root = URL(fileURLWithPath: repoPath).standardizedFileURL
        return raw.compactMap { citation in
            guard let parsed = Evidence.parse(citation) else { return nil }
            let resolved = root.appendingPathComponent(parsed.path).standardizedFileURL
            // A citation must stay inside the repository: "../../etc/passwd"
            // is not evidence about this codebase.
            let inside = resolved.path.hasPrefix(root.path)
            return Evidence(
                path: parsed.path,
                line: parsed.line,
                exists: inside && FileManager.default.fileExists(atPath: resolved.path)
            )
        }
    }

    // MARK: - Duplicates

    private func existingTitles(repo: Repo) async -> [DuplicateHint] {
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
        return hints
    }

    private func hint(for title: String, among candidates: [DuplicateHint]) -> DuplicateHint? {
        let titles = candidates.map { hint -> String in
            switch hint {
            case .card(_, let title): title
            case .issue(_, let title): title
            }
        }
        guard let match = TextSimilarity.bestMatch(for: title, among: titles) else { return nil }
        return candidates[match.index]
    }
}
