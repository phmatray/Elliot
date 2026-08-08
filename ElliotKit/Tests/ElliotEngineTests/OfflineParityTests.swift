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
            let live = try await board.liveText(request)
            let snapshot = try await board.snapshotText(request)
            #expect(live == snapshot, "\(request) diverged:\n  live: \(live)\n   off: \(snapshot)")
        }
    }

    /// The positive control the equality check cannot be.
    ///
    /// `readsAgree` compares two encoded answers, so **two nils compare equal**:
    /// if neither side carried the pull request reading at all, it would pass
    /// having compared nothing — the same blindness the proposal seeding above
    /// records, one field over. This asserts each side independently carries the
    /// reading, and carries the right one.
    @Test("Both sides actually carry the pull request reading, not a matching nil")
    func prStatusReachesBothAnswers() async throws {
        let board = try await ParityBoard.seeded()
        let request = ElliotRequest.getCard(id: board.reviewCardID)

        let answers = [
            ("live", await board.handler.handle(request)),
            ("snapshot", await board.responder.respond(to: request)),
        ]
        for (side, response) in answers {
            guard case .ok(let payload) = response, case .card(let card) = payload else {
                Issue.record("\(side) did not answer with a card")
                continue
            }
            let status = try #require(card.prStatus, "\(side) carried no pull request reading")
            // The seeded row is DIRTY with a failing check: the conflict wins the
            // sign, and the failure survives on its own facet rather than being
            // swallowed by it.
            #expect(status.sign == "conflict", "\(side)")
            #expect(status.merge == "conflict", "\(side)")
            #expect(status.ci == "failing", "\(side)")
            #expect(status.checks.map(\.name) == ["build", "test"], "\(side)")
            #expect(!status.isStale, "\(side)")
        }
    }

    /// A merged card must not keep answering with the reading that was true
    /// before it merged.
    ///
    /// The rows are not deleted when a card leaves In Review — nothing needs
    /// them to be — so without the column gate a card `merge-pr` has just moved
    /// to Done would serve its pre-merge verdict as *fresh* for the whole
    /// `maximumAge` window: "a review is required", about a pull request already
    /// on `main`. The app filtered to In Review from the start; this is the MCP
    /// surface agreeing with it rather than quietly disagreeing.
    @Test("A card that has left In Review stops carrying its reading, on both sides")
    func readingIsDroppedOnceTheCardMovesOn() async throws {
        let board = try await ParityBoard.seeded()

        var card = try #require(try await board.store.card(id: board.reviewCardID))
        #expect(try await board.store.prStatus(repoID: card.repoID, prNumber: 7) != nil)

        card.column = .done
        try await board.store.saveCard(card)

        let request = ElliotRequest.getCard(id: board.reviewCardID)
        for (side, response) in [
            ("live", await board.handler.handle(request)),
            ("snapshot", await board.responder.respond(to: request)),
        ] {
            guard case .ok(let payload) = response, case .card(let dto) = payload else {
                Issue.record("\(side) did not answer with a card")
                continue
            }
            #expect(dto.column == "done", "\(side)")
            #expect(dto.prStatus == nil, "\(side) still served a pre-merge reading")
        }
        // The row itself is left alone — this is a gate on the answer, not a
        // deletion, so nothing is lost if the card comes back.
        #expect(try await board.store.prStatus(repoID: card.repoID, prNumber: 7) != nil)
    }

    @Test("A card with no reading says so with an absent object, on both sides")
    func cardWithoutAReadingCarriesNothing() async throws {
        let board = try await ParityBoard.seeded()
        let request = ElliotRequest.getCard(id: board.cardID)

        for (side, response) in [
            ("live", await board.handler.handle(request)),
            ("snapshot", await board.responder.respond(to: request)),
        ] {
            guard case .ok(let payload) = response, case .card(let card) = payload else {
                Issue.record("\(side) did not answer with a card")
                continue
            }
            #expect(card.prStatus == nil, "\(side) invented a reading")
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

    /// The hint is asserted **positively**, not just held equal.
    ///
    /// Equality alone is the vacuous pass this suite has already been caught
    /// making twice: two sides that both answer `nil` compare fine and prove
    /// nothing. That is not hypothetical here — it is this exact refusal's
    /// history. The snapshot carried a pointer to `board_list_cards` and the
    /// live path did not, so #144 reached parity by taking the pointer away,
    /// and the equality below went on holding throughout. Naming the string
    /// makes dropping it from *both* sides a failure rather than a tidy-up.
    ///
    /// Asserted on the snapshot rather than on each side in turn because the
    /// byte comparison that follows carries it to the live answer: a live path
    /// that stopped sending the hint would fail on the encoded diff, with the
    /// field named in the output.
    @Test("A card id nothing matches is refused in the same words on both sides")
    func unknownCardRefusalAgrees() async throws {
        let board = try await ParityBoard.seeded()
        let request = ElliotRequest.listRuns(cardID: UUID(), limit: 0)

        let live = await board.handler.handle(request)
        let snapshot = await board.responder.respond(to: request)

        guard case .failure(let code, _, let hint) = snapshot else {
            Issue.record("the snapshot answered a page for a card that does not exist")
            return
        }
        #expect(code == .cardNotFound)
        #expect(hint == RefusalHint.cardNotFound)
        #expect(try encoded(live) == encoded(snapshot))
    }

    /// The sibling refusal, which nothing held together until #145.
    ///
    /// `listRuns` and `getCard` reach `card_not_found` from two separate
    /// lookups in each of two files, and only the first pair was compared — so
    /// the second was free to drift in either direction with the suite green.
    /// That is not a theoretical gap: every drift this file's own comments
    /// record was found one tool at a time, precisely because the next tool
    /// over had no assertion on it.
    ///
    /// The `readRequests` list above cannot cover this. It compares *answers*
    /// to reads that succeed; the interesting thing about a refusal is that it
    /// happens at all, and an id that matches nothing has to be constructed on
    /// purpose.
    @Test("board_get_card refuses an unknown card in the same words on both sides")
    func unknownCardOnGetCardRefusalAgrees() async throws {
        let board = try await ParityBoard.seeded()
        let request = ElliotRequest.getCard(id: UUID())

        let live = await board.handler.handle(request)
        let snapshot = await board.responder.respond(to: request)

        guard case .failure(let code, let message, let hint) = snapshot else {
            Issue.record("the snapshot answered with a card that does not exist")
            return
        }
        #expect(code == .cardNotFound)
        #expect(message.contains("No card with id"))
        #expect(hint == RefusalHint.cardNotFound)
        #expect(try encoded(live) == encoded(snapshot))
    }

    // MARK: - The read that is allowed to disagree

    /// `screenshot` is a read, and it is the one read whose two sides **must**
    /// differ. Everything above compares because both sides can answer off the
    /// same rows; a window is not a row. The running app has one and can
    /// photograph it; a file on disk does not and never will.
    ///
    /// Written down as a test rather than left as an omission from
    /// `readRequests`, because an omission is indistinguishable from an
    /// oversight — and the obvious "fix" for the next person who notices is to
    /// add the case to that list, where it fails, and then to make the two sides
    /// equal, which would mean the app refusing a screenshot it could perfectly
    /// well take.
    @Test("A screenshot is the one read the snapshot cannot answer")
    func screenshotDivergesOnPurpose() async throws {
        let board = try await ParityBoard.seeded()
        let request = ElliotRequest.screenshot(window: "board", maxInlineBytes: 0)

        let live = await board.handler.handle(request)
        let snapshot = await board.responder.respond(to: request)

        guard
            case .failure(let liveCode, _, _) = live,
            case .failure(let snapshotCode, let message, let hint) = snapshot
        else {
            Issue.record("both sides should refuse in this harness")
            return
        }

        // The snapshot's refusal is `app_unavailable`, never `read_only`.
        // Nothing is being written — there is simply no window — and `read_only`
        // is the code that tells an agent to stop trying to mutate, which is
        // advice about a mistake it did not make.
        #expect(snapshotCode == .appUnavailable)
        #expect(message.contains("window"))
        #expect(hint?.contains("Elliot.app") == true)

        // The live side refuses here only because this harness builds a handler
        // with no capturer. That is a *different* refusal from the snapshot's,
        // and the difference is the point: in the app, this call returns a
        // picture.
        #expect(liveCode == .internalError)
        #expect(liveCode != snapshotCode)
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

        // `listProposals` is compared under a repo filter, so it is worth
        // nothing unless there is a proposal the filter must *exclude*.
        guard case .ok(.proposals(let filtered)) = await board.responder.respond(
            to: .listProposals(analysisID: nil, repo: "phmatray/Elliot", status: nil, limit: 100)
        ) else {
            Issue.record("expected a list of proposals")
            return
        }
        #expect(filtered.count == 1)
        #expect(filtered.allSatisfy { $0.repo == "phmatray/Elliot" })
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
    /// The card in In Review — the only one that carries a pull request reading,
    /// and therefore the only `getCard` that compares a `PRStatusDTO`.
    var reviewCardID: UUID

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

        // A pull request reading for the card in In Review, so `getCard` has the
        // whole `PRStatusDTO` to compare rather than two nils. Dated **now**, not
        // at the epoch: an epoch row is stale on both sides and the comparison
        // would hold "unknown" against "unknown" and see none of the fields —
        // the same blindness the proposal seeding above records.
        try await store.savePRStatus(PRStatus(
            repoID: koine.id, prNumber: 7,
            headRefOid: "3be5f1ee906ff61bdedef0072b635ec6ec40c632",
            checkedAt: Date(),
            rawMergeStateStatus: "DIRTY", rawMergeable: "CONFLICTING", rawReviewDecision: "",
            checks: [
                GHMergeStatus.StatusCheck(name: "build", conclusion: "SUCCESS", status: "COMPLETED"),
                GHMergeStatus.StatusCheck(name: "test", conclusion: "FAILURE", status: "COMPLETED"),
            ]))

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

        // A proposal in **each** repository, which is the whole point of seeding
        // them at all: `listProposals` is the one read whose two implementations
        // are written differently, and with proposals in only one repository —
        // or none — the comparison holds `[]` against `[]` and sees nothing.
        // Measured: with an empty board here, dropping the repo filter from
        // `OfflineResponder.listProposals` (the exact drift that tool's comment
        // records) passed this suite 4/4 and the full suite 1050/1050.
        for (repo, angle, title) in [
            (elliot, AnalysisAngle.bugs, "The reconciler drops a run"),
            (koine, AnalysisAngle.techDebt, "Two copies of the same parser"),
        ] {
            // The analysis row first: `StoryProposal.analysisID` is a foreign
            // key, so a proposal hung off a bare `UUID()` is rejected by the
            // schema rather than merely unreferenced.
            let analysisID = UUID()
            try await store.saveAnalysis(Analysis(
                id: analysisID, repoID: repo.id, angles: [angle],
                maxStoriesPerAngle: 5, createdAt: epoch
            ))
            try await store.saveProposal(StoryProposal(
                analysisID: analysisID,
                runID: UUID(),
                repoID: repo.id,
                angle: angle,
                title: title,
                story: UserStory(role: "developer", want: title, benefit: "the board is honest"),
                rationale: "seeded so a repo filter has something to exclude",
                createdAt: epoch
            ))
        }

        return ParityBoard(
            store: store,
            handler: MCPRequestHandler(store: store, board: board, analysis: analysis),
            responder: OfflineResponder(store: store),
            cardID: held.id,
            reviewCardID: review.id
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
            .getCard(id: reviewCardID),
            .listRuns(cardID: nil, limit: 0),
            .listRuns(cardID: cardID, limit: 0),
            .next(repo: nil, limit: 0),
            .next(repo: "phmatray/Elliot", limit: 1),
            .listProposals(analysisID: nil, repo: "phmatray/Elliot", status: nil, limit: 100),
        ]
    }

    /// Both throw rather than swallowing. `try?` here would compare `"" == ""`
    /// on an encode failure and pass having compared nothing — and since the two
    /// sides share one encoder, a single DTO the encoder chokes on would silence
    /// every read comparison at once, which is the failure this whole suite
    /// exists to make impossible.
    func liveText(_ request: ElliotRequest) async throws -> String {
        String(decoding: try encoded(await handler.handle(request)), as: UTF8.self)
    }

    func snapshotText(_ request: ElliotRequest) async throws -> String {
        String(decoding: try encoded(await responder.respond(to: request)), as: UTF8.self)
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
