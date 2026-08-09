import ElliotModel
import SwiftUI

/// The selected card, drawn as a panel that belongs to the column it came from.
///
/// `InspectorView`, which this succeeds, was a 344pt strip pinned to the
/// trailing edge of the window — as far from the card that was clicked as the
/// window allows, with nothing connecting the two, and with the run log stacked
/// underneath several screens of issue body. This one is measured **in columns**
/// (`PanelLayout.panelWidth`), takes its top rail from the origin column's
/// `railTint`, and at three spans reads the issue and the runs side by side.
///
/// ⚠️ **The container does not clip, and must not.** The caret notched into its
/// edge and the tether reaching across the gutter to the card both sit *outside*
/// these bounds; a `.clipShape` here is precisely what would erase them. Each
/// pane clips itself instead, rounding only the bottom corner it actually owns.
///
/// The shape of the panel — which blocks are in the header, which panes are
/// built — is decided by `PanelLayout`, not here. `ElliotApp` has no test
/// target and this view has no assertions in it: what a test can hold lives in
/// those pure functions, and this places what they return.
struct DetailPanelView: View {
    @Environment(AppModel.self) private var model

    /// The board's column width, passed in rather than measured here.
    ///
    /// The panel is measured in columns, so it needs the same number the columns
    /// were laid out with. A second `GeometryReader` inside the one that already
    /// answered that question would be a second answer to it.
    let columnWidth: CGFloat

    @State private var editor = CardEditor()
    @State private var saveError: String?

    /// Which pane is showing when only one fits.
    ///
    /// `@State` rather than a field on `AppModel`: the panel keeps **one**
    /// identity across selections — `BoardSlot.panel` is a single case for
    /// exactly that reason — so this survives clicking from card to card, and
    /// resets only when the panel closes, which is when a reading mode has
    /// stopped meaning anything.
    @State private var pane: PanelPane = .issue

    /// No empty state on purpose: the board only builds this view when a card is
    /// selected, so there is no reachable "nothing selected" case. One existed
    /// briefly, while `.inspector()` kept the panel open across a deselect —
    /// reverted with it in #52.
    var body: some View {
        if let card = model.selectedCard {
            panel(card)
                .frame(width: PanelLayout.panelWidth(
                    columnWidth: columnWidth, spans: model.panelSpans
                ))
                .frame(maxHeight: .infinity, alignment: .top)
                .task(id: card.id) {
                    editor.end()
                    saveError = nil
                    await model.refreshRuns(cardID: card.id)
                    // Here and nowhere else: this is the one place that knows a
                    // single card is open. `CardView.task` calls `refreshRuns`
                    // for every visible card, and the 100-row read has no
                    // business happening that often.
                    await model.refreshHistory(cardID: card.id)
                }
        }
    }

    // MARK: - The container

