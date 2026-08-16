import ElliotModel
import ElliotProcess
import ElliotStore
import Foundation
import Testing

@testable import ElliotEngine

/// The harvester reads the **artifact or nothing**.
///
/// `ProposalHarvester` falls back to a fenced JSON block in the closing message,
/// and that is right for it: a proposal lands in a review queue a person reads.
/// An appraisal lands in a card field an unattended ranking sorts on, so prose
/// salvaged from a chat message would become a measurement. Leaving the card
/// unappraised and saying so is the better answer — the three failure tests
/// below are what says so.
@Suite("Appraisal harvester")
struct AppraisalHarvesterTests {

    private struct Fixture {
        var store: BoardStore
        var repo: Repo
        var card: Card
        var run: SkillRun
        var artifactURL: URL
        var root: URL

        func cleanUp() { try? FileManager.default.removeItem(at: root) }
    }

    /// A throwaway repository with one real file, so evidence resolution has
    /// something true and something false to tell apart.
    private func makeFixture() async throws -> Fixture {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("elliot-appraise-\(UUID().uuidString)", isDirectory: true)
        let sources = root.appendingPathComponent("Sources", isDirectory: true)
        try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
        try "// real".write(
            to: sources.appendingPathComponent("Real.swift"), atomically: true, encoding: .utf8)

        let store = try BoardStore.inMemory()
        let repo = Repo(path: root.path, nameWithOwner: "phmatray/Elliot", displayName: "Elliot")
        try await store.saveRepo(repo)

        let now = Date()
        let card = Card(
            repoID: repo.id, title: "A story", columnEnteredAt: now,
            createdAt: now, updatedAt: now
        )
        try await store.saveCard(card)

        let run = SkillRun.card(
            cardID: card.id, repoID: repo.id, kind: .appraiseCards, prompt: "…",
            cwd: repo.path,
            logPath: root.appendingPathComponent("run.ndjson").path,
            stderrPath: root.appendingPathComponent("run.log").path,
            createdAt: now
        )
        try await store.saveRun(run)

        return Fixture(
            store: store, repo: repo, card: card, run: run,
            artifactURL: root.appendingPathComponent("appraisal.json"),
            root: root
        )
    }

    @Test("A good artifact lands on the card, with evidence resolved")
    func harvestsFromArtifact() async throws {
        let fixture = try await makeFixture()
        defer { fixture.cleanUp() }

        try """
        {"effort":"small","evidence":["Sources/Real.swift:3","Sources/Nowhere.swift"]}
        """.write(to: fixture.artifactURL, atomically: true, encoding: .utf8)

        let report = await AppraisalHarvester(store: fixture.store).harvest(
            run: fixture.run, repo: fixture.repo, artifactURL: fixture.artifactURL
        )
        #expect(report.harvestSource == .artifact)
        #expect(report.kept == 1)
        #expect(report.dropped.isEmpty)

        let card = try #require(try await fixture.store.card(id: fixture.card.id))
        #expect(card.effort == .small)
        #expect(card.appraisedAt != nil)
        let evidence = try #require(card.evidence)
        #expect(evidence.count == 2)
        #expect(evidence[0].exists)
        #expect(evidence[1].exists == false)
    }

    @Test("No artifact leaves the card unappraised, and the report names the path")
    func noArtifact() async throws {
        let fixture = try await makeFixture()
        defer { fixture.cleanUp() }

        let report = await AppraisalHarvester(store: fixture.store).harvest(
            run: fixture.run, repo: fixture.repo, artifactURL: fixture.artifactURL
        )
        #expect(report.harvestSource == .none)
        #expect(report.kept == 0)
        #expect(report.dropped.contains { $0.contains(fixture.artifactURL.path) })

        let card = try #require(try await fixture.store.card(id: fixture.card.id))
        #expect(card.appraisedAt == nil)
        #expect(card.effort == nil)
        #expect(card.evidence == nil)
    }

