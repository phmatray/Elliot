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

            #expect(
                holders == ["UnattendedStartRefusal.swift"],
                Comment(
                    rawValue: """
                        "\(sentence)" is written in \(holders.isEmpty ? "no source" : holders.joined(separator: " · ")). \
                        It belongs to UnattendedStartRefusal, once: four surfaces read it — the \
                        toolbar tooltip, the analysis footer, a refused move's caption, and any \
                        service that refuses a start — and a second copy is a reword that lands on \
                        some of them.
                        """))
        }
    }

    // MARK: - Reading the package

    /// Every `.swift` file under `Sources/`, by name and content.
    ///
    /// Discovered rather than listed, so a module added tomorrow is covered on the
    /// day it is created — which is the only day the mistake is easy to make.
    private static func swiftSources() throws -> [(name: String, source: String)] {
        let root = HiddenFaceState.viewSources.deletingLastPathComponent()  // …/Sources
        let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: nil)
        var found: [(name: String, source: String)] = []
        while let url = enumerator?.nextObject() as? URL {
            guard url.pathExtension == "swift" else { continue }
            found.append((url.lastPathComponent, try String(contentsOf: url, encoding: .utf8)))
        }
        return found.sorted { $0.name < $1.name }
    }

    /// One function's body, by brace matching from its signature — the idiom
    /// `AnalysisRefusalTests` and `AnalysisPanelViewSourceTests` both use, and
    /// honest for the same reason: the functions it is pointed at hold no braces
    /// inside a string literal, and comments are already cut.
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
}
