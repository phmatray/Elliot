import ElliotIPC
import ElliotModel
import Foundation
import MCP

/// Starts one `claude -p` run per angle and returns as soon as they are queued.
///
/// A write, so it is never served from the snapshot: a queued run is a process
/// the app has to spawn, and answering "started" from a database Elliot is not
/// reading would be a promise nothing is keeping.
struct AnalyzeRepoTool: BoardTool {
    var tool: Tool {
        Tool(
            name: "board_analyze_repo",
            description: """
                Read a repository through one or more lenses and propose user \
                stories. Each angle is its own `claude -p` run and takes minutes; \
                this returns as soon as the runs are queued. Poll board_list_runs \
                to follow them, then board_list_proposals to read what they found. \
                Proposals are not cards: nothing reaches the board until \
                board_accept_proposals is called.
                """,
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "repo": .object([
                        "type": .string("string"),
                        "description": .string("Repository as owner/name, or an absolute path."),
                    ]),
                    "angles": .object([
                        "type": .string("array"),
                        "items": .object([
                            "type": .string("string"),
                            "enum": .array(AnalysisAngle.allCases.map { .string($0.rawValue) }),
                        ]),
                        "description": .string(
                            "One run per angle. bugs = defects; quickWins = high value for one "
                            + "sitting; features = capabilities the code is asking for; "
                            + "techDebt = structure costing something now; tests = uncovered "
                            + "invariants; docsAndDX = friction a newcomer hits."
                        ),
                    ]),
                    "max_stories": .object([
                        "type": .string("integer"),
                        "description": .string("Cap per angle, 1–30."),
                        "default": .int(8),
                    ]),
                    "instructions": .object([
                        "type": .string("string"),
                        "description": .string(
                            "Extra direction folded into every angle's prompt, e.g. "
                            + "\"concentrate on the process layer\"."
                        ),
                    ]),
                ]),
                "required": .array([.string("repo"), .string("angles")]),
            ]),
            annotations: .init(
                title: "Analyse a repository",
                readOnlyHint: false,
                destructiveHint: false,
                // Starts one unattended `claude -p` run per angle in a real
                // checkout, under the repository's own permission mode. That is
                // the same class of act as board_move_card, and this said
                // `false` until #27 — the tool's own description said "each
                // angle is its own `claude -p` run" on the line above while the
                // annotation claimed a closed world.
                openWorldHint: true
            )
        )
    }

    func call(_ args: [String: Value], bridge: any BridgeProviding) async throws -> CallTool.Result {
        guard let repo = args["repo"]?.stringValue else {
            throw ToolFailure(code: "bad_argument", message: "repo is required.")
        }
        let angles = args["angles"]?.arrayValue?.compactMap(\.stringValue) ?? []
        guard !angles.isEmpty else {
            throw ToolFailure(
                code: "bad_argument",
                message: "angles must list at least one lens.",
                hint: "One of: \(AnalysisAngle.allCases.map(\.rawValue).joined(separator: ", "))."
            )
        }

        let response = await bridge.write(.analyzeRepo(
            repo: repo,
            angles: angles,
            maxStories: try args.integer("max_stories") ?? 8,
            instructions: args["instructions"]?.stringValue ?? ""
        ))
        return try .render(response) { payload in
            guard case .analysisStarted(let analysis) = payload else { return nil }
            return [
                "analysis_id": .string(analysis.id.uuidString),
                "repo": .string(analysis.repo),
                "runs": try Value.encoding(analysis.runs),
                "note": .string(
                    "Each run takes minutes. Poll board_list_runs, then "
                    + "board_list_proposals with this analysis_id."
                ),
            ]
        }
    }
}
