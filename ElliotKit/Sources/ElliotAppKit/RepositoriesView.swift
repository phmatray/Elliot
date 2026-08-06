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

    /// Collapsed by default: on a healthy portfolio the report is two hundred
    /// lines saying "up to date", and the sentence above it is the answer.
    @State private var isReportExpanded = false

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
                Button("Sync", systemImage: "arrow.triangle.2.circlepath") {
                    Task { await model.syncAll() }
                }
                .controlSize(.small)
                .disabled(model.isReconciling || behindCount == 0)
                .help(syncHelp)
            }
            Text(countSentence)
                .font(Type.prose)
                .foregroundStyle(.secondary)

            // The outcome sentence used to go to `status`, which lives in the
            // board's status bar — a different window from the button that
            // produced it. A fix that failed read exactly like one that worked.
            // What the sweep decided *not* to do. The list below shows each
            // row's own verdict, so this block exists for the one question it
            // cannot answer — a repository the sweep passed over looks exactly
            // like one that was never in it.
            if let summary = model.lastSyncSummary {
                DisclosureGroup(isExpanded: $isReportExpanded) {
                    // Bounded, and scrolled rather than truncated: on a real
                    // portfolio `skipped` holds two hundred entries, and a
                    // header free to grow to fit them would eat the page. Every
                    // one is still in there — a report that quietly dropped the
                    // tail would be the failure it is meant to expose.
                    ScrollView {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(summary.failed, id: \.0) { id, reason in
                                reportLine(id: id, reason: reason, refused: true)
                            }
                            ForEach(summary.skipped, id: \.0) { id, reason in
                                reportLine(id: id, reason: reason, refused: false)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 160)
                } label: {
                    Text(summary.sentence)
                        .font(Type.prose)
                        .foregroundStyle(summary.failed.isEmpty ? Color.secondary : Palette.refused)
                }
                .accessibilityLabel("Last sync: \(summary.sentence)")
            }

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

    /// One line of the sweep's report: what it is, and why it was left out.
    private func reportLine(id: String, reason: String, refused: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(id)
                .font(Type.factSmall)
                .foregroundStyle(refused ? Palette.refused : .secondary)
            Text(reason)
                .font(Type.prose)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }

    /// How many rows the sweep would actually act on — asked of `RepoIssue`, so
    /// the number on the button and the rows `syncAll` picks cannot disagree.
    private var behindCount: Int {
        model.repoRows.count { $0.issue.isBehind }
    }

    private var syncHelp: String {
        behindCount == 0
            ? "Nothing is behind — there is nothing to fast-forward."
            : "Fast-forward the \(behindCount) clone(s) that are behind, eight at a time. "
                + "Anything carrying local work — uncommitted changes, unpushed commits, a "
                + "detached HEAD — is skipped and named. Never merges, never moves a directory."
    }

    private var countSentence: String {
        let total = model.repoRows.count
        guard total > 0 else {
            return model.isReconciling
                ? "Reading GitHub, the disk and the board…"
                : "Nothing found under \(model.layout.root)."
        }
        let repositories = "\(total) repositor\(total == 1 ? "y" : "ies")"
        return ([repositories] + Self.clauses(for: model.repoRows)).joined(separator: " · ")
    }

    /// The sentence's clauses, in order, or the single "nothing" clause.
    ///
    /// `.unlisted` gets counted here on its own rather than folded into
    /// "needs attention", and it cannot simply join that count: attention is
    /// measured by having a fix, and an unlisted row has no button to press.
    /// Left out entirely it would have been swallowed by "nothing needs
    /// attention" — which is the row-level verdict this change exists to fix,
    /// restated one level up, and just as quiet.
    nonisolated static func clauses(for rows: [RepoRow]) -> [String] {
        let actionable = rows.filter { !$0.fixes.isEmpty }.count
        let unlisted = rows.filter { $0.issue == .unlisted }.count
        var clauses: [String] = []
        if actionable > 0 {
            clauses.append("\(actionable) need\(actionable == 1 ? "s" : "") attention")
        }
        if unlisted > 0 { clauses.append("\(unlisted) unlisted") }
        return clauses.isEmpty ? ["nothing needs attention"] : clauses
    }

    // MARK: - Rows

    private func repoRow(_ row: RepoRow) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: Self.icon(row.issue))
                .font(.system(size: 11))
                .foregroundStyle(Self.tint(row.issue))
                .padding(.top, 2)
                .accessibilityLabel(Self.verdict(row.issue))

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(row.nameWithOwner.map(displayName) ?? row.id)
                        .font(Type.cardTitle)
                    Fact(text: Self.verdict(row.issue), tint: Self.tint(row.issue), small: true)
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
        case .pull(let path):
            "Fast-forward \(path) to its upstream. Never merges, never rebases, and refuses outright "
                + "if anything there is uncommitted."
        }
    }

    // MARK: - Status vocabulary

    /// Deliberately the same three symbols and tints Preflight uses, so the two
    /// screens read alike. `outOfScope` is neutral, not a warning: a fork or an
    /// archived repository is *fine*, it is simply not ours to harmonise.
    ///
    /// Every switch below is exhaustive, with no `default:`. That is the point of
    /// the vocabulary rather than a style note: a verdict added to `RepoIssue`
    /// must fail to compile here, so it gets a symbol and a tint someone chose
    /// instead of silently inheriting the warning triangle. `.unlisted` reached
    /// this file exactly that way.
    ///
    /// They are `static` so `ElliotAppKitTests` can read them — the same shape as
    /// `VerdictBlock.receipt`. What the page says about a verdict is assertable;
    /// where the row sits on screen still is not.
    nonisolated static func icon(_ issue: RepoIssue) -> String {
        switch issue {
        case .ok: "checkmark.circle.fill"
        case .outOfScope: "minus.circle"
        // A question, not a warning triangle: nothing here is known to be
        // broken. The fill keeps it in this file's "wants a decision" tier
        // rather than the neutral one a fork sits in.
        case .unlisted: "questionmark.circle.fill"
        case .notCloned, .notRegistered, .missing, .misplaced: "exclamationmark.triangle.fill"
        // The git-state verdicts a probe produces. Grouped, and drawn exactly as
        // the `default:` arm drew them before this file became exhaustive —
        // giving each git state a symbol of its own is a decision belonging to
        // the sweep that introduced them, not to this merge. They are listed
        // rather than caught, so that decision has somewhere to land.
        case .behind, .dirty, .ahead, .diverged, .detached, .noRemote, .unreadable:
            "exclamationmark.triangle.fill"
        }
    }

    nonisolated static func tint(_ issue: RepoIssue) -> Color {
        switch issue {
        case .ok: Palette.verified
        case .outOfScope: .secondary
        // `attention` is "still alive, but wants a decision", which is exactly
        // this row: a human has to go and look. Not `verified` — nothing was
        // verified — and no sixth accent is invented for it. `RunsPane` already
        // spends the same tint on "Nothing verified for this run", which is the
        // same claim about a run that this is about a repository.
        case .unlisted: Palette.attention
        case .notCloned, .notRegistered, .missing, .misplaced: Palette.attention
        // As above: the tint the `default:` arm gave them, preserved verbatim.
        case .behind, .dirty, .ahead, .diverged, .detached, .noRemote, .unreadable:
            Palette.attention
        }
    }

    nonisolated static func verdict(_ issue: RepoIssue) -> String {
        switch issue {
        case .ok: "ok"
        case .notCloned: "not cloned"
        case .notRegistered: "not registered"
        case .missing: "missing"
        case .misplaced: "misplaced"
        case .unlisted: "unlisted"
        case .outOfScope(.fork): "fork"
        case .outOfScope(.archived): "archived"
        case .outOfScope(.otherRoot): "out of scope"
        case .behind(let count): "behind by \(count)"
        case .dirty: "dirty"
        case .ahead: "ahead"
        case .diverged: "diverged"
        case .detached: "detached"
        case .noRemote: "no remote"
        case .unreadable: "unreadable"
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
