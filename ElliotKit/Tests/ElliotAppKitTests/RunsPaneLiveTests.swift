import AppKit
import ElliotEngine
import ElliotModel
import ElliotProcess
import ElliotStore
import Foundation
import SwiftUI
import TestSupport
import Testing

@testable import ElliotAppKit

/// What a test can hold of the runs pane.
///
/// Not the pixels — `swift test` cannot see where a chip sits, and this project
/// has paid for pretending otherwise four times (#47, #50, #52, #53). What it
/// *can* see is the thing criterion 16 is actually about: that the log stopped
/// being a wall of identical lines and became one typed row per event kind, and
/// that those rows exist **while a run is still going** rather than only in the
/// file it leaves behind.
///
/// So the centrepiece drives `Scripts/fake-claude.sh` through the real
/// scheduler — a real `Process`, a real stdout pipe, the real NDJSON decoder —
/// and reads the rows out of the live tail before the run has finished. A test
/// built on hand-written `StreamEvent`s would pass with the spawn broken.
///
/// ### Why this suite lives in `ElliotAppKitTests`
///
/// The obvious home is `ElliotEngineTests`, next to `EndToEndTests` and its
/// `Stack`. It does not compile there: `Package.swift` gives that target
/// `["ElliotEngine", "TestSupport"]` and nothing more, so `RunsPane`,
/// `LogRowAccessibility` and `VerdictBlock` are all out of reach — and because
/// `swift test --filter` exits 0 when it matches nothing, the mistake would
/// have read as six unrelated tests passing. `ElliotAppKitTests` has
/// `ElliotAppKit`, which depends on `ElliotEngine`, `ElliotProcess` and
/// `ElliotStore`, so the whole stack is reachable from here and no dependency
/// edge had to be added.
@Suite("Runs pane, live")
struct RunsPaneLiveTests {

    // MARK: - Paths

    /// Fixtures and the fake tool live at the repository root, not in a resource
    /// bundle: the same files are usable by hand from a terminal when
    /// reproducing a run.
    private static let repoRoot: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // ElliotAppKitTests
        .deletingLastPathComponent()   // Tests
        .deletingLastPathComponent()   // ElliotKit
        .deletingLastPathComponent()   // repo root

    private static var fakeClaude: String {
        repoRoot.appendingPathComponent("Scripts/fake-claude.sh").path
    }

    private static func fixture(_ name: String) -> String {
        repoRoot.appendingPathComponent("Fixtures/stream-json/\(name)").path
    }

    // MARK: - The live run

    /// Everything captured strictly before `.runFinished` arrived.
    ///
    /// `AsyncStream` delivers in order and `RunScheduler` yields `.runFinished`
    /// only from `finish()`, after the child's stream has ended — so anything
    /// collected before that update is, by construction, something the panel
    /// could have drawn while the run was still going. That ordering is the
    /// proof; no duration is measured anywhere in this file.
    private struct LiveCapture: Sendable {
        var outputs: [SchedulerUpdate]
        /// Every row kind seen in *any* snapshot taken during the run.
        var kinds: Set<String>
        /// The rows as of the last `.runOutput`, still before `.runFinished`.
        var finalRows: [RunLogRow]
        /// The row the successful tool result was nested under, if one was ever
        /// seen mid-run.
        var sawNestedSuccess: Bool
    }

