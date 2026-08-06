import ElliotIPC
import ElliotModel
import Foundation
import MCP
import Testing

@testable import ElliotMCPKit

/// What the tool boundary promises before any board is consulted: the names it
/// answers to, the arguments it accepts, and what it tells a client each tool
/// will do to the world.
@Suite("MCP tool surface")
struct ToolSurfaceTests {

    private func tool(_ name: String) throws -> Tool {
        try #require(ElliotMCPServer.tools.first { $0.name == name })
    }

    // MARK: - Dispatch

    @Test("A tool nobody implements is refused, not thrown")
    func unknownToolIsRefused() async throws {
        let answer = try await call(ElliotMCPServer(bridge: StubBridge()), "board_delete_everything")

        #expect(answer.isError)
        #expect(answer.error == "unknown_tool")
        #expect(answer.message.contains("board_delete_everything"))
    }

    @Test("Every advertised tool is one the server actually dispatches")
    func everyToolDispatches() async throws {
        // A tool listed but not routed answers `unknown_tool`, which a model
        // reads as "this server is broken" — and nothing else would catch a
        // name misspelled in exactly one of the two places.
        for tool in ElliotMCPServer.tools {
            let answer = try await call(ElliotMCPServer(bridge: StubBridge()), tool.name)
            #expect(answer.error != "unknown_tool", "\(tool.name) is advertised but not dispatched")
        }
    }

    @Test("No two tools claim the same name")
    func toolNamesAreUnique() {
        // The dispatch table is a `Dictionary(uniqueKeysWithValues:)` over these
        // very names, so a duplicate traps rather than shadowing a tool into
        // unreachability — but only at the first *use* of that lazily
        // initialised static, which is the first tools/list or tools/call. This
        // is what finds it before then.
        //
        // `BoardTool.name` is a protocol *extension* returning `tool.name`, not
        // a requirement a conformance can answer its own way, so these are
        // exactly the keys that dictionary is built from.
        let names = ElliotMCPServer.tools.map(\.name)
        // A registry that emptied out would satisfy the line below vacuously.
        #expect(!names.isEmpty)
        #expect(Set(names).count == names.count, "duplicate tool name among \(names.sorted())")
    }

    // MARK: - Arguments
    //
    // An argument the caller sent but spelled wrong must come back as a
    // refusal. Answered with a default it becomes a plausible-looking answer to
    // a question nobody asked, which is the same defect as a silent truncation.

    @Test("A card id that is not a UUID is refused as a bad argument")
    func nonUUIDCardID() async throws {
        let answer = try await call(
            ElliotMCPServer(bridge: StubBridge()),
            "board_get_card",
            ["card_id": .string("the-one-about-logs")]
        )

        #expect(answer.isError)
        #expect(answer.error == "bad_argument")
        #expect(answer.message.contains("card_id"))
    }

    @Test("A required argument that was left out is named")
    func missingRequiredArgument() async throws {
        let answer = try await call(
            ElliotMCPServer(bridge: StubBridge()),
            "board_create_card",
            ["title": .string("Stream the run log")]
        )

        #expect(answer.isError)
        #expect(answer.error == "bad_argument")
        #expect(answer.message.contains("repo"))
    }

    @Test("A column that is not on the board is refused with the five that are")
    func unknownMoveTarget() async throws {
        let answer = try await call(
            ElliotMCPServer(bridge: StubBridge()),
            "board_move_card",
            ["card_id": .string(UUID().uuidString), "to": .string("shipped")]
        )

        #expect(answer.isError)
        #expect(answer.error == "bad_argument")
        #expect(answer.message.contains("inReview"))
    }

    @Test("A misspelled column filter is refused, not widened to the whole board")
    func unknownColumnFilter() async throws {
        let bridge = StubBridge(onRead: { _ in
            .live(.ok(.cards(CardPage(cards: [], total: 0, limit: 100))))
        })

        let answer = try await call(
            ElliotMCPServer(bridge: bridge),
            "board_list_cards",
            ["column": .string("in-progress")]
        )

        #expect(answer.isError)
        #expect(answer.error == "bad_argument")
        #expect(answer.message.contains("inProgress"))
        // The refusal has to happen before the board is asked: a request that
        // reached the app with no column filter would come back as a page of
        // everything, which is what the caller must not be handed.
        #expect(answer["cards"] == nil)
    }

    @Test("A column that is not on the board is refused at creation too")
    func unknownColumnOnCreate() async throws {
        let answer = try await call(
            ElliotMCPServer(bridge: StubBridge()),
            "board_create_card",
            [
                "repo": .string("phmatray/Elliot"),
                "title": .string("Stream the run log"),
                "column": .string("Backlog"),
            ]
        )

        #expect(answer.isError)
        #expect(answer.error == "bad_argument")
        // Silently landing in `backlog` would be the same card in a different
        // place from the one the caller asked for, reported as a success.
        #expect(answer["card"] == nil)
    }

    @Test("A wait of zero seconds or less is refused, not read as the default")
    func nonPositiveAwaitTimeout() async throws {
        // `deadline - now` going negative is how a caller arrives here, and
        // clamping it up would answer "still running" forever with nothing
        // naming the argument that was wrong.
        for seconds in [0, -30] {
            let answer = try await call(
                ElliotMCPServer(bridge: StubBridge()),
                "board_await_run",
                ["run_id": .string(UUID().uuidString), "timeout_seconds": .int(seconds)]
            )

            #expect(answer.isError, "\(seconds)")
            #expect(answer.error == "bad_argument", "\(seconds)")
            #expect(answer["run"] == nil, "\(seconds)")
        }
    }

