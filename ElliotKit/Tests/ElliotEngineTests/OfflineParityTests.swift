import ElliotIPC
import ElliotModel
import ElliotProcess
import ElliotStore
import Foundation
import TestSupport
import Testing

@testable import ElliotEngine
@testable import ElliotMCPKit

/// The running app and the snapshot, asked the same questions off the same
/// board, answering byte for byte the same.
///
/// This is the assertion the rest of #141 exists to make possible. The two
/// implementations cannot share code — `MCPRequestHandler` lives in
/// `ElliotEngine`, and `ElliotMCPKit` deliberately imports neither it nor
/// `ElliotProcess`, so the helper holds no copy of the rules — but since #141
/// they share a **vocabulary**: both map `ElliotRequest` to `ElliotResponse`.
/// That is enough to drive them from one store and diff the results, which
/// turns "these two must not drift" from a comment into a failing build.
///
/// It has to live in `ElliotEngineTests`, the only target that can see both.
/// The edge is on the test target alone; no source target gained a dependency.
///
/// The comparison is of the **encoded** response, not the enum, because what an
/// agent reads is bytes: two responses that are `==` in Swift but encode
/// differently would still be two different answers to the same question.
@Suite("The live and snapshot answers agree")
struct OfflineParityTests {

    // MARK: - Answers

    @Test("Every read request answers identically, live and from the snapshot")
    func readsAgree() async throws {
        let board = try await ParityBoard.seeded()

        for request in board.readRequests {
            // Both sides resolved before the assertion: an `await` inside
            // `#expect`'s message autoclosure will not compile, and the text is
            // the point — a bare "not equal" on two blobs of JSON says nothing
            // about which field moved.
            let live = await board.liveText(request)
            let snapshot = await board.snapshotText(request)
            #expect(live == snapshot, "\(request) diverged:\n  live: \(live)\n   off: \(snapshot)")
        }
    }

    // MARK: - Refusals

    /// The two refusals every recorded drift was about.
    ///
    /// `board_list_cards` on a repository nobody registered used to read as "no
    /// filter" and answer with the whole board; `board_list_runs` on a card id
    /// nothing matches used to answer an empty page, which tells an agent to
    /// keep polling for something that will never arrive. Both were fixed on the
    /// live side first and taught to the snapshot separately, months later, one
    /// tool at a time — so these are the cases worth holding together rather
    /// than merely holding.
    @Test("An unknown repository is refused in the same words on both sides")
    func unknownRepoRefusalAgrees() async throws {
        let board = try await ParityBoard.seeded()
        let request = ElliotRequest.listCards(repo: "phmatray/Eliot", column: nil, limit: 0)

        let live = await board.handler.handle(request)
        let snapshot = await board.responder.respond(to: request)

        // Named as well as compared: an assertion that only said "equal" would
        // pass just as happily if both sides started answering with the board.
        guard case .failure(let code, let message, let hint) = snapshot else {
            Issue.record("the snapshot did not refuse an unknown repository")
            return
        }
        #expect(code == .repoNotFound)
        #expect(message.contains("phmatray/Eliot"))
        #expect(hint?.contains("phmatray/Elliot") == true)
        #expect(try encoded(live) == encoded(snapshot))
    }

    @Test("A card id nothing matches is refused in the same words on both sides")
    func unknownCardRefusalAgrees() async throws {
        let board = try await ParityBoard.seeded()
        let request = ElliotRequest.listRuns(cardID: UUID(), limit: 0)

        let live = await board.handler.handle(request)
        let snapshot = await board.responder.respond(to: request)

        guard case .failure(let code, _, _) = snapshot else {
            Issue.record("the snapshot answered a page for a card that does not exist")
            return
        }
        #expect(code == .cardNotFound)
        #expect(try encoded(live) == encoded(snapshot))
    }

    // MARK: - The control

    /// Without this the suite above could pass on two implementations that both
    /// answered nothing: every comparison would hold, and every one would be
    /// vacuous. So one answer is read for its content rather than its equality.
    @Test("The board being compared is not empty")
    func theBoardHasSomethingToDisagreeAbout() async throws {
        let board = try await ParityBoard.seeded()

        guard case .ok(.cards(let page)) =
            await board.responder.respond(to: .listCards(repo: nil, column: nil, limit: 0))
        else {
            Issue.record("expected a page of cards")
            return
        }
        #expect(page.total == 4)
        // The held card is the interesting one: `activeRunID` is the field a
        // snapshot that skipped its second query left nil, reporting every held
        // card as movable.
        #expect(page.cards.contains { $0.activeRunID != nil })

        guard case .ok(.next(let next)) =
            await board.responder.respond(to: .next(repo: nil, limit: 0))
        else {
            Issue.record("expected a ranked page")
            return
        }
        #expect(next.items.contains { $0.isReady })
        #expect(next.items.contains { !$0.isReady })
    }
}

// MARK: - One board, two ways of reading it

/// A seeded in-memory board plus both readers of it.
///
/// Deliberately varied: two repositories so a filter has something to exclude,
/// one card per interesting column so `board_next` produces both a ready item
/// and a blocked one, and a run still in flight so `activeRunID` is filled on
/// one card and absent on the others.
private struct ParityBoard {
    var store: BoardStore
    var handler: MCPRequestHandler
    var responder: OfflineResponder
    var cardID: UUID

