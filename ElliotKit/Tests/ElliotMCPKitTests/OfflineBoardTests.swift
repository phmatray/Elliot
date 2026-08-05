import ElliotIPC
import ElliotModel
import ElliotStore
import Foundation
import MCP
import Testing

@testable import ElliotMCPKit

/// The snapshot path: what an agent gets when Elliot is not running.
///
/// This is the half of the tool layer that no live machine ever exercises, and
/// the half where every one of its interesting refusals lives.
@Suite("Reading the board from a snapshot")
struct OfflineBoardTests {

    // MARK: - An unknown repository is refused, not widened

    @Test("A repository nobody registered is refused, not answered with the whole board")
    func unknownRepoIsRefused() async throws {
        let elliot = makeRepo("phmatray/Elliot")
        let koine = makeRepo("Atypical-Consulting/Koine")
        let store = try await makeStore(
            repos: [elliot, koine],
            cards: [makeCard(repoID: elliot.id), makeCard(repoID: koine.id)]
        )
        let server = ElliotMCPServer(bridge: StubBridge.snapshot(store))

        let answer = try await call(server, "board_list_cards", ["repo": .string("phmatray/Eliot")])

        #expect(answer.isError)
        #expect(answer.error == ElliotErrorCode.repoNotFound.rawValue)
        // The cards must not be there at all. A page of the whole board under
        // an error flag is still a page of the whole board.
        #expect(answer["cards"] == nil)
        #expect(answer.hint.contains("phmatray/Elliot"))
        #expect(answer.hint.contains("Atypical-Consulting/Koine"))
    }

    @Test("board_next refuses an unknown repository the same way board_list_cards does")
    func unknownRepoIsRefusedByNext() async throws {
        let elliot = makeRepo("phmatray/Elliot")
        let store = try await makeStore(repos: [elliot], cards: [makeCard(repoID: elliot.id)])

        let answer = try await call(
            ElliotMCPServer(bridge: StubBridge.snapshot(store)),
            "board_next",
            ["repo": .string("/Users/phmatray/not/a/checkout")]
        )

        #expect(answer.isError)
        #expect(answer.error == ElliotErrorCode.repoNotFound.rawValue)
        #expect(answer["items"] == nil)
    }

    @Test("No repository filter still means the whole board")
    func noFilterMeansEverything() async throws {
        // The control for the two tests above: "you named one I do not know" and
        // "you named none" are different questions, and only one of them is a
        // refusal. Without this, refusing everything would pass them both.
        let elliot = makeRepo("phmatray/Elliot")
        let koine = makeRepo("Atypical-Consulting/Koine")
        let store = try await makeStore(
            repos: [elliot, koine],
            cards: [makeCard(repoID: elliot.id), makeCard(repoID: koine.id)]
        )

        let answer = try await call(ElliotMCPServer(bridge: StubBridge.snapshot(store)), "board_list_cards")

        #expect(!answer.isError)
        #expect(answer["total"]?.intValue == 2)
        #expect(answer["cards"]?.arrayValue?.count == 2)
    }

    @Test("A repository named by its checkout path is found")
    func repoResolvesByPath() async throws {
        let elliot = makeRepo("phmatray/Elliot", path: "/tmp/elliot-checkout")
        let store = try await makeStore(repos: [elliot], cards: [makeCard(repoID: elliot.id)])

        let answer = try await call(
            ElliotMCPServer(bridge: StubBridge.snapshot(store)),
            "board_list_cards",
            ["repo": .string("/tmp/elliot-checkout")]
        )

        #expect(!answer.isError)
        #expect(answer["cards"]?.arrayValue?.count == 1)
    }

    // MARK: - A cut answer says it was cut

    @Test("An answer cut by the caller's own limit says how much it left out")
    func truncationIsAnnounced() async throws {
        let repo = makeRepo()
        let cards = (0..<5).map {
            makeCard(repoID: repo.id, title: "Card \($0)", orderIndex: Double(1024 * ($0 + 1)))
        }
        let store = try await makeStore(repos: [repo], cards: cards)

        let answer = try await call(
            ElliotMCPServer(bridge: StubBridge.snapshot(store)),
            "board_list_cards",
            ["limit": .int(2)]
        )

        #expect(!answer.isError)
        #expect(answer["cards"]?.arrayValue?.count == 2)
        #expect(answer["total"]?.intValue == 5)
        #expect(answer["truncated"]?.boolValue == true)
        // Said in prose as well as in a flag: a model that reads the note and
        // skips the fields must not conclude it saw the board.
        #expect(answer.note.contains("Showing 2 of 5"))
    }

