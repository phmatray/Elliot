import ElliotModel
import Foundation
import Testing

@testable import ElliotIPC

@Suite("Analysis wire format")
struct AnalysisWireTests {

    @Test("The protocol version moved, so an old helper fails loudly")
    func versionBumped() {
        #expect(elliotProtocolVersion == 2)
    }

    @Test("Every new request round-trips through the wire codec", arguments: [
        ElliotRequest.analyzeRepo(
            repo: "phmatray/Elliot", angles: ["bugs", "quickWins"],
            maxStories: 5, instructions: "focus on ElliotProcess"
        ),
        .listProposals(analysisID: UUID(), repo: nil, status: "proposed", limit: 100),
        .listProposals(analysisID: nil, repo: "phmatray/Elliot", status: nil, limit: 20),
        .acceptProposals(ids: [UUID(), UUID()]),
        .rejectProposals(ids: [UUID()]),
    ])
    func requestsRoundTrip(request: ElliotRequest) throws {
        let line = try WireCodec.encodeLine(Envelope(body: request))
        let back = try WireCodec.decode(
            Envelope<ElliotRequest>.self, from: line.dropLast()
        )
        // Re-encoding the decoded value must produce the same bytes: that is
        // the only cheap way to assert an enum with payloads survived intact.
        #expect(try WireCodec.encodeLine(Envelope(id: back.id, body: back.body)) == line)
    }

    @Test("A proposal DTO carries what an agent needs to decide")
    func proposalDTOIsSelfDescribing() throws {
        let proposal = StoryProposal(
            analysisID: UUID(), runID: UUID(), repoID: UUID(), angle: .quickWins,
            title: "Add --json to preflight",
            story: UserStory(
                role: "developer", want: "preflight as JSON",
                benefit: "I can gate CI on it", acceptanceCriteria: ["one object per check"]
            ),
            rationale: "The checks already exist.",
            evidence: [Evidence(path: "Sources/A.swift", line: 3, exists: true)],
            effort: .small,
            duplicateOf: .issue(number: 12, title: "Preflight JSON"),
            createdAt: Date()
        )
        let dto = ProposalDTO(proposal: proposal, repoName: "phmatray/Elliot")
        #expect(dto.angle == "quickWins")
        #expect(dto.effort == "small")
        #expect(dto.status == "proposed")
        #expect(dto.grounded)
        #expect(dto.evidence == ["Sources/A.swift:3"])
        #expect(dto.duplicateHint?.contains("#12") == true)
        #expect(dto.story.narrative.hasPrefix("As a developer"))

        // And it survives the wire.
        let data = try WireCodec.encoder.encode(dto)
        let back = try WireCodec.decoder.decode(ProposalDTO.self, from: data)
        #expect(back == dto)
    }

    @Test("An analysis DTO says what was asked and what is running")
    func analysisDTO() {
        let analysis = Analysis(
            repoID: UUID(), angles: [.bugs, .tests], extraInstructions: "",
            maxStoriesPerAngle: 8, origin: .mcp(client: "claude-code"), createdAt: Date()
        )
        let dto = AnalysisDTO(
            analysis: analysis, repoName: "phmatray/Elliot",
            runs: [AnalysisRunDTO(runID: UUID(), angle: "bugs", state: "queued")]
        )
        #expect(dto.angles == ["bugs", "tests"])
        #expect(dto.runs.count == 1)
        #expect(dto.repo == "phmatray/Elliot")
    }
}