    static func seeded() async throws -> ParityBoard {
        // `AnalysisService` computes an artifact path through `StoreLocation`
        // even against an in-memory store — the same reason the other suites in
        // this target touch the shared home first.
        _ = TestHome.root
        let store = try BoardStore.inMemory()
        let config = ToolConfig(
            claudePath: "/usr/bin/false", ghPath: "/usr/bin/false",
            gitPath: "/usr/bin/false", environment: [:]
        )
        let launcher = NoLaunch()
        let board = BoardService(store: store, launcher: launcher)
        let analysis = AnalysisService(
            store: store, launcher: launcher, board: board, gh: GHClient(config: config)
        )

        let epoch = Date(timeIntervalSince1970: 1_700_000_000)
        let elliot = Repo(path: "/tmp/elliot", nameWithOwner: "phmatray/Elliot", displayName: "Elliot")
        var koine = Repo(path: "/tmp/koine", nameWithOwner: "Atypical-Consulting/Koine", displayName: "Koine")
        koine.permissionMode = .bypassPermissions
        try await store.saveRepo(elliot)
        try await store.saveRepo(koine)

        func card(
            _ title: String, _ repoID: UUID, _ column: Column, _ order: Double,
            issue: Int? = nil, pr: Int? = nil
        ) -> Card {
            Card(
                repoID: repoID, title: title, column: column, orderIndex: order,
                issueNumber: issue, prNumber: pr,
                columnEnteredAt: epoch, createdAt: epoch, updatedAt: epoch
            )
        }

        // Ready to file · blocked without an issue number · held by a run ·
        // ready to merge. Between them they exercise every branch `board_next`
        // has an opinion about.
        let backlog = card("File me", elliot.id, .backlog, 1024)
        let stuck = card("Stuck", elliot.id, .todo, 2048)
        let held = card("Held", elliot.id, .inProgress, 3072, issue: 12)
        let review = card("Merge me", koine.id, .inReview, 4096, issue: 13, pr: 7)
        for one in [backlog, stuck, held, review] { try await store.saveCard(one) }

        func run(
            _ cardID: UUID, _ repoID: UUID, _ kind: SkillKind, _ state: RunState, _ at: Date
        ) -> SkillRun {
            SkillRun(
                cardID: cardID, repoID: repoID, kind: kind,
                prompt: "/\(kind.skillName)", cwd: "/tmp", state: state, startedAt: at,
                logPath: "/tmp/\(kind.skillName).ndjson", stderrPath: "/tmp/\(kind.skillName).stderr",
                createdAt: at
            )
        }
        try await store.saveRun(run(held.id, elliot.id, .implementIssue, .running, epoch))
        try await store.saveRun(
            run(backlog.id, elliot.id, .createIssue, .succeeded, epoch.addingTimeInterval(1))
        )

        return ParityBoard(
            store: store,
            handler: MCPRequestHandler(store: store, board: board, analysis: analysis),
            responder: OfflineResponder(store: store),
            cardID: held.id
        )
    }

    /// Every read the wire has. Named as a list rather than written out per
    /// test, so a request added to the protocol is one line away from being
    /// compared here too.
    var readRequests: [ElliotRequest] {
        [
            .listRepos,
            .listCards(repo: nil, column: nil, limit: 0),
            .listCards(repo: "phmatray/Elliot", column: .inProgress, limit: 0),
            .listCards(repo: nil, column: nil, limit: 2),
            .getCard(id: cardID),
            .listRuns(cardID: nil, limit: 0),
            .listRuns(cardID: cardID, limit: 0),
            .next(repo: nil, limit: 0),
            .next(repo: "phmatray/Elliot", limit: 1),
            .listProposals(analysisID: nil, repo: "phmatray/Elliot", status: nil, limit: 100),
        ]
    }

    func live(_ request: ElliotRequest) async -> Data? {
        try? encoded(await handler.handle(request))
    }

    func snapshot(_ request: ElliotRequest) async -> Data? {
        try? encoded(await responder.respond(to: request))
    }

    func liveText(_ request: ElliotRequest) async -> String {
        String(decoding: await live(request) ?? Data(), as: UTF8.self)
    }

    func snapshotText(_ request: ElliotRequest) async -> String {
        String(decoding: await snapshot(request) ?? Data(), as: UTF8.self)
    }
}

/// `BoardService` needs a launcher; nothing here starts a run.
private actor NoLaunch: RunLaunching {
    func launch(runID: UUID) async {}
    func cancel(runID: UUID) async {}
}

/// `WireCodec`'s date strategy — the one that decides what an agent reads — plus
/// `.sortedKeys`, which decides nothing.
///
/// ⚠️ `WireCodec.encoder` itself cannot be used for a byte comparison, and the
/// first version of this suite tried. `JSONEncoder` does **not** emit a keyed
/// container in declaration order: it writes through an unordered dictionary, so
/// two encodes of structurally identical values in the same process can differ
/// in key order. Measured: of the ten reads below, seven happened to agree and
/// three did not — `listRepos` and both `next` requests — with every key and
/// every value identical and only the order apart. Comparing that is measuring
/// the encoder's hashing, and it would have failed intermittently forever while
/// reading like a real divergence.
///
/// Canonicalising is not weakening the assertion. JSON object order carries no
/// meaning, no agent reads it, and a key present on one side and absent on the
/// other — or holding a different value — still fails. What is dropped is only
/// the part of the rendering that was never about the answer.
private let canonical: JSONEncoder = {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.sortedKeys]
    return encoder
}()

private func encoded(_ response: ElliotResponse) throws -> Data {
    try canonical.encode(response)
}