    private func panel(_ card: Card) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            rail(card)
            header(card)
            Divider()
            if editor.isEditing {
                editorBody(card)
                Divider()
                editorActions(card)
            } else {
                paneRow(card)
            }
        }
        // ⛔ On the **panel**, not on `editorBody` — which is where it was, and
        // that was wrong in the one place criterion 6 is about. `CardEditor.begin`
        // refuses a card carrying an issue number, so a filed card can never
        // reach edit mode, so the load never ran for it: `labels(for:)` stayed
        // unestablished, `isMissing` was unconditionally false, and the chips
        // that exist to *mark* a label the repository lacks drew it as an
        // ordinary one. Worse, it was intermittent — the mark appeared only if
        // the reader happened to have opened the editor on some other, unfiled
        // card in the same repository earlier in the session.
        //
        // One `gh label list` per repository per selection, which is the same
        // budget Preflight already spends and far less than the panel's own
        // reads. Deliberately **not** skipped when a list is already held: this
        // codebase's recurring defect is serving a remembered answer as a
        // current one, and a label created since — by Preflight's own
        // `createLabels` button, one screen over — would otherwise go on reading
        // as missing.
        .task(id: card.repoID) { await model.loadLabels(for: card.repoID) }
        .background(Color(nsColor: .windowBackgroundColor), in: outline)
        .overlay {
            outline.strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1)
        }
        // On the edge that is *not* against the origin column, so the handle is
        // never on the same side as the caret and the tether. Those are drawn
        // by `CaretRail` as a board-level overlay with `.allowsHitTesting(false)`
        // — they cannot take a drag from the handle, and the handle cannot
        // paint over them, because it is on the other edge of the panel.
        .overlay(alignment: opensLeft(card) ? .leading : .trailing) {
            @Bindable var model = model
            PanelResizeHandle(
                spans: $model.panelSpans,
                columnWidth: columnWidth,
                opensLeft: opensLeft(card),
                help: "Drag to make the panel two or three columns wide",
                label: "Panel width"
            )
        }
        // The only shadow on the board: the panel floats above the columns it is
        // placed between, and that is what says it is not one of them.
        .shadow(
            color: .black.opacity(Metric.panelElevation.opacity),
            radius: Metric.panelElevation.radius,
            y: Metric.panelElevation.y
        )
        .accessibilityElement(children: .contain)
        // Names the card and the column, because "Card details" told a
        // screen-reader user the one thing they already knew. The sentence is
        // built by a pure function so it can be asserted; it has to be applied
        // *here* rather than from the board, since `accessibilityLabel`
        // resolves innermost-first and an outer one would be silently inert.
        .accessibilityLabel(
            BoardAccessibility.panelLabel(title: card.displayTitle, column: card.column)
        )
    }

    /// The panel's silhouette, used as a background fill and as a border — never
    /// as a clip. See the ⚠️ on the type.
    private var outline: RoundedRectangle {
        RoundedRectangle(cornerRadius: Metric.panelRadius)
    }

    /// Which edge of its column the panel opened on — and so which of its own
    /// edges is the outer one. Read through `PanelLayout` rather than compared
    /// here, so the handle and the board's own placement cannot disagree.
    private func opensLeft(_ card: Card) -> Bool {
        PanelLayout.opensLeft(of: card.column)
    }

    // MARK: - Resizing
    //
    // The handle itself is `PanelResizeHandle`, applied as an overlay in
    // `panel(_:)` above. It lived here until #151, when the analysis panel
    // became the board's second resizable panel: the strip carries four fixes
    // whose reasons are written into it, and a second copy of it would be a
    // second copy of those.
    //
    // Both affordances still write the same `model.panelSpans` — the drag and
    // View ▸ Narrow / Widen Details, which a reader looking at the panel has no
    // reason to find.

    /// The origin column's standing cost, carried onto the panel so the panel
    /// reads as *of* that column rather than as a floating window that happens
    /// to be nearby. The same two points of colour the column itself wears.
    private func rail(_ card: Card) -> some View {
        UnevenRoundedRectangle(
            topLeadingRadius: Metric.panelRadius, topTrailingRadius: Metric.panelRadius
        )
        .fill(card.column.railTint)
        .frame(height: Metric.railHeight)
        .accessibilityHidden(true)
    }

    // MARK: - Header

    private func header(_ card: Card) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top) {
                Text(card.displayTitle)
                    .font(Type.sheetTitle)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Button {
                    model.selectedCardID = nil
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close details")
            }

            HStack(spacing: 6) {
                ConsoleLabel(text: card.column.displayName, tint: card.column.railTint)
                if let repo = model.repo(for: card) {
                    Fact(text: repo.nameWithOwner, tint: Palette.quiet, small: true)
                }
                Spacer()
                Fact(text: "here \(Elapsed.age(of: card.columnEnteredAt))",
                     tint: Palette.quiet, small: true)
            }

            // In Review is the only column Elliot fills by itself, and a card
            // that turned up there explained nothing about how. The decision was
            // `PRWatcher`'s and was already recorded; this only reads it back.
            if let note = arrivalNote(card) {
                Text(note)
                    .font(Type.prose)
                    .foregroundStyle(Palette.inert)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // `card.isEditable`, which is `CardEditor.begin`'s guard and
            // `BoardService.updateCard`'s refusal — one rule, read three times.
            // Offering a button whose action is refused one layer down is how
            // this drifted: the panel asked a looser question than the service
            // answered.
            if !editor.isEditing, card.isEditable {
                Button("Edit story", systemImage: "pencil") { editor.begin(from: card) }
                    .controlSize(.small)
            }

            // Drawn from `PanelLayout.headerRegions`, which takes no pane
            // argument — so nothing below can be hidden by the switch, including
            // the one block that must never be.
            ForEach(headerRegions(card), id: \.self) { region in
                switch region {
                case .mergeConfirmation:
                    if let pending = pendingMerge(card) {
                        MergeConfirmation(pending: pending)
                    }
                case .lastError:
                    lastError(card)
                case .nextStep:
                    nextStep(card)
                case .paneSwitch:
                    paneSwitch(card)
                }
            }
        }
        .padding(14)
    }

    private func headerRegions(_ card: Card) -> [PanelHeaderRegion] {
        PanelLayout.headerRegions(
            spans: model.panelSpans,
            isEditing: editor.isEditing,
            isMergePending: pendingMerge(card) != nil,
            hasNextStep: card.column.naturalNext != nil,
            hasLastError: card.lastError != nil
        )
    }

    // MARK: - What went wrong

    /// The card's `lastError`, in full and selectable.
    ///
    /// `CardView` was the only place in the app that drew this: 11pt, two lines,
    /// no tooltip, no selection, inside a column that can be 226pt wide. The
    /// panel — two to three columns across, and the thing a reader opens
    /// *because* something went wrong — never mentioned it at all.
    ///
    /// A header region rather than a pane, so the pane switch cannot hide it —
    /// the same guarantee `PanelLayout.headerRegions` spells out for the merge
    /// confirmation, and it comes for free from being in that list.
    ///
    /// ⚠️ It spends `Palette.refused` on a surface and can sit directly above a
    /// refused next step washed in the same tint. They are told apart by their
    /// console labels and by this one's border, which the next step only draws
    /// on its own button — but it is a real adjacency and the pair is what an
    /// on-screen check should look at first.
    @ViewBuilder
    private func lastError(_ card: Card) -> some View {
        if let message = card.lastError {
            VStack(alignment: .leading, spacing: 4) {
                ConsoleLabel(text: "Last error", tint: Palette.refused)
                Text(message)
                    .font(Type.prose)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
            .background(Surface.washFaint(Palette.refused))
            .clipShape(RoundedRectangle(cornerRadius: Metric.cardRadius))
            .overlay {
                RoundedRectangle(cornerRadius: Metric.cardRadius)
                    .strokeBorder(Surface.washBorder(Palette.refused), lineWidth: 1)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Last error, \(message)")
        }
    }

    /// The armed merge, but only this card's. `pendingFollowUps` is one field on
    /// the model and the panel draws one card.
    private func pendingMerge(_ card: Card) -> AppModel.PendingMerge? {
        guard let pending = model.pendingFollowUps, pending.cardID == card.id else { return nil }
        return pending
    }

    /// Only for the move that actually put the card where it is now — an older
    /// audit describes a column it has since left.
    private func arrivalNote(_ card: Card) -> String? {
        guard let audit = model.lastMove[card.id], audit.to == card.column else { return nil }
        return audit.origin.arrivalNote
    }

    // MARK: - Next step

    /// The same verdict the columns show, as a button that says what it does.
    @ViewBuilder
    private func nextStep(_ card: Card) -> some View {
        if let next = card.column.naturalNext {
            let consequence = Consequence.of(model.preview(card, to: next))
            VStack(alignment: .leading, spacing: 6) {
                ConsoleLabel(text: "Next step")
                Button {
                    Task { await model.move(cardID: card.id, to: next) }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: consequence.isRefused ? "hand.raised.fill" : "arrow.right")
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Move to \(next.displayName)")
                                .font(Type.rowTitle)
                            Text(consequence.summary)
                                .font(Type.prose)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 0)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(consequence.isRefused
                        ? Surface.washFaint(consequence.tint)
                        : Surface.wash(consequence.tint))
                    .clipShape(RoundedRectangle(cornerRadius: Metric.cardRadius))
                    .overlay {
                        RoundedRectangle(cornerRadius: Metric.cardRadius)
                            .strokeBorder(Surface.washBorder(consequence.tint), lineWidth: 1)
                    }
                }
                .buttonStyle(.plain)
                .disabled(consequence.isRefused)
                .help(consequence.summary)
            }
        }
    }

    // MARK: - The pane switch

    /// Only drawn when a pane is actually hidden — `headerRegions` decides that,
    /// so the switch and the body cannot disagree about how many panes there are.
    private func paneSwitch(_ card: Card) -> some View {
        Picker("Details to show", selection: $pane) {
            ForEach(PanelPane.allCases) { which in
                Text(paneTitle(which, card: card)).tag(which)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .accessibilityLabel("Details to show")
    }

    /// ⚠️ Built as a `String` and handed to `Text` as one. Interpolating an `Int`
    /// into a `Text` directly makes it a `LocalizedStringKey`, which formats the
    /// number for the reader's locale — issue 1234 rendered as "Issue #1.234" on
    /// a European machine, the same bug `MergeConfirmation` documents. An issue
    /// number is an identifier, not a quantity.
    private func paneTitle(_ which: PanelPane, card: Card) -> String {
        switch which {
        case .issue:
            guard let issue = card.issueNumber else { return which.displayName }
            return "\(which.displayName) #\(issue)"
        case .runs:
            let count = model.runsByCard[card.id]?.count ?? 0
            guard count > 0 else { return which.displayName }
            return "\(which.displayName) · \(count)"
        }
    }

    // MARK: - Body

    /// One pane, or two side by side. Never two with one hidden: what is not
    /// showing is not built, which is the difference between a pane a
    /// screen-reader skips and one it reads out anyway.
    private func paneRow(_ card: Card) -> some View {
        let panes = PanelLayout.panes(spans: model.panelSpans, selected: pane)

        return HStack(spacing: 0) {
            ForEach(Array(panes.enumerated()), id: \.element) { index, which in
                if index > 0 { Divider() }
                paneContent(which, card: card)
                    .frame(maxWidth: .infinity)
                    .clipShape(paneShape(index: index, of: panes.count))
            }
        }
    }

    private func paneContent(_ which: PanelPane, card: Card) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                switch which {
                case .issue:
                    provenance(card)
                    labels(card)
                    PRStatusBlock(card: card)
                    IssuePane(card: card)
                case .runs:
                    // Above the runs, mirroring `provenance` above the issue: a
                    // row saying a move started `create-issue` sits directly
                    // over the run box it names.
                    MoveHistoryBlock(card: card)
                    RunsPane(card: card)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// The bottom corner this pane owns, and only that one.
    ///
    /// The rounding at the foot of the panel has to be the panes' own, because
    /// the container is not allowed to clip — see the ⚠️ on the type. A single
    /// pane owns both corners; the leading of two owns the left, the trailing
    /// the right.
    private func paneShape(index: Int, of count: Int) -> UnevenRoundedRectangle {
        UnevenRoundedRectangle(
            bottomLeadingRadius: index == 0 ? Metric.panelRadius : 0,
            bottomTrailingRadius: index == count - 1 ? Metric.panelRadius : 0
        )
    }

    // MARK: - Editing

    /// Editing replaces the body rather than sitting inside a pane: a card is
    /// only editable until it carries an issue number, and while it is being
    /// rewritten there is nothing on GitHub to read beside it.
    private func editorBody(_ card: Card) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                CardFieldsEditor(
                    draft: $editor.draft,
                    repositoryLabels: model.labels(for: card.repoID)
                )
                if let saveError {
                    Text(saveError).font(Type.prose).foregroundStyle(Palette.refused)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        // Square: the actions row below owns the bottom of the panel.
        .clipShape(Rectangle())
    }

    private func editorActions(_ card: Card) -> some View {
        HStack {
            Spacer()
            Button("Cancel", role: .cancel) { editor.end(); saveError = nil }
            Button("Save changes") { save(card, editor.draft) }
                .keyboardShortcut(.defaultAction)
                .disabled(!editor.draft.isValid)
        }
        .padding(12)
    }

    private func save(_ card: Card, _ draft: CardDraft) {
        Task {
            if await model.updateCard(id: card.id, draft: draft) {
                editor.end()
                saveError = nil
            } else {
                // Filed, or deleted, since the editor opened. Stay in edit mode
                // — the typed text is still here.
                saveError = model.status
            }
        }
    }

    // MARK: - Provenance

    /// Everything here was read back from `gh` — never parsed out of what the
    /// agent said — so it is all set in the fact face. It heads the Issue pane
    /// because it is what GitHub holds, which is what that pane is about.
    @ViewBuilder
    private func provenance(_ card: Card) -> some View {
        if card.issueNumber != nil || card.prNumber != nil || card.branch != nil {
            VStack(alignment: .leading, spacing: 6) {
                ConsoleLabel(text: "On GitHub")
                if let issue = card.issueNumber {
                    row("Issue", "#\(issue)", url: card.issueURL)
                }
                if let pr = card.prNumber {
                    row("Pull request", "\(pr)", url: card.prURL)
                }
                if let branch = card.branch {
                    row("Branch", branch, url: nil)
                }
                // Exactly when the Edit button is absent, and saying which
                // record replaced it. A card imported from a pull request that
                // closes no issue used to get no sentence at all — and an Edit
                // button, which is the other half of the same drift.
                if let refusal = card.editRefusal {
                    Text(refusal.sentence)
                        .font(Type.prose)
                        .foregroundStyle(.tertiary)
                        .padding(.top, 2)
                }
            }
        }
    }

    /// The labels the card asks for, read-only, beside what GitHub already
    /// holds — because that is the question they answer: *what will this issue
    /// carry*.
    ///
    /// Not removable here. A card's labels obey the same rule as its story:
    /// correctable in the editor until it is filed, and refused afterwards.
    /// Once the issue exists, github.com holds the labels and the card is a
    /// record of what was asked for.
    @ViewBuilder
    private func labels(_ card: Card) -> some View {
        if PanelLayout.showsLabels(card) {
            VStack(alignment: .leading, spacing: 6) {
                ConsoleLabel(text: card.issueNumber == nil ? "Labels to apply" : "Labels asked for")
                LabelChips(
                    names: card.labels,
                    isMissing: { model.labels(for: card.repoID).isMissing($0) }
                )
            }
        }
    }

    private func row(_ label: String, _ value: String, url: String?) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(Type.prose)
                .foregroundStyle(.secondary)
                .frame(width: 84, alignment: .leading)
            Fact(text: value, tint: .primary)
                .textSelection(.enabled)
            if let url, let real = URL(string: url) {
                Button {
                    NSWorkspace.shared.open(real)
                } label: {
                    Image(systemName: "arrow.up.forward.square").font(.system(size: 10))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .accessibilityLabel("Open \(label) on GitHub")
            }
            Spacer()
        }
    }
}
