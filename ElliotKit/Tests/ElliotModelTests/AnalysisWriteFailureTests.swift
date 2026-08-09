import Foundation
import Testing

@testable import ElliotModel

/// What a failed analysis write says, and the property that matters more than
/// the wording: it says the edit did not happen.
///
/// The failure a reader must never meet is the silent one — an editor closing
/// exactly as it does on success, with the old text waiting on the next screen,
/// which reads as the app having forgotten rather than as a write having failed
/// (#223).
@Suite("Analysis write failure")
struct AnalysisWriteFailureTests {

    /// Both routes to "it did not happen" have to say so. An error path that
    /// covered only `throw` would still dismiss silently when the service is
    /// absent, which is the same outcome by a different route — the quieter
    /// half of #223, and the one a fix forgets.
    @Test("Every failure states that nothing was saved")
    func everyFailureSaysItDidNotSave() {
        let failures: [AnalysisWriteFailure] = [
            .serviceUnavailable,
            .refused("the store is locked"),
        ]
        for failure in failures {
            #expect(
                failure.sentence.hasPrefix("Not saved"),
                "\(failure) opens with \(failure.sentence) — a reader has to be told the edit is gone"
            )
            #expect(!failure.sentence.isEmpty)
        }
    }

    @Test("A refusal carries the reason it was given, and an absent service does not invent one")
    func theReasonSurvives() {
        #expect(AnalysisWriteFailure.refused("disk full").sentence.contains("disk full"))
        #expect(
            AnalysisWriteFailure.serviceUnavailable.sentence.contains("not running"),
            "an absent service is a different fact from a refusal and reads as one"
        )
    }

    // MARK: - The note after a rejection

    /// The louder half of #223: `rejectProposals` swallowed its error and then
    /// wrote "Rejected N proposals" on the very next line, whichever had
    /// happened. A silent failure leaves a reader guessing; an asserted one
    /// leaves them certain and wrong.
    @Test("A failed rejection never claims anything was rejected", arguments: [0, 1, 2, 17])
    func aFailedRejectionSaysSo(count: Int) {
        for failure in [AnalysisWriteFailure.serviceUnavailable, .refused("no")] {
            let note = AnalysisWriteFailure.rejectionNote(count: count, failure: failure)
            #expect(
                !note.contains("Rejected"),
                "\(count) proposals with \(failure) produced \(note) — the board claimed a success"
            )
            #expect(note == failure.sentence)
        }
    }

    @Test("A rejection that landed says how many, and counts one of them properly")
    func aSuccessfulRejectionCountsCorrectly() {
        #expect(AnalysisWriteFailure.rejectionNote(count: 1, failure: nil) == "Rejected 1 proposal.")
        #expect(AnalysisWriteFailure.rejectionNote(count: 3, failure: nil) == "Rejected 3 proposals.")
    }

    // MARK: - The note after a restoration

    @Test("A failed restoration never claims anything came back", arguments: [0, 1, 2, 17])
    func aFailedRestorationSaysSo(count: Int) {
        for failure in [AnalysisWriteFailure.serviceUnavailable, .refused("no")] {
            let note = AnalysisWriteFailure.restorationNote(
                asked: count, restored: count, failure: failure
            )
            #expect(
                !note.contains("Restored"),
                "\(count) proposals with \(failure) produced \(note) — the board claimed a success"
            )
            #expect(note == failure.sentence)
        }
    }

    @Test("A restoration that landed in full says how many, and counts one properly")
    func aFullRestorationCountsCorrectly() {
        #expect(
            AnalysisWriteFailure.restorationNote(asked: 1, restored: 1, failure: nil)
                == "Restored 1 proposal.")
        #expect(
            AnalysisWriteFailure.restorationNote(asked: 3, restored: 3, failure: nil)
                == "Restored 3 proposals.")
    }

    /// The whole reason this note takes two counts and `rejectionNote` takes
    /// one. A restore can lose its claim to a proposal that already produced a
    /// **card**, and announcing the number asked for would hide exactly the case
    /// the store's refusal exists for — a reader would read "Restored 3", see
    /// two rows move, and have nothing to tell them why.
    @Test("A partly-refused restoration reports what actually moved, not what was asked")
    func aPartialRestorationTellsTheTruth() {
        let note = AnalysisWriteFailure.restorationNote(asked: 3, restored: 2, failure: nil)
        #expect(note.contains("2"))
        #expect(note.contains("3"))
        #expect(
            !note.hasPrefix("Restored 3"),
            "\(note) announces the number the button asked for, which is the defect"
        )
    }

    @Test("A restoration that moved nothing says so rather than counting zero")
    func aRefusedRestorationDoesNotCountZero() {
        for asked in [0, 1, 5] {
            let note = AnalysisWriteFailure.restorationNote(
                asked: asked, restored: 0, failure: nil
            )
            #expect(note.hasPrefix("Nothing to restore"))
            #expect(
                !note.contains("Restored 0"),
                "\(note) reads as a successful restoration of nothing"
            )
        }
    }

    @Test("The two failures are distinguishable")
    func theCasesAreNotInterchangeable() {
        #expect(AnalysisWriteFailure.serviceUnavailable != .refused("anything"))
        #expect(AnalysisWriteFailure.refused("a") != .refused("b"))
        #expect(AnalysisWriteFailure.refused("a") == .refused("a"))
    }
}