    @Test("A complete answer does not claim to be cut")
    func completeAnswerIsNotFlagged() async throws {
        let repo = makeRepo()
        let store = try await makeStore(repos: [repo], cards: [makeCard(repoID: repo.id)])

        let answer = try await call(ElliotMCPServer(bridge: StubBridge.snapshot(store)), "board_list_cards")

        #expect(answer["truncated"]?.boolValue == false)
        #expect(!answer.note.contains("left out"))
        #expect(answer["limit_capped_from"] == nil)
    }

    @Test("The server's own cap is announced when it bites")
    func serverCapIsAnnounced() async throws {
        let repo = makeRepo()
        let store = try await makeStore(repos: [repo], cards: [makeCard(repoID: repo.id)])

        let answer = try await call(
            ElliotMCPServer(bridge: StubBridge.snapshot(store)),
            "board_list_cards",
            ["limit": .int(9999)]
        )

        #expect(answer["limit"]?.intValue == ElliotPaging.cardLimitMax)
        #expect(answer["limit_capped_from"]?.intValue == 9999)
        #expect(answer.note.contains("You asked for 9999"))
    }

    @Test("A run page says how many runs it left behind")
    func runTruncationIsAnnounced() async throws {
        let repo = makeRepo()
        let card = makeCard(repoID: repo.id)
        let runs = (0..<4).map {
            makeRun(
                cardID: card.id, repoID: repo.id,
                createdAt: epoch.addingTimeInterval(Double($0))
            )
        }
        let store = try await makeStore(repos: [repo], cards: [card], runs: runs)

        let answer = try await call(
            ElliotMCPServer(bridge: StubBridge.snapshot(store)),
            "board_list_runs",
            ["limit": .int(1)]
        )

        #expect(answer["runs"]?.arrayValue?.count == 1)
        #expect(answer["total"]?.intValue == 4)
        #expect(answer["truncated"]?.boolValue == true)
    }

    // MARK: - A held card reads as held

    @Test("A card a run is holding reports that run from the snapshot")
    func activeRunIsFilledOffline() async throws {
        let repo = makeRepo()
        let held = makeCard(repoID: repo.id, title: "Held", column: .todo, orderIndex: 1024)
        let free = makeCard(repoID: repo.id, title: "Free", column: .todo, orderIndex: 2048)
        let running = makeRun(cardID: held.id, repoID: repo.id, kind: .implementIssue, state: .running)
        // A finished run does not hold anything, and must not be reported as if
        // it did.
        let done = makeRun(cardID: free.id, repoID: repo.id, state: .succeeded)
        let store = try await makeStore(repos: [repo], cards: [held, free], runs: [running, done])

        let answer = try await call(ElliotMCPServer(bridge: StubBridge.snapshot(store)), "board_list_cards")

        let cards = try #require(answer["cards"]?.arrayValue)
        var byTitle: [String: Value] = [:]
        for card in cards { byTitle[card["title"]?.stringValue ?? ""] = card }
        // Absent means "no run holds this card" and nothing else — so a
        // snapshot that skipped the lookup would report every held card as
        // movable, which is the reading this pins shut.
        #expect(byTitle["Held"]?["activeRunID"]?.stringValue == running.id.uuidString)
        #expect(byTitle["Free"]?["activeRunID"] == nil)
    }

    @Test("Fetching one card from the snapshot reports the run holding it")
    func activeRunIsFilledOnGetCard() async throws {
        let repo = makeRepo()
        let card = makeCard(repoID: repo.id, column: .inProgress)
        let running = makeRun(cardID: card.id, repoID: repo.id, kind: .implementIssue, state: .running)
        let store = try await makeStore(repos: [repo], cards: [card], runs: [running])

        let answer = try await call(
            ElliotMCPServer(bridge: StubBridge.snapshot(store)),
            "board_get_card",
            ["card_id": .string(card.id.uuidString)]
        )

        #expect(answer["card"]?["activeRunID"]?.stringValue == running.id.uuidString)
        #expect(answer["card"]?["repo"]?.stringValue == "phmatray/Elliot")
    }