    @Test("A run in flight reaches a distinct typed row for each event kind")
    @MainActor
    func liveRowsWhileTheRunIsStillGoing() async throws {
        let home = TestHome.scratch("runs-pane-live")
        defer { try? FileManager.default.removeItem(at: home) }
        try FileManager.default.createDirectory(
            at: home.appendingPathComponent("runs"), withIntermediateDirectories: true
        )
        try StoreLocation.ensureDirectories()

        let ready = home.appendingPathComponent("ready")
        let store = try BoardStore.open(at: home.appendingPathComponent("elliot.sqlite"))
        let repo = Repo(path: home.path, nameWithOwner: "phmatray/Elliot", displayName: "Elliot")
        try await store.saveRepo(repo)

        let config = ToolConfig(
            claudePath: Self.fakeClaude,
            // `false` for both, so nothing here can reach the network or the
            // work tree: this test is about what the panel draws from a stream.
            ghPath: "/usr/bin/false",
            gitPath: "/usr/bin/false",
            environment: [
                "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                // One fixture that carries all of it: a session init, agent
                // prose, a tool call whose result **succeeded**, a tool call
                // whose result failed, a refusal (inside the result line), and
                // the terminal result.
                "FAKE_CLAUDE_FIXTURE": Self.fixture("failing-tool.ndjson"),
                "FAKE_CLAUDE_READY": ready.path,
                // Paced so the lines arrive as separate reads rather than one
                // buffer. Nothing is asserted about the delay — see the note on
                // `LiveCapture`.
                "FAKE_CLAUDE_DELAY_MS": "5",
            ]
        )
        let scheduler = RunScheduler(
            store: store, toolConfig: config, verifier: Verifier(gh: GHClient(config: config))
        )

        // A card, because the store's own CHECK constraint insists a run belongs
        // to exactly one of a card or an analysis — the schema will not let this
        // test invent a third kind of run to keep itself simple.
        let card = Card(
            repoID: repo.id, title: "Build and test every pull request",
            columnEnteredAt: Date(), createdAt: Date(), updatedAt: Date()
        )
        try await store.saveCard(card)

        let runID = UUID()
        let run = SkillRun(
            id: runID,
            cardID: card.id,
            repoID: repo.id,
            kind: .createIssue,
            prompt: "/ai-migration-kit:create-issue a story",
            cwd: repo.path,
            logPath: home.appendingPathComponent("runs/\(runID.uuidString).ndjson").path,
            stderrPath: home.appendingPathComponent("runs/\(runID.uuidString).stderr.log").path,
            createdAt: Date()
        )
        try await store.saveRun(run)
        await scheduler.launch(runID: runID)

        // Wait on the fact that the child is up, not on a duration: the script
        // touches this file before it replays a single line, and under load a
        // fixed sleep expires before bash gets there.
        try await withTimeout(.seconds(10)) {
            while !FileManager.default.fileExists(atPath: ready.path) {
                try await Task.sleep(for: .milliseconds(20))
            }
        }

        let capture = try await withTimeout(.seconds(30)) {
            var outputs: [SchedulerUpdate] = []
            var events: [StreamEvent] = []
            var kinds: Set<String> = []
            var nested = false

            for await update in scheduler.updates {
                // Everything past here would be after the run, which is the one
                // thing this test is written to exclude.
                if case .runFinished = update { break }
                guard case .runOutput(_, let event) = update else { continue }

                outputs.append(update)
                events.append(event)
                let rows = RunsPane.rows(of: run, events: events).rows
                for row in rows {
                    kinds.insert(LogRowAccessibility.kind(of: row))
                    if case .toolUse(_, _, _, let outcome) = row, outcome?.isError == false {
                        nested = true
                    }
                }
            }
            return LiveCapture(
                outputs: outputs, kinds: kinds,
                finalRows: RunsPane.rows(of: run, events: events).rows,
                sawNestedSuccess: nested
            )
        }

        // Criterion 16, mid-flight: four distinct kinds, from four distinct
        // cases of `RunLogRow`.
        #expect(capture.kinds.contains("Tool use"))
        #expect(capture.kinds.contains("Refused"))
        #expect(capture.kinds.contains("Result"))
        #expect(capture.kinds.contains("Session"))
        #expect(capture.kinds.contains("It said"))
        #expect(
            capture.sawNestedSuccess,
            """
            No tool call ever carried a successful result. That is the case the \
            old `[String]` log dropped outright — `AppModel.describe` returns \
            nil for it — and the one this pane exists to show.
            """
        )

        // …and the four kinds are four *different* rows, not one row counted
        // four times.
        let byKind = Dictionary(grouping: capture.finalRows, by: LogRowAccessibility.kind(of:))
        #expect(byKind["Tool use"]?.count == 2)
        #expect(byKind["Refused"]?.count == 1)
        #expect(byKind["Result"]?.count == 1)