    @Test("An artifact that cannot be read leaves the card unappraised, and names the failure")
    func unreadableArtifact() async throws {
        let fixture = try await makeFixture()
        defer { fixture.cleanUp() }
        // A directory at the artifact path forces a read failure without
        // chmod: `Data(contentsOf:)` throws rather than returning nothing, and
        // that is a different fact from "no artifact was written" — see
        // Override 2 in the task-9 handoff.
        try FileManager.default.createDirectory(
            at: fixture.artifactURL, withIntermediateDirectories: true)

        let report = await AppraisalHarvester(store: fixture.store).harvest(
            run: fixture.run, repo: fixture.repo, artifactURL: fixture.artifactURL
        )
        #expect(report.harvestSource == .none)
        #expect(report.kept == 0)
        #expect(report.dropped.contains { $0.contains("could not be read") })
        // Must not be confused with the "no artifact was written" sentence:
        // the file is right there, just unreadable as data.
        #expect(!report.dropped.contains { $0.contains("No artifact was written") })

        let card = try #require(try await fixture.store.card(id: fixture.card.id))
        #expect(card.appraisedAt == nil)
    }

    @Test("An empty artifact leaves the card unappraised, and says it was empty")
    func emptyArtifact() async throws {
        let fixture = try await makeFixture()
        defer { fixture.cleanUp() }
        try Data().write(to: fixture.artifactURL)

        let report = await AppraisalHarvester(store: fixture.store).harvest(
            run: fixture.run, repo: fixture.repo, artifactURL: fixture.artifactURL
        )
        #expect(report.harvestSource == .none)
        #expect(report.dropped.contains { $0.contains("empty") })
        #expect(try await fixture.store.card(id: fixture.card.id)?.appraisedAt == nil)
    }

    @Test("A malformed artifact leaves the card unappraised, and says what was wrong")
    func malformedArtifact() async throws {
        let fixture = try await makeFixture()
        defer { fixture.cleanUp() }
        try "this is not json".write(
            to: fixture.artifactURL, atomically: true, encoding: .utf8)

        let report = await AppraisalHarvester(store: fixture.store).harvest(
            run: fixture.run, repo: fixture.repo, artifactURL: fixture.artifactURL
        )
        #expect(report.harvestSource == .none)
        #expect(report.dropped.contains { $0.contains("not valid JSON") })
        #expect(try await fixture.store.card(id: fixture.card.id)?.appraisedAt == nil)
    }

    @Test("The closing message is never read, even when it holds a perfect answer")
    func neverFallsBackToResultText() async throws {
        let fixture = try await makeFixture()
        defer { fixture.cleanUp() }

        var run = fixture.run
        // `resultText` cannot be assigned directly — `SkillRun.setClosing(_:)`
        // is the one write path (`SkillRun.swift:257`) — but the point of this
        // test is unchanged: a run whose closing prose contains a plausible
        // appraisal must still yield nothing when no artifact was written.
        run.setClosing(
            ClosingRemark(
                text: """
                    I had a look. Here is the appraisal:

                    ```json
                    {"effort":"large","evidence":["Sources/Real.swift:1"]}
                    ```
                    """,
                source: .agent))
        try await fixture.store.saveRun(run)

        let report = await AppraisalHarvester(store: fixture.store).harvest(
            run: run, repo: fixture.repo, artifactURL: fixture.artifactURL
        )
        // The one difference from `ProposalHarvester`, asserted rather than
        // commented: a card left unappraised beats prose in a card field.
        #expect(report.harvestSource == .none)
        #expect(report.kept == 0)
        #expect(try await fixture.store.card(id: fixture.card.id)?.effort == nil)
    }

