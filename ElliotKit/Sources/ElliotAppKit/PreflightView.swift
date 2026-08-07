import ElliotEngine
import ElliotIPC
import ElliotModel
import SwiftUI

public struct PreflightView: View {
    public init() {}

    @Environment(AppModel.self) private var model
    @State private var copied = false
    /// Per-check override of the default open-if-failing state.
    @State private var expansion: [String: Bool] = [:]

    /// How many runs may go at once, and how many are going.
    ///
    /// Here rather than in a Settings screen because there is no Settings screen
    /// and this is the page about the machine. It is deliberately small: the
    /// Operations screen (#69) is where this eventually belongs, beside the
    /// queue these caps are holding back.
    ///
    /// Each stepper says what it is holding right now. A cap of 4 means nothing
    /// on its own — "2 of 4 in flight" is what tells you whether raising it
    /// would change anything.
    private var runLimits: some View {
        VStack(alignment: .leading, spacing: 8) {
            ConsoleLabel(text: "Runs at once")
            Text(
                "Writers build, so two at once in one checkout is the reason for the cap. "
                    + "An analysis only reads, and gets its own lane."
            )
            .font(Type.prose)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            limitStepper(
                title: "Writers", inFlight: model.occupancy.writers,
                value: model.limits.maxConcurrent
            ) { new in
                SchedulerLimits(
                    maxConcurrent: new,
                    maxConcurrentAnalyses: model.limits.maxConcurrentAnalyses
                )
            }

            limitStepper(
                title: "Analyses", inFlight: model.occupancy.analyses,
                value: model.limits.maxConcurrentAnalyses
            ) { new in
                SchedulerLimits(
                    maxConcurrent: model.limits.maxConcurrent,
                    maxConcurrentAnalyses: new
                )
            }
        }
    }

    private func limitStepper(
        title: String,
        inFlight: Int,
        value: Int,
        make: @escaping (Int) -> SchedulerLimits
    ) -> some View {
        HStack(spacing: 8) {
            Stepper(value: makeBinding(value, make), in: 1...SchedulerLimits.ceiling) {
                Text("\(title): \(value)").font(Type.bodyProse)
            }
            .fixedSize()
            Fact(text: "\(inFlight) in flight", tint: Palette.quiet, small: true)
            Spacer()
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title), at most \(value) at once, \(inFlight) in flight")
    }

    /// The stepper writes through `AppModel`, which saves *then* applies. A
    /// local `@State` mirror would let the two disagree the moment a save fails.
    private func makeBinding(
        _ value: Int, _ make: @escaping (Int) -> SchedulerLimits
    ) -> Binding<Int> {
        Binding(
            get: { value },
            set: { new in Task { await model.updateLimits(make(new)) } }
        )
    }

