import ElliotEngine
import ElliotModel
import SwiftUI

struct PreflightView: View {
    @Environment(AppModel.self) private var model
    @State private var copied = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                section("This machine", results: model.globalChecks)

                GroupBox("Claude Code integration") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Register the bundled MCP helper so an agent can drive the board:")
                            .font(.callout)
                        Text(AppModel.mcpRegistrationCommand)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                            .padding(8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.secondary.opacity(0.08))
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                        Button(copied ? "Copied" : "Copy command", systemImage: "doc.on.doc") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(
                                AppModel.mcpRegistrationCommand, forType: .string
                            )
                            copied = true
                        }
                        .controlSize(.small)
                        // The registration records an absolute path, so moving
                        // the app silently breaks the server.
                        Text("Re-run this if you move Elliot.app — the path is recorded verbatim.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                ForEach(model.repos) { repo in
                    repoSection(repo)
                }

                HStack {
                    Button("Add a repository…", systemImage: "folder.badge.plus") { choose() }
                    Button("Re-check", systemImage: "arrow.clockwise") {
                        Task { await model.refreshRepoChecks() }
                    }
                }
            }
            .padding(16)
        }
        .navigationTitle("Preflight")
    }

    private func repoSection(_ repo: Repo) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(repo.displayName).font(.headline)
                Text(repo.nameWithOwner).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Toggle("Enabled", isOn: Binding(
                    get: { repo.isEnabled },
                    set: { value in Task { await model.setRepoEnabled(repo, enabled: value) } }
                ))
                .toggleStyle(.switch)
                .controlSize(.mini)
                Button("Remove", systemImage: "trash", role: .destructive) {
                    Task { await model.removeRepo(id: repo.id) }
                }
                .buttonStyle(.borderless)
            }
            Text(repo.path).font(.caption2).foregroundStyle(.tertiary)
            checkList(model.repoChecks[repo.id] ?? [])
        }
        .padding(10)
        .background(Color.secondary.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func section(_ title: String, results: [CheckResult]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.headline)
            checkList(results)
        }
    }

    private func checkList(_ results: [CheckResult]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(results) { result in
                DisclosureGroup {
                    VStack(alignment: .leading, spacing: 4) {
                        if let command = result.command {
                            // Showing the command means the verdict can be
                            // checked rather than trusted.
                            Text(command)
                                .font(.caption.monospaced())
                                .textSelection(.enabled)
                        }
                        if let hint = result.fixHint {
                            Text(hint).font(.caption).foregroundStyle(.orange)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, 4)
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: icon(result.status))
                            .foregroundStyle(tint(result.status))
                        Text(result.title).font(.callout.weight(.medium))
                        Text(result.detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
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
        case .pass: .green
        case .warn: .orange
        case .fail: .red
        }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Add"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await model.addRepo(path: url.path) }
    }
}
