import ElliotModel
import Foundation
import Testing

@testable import ElliotAppKit

/// ⛔ **The half of this change no behavioural test can reach.**
///
/// Measured by break-testing rather than assumed: replacing
/// `AnalysisRefusal.decide`'s call to `UnattendedStartRefusal.refusal(…)` with the
/// two guards written out again — `if !subject.isEnabled` … `if
/// subject.preflightVerdict == .failing` — left **all 2416 tests in 278 suites
/// green**. Every value either side of the delegation is pinned, and the step
/// between them was not, which is `CaretAnchorTests`' finding restated: the
/// arithmetic was pure, extracted and tested, and the decoration still never
/// appeared.
///
/// It matters here because the whole point of the rule is that three callers —
/// this screen, `AnalysisService` and the appraisal, the last of which passes
/// through no board transition at all — consult one answer. A second copy in the
/// screen is not a cosmetic regression: it is the shape that let `isBlocking` be
/// asserted in three documents and implemented in none.
///
/// The same break, one layer over: pasting the sentence back into
/// `Consequence.reason` also leaves everything green, because the two strings are
/// then equal — and the two suites that used to hold them together now compare
/// `refusal?.text == Consequence.reason(.repoDisabled)`, which reads the *same*
/// string on both sides and can no longer tell them apart.
@Suite("One rule for an unattended start")
struct UnattendedStartDelegationTests {

    /// The two sentences, verbatim, as the literals a second copy would be.
    ///
    /// Written out here rather than read off `UnattendedStartRefusal` on purpose:
    /// a gate whose needle comes from the code it is inspecting agrees with that
    /// code by construction.
    private static let sentences = [
        "This repository is switched off in Preflight.",
        "A Preflight check is failing for this repository — fix it there first.",
    ]

    /// The sentence the ruling deliberately kept out of the rule.
    private static let pickerSentence = "Pick a single repository to analyse."

    private func repo(_ name: String, enabled: Bool = true, preflight: PreflightState? = nil) -> Repo
    {
        Repo(
            path: "/tmp/\(name)", nameWithOwner: "o/\(name)", displayName: name,
            isEnabled: enabled, preflight: preflight
        )
    }

    // MARK: - What asking the rule actually changed

    /// ⛔ **The one new guarantee this change makes, and the break that found it
    /// unguarded.**
    ///
    /// `decide` used to key its preflight branch on `blocked != nil` — the badge's
    /// *presence* — so a repository whose persisted verdict is `.failing` arriving
    /// with no badge was refused **nothing at all**. That is a gate opening on an
    /// absent value, which is the shape the whole task exists to remove; it is now
    /// keyed on the rule's verdict.
    ///
    /// Measured: restoring the old form (`guard let blocked else { return nil }`)
    /// left **2419/2419 green**. `AnalysisRefusalTests.aVerdictWithoutAReadingStillOffersTheWay`
    /// looks like the covering test and is not — it drives `AppModel`, where
    /// `blockedBadge` returns non-`nil` for every `.failing` verdict, so the
    /// `blocked == nil` path is unreachable from there. This one calls `decide`
    /// directly, which is the only way to reach it.
    ///
    /// ⚠️ **Both halves are deliberate.** The refusal is the point; the *empty*
    /// `fixes` is the honest consequence and not an accident — `AnalysisRefusal.fixes`
    /// already documents empty as a real answer ("the explanation is `text`, and it
    /// stands alone"), and there is nothing to offer, because `.showPreflight`
    /// needs the badge that did not arrive. Refusing while inventing a fix, or
    /// permitting because no fix could be named, are both worse.
    @Test("A failing verdict with no badge is still refused, with nothing to offer")
    func aFailingVerdictRefusesEvenWithNoBadgeToOffer() throws {
        let blocked = repo("blocked", preflight: .failing)

        let refusal = try #require(
            AnalysisRefusal.decide(subject: blocked, registered: [blocked], blocked: nil),
            """
            decide permitted an analysis in a repository whose persisted Preflight verdict is \
            failing, because no BlockedBadge came with it. The badge is the remedy; the verdict is \
            the gate. Keyed on the badge, this is a gate that opens on an absent value — eight \
            unattended runs at bypassPermissions inside a checkout Elliot has diagnosed as broken.
            """)

        #expect(refusal.text == Self.sentences[1])
        #expect(refusal.fixes.isEmpty)

