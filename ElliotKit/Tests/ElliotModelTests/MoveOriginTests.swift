import Foundation
import Testing

@testable import ElliotModel

/// The one property that decides whether an unattended agent starts.
///
/// It had no test at all, and it was written as `if case .system = self { return
/// false }; return true` — a shape in which a seventh origin inherits `true` in
/// silence. The switch below the fix is the real guard; this file is its
/// witness, and it is a witness worth having because the thing being granted is
/// a `claude -p` at `bypassPermissions` inside a real checkout.
@Suite("Move origin")
struct MoveOriginTests {

    private static let systemReasons: [MoveOrigin.SystemReason] = [
        .prBecameReady, .prMergedExternally, .reconciliation, .githubImport,
    ]

    @Test("A system move never allows a side effect, for any of its four reasons")
    func systemReasonsAllowNothing() {
        for reason in Self.systemReasons {
            #expect(
                !MoveOrigin.system(reason: reason).allowsSideEffects,
                "\(reason.rawValue) would fire a skill"
            )
        }
    }

    @Test("The three origins that are somebody's decision all allow side effects")
    func decisionsAllowSideEffects() {
        #expect(MoveOrigin.userDrag.allowsSideEffects)
        #expect(MoveOrigin.mcp(client: "claude-code").allowsSideEffects)
        // Auto-dev is the whole point of the case: a session that could not fire
        // a skill would move cards and do nothing.
        #expect(MoveOrigin.autoDev(sessionID: UUID()).allowsSideEffects)
    }

    @Test("An auto-dev origin survives a round trip through its stored JSON")
    func autoDevIsCodable() throws {
        // `moveAudit.origin` is a JSON column, so the synthesised `Codable` is
        // the on-disk contract for every move this feature makes.
        let sessionID = UUID()
        let data = try JSONEncoder().encode(MoveOrigin.autoDev(sessionID: sessionID))
        let back = try JSONDecoder().decode(MoveOrigin.self, from: data)
        #expect(back == .autoDev(sessionID: sessionID))
    }
}