    @Test("A limit that is not a number is refused rather than quietly defaulted")
    func nonNumericLimit() async throws {
        let answer = try await call(
            ElliotMCPServer(bridge: StubBridge()),
            "board_list_cards",
            ["limit": .string("10")]
        )

        #expect(answer.isError)
        #expect(answer.error == "bad_argument")
        #expect(answer.message.contains("limit"))
    }

    @Test("A limit written as a round number is the number it names")
    func integralDoubleLimit() async throws {
        let log = RequestLog()
        let bridge = StubBridge(onRead: { request in
            log.record(request)
            return .live(.ok(.cards(CardPage(cards: [], total: 0, limit: 5))))
        })

        // `5.0` is five. Refusing it would turn a client's JSON number
        // formatting into an error, which is strictness spent on nothing.
        let answer = try await call(
            ElliotMCPServer(bridge: bridge),
            "board_list_cards",
            ["limit": .double(5)]
        )
        #expect(!answer.isError)

        guard case .listCards(_, _, let limit)? = log.last else {
            Issue.record("the helper did not forward a listCards request")
            return
        }
        #expect(limit == 5)
    }

    @Test("The caller's own limit reaches the app unclamped")
    func limitIsNotClampedBeforeTheApp() async throws {
        let log = RequestLog()
        let bridge = StubBridge(onRead: { request in
            log.record(request)
            return .live(.ok(.cards(CardPage(
                cards: [], total: 0, limit: ElliotPaging.cardLimitMax,
                limitCappedFrom: 9999
            ))))
        })

        _ = try await call(ElliotMCPServer(bridge: bridge), "board_list_cards", ["limit": .int(9999)])

        // Clamping here first would hand the app a number that can never exceed
        // its own cap, so `limitCappedFrom` would come back nil every time and
        // the cap would be silent — the defect it exists to close.
        guard case .listCards(_, _, let limit)? = log.last else {
            Issue.record("the helper did not forward a listCards request")
            return
        }
        #expect(limit == 9999)
    }

    // MARK: - Annotations
    //
    // These are what a client shows a human before it lets a model call the
    // tool. Understating them is how a merge to a default branch reads as
    // bookkeeping.

    @Test("board_move_card is annotated destructive and open-world")
    func moveIsAnnotatedHonestly() throws {
        let move = try tool("board_move_card")

        #expect(move.annotations.readOnlyHint == false)
        #expect(move.annotations.destructiveHint == true)
        #expect(move.annotations.openWorldHint == true)
        // A second call is a second move, and can be a second run.
        #expect(move.annotations.idempotentHint == false)
    }

    @Test("board_move_card's description names its blast radius")
    func moveDescribesItsBlastRadius() throws {
        let description = try #require(tool("board_move_card").description)

        #expect(description.contains("bypassPermissions"))
        #expect(description.contains("merge"))
        #expect(description.contains("follow_ups"))
    }

    @Test("Cancelling a run is annotated destructive, because half-done work stays half-done")
    func cancelIsAnnotatedDestructive() throws {
        #expect(try tool("board_cancel_run").annotations.destructiveHint == true)
    }

    @Test("No tool claims to be read-only while going through a write")
    func writesDoNotClaimToBeReadOnly() throws {
        // `board_await_run` writes nothing but travels the write path, which
        // launches Elliot if Elliot is down — starting a GUI process is not a
        // read, whatever the database sees.
        let writes = ["board_create_card", "board_update_card", "board_move_card",
                      "board_await_run", "board_cancel_run"]
        for name in writes {
            #expect(try tool(name).annotations.readOnlyHint == false, "\(name)")
        }

        let reads = ["board_next", "board_list_cards", "board_get_card",
                     "board_list_repos", "board_list_runs"]
        for name in reads {
            #expect(try tool(name).annotations.readOnlyHint == true, "\(name)")
        }
    }

    @Test("Every tool carries a description, since it is the only documentation an agent reads")
    func everyToolIsDocumented() {
        for tool in ElliotMCPServer.tools {
            #expect(tool.description?.isEmpty == false, "\(tool.name) has no description")
            #expect(tool.annotations.title?.isEmpty == false, "\(tool.name) has no title")
        }
    }

    @Test("The server names the build it is, not a literal")
    func serverInstructionsCarryTheBuild() {
        // Asserting `contains(ElliotBuild.version)` would be a tautology — the
        // sentence is built by interpolating that very value — so this asserts
        // what can actually be wrong instead: the literal that used to be there,
        // and a version that names nothing.
        #expect(!ElliotMCPServer.instructions.contains("1.0.0"))
        #expect(!ElliotMCPServer.instructions.contains("unknown"))
        #expect(ElliotMCPServer.instructions.contains("\(elliotProtocolVersion)"))
    }

    @Test("The build always names something, whatever bundle it finds itself in")
    func buildVersionIsNeverNothing() {
        // Whether `Bundle.main` is `Elliot.app`, a bare binary or a test runner
        // is not this suite's business — the four cases are pinned in
        // ElliotIPCTests. What matters here is that the word "unknown", which
        // named nothing at all, never reaches a client again.
        #expect(!ElliotBuild.version.isEmpty)
        #expect(!ElliotBuild.version.contains("unknown"))
    }
}