    @Test("A card id that matches nothing is card_not_found, not an empty card")
    func missingCardOffline() async throws {
        let store = try await makeStore(repos: [makeRepo()])

        let answer = try await call(
            ElliotMCPServer(bridge: StubBridge.snapshot(store)),
            "board_get_card",
            ["card_id": .string(UUID().uuidString)]
        )

        #expect(answer.isError)
        #expect(answer.error == ElliotErrorCode.cardNotFound.rawValue)
    }

    // MARK: - What to do next

    @Test("A ready card outranks a blocked one, and the block is named")
    func readyOutranksBlocked() async throws {
        let repo = makeRepo()
        // Ready to merge: furthest along the board.
        let review = makeCard(repoID: repo.id, title: "Merge me", column: .inReview, prNumber: 12)
        // Ready to file an issue: ready, but earlier on the board.
        let backlog = makeCard(repoID: repo.id, title: "File me", column: .backlog)
        // Blocked: a todo card cannot be implemented without an issue number.
        let todo = makeCard(repoID: repo.id, title: "Stuck", column: .todo)
        let store = try await makeStore(repos: [repo], cards: [todo, backlog, review])

        let answer = try await call(ElliotMCPServer(bridge: StubBridge.snapshot(store)), "board_next")

        let items = try #require(answer["items"]?.arrayValue)
        #expect(items.count == 3)
        #expect(answer["ready_count"]?.intValue == 2)

        #expect(items[0]["card"]?["title"]?.stringValue == "Merge me")
        #expect(items[0]["isReady"]?.boolValue == true)
        #expect(items[0]["wouldTrigger"]?.stringValue == "merge-pr")
        #expect(items[0]["nextColumn"]?.stringValue == "done")
        #expect(items[0]["rank"]?.intValue == 1)

        #expect(items[1]["card"]?["title"]?.stringValue == "File me")
        #expect(items[1]["wouldTrigger"]?.stringValue == "create-issue")

        #expect(items[2]["card"]?["title"]?.stringValue == "Stuck")
        #expect(items[2]["isReady"]?.boolValue == false)
        #expect(items[2]["blockCode"]?.stringValue == MoveBlock.missingIssueNumber.code)
        #expect(items[2]["blockHint"]?.stringValue?.contains("backlog") == true)
        #expect(items[2]["rank"]?.intValue == 3)
    }

    @Test("A card ready to merge is one that would merge with no follow-ups filed")
    func inReviewIsReadyWithNoFollowUps() async throws {
        // Evaluated with `providedFollowUps: []` and not nil: nil would report
        // every inReview card as needing input, when board_move_card already
        // defaults follow-ups to none — so the one transition an agent can
        // actually make would read as blocked.
        let repo = makeRepo()
        let card = makeCard(repoID: repo.id, column: .inReview, prNumber: 7)
        let store = try await makeStore(repos: [repo], cards: [card])

        let answer = try await call(ElliotMCPServer(bridge: StubBridge.snapshot(store)), "board_next")

        #expect(answer["items"]?[0]?["isReady"]?.boolValue == true)
        #expect(answer["items"]?[0]?["blockCode"] == nil)
    }

    @Test("A done card is not something to do next")
    func doneCardsAreNotCandidates() async throws {
        let repo = makeRepo()
        let store = try await makeStore(
            repos: [repo],
            cards: [
                makeCard(repoID: repo.id, title: "Shipped", column: .done, prNumber: 3),
                makeCard(repoID: repo.id, title: "Waiting", column: .backlog),
            ]
        )

        let answer = try await call(ElliotMCPServer(bridge: StubBridge.snapshot(store)), "board_next")

        #expect(answer["total"]?.intValue == 1)
        #expect(answer["items"]?.arrayValue?.count == 1)
        #expect(answer["items"]?[0]?["card"]?["title"]?.stringValue == "Waiting")
    }

    @Test("The count of ready work covers the whole board, not just the page returned")
    func readyCountSpansEveryCandidate() async throws {
        // An agent that sees `ready_count: 0` must be able to conclude the
        // board is waiting on something — which it cannot if the number only
        // counts the rows that fitted.
        let repo = makeRepo()
        let cards = (0..<3).map {
            makeCard(repoID: repo.id, title: "Card \($0)", orderIndex: Double(1024 * ($0 + 1)))
        }
        let store = try await makeStore(repos: [repo], cards: cards)

        let answer = try await call(
            ElliotMCPServer(bridge: StubBridge.snapshot(store)),
            "board_next",
            ["limit": .int(1)]
        )

        #expect(answer["items"]?.arrayValue?.count == 1)
        #expect(answer["total"]?.intValue == 3)
        #expect(answer["ready_count"]?.intValue == 3)
        #expect(answer["truncated"]?.boolValue == true)
    }

