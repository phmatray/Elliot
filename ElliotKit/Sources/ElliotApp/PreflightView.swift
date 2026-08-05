import ElliotEngine
import ElliotIPC
import ElliotModel
import SwiftUI

struct PreflightView: View {
    @Environment(AppModel.self) private var model
    @State private var copied = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                identity
                summary

                section("This machine", results: model.globalChecks)
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
                    .font(.system(size: 13, weight: .medium))
                Text("\(all.count) checks across this machine and \(model.repos.count) repositor\(model.repos.count == 1 ? "y" : "ies").")
                    .font(Type.prose)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.07))
        .clipShape(RoundedRectangle(cornerRadius: 8))
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
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator))
            HStack {
                Button(copied ? "Copied" : "Copy command", systemImage: copied ? "checkmark" : "doc.on.doc") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(AppModel.mcpRegistrationCommand, forType: .string)
                    copied = true
                }
                .controlSize(.small)
                Spacer()
            }
            // The registration records an absolute path, so moving the app
            // silently breaks the server.
            Text("Run it again if you move Elliot.app — the path is recorded verbatim.")
                .font(Type.prose)
                .foregroundStyle(.tertiary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func repoSection(_ repo: Repo) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(repo.displayName).font(.system(size: 13, weight: .medium))
                    Fact(text: repo.nameWithOwner, small: true).foregroundStyle(.tertiary)
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
        .background(Color.secondary.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 8))
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
                DisclosureGroup {
                    VStack(alignment: .leading, spacing: 4) {
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
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, 4)
                    .padding(.top, 2)
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: icon(result.status))
                            .font(.system(size: 11))
                            .foregroundStyle(tint(result.status))
                        Text(result.title).font(.system(size: 12, weight: .medium))
                        Text(result.detail)
                            .font(Type.prose)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Spacer()
                    }
                }
            }
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
