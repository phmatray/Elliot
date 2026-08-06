import ElliotEngine
import ElliotModel
import SwiftUI

/// The fleet, one row per repository, with the single named action its verdict
/// allows.
///
/// This view judges nothing. Every verdict on screen was computed by
/// `RepoReconciler` in `ElliotModel`, and every button is a `RepoFix` that
/// verdict already carried — `ElliotApp` has no test target, so a rule written
/// here would be unprovable by `swift test`.
public struct RepositoriesView: View {
    public init() {}

    @Environment(AppModel.self) private var model

    public var body: some View {
        Group {
            if model.isReady {
                List {
                    ForEach(sections, id: \.owner) { section in
                        Section(section.owner) {
                            ForEach(section.rows) { row in
                                repoRow(row)
                            }
                        }
                    }
                }
                .listStyle(.inset)
            } else {
                ContentUnavailableView(
                    "Still starting", systemImage: "hourglass",
                    description: Text(model.status))
            }
        }
        .safeAreaInset(edge: .top) { header }
        .navigationTitle("Repositories")
        // Keyed on `isReady`, not bare: the toolbar is live before `start()`
        // finishes, and a bare `.task` firing then would find no registry, return
        // silently, and leave the page asserting "nothing found" about a scan
        // that never ran.
        .task(id: model.isReady) {
            // Only on first arrival: rebuilding costs one `gh repo list` per
            // owner, and coming back from a fix already refreshed the list.
            if model.isReady, model.repoRows.isEmpty { await model.refreshRepoRows() }
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 1) {
                    ConsoleLabel(text: "Repository tree")
                    Text(model.layout.root)
                        .font(Type.factSmall)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
                Spacer()
                if model.isReconciling {
                    ProgressView().controlSize(.small)
                }
                Button("Change…", systemImage: "folder") { chooseRoot() }
                    .controlSize(.small)
                    .help("Choose the folder holding your <owner>/<public|private>/<name> tree")
                Button("Refresh", systemImage: "arrow.clockwise") {
                    Task { await model.refreshRepoRows() }
                }
                .controlSize(.small)
                .disabled(model.isReconciling)
                .help("Re-read GitHub, the disk and the board")
            }
            Text(countSentence)
                .font(Type.prose)
                .foregroundStyle(.secondary)

            // The outcome sentence used to go to `status`, which lives in the
            // board's status bar — a different window from the button that
            // produced it. A fix that failed read exactly like one that worked.
            if let outcome = model.lastFixOutcome {
                Label(
                    outcome.detail,
                    systemImage: outcome.succeeded
                        ? "checkmark.circle"
                        : "exclamationmark.triangle.fill"
                )
                .font(Type.prose)
                .foregroundStyle(outcome.succeeded ? Color.secondary : Palette.refused)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.bar)
    }

    private var countSentence: String {
        let total = model.repoRows.count
        guard total > 0 else {
            return model.isReconciling
                ? "Reading GitHub, the disk and the board…"
                : "Nothing found under \(model.layout.root)."
        }
        let actionable = model.repoRows.filter { !$0.fixes.isEmpty }.count
        let repositories = "\(total) repositor\(total == 1 ? "y" : "ies")"
        return actionable == 0
            ? "\(repositories) · nothing needs attention"
            : "\(repositories) · \(actionable) need\(actionable == 1 ? "s" : "") attention"
    }

    // MARK: - Rows

    private func repoRow(_ row: RepoRow) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon(row.issue))
                .font(.system(size: 11))
                .foregroundStyle(tint(row.issue))
                .padding(.top, 2)
                .accessibilityLabel(verdict(row.issue))

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(row.nameWithOwner.map(displayName) ?? row.id)
                        .font(Type.cardTitle)
                    Fact(text: verdict(row.issue), tint: tint(row.issue), small: true)
                }
                if let nameWithOwner = row.nameWithOwner {
                    Fact(text: nameWithOwner, tint: Palette.quiet, small: true)
                }
                Text(row.detail)
                    .font(Type.prose)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let path = row.path {
                    // A path on disk is machine-established, so it belongs in
                    // the fact face like every other one. This was the file's
                    // only semantic system font; the trade is a little Dynamic
                    // Type scaling for rule-1 consistency.
                    Text(path)
                        .font(Type.factSmall)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
            }

            Spacer(minLength: 8)

            // One button per legal fix, and nothing here deletes: `RepoFix` has
            // no `.delete` case, deliberately.
            VStack(alignment: .trailing, spacing: 4) {
                ForEach(row.fixes, id: \.self) { fix in
                    Button(fix.label) { Task { await model.apply(fix) } }
                        .controlSize(.small)
                        .disabled(model.isReconciling)
                        .help(explain(fix))
                }
            }
        }
        .padding(.vertical, 4)
    }

    /// The last path component of `owner/name` — the name a person uses.
    private func displayName(_ nameWithOwner: String) -> String {
        String(nameWithOwner.split(separator: "/").last ?? Substring(nameWithOwner))
    }

    private func explain(_ fix: RepoFix) -> String {
        switch fix {
        case .clone(let nameWithOwner, let into):
            "Clone \(nameWithOwner) into \(into)."
        case .move(let from, let to):
            "Move \(from) to \(to), and repoint the registration. Nothing is deleted."
        case .register(let path):
            "Let Elliot drive the checkout at \(path)."
        case .forget:
            "Remove the registration and this repository's cards. The clone on disk is untouched."
        }
    }

    // MARK: - Status vocabulary

    /// Deliberately the same three symbols and tints Preflight uses, so the two
    /// screens read alike. `outOfScope` is neutral, not a warning: a fork or an
    /// archived repository is *fine*, it is simply not ours to harmonise.
    private func icon(_ issue: RepoIssue) -> String {
        switch issue {
        case .ok: "checkmark.circle.fill"
        case .outOfScope: "minus.circle"
        default: "exclamationmark.triangle.fill"
        }
    }

    private func tint(_ issue: RepoIssue) -> Color {
        switch issue {
        case .ok: Palette.verified
        case .outOfScope: .secondary
        default: Palette.attention
        }
    }

    private func verdict(_ issue: RepoIssue) -> String {
        switch issue {
        case .ok: "ok"
        case .notCloned: "not cloned"
        case .notRegistered: "not registered"
        case .missing: "missing"
        case .misplaced: "misplaced"
        case .outOfScope(.fork): "fork"
        case .outOfScope(.archived): "archived"
        case .outOfScope(.otherRoot): "out of scope"
        }
    }

    // MARK: - Grouping

    private struct OwnerSection {
        var owner: String
        var rows: [RepoRow]
    }

    /// A section per configured owner, in the order the layout lists them, plus
    /// one for everything else. Rows are never dropped for having an owner we do
    /// not manage — silence is how a repository disappears from a sweep.
    private var sections: [OwnerSection] {
        let grouped = Dictionary(grouping: model.repoRows) { row in
            row.nameWithOwner.flatMap { $0.split(separator: "/").first.map(String.init) } ?? ""
        }
        var sections = model.layout.owners.compactMap { owner in
            grouped[owner].map { OwnerSection(owner: owner, rows: $0) }
        }
        let others = grouped
            .filter { !model.layout.owners.contains($0.key) }
            .values.flatMap { $0 }
            .sorted { $0.id.lowercased() < $1.id.lowercased() }
        if !others.isEmpty {
            sections.append(OwnerSection(owner: "Other owners", rows: others))
        }
        return sections
    }

    private func chooseRoot() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Use"
        panel.message = "Choose the folder holding your <owner>/<public|private>/<name> tree."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await model.setRepositoriesRoot(url.path) }
    }
}
