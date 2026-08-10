import Testing

@testable import ElliotModel

/// The mode an appraisal runs under, for every mode a repository can be in.
///
/// An allow-list and not a ranking. The CLI has added modes before (`auto`,
/// `dontAsk`), and an ordering of names nobody here has measured is a guess —
/// this repository's whole discipline is that a guess written down becomes a
/// fact. So the modes this project is willing to leave alone are named, and
/// everything else is capped.
@Suite("Appraisal permission mode")
struct AppraisalPermissionModeTests {

    /// The whole mapping, written out, one row per case.
    ///
    /// ⛔ A disjunction — `capped == mode || capped == .acceptEdits` — was the
    /// obvious way to write the totality check and is satisfied by an
    /// implementation that returns `mode` for every case, i.e. by no capping at
    /// all. A table is the only form of this test that fails when the rule is
    /// removed, which was verified by removing it.
    private static let expected: [PermissionMode: PermissionMode] = [
        .manual: .manual,
        .acceptEdits: .acceptEdits,
        .plan: .plan,
        .auto: .acceptEdits,
        .dontAsk: .acceptEdits,
        .bypassPermissions: .acceptEdits,
    ]

    @Test("The default is capped at acceptEdits")
    func bypassIsCapped() {
        #expect(PermissionMode.appraisal(repo: .bypassPermissions) == .acceptEdits)
    }

    @Test("Modes whose reach is not measured here are capped too", arguments: [
        PermissionMode.auto, .dontAsk,
    ])
    func unmeasuredModesAreCapped(mode: PermissionMode) {
        #expect(PermissionMode.appraisal(repo: mode) == .acceptEdits)
    }

    @Test("A repository already at or below the cap keeps its own choice", arguments: [
        PermissionMode.plan, .manual, .acceptEdits,
    ])
    func tighterChoicesAreKept(mode: PermissionMode) {
        // `.plan` is kept even though a run under it may not be able to write
        // the artifact at all. That is the honest outcome — the harvester
        // reports "no artifact" — and it beats overriding a mode the operator
        // chose deliberately.
        #expect(PermissionMode.appraisal(repo: mode) == mode)
    }

    @Test("Every mode has an answer, and it is the one named here")
    func everyModeIsAnswered() throws {
        // The table is exhaustive over `allCases`, so a seventh mode fails here
        // by name rather than being absorbed into a rule nobody chose for it.
        #expect(Set(Self.expected.keys) == Set(PermissionMode.allCases))
        for mode in PermissionMode.allCases {
            let want = try #require(Self.expected[mode], "No answer recorded for \(mode)")
            #expect(PermissionMode.appraisal(repo: mode) == want)
        }
    }

    @Test("It is never wider than bypassPermissions, whatever the repository says")
    func itNeverWidens() {
        #expect(PermissionMode.allCases.allSatisfy {
            PermissionMode.appraisal(repo: $0) != .bypassPermissions
        })
    }
}