    /// The brake. Off by default, because a ceiling nobody chose will stop a
    /// legitimate `merge-pr` at 3 a.m. and read as a bug.
    ///
    /// Today's spend is shown beside it, and it is the number that makes the
    /// setting meaningful: a $20 ceiling means nothing until you know the board
    /// spent $34 yesterday.
    private var spendCeiling: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                ConsoleLabel(text: "Spending")
                Spacer()
                Fact(
                    text: "today \(model.spentToday.sentence())",
                    tint: model.isOverDailyCeiling ? Palette.refused : Palette.quiet,
                    small: true
                )
            }
            Text(
                "A drag starts an unattended agent. Without a ceiling there is no upper bound "
                    + "on what one costs."
            )
            .font(Type.prose)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            ceilingField(
                title: "Per run", value: model.ceiling.perRunUSD,
                help: "Handed to Claude Code, which stops the run itself."
            ) { new in SpendCeiling(perRunUSD: new, perDayUSD: model.ceiling.perDayUSD) }

            ceilingField(
                title: "Per day", value: model.ceiling.perDayUSD,
                help: "Checked before a run starts. Runs already going are never cut off."
            ) { new in SpendCeiling(perRunUSD: model.ceiling.perRunUSD, perDayUSD: new) }

            if model.isOverDailyCeiling {
                // The one refusal a user cannot deduce from the board: the queue
                // simply stops moving, and without this it reads as a broken
                // scheduler rather than as the setting doing its job.
                Label(
                    "Today's ceiling is reached — queued runs are held until tomorrow, "
                        + "or until you raise it.",
                    systemImage: "hand.raised.fill"
                )
                .font(Type.prose)
                .foregroundStyle(Palette.refused)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func ceilingField(
        title: String,
        value: Double?,
        help: String,
        make: @escaping (Double?) -> SpendCeiling
    ) -> some View {
        HStack(spacing: 8) {
            Text(title).font(Type.bodyProse).frame(width: 68, alignment: .leading)
            TextField(
                "no ceiling",
                text: Binding(
                    // Empty, not "0": the placeholder says "no ceiling", and a
                    // zero in the box would read as a ceiling of nothing.
                    get: { value.map { String(format: "%.2f", $0) } ?? "" },
                    set: { typed in
                        let parsed = Double(typed.replacingOccurrences(of: ",", with: "."))
                        Task { await model.updateCeiling(make(parsed)) }
                    }
                )
            )
            .textFieldStyle(.roundedBorder)
            .frame(width: 90)
            Text(help).font(Type.prose).foregroundStyle(.tertiary)
            Spacer()
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(title) ceiling, \(value.map { MoneyFormat.usd($0) } ?? "none"). \(help)")
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                identity
                summary

                section("This machine", results: model.globalChecks)
                runLimits
                spendCeiling
                integration

                VStack(alignment: .leading, spacing: 8) {
                    ConsoleLabel(text: "Repositories")
                    if model.repos.isEmpty {
                        Text("None yet. Add the main checkout of a repository — not a linked worktree, which merge-pr cannot tear down from inside.")
                            .font(Type.prose)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(model.repos) { repo in
                        repoSection(repo)
                    }
                }

                HStack {
                    Button("Add a repository…", systemImage: "folder.badge.plus") { choose() }
                    Button("Check again", systemImage: "arrow.clockwise") {
                        Task { await model.refreshRepoChecks() }
                    }
                    Spacer()
                }
            }
            .padding(18)
            .frame(maxWidth: 760, alignment: .leading)
        }
        .frame(maxWidth: .infinity)
        .navigationTitle("Preflight")
    }

    /// Preflight is the first screen a new user sees, and until now it opened
    /// with a verdict about a product it never names. The version is set in the
    /// fact face because the build stamped it, not a person — and it is the one
    /// thing a bug report from the field is trusted on.
    private var identity: some View {
        HStack(spacing: 10) {
            MarkBadge(size: 34)
            VStack(alignment: .leading, spacing: 1) {
                Text("Elliot").font(Type.sheetTitle)
                Fact(text: ElliotBuild.version, small: true)
            }
            Spacer()
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Elliot, version \(ElliotBuild.version)")
    }

    /// The verdict first. A wall of green ticks makes you hunt for the one
    /// thing that is wrong.
    private var summary: some View {
        let all = model.globalChecks + model.repos.flatMap { model.repoChecks[$0.id] ?? [] }
        let failing = all.filter { $0.status == .fail }
        let warning = all.filter { $0.status == .warn }

        return HStack(spacing: 8) {
            Image(systemName: failing.isEmpty ? (warning.isEmpty ? "checkmark.seal.fill" : "exclamationmark.triangle.fill") : "xmark.seal.fill")
                .font(.system(size: 20))
                .foregroundStyle(failing.isEmpty ? (warning.isEmpty ? Palette.verified : Palette.attention) : Palette.refused)
            VStack(alignment: .leading, spacing: 1) {
                Text(headline(failing: failing.count, warning: warning.count))
                    .font(Type.cardTitle)
                Text("\(all.count) checks across this machine and \(model.repos.count) repositor\(model.repos.count == 1 ? "y" : "ies").")
                    .font(Type.prose)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Surface.recess)
        .clipShape(RoundedRectangle(cornerRadius: Metric.panelRadius))
    }

    private func headline(failing: Int, warning: Int) -> String {
        if failing > 0 { return "\(failing) check\(failing == 1 ? "" : "s") failing — runs will not work" }
        if warning > 0 { return "\(warning) warning\(warning == 1 ? "" : "s")" }
        return "Everything Elliot needs is here"
    }

    private var integration: some View {
        VStack(alignment: .leading, spacing: 8) {
            ConsoleLabel(text: "Claude Code integration")
            Text("Register the bundled MCP helper so an agent can drive this board.")
                .font(Type.prose)
                .foregroundStyle(.secondary)
            Text(AppModel.mcpRegistrationCommand)
                .font(Type.fact)
                .textSelection(.enabled)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(nsColor: .textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: Metric.cardRadius))
                .overlay(RoundedRectangle(cornerRadius: Metric.cardRadius).strokeBorder(.separator))
            HStack {
                Button(copied ? "Copied" : "Copy command", systemImage: copied ? "checkmark" : "doc.on.doc") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(AppModel.mcpRegistrationCommand, forType: .string)
                    copied = true
                }
                .controlSize(.small)
                Spacer()
            }
            // "Copied" was permanent, so the button stopped naming what it
            // does. Structured, so it cancels if the window closes mid-count.
            .task(id: copied) {
                guard copied else { return }
                try? await Task.sleep(for: .seconds(2))
                copied = false
            }
            // The registration records an absolute path, so moving the app
            // silently breaks the server.
            Text("Run it again if you move Elliot.app — the path is recorded verbatim.")
                .font(Type.prose)
                .foregroundStyle(.tertiary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Surface.recess)
        .clipShape(RoundedRectangle(cornerRadius: Metric.panelRadius))
    }

    private func repoSection(_ repo: Repo) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(repo.displayName).font(Type.cardTitle)
                    Fact(text: repo.nameWithOwner, tint: Palette.quiet, small: true)
                }
                Spacer()
                Toggle("Enabled", isOn: Binding(
                    get: { repo.isEnabled },
                    set: { value in Task { await model.setRepoEnabled(repo, enabled: value) } }
                ))
                .toggleStyle(.switch)
                .controlSize(.mini)
                .labelsHidden()
                .help(repo.isEnabled ? "Switch off to refuse every move on this repository" : "Switched off — moves are refused")

                Button {
                    Task { await model.removeRepo(id: repo.id) }
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help("Remove \(repo.displayName) from Elliot. The checkout on disk is untouched.")
                .accessibilityLabel("Remove \(repo.displayName)")
            }
            Text(repo.path)
                .font(Type.factSmall)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
            checkList(model.repoChecks[repo.id] ?? [])
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Surface.recess)
        .clipShape(RoundedRectangle(cornerRadius: Metric.panelRadius))
        .opacity(repo.isEnabled ? 1 : 0.6)
    }

    private func section(_ title: String, results: [CheckResult]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ConsoleLabel(text: title)
            checkList(results)
        }
    }

    private func checkList(_ results: [CheckResult]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(results) { result in
                DisclosureGroup(isExpanded: expansion(for: result)) {
                    VStack(alignment: .leading, spacing: 4) {
                        // The detail lives here, not in the label: it was
                        // `lineLimit(1)` on a row that also carried the title,
                        // so the sentence saying *what is wrong* was the first
                        // thing truncated. It also means a check with neither
                        // command nor hint no longer expands to an empty box.
                        Text(result.detail)
                            .font(Type.prose)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                        if let command = result.command {
                            // Showing the command means the verdict can be
                            // checked rather than trusted.
                            Text(command)
                                .font(Type.fact)
                                .textSelection(.enabled)
                                .foregroundStyle(.secondary)
                        }
                        if let hint = result.fixHint {
                            Label(hint, systemImage: "wrench.and.screwdriver")
                                .font(Type.prose)
                                .foregroundStyle(tint(result.status))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        // A finding you can act on. Every check that shipped
                        // before #170 carries no fixes, so this renders nothing
                        // for all of them — the screen did not grow buttons, it
                        // gained the ability to have one.
                        let buttons = PreflightFixes.buttons(for: result)
                        if !buttons.isEmpty {
                            HStack(spacing: 8) {
                                ForEach(buttons) { button in
                                    Button(button.title) {
                                        Task { await model.apply(button.fix) }
                                    }
                                    .font(Type.prose)
                                }
                            }
                            .padding(.top, 2)
                        }
                        if let outcome = model.fixOutcome(for: result) {
                            // What the last fix did, in its own words. Shown
                            // rather than swallowed because `apply` reports a
                            // *partial* success — four labels asked for, three
                            // created — and that sentence is the only place that
                            // distinction survives.
                            Text(outcome.detail)
                                .font(Type.prose)
                                .foregroundStyle(outcome.succeeded ? .secondary : tint(.fail))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, 4)
                    .padding(.top, 2)
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: icon(result.status))
                            .font(.system(size: 11))
                            .foregroundStyle(tint(result.status))
                            // The verdict was carried by colour and shape
                            // alone. `RepositoriesView` already names the same
                            // three symbols for the same reason.
                            .accessibilityLabel(word(result.status))
                        Text(result.title).font(Type.rowTitle)
                        Spacer()
                    }
                }
            }
        }
    }

    /// Open on arrival when the check is failing — that is the one you came
    /// for — and remembers your own collapse afterwards.
    private func expansion(for result: CheckResult) -> Binding<Bool> {
        Binding(
            get: { expansion[result.id] ?? (result.status == .fail) },
            set: { expansion[result.id] = $0 }
        )
    }

    private func word(_ status: CheckStatus) -> String {
        switch status {
        case .pass: "passed"
        case .warn: "warning"
        case .fail: "failed"
        }
    }

    private func icon(_ status: CheckStatus) -> String {
        switch status {
        case .pass: "checkmark.circle.fill"
        case .warn: "exclamationmark.triangle.fill"
        case .fail: "xmark.circle.fill"
        }
    }

    private func tint(_ status: CheckStatus) -> Color {
        switch status {
        case .pass: Palette.verified
        case .warn: Palette.attention
        case .fail: Palette.refused
        }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Add"
        panel.message = "Choose the main checkout — not a linked worktree."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await model.addRepo(path: url.path) }
    }
}