    @Test("\"appraised and found nothing\" is written, because it is a third state")
    func anEmptyAnswerIsStillAnAnswer() async throws {
        let fixture = try await makeFixture()
        defer { fixture.cleanUp() }

        try """
        {"effort":"unstated","evidence":[]}
        """.write(to: fixture.artifactURL, atomically: true, encoding: .utf8)

        let report = await AppraisalHarvester(store: fixture.store).harvest(
            run: fixture.run, repo: fixture.repo, artifactURL: fixture.artifactURL
        )
        #expect(report.harvestSource == .artifact)
        #expect(report.kept == 1)

        let card = try #require(try await fixture.store.card(id: fixture.card.id))
        // `appraisedAt` is the third state. Without it, "nobody has appraised
        // this card" and "this card was appraised and carries no signal" are the
        // same value, and PR2's `CardValue` cannot tell `.neverAppraised` from
        // `.ungradeable`.
        #expect(card.appraisedAt != nil)
        #expect(card.effort == .unstated)
        #expect(card.evidence == [])
    }

    @Test("Decoder complaints reach the report rather than being swallowed")
    func droppedReasonsSurvive() async throws {
        let fixture = try await makeFixture()
        defer { fixture.cleanUp() }
        try """
        {"effort":"small","evidence":["Sources/Real.swift",7]}
        """.write(to: fixture.artifactURL, atomically: true, encoding: .utf8)

        let report = await AppraisalHarvester(store: fixture.store).harvest(
            run: fixture.run, repo: fixture.repo, artifactURL: fixture.artifactURL
        )
        #expect(report.kept == 1)
        #expect(report.dropped.contains { $0.contains("Citation 2") })
    }

    @Test("A run with no card is reported, not crashed on")
    func aCardlessRunIsReported() async throws {
        let fixture = try await makeFixture()
        defer { fixture.cleanUp() }
        try """
        {"effort":"small","evidence":[]}
        """.write(to: fixture.artifactURL, atomically: true, encoding: .utf8)

        var run = fixture.run
        run.cardID = nil
        let report = await AppraisalHarvester(store: fixture.store).harvest(
            run: run, repo: fixture.repo, artifactURL: fixture.artifactURL
        )
        #expect(report.harvestSource == .none)
        #expect(report.dropped.contains { $0.contains("no card") })
    }

    @Test("A card deleted mid-run is reported, not crashed on")
    func aDeletedCardIsReported() async throws {
        let fixture = try await makeFixture()
        defer { fixture.cleanUp() }
        try """
        {"effort":"small","evidence":[]}
        """.write(to: fixture.artifactURL, atomically: true, encoding: .utf8)
        try await fixture.store.deleteCard(id: fixture.card.id)

        let report = await AppraisalHarvester(store: fixture.store).harvest(
            run: fixture.run, repo: fixture.repo, artifactURL: fixture.artifactURL
        )
        #expect(report.harvestSource == .none)
        #expect(report.dropped.contains { $0.contains("could not be found") })
    }
}

/// The routing in `RunScheduler.finish`, read out of the source.
///
/// In the idiom of `DrainDuplicationTests` and `RunSchedulerShapeTests`: what is
/// under test is a **shape** no behavioural test can pin, because a boolean that
/// happened to route correctly today would pass every one of them. The shape is
/// what stops the next kind from silently joining a branch — `if updated.isAnalysis`
/// sent an appraisal into `completeCardRun`, which asks `gh` about an issue and a
/// pull request the card does not have.
///
/// ⚠️ **Scoped, and measured against comment-stripped source.** The task brief
/// asked for `!text.contains("default:")` and `!text.contains("if updated.isAnalysis")`
/// over the whole 800-line file. Both would be tripped by prose rather than by
/// code: a `default:` in a `switch` over some unrelated enum is none of this
/// suite's business, and a doc comment explaining *why* the boolean was removed
/// is exactly the sentence the next reader needs and exactly the string a
/// whole-file gate forbids. This repository has already paid for a string gate
/// over prose — CLAUDE.md's `no CI` grep, which returns innocent hits inside
/// frozen fixtures that must not be "corrected". So every assertion here is
/// scoped to the body of the function it is about, and every one of them reads
/// source with `//` comments removed, the way `RunSchedulerShapeTests` and
/// `AppraisalTransactionShapeTests` already do.
///
/// The exhaustiveness itself is the **compiler's** guarantee, not this suite's: a
/// sixth `SkillKind` fails to build at that `switch`. What these tests pin is
/// that the `switch` is still there to fail — a `default:` slipped into it, or a
/// reversion to a boolean, would hand a new kind a silent wrong branch instead.
@Suite("Scheduler finish — routing")
struct SchedulerFinishRoutingTests {