        // The positive witness for the other half: the same verdict *with* a badge
        // still carries the way to the finding, so the claim above is about the
        // gate and not about having quietly dropped the remedy.
        let badge = BlockedBadge(repoID: blocked.id, check: nil)
        #expect(
            AnalysisRefusal.decide(subject: blocked, registered: [blocked], blocked: badge)?.fixes
                == [.showPreflight(badge)])
    }

    /// ⛔ The screen renders the rule; it does not re-decide it.
    @Test("The analysis refusal asks the rule rather than re-implementing its guards")
    func theScreenAsksTheRule() throws {
        let code = try HiddenFaceState.code(of: "AnalysisRefusal.swift")

        // Positive witnesses: a renamed decider would make every claim below
        // vacuously true and this suite would go green having read nothing.
        #expect(
            code.contains("static func decide("),
            "AnalysisRefusal no longer declares decide( — this gate is reading the wrong thing")

        let body = try Self.body(of: "static func decide(", in: code)
        #expect(
            body.contains("UnattendedStartRefusal.refusal("),
            """
            AnalysisRefusal.decide does not consult UnattendedStartRefusal. Whether an unattended \
            agent may start against a repository is one rule with three askers — this screen, \
            AnalysisService, and the appraisal, which passes through no transition and so has no \
            evaluateMove to be asked in. A second copy here is how the two come to disagree.
            """)

        // The guards themselves, which belong to the rule and not to the screen.
        // `subject.preflightVerdict` is deliberately *not* a needle: passing the
        // persisted verdict in is the delegation, not a second opinion.
        for needle in ["isEnabled", ".failing", ".passing", ".notChecked"] {
            #expect(
                !body.contains(needle),
                Comment(
                    rawValue: """
                        AnalysisRefusal.decide reads \(needle). That is the rule's own guard \
                        re-derived in a view module — UnattendedStartRefusal.refusal(repo:preflight:) \
                        answers it, in evaluateMove's order, with the reasons written beside it. \
                        Widen this gate deliberately if the screen genuinely needs the token; do \
                        not let a second rule grow here unnoticed.
                        """))
        }
    }

    /// ⛔ **The second caller, held the same way — and the reason the sweep now
    /// crosses a module boundary.**
    ///
    /// This suite lives in `ElliotAppKitTests` because its first subject was a
    /// screen, and it read `Sources/ElliotAppKit` alone. `AnalysisService.start`
    /// is the other caller of the same rule and it is in `ElliotEngine`, so a
    /// gate that stopped at the module edge would hold the *cheaper* half: the
    /// screen refuses a press, this one refuses up to eight unattended `claude
    /// -p` runs at `bypassPermissions`. `swiftSources()` already enumerates the
    /// whole of `Sources/` for ``eachSentenceHasOneHome``; this reads one file
    /// out of it rather than adding a second walk.
    ///
    /// ⚠️ **A source gate, because no behavioural test can reach this either.**
    /// Measured, not assumed: writing the two guards back out inside `start` —
    /// `guard repo.isEnabled` … `if await gate.verdict(for: repo) == .failing` —
    /// leaves every test in `AnalysisServiceTests` green, because the values
    /// either side of the delegation are identical. That is
    /// ``theScreenAsksTheRule``'s finding one module over, and `CaretAnchorTests`'
    /// before it.
    @Test("The analysis service asks the rule rather than re-implementing its guards")
    func theServiceAsksTheRule() throws {
        let sources = try Self.swiftSources()
        let file = try #require(
            sources.first { $0.name == "AnalysisService.swift" && $0.module == "ElliotEngine" },
            "the sweep did not find AnalysisService in ElliotEngine — it is reading the wrong tree")
        let code = HiddenFaceState.stripped(file.source)

        // Positive witness: a renamed or moved `start` would make every claim
        // below vacuously true and this gate would go green having read nothing.
        #expect(
            code.contains("public func start("),
            "AnalysisService no longer declares start( — this gate is reading the wrong thing")

        let body = try Self.body(of: "public func start(", in: code)
        #expect(
            body.contains("UnattendedStartRefusal.refusal("),
            """
            AnalysisService.start does not consult UnattendedStartRefusal. Whether an unattended \
            agent may start against a repository is one rule with three askers — the analysis \
            panel, this service, and the appraisal — and this is the asker that spawns up to eight \
            agents at bypassPermissions inside a real checkout. A second copy here is how the \
            board's answer and the service's come to disagree.
            """)

        // The guards themselves. `gate.verdict(for:)` is deliberately not a
        // needle: handing the rule a measured verdict *is* the delegation.
        for needle in ["isEnabled", ".failing", ".passing", ".notChecked"] {
            #expect(
                !body.contains(needle),
                Comment(
                    rawValue: """
                        AnalysisService.start reads \(needle). That is the rule's own guard \
                        re-derived in a service — UnattendedStartRefusal.refusal(repo:preflight:) \
                        answers it, in evaluateMove's order, with the reasons written beside it. \
                        Short-circuiting the gate to save a Preflight sweep needs exactly this \
                        knowledge, and that is a second copy of an ordering.
                        """))
        }
    }

    /// ⛔ **The third caller, and the only one that reaches an unattended agent
    /// through no transition and no gesture at all.**
    ///
    /// `AnalysisRefusal` refuses a press and `AnalysisService.start` refuses
    /// behind a panel somebody pressed. An appraisal is started by neither: it
    /// passes through no board transition, so `evaluateMove`,
    /// `MoveOrigin.allowsSideEffects` and the move's own preflight never see it,
    /// and this rule is the entirety of its guard. Of the three callers it is the
    /// one where a second copy could disagree with the board and nothing on the
    /// board would ever say so.
    ///
    /// ⚠️ **Measured in both directions, not assumed.** Replacing the call to
    /// `UnattendedStartRefusal.refusal(…)` inside `appraise` with the two guards
    /// written out faithfully — `if !repo.isEnabled` … `if await
    /// gate.verdict(for: repo) == .failing` — leaves **2452/2452 green**:
    /// `AppraisalServiceTests` pins both arms of the gate and the order between
    /// them, so every value either side of the delegation is held and only the
    /// step between them was not. Against that break this gate reports **three**
    /// issues; against the real source it passes. That is
    /// ``theScreenAsksTheRule``'s finding a second module over, and
    /// `CaretAnchorTests`' before it.
    @Test("The appraisal service asks the rule rather than re-implementing its guards")
    func theAppraisalServiceAsksTheRule() throws {
        let sources = try Self.swiftSources()
        let file = try #require(
            sources.first { $0.name == "AppraisalService.swift" && $0.module == "ElliotEngine" },
            "the sweep did not find AppraisalService in ElliotEngine — it is reading the wrong tree")
        let code = HiddenFaceState.stripped(file.source)

        // Positive witness: a renamed or moved `appraise` would make every claim
        // below vacuously true and this gate would go green having read nothing.
        #expect(
            code.contains("public func appraise("),
            "AppraisalService no longer declares appraise( — this gate is reading the wrong thing")

        let body = try Self.body(of: "public func appraise(", in: code)
        #expect(
            body.contains("UnattendedStartRefusal.refusal("),
            """
            AppraisalService.appraise does not consult UnattendedStartRefusal. Whether an \
            unattended agent may start against a repository is one rule with three askers — the \
            analysis panel, AnalysisService, and this one, which spawns a claude -p at \
            bypassPermissions inside a real checkout without passing through a transition or a \
            gesture. A second copy here is the one no board behaviour can contradict.
            """)

        // The guards themselves. `gate.verdict(for:)` is deliberately not a
        // needle: handing the rule a measured verdict *is* the delegation.
        for needle in ["isEnabled", ".failing", ".passing", ".notChecked"] {
            #expect(
                !body.contains(needle),
                Comment(
                    rawValue: """
                        AppraisalService.appraise reads \(needle). That is the rule's own guard \
                        re-derived in a service — UnattendedStartRefusal.refusal(repo:preflight:) \
                        answers it, in evaluateMove's order, with the reasons written beside it. \
                        Skipping the sweep for a repository already switched off needs exactly \
                        this knowledge, and that is a second copy of an ordering.
                        """))
        }
    }

    @Test("A refused move reads the rule's sentence rather than keeping a copy")
    func theMoveRefusalReadsTheRule() throws {
        let code = try HiddenFaceState.code(of: "Consequence.swift")

        #expect(
            code.contains("static func reason("),
            "Consequence no longer declares reason( — this gate is reading the wrong thing")

        let body = try Self.body(of: "static func reason(", in: code)
        #expect(
            body.contains("UnattendedStartRefusal.repoDisabled.sentence"),
            """
            Consequence.reason(.repoDisabled) no longer reads the rule's sentence. A refused move \
            and a refused unattended start are different questions, but on this case they are the \
            same fact about the same switch — and the assertions in AnalysisRefusalTests and \
            AnalysisSessionTests compare refusal text *against this function*, so two copies here \
            make those comparisons tautologies rather than gates.
            """)
    }

    /// Each sentence exists once in the package, and that once is the rule.
    ///
    /// ⚠️ **Comments are cut, and that is load-bearing rather than defensive.**
    /// Measured: `ElliotAppKit/RunsPane.swift` documents *"a card whose repository
    /// is switched off in Preflight"*, so a gate over raw text fails on prose that
    /// is not a copy of anything. CLAUDE.md's #186 entry states the general form —
    /// a string gate over prose *"can tell neither a claim from a mention nor a
    /// live claim from a quoted one"*.
    @Test("Each sentence has exactly one home, and it is the rule in ElliotModel")
    func eachSentenceHasOneHome() throws {
        let sources = try Self.swiftSources()

        // A negative needs its positive witness: an empty sweep would make the
        // claim below true of nothing at all.
        #expect(
            sources.count > 50,
            "swept only \(sources.count) Swift sources — this gate is reading the wrong directory")

        for sentence in Self.sentences {
            let holders = sources
                .filter { HiddenFaceState.stripped($0.source).contains(sentence) }
                .map(\.name)
            let where_ = holders.isEmpty ? "no source at all" : holders.joined(separator: " · ")

            #expect(
                holders == ["UnattendedStartRefusal.swift"],
                Comment(
                    rawValue: """
                        "\(sentence)" is written in \(where_). It belongs to \
                        UnattendedStartRefusal, once: four surfaces read it — the toolbar tooltip, \
                        the analysis footer, a refused move's caption, and any service that refuses \
                        a start — and a second copy is a reword that lands on some of them.
                        """))
        }
    }

    /// ⛔ **The picker's sentence stayed out of the rule, and that was a decision.**
    ///
    /// "Which repository" is a question a picker has and a service does not — an
    /// appraisal is handed a card, `AnalysisService.start` a `repoID` — so in
    /// `UnattendedStartRefusal` it would be a case `refusal(repo:preflight:)` can
    /// never return, forcing two services to switch over a state they cannot be in.
    /// This holds the decision from the side that can be held: the sentence has no
    /// home in `ElliotModel`.
    ///
    /// ⚠️ **It is deliberately *not* asserted to have exactly one home, unlike the
    /// two above, and the reason is a measurement rather than caution.** It has
    /// two: `AnalysisRefusal.decide` and `BoardView.analysisPanelLabel:1648`, which
    /// composes it into an accessibility label — *"Analysis. Pick a single
    /// repository to analyse."* That is a real duplication and a real drift risk (a
    /// reword lands on the footer and not on VoiceOver), it pre-dates this change,
    /// and closing it means deciding whether the label composes the refusal's
    /// sentence — a change to a `body`'s vocabulary that belongs in its own pass.
    /// A gate that blessed the pair would be worse than this one; a gate that
    /// failed on unmodified `main` would be worse still.
    @Test("The picker's sentence has no home in the rule's module")
    func thePickerSentenceStaysOutOfTheRule() throws {
        let sources = try Self.swiftSources()
        let inModel = sources
            .filter { $0.module == "ElliotModel" }
            .filter { HiddenFaceState.stripped($0.source).contains(Self.pickerSentence) }
            .map(\.name)

        // Positive witness: the sweep can see ElliotModel at all.
        #expect(
            sources.contains { $0.name == "UnattendedStartRefusal.swift" && $0.module == "ElliotModel" },
            "the sweep did not find the rule in ElliotModel — it is reading the wrong tree")

        #expect(
            inModel.isEmpty,
            Comment(
                rawValue: """
                    "\(Self.pickerSentence)" is written in ElliotModel \
                    (\(inModel.joined(separator: " · "))). \
                    Whether a repository is picked is not a fact about a repository, and a service \
                    handed one cannot be in that state — a rule case no rule returns is a branch \
                    every caller must write and none can reach.
                    """))
    }

    // MARK: - Reading the package

    /// Every `.swift` file under `Sources/`, by name, owning module and content.
    ///
    /// Discovered rather than listed, so a module added tomorrow is covered on the
    /// day it is created — which is the only day the mistake is easy to make. The
    /// module is the first path component under `Sources/`, which is what SwiftPM's
    /// own layout guarantees here.
    private static func swiftSources() throws -> [(name: String, module: String, source: String)] {
        let root = HiddenFaceState.viewSources.deletingLastPathComponent()  // …/Sources
        let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: nil)
        var found: [(name: String, module: String, source: String)] = []
        while let url = enumerator?.nextObject() as? URL {
            guard url.pathExtension == "swift" else { continue }
            let module =
                url.pathComponents.dropFirst(root.pathComponents.count).first ?? ""
            found.append(
                (url.lastPathComponent, module, try String(contentsOf: url, encoding: .utf8)))
        }
        return found.sorted { $0.name < $1.name }
    }

    /// Brace matching from a signature, through the one implementation.
    ///
    /// ⚠️ **Not a fourth copy of the walk.** `HiddenFaceState` owns the parse — its
    /// own header says the parse lives there and the judgement does not — and the
    /// three pre-existing copies are named in its doc comment along with why they
    /// are not folded in here.
    private static func body(of signature: String, in source: String) throws -> String {
        try HiddenFaceState.body(of: signature, in: source)
    }
}
