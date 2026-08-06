import ElliotModel
import Foundation
import MCP
import Testing

@testable import ElliotIPC
@testable import ElliotMCPKit

@Suite("Analysis wire format")
struct AnalysisWireTests {

    /// 4: a run now carries its analysis, its angle and its harvest report.
    /// Additive in JSON, and bumped anyway — a 4 helper meeting a 3 app finds
    /// `workingTreeChanged` absent on every analysis run and reports "the
    /// sentinel never ran". That is a claim about the user's repository,
    /// produced by the age of their app bundle, and refusing the pairing is
    /// what the handshake is for.
    @Test("The protocol version moved, so an old helper fails loudly")
    func versionBumped() {
        #expect(elliotProtocolVersion == 4)
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

    @Test("A report DTO maps every field of the model it comes from")
    func reportMapsModel() {
        let dto = AnalysisReportDTO(AnalysisRunReport(
            harvestSource: .resultText,
            kept: 2,
            dropped: ["story 3: no acceptance criteria"],
            workingTreeChanged: true,
            workingTreeDiff: " M Sources/A.swift"
        ))

        #expect(dto.source == "resultText")
        #expect(dto.kept == 2)
        #expect(dto.dropped == ["story 3: no acceptance criteria"])
        #expect(dto.workingTreeChanged == true)
        #expect(dto.workingTreeDiff == " M Sources/A.swift")
    }

    /// The sentinel is worth nothing if the wire flattens it. `nil` means the
    /// baseline died with the app and nobody looked; `false` means someone
    /// looked and the tree was untouched. An agent that reads the first as the
    /// second reports a repository as clean on no evidence at all.
    @Test("Never-checked and checked-and-clean are different bytes")
    func workingTreeTriStateSurvivesTheCodec() throws {
        let unchecked = AnalysisReportDTO(
            AnalysisRunReport(harvestSource: .artifact, kept: 3, dropped: ["no evidence"])
        )
        let clean = AnalysisReportDTO(
            AnalysisRunReport(harvestSource: .artifact, kept: 3, workingTreeChanged: false)
        )

        #expect(unchecked.workingTreeChanged == nil)
        #expect(clean.workingTreeChanged == false)

        let uncheckedJSON = String(decoding: try WireCodec.encoder.encode(unchecked), as: UTF8.self)
        let cleanJSON = String(decoding: try WireCodec.encoder.encode(clean), as: UTF8.self)
        #expect(!uncheckedJSON.contains("workingTreeChanged"))
        #expect(cleanJSON.contains("\"workingTreeChanged\":false"))

        // And back, so the absence is still an absence on the other side.
        let back = try WireCodec.decoder.decode(
            AnalysisReportDTO.self, from: Data(uncheckedJSON.utf8)
        )
        #expect(back.workingTreeChanged == nil)
        #expect(back == unchecked)
    }

    @Test("A run DTO built from an analysis run says which analysis and which angle")
    func analysisRunIsIdentifiable() throws {
        let analysisID = UUID()
        let run = SkillRun.analysis(
            repoID: UUID(),
            analysisID: analysisID,
            analysisAngle: .techDebt,
            prompt: "read this repository",
            cwd: "/tmp/repo",
            state: .succeeded,
            logPath: "/tmp/run.ndjson",
            stderrPath: "/tmp/run.err",
            analysisReport: AnalysisRunReport(
                harvestSource: .artifact, kept: 4, workingTreeChanged: false
            ),
            createdAt: Date(timeIntervalSince1970: 1_700_000_000)
        )

        let dto = RunDTO(run: run)

        #expect(dto.cardID == nil)
        #expect(dto.analysisID == analysisID)
        #expect(dto.angle == "techDebt")
        #expect(dto.analysisReport?.source == "artifact")
        #expect(dto.analysisReport?.kept == 4)
        #expect(dto.analysisReport?.workingTreeChanged == false)

        // Two readings of one repository are told apart by the angle, so the
        // angle has to still be there on the other side of the socket.
        let line = try WireCodec.encodeLine(Envelope(body: dto))
        let back = try WireCodec.decode(Envelope<RunDTO>.self, from: line.dropLast())
        #expect(back.body == dto)
    }

    @Test("A run DTO built from a card run carries no analysis fields")
    func cardRunHasNoAnalysisFields() {
        let run = SkillRun.card(
            cardID: UUID(),
            repoID: UUID(),
            kind: .createIssue,
            prompt: "/ai-migration-kit:create-issue",
            cwd: "/tmp/repo",
            logPath: "/tmp/run.ndjson",
            stderrPath: "/tmp/run.err",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000)
        )

        let dto = RunDTO(run: run)

        #expect(dto.analysisID == nil)
        #expect(dto.angle == nil)
        #expect(dto.analysisReport == nil)
    }

    /// The memberwise initialiser declared `cardID: UUID` while the property is
    /// `UUID?`, so the one kind of run that has no card could not be built with
    /// it. Nothing called it, which is why nothing caught it.
    @Test("The memberwise initialiser can express an analysis run")
    func memberwiseInitTakesNoCard() {
        let analysisID = UUID()

        let dto = RunDTO(
            id: UUID(),
            cardID: nil,
            analysisID: analysisID,
            angle: "bugs",
            kind: "analyze-repo",
            state: "succeeded",
            isTerminal: true,
            isActive: false,
            prompt: "read this repository",
            logPath: "/tmp/a.ndjson",
            stderrPath: "/tmp/a.err"
        )

        #expect(dto.cardID == nil)
        #expect(dto.analysisID == analysisID)
        #expect(dto.angle == "bugs")
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
        // The refusal every offline branch shares, asserted at its one
        // implementation: a tool reaching for its own lookup instead is exactly
        // how the fall-through came back the first time.
        #expect(throws: ToolFailure.self) {
            try OfflineBoard.filter("no/such-repo", in: repos)
        }
        do {
            _ = try OfflineBoard.filter("no/such-repo", in: repos)
            Issue.record("expected an unknown repository to be refused")
        } catch let failure as ToolFailure {
            #expect(failure.code == "repo_not_found")
            #expect(failure.message.contains("no/such-repo"))
            #expect(failure.hint?.contains("phmatray/Elliot") == true)
            #expect(failure.hint?.contains("phmatray/Other") == true)
        }

        // And a name that does match still resolves, so the guard above is
        // refusing the unknown rather than refusing everything.
        #expect(try OfflineBoard.filter("phmatray/Other", in: repos).repoID == repos[1].id)
        #expect(try OfflineBoard.filter(nil, in: repos).repoID == nil)
    }
}
