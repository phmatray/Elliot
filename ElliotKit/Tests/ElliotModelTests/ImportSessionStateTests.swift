import Foundation
import Testing

@testable import ElliotModel

@Suite("Import session state")
struct ImportSessionStateTests {

    private let a = UUID()
    private let b = UUID()

    @Test("An unseen repository is worth importing")
    func unseenIsImportable() {
        let state = ImportSessionState()
        #expect(state.shouldImport(repoID: a))
        #expect(state.shouldAutoImport(repoID: a))
        #expect(state.failure(repoID: a) == nil)
    }

    @Test("A success is absorbing: neither path asks again")
    func successStops() {
        var state = ImportSessionState()
        state.recordSuccess(repoID: a)
        #expect(!state.shouldImport(repoID: a))
        #expect(!state.shouldAutoImport(repoID: a))
        #expect(state.failure(repoID: a) == nil)
    }

    /// The whole bug: "we tried" was being stored as "we succeeded". A failure
    /// leaves the repository importable, and says why it is not imported.
    @Test("A failure stays importable, and keeps its message")
    func failureIsRetryable() {
        var state = ImportSessionState()
        state.recordFailure(repoID: a, message: "gh: not logged in")
        #expect(state.shouldImport(repoID: a))
        #expect(state.failure(repoID: a) == "gh: not logged in")
    }

    /// Criterion 4, held by the type rather than by a belief about SwiftUI.
    /// `shouldImport` stays true so a gesture can retry, but the unattended
    /// path is spent after one attempt, so a repository that fails while `gh`
    /// is down cannot produce a second unattended call — however many times the
    /// view re-evaluates.
    @Test("A failure spends the unattended attempt, so re-evaluation cannot loop")
    func failureBoundsTheAutomaticPath() {
        var state = ImportSessionState()
        state.recordFailure(repoID: a, message: "offline")
        #expect(state.shouldImport(repoID: a), "a gesture may still retry")
        #expect(!state.shouldAutoImport(repoID: a), "the unattended path may not")

        for _ in 0..<100 { #expect(!state.shouldAutoImport(repoID: a)) }
    }

    @Test("A success after a failure clears the message")
    func successClearsFailure() {
        var state = ImportSessionState()
        state.recordFailure(repoID: a, message: "rate limited")
        state.recordSuccess(repoID: a)
        #expect(state.failure(repoID: a) == nil)
        #expect(!state.shouldImport(repoID: a))
    }

    @Test("A second failure replaces the first message rather than stacking")
    func failureMessageIsLatest() {
        var state = ImportSessionState()
        state.recordFailure(repoID: a, message: "first")
        state.recordFailure(repoID: a, message: "second")
        #expect(state.failure(repoID: a) == "second")
    }

    @Test("Repositories do not share state")
    func perRepository() {
        var state = ImportSessionState()
        state.recordSuccess(repoID: a)
        state.recordFailure(repoID: b, message: "boom")
        #expect(!state.shouldImport(repoID: a))
        #expect(state.shouldImport(repoID: b))
        #expect(state.failure(repoID: a) == nil)
        #expect(state.failure(repoID: b) == "boom")
    }

    /// `clearDismissals` resets a repository so the next refresh brings back
    /// what was deleted — that has to restore the unattended attempt too, or
    /// the automatic path stays spent for the rest of the session.
    @Test("Forgetting a repository restores both paths and drops the message")
    func forgetResets() {
        var state = ImportSessionState()
        state.recordFailure(repoID: a, message: "boom")
        state.forget(repoID: a)
        #expect(state.shouldImport(repoID: a))
        #expect(state.shouldAutoImport(repoID: a))
        #expect(state.failure(repoID: a) == nil)

        var succeeded = ImportSessionState()
        succeeded.recordSuccess(repoID: b)
        succeeded.forget(repoID: b)
        #expect(succeeded.shouldAutoImport(repoID: b))
    }

    @Test("Every failure is reportable, so a view can render them all")
    func failuresAreEnumerable() {
        var state = ImportSessionState()
        state.recordFailure(repoID: a, message: "one")
        state.recordFailure(repoID: b, message: "two")
        #expect(state.failures.count == 2)
        #expect(state.failures[a] == "one")
        #expect(state.failures[b] == "two")
    }
}