    @Test("A ranked answer from the running app is put on the wire with the same field names")
    func liveNextIsRenderedTheSameWay() async throws {
        // Only the envelope: the page comes from the app already built, so what
        // this pins is the field names and the note, not the item text. That the
        // two paths *phrase* an item the same way is `NextRenderingTests`, which
        // is where the one renderer they now share lives — the earlier version
        // of this test claimed the wider thing and missed a real divergence.
        let card = CardDTO(id: UUID(), title: "Stuck", column: "todo", repo: "phmatray/Elliot")
        let page = NextPage(
            items: [NextDTO(
                card: card, nextColumn: "inProgress", isReady: false,
                blockCode: MoveBlock.missingIssueNumber.code,
                blockReason: "The card has no issue number.",
                blockHint: "Move it backlog → todo first, which files the issue.",
                rank: 1,
                summary: "\"Stuck\" cannot move to In Progress: the card has no issue number."
            )],
            total: 1, limit: ElliotPaging.nextLimitDefault, readyCount: 0
        )

        let answer = try await call(
            ElliotMCPServer(bridge: StubBridge.answering(.next(page))),
            "board_next"
        )

        #expect(answer.source == "live")
        #expect(answer["ready_count"]?.intValue == 0)
        #expect(answer["items"]?[0]?["blockCode"]?.stringValue == "missing_issue_number")
        #expect(answer["items"]?[0]?["rank"]?.intValue == 1)
        #expect(answer.note.contains("Nothing on the board is ready"))
    }

    @Test("A board with nothing ready says so instead of returning an empty list")
    func nothingReadyIsAnAnswer() async throws {
        let repo = makeRepo()
        let store = try await makeStore(
            repos: [repo],
            cards: [makeCard(repoID: repo.id, title: "Stuck", column: .todo)]
        )

        let answer = try await call(ElliotMCPServer(bridge: StubBridge.snapshot(store)), "board_next")

        #expect(answer["ready_count"]?.intValue == 0)
        #expect(answer["items"]?.arrayValue?.count == 1)
        #expect(answer.note.contains("Nothing on the board is ready"))
    }

    @Test("A card in a disabled repository is blocked, with the repository named as the reason")
    func disabledRepoBlocks() async throws {
        let repo = makeRepo(isEnabled: false)
        let store = try await makeStore(
            repos: [repo],
            cards: [makeCard(repoID: repo.id, column: .backlog)]
        )

        let answer = try await call(ElliotMCPServer(bridge: StubBridge.snapshot(store)), "board_next")

        #expect(answer["items"]?[0]?["blockCode"]?.stringValue == MoveBlock.repoDisabled.code)
        #expect(answer["items"]?[0]?["isReady"]?.boolValue == false)
        #expect(answer["ready_count"]?.intValue == 0)
    }

    @Test("A card a run is already working on cannot be moved, and says which run")
    func runInFlightBlocksNext() async throws {
        let repo = makeRepo()
        let card = makeCard(repoID: repo.id, column: .backlog)
        let running = makeRun(cardID: card.id, repoID: repo.id, state: .running)
        let store = try await makeStore(repos: [repo], cards: [card], runs: [running])

        let answer = try await call(ElliotMCPServer(bridge: StubBridge.snapshot(store)), "board_next")

        let item = try #require(answer["items"]?[0])
        #expect(item["blockCode"]?.stringValue == "run_already_in_flight")
        #expect(item["blockReason"]?.stringValue?.contains(running.id.uuidString) == true)
        #expect(item["card"]?["activeRunID"]?.stringValue == running.id.uuidString)
    }

    // MARK: - Saying which board answered

    @Test("A snapshot answer says it is a snapshot")
    func offlineAnswersSaySo() async throws {
        let repo = makeRepo()
        let store = try await makeStore(repos: [repo], cards: [makeCard(repoID: repo.id)])
        let server = ElliotMCPServer(bridge: StubBridge.snapshot(store))

        for tool in ["board_list_cards", "board_list_repos", "board_next", "board_list_runs"] {
            let answer = try await call(server, tool)
            #expect(answer.source == "offline-db", "\(tool)")
            #expect(answer.note.contains("Elliot is not running"), "\(tool)")
        }
    }