        let succeeded = capture.finalRows.filter {
            if case .toolUse(_, _, _, let outcome) = $0 { return outcome?.isError == false }
            return false
        }
        let failed = capture.finalRows.filter {
            if case .toolUse(_, _, _, let outcome) = $0 { return outcome?.isError == true }
            return false
        }
        #expect(succeeded.count == 1, "the successful `swift build` call lost its result")
        #expect(failed.count == 1, "the failing `swift test` call lost its result")

        // The refusal is knowable from the stream alone. `SkillRun`'s own
        // `permissionDenials` is written by `finish()`, which has not run yet —
        // so had the pane read only the record, this row would not exist.
        #expect(RunsPane.denials(of: run, in: capture.outputs.compactMap(Self.event)) == ["WebFetch"])
        #expect(run.permissionDenials.isEmpty, "the queued record cannot know about a refusal yet")

        // And the same updates, driven through the real model rather than a
        // local array, produce the same rows: `AppModel.apply` is the only
        // thing that fills `liveLog`, and a pane that agreed with a test fixture
        // but not with the model would be green and blind.
        let model = AppModel()
        for update in capture.outputs { model.apply(update) }
        #expect(RunsPane.rows(of: run, events: model.liveLog[runID] ?? []).rows == capture.finalRows)

        // Finally, let the run land, so the temporary home is not deleted from
        // under a child that is still writing to it.
        let finished = try await Self.awaitTerminal(runID: runID, in: store)
        #expect(finished.state == .completedWithDenials)
        #expect(finished.permissionDenials == ["WebFetch"])
        // The record now knows, and the fallback path agrees with the stream.
        #expect(RunsPane.denials(of: finished, in: []) == ["WebFetch"])
    }

    /// Polls until the run reaches a terminal state, reporting what it last saw
    /// rather than "timed out" so a flake names its own cause.
    private static func awaitTerminal(runID: UUID, in store: BoardStore) async throws -> SkillRun {
        try await withTimeout(.seconds(30)) {
            var lastSeen = "no run row"
            while true {
                if let run = try await store.run(id: runID) {
                    if run.state.isTerminal { return run }
                    lastSeen = "\(run.state)"
                }
                try await Task.sleep(for: .milliseconds(50))
                _ = lastSeen
            }
        }
    }

    private static func event(_ update: SchedulerUpdate) -> StreamEvent? {
        if case .runOutput(_, let event) = update { return event }
        return nil
    }

    // MARK: - Which source a refusal comes from

    /// The stream wins when it has a terminal line, because it is the source the
    /// record is filled *from* — `RunScheduler.finish` writes
    /// `result.permissionDenials.map(\.toolName)` verbatim. Preferring one
    /// rather than merging both is what stops a finished run drawing every
    /// refusal twice.
    @Test("A refusal is read from the stream when it has one, and from the run otherwise")
    func denialsPreferTheStream() {
        let stream = RunResult(
            subtype: "success", isError: false,
            permissionDenials: [PermissionDenial(toolName: "WebFetch")]
        )
        let recorded = Self.run(denials: ["Bash", "WebFetch"])

        #expect(RunsPane.denials(of: recorded, in: [.result(stream)]) == ["WebFetch"])
        #expect(RunsPane.denials(of: recorded, in: []) == ["Bash", "WebFetch"])
        #expect(RunsPane.denials(of: recorded, in: [.assistantText("no result yet")])
            == ["Bash", "WebFetch"])
        // A finished run whose stream says "nothing was refused" is not the same
        // as one whose stream has not got there yet.
        #expect(RunsPane.denials(of: recorded, in: [.result(RunResult(subtype: "success", isError: false))])
            .isEmpty)
    }

    @Test("A run with no events at all yields no rows")
    func noEventsNoRows() {
        #expect(RunsPane.rows(of: Self.run(), events: []).rows.isEmpty)
    }

    // MARK: - The filter, and what it announces

    /// One announcement, carrying the number: "tools" alone does not say whether
    /// the log went quiet or the filter did.
    @Test("Changing the filter announces the mode and the count")
    func filterAnnouncement() {
        #expect(RunsPane.announcement(.tools, shown: 6, of: 11) == "tools, 6 of 11 lines")
        #expect(RunsPane.announcement(.all, shown: 11, of: 11) == "all, 11 of 11 lines")
        #expect(RunsPane.announcement(.errors, shown: 0, of: 11) == "errors, 0 of 11 lines")
    }

    // MARK: - The verdict block

    /// The single easiest thing to get wrong here, and the reason the block
    /// exists: a fixed verified tint would paint "Not merged" green in the one
    /// place built to stop that. So the tint is not merely *expected* to differ
    /// — it is asserted to be `VerifiedOutcome.receipt`'s, unchanged.
    @Test("The gh side takes its text, tint and icon from the outcome, verbatim")
    func ghSideIsTheReceiptVerbatim() throws {
        for outcome: VerifiedOutcome in [
            .issueCreated(number: 47, url: "https://github.com/phmatray/Elliot/issues/47"),
            .prOpen(number: 72, url: "…", isDraft: true, branch: "feat/47-ci"),
            .merged(commitSHA: "abcdef1234", number: nil, url: nil, branch: nil),
            .noIssueCreated(reason: "nothing to file"),
            .notMerged(reason: "the branch is behind"),
            .closedUnmerged(number: nil, url: nil, branch: nil),
            .unverified(reason: "gh did not answer"),
        ] {
            let receipt = try #require(VerdictBlock.receipt(for: Self.run(outcome: outcome)))
            #expect(receipt.text == outcome.receipt.text)
            #expect(receipt.icon == outcome.receipt.icon)
            #expect(receipt.text == outcome.receiptText, "the wording drifted from ElliotModel's")
        }
    }

    /// Stated as colour rather than as identity, because "it is the same tuple"
    /// would still pass if `VerifiedOutcome.receipt` itself went green for
    /// everything. Resolved against a fixed appearance: these are dynamic
    /// colours, and one read outside a drawing appearance is whatever the
    /// process last drew in.
    @MainActor
    @Test("A run whose pull request was not merged is not painted green")
    func notMergedIsNotGreen() throws {
        let appearance = try #require(NSAppearance(named: .aqua))
        let verified = try #require(Self.srgb(Palette.verified, in: appearance))

        for outcome: VerifiedOutcome in [
            .notMerged(reason: "the branch is behind"),
            .closedUnmerged(number: nil, url: nil, branch: nil),
            .unverified(reason: "gh did not answer"),
        ] {
            let receipt = try #require(VerdictBlock.receipt(for: Self.run(outcome: outcome)))
            let tint = try #require(Self.srgb(receipt.tint, in: appearance))
            #expect(tint != verified, "\(outcome) drew in the verified tint")
            #expect(receipt.icon != "checkmark.seal.fill")
        }

        // And the other half of the claim: a receipt that *is* verified still
        // gets the verified tint, so the test above is not passing because
        // nothing is ever green.
        let merged = VerifiedOutcome.merged(commitSHA: nil, number: nil, url: nil, branch: nil)
        let created = try #require(VerdictBlock.receipt(for: Self.run(outcome: merged)))
        #expect(try #require(Self.srgb(created.tint, in: appearance)) == verified)
    }

    /// A run still going has nothing verified *yet*, which is not the same as a
    /// finished run with nothing verified — the first is silence, the second is
    /// the fact the board's rule cares about most.
    @Test("The gh side is silent while the run is going and speaks once it has ended")
    func nothingVerifiedOnlyOnceTheRunHasEnded() {
        #expect(VerdictBlock.receipt(for: Self.run(state: .running)) == nil)
        #expect(VerdictBlock.receipt(for: Self.run(state: .queued)) == nil)

        let ended = VerdictBlock.receipt(for: Self.run(state: .succeeded))
        #expect(ended?.text == "Nothing verified for this run")
    }

    /// Criterion 18's other half, restated where the block reads it: what the
    /// agent claimed never reaches the `gh` side, whatever it claimed.
    @Test("A claim of \"Filed issue #47\" puts no number on the gh side")
    func theClaimNeverBecomesTheFact() {
        var run = Self.run(outcome: .unverified(reason: "gh did not answer"))
        run.setClosing(ClosingRemark(
            text: "Filed issue #47 — https://github.com/phmatray/Elliot/issues/47",
            source: .agent
        ))

        let verdict = RunVerdict.of(run)
        #expect(verdict.itSaid?.contains("#47") == true)
        #expect(verdict.ghSays?.contains(where: \.isNumber) == false)
    }

    /// #288, drawn: a run that died before its terminal event stores the
    /// process's stderr, and the block set it in `Type.hearsay` under an "IT
    /// SAID" caption — the app's central rule inverted inside the one block
    /// built to make that rule visible.
    ///
    /// Asserted as *face and colour*, not as "the tuple differs", for the
    /// reason `notMergedIsNotGreen` above is: the claim is about which tier the
    /// reader sees, and a tuple comparison would still pass if both tiers went
    /// italic. Resolved against a fixed appearance, since these are dynamic
    /// colours.
    @MainActor
    @Test("A fact-tier closing text is drawn as a fact, never as demoted prose")
    func stderrIsNotDrawnInTheHearsayFace() throws {
        let appearance = try #require(NSAppearance(named: .aqua))
        let refused = try #require(Self.srgb(Palette.refused, in: appearance))

        let said = VerdictBlock.style(for: ClosingRemark(text: "I filed it.", source: .agent))
        #expect(said.font == Type.hearsay, "the agent's own prose stopped being demoted")
        let saidGround = try #require(Self.srgb(said.ground, in: appearance))
        #expect(try #require(Self.srgb(said.tint, in: appearance)) != refused)

        // Over the set rather than over `.stderr` alone: a fourth fact-tier
        // source added later must be drawn as one on the day it is added.
        for source in RunResultSource.allCases where !source.isHearsay {
            let style = VerdictBlock.style(for: ClosingRemark(text: "boom", source: source))
            #expect(style.font == Type.fact, "\(source) drew in a face that is not the fact face")
            #expect(style.font != Type.hearsay, "\(source) is still being demoted to italic")
            #expect(try #require(Self.srgb(style.tint, in: appearance)) == refused)
            #expect(
                try #require(Self.srgb(style.ground, in: appearance)) != saidGround,
                "\(source) sits on the hearsay row's ground"
            )
        }
    }

    /// ⚠️ The five assertions above are about `style(for:)`, and `style(for:)`
    /// is a function the body could stop calling — `CaretAnchorTests` records
    /// what that costs: five green behavioural tests over a decoration that
    /// never drew. `swift test` cannot see this view, so the shape is pinned
    /// where the shape lives.
    @Test("The verdict block reads the caption and the tier, it does not choose them")
    func theBlockDoesNotDecideTheTierItself() throws {
        let source = try String(
            contentsOf: URL(filePath: #filePath)
                .deletingLastPathComponent()   // ElliotAppKitTests
                .deletingLastPathComponent()   // Tests
                .deletingLastPathComponent()   // ElliotKit
                .appending(path: "Sources/ElliotAppKit/RunsPane.swift"),
            encoding: .utf8
        )
        // The positive witness first: a claim about what a file does not
        // contain is vacuous if the file was never found or has been renamed.
        #expect(source.contains("struct VerdictBlock"), "this gate is reading the wrong file")

        // Comments are cut, because this file *explains* the defect by naming
        // the old caption — the hazard #186 recorded, and a matcher over prose
        // cannot tell a mention from a claim.
        let code = source.components(separatedBy: "\n").map { line in
            line.range(of: "//").map { String(line[..<$0.lowerBound]) } ?? line
        }
        func sites(_ needle: String) -> [String] {
            code.enumerated()
                .filter { $0.element.contains(needle) }
                .map { "RunsPane.swift:\($0.offset + 1)" }
        }

        #expect(
            sites("caption: \"it said\"").isEmpty,
            """
            the verdict block is captioning the top row "it said" again. Which tier a closing text \
            belongs to is `ClosingRemark`'s answer, and a caption written in a view is a caption \
            `swift test` cannot see (#288).
            """
        )

        // Exactly one, and it is the tuple `style(for:)` returns. Re-derived
        // rather than asserted absent, because the face has to be named
        // *somewhere* in this file — what must not happen is a second site
        // deciding it again.
        let hearsayFace = sites("Type.hearsay")
        #expect(
            hearsayFace.count == 1,
            "the demoted face is chosen in \(hearsayFace.count) places: \(hearsayFace.joined(separator: " · "))"
        )
        #expect(
            code.first { $0.contains("Type.hearsay") }?.contains("Surface.recessFaint") == true,
            "the one site naming the demoted face is no longer VerdictBlock.style(for:)'s tuple"
        )
        #expect(source.contains("Self.style(for: closing)"), "the body stopped asking for the tier")
        #expect(source.contains("caption: closing.caption"), "the body stopped asking for the caption")
    }

    // MARK: - What a screen reader hears

    /// Every row is one combined element whose label leads with its kind. Over
    /// one of each case, because the rule is about the set: an eighth case added
    /// without a label draws fine and reads as nothing.
    @Test("Every row's label leads with its kind")
    func everyLabelLeadsWithItsKind() throws {
        for row in try Self.oneOfEachRow() {
            let kind = LogRowAccessibility.kind(of: row)
            let label = LogRowAccessibility.label(for: row)
            #expect(!kind.isEmpty)
            #expect(label.hasPrefix(kind), "\(kind) label was \"\(label)\"")
            #expect(label.count > kind.count, "\(kind) says its kind and nothing else")
            #expect(!LogRowView.glyph(for: row).isEmpty)
        }
    }

    @Test("A label carries the row's content, not only its kind")
    func labelsCarryContent() {
        #expect(LogRowAccessibility.label(for: .denial(toolName: "WebFetch"))
            == "Refused, WebFetch. The run carried on around it.")

        let call = RunLogRow.toolUse(
            name: "Bash", id: "tu_1", input: "swift build",
            outcome: ToolOutcome(isError: false, preview: "Build complete.")
        )
        #expect(LogRowAccessibility.label(for: call)
            == "Tool use, Bash, swift build. Succeeded, Build complete.")

        // A call still in flight has not failed, and saying either would be a
        // claim the log cannot make.
        let inFlight = RunLogRow.toolUse(name: "Edit", id: "tu_2", input: "ci.yml", outcome: nil)
        #expect(LogRowAccessibility.label(for: inFlight) == "Tool use, Edit, ci.yml. Still running.")
    }

    // MARK: - The chips a session line becomes

    /// Only what the line carried. A missing model is not "claude": the app does
    /// not know which one, and filling in the usual answer is how a log stops
    /// being a record.
    @Test("A session line becomes only the chips it has")
    func sessionChips() throws {
        let full = try Self.systemInit("""
            {"type":"system","subtype":"init","session_id":"s",\
            "cwd":"/Users/phmatray/Repositories/phmatray/private/Elliot",\
            "model":"claude-opus-5","permissionMode":"bypassPermissions",\
            "tools":["Bash","Read","Edit"],"slash_commands":[],"mcp_servers":[]}
            """)
        #expect(SessionRow.chips(full)
            == ["claude-opus-5", "bypassPermissions", "3 tools", "…/private/Elliot"])

        let bare = try Self.systemInit("""
            {"type":"system","subtype":"init","session_id":"s",\
            "tools":["Read"],"slash_commands":[],"mcp_servers":[]}
            """)
        #expect(SessionRow.chips(bare) == ["1 tool"])
    }

    @Test("A short path is not abbreviated")
    func shortPathsSurvive() {
        #expect(SessionRow.abbreviated("/repo") == "/repo")
        #expect(SessionRow.abbreviated("/tmp/repo") == "/tmp/repo")
        #expect(SessionRow.abbreviated("/a/b/c") == "…/b/c")
    }

    /// The closing line prints the fields the result carried and no others: a
    /// fabricated "0 turns" would read as a measurement.
    @Test("The closing line states only the fields the result carried")
    func terminalSummaryOmitsWhatItDoesNotHave() {
        #expect(TerminalRow.summary(RunResult(subtype: "success", isError: false))
            == "Finished clean")
        #expect(
            TerminalRow.summary(RunResult(
                subtype: "success", isError: false, numTurns: 7, durationMS: 18_320
            )) == "Finished clean · 7 turns · 18.3 s"
        )
        #expect(
            TerminalRow.summary(RunResult(subtype: "error_during_execution", isError: true, numTurns: 1))
                == "Finished with issues · 1 turn"
        )
    }

    /// The ACP closing line, and the one case it exists to keep readable: a **refused fork**.
    ///
    /// ⛔ This is the reader that made `stopReason: nil` the wrong value on that path. The row
    /// appends a reason only when there is one, so a refused fork with a nil reason draws as a
    /// bare "Finished with issues" — the single failure a relaunch can fix, rendered exactly like
    /// a run that fell over for unknown reasons. Pinned here rather than read off the source,
    /// because "it names itself on screen" was a claim about a function nothing called in a test:
    /// `terminalSummaryOmitsWhatItDoesNotHave` above covers `TerminalRow.summary`, the
    /// **stream-json** renderer, and this ACP one had no coverage at all.
    @Test("The ACP closing line names an Elliot-authored stop reason")
    func turnEndedSummaryNamesTheStopReason() {
        #expect(
            TurnEndedRow.summary(TurnSummary(
                stopReason: AgentRun.sessionForkRefusedStopReason, isError: true))
                == "Finished with issues · elliot/session_fork_refused"
        )
        // The brake's reason is the precedent this one follows; both are Elliot's own words, and
        // both must survive to the row rather than being recognised and dropped.
        #expect(
            TurnEndedRow.summary(TurnSummary(
                stopReason: AgentRun.maxBudgetStopReason, isError: true))
                == "Finished with issues · elliot/max_budget"
        )
        // And nil is still nil: a run that died mid-turn has no reason, and inventing one would
        // read as a measurement.
        #expect(
            TurnEndedRow.summary(TurnSummary(stopReason: nil, isError: true))
                == "Finished with issues"
        )
        #expect(
            TurnEndedRow.summary(TurnSummary(stopReason: "end_turn", isError: false))
                == "Finished clean · end_turn"
        )
    }

    // MARK: - Fixtures and helpers

    private static func run(
        state: RunState = .succeeded,
        outcome: VerifiedOutcome? = nil,
        denials: [String] = []
    ) -> SkillRun {
        SkillRun(
            cardID: nil, repoID: UUID(), kind: .createIssue, prompt: "p", cwd: "/tmp",
            state: state, logPath: "/tmp/none.ndjson", stderrPath: "/tmp/none.log",
            permissionDenials: denials, verifiedOutcome: outcome,
            createdAt: Date(timeIntervalSince1970: 1_770_000_000)
        )
    }

    private static func oneOfEachRow() throws -> [RunLogRow] {
        [
            .session(try systemInit("""
                {"type":"system","subtype":"init","session_id":"s","cwd":"/repo",\
                "model":"claude-opus-5","permissionMode":"bypassPermissions",\
                "tools":["Bash"],"slash_commands":[],"mcp_servers":[]}
                """)),
            .agentText("Reading the implementation plan."),
            .toolUse(
                name: "Bash", id: "tu_1", input: "swift build",
                outcome: ToolOutcome(isError: false, preview: "Build complete.")
            ),
            .denial(toolName: "WebFetch"),
            .orphanResult(ToolOutcome(isError: true, preview: "no call in this log")),
            .terminal(RunResult(subtype: "success", isError: false, text: "Done.", numTurns: 3)),
            .unreadable(text: "this line is not JSON at all"),
        ]
    }

    /// Decoded rather than built: `SystemInit`'s memberwise initialiser is
    /// internal to `ElliotModel`, and going through the real decoder is the
    /// idiom `RunLogRowTests` already uses — a fixture assembled by hand can
    /// describe a line the decoder would never produce.
    private static func systemInit(_ line: String) throws -> SystemInit {
        for case .systemInit(let info) in StreamEventDecoder.decodeAll(line: Data(line.utf8)) {
            return info
        }
        throw FixtureError.notASystemInitLine(line)
    }

    private enum FixtureError: Error { case notASystemInitLine(String) }

    /// The sRGB components a `Color` resolves to under one appearance. Dynamic
    /// colours resolve against the *current drawing* appearance, so it has to be
    /// made current first.
    @MainActor
    private static func srgb(
        _ color: Color, in appearance: NSAppearance
    ) -> [CGFloat]? {
        var out: [CGFloat]?
        appearance.performAsCurrentDrawingAppearance {
            guard let srgb = NSColor(color).usingColorSpace(.sRGB) else { return }
            out = [srgb.redComponent, srgb.greenComponent, srgb.blueComponent]
        }
        return out
    }
}
