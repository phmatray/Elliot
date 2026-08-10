import ElliotModel
import ElliotProcess
import Foundation
import Testing

@testable import ElliotEngine

/// The seam between "what Preflight says" and "may an unattended agent start".
///
/// ⛔ **A gate answers a `PreflightState`, never a `Bool`, and that is the whole
/// point of the type.** The brief this was built from asked for
/// `blocks(_:) async -> Bool` over `PreflightService.isBlocking` — a function
/// deleted in #302 for being exactly the two-valued answer to a three-valued
/// question that let a gate be asserted in three documents and implemented in
/// none. A `Bool` here would put that shape back one layer up: a gate that could
/// not say *nobody looked* would have to say *fine*.
@Suite("Repository gating")
struct RepoGateTests {

    private let repo = Repo(
        path: "/tmp/elliot-not-a-repository-9f3a",
        nameWithOwner: "phmatray/Elliot", displayName: "Elliot"
    )

    private var preflight: PreflightService {
        PreflightService(
            environment: LoginShellEnvironment(variables: [:], capturedVia: "test"),
            config: ToolConfig(
                claudePath: "/usr/bin/false", ghPath: "/usr/bin/false",
                gitPath: "/usr/bin/false", environment: [:]
            )
        )
    }

    /// ⚠️ **`OpenGate` answers `notChecked`, not `passing`, and the difference is
    /// not academic.**
    ///
    /// It refuses nothing *today* — `UnattendedStartRefusal` lets `notChecked`
    /// through, for the reasons `PreflightState` writes out — so it is still the
    /// gate a caller reaches for when it has already decided. What it must not do
    /// is claim a sweep happened. `passing` here would be a caller saying "asked
    /// and clear" having asked nothing, which is the collapse `PreflightState`
    /// exists to prevent, planted in the one type whose name invites it.
    ///
    /// The consequence is deliberate and worth naming: the day `notChecked`
    /// starts refusing — which `PreflightState` says is one line in
    /// `evaluateMove` — every site holding an `OpenGate` starts refusing too, and
    /// has to state a verdict it has actually measured. That is the loud
    /// direction. `passing` would leave them all silently permitting.
    @Test("An open gate says nobody looked, rather than claiming a pass")
    func openGateSaysNobodyLooked() async {
        #expect(await OpenGate().verdict(for: repo) == .notChecked)
    }

    /// The rule's own answer for that state, asserted here rather than inherited.
    ///
    /// `UnattendedStartRefusalTests.notCheckedDoesNotRefuse` pins the rule. This
    /// pins what it means *for a service that spawns up to eight unattended
    /// `claude -p` runs at `bypassPermissions`*: a gate whose sweep never landed
    /// permits. It is consistent with the board and it is a decision, so it is
    /// written down at the caller that pays for it.
    @Test("A gate that never looked permits an unattended start")
    func nobodyLookedPermits() async {
        #expect(
            UnattendedStartRefusal.refusal(
                repo: repo, preflight: await OpenGate().verdict(for: repo)) == nil)
    }

    /// The real gate, over a path that is not a git repository at all.
    ///
    /// ⚠️ **The honest limit of this test: it cannot show a `passing` verdict.**
    /// Reaching one needs a real checkout *and* a `gh` that answers `repo view`,
    /// and `Scripts/fake-gh.sh` deliberately exits 64 on anything but `issue
    /// list` / `pr list` — an unexpected call must fail loudly. So the positive
    /// witness here is the other half: the verdict is tied to a named failing
    /// check the service actually produced, rather than being a constant this
    /// suite would agree with either way.
    @Test("The real gate refuses a path that is not a checkout, naming the check")
    func preflightGateRefusesANonRepository() async {
        let service = preflight
        let results = await service.repoChecks(repo)

        #expect(results.contains { $0.id == "repo.exists" && $0.status == .fail })
        #expect(await PreflightGate(preflight: service).verdict(for: repo) == .failing)
    }

    /// A reading *is* somebody having looked, so the real gate has two answers.
    ///
    /// `PreflightReading.verdict` can never be `notChecked`, and `PreflightGate`
    /// takes a reading every time it is asked rather than consulting a cache —
    /// which is why the third state belongs to a caller that did not ask, and not
    /// to this one.
    @Test("The real gate never answers notChecked")
    func preflightGateNeverSaysNobodyLooked() async {
        #expect(await PreflightGate(preflight: preflight).verdict(for: repo) != .notChecked)
    }
}
