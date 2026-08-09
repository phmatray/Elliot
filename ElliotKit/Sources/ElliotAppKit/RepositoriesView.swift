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
    @Environment(\.openWindow) private var openWindow

    /// Collapsed by default: on a healthy portfolio the report is two hundred
    /// lines saying "up to date", and the sentence above it is the answer.
    @State private var isReportExpanded = false

    public var body: some View {
        @Bindable var model = model

        Group {
            if model.isReady {
                // Selectable, and the selection lives on `AppModel` rather than
                // in `@State` here: the menu item that carries ⌘↩ is in
                // `ElliotApp`'s `Commands`, which is not a view hierarchy and
                // cannot read another view's state. Selection also buys
                // arrow-key movement between rows for free on macOS, which is
                // half of criterion 4.
                List(selection: $model.selectedRepoRowID) {
                    ForEach(sections, id: \.owner) { section in
                        Section(section.owner) {
                            ForEach(section.rows) { row in
                                repoRow(row)
                            }
                        }
                    }
                }
                .listStyle(.inset)
                // ↩ on the focused list, alongside the menu item's ⌘↩. The
                // menu item is what makes the shortcut *discoverable*; this is
                // the gesture a person reaches for without being told, and it
                // is the same act through the same method.
                //
                // `.ignored` rather than swallowing the key when there is
                // nothing to open: ↩ belongs to whatever else wants it, and a
                // handled-but-silent Return is the "confident-looking no-op"
                // this file keeps refusing to ship.
                .onKeyPress(.return) {
                    openBoard(model.selectedRowBoardAction) ? .handled : .ignored
                }
            } else {
                ContentUnavailableView(
                    "Still starting", systemImage: "hourglass",
                    description: Text(model.status))
            }
        }
        .safeAreaInset(edge: .top) { header }
        // No `.navigationTitle`: this is a console face now, and a title set
        // here propagates to the *board window* and renames it (#263).
        // Keyed on `isReady`, not bare: the toolbar is live before `start()`
        // finishes, and a bare `.task` firing then would find no registry, return
        // silently, and leave the page asserting "nothing found" about a scan
        // that never ran.
        .task(id: model.isReady) {
            // Only on first arrival: rebuilding costs one `gh repo list` per
            // owner, and coming back from a fix already refreshed the list.
            if model.isReady, model.repoRows.isEmpty {
                await model.refreshRepoRows()
            } else if model.isReady {
                // The figures alone: three grouped statements, no `gh` and no
                // disk scan, so the guard above would be paying the wrong price
                // here. `else` rather than a second unconditional call, because
                // `refreshRepoRows()` reads the tallies itself — running both
                // is six statements where three answer.
                //
                // ⚠️ This is *not* "on every arrival", which is what this
                // comment claimed until code review measured it. `.task` runs
                // when the view is created and is cancelled when it goes away,
                // so re-focusing a Repositories window that stayed open re-runs
                // nothing. What bounds the staleness is the header's **Refresh**,
                // which goes through `reloadRepoRows()` and reassigns all three
                // values together.
                await model.refreshRepoTallies()
            }
        }
        .forgetConfirmation(model: model, on: .repositories)
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
            Text(
                Self.countSentence(
                    rows: model.repoRows, failures: model.repoListingFailures,
                    isReconciling: model.isReconciling, root: model.layout.root)
            )
            .font(Type.prose)
            .foregroundStyle(.secondary)

            // Criterion 1: the owner and the error, said out loud, beside
            // whatever *did* read. Not instead of the rows — the disk scan and
            // the store read both succeeded and have real answers, and blanking
            // them for one owner's rate limit is the regression #131 fixed for
            // the board.
            //
            // No retry button, for #131's reason unchanged: re-reading fails
            // identically, and the header already has **Refresh**.
            ForEach(model.repoListingFailures, id: \.owner) { failure in
                Label(Self.bannerLine(failure), systemImage: "exclamationmark.triangle.fill")
                    .font(Type.prose)
                    .foregroundStyle(Palette.refused)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel(Self.bannerLine(failure))
            }

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

    /// The sentence above the rows.
    ///
    /// `nonisolated static` for the reason `clauses`, `icon`, `tint` and
    /// `verdict` are: what the page *says* is assertable, and `ElliotAppKitTests`
    /// reads it. It takes the failures rather than asking the model, because the
    /// two new rules are about them.
    ///
    /// **Any failed listing and it counts nothing.** Not the rows that need
    /// attention, and not the "nothing needs attention" that stands in for
    /// them — with part of the tree unread, both are claims about a whole nobody
    /// measured. It says what it counted and what it could not.
    ///
    /// **No rows *and* a failure is not an empty tree.** The direct analogue of
    /// `BoardPhase.of` refusing `.empty` while `unreadableCount > 0`: "Nothing
    /// found under `<root>`" is a claim about the disk, and the disk was never
    /// what failed.
    nonisolated static func countSentence(
        rows: [RepoRow], failures: [OwnerListingFailure],
        isReconciling: Bool, root: String
    ) -> String {
        let unlistable = failures.isEmpty
            ? []
            : ["\(failures.count) owner\(failures.count == 1 ? "" : "s") could not be listed"]

        guard !rows.isEmpty else {
            if isReconciling { return "Reading GitHub, the disk and the board…" }
            // The banner underneath names each owner and its error; this line
            // only has to stop asserting the one thing that is not known.
            if let unlistable = unlistable.first { return unlistable + "." }
            return "Nothing found under \(root)."
        }
        let repositories = "\(rows.count) repositor\(rows.count == 1 ? "y" : "ies")"
        guard failures.isEmpty else {
            return ([repositories] + unlistable).joined(separator: " · ")
        }
        return ([repositories] + clauses(for: rows)).joined(separator: " · ")
    }

    /// One failed owner, as one line. A static so the `Label`, its accessibility
    /// label and the test all read the same string — an unlabelled banner is an
    /// unverifiable one, and this page's on-screen check is an accessibility-tree
    /// diff.
    nonisolated static func bannerLine(_ failure: OwnerListingFailure) -> String {
        "GitHub could not list \(failure.owner): \(failure.reason)"
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
            // The double-click lives on *this* half of the row, never the whole
            // of it. A gesture on the row fires for taps on its descendants
            // too, so a row-wide one made double-clicking `Forget` or
            // `Move to …` run that repair **and** yank the window to the board
            // — `CLAUDE.md` records the same shape costing this project a
            // deselect that closed the panel being read.
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
                // Only for a row Elliot drives. `board` is nil for every other,
                // so nothing is drawn at all rather than a zero — blank never
                // means zero, because a row that shows nothing is a row with no
                // element here (#209, criterion 4).
                if let board = row.board {
                    Fact(text: Self.boardLine(board), tint: Palette.quiet, small: true)
                        .help(board.spendToday.sentence())
                    if let reason = board.refreshFailure {
                        // The banner's own symbol and tint, because it is the
                        // same fact — and no Retry: this page's header already
                        // carries Refresh, and a second control re-running the
                        // same failing call is #131's rejected retry restated.
                        HStack(alignment: .firstTextBaseline, spacing: 4) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.system(size: 9))
                                .foregroundStyle(Palette.attention)
                            Text(Self.refreshFailureLine(reason))
                                .font(Type.factSmall)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        .help(Self.refreshFailureLine(reason))
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel(Self.refreshFailureLine(reason))
                    }
                }
            }

            Spacer(minLength: 8)
            }
            .contentShape(Rectangle())
            // `simultaneousGesture` rather than `.onTapGesture(count: 2)`: the
            // latter competes with the `List`'s own click handling for the row,
            // and what is wanted is both — select *and* open.
            //
            // The selection is written here rather than left to the `List`
            // recognising alongside, because ⌘↩ afterwards acts on
            // `selectedRepoRowID`: if the list did not also select, the
            // keyboard would re-scope the board to the row selected *before*
            // this one. Writing it makes the two agree by construction instead
            // of by a coincidence this branch could not actuate to measure.
            .simultaneousGesture(
                TapGesture(count: 2).onEnded {
                    model.selectedRepoRowID = row.id
                    openBoard(row.boardAction)
                })

            VStack(alignment: .trailing, spacing: 4) {
                // Above the actions, because it is not one: it is the setting
                // that decides what those actions will run. `boardButton` keeps
                // its place directly beneath, as the only non-repair button.
                methodPicker(row)

                // Above the fixes, because it is the only one of these buttons
                // that is not a repair — see `RepoRowBoardAction`.
                boardButton(row)

                // One button per legal fix, and nothing here deletes: `RepoFix`
                // has no `.delete` case, deliberately.
                ForEach(row.fixes, id: \.self) { fix in
                    Button(fix.label) { Task { await model.apply(fix) } }
                        .controlSize(.small)
                        .disabled(model.isReconciling)
                        .help(explain(fix, in: row))
                }
            }
        }
        .padding(.vertical, 4)
        .contextMenu {
            // Conditional content rather than a conditionally-applied modifier:
            // switching the modifier on and off would change the row's view
            // identity for a menu.
            if case .open = row.boardAction {
                Button("Open board") {
                    // Selects for the same reason the double-click does.
                    model.selectedRepoRowID = row.id
                    openBoard(row.boardAction)
                }
            }
        }
    }

    /// The method this repository runs — or nothing at all for a row that is not
    /// registered.
    ///
    /// Nothing rather than a disabled control: an unregistered clone has no
    /// `Repo` to write to, and a greyed picker beside it would name a setting
    /// that does not exist yet — the confident-looking no-op this file keeps
    /// refusing to ship. The row's own `Register` fix is the way in.
    ///
    /// ⚠️ **The gate is registration — `repoID != nil` — and that is deliberate,
    /// not the mistake `RepoRow.showsBoardFigures` warns about.** That property
    /// says *"Not `repoID != nil`"* because *figures* are meaningless for an
    /// out-of-scope row; but the *cards* of a registered fork are still on the
    /// board and still draggable, which is exactly `boardAction`'s own rule —
    /// *"Registration is the gate, not `issue == .ok`"*. A registered
    /// `.outOfScope` row therefore gets a picker on purpose: a repository whose
    /// cards can run something must be able to say what.
    ///
    /// It reads the registration out of `model.repos` rather than off the
    /// `RepoRow`, because a row is a *reconciliation* of GitHub, the disk and
    /// the registration and carries no `methodID`. `repoID` is the join.
    @ViewBuilder
    private func methodPicker(_ row: RepoRow) -> some View {
        if let repoID = row.repoID, let repo = model.repos.first(where: { $0.id == repoID }) {
            Picker(
                "Method",
                selection: Binding(
                    get: { repo.methodID },
                    set: { value in Task { await model.setRepoMethod(repo, methodID: value) } }
                )
            ) {
                // `nil` is its own row, and it is **not** the default pack's row.
                // Collapsing the two would make a repository that never chose
                // look like one that did, and it would stop following the
                // default if the default ever moved.
                Text(Self.unsetMethodLabel()).tag(String?.none)
                ForEach(MethodCatalog.builtIn) { pack in
                    Text(pack.displayName).tag(String?.some(pack.id))
                }
                // An id this build has no pack for still has to be visible and
                // still has to be leaveable. Without a row carrying this tag the
                // menu renders blank, which reads as "no method" — exactly the
                // silent substitution `MethodResolution.unknown` exists to stop,
                // restored by the view.
                if case .unknown(let id) = repo.method {
                    Text(Self.unknownMethodLabel(id)).tag(String?.some(id))
                }
            }
            .pickerStyle(.menu)
            .controlSize(.small)
            .labelsHidden()
            .frame(maxWidth: 190)
            // A sweep in flight is two writers on one checkout; changing what it
            // runs mid-sweep is the same hazard the fix buttons refuse.
            .disabled(model.isReconciling)
            .help(Self.methodHelp(repo.method))
            .accessibilityLabel("Method for \(row.nameWithOwner ?? row.id)")
        }
    }

    /// The board action, as a button — or as nothing at all.
    ///
    /// Exhaustive over `RepoRowBoardAction` with no `default:`, for the reason
    /// `icon`/`tint`/`verdict` are: a fourth case must fail to compile here so
    /// someone decides what the row offers, instead of inheriting silence.
    @ViewBuilder
    private func boardButton(_ row: RepoRow) -> some View {
        switch row.boardAction {
        case .open:
            Button("Open board") { openBoard(row.boardAction) }
                .controlSize(.small)
                // Deliberately **not** `.disabled(model.isReconciling)`, unlike
                // every button below it. A sweep in flight is a reason not to
                // *repair* a repository — two writers on one checkout — and no
                // reason whatsoever to refuse to show its cards.
                .help(Self.boardHelp(row) ?? "")
        case .registerFirst, .unavailable:
            // Nothing. `.registerFirst` is already served by the `Register` fix
            // the row carries in the `ForEach` above, and offering both would
            // name an act that cannot work yet (criterion 3). `.unavailable`
            // has nowhere to go.
            EmptyView()
        }
    }

    /// The one implementation the button, the double-click, the context menu
    /// and ↩ all share.
    ///
    /// The *judgement* — unwrap `.open`, check the registration still exists,
    /// explain the refusal — is `AppModel.showBoard(_:)`, so ⌘↩ in `ElliotApp`
    /// asks the same question rather than repeating it across a module
    /// boundary. What is left here is the one line that genuinely cannot move:
    /// `openWindow` is an environment value and the model has no environment.
    ///
    /// The window is raised only when the scoping actually happened, so a
    /// refused hop does not answer with a board that did not change — a
    /// confident-looking no-op. Returning whether it acted is what lets
    /// `onKeyPress` say `.ignored` and leave ↩ to whatever else wants it.
    @discardableResult
    private func openBoard(_ action: RepoRowBoardAction) -> Bool {
        guard model.showBoard(action) else { return false }
        openWindow(id: "board")
        return true
    }

    /// Why pressing **Open board** is worth it, in the row's own name.
    ///
    /// `nonisolated static` for the reason `verdict`, `boardLine` and the rest
    /// are: what the page *says* is assertable, and `ElliotAppKitTests` reads
    /// exactly this string.
    ///
    /// It spells out `owner/name` rather than the `displayName` the row's title
    /// uses, and that is the feature rather than a detail: the board's picker
    /// lists last path components, in which `phmatray/Elliot` and
    /// `Atypical-Consulting/Elliot` are the same word. Dropping the owner here
    /// would restate the ambiguity this action exists to remove.
    ///
    /// `nil` for the other two actions — no board action, nothing to explain.
    nonisolated static func boardHelp(_ row: RepoRow) -> String? {
        guard case .open = row.boardAction else { return nil }
        return "Show \(row.nameWithOwner ?? row.id)'s cards on the board."
    }

    /// The last path component of `owner/name` — the name a person uses.
    private func displayName(_ nameWithOwner: String) -> String {
        String(nameWithOwner.split(separator: "/").last ?? Substring(nameWithOwner))
    }

    /// `RepoFix.forget` carries only a `repoID`, so the row supplies the name —
    /// the same expression the row's title uses, so the tooltip and the heading
    /// above it cannot name different things.
    private func explain(_ fix: RepoFix, in row: RepoRow) -> String {
        switch fix {
        case .clone(let nameWithOwner, let into):
            "Clone \(nameWithOwner) into \(into)."
        case .move(let from, let to):
            "Move \(from) to \(to), and repoint the registration. Nothing is deleted."
        case .register(let path):
            "Let Elliot drive the checkout at \(path)."
        case .forget:
            Self.explainForget(displayName: row.nameWithOwner.map(displayName) ?? row.id)
        case .pull(let path):
            "Fast-forward \(path) to its upstream. Never merges, never rebases, and refuses outright "
                + "if anything there is uncommitted."
        }
    }

    /// The forget tooltip is `ForgetPrompt`'s, not this file's: the two screens
    /// had already drifted here, one naming cards and the other naming nothing.
    nonisolated static func explainForget(displayName: String) -> String {
        ForgetPrompt.tooltip(displayName: displayName)
    }

    // MARK: - Method vocabulary

    /// The menu row for a repository that has never chosen.
    ///
    /// It names the pack it falls back to *and* says it is a fallback, because
    /// those are two facts and a reader deciding whether to choose needs both.
    nonisolated static func unsetMethodLabel() -> String {
        guard case .unset(let pack) = MethodCatalog.resolve(nil) else { return "Default" }
        return "Default — \(pack.displayName)"
    }

    /// The menu row for an id this build has no pack for.
    nonisolated static func unknownMethodLabel(_ id: String) -> String {
        "\(id) — not installed"
    }

    /// What choosing this method means, in one sentence.
    ///
    /// Exhaustive with no `default:`, for the reason `icon`/`tint`/`verdict`
    /// are: a fourth `MethodResolution` case must fail to compile here so
    /// someone writes its sentence instead of inheriting one that is wrong.
    nonisolated static func methodHelp(_ resolution: MethodResolution) -> String {
        switch resolution {
        case .unset(let pack):
            "Never chosen — dragging a card here runs \(pack.displayName). \(pack.summary)"
        case .chosen(let pack):
            "Dragging a card here runs \(pack.displayName). \(pack.summary)"
        case .unknown(let id):
            "Set to \"\(id)\", which this build has no pack for. Nothing can be dragged here "
                + "until it names a method Elliot knows."
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
        // The dashed outline against `.unlisted`'s filled one, because the
        // difference between the two verdicts is exactly an answer that is
        // missing rather than negative. Same family so nobody has to learn a
        // second symbol; a different weight so the two rows never read alike.
        case .notChecked: "questionmark.circle.dashed"
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
        // The same tint, and no sixth accent invented for it: `BrandColorTests`
        // pins five, and a new one is a design decision rather than a merge. The
        // distinction between "GitHub said nothing about it" and "GitHub was
        // never asked" is carried by the word and the symbol, which is where the
        // test asserts it.
        case .notChecked: Palette.attention
        case .notCloned, .notRegistered, .missing, .misplaced: Palette.attention
        // As above: the tint the `default:` arm gave them, preserved verbatim.
        case .behind, .dirty, .ahead, .diverged, .detached, .noRemote, .unreadable:
            Palette.attention
        }
    }

    /// What one repository's board holds, as one line.
    ///
    /// `nonisolated static` for the reason `countSentence` and `verdict` are:
    /// what the page *says* is assertable, and `ElliotAppKitTests` reads exactly
    /// this string — which is what makes the on-screen check an
    /// accessibility-tree diff rather than a squint.
    ///
    /// **`no cards` rather than `0 cards`.** Criterion 3 asks the row to say so,
    /// and a zero is what a reader skims past. It is only ever reached by a row
    /// entitled to figures at all: a row Elliot does not drive has `board == nil`
    /// and draws no element, which is criterion 4 and is decided in
    /// `RepoBoardDigest`, not here.
    ///
    /// Spend is appended only when there is some, on the convention
    /// `SyncSummary.sentence` already holds — a clean pass does not advertise a
    /// zero. It is written as a plain amount rather than through
    /// `Spend.sentence`, whose "at least; N of M runs never reported a cost"
    /// qualifier is a paragraph on a row; the row hands that sentence to
    /// `.help(…)` instead, so the unknown-cost caveat is one hover away rather
    /// than lost.
    nonisolated static func boardLine(_ tally: RepoBoardTally, locale: Locale = .current) -> String {
        var clauses: [String] = [
            tally.cards == 0 ? "no cards" : "\(tally.cards) card\(tally.cards == 1 ? "" : "s")"
        ]
        if tally.runsInFlight > 0 { clauses.append("\(tally.runsInFlight) running") }
        if tally.spendToday.totalUSD > 0 {
            clauses.append("\(MoneyFormat.usd(tally.spendToday.totalUSD, locale: locale)) today")
        }
        return clauses.joined(separator: " · ")
    }

    /// Why this repository's cards may be stale, in `gh`'s own words.
    ///
    /// The reason is quoted rather than paraphrased, and the row keeps its
    /// verdict beside it: `ok` and *"could not be refreshed"* answer two
    /// different questions — where the clone is, and whether what is on its
    /// board is current — and a row that dropped either would be answering the
    /// wrong one.
    nonisolated static func refreshFailureLine(_ reason: String) -> String {
        "could not be refreshed: \(reason)"
    }

    nonisolated static func verdict(_ issue: RepoIssue) -> String {
        switch issue {
        case .ok: "ok"
        case .notCloned: "not cloned"
        case .notRegistered: "not registered"
        case .missing: "missing"
        case .misplaced: "misplaced"
        case .unlisted: "unlisted"
        case .notChecked: "not checked"
        case .outOfScope(.fork): "fork"
        case .outOfScope(.archived): "archived"
        case .outOfScope(.empty): "empty"
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
        // `repoBoardRows`, not `repoRows`: the figures are attached by
        // `RepoBoardDigest` on read, so the join with the session's refresh
        // failures happens here rather than a refresh behind the board's banner.
        let grouped = Dictionary(grouping: model.repoBoardRows) { row in
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