    /// Three deletions, not two: this file is
    /// `ElliotKit/Tests/ElliotEngineTests/AppraisalHarvesterTests.swift`, and
    /// `Sources/` is a sibling of `Tests/` under `ElliotKit`. The same climb
    /// `RunSchedulerShapeTests` makes.
    private static let source: String = {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // ElliotEngineTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // ElliotKit
            .appendingPathComponent("Sources/ElliotEngine/RunScheduler.swift")
        return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }()

    /// The source with `//` line comments removed, so these tests measure code
    /// and not prose. A source-shape test a comment can turn red teaches
    /// everyone to delete the comment.
    private static let code: String = {
        source
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> String in
                guard let marker = line.range(of: "//") else { return String(line) }
                return String(line[..<marker.lowerBound])
            }
            .joined(separator: "\n")
    }()

    /// The body of a declaration at four-space indentation, up to the next
    /// declaration at that same indentation.
    ///
    /// Closes on the *nearest* following `private`/`static`/`public func` rather
    /// than balancing braces — the choice `RunSchedulerShapeTests` and
    /// `AppraisalTransactionShapeTests` both make, for the reason they both give:
    /// brace-balancing text miscounts a brace inside a string literal. `min()`
    /// over the three anchors rather than `??`, because `??` takes the first
    /// *kind* of anchor that matches anywhere below, which need not be the
    /// nearest one.
    ///
    /// An anchor that stops matching returns `""`, and every test below asserts
    /// the slice is non-empty with a message naming the parser — so a renamed
    /// function fails as "fix this test", never as "the invariant moved".
    private static func body(after signature: String) -> String {
        guard let begin = code.range(of: signature) else { return "" }
        let rest = code[begin.upperBound...]
        let ends = ["\n    private func ", "\n    static func ", "\n    public func "]
            .compactMap { rest.range(of: $0)?.lowerBound }
        guard let end = ends.min() else { return String(rest) }
        return String(rest[..<end])
    }

    private static var finishBody: String {
        body(after: "private func finish(run: SkillRun, outcome: AgentRunOutcome?) async {")
    }

    private static var startBody: String {
        body(after: "private func start(_ run: SkillRun) async {")
    }

    @Test("finish routes on the kind, not on a boolean")
    func routingIsASwitch() {
        let body = Self.finishBody
        #expect(
            !body.isEmpty,
            "finish(run:outcome:) moved or was reworded — this test's parser needs updating, not deleting"
        )
        #expect(
            body.contains("switch updated.kind {"),
            """
            `finish` no longer routes on `run.kind`. Whatever it routes on instead, \
            the compiler has stopped being the guard: a sixth `SkillKind` will join \
            an existing branch silently rather than failing to build.
            """
        )
        // The boolean survives as `SkillRun.isAnalysis` for readers that
        // genuinely mean "an analysis" — but nothing in `finish` may route on
        // it. It is what sent an appraisal into `completeCardRun`.
        #expect(
            !body.contains("isAnalysis"),
            """
            `finish` reads `isAnalysis` again. That boolean answers "is this kind \
            `.analyzeRepo`", which is a *different* question from "may this kind \
            only read" — an appraisal is read-only and is not an analysis, and \
            routing on the boolean sent it into `completeCardRun`, where `gh` is \
            asked about an issue and a pull request the card does not have.
            """
        )
    }

    @Test("Every kind is named in the routing, so a sixth is a compile error")
    func routingNamesEveryKind() {
        let body = Self.finishBody
        #expect(
            !body.isEmpty,
            "finish(run:outcome:) moved or was reworded — this test's parser needs updating, not deleting"
        )
        #expect(body.contains("case .analyzeRepo:"))
        #expect(body.contains("case .appraiseCards:"))
        #expect(body.contains("case .createIssue, .implementIssue, .mergePR:"))
        // Scoped to `finish`, not to the file: a `default:` in some other
        // switch over some other enum is none of this test's business, and
        // saying otherwise is how a shape gate starts failing for reasons that
        // have nothing to do with its subject.
        #expect(
            !body.contains("default:"),
            """
            `finish`'s routing carries a `default:`. That is precisely what stops \
            the compiler catching a sixth `SkillKind` here — the new kind falls \
            into whichever branch the default names, silently, and the completion \
            it never reaches is the one that would have written its result.
            """
        )
    }

    @Test("The card arm still hands the resume verdict to completeCardRun")
    func theCardArmKeepsTheResumeVerdict() {
        let body = Self.finishBody
        #expect(
            !body.isEmpty,
            "finish(run:outcome:) moved or was reworded — this test's parser needs updating, not deleting"
        )
        #expect(
            body.contains("completeCardRun(&updated, resume: resume)"),
            """
            The card arm no longer passes `resume:`. `ResumeVerdict` is computed in \
            `finish` because that is the only place the terminal result exists — \
            `numTurns` and `errors` live on `outcome.result` and are gone by the \
            time anything downstream sees the row. Dropping the argument does not \
            skip a verification, it verifies without knowing the resume failed.
            """
        )
    }

    /// The same leak, one dictionary over, and the reason this gate is written rather than trusted
    /// to prose: `cancelRequested` is exactly `treeBaselines`' shape — a per-run entry with one
    /// erasure — and it arrived with the switchover to ACP, where the process no longer carries a
    /// `wasTerminated` flag and Elliot's own memory is the only thing that can tell a cancel from
    /// a crash.
    ///
    /// ⛔ **Two insert sites would be the defect, not one.** `cancel(runID:)` has three branches
    /// and only the **live** one reaches `finish`: a queued run goes through `discardQueued` and
    /// returns, an orphan row is written `.cancelled` in place and returns. An insert at the top of
    /// that method leaks one entry per queued-or-orphan cancel for the life of the process — and
    /// leaks it *silently*, since nothing downstream reads a set it never gets to.
    @Test("A requested cancel is recorded at one site and erased unconditionally")
    func cancelRequestedIsErasedOnce() {
        let code = Self.code
        let inserts = code.components(separatedBy: "cancelRequested.insert").count - 1
        let removals = code.components(separatedBy: "cancelRequested.remove(").count - 1
        #expect(
            inserts == 1,
            """
            cancelRequested is inserted at \(inserts) sites, not the 1 on `cancel`'s live branch. \
            Only that branch reaches `finish`, which is the only erasure.
            """
        )
        #expect(removals == 1, "cancelRequested is erased at \(removals) sites, not the 1 in `finish`")

        let body = Self.finishBody
        #expect(
            !body.isEmpty,
            "finish(run:outcome:) moved or was reworded — this test's parser needs updating, not deleting"
        )
        guard let removal = body.range(of: "cancelRequested.remove("),
              let routing = body.range(of: "switch updated.kind {")
        else {
            Issue.record(
                """
                finish no longer erases the cancel request above a `switch updated.kind` \
                — parser or invariant moved
                """
            )
            return
        }
        #expect(
            removal.lowerBound < routing.lowerBound,
            """
            The cancel request is erased inside a branch of the routing rather than above it. \
            Every kind that does not take that branch then leaves its entry behind for the \
            lifetime of the process.
            """
        )
        // And it is erased before the state is decided, because `state(for:cancelRequested:)` is
        // what consumes it: an erasure *after* the fold would hand every cancelled run `false`.
        guard let fold = body.range(of: "Self.state(for: outcome, cancelRequested:") else {
            Issue.record("finish no longer folds the outcome through `state(for:cancelRequested:)`")
            return
        }
        #expect(removal.lowerBound < fold.lowerBound)
    }

    @Test("The tree baseline is erased once, above the routing")
    func baselineIsErasedOnce() {
        let code = Self.code
        // Exactly three sites — the two in `start` and the erasure in `finish`.
        // A fourth path that returned without erasing would leak one entry per
        // run for the lifetime of the process.
        let writes = code.components(separatedBy: "treeBaselines[run.id]").count - 1
        let removals = code.components(separatedBy: "treeBaselines.removeValue").count - 1
        #expect(writes == 2, "treeBaselines is written at \(writes) sites, not the 2 in `start`")
        #expect(removals == 1, "treeBaselines is erased at \(removals) sites, not the 1 in `finish`")

        let body = Self.finishBody
        #expect(
            !body.isEmpty,
            "finish(run:outcome:) moved or was reworded — this test's parser needs updating, not deleting"
        )
        guard let removal = body.range(of: "treeBaselines.removeValue"),
              let routing = body.range(of: "switch updated.kind {")
        else {
            Issue.record(
                """
                finish no longer erases the baseline above a `switch updated.kind` \
                — parser or invariant moved
                """
            )
            return
        }
        #expect(
            removal.lowerBound < routing.lowerBound,
            """
            The baseline is erased inside a branch of the routing rather than above \
            it. Every kind that does not take that branch then leaves its entry \
            behind for the lifetime of the process.
            """
        )
        // And it is no longer erased inside `completeAnalysisRun`: that method
        // takes the baseline as a parameter now, so both read-only completions
        // are handed the same value by the one site that owns it.
        #expect(
            code.contains("baseline: String?"),
            "the read-only completions no longer take the baseline as a parameter"
        )
    }

    @Test("The git sentinel is folded on once, by one function both read-only kinds call")
    func theSentinelIsNotCopied() {
        let code = Self.code
        // The lines that fold the sentinel onto a report exist once. Two copies
        // is the shape #146 caught in `ChildProcess`: when the *explanation* of
        // an invariant has been copied word for word, the invariant has been
        // copied too.
        let folds = code.components(separatedBy: "report.workingTreeChanged = changed").count - 1
        #expect(folds == 1, "the sentinel fold exists at \(folds) sites, not 1")
        #expect(code.contains("private func sealSentinel("), "sealSentinel is gone")

        let analysis = Self.body(after: "private func completeAnalysisRun(")
        let appraisal = Self.body(after: "private func completeAppraisalRun(")
        #expect(
            !analysis.isEmpty && !appraisal.isEmpty,
            "one of the read-only completions moved or was reworded — this test's parser needs updating"
        )
        #expect(analysis.contains("sealSentinel("), "completeAnalysisRun no longer answers the sentinel")
        #expect(appraisal.contains("sealSentinel("), "completeAppraisalRun no longer answers the sentinel")
    }

    @Test("The sentinel is armed on the kind being read-only, not on it being an analysis")
    func theSentinelIsArmedOnTheKind() {
        let body = Self.startBody
        #expect(
            !body.isEmpty,
            "start(_:) moved or was reworded — this test's parser needs updating, not deleting"
        )
        #expect(
            body.contains("if updated.kind.isReadOnly {"),
            """
            `start` no longer arms the working-tree sentinel on `kind.isReadOnly`. \
            An appraisal reads the working tree exactly as an analysis does, and \
            the prompt forbidding a write is an instruction no CLI flag enforces — \
            without the baseline its report says the tree was never looked at.
            """
        )
        #expect(
            !body.contains("isAnalysis"),
            "`start` arms the sentinel on `isAnalysis` again, which is false for an appraisal"
        )
    }
}
