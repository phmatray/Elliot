import ElliotEngine
import ElliotModel
import ElliotStore
import Foundation
import Testing

@testable import ElliotAppKit

/// The analysis refusal, and the fix it now carries (#294).
///
/// `AnalysisFooterMessage.setup` ranks the refusal above the failure, the clash
/// and the consequence *because it is the only one of the four that names
/// something to go and do* — and then the footer handed the reader a sentence.
/// #170 settled the principle for Preflight (`CheckResult.fixes`) and #12 for
/// Repositories (`RepoRow.fixes`); this was the last diagnostic in the app that
/// was prose only.
@Suite("Analysis refusal")
@MainActor
struct AnalysisRefusalTests {

    private func repo(_ name: String, enabled: Bool = true, preflight: PreflightState? = nil) -> Repo {
        Repo(
            path: "/tmp/\(name)", nameWithOwner: "o/\(name)", displayName: name,
            isEnabled: enabled, preflight: preflight
        )
    }

    private func check(_ id: String, _ title: String, _ status: CheckStatus) -> CheckResult {
        CheckResult(id: id, title: title, status: status, detail: "d")
    }

    // MARK: - The decision, as values

    /// ⚠️ The three sentences are asserted **verbatim** here and in
    /// `AnalysisSessionTests`. They are what the toolbar's tooltip has always
    /// said; this issue is about what the reader can press, and rewording them
    /// in the same change would make an unrelated regression look like part of
    /// it.
    @Test("Nothing picked offers every registered repository, in the board's order")
    func nothingPickedOffersThemAll() {
        let a = repo("a")
        let b = repo("b")
        let c = repo("c")

        let refusal = try? #require(
            AnalysisRefusal.decide(subject: nil, registered: [a, b, c], blocked: nil))

