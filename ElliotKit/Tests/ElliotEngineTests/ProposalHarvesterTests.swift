import ElliotModel
import ElliotProcess
import ElliotStore
import Foundation
import Testing

@testable import ElliotEngine

@Suite("Proposal harvester")
struct ProposalHarvesterTests {

    /// A throwaway repository with two real files, so evidence resolution has
    /// something true and something false to distinguish.
    private struct Fixture {
        var store: BoardStore
        var repo: Repo
        var analysis: Analysis
        var run: SkillRun
        var artifactURL: URL
        var root: URL

        func cleanUp() { try? FileManager.default.removeItem(at: root) }
    }

    private func makeFixture() async throws -> Fixture {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("elliot-harvest-\(UUID().uuidString)", isDirectory: true)
        let sources = root.appendingPathComponent("Sources", isDirectory: true)
        try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
        try "// real".write(to: sources.appendingPathComponent("Real.swift"), atomically: true, encoding: .utf8)

        let store = try BoardStore.inMemory()
        let repo = Repo(path: root.path, nameWithOwner: "phmatray/Elliot", displayName: "Elliot")
        try await store.saveRepo(repo)

        let analysis = Analysis(repoID: repo.id, angles: [.bugs], maxStoriesPerAngle: 8, createdAt: Date())
        try await store.saveAnalysis(analysis)

        let run = SkillRun(
            cardID: nil, repoID: repo.id, analysisID: analysis.id, analysisAngle: .bugs,
            kind: .analyzeRepo, prompt: "…", cwd: repo.path,
            logPath: root.appendingPathComponent("run.ndjson").path,
            stderrPath: root.appendingPathComponent("run.log").path,
            createdAt: Date()
        )
        try await store.saveRun(run)

        return Fixture(
            store: store, repo: repo, analysis: analysis, run: run,
            artifactURL: root.appendingPathComponent("stories.json"),
            root: root
        )
    }

    /// `gh` unreachable, so duplicate hints come from the board alone — which is
    /// also the honest default in these tests.
    private func makeHarvester(_ fixture: Fixture) -> ProposalHarvester {
        let config = ToolConfig(
            claudePath: "/usr/bin/false", ghPath: "/usr/bin/false",
            gitPath: "/usr/bin/false", environment: [:]
        )
        return ProposalHarvester(store: fixture.store, gh: GHClient(config: config))
    }

    @Test("A harvested artifact becomes proposals, with evidence resolved")
    func harvestsFromArtifact() async throws {
        let fixture = try await makeFixture()
        defer { fixture.cleanUp() }

        try """
        [
          {"title":"Grounded","role":"dev","want":"w","benefit":"b",
           "evidence":["Sources/Real.swift:3"],"effort":"small"},
          {"title":"Invented","role":"dev","want":"w","benefit":"b",
           "evidence":["Sources/Nowhere.swift:9"],"effort":"large"}
        ]
        """.write(to: fixture.artifactURL, atomically: true, encoding: .utf8)

        let report = await makeHarvester(fixture).harvest(
            run: fixture.run, analysis: fixture.analysis,
            repo: fixture.repo, artifactURL: fixture.artifactURL
        )

        #expect(report.harvestSource == .artifact)
        #expect(report.kept == 2)
        #expect(report.dropped.isEmpty)

        let proposals = try await fixture.store.proposals(analysisID: fixture.analysis.id)
        #expect(proposals.count == 2)

        let grounded = try #require(proposals.first { $0.title == "Grounded" })
        #expect(grounded.isGrounded)
        #expect(grounded.evidence.first?.line == 3)
        #expect(grounded.effort == .small)
        #expect(grounded.angle == .bugs)
        #expect(grounded.runID == fixture.run.id)

        let invented = try #require(proposals.first { $0.title == "Invented" })
        #expect(!invented.isGrounded)
    }

    @Test("With no artifact the closing message is tried, and the source says so")
    func fallsBackToResultText() async throws {
        let fixture = try await makeFixture()
        defer { fixture.cleanUp() }

        var run = fixture.run
        run.resultText = """
            Here is what I found:

            ```json
            [{"title":"From prose","role":"dev","want":"w","benefit":"b",
              "evidence":["Sources/Real.swift"]}]
            ```
            """
        try await fixture.store.saveRun(run)

        let report = await makeHarvester(fixture).harvest(
            run: run, analysis: fixture.analysis,
            repo: fixture.repo, artifactURL: fixture.artifactURL
        )

        #expect(report.harvestSource == .resultText)
        #expect(report.kept == 1)
        let proposals = try await fixture.store.proposals(analysisID: fixture.analysis.id)
        #expect(proposals.map(\.title) == ["From prose"])
    }

    @Test("Nothing anywhere is reported as nothing, not as a crash")
    func nothingHarvested() async throws {
        let fixture = try await makeFixture()
        defer { fixture.cleanUp() }

        let report = await makeHarvester(fixture).harvest(
            run: fixture.run, analysis: fixture.analysis,
            repo: fixture.repo, artifactURL: fixture.artifactURL
        )
        #expect(report.harvestSource == .none)
        #expect(report.kept == 0)
        #expect(!report.dropped.isEmpty)
    }

