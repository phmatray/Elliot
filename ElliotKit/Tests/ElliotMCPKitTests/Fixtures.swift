import ElliotIPC
import ElliotModel
import ElliotStore
import Foundation
import MCP
import Testing

@testable import ElliotMCPKit

// MARK: - A board that answers from a script

/// Stands in for `AppBridge`, so the tools can be driven with no socket and no
/// app.
///
/// The branches that most need pinning are the ones hardest to reach by hand:
/// refusing an unknown repository, filling `activeRunID` from a snapshot,
/// saying an answer was cut. All of them are on the *offline* path, which by
/// definition never runs on a machine where Elliot is up.
///
/// The two defaults refuse rather than answer emptily: a test that reaches a
/// side of the bridge it did not mean to fails on the spot instead of quietly
/// asserting against a stub.
struct StubBridge: BridgeProviding {
    var isAppRunning = true
    var onRead: @Sendable (ElliotRequest) -> BridgeOutcome = { _ in
        .live(.failure(code: .internalError, message: "this test expected no read", hint: nil))
    }
    var onWrite: @Sendable (ElliotRequest) -> ElliotResponse = { _ in
        .failure(code: .internalError, message: "this test expected no write", hint: nil)
    }

    func read(_ request: ElliotRequest) -> BridgeOutcome { onRead(request) }
    func write(_ request: ElliotRequest) -> ElliotResponse { onWrite(request) }
}

extension StubBridge {
    /// Elliot is up and answers this to everything.
    static func answering(_ payload: ElliotPayload) -> StubBridge {
        StubBridge(onRead: { _ in .live(.ok(payload)) }, onWrite: { _ in .ok(payload) })
    }

    static func refusing(
        _ code: ElliotErrorCode,
        _ message: String = "refused",
        hint: String? = nil
    ) -> StubBridge {
        StubBridge(
            onRead: { _ in .live(.failure(code: code, message: message, hint: hint)) },
            onWrite: { _ in .failure(code: code, message: message, hint: hint) }
        )
    }

    /// Elliot is down: reads fall back to the snapshot, writes are refused —
    /// which is the whole architecture in one stub.
    ///
    /// `reason` defaults to the common case but is a parameter because the
    /// other one — up, and not answering — has to be reachable from a test:
    /// it is served by the same branch and must not borrow this one's story.
    static func snapshot(
        _ store: BoardStore,
        reason: SnapshotReason = .appNotRunning
    ) -> StubBridge {
        StubBridge(
            isAppRunning: false,
            onRead: { _ in .offline(store, reason) },
            onWrite: { _ in
                .failure(
                    code: .appUnavailable,
                    message: "Elliot is not running and could not be launched.",
                    hint: "Open Elliot.app and try again."
                )
            }
        )
    }
}

/// What the bridge was actually asked.
///
/// A lock rather than an actor: these stubs answer without suspending, so a
/// recorder that had to be awaited would make every assertion about it a race.
/// The bridge's methods are `async` because the real one blocks on a socket,
/// not because anything here needs to.
final class RequestLog: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [ElliotRequest] = []

    func record(_ request: ElliotRequest) {
        lock.lock()
        defer { lock.unlock() }
        storage.append(request)
    }

    var requests: [ElliotRequest] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    var last: ElliotRequest? { requests.last }
    var count: Int { requests.count }
}

// MARK: - Reading what the agent reads

/// The parsed body of a tool result.
///
/// Every assertion in this suite goes through here rather than through "the
/// call did not throw": the tool layer's whole job is the shape of this JSON,
/// and a result that is `isError: false` with nothing useful in it is exactly
/// the failure mode finding 11 is about.
struct Answer {
    var isError: Bool
    var body: Value
    var text: String

    subscript(key: String) -> Value? { body[key] }

    var error: String? { self["error"]?.stringValue }
    var message: String { self["message"]?.stringValue ?? "" }
    var hint: String { self["hint"]?.stringValue ?? "" }
    var note: String { self["note"]?.stringValue ?? "" }
    var source: String? { self["source"]?.stringValue }
}

extension Value {
    subscript(key: String) -> Value? { objectValue?[key] }

    subscript(index: Int) -> Value? {
        guard let array = arrayValue, array.indices.contains(index) else { return nil }
        return array[index]
    }
}

private struct ResultWasNotText: Error {}

func answer(_ result: CallTool.Result) throws -> Answer {
    guard case .text(let text, _, _) = try #require(result.content.first) else {
        throw ResultWasNotText()
    }
    return Answer(
        isError: result.isError ?? false,
        body: try WireCodec.decoder.decode(Value.self, from: Data(text.utf8)),
        text: text
    )
}

/// One call, parsed. Nearly every test is this line.
func call(
    _ server: ElliotMCPServer,
    _ name: String,
    _ arguments: [String: Value] = [:]
) async throws -> Answer {
    try answer(await server.call(name: name, arguments: arguments))
}

// MARK: - Model fixtures

/// Fixed, so two DTOs built from the same fixture compare equal and no
/// assertion depends on when the suite ran.
let epoch = Date(timeIntervalSince1970: 1_700_000_000)

func makeRepo(
    _ nameWithOwner: String = "phmatray/Elliot",
    id: UUID = UUID(),
    path: String? = nil,
    displayName: String? = nil,
    isEnabled: Bool = true
) -> Repo {
    Repo(
        id: id,
        path: path ?? "/tmp/\(nameWithOwner.replacingOccurrences(of: "/", with: "-"))",
        nameWithOwner: nameWithOwner,
        displayName: displayName ?? nameWithOwner,
        isEnabled: isEnabled
    )
}

func makeCard(
    repoID: UUID,
    id: UUID = UUID(),
    title: String = "Stream the run log",
    column: Column = .backlog,
    orderIndex: Double = 1024,
    issueNumber: Int? = nil,
    prNumber: Int? = nil
) -> Card {
    Card(
        id: id,
        repoID: repoID,
        title: title,
        column: column,
        orderIndex: orderIndex,
        issueNumber: issueNumber,
        prNumber: prNumber,
        columnEnteredAt: epoch,
        createdAt: epoch,
        updatedAt: epoch
    )
}

func makeRun(
    cardID: UUID,
    repoID: UUID,
    id: UUID = UUID(),
    kind: SkillKind = .createIssue,
    state: RunState = .succeeded,
    outcome: VerifiedOutcome? = nil,
    totalCostUSD: Double? = nil,
    createdAt: Date = epoch
) -> SkillRun {
    SkillRun(
        id: id,
        cardID: cardID,
        repoID: repoID,
        kind: kind,
        prompt: "/\(kind.skillName)",
        cwd: "/tmp",
        state: state,
        startedAt: createdAt,
        logPath: "/tmp/\(id.uuidString).ndjson",
        stderrPath: "/tmp/\(id.uuidString).stderr",
        totalCostUSD: totalCostUSD,
        verifiedOutcome: outcome,
        createdAt: createdAt
    )
}

/// An in-memory board, seeded in dependency order because the schema has real
/// foreign keys.
func makeStore(
    repos: [Repo] = [],
    cards: [Card] = [],
    runs: [SkillRun] = []
) async throws -> BoardStore {
    let store = try BoardStore.inMemory()
    for repo in repos { try await store.saveRepo(repo) }
    for card in cards { try await store.saveCard(card) }
    for run in runs { try await store.saveRun(run) }
    return store
}