        #expect(refusal?.text == "Pick a single repository to analyse.")
        #expect(
            refusal?.fixes == [
                .analyse(repoID: a.id, name: "a"),
                .analyse(repoID: b.id, name: "b"),
                .analyse(repoID: c.id, name: "c"),
            ])
    }

    /// ⛔ **The offer includes repositories that are switched off or failing**,
    /// deliberately. Filtering them would hide from this menu repositories the
    /// board's own toolbar picker shows; picking one moves the reader to the next
    /// refusal, which names the next thing to press.
    @Test("The offer is the picker's list, not a filtered one")
    func theOfferIsNotFiltered() {
        let healthy = repo("healthy")
        let off = repo("off", enabled: false)
        let blocked = repo("blocked", preflight: .failing)

        let refusal = AnalysisRefusal.decide(
            subject: nil, registered: [healthy, off, blocked], blocked: nil)

        #expect(refusal?.fixes.count == 3)
    }

    /// ⛔ **A menu with no rows is the trap #151 removed from the Analyse
    /// toggle** — a control you cannot use is worse than one that opens onto an
    /// explanation. With nothing registered the explanation stands alone.
    @Test("With no repository registered the refusal carries no fix at all")
    func nothingToOffer() {
        let refusal = AnalysisRefusal.decide(subject: nil, registered: [], blocked: nil)

        #expect(refusal?.text == "Pick a single repository to analyse.")
        #expect(refusal?.fixes.isEmpty == true)
        #expect(AnalysisFix.chooser(for: refusal?.fixes ?? []) == nil)
    }

    @Test("A repository switched off is offered the switch, by name")
    func disabledOffersTheSwitch() {
        let off = repo("off", enabled: false)

        let refusal = AnalysisRefusal.decide(subject: off, registered: [off], blocked: nil)

        #expect(refusal?.text == Consequence.reason(.repoDisabled))
        #expect(refusal?.fixes == [.enable(repoID: off.id, name: "off")])
        #expect(refusal?.fixes.first?.label == "Switch off on")
    }

    @Test("A repository Preflight is failing is offered the way to the finding")
    func blockedOffersPreflight() {
        let blocked = repo("blocked", preflight: .failing)
        let badge = BlockedBadge(
            repoID: blocked.id, check: check("repo.isMainCheckout", "Main checkout", .fail))

        let refusal = AnalysisRefusal.decide(
            subject: blocked, registered: [blocked], blocked: badge)

        #expect(
            refusal?.text
                == "A Preflight check is failing for this repository — fix it there first.")
        #expect(refusal?.fixes == [.showPreflight(badge)])
        // ✅ The wording is the badge's own, so the card's tooltip, its VoiceOver
        // action and this button cannot come to name one act three ways.
        #expect(refusal?.fixes.first?.label == "Show Main checkout in Preflight")
    }

    /// ⛔ The order is load-bearing. A repository can be both, and a switch the
    /// reader threw themselves is not a diagnosis Elliot made — `Consequence`
    /// keeps `.repoDisabled` and `.repoBlocked` apart in as many words. Offering
    /// Preflight first would send someone hunting a finding when the answer is a
    /// toggle.
    @Test("Switched off outranks failing, and offers the switch rather than the finding")
    func disabledOutranksBlocked() {
        let both = repo("both", enabled: false, preflight: .failing)
        let badge = BlockedBadge(repoID: both.id, check: check("x", "Main checkout", .fail))

        let refusal = AnalysisRefusal.decide(subject: both, registered: [both], blocked: badge)

        #expect(refusal?.text == Consequence.reason(.repoDisabled))
        #expect(refusal?.fixes == [.enable(repoID: both.id, name: "both")])
    }

    @Test("A healthy picked repository is refused nothing")
    func healthyIsNotRefused() {
        let healthy = repo("healthy")
        #expect(AnalysisRefusal.decide(subject: healthy, registered: [healthy], blocked: nil) == nil)
    }

    // MARK: - One button, or one menu

    /// ⚠️ **The rule asks what the fixes are, not how many.** Only the repository
    /// offer is ever plural; a plural list of *different* acts is a list of
    /// buttons, and counting alone would sweep those into a menu titled for
    /// repositories.
    @Test("Several repositories collapse into one menu; one repository is one button")
    func severalRepositoriesBecomeAMenu() {
        let one = AnalysisFix.analyse(repoID: UUID(), name: "one")
        let two = AnalysisFix.analyse(repoID: UUID(), name: "two")

        #expect(AnalysisFix.chooser(for: []) == nil)
        #expect(AnalysisFix.chooser(for: [one]) == nil)
        #expect(AnalysisFix.chooser(for: [one, two]) == "Pick a repository")
    }

    @Test("A plural list of different acts stays a list of buttons")
    func aMixedListIsNotAChooser() {
        let id = UUID()
        let mixed: [AnalysisFix] = [
            .enable(repoID: id, name: "off"),
            .showPreflight(BlockedBadge(repoID: id, check: nil)),
        ]
        #expect(AnalysisFix.chooser(for: mixed) == nil)
    }

    /// A `ForEach` rebuilds the row under the pointer when its identity moves, so
    /// the id is keyed on what the fix acts on rather than on where it sits.
    @Test("Two fixes for two repositories are two identities; two acts on one are also two")
    func identitiesDoNotCollide() {
        let a = UUID()
        let b = UUID()
        let fixes: [AnalysisFix] = [
            .analyse(repoID: a, name: "a"),
            .analyse(repoID: b, name: "b"),
            .enable(repoID: a, name: "a"),
            .showPreflight(BlockedBadge(repoID: a, check: nil)),
        ]
        #expect(Set(fixes.map(\.id)).count == fixes.count)
    }

    // MARK: - What the model decides

    @Test("The model's refusal names the same three cases, each with its fix")
    func theModelWiresItUp() throws {
        let healthy = repo("healthy")
        let off = repo("off", enabled: false)
        let blocked = repo("blocked", preflight: .failing)

        let model = AppModel()
        model.testOnlySeed(repos: [healthy, off, blocked], cards: [])
        model.testOnlySeedChecks(
            repo: blocked.id, [check("repo.isMainCheckout", "Main checkout", .fail)])

        model.selectedRepoID = nil
        #expect(model.analysisRefusal?.text == "Pick a single repository to analyse.")
        #expect(model.analysisRefusal?.fixes.count == 3)

        model.selectedRepoID = off.id
        #expect(model.analysisRefusal?.fixes == [.enable(repoID: off.id, name: "off")])

        model.selectedRepoID = blocked.id
        // ✅ The *same* badge the card's own blocked badge draws, not a second
        // one built here — which is the whole of "reuse rather than reinvent".
        let badge = try #require(model.blockedBadge(for: blocked))
        #expect(model.analysisRefusal?.fixes == [.showPreflight(badge)])

        model.selectedRepoID = healthy.id
        #expect(model.analysisRefusal == nil)
    }

    /// The launch window `BlockedBadge` exists for, reaching this screen too: a
    /// verdict persisted with no reading behind it yet still refuses the
    /// analysis, and the fix still goes somewhere — Preflight's section for that
    /// repository, with nothing to expand.
    @Test("A verdict with no reading behind it still carries a way to Preflight")
    func aVerdictWithoutAReadingStillOffersTheWay() {
        let blocked = repo("blocked", preflight: .failing)
        let model = AppModel()
        model.testOnlySeed(repos: [blocked], cards: [])
        model.selectedRepoID = blocked.id

        #expect(
            model.analysisRefusal?.fixes
                == [.showPreflight(BlockedBadge(repoID: blocked.id, check: nil))])
        #expect(model.analysisRefusal?.fixes.first?.label == "Show this repository in Preflight")
    }

    // MARK: - Pressing them

    @Test("Analysing a repository points the panel at it, and lifts the refusal")
    func analysingPointsThePanel() async {
        let a = repo("a")
        let b = repo("b")
        let model = AppModel()
        model.testOnlySeed(repos: [a, b], cards: [])
        model.selectedRepoID = nil

        await model.apply(.analyse(repoID: b.id, name: "b"))

        #expect(model.analysisRepoID == b.id)
        // The claim that matters: the sentence and its own button are gone,
        // which is how this fix reports rather than through a `FixOutcome`.
        #expect(model.analysisRefusal == nil)
    }

    /// ⛔ The offer was built while the footer rendered. A repository forgotten
    /// between then and the press must not point the board at a registration
    /// that is gone — an empty board under a phantom name.
    @Test("Analysing a repository that has since been forgotten changes nothing")
    func analysingAForgottenRepositoryIsRefused() async {
        let a = repo("a")
        let model = AppModel()
        model.testOnlySeed(repos: [a], cards: [])
        model.selectedRepoID = a.id

        await model.apply(.analyse(repoID: UUID(), name: "gone"))

        #expect(model.selectedRepoID == a.id)
    }

    /// ⛔ **The write goes through `setRepoEnabled`, the writer Preflight's own
    /// toggle uses.** This is a screen that has only ever read a `Repo`, and a
    /// second writer for one column is how two screens come to disagree about it.
    /// Asserted against the **store**, because that is where the switch lives.
    @Test("Switching a repository on writes the row the registry writes")
    func enablingGoesThroughTheStore() async throws {
        let store = try BoardStore.inMemory()
        let off = repo("off", enabled: false)
        try await store.saveRepo(off)

        let model = AppModel()
        model.testOnlySeed(repos: [off], cards: [])
        model.testOnlySeedStore(store)
        model.selectedRepoID = off.id

        #expect(try await store.repo(id: off.id)?.isEnabled == false)

        await model.apply(.enable(repoID: off.id, name: "off"))

        #expect(try await store.repo(id: off.id)?.isEnabled == true)
    }

    /// ⛔ **The claim above is about the *route*, and asserting the store cannot
    /// see one.**
    ///
    /// Found by break-testing `enablingGoesThroughTheStore`: replacing
    /// `setRepoEnabled(repo, enabled: true)` with `repo.isEnabled = true;
    /// try? await store?.saveRepo(repo)` — a second writer, three lines, right
    /// here in the analysis section — left all 63 tests in these suites **green**.
    /// The row ends up switched on either way, so no assertion about the row can
    /// tell the two apart. That is the same gap `CaretAnchorTests` records: the
    /// values either side were pinned and the step between them was not.
    ///
    /// So the claim is checked where it lives, the way `CardOutcome`'s is —
    /// CLAUDE.md: *"Enforced by grep: none of `issueNumber|…| lastError =`
    /// appears in those three files."* One assignment, in `setRepoEnabled`, which
    /// is the writer Preflight's own toggle reaches.
    ///
    /// ⚠️ It is scoped to `AppModel.swift` and to the needle `isEnabled =`, so an
    /// unrelated `isEnabled` arriving on this model will trip it. That is the
    /// intended failure: whoever lands it either routes through the one writer or
    /// widens this gate on purpose, rather than growing a second one unnoticed.
    @Test("`isEnabled` is assigned in exactly one place, and that place is setRepoEnabled")
    func theSwitchHasOneWriter() throws {
        let code = try HiddenFaceState.code(of: "AppModel.swift")

        // A positive witness: a renamed writer would make the count below
        // meaningless rather than false.
        #expect(
            code.contains("func setRepoEnabled("),
            "AppModel no longer declares setRepoEnabled — this gate is reading the wrong file")

        let writes = code.components(separatedBy: "isEnabled =").count - 1
        #expect(
            writes == 1,
            """
            AppModel.swift assigns isEnabled \(writes) time(s); it may do so exactly once, inside \
            setRepoEnabled. The analysis footer's "Switch … on" is a screen that had only ever \
            read a Repo, and a second writer for one column is how two screens come to disagree \
            about it (#294).
            """)

        let body = try Self.body(of: "func setRepoEnabled(", in: code)
        #expect(
            body.contains("isEnabled ="),
            """
            the one assignment of isEnabled is not inside setRepoEnabled. The count above is then \
            satisfied by whichever writer happens to be the survivor (#294).
            """)
    }

    /// One function's body, by brace matching from its signature — the idiom
    /// `AnalysisPanelViewSourceTests` uses, and honest for the same reason: the
    /// function it is pointed at holds no braces inside a string literal.
    private static func body(of signature: String, in source: String) throws -> String {
        let start = try #require(source.range(of: signature))
        var depth = 0
        var open: String.Index?
        var index = start.upperBound
        while index < source.endIndex {
            if source[index] == "{" {
                if depth == 0 { open = source.index(after: index) }
                depth += 1
            } else if source[index] == "}" {
                depth -= 1
                if depth == 0, let open { return String(source[open..<index]) }
            }
            index = source.index(after: index)
        }
        Issue.record("no matching brace for \(signature)")
        return ""
    }

    @Test("Switching on a repository that has since been forgotten writes nothing")
    func enablingAForgottenRepositoryIsRefused() async throws {
        let store = try BoardStore.inMemory()
        let off = repo("off", enabled: false)
        try await store.saveRepo(off)

        let model = AppModel()
        model.testOnlySeed(repos: [], cards: [])
        model.testOnlySeedStore(store)

        await model.apply(.enable(repoID: off.id, name: "off"))

        #expect(try await store.repo(id: off.id)?.isEnabled == false)
    }

    /// ✅ The act already existed. This asserts that pressing the footer's button
    /// does the same three things #353 built for a card's badge — and it is
    /// asserted through `apply`, so a second implementation here would have to
    /// reproduce all three to pass.
    @Test("Showing Preflight unfolds the console, aims it, and opens the check")
    func showingPreflightReusesTheBadgesAct() async throws {
        let blocked = repo("blocked", preflight: .failing)
        let model = AppModel()
        model.testOnlySeed(repos: [blocked], cards: [])
        model.testOnlySeedChecks(repo: blocked.id, [check("repo.profile", "Repo profile", .fail)])
        model.selectedRepoID = blocked.id

        let fix = try #require(model.analysisRefusal?.fixes.first)
        await model.apply(fix)

        #expect(model.console.face == .preflight)
        #expect(model.preflightFocus == blocked.id)
        // `failing: false` is the point: the disclosure is open because the
        // reader was sent here, not because the default happens to agree.
        #expect(
            model.isCheckExpanded(
                CheckAddress(repoID: blocked.id, checkID: "repo.profile"), failing: false))
    }
}