    @Test("A story that matches a card on the board is flagged, not removed")
    func duplicateOfACardIsHinted() async throws {
        let fixture = try await makeFixture()
        defer { fixture.cleanUp() }

        let existing = Card(
            repoID: fixture.repo.id, title: "Cache the login shell environment",
            columnEnteredAt: Date(), createdAt: Date(), updatedAt: Date()
        )
        try await fixture.store.saveCard(existing)

        try """
        [{"title":"Cache the login shell environment at startup","role":"dev",
          "want":"w","benefit":"b","evidence":["Sources/Real.swift:1"]}]
        """.write(to: fixture.artifactURL, atomically: true, encoding: .utf8)

        _ = await makeHarvester(fixture).harvest(
            run: fixture.run, analysis: fixture.analysis,
            repo: fixture.repo, artifactURL: fixture.artifactURL
        )

        let proposal = try #require(try await fixture.store.proposals(analysisID: fixture.analysis.id).first)
        // Flagged, never dropped: skipping a near-duplicate is the reader's call.
        #expect(proposal.status == .proposed)
        guard case .card(_, let title)? = proposal.duplicateOf else {
            Issue.record("expected a card duplicate hint, got \(String(describing: proposal.duplicateOf))")
            return
        }
        #expect(title == "Cache the login shell environment")
    }

    @Test("Dropped stories keep their reasons in the report")
    func droppedReasonsSurvive() async throws {
        let fixture = try await makeFixture()
        defer { fixture.cleanUp() }

        try """
        [{"title":"No benefit","role":"dev","want":"w","evidence":["Sources/Real.swift:1"]}]
        """.write(to: fixture.artifactURL, atomically: true, encoding: .utf8)

        let report = await makeHarvester(fixture).harvest(
            run: fixture.run, analysis: fixture.analysis,
            repo: fixture.repo, artifactURL: fixture.artifactURL
        )
        #expect(report.kept == 0)
        #expect(report.dropped.contains { $0.contains("benefit") })
    }

    @Test("A citation that escapes via a sibling directory is not treated as inside the repository")
    func evidenceContainmentRejectsSiblingEscape() async throws {
        let fixture = try await makeFixture()
        defer { fixture.cleanUp() }

        // "elliot-harvest-<uuid>-evil" shares `root`'s path as a string
        // *prefix* without being underneath it — exactly the shape a naive
        // `hasPrefix` check would wrongly admit.
        let evilRoot = fixture.root.deletingLastPathComponent()
            .appendingPathComponent("\(fixture.root.lastPathComponent)-evil", isDirectory: true)
        try FileManager.default.createDirectory(at: evilRoot, withIntermediateDirectories: true)
        try "// secret".write(
            to: evilRoot.appendingPathComponent("secret.swift"), atomically: true, encoding: .utf8
        )
        defer { try? FileManager.default.removeItem(at: evilRoot) }

        try """
        [{"title":"Escaping citation","role":"dev","want":"w","benefit":"b",
          "evidence":["../\(fixture.root.lastPathComponent)-evil/secret.swift:1"]}]
        """.write(to: fixture.artifactURL, atomically: true, encoding: .utf8)

        _ = await makeHarvester(fixture).harvest(
            run: fixture.run, analysis: fixture.analysis,
            repo: fixture.repo, artifactURL: fixture.artifactURL
        )

        let proposal = try #require(try await fixture.store.proposals(analysisID: fixture.analysis.id).first)
        let evidence = try #require(proposal.evidence.first)
        // The escaped file genuinely exists — proving the containment check,
        // not a missing-file coincidence, is what marked this ungrounded.
        #expect(FileManager.default.fileExists(atPath: evilRoot.appendingPathComponent("secret.swift").path))
        #expect(evidence.exists == false)
    }

    @Test("A run with no recorded angle still yields proposals, visibly labelled as suspect")
    func missingAngleIsNotedNotHidden() async throws {
        let fixture = try await makeFixture()
        defer { fixture.cleanUp() }

        var run = fixture.run
        run.analysisAngle = nil
        try await fixture.store.saveRun(run)

        try """
        [{"title":"No angle on the run","role":"dev","want":"w","benefit":"b",
          "evidence":["Sources/Real.swift:1"]}]
        """.write(to: fixture.artifactURL, atomically: true, encoding: .utf8)

        let report = await makeHarvester(fixture).harvest(
            run: run, analysis: fixture.analysis,
            repo: fixture.repo, artifactURL: fixture.artifactURL
        )

        #expect(report.kept == 1)
        #expect(report.dropped.contains { $0.contains("no recorded angle") })

        let proposal = try #require(try await fixture.store.proposals(analysisID: fixture.analysis.id).first)
        // Defaulted, not dropped: the proposal still lands, under the
        // analysis's first angle, with the guess recorded above.
        #expect(proposal.angle == fixture.analysis.angles.first)
    }
}