    @Test("A live answer says it came from the running app")
    func liveAnswersSaySo() async throws {
        let bridge = StubBridge.answering(.cards(CardPage(cards: [], total: 0, limit: 100)))

        let answer = try await call(ElliotMCPServer(bridge: bridge), "board_list_cards")

        #expect(answer.source == "live")
        #expect(answer.note.isEmpty)
    }

    @Test("The repositories a snapshot lists carry the permission mode their runs get")
    func reposCarryPermissionMode() async throws {
        var repo = makeRepo()
        repo.permissionMode = .bypassPermissions
        let store = try await makeStore(repos: [repo])

        let answer = try await call(ElliotMCPServer(bridge: StubBridge.snapshot(store)), "board_list_repos")

        #expect(answer["total"]?.intValue == 1)
        // Surfaced because it is what makes moving a card an execution
        // primitive rather than bookkeeping.
        #expect(answer["repos"]?[0]?["permissionMode"]?.stringValue == "bypassPermissions")
        #expect(answer["repos"]?[0]?["nameWithOwner"]?.stringValue == "phmatray/Elliot")
    }

    // MARK: - Writes never touch the snapshot

    @Test("A write is refused when Elliot is down rather than served from the database")
    func writesAreNeverServedOffline() async throws {
        let repo = makeRepo()
        let card = makeCard(repoID: repo.id)
        let store = try await makeStore(repos: [repo], cards: [card])
        let log = RequestLog()
        let bridge = StubBridge(
            isAppRunning: false,
            onRead: { request in
                log.record(request)
                return .offline(store)
            },
            onWrite: { _ in
                .failure(code: .appUnavailable, message: "Elliot is not running.", hint: "Open Elliot.app.")
            }
        )

        let answer = try await call(
            ElliotMCPServer(bridge: bridge),
            "board_move_card",
            ["card_id": .string(card.id.uuidString), "to": .string("todo")]
        )

        #expect(answer.isError)
        #expect(answer.error == ElliotErrorCode.appUnavailable.rawValue)
        // Writing the column straight to SQLite would move the card without
        // firing its rule, which is the bug this architecture exists to
        // prevent. The read side must not even be consulted.
        #expect(log.count == 0)
    }

    // MARK: - Resources

    @Test("A card can be read as a resource from the snapshot")
    func cardResourceOffline() async throws {
        let repo = makeRepo()
        let card = makeCard(repoID: repo.id, title: "Stream the run log")
        let store = try await makeStore(repos: [repo], cards: [card])
        let server = ElliotMCPServer(bridge: StubBridge.snapshot(store))

        let result = try await server.readResource(uri: "elliot://card/\(card.id.uuidString)")

        let content = try #require(result.contents.first)
        #expect(content.mimeType == "application/json")
        let dto = try WireCodec.decoder.decode(CardDTO.self, from: Data((content.text ?? "").utf8))
        #expect(dto.title == "Stream the run log")
        #expect(dto.repo == "phmatray/Elliot")
    }

    @Test("A resource Elliot does not serve is refused with the ones it does")
    func unknownResourceIsRefused() async throws {
        let store = try await makeStore(repos: [makeRepo()])
        let server = ElliotMCPServer(bridge: StubBridge.snapshot(store))

        await #expect(throws: MCPError.self) {
            try await server.readResource(uri: "elliot://board/everything")
        }
    }

    @Test("Listing resources when Elliot refuses is an error, not an empty shelf")
    func listResourcesReportsRefusal() async throws {
        // An empty list is the statement "there are no run logs", which is a
        // different statement from "I could not find out".
        let server = ElliotMCPServer(bridge: StubBridge.refusing(.unauthorized, "bad token"))

        await #expect(throws: MCPError.self) {
            try await server.listResources()
        }
    }

    @Test("Listing resources names one log per run")
    func listResourcesFromSnapshot() async throws {
        let repo = makeRepo()
        let card = makeCard(repoID: repo.id)
        let run = makeRun(cardID: card.id, repoID: repo.id, kind: .mergePR, state: .succeeded)
        let store = try await makeStore(repos: [repo], cards: [card], runs: [run])

        let result = try await ElliotMCPServer(bridge: StubBridge.snapshot(store)).listResources()

        let resource = try #require(result.resources.first)
        #expect(resource.uri == "elliot://run/\(run.id.uuidString)/log")
        #expect(resource.mimeType == "application/x-ndjson")
        // The same vocabulary the rest of the wire uses, not the persisted
        // raw value.
        #expect(resource.title?.contains("merge-pr") == true)
    }
}
