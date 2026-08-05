import ElliotModel
import Foundation
import MCP
import Testing

@testable import ElliotIPC
@testable import ElliotMCPKit

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
        // Foundation's JSONEncoder does not promise a stable key order
        // between two calls, so a byte-for-byte comparison of two separate
        // encodes is not a safe assertion — `ElliotRequest` is Equatable
        // precisely so this can compare values instead.
        #expect(back.body == request)
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

@Suite("Analysis MCP tools")
struct AnalysisMCPToolTests {

    private func tool(_ name: String) -> MCP.Tool? {
        ElliotMCPServer.tools.first { $0.name == name }
    }

    @Test("The four analysis tools are declared", arguments: [
        "board_analyze_repo", "board_list_proposals",
        "board_accept_proposals", "board_reject_proposals",
    ])
    func toolsExist(name: String) {
        #expect(tool(name) != nil)
    }

    @Test("Only listing proposals is a read")
    func readOnlyHints() {
        #expect(tool("board_list_proposals")?.annotations.readOnlyHint == true)
        #expect(tool("board_analyze_repo")?.annotations.readOnlyHint == false)
        #expect(tool("board_accept_proposals")?.annotations.readOnlyHint == false)
        #expect(tool("board_reject_proposals")?.annotations.readOnlyHint == false)
    }

    /// The descriptions are the only thing an agent reads before acting. Two
    /// facts must be in them or it will guess wrong.
    @Test("The descriptions say an analysis is slow and that accepting files nothing")
    func descriptionsCarryTheTwoFactsThatMatter() throws {
        // Broken into two steps rather than chained: `.lowercased()` right
        // after an optional-chain `?.` is ambiguous once GRDB is in scope —
        // `SQLSpecificExpressible.lowercased` is a same-named property, and
        // the type checker picks it over `String.lowercased()`.
        let analyzeDescription = try #require(tool("board_analyze_repo")?.description)
        let analyze = analyzeDescription.lowercased()
        #expect(analyze.contains("minute"))
        #expect(analyze.contains("board_list_runs"))

        let acceptDescription = try #require(tool("board_accept_proposals")?.description)
        let accept = acceptDescription.lowercased()
        #expect(accept.contains("backlog"))
        #expect(accept.contains("github"))
    }

    @Test("The list description says what status it defaults to")
    func listProposalsDescriptionMentionsTheDefaultStatus() throws {
        let listDescription = try #require(tool("board_list_proposals")?.description)
        #expect(listDescription.lowercased().contains("proposed"))
    }

    /// `AnalysisService.reject` discards its per-id claim result, so `decided`
    /// in the response is truthful only for accept. An agent reading the
    /// static description before calling has no other way to learn that.
    @Test("The reject description says decided doesn't mean this call was the one that decided it")
    func rejectDescriptionCarriesTheDecidedCaveat() throws {
        let rejectDescription = try #require(tool("board_reject_proposals")?.description)
        #expect(rejectDescription.lowercased().contains("decided"))
    }

    @Test("Every angle is offered in the schema")
    func schemaEnumeratesAngles() throws {
        let analyze = try #require(tool("board_analyze_repo"))
        let json = try #require(String(data: WireCodec.encoder.encode(analyze.inputSchema), encoding: .utf8))
        for angle in AnalysisAngle.allCases {
            #expect(json.contains(angle.rawValue))
        }
    }

    /// The bug this guards: the offline branch of `board_list_proposals` and
    /// `board_list_cards` used to let an unmatched `repo` silently fall
    /// through to "no filter" rather than fail — returning every repo's rows
    /// in exactly the situation where the caller has the least way to notice.
    @Test("A repo that matches nothing fails loudly, naming what was asked and what is known")
    func repoNotFoundNamesWhatWasAskedAndWhatIsKnown() throws {
        let repos = [
            Repo(path: "/tmp/elliot", nameWithOwner: "phmatray/Elliot", displayName: "Elliot"),
            Repo(path: "/tmp/other", nameWithOwner: "phmatray/Other", displayName: "Other"),
        ]
        let result = ElliotMCPServer.repoNotFound("no/such-repo", in: repos)
        #expect(result.isError == true)

        let content = try #require(result.content.first)
        guard case .text(let text, _, _) = content else {
            Issue.record("Expected a text content block, got \(content)")
            return
        }
        // Decoded, not raw-`contains`ed: JSONEncoder escapes "/" as "\/", which
        // a plain substring check on the wire text would trip over.
        let data = try #require(text.data(using: .utf8))
        let fields = try WireCodec.decoder.decode([String: String].self, from: data)
        #expect(fields["error"] == "repo_not_found")
        #expect(fields["message"]?.contains("no/such-repo") == true)
        #expect(fields["hint"]?.contains("phmatray/Elliot") == true)
        #expect(fields["hint"]?.contains("phmatray/Other") == true)
    }
}
