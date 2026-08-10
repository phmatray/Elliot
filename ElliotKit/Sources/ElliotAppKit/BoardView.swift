import AppKit
import ElliotEngine
import ElliotModel
import ElliotStore
import SwiftUI
import UniformTypeIdentifiers

public struct BoardView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.openWindow) private var openWindow
    @FocusState private var boardFocused: Bool

    /// The board's horizontal scroll, held rather than driven through a
    /// `ScrollViewReader`.
    ///
    /// `ScrollViewProxy.scrollTo(_:anchor:)` aligns a view to a `UnitPoint` and
    /// takes no offset, so it cannot express the lead that keeps the previous
    /// column showing — and with the panel inline, `anchor: .center` on the
    /// origin column pushes the panel half off the right edge, or the whole
    /// panel off-screen in the flipped case. `ScrollPosition` takes the x.
    @State private var boardScroll = ScrollPosition(edge: .leading)

    /// The window's content height, observed rather than measured by a
    /// container. Everything the console's arithmetic needs is derived from it,
    /// so a zero here means "not laid out yet" and the doors are simply refused
    /// until the first pass — which `ConsoleLayout.canOpen(contentHeight: 0)`
    /// already answers correctly.
    @State private var contentHeight: CGFloat = 0

    /// Which repository groups the reader has folded, per column.
    ///
    /// Held here rather than inside `ColumnView`, where it was, because the
    /// **keyboard** lives here. `stepCard` has to walk what a column is drawing,
    /// and a `@State` inside the column is unreachable from outside it — which
    /// is exactly how ↓ came to step into cards nobody could see, and ⌘→ to
    /// advance one (#278).
    ///
    /// ⛔ Still per column, and still not on `AppModel`. Folding a repository in
    /// Backlog must not fold it in To Do — those are different questions — and
    /// this is a reader's view of the board, not a fact about it. `collapsedDays`
    /// *is* on the model, for the one reason that does not apply here: the
    /// Archive folds the same days, so a second copy of that set drifted.
    @State private var collapsedRepos: [ElliotModel.Column: Set<UUID>] = [:]

    public init() {}

    public var body: some View {
        @Bindable var model = model

        VStack(spacing: 0) {
            // Above the board, not inside it, because the case it exists for is
            // a board with *nothing* in it: an empty column set and an
            // unreachable repository are otherwise the same screen (#42).
            unreachableBanner

            // Three states, not two. The board used to assert "No repository
            // yet" for the whole of startup — through the login-shell capture,
            // three tool lookups and a preflight sweep — to a user whose
            // repositories were in the database the entire time.
            // Asked, not decided. The board used to read `hasLoadedRepos` here
            // while the status bar below read `isReady`, which is how it came
            // to say "Still starting" over "Ready." for ever (#118).
            switch model.boardPhase {
            case .starting: startingState
            case .unreadable(let reason): unreadableState(reason)
            case .empty: emptyState
            case .ready: board
            }
            // Between the board and the status bar, so the doors that opened it
            // sit directly under what they opened. The board above takes
            // whatever height is left, which is `ConsoleLayout.boardHeight` by
            // construction rather than by a second calculation — the property
            // `theHeightsSumToWhatIsAvailable` pins.
            if let face = model.console.face {
                Divider()
                ConsoleRegion(
                    face: face,
                    height: ConsoleLayout.consoleHeight(
                        model.console.height, contentHeight: contentHeight)
                )
                // Driven by the `.animation(…, value: model.console.face)`
                // below, which is gated on `reduceMotion`; with motion reduced
                // that animation is nil and this transition is applied with no
                // animation to run it, so the console appears and disappears
                // outright.
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            Divider()
            StatusBar(contentHeight: contentHeight)
        }
        // The window's content height, read without adding a `GeometryReader`.
        // This is a layout that has been wrecked three times (#47, #50, #52,
        // #53); a container introduced to measure it is a container that can
        // change it, and this modifier only observes.
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
        .animation(reduceMotion ? nil : .snappy(duration: 0.22), value: model.console.face)
        .animation(reduceMotion ? nil : .snappy(duration: 0.22), value: model.console.height)
        .animation(reduceMotion ? nil : .snappy(duration: 0.22), value: model.selectedCardID)
        // The columns slide aside for the analysis panel the way they do for the
        // detail panel. Keyed on its own value: the one above is keyed on the
        // selection, which does not move when this panel opens.
        .animation(reduceMotion ? nil : .snappy(duration: 0.22), value: model.showingAnalysisPanel)
        .toolbar { toolbarContent }
        .navigationTitle("Elliot")
        .task(id: model.selectedRepoID) {
            await model.importIfNeeded(repoID: model.selectedRepoID)
        }
        // The board keeps focus so a card can be moved without the mouse.
        .focusable()
        .focusEffectDisabled()
        .focused($boardFocused)
        .defaultFocus($boardFocused, true)
        // The order is `EscapeRoute`'s and not this closure's. It used to be a
        // two-line guard, which was the whole rule while the selection was the
        // only dismissable thing on the board; with the console over it there is
        // an order to state, and `.ignored` still has to reach the responder
        // chain below (an inline editor's own `.onExitCommand`, then the
        // window).
        .onKeyPress(.escape) {
            switch EscapeRoute.next(
                consoleIsOpen: model.console.isOpen,
                hasSelectedCard: model.selectedCardID != nil,
                // Since #265 a `confirmationDialog` can be up *in this window*:
                // Preflight and Repositories are console faces, and both present
                // `ForgetConfirmation`. Folding the console out from under it
                // would leave a question attached to a screen that is gone.
                hasOpenDialog: model.forgetRequest != nil)
            {
            case .foldConsole:
                model.closeConsole()
                return .handled
            case .deselectCard:
                model.selectedCardID = nil
                return .handled
            case .ignored:
                return .ignored
            }
        }
        // Picking a card was pointer-only, which made every affordance built
        // for the keyboard — ⌘→, ⌘←, Escape, the whole Card menu — depend on a
        // pointer first. The arrows only move the selection; ⌘-arrow still owns
        // moving a card, and no rule leaves ElliotModel.
        .onKeyPress(.downArrow) { stepCard(by: 1) }
        .onKeyPress(.upArrow) { stepCard(by: -1) }
        .onKeyPress(.leftArrow) { stepColumn(by: -1) }
        .onKeyPress(.rightArrow) { stepColumn(by: 1) }
        // A refusal is the one status change a screen-reader user has no other
        // way to learn: the note is drawn on a card they may not be on. Only
        // refusals — announcing `status` wholesale would turn VoiceOver into a
        // ticker of import progress.
        .onChange(of: model.refusal) { _, refusal in
            guard let refusal else { return }
            AccessibilityNotification.Announcement(refusal.message).post()
        }
    }

    // MARK: - Keyboard selection

    /// The cards a column is **drawing**, in the order it draws them.
    ///
    /// Not `model.cards(in:)`, which is where both step functions used to look.
    /// That answer knows nothing about a folded repository group, nothing about
    /// Done's seven-day horizon, and nothing about the fact that an
    /// all-repositories column draws in repository order while it returns
    /// `orderIndex` order — so ↓ walked a list the reader could not see, in an
    /// order their eye could not follow. `ColumnRows` is the list the column
    /// itself draws (#278).
    private func drawnCards(in column: ElliotModel.Column) -> [Card] {
        ColumnRows.of(column, model: model, foldedRepoIDs: collapsedRepos[column, default: []])
            .cards
    }

    /// Move the selection up or down within its column.
    private func stepCard(by delta: Int) -> KeyPress.Result {
        let column = model.selectedCard?.column ?? .backlog
        let cards = drawnCards(in: column)
        guard !cards.isEmpty else { return .ignored }
        guard let current = model.selectedCard,
              let index = cards.firstIndex(where: { $0.id == current.id })
        else {
            model.selectedCardID = cards.first?.id
            return .handled
        }
        model.selectedCardID = cards[min(max(index + delta, 0), cards.count - 1)].id
        return .handled
    }

    /// Move the selection sideways, skipping columns that are **showing**
    /// nothing. If every column that way is empty the selection stays put —
    /// jumping somewhere arbitrary is worse than not moving.
    ///
    /// "Showing" rather than "holding" since #278: a column whose every group is
    /// folded draws no card, and landing the selection on one of them would be
    /// the arbitrary jump this already refuses to make.
    private func stepColumn(by delta: Int) -> KeyPress.Result {
        let order = ElliotModel.Column.allCases
        let from = model.selectedCard?.column ?? (delta > 0 ? .backlog : .done)
        guard let index = order.firstIndex(of: from) else { return .ignored }

        var candidate = model.selectedCard == nil ? index : index + delta
        while order.indices.contains(candidate) {
            if let first = drawnCards(in: order[candidate]).first {
                model.selectedCardID = first.id
                return .handled
            }
            candidate += delta
        }
        return .ignored
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            @Bindable var model = model
            Picker("Repository", selection: $model.selectedRepoID) {
                Text("All repositories").tag(UUID?.none)
                ForEach(model.repos) { repo in
                    // Badged in the list too, so a repository that could not be
                    // refreshed is findable while a *different* one is selected
                    // — otherwise the only way to learn it failed is to pick it.
                    if model.importFailure(repoID: repo.id) != nil {
                        Label(repo.displayName, systemImage: "exclamationmark.triangle.fill")
                            .tag(UUID?.some(repo.id))
                    } else {
                        Text(repo.displayName).tag(UUID?.some(repo.id))
                    }
                }
            }
            .labelsHidden()
            .frame(minWidth: 160)
        }

        ToolbarItem {
            Button {
                // No repository is assigned here any more. `AppModel.newCardRepo`
                // resolves the face's target from the board and from whatever the
                // reader picks in the face itself, so an assignment at the moment
                // of opening would freeze one guess — and, since #314, overwrite a
                // choice the reader had already made and folded away (#314).
                model.showConsoleFace(.newStory)
            } label: {
                Label("New story", systemImage: "plus")
            }
            .labelStyle(.titleAndIcon)
            .disabled(model.repos.isEmpty)
            // No `.keyboardShortcut` here: the File menu owns ⌘N, and a
            // shortcut declared in two places is matched reliably in neither.
            .help("Write a new backlog story")
        }

        ToolbarItem {
            Menu {
                Button("Forget dismissed items") {
                    Task { await model.clearDismissals() }
                }
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            } primaryAction: {
                Task { await model.refreshFromGitHub() }
            }
            .labelStyle(.titleAndIcon)
            .menuStyle(.button)
            .fixedSize()
            .disabled(model.repos.isEmpty || model.isImporting)
            .help(model.selectedRepoID == nil
                ? "Bring every repository's GitHub issues and pull requests onto the board."
                : "Bring this repository's GitHub issues and pull requests onto the board.")
        }

        ToolbarItem {
            Button {
                model.showingAnalysisPanel.toggle()
            } label: {
                Label("Analyse", systemImage: "sparkle.magnifyingglass")
            }
            .labelStyle(.titleAndIcon)
            // Tinted while open, like Details: the panel opens between columns
            // and the board scrolls, so "is it showing" stopped being answerable
            // at a glance the moment it stopped being a window.
            .tint(model.showingAnalysisPanel ? Palette.armed : nil)
            .foregroundStyle(model.showingAnalysisPanel ? Palette.armed : Color.primary)
            // ⚠️ No `.disabled`, and that is a change from the window it
            // replaces. Hiding a panel must never be blocked by the reason its
            // *contents* are unavailable — a disabled toggle is a toggle you
            // cannot switch off. The refusal is stated inside the panel by
            // `analyseHelp`, and the Start button in it is what stays disabled.
            .help(model.showingAnalysisPanel ? "Hide the analysis" : analyseHelp)
        }

        ToolbarItem {
            // Still a Button and not a Toggle. As a Toggle it read
            // `showingInspector`, so the toolbar re-vended its items in the
            // middle of the split view's own collapse animation — the crash in
            // #50.
            //
            // It now reads that state anyway, to tint itself while the panel is
            // open, which is what #50 is a warning about. What made that crash
            // was an `NSSplitViewItem` collapsing *while* the toolbar rebuilt;
            // the panel is a plain sibling in an `HStack` now and there is no
            // split view left to collapse. The tint is worth it because the
            // panel no longer sits at a fixed edge: it opens between columns
            // and the board scrolls, so "is a panel open" stopped being
            // answerable at a glance. Toggled repeatedly on screen before this
            // landed — if it ever crashes on collapse again, this is the line.
            Button {
                model.showingInspector.toggle()
            } label: {
                Label("Details", systemImage: "sidebar.right")
            }
            .labelStyle(.titleAndIcon)
            .tint(isPanelShowing ? Palette.armed : nil)
            .foregroundStyle(isPanelShowing ? Palette.armed : Color.primary)
            .disabled(model.selectedCard == nil)
            .help(isPanelShowing
                ? "Hide the selected card's details"
                : "Show the selected card's details")
        }

        ToolbarItem {
            Button {
                model.showConsoleFace(.repositories)
            } label: {
                Label("Repositories", systemImage: "square.stack.3d.up")
            }
            .labelStyle(.titleAndIcon)
            .help("Every repository of your accounts, and what is wrong with it")
        }

        ToolbarItem {
            Button {
                model.showConsoleFace(.preflight)
            } label: {
                Label("Preflight", systemImage: "checkmark.seal")
            }
            .labelStyle(.titleAndIcon)
            .help("Check the tools and repositories Elliot depends on")
        }
    }

    /// Whether a panel is actually drawn, which is both flags and not either
    /// one: `showingInspector` can be true with nothing selected, and a
    /// selection means nothing while the panel is hidden.
    private var isPanelShowing: Bool {
        model.showingInspector && model.selectedCard != nil
    }

    /// Says which gate is closed, rather than repeating the one that is open.
    ///
    /// The refusal itself is `AppModel.analysisRefusal`, so this tooltip and the
    /// panel's own footer say the same sentence and the Start button is disabled
    /// by the same value that explains why.
    private var analyseHelp: String {
        model.analysisRefusal ?? "Read this repository through several lenses and propose stories."
    }

    /// The five columns and, when a card is selected, its detail panel between
    /// them — one ordered row, `PanelLayout.boardOrder` deciding the order.
    ///
    /// The panel is a **sibling in this row**. Not a split of the window: as
    /// `.inspector()` it bought drag-to-resize and cost the window its layout,
    /// because applied to the stack that also holds the Divider and StatusBar
    /// the split covered the strip the title bar occupies — the board rode up
    /// under the traffic lights and the status bar fell off the bottom (#52),
    /// after it had already crashed on a collapse (#50). And not an overlay
    /// either, which would look identical and be wrong invisibly: an overlay is
    /// not a sibling, so VoiceOver would reach the panel somewhere other than
    /// after its origin column with no visible symptom.
    ///
    /// Everything below the row — the Divider and the StatusBar — is outside
    /// it, which is what keeps the status bar full-width at the bottom and the
    /// board's height the same whether the panel is open or shut.
    private var board: some View {
        // The board has exactly five columns and always will — the rule engine
        // is a fixed transition matrix. So they share the width rather than
        // sitting at a fixed size that leaves Done half off-screen.
        // The formula itself lives in `PanelLayout`, where a test can pin it:
        // the detail panel is measured in columns, so its width and this one
        // have to be the same number rather than two copies of it.
        GeometryReader { geometry in
            let boardWidth = geometry.size.width
            let width = PanelLayout.columnWidth(boardWidth: boardWidth)

            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: Metric.gutter) {
                    ForEach(
                        PanelLayout.boardOrder(
                            selected: panelOrigin, analysisOpen: model.showingAnalysisPanel),
                        id: \.self
                    ) { slot in
                        switch slot {
                        case .analysis:
                            analysisPanel(width: width)
                        case .column(let column):
                            ColumnView(
                                column: column, width: width,
                                collapsedRepos: $collapsedRepos.folds(of: column))
                        case .panel:
                            panel(width: width)
                        }
                    }
                }
                .padding(Metric.gutter)
                .frame(minWidth: boardWidth, alignment: .leading)
                // The caret and its tether, drawn over the whole row rather
                // than inside the panel. They sit *outside* the panel's bounds
                // by design, and in the flipped case they hang over Done — up
                // here nothing clips them and nothing paints over them. The
                // card, the origin column's viewport and the panel all arrive
                // as anchors, so one `GeometryProxy` resolves the three in one
                // space and the caret is drawn from the layout pass that is
                // happening rather than the one before it.
                .overlayPreferenceValue(CaretAnchorKey.self) { anchors in
                    CaretRail(anchors: anchors, flipped: isPanelFlipped)
                }
            }
            .scrollPosition($boardScroll)
            // Derived from the same width function the row is built from, never
            // a second copy of the arithmetic. The old predicate asked only
            // whether five columns fit, so with the panel open it reported
            // "everything fits" over content 1.6–1.7× the viewport — leaving
            // the panel or Done silently unreachable with no scrollbar, green
            // on both `swift build` and `swift test`.
            .scrollDisabled(
                PanelLayout.contentWidth(
                    boardWidth: boardWidth, spans: openSpans, analysisSpans: openAnalysisSpans)
                    <= boardWidth
            )
            // In a window too narrow for what the row holds the board scrolls,
            // and the card you just selected could be the one off-screen.
            //
            // One handler on one value, and that value is the row itself rather
            // than a proxy for it. There used to be two — `selectedCardID` and
            // the selected card's column — and between them they missed every
            // path that reshapes the row without touching either: the Details
            // toolbar button opening the panel on a card already selected, a
            // resize (drag handle, or View ▸ Narrow/Widen) changing
            // `panelSpans`, and `armPendingMerge`, which selects a card that may
            // already be selected and opens the panel in the same breath. Each
            // left the board framed for the row it had a moment ago, which is
            // the same failure this branch already fixed once for the selection
            // path — and the third is the one that arms the merge, so the
            // confirmation for the single irreversible act in the product was
            // the one that could open off-screen.
            .onChange(of: framing) { old, new in
                frame(new, from: old, boardWidth: boardWidth)
            }
        }
        .frame(maxWidth: .infinity)
        .background(Color(nsColor: .underPageBackgroundColor))
        // No deselect gesture here any more; `ColumnView` carries it.
        //
        // It lived here and fired by bubbling, which stopped working the moment
        // the panel widened the row past the viewport: an enabled `ScrollView`
        // swallows the tap, so nothing deselected at all. Moving it to the row's
        // background fixed that and broke the opposite direction — that
        // background also lies under the panel, so a click on the panel being
        // read closed it, and the panel's own empty `onTapGesture` did not
        // absorb it.
        //
        // An ancestor's tap fires for taps on its descendants, so any deselect
        // above the panel is a deselect *through* the panel. The reach has to be
        // the columns themselves. What that gives up is the 10pt padding ring,
        // which no longer deselects; Escape still does, and the columns cover
        // the gesture anyone actually makes.
    }

    /// The column the panel opens beside, or `nil` when there is no panel — the
    /// one place "is the panel showing" is decided, so the order, the width of
    /// the row and the framing cannot disagree about it.
    private var panelOrigin: ElliotModel.Column? {
        guard model.showingInspector, let card = model.selectedCard else { return nil }
        return card.column
    }

    /// The reader's span preference while the panel is open, `nil` while it is
    /// shut — which is the shape `PanelLayout.contentWidth` takes for "no
    /// panel", so the closed board measures exactly what it measures today.
    private var openSpans: Int? {
        panelOrigin == nil ? nil : model.panelSpans
    }

    /// The reader's analysis-span preference while that panel is showing, `nil`
    /// while it is hidden — the same shape `PanelLayout.contentWidth` takes for
    /// "no panel", so a hidden analysis costs the row exactly nothing.
    private var openAnalysisSpans: Int? {
        model.showingAnalysisPanel ? model.analysisSpans : nil
    }

    /// Which edge of the panel the caret hangs off, decided by the same function
    /// that put the panel on that side of its column. Reading it off
    /// `panelOrigin` rather than off the card is deliberate: the panel and its
    /// caret cannot then disagree about which column they belong to.
    private var isPanelFlipped: Bool {
        panelOrigin.map(PanelLayout.opensLeft(of:)) ?? false
    }

    /// The analysis, as one slot of the row — the leading one.
    ///
    /// Both modifiers below are load-bearing and neither looks it.
    private func analysisPanel(width: CGFloat) -> some View {
        AnalysisPanelView(columnWidth: width)
            // Later siblings paint over earlier ones, and this one is *first* —
            // so Backlog's background, clip and border would paint over the
            // shadow that says this panel floats above the columns. Same
            // reasoning as the detail panel's `zIndex`, arrived at from the
            // other end of the row.
            .zIndex(1)
            // The columns clear the selection on a tap that reaches their empty
            // space, and an ancestor's tap fires for taps on its descendants.
            // Without absorbing its own strays, clicking this panel's padding, a
            // section label or its header would deselect the card being read in
            // the column next door.
            .contentShape(Rectangle())
            .onTapGesture {}
    }

    /// The detail panel, as one slot of the row.
    private func panel(width: CGFloat) -> some View {
        DetailPanelView(columnWidth: width)
            // Where the caret's flat side goes. The panel's anchor is also the
            // whole "is there a caret" condition — it exists exactly while the
            // panel is built, so there is no second copy of that question.
            //
            // Through the helper like the other two. Safe as a bare modifier
            // *today*, because nothing inside `DetailPanelView` writes this key
            // — but that is a fact about the panel's current contents, not about
            // this line, and the day it gains a child that reports a caret
            // anchor the child's value would be replaced exactly as
            // `ColumnView.list` replaced the card's. #159 was one site making
            // that bet and losing it.
            .reportsCaretAnchor { CaretAnchors(panel: $0) }
            // Load-bearing. Later siblings paint over earlier ones, and in the
            // flipped case the panel is placed *before* Done — whose
            // background, clip and border would paint over the caret notched
            // into the panel's edge and the tether reaching across the gutter.
            // That would be invisible in exactly one column and nowhere else: a
            // bug that survives every test and most manual passes.
            .zIndex(1)
            // The board clears the selection on a click that reaches its
            // background, and this panel now sits inside that container. Without
            // absorbing its own strays, clicking the panel's padding, a section
            // label or its header would close the panel being read.
            .contentShape(Rectangle())
            .onTapGesture {}
            // `BoardSlot.panel` is one constant identity, so changing origin
            // column re-orders the panel instead of destroying and rebuilding
            // it — that is what stops a second panel and a second caret
            // appearing mid-transition. This is the other half of that: a
            // re-order is a frame change, and a frame change under the
            // stack-wide `.animation(…, value: selectedCardID)` interpolates,
            // so Backlog → Done would send the panel gliding across four
            // columns. The panel's own placement does not animate; the columns
            // sliding aside still does.
            //
            // ⚠️ Deliberately a bare `nil`, and not the `reduceMotion ? nil : …`
            // every other animation on this board is written as. This one is
            // unconditional: the panel must not glide for anyone, reduce motion
            // on or off. So it is *stricter* than reduce motion asks for rather
            // than an ungated animation — there is no animation here to gate.
            // Turning it into `reduceMotion ? nil : .something` would reinstate
            // the glide for everyone who has not switched reduce motion on.
            .animation(nil, value: model.selectedCardID)
    }

    /// Everything the framing answers to, gathered from the model in one place.
    ///
    /// A computed property rather than four `onChange` handlers: the row's shape
    /// is one thing, and asking about it in pieces is how three of the pieces
    /// came to be missing.
    private var framing: BoardFraming {
        BoardFraming(
            selectedCardID: model.selectedCardID,
            selectedColumn: model.selectedCard?.column,
            panelOrigin: panelOrigin,
            spans: model.panelSpans,
            analysisOpen: model.showingAnalysisPanel,
            analysisSpans: model.analysisSpans
        )
    }

    /// Scroll the board so the selected card's column and its panel are framed
    /// together, with a lead of the previous column still showing.
    ///
    /// The arithmetic is `BoardFraming.offsetX(boardWidth:)`, which is pure and
    /// pinned by `swift test`. All that is left here is the deferral, which is
    /// the one part of this no test can see.
    private func frame(_ framing: BoardFraming, from previous: BoardFraming, boardWidth: CGFloat) {
        guard let offset = framing.offsetX(from: previous, boardWidth: boardWidth) else { return }

        // Deferred by one turn of the main actor, and this is the whole reason
        // the first attempt did nothing on screen. `onChange` runs *inside* the
        // update that changed the selection, so the row it scrolls is still the
        // one without a panel: five columns, content no wider than the
        // viewport, `scrollDisabled` still true. The offset was computed for
        // the row that was about to exist and applied to the row that still
        // did, where it clamps to zero. Both `swift build` and `swift test`
        // were green through all of it — the board simply never moved, and only
        // the last column showed it, because that is the one case where the
        // pair does not already fit.
        Task { @MainActor in
            withAnimation(reduceMotion ? nil : .default) {
                boardScroll.scrollTo(x: offset)
            }
        }
    }

    /// Startup, said in the same words `RepositoriesView` already uses for it,
    /// so the two screens stop disagreeing about one launch.
    private var startingState: some View {
        ContentUnavailableView(
            BoardPhase.starting.title ?? "",
            systemImage: "hourglass",
            // From the phase, not from `model.status` directly. Identical while
            // startup runs — which is the only time this screen is drawn — but
            // it means the title and the line under it come from one decision
            // rather than two, which is the whole of #118.
            description: Text(BoardPhase.starting.detail(status: model.status) ?? "")
        )
        .frame(maxHeight: .infinity)
    }

    /// The store could not be read — distinct from both the spinner above and
    /// the empty state below.
    ///
    /// A question mark rather than an hourglass: nothing is still happening, and
    /// an hourglass is what said otherwise for ever. Drawn in `Palette.refused`
    /// because this is a failure the reader has to act on, unlike the empty
    /// state, which is an invitation.
    private func unreadableState(_ reason: String) -> some View {
        ContentUnavailableView {
            Label(
                BoardPhase.unreadable(reason: reason).title ?? "",
                systemImage: "questionmark.folder"
            )
            .foregroundStyle(Palette.refused)
        } description: {
            Text(reason)
        } actions: {
            // The one thing a reader can usefully do about a store Elliot
            // cannot read. It does not repair anything, and does not pretend to.
            Button("Show the store in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([StoreLocation.databaseURL])
            }
        }
        .frame(maxHeight: .infinity)
    }

    /// What #42 is actually about: an empty board that means "I could not ask"
    /// looking exactly like one that means "there is nothing to show".
    ///
    /// A bar rather than a status sentence, because `status` is one shared line
    /// that the next event overwrites — a run finishing, a preflight pass,
    /// another repository's summary — and the failure was gone seconds later.
    /// This stays until the repository imports or is forgotten.
    ///
    /// Scoped to what the picker is showing: the selected repository, or every
    /// failed one when "All repositories" is chosen.
    @ViewBuilder
    private var unreachableBanner: some View {
        let failures = model.visibleImportFailures
        let skipped = BoardPhase.skippedNote(model.unreadableRepoCount)

        if !failures.isEmpty || skipped != nil {
            VStack(alignment: .leading, spacing: 2) {
                // Rows the store could not decode. Beside the repositories that
                // *did* read, not instead of them — one bad row costs one
                // repository, and saying so is what keeps that from being the
                // same defect with a smaller radius (#118, criterion 4).
                //
                // No Retry: re-reading will fail the same way. The row needs
                // repairing, which is not something the board can offer.
                if let skipped {
                    HStack(spacing: 6) {
                        Image(systemName: "questionmark.circle.fill")
                            .foregroundStyle(Palette.attention)
                        Text(skipped)
                            .font(Type.rowTitle)
                        Spacer(minLength: 8)
                    }
                }
                ForEach(failures, id: \.repo.id) { entry in
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(Palette.attention)
                        Text("\(entry.repo.displayName) could not be refreshed")
                            .font(Type.rowTitle)
                        // The reason in the fact face: it is `gh`'s words, not
                        // ours, and the board's own convention keeps those apart.
                        Text(entry.message)
                            .font(Type.factSmall)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 8)
                        // This row names one repository and one `gh` message, so
                        // its button means that repository. It used to re-import
                        // the whole board whenever the picker said "All".
                        Button("Retry") {
                            Task { await model.refreshFromGitHub(repoID: entry.repo.id) }
                        }
                        .buttonStyle(.link)
                        .font(Type.labelSmall)
                        .disabled(model.isImporting)
                        .help("Re-import \(entry.repo.displayName)")
                    }
                    .help(entry.message)
                }
            }
            .padding(.horizontal, Metric.gutter)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Palette.attention.opacity(0.12))
            .overlay(alignment: .bottom) { Divider() }
            .accessibilityIdentifier("import-failure-banner")
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No repository yet", systemImage: "folder.badge.plus")
        } description: {
            Text("Add the main checkout of a git repository. Elliot files issues, opens pull requests and merges them there.")
        } actions: {
            Button("Add a repository…") { chooseRepository() }
                .buttonStyle(.borderedProminent)
        }
        .frame(maxHeight: .infinity)
    }

    private func chooseRepository() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Add"
        panel.message = "Choose the main checkout — not a linked worktree."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await model.addRepo(path: url.path) }
    }

}

extension Binding where Value == [ElliotModel.Column: Set<UUID>] {

    /// One column's folded repositories.
    ///
    /// `Binding`'s stock dictionary subscript hands back a `Binding<Set<UUID>?>`,
    /// and an optional here would distinguish "this column has never had
    /// anything folded" from "this column has nothing folded" — the same board,
    /// drawn the same way, with an unwrap in front of every reader of it.
    func folds(of column: ElliotModel.Column) -> Binding<Set<UUID>> {
        Binding<Set<UUID>>(
            get: { wrappedValue[column] ?? [] },
            set: { wrappedValue[column] = $0 }
        )
    }
}

// MARK: - What the board frames, and where

/// Everything the board's framing must answer to, as **one** value.
///
/// It exists because framing was keyed on two proxies — `selectedCardID` and
/// the selected card's column — and three paths reshape the row without
/// touching either of them:
///
/// 1. the **Details** toolbar button, opening the panel on a card that is
///    already selected;
/// 2. a **resize** — the drag handle, or View ▸ Narrow/Widen — changing
///    `panelSpans`, which changes how far the row extends and therefore where a
///    scroll offset clamps;
/// 3. `AppModel.armPendingMerge(cardID:prNumber:)`, which selects a card *and*
///    opens the panel together. It re-framed only when the card it arms was not
///    the one already selected — and that is the path to the one act in the
///    product that cannot be taken back, so a confirmation opening off-screen
///    is the worst of the three.
///
/// Each left the board scrolled for the row it had a moment ago, which is the
/// failure this branch already fixed once for the selection path.
///
/// ⚠️ On the first two the recomputed offset is the **same number**, and that is
/// not an argument against firing. `PanelLayout.minX` sums the slots ahead of
/// its target and a panel is never among them, so `offsetX` is invariant to
/// `spans` and, for a column that is not flipped, to whether the panel is open
/// — pinned by `BoardFramingTests.offsetIsInvariantToThePanelsWidth`. What
/// changes is whether that number can be *applied*: with the panel shut the row
/// fits the window and `scrollDisabled` clamps every scroll to zero; opening it
/// makes the row 1.6–1.7× the viewport and the same offset finally means
/// something. A trigger that does not fire is therefore the whole bug, even
/// where the arithmetic would not have moved.
///
/// `selectedCardID` is kept even though it is not geometry — two cards in one
/// column frame identically — because re-selecting inside a column the reader
/// has scrolled away from must still bring that column back, which is what the
/// old `onChange(of: selectedCardID)` did and what dropping it would quietly
/// lose.
///
/// The board's **width** is deliberately *not* a member. It is an argument to
/// `offsetX(boardWidth:)`, so the arithmetic still answers for the window it is
/// asked about — but a live window resize emits a width per frame, and an
/// animated scroll on each of them would fight the gesture rather than follow
/// the reader. What is framed here is a change of *row*, not of window.
struct BoardFraming: Equatable, Sendable {
    var selectedCardID: UUID?
    /// The column the selected card sits in, or `nil` when nothing is selected.
    var selectedColumn: ElliotModel.Column?
    /// The column the panel opens beside, or `nil` when no panel is drawn. Folds
    /// `showingInspector` and the selection together exactly as
    /// `BoardView.panelOrigin` does — one answer to "is there a panel", shared
    /// by the order, the width of the row and the framing.
    var panelOrigin: ElliotModel.Column?
    /// How many columns wide the panel is.
    var spans: Int
    /// Whether the analysis panel is showing, as the row's leading slot.
    ///
    /// Part of the row's shape, so a change to it must re-frame — the same
    /// argument the three paths above make. This one is stronger than any of
    /// them: the analysis panel sits *ahead* of all five columns, so opening it
    /// moves every column's leading edge, and a board that did not re-frame
    /// would be looking at the wrong column rather than at the right one from
    /// the wrong distance.
    var analysisOpen: Bool
    /// How many columns wide the analysis panel is.
    var analysisSpans: Int

    /// Where the board must scroll so the selected column and its panel are
    /// framed together, or `nil` when there is nothing to frame.
    ///
    /// Pure, and out here rather than in the view for the reason the whole of
    /// `PanelLayout` is: `swift test` cannot see the screen, but it can see
    /// this. It works out where the pair *will* be rather than measuring where
    /// it is — the row is an `HStack` of known widths, so `PanelLayout.minX`
    /// answers before the layout that inserts the panel has run.
    func offsetX(boardWidth: CGFloat) -> CGFloat? {
        guard let selectedColumn else { return nil }
        let slots = PanelLayout.boardOrder(selected: panelOrigin, analysisOpen: analysisOpen)
        let columnWidth = PanelLayout.columnWidth(boardWidth: boardWidth)
        let panelWidth = PanelLayout.panelWidth(columnWidth: columnWidth, spans: spans)
        // Zero when it is shut, which is what makes it contribute nothing to the
        // sum rather than a width for a slot that is not in the row.
        let analysisWidth = analysisOpen
            ? PanelLayout.panelWidth(columnWidth: columnWidth, spans: analysisSpans)
            : 0

        guard let originMinX = PanelLayout.minX(
            of: .column(selectedColumn), in: slots,
            columnWidth: columnWidth, panelWidth: panelWidth, analysisWidth: analysisWidth
        ) else { return nil }
        // `nil` when the panel is shut, and passed through as `nil`: the pair is
        // then the column by itself, which is what `frameOffsetX` measures the
        // lead against.
        let panelMinX = PanelLayout.minX(
            of: .panel, in: slots,
            columnWidth: columnWidth, panelWidth: panelWidth, analysisWidth: analysisWidth
        )
        return PanelLayout.frameOffsetX(
            originMinX: originMinX,
            panelMinX: panelMinX,
            flipped: panelOrigin != nil && PanelLayout.opensLeft(of: selectedColumn),
            columnWidth: columnWidth,
            panelWidth: panelWidth,
            // The window is the whole point of the clamp, and it is already the
            // parameter this method is asked in terms of.
            viewportWidth: boardWidth
        )
    }

    /// The offset to apply given what the row just *became*.
    ///
    /// Opening the analysis panel frames the analysis panel — it is the leading
    /// slot, so that is 0 — because a panel the reader has just asked for that
    /// lands off-screen to the left reads as a panel that did not open. That
    /// false negative is written down in `CLAUDE.md`: it cost nine written
    /// claims and two merges on the window scenes, and the only reason a
    /// board-inline panel escapes it is that the board scrolls to it.
    ///
    /// Every other transition — closing it included — frames the selected card
    /// and its panel exactly as it does today. Closing is deliberately not a
    /// special case: the reader's attention after a close is wherever their card
    /// is, not at the leading edge of a row that no longer has a panel in it.
    func offsetX(from previous: BoardFraming, boardWidth: CGFloat) -> CGFloat? {
        if analysisOpen && !previous.analysisOpen { return 0 }
        return offsetX(boardWidth: boardWidth)
    }
}

// MARK: - Status bar

/// The only strip that is always on screen, and until #68 it carried the least
/// information available: "N running" and a status sentence. Neither the queue
/// depth, nor the capacity in use, nor the day's spend appeared — although all
/// three were either already in memory or one aggregate query away.
///
/// It says the three numbers of a control room now. Each **is a door**: pressing
/// one unfolds the screen that can act on that number, in this window, directly
/// above the figure that was pressed. So the strip is a way in rather than a
/// readout — and since the console lives here, pressing the same figure again is
/// the way back out.
struct StatusBar: View {
    @Environment(AppModel.self) private var model

    /// The window's content height, passed down rather than measured here,
    /// because what a door needs to know is whether the *console* fits — a
    /// question about the window, not about this 28pt strip.
    let contentHeight: CGFloat

    var body: some View {
        HStack(spacing: 8) {
            if !model.isReady || model.isImporting {
                ProgressView().controlSize(.small)
            }
            // `refreshFromGitHub` joins one sentence per repository, which
            // used to wrap and grow `.bar`, shoving the whole board upwards.
            Text(model.status)
                .font(Type.prose)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .help(model.status)

            Spacer(minLength: 8)

            figure(
                text: "\(model.occupancy.writers)/\(model.limits.maxConcurrent) workers",
                tint: model.occupancy.writers > 0 ? Palette.armed : Palette.quiet,
                help: "How many runs are going, against the limit. Click to change it.",
                spoken: "\(model.occupancy.writers) of \(model.limits.maxConcurrent) workers busy",
                face: .operations
            )

            // Only when there is one. A permanent "0 queued" is furniture, and
            // this strip has been pushed around by its own contents before.
            if !model.queue.isEmpty {
                figure(
                    text: "\(model.queue.count) queued",
                    tint: model.isQueuePaused ? Palette.refused : Palette.attention,
                    help: model.queue.first?.refusal.sentence ?? "Runs waiting to start.",
                    spoken: model.isQueuePaused
                        ? "\(model.queue.count) queued, paused"
                        : "\(model.queue.count) runs queued",
                    face: .operations
                )
            }

            // Criterion 3 of #334: the number that reported the suppressions
            // becomes the way into them. It was a fragment of `model.status` —
            // `ImportSummary.sentence` appending "3 dismissed" — inside one
            // truncated, `lineLimit(1)` string, naming none of them, with
            // nothing to press.
            //
            // Same rule as the queue above: only when there is one. That is why
            // the face also has a View-menu item — at zero this door is absent,
            // and a screen whose only way in vanishes with its own contents is
            // one nobody can open to learn it is empty.
            //
            // Driven by `dismissedFigure`, a reading of the **table**, not by
            // the last import summary: a summary is a record of one pass, so it
            // cannot decrement when a row is restored, and the next thing to
            // speak into `status` erases it.
            if let dismissed = model.dismissedFigure {
                figure(
                    text: dismissed,
                    tint: Palette.quiet,
                    help: "Issues and pull requests this board is not importing. "
                        + "Click to see them and restore one.",
                    spoken: "\(dismissed) items are being skipped on refresh",
                    face: .dismissed
                )
            }

            // Same rule as the queue above — only when there is one. With the
            // shipped retention constants a launch prunes nothing, so this is
            // absent on an ordinary day rather than reading "0 pruned"; and
            // because it is derived from `artifactSweep` rather than pushed into
            // `status`, nothing that speaks later can overwrite it.
            if let sweep = model.artifactSweep, let sentence = sweep.sentence {
                figure(
                    text: "\(sweep.removed) pruned",
                    tint: Palette.quiet,
                    help: "\(sentence) Artefacts past the retention horizon, removed at launch.",
                    spoken: sentence,
                    face: .operations
                )
            }

            // `todayFigure`, not `spentToday`: the store's query keys on
            // `endedAt`, so the runs going right now are absent from this
            // number and the sentence is the only place that can say so.
            figure(
                text: model.todayFigure.amount(),
                tint: model.isOverDailyCeiling ? Palette.refused : Palette.quiet,
                help: "Spent today — \(model.todayFigure.sentence()). Click to set a ceiling.",
                spoken: "spent today, \(model.todayFigure.sentence())",
                face: .operations
            )

            // Elliot wrote this hint, so it is not set in the fact face. It said
            // a flat "⌘→ advance" for every card, including the ones where ⌘→
            // does nothing at all; `selectionHint` reaches `preview` for the
            // card actually selected.
            Text(model.selectionHint)
                .font(Type.prose)
                .foregroundStyle(Palette.quiet)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        // Fixed, and `lineLimit(1)` above: this bar has grown and shoved the
        // whole board upwards before, and the numbers in it change constantly.
        .frame(height: Metric.statusBarHeight)
        .background(.bar)
    }

    /// One figure, and a way to act on it.
    ///
    /// `spoken` rather than reading the label aloud: "2/4 workers" is a
    /// screen-reader's nightmare, and a number with no sentence around it says
    /// nothing to anyone who cannot see where it sits.
    /// ⚠️ `face` is a `ConsoleFace` and was a `String` window id. A typo in that
    /// string opened nothing at all, silently — there is no such thing as a
    /// mistyped case.
    private func figure(
        text: String, tint: Color, help: String, spoken: String, face: ConsoleFace
    ) -> some View {
        // Refused only when the console is *shut* and could not fit. A door on
        // an open console must stay live whatever the window height, or a reader
        // who shrank the window would have no way to fold away what is on
        // screen — Escape aside, and Escape is not discoverable.
        let refusal = model.console.isOpen ? nil : ConsoleLayout.refusal(contentHeight: contentHeight)

        return Button { model.pressConsoleDoor(face) } label: {
            Fact(text: text, tint: tint, small: true)
        }
        .buttonStyle(.plain)
        .disabled(refusal != nil)
        .help(refusal ?? help)
        .accessibilityLabel(spoken)
        .accessibilityHint(
            refusal ?? (model.console.face == face
                ? "Folds away the screen that can change it"
                : "Unfolds the screen that can change it"))
    }
}

// MARK: - Column

struct ColumnView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.openWindow) private var openWindow
    let column: ElliotModel.Column
    let width: CGFloat
    /// Which repository groups this column has folded — per column and per
    /// repository, so folding a repository in Backlog does not hide it in To Do.
    ///
    /// A `Binding` rather than this view's own `@State` since #278: the set now
    /// belongs to `BoardView`, because the arrow keys are there and they have to
    /// know what this column is drawing. The granularity is unchanged; only the
    /// owner is.
    @Binding var collapsedRepos: Set<UUID>
    @State private var isTargeted = false
    // Which days in Done are folded is `AppModel.collapsedDays`, not a `@State`
    // here. It was one, and the Archive held a second over the same
    // `ShipDay.start` keys with the toggle written out twice — so folding
    // "Yesterday" in Done left it open in the Archive, showing the same cards
    // under the same heading. It stays a **separate** set from `collapsedRepos`
    // above, for the reason that comment gives: a repository and a day are
    // different things to have folded.
    /// The card a drop would land above, or `nil` when the pointer is not over
    /// one. Held on the column rather than as `@State` inside each card, so
    /// exactly one insertion cue can be drawn at a time — two bars would say the
    /// card is about to land in two places.
    @State private var insertAbove: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            rail
            header
            list
        }
        .frame(width: width)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(background)
        // Clearing the selection belongs to the columns, not to the row.
        //
        // It used to sit on the board container and work by bubbling out of a
        // column's empty space — but only because the old predicate disabled
        // scrolling whenever five columns fit, and a disabled `ScrollView`
        // passes a tap through. The panel makes the row wider than the viewport
        // by design, so scrolling is now always on while it is open, an enabled
        // `ScrollView` swallows the tap, and the board became impossible to
        // deselect by clicking — in every column, with `swift build` clean and
        // all 726 tests green. Caught by looking, and confirmed a regression by
        // driving `main` through the same gesture.
        //
        // Putting it on the row's background instead only moved the bug: that
        // background also lies under the panel, so clicking the panel being read
        // closed it. Here the reach is exactly right — a column's own empty
        // space and nothing else. Cards sit in front and keep their own tap.
        .contentShape(Rectangle())
        .onTapGesture { model.selectedCardID = nil }
        .clipShape(RoundedRectangle(cornerRadius: Metric.columnRadius))
        .overlay {
            RoundedRectangle(cornerRadius: Metric.columnRadius)
                .strokeBorder(borderTint, lineWidth: isTargeted ? 2 : 1)
        }
        .dropDestination(for: String.self) { items, _ in
            guard let id = items.first.flatMap(UUID.init(uuidString:)) else { return false }
            // Answered now, not a round trip later. `move` is async, so this
            // closure used to return `true` — "accepted" — for drops it was
            // about to refuse: the card animated in, then jumped back with a
            // note on it. Returning `false` makes the drag snap back, which is
            // what a refusal looks like on this platform.
            guard !model.refuse(cardID: id, to: column) else { return false }
            Task { await model.move(cardID: id, to: column) }
            return true
        } isTargeted: { targeted in
            // The refusal is stated in the header the whole time a card is
            // selected, so a refused column simply does not light up.
            isTargeted = targeted && !isRefused
        }
        .animation(reduceMotion ? nil : .snappy(duration: 0.18), value: isTargeted)
    }

    /// The column's standing cost, always visible. Two points of colour, and
    /// only where arriving actually does something.
    private var rail: some View {
        Rectangle()
            .fill(consequence?.tint ?? column.railTint)
            .frame(height: Metric.railHeight)
            .opacity(isRefused ? 0.25 : 1)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                ConsoleLabel(text: column.displayName, tint: .primary)
                Fact(text: "\(cards.count)", tint: Palette.quiet, small: true)
                Spacer()
                if column.isConsequential {
                    Image(systemName: column == .done ? "flame.fill" : "bolt.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(column.railTint)
                        .accessibilityHidden(true)
                }
            }

            // The heart of it: what a drop here does, decided by the same pure
            // function that will run it. No card selected, no card in hand —
            // the column falls back to describing itself.
            Text(consequence?.summary ?? column.standingRule)
                .font(Type.prose)
                .foregroundStyle(captionTint)
                .lineLimit(2, reservesSpace: true)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 10)
        .padding(.top, 8)
        .padding(.bottom, 8)
        .accessibilityElement(children: .combine)
        // One of the five captions #79 requires to survive the panel. Built by
        // a pure function so that survival is a claim `swift test` can hold —
        // the string itself used to be written here, where nothing could.
        .accessibilityLabel(
            BoardAccessibility.columnCaption(
                name: column.displayName,
                count: cards.count,
                rule: consequence?.summary ?? column.standingRule
            )
        )
    }

    private var list: some View {
        // Computed once and read three times below, not computed three times:
        // this is the filter, the sort, the grouping and — in Done — the day
        // bucketing. And the scroll handler has to be judged against the very
        // list the rows were built from, or it can ask for a card this pass did
        // not draw.
        let rows = rows
        let focus = ColumnFocus.of(
            landing: model.lastLanded, selection: model.selectedCardID, drawn: rows)

        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 6) {
                    // One list, in the order it is drawn — `ColumnRows` decides
                    // whether this column is a dated log, a set of repository
                    // groups or a plain run of cards, and the arrow keys in
                    // `BoardView` walk the very same value. The three `if`
                    // branches that used to be here were the second opinion the
                    // keyboard could not see (#278).
                    ForEach(rows.rows) { row in
                        switch row {
                        case .repository(let group, let folded):
                            groupHeader(group, folded: folded)
                        case .day(let day, let folded):
                            dayHeader(day, folded: folded)
                        case .card(let card):
                            draggable(card)
                        }
                    }

                    if rows.olderCount > 0 {
                        olderFooter(rows.olderCount)
                    }

                    if cards.isEmpty {
                        // Driven by the gated `.animation(…, value: cards.map(\.id))`
                        // a few lines down — the last card leaving is what
                        // makes this appear, and that *is* a change to that
                        // value. With reduce motion on the gate hands SwiftUI
                        // `nil` and the hint is simply there.
                        dropHint.transition(.opacity)
                    }
                }
                // The constant, not the 8 it holds. The tether's reach is
                // `Metric.gutter + Metric.columnListPadding`, computed from the
                // named one — so a bare literal here is half of one value with
                // nothing linking it to the other half, and the day it moved the
                // rail would stop touching the card with no test to say so.
                .padding(.horizontal, Metric.columnListPadding)
                .padding(.bottom, 10)
                .frame(maxWidth: .infinity, alignment: .top)
                // On the list itself, not the board: this is about membership
                // of *this* column changing.
                .animation(reduceMotion ? nil : .snappy(duration: 0.24), value: cards.map(\.id))
            }
            .scrollBounceBehavior(.basedOnSize)
            // A dropped card landed at the bottom of a column nothing scrolled,
            // so a full column swallowed it — and the same was true of a card
            // the *keyboard* selected: ↓ past the viewport left the selection,
            // its armed border and the caret's anchor off screen, with the rail
            // drawing a truthful picture of a card nobody could see (#277).
            //
            // One handler on one value. A drop is both a landing and a
            // selection, so two handlers on this proxy would animate the column
            // twice for one gesture; `ColumnFocus` folds them and its
            // `target(from:)` says which half moved, exactly as `BoardFraming`
            // does for the row. No colour flash is needed — the card is already
            // selected and already wears the armed border.
            .onChange(of: focus) { previous, current in
                guard let target = current.target(from: previous) else { return }
                withAnimation(reduceMotion ? nil : .default) {
                    proxy.scrollTo(target.cardID, anchor: target.anchor)
                }
            }
        }
        // What the reader can currently see of this list, which is what decides
        // whether the caret still has a card to point at. The `ScrollView`'s own
        // bounds are the viewport, not the content — a card whose centre leaves
        // this rectangle has scrolled out, and `PanelLayout.isDetached` says so.
        //
        // Only the column the panel opened from reports. The other four have
        // nothing to say about a caret that is not theirs, and four extra
        // rectangles arriving at one key is four chances to answer for the wrong
        // column.
        //
        // ⚠️ **`reportsCaretAnchor`, never a bare `.anchorPreference`, and that
        // is the whole of #159.** This view is an *ancestor* of the `CardView`s,
        // and the modifier applied directly to an ancestor does not merge with
        // what its subtree contributed through `reduce` — it **replaces** it.
        // The selected card's `CaretAnchors(card:)` reached here and was
        // overwritten one level below the overlay, so `card` was permanently
        // `nil`, `PanelLayout.isDetached` answered `true` on its first `guard`
        // for ever, and the tether drew at opacity 0 while the caret sat faint
        // at `panel.midY`. A truthful rendering of a false input, which is why
        // the gutter looked empty and every number `PanelLayoutTests` pins was
        // right the whole time.
        .reportsCaretAnchor { bounds in
            model.selectedCard?.column == column ? CaretAnchors(list: bounds) : CaretAnchors()
        }
    }

    private func draggable(_ card: Card) -> some View {
        CardView(card: card)
            .id(card.id)
            // Arriving at a *position* starts nothing, so the cue is
            // `Palette.inert` and not an accent. `armed` means a gesture starts
            // an agent and `irreversible` means it merges; spending either here
            // is exactly the dilution #47 spent its effort undoing.
            .overlay(alignment: .top) {
                if insertAbove == card.id {
                    Rectangle()
                        .fill(Palette.inert)
                        .frame(height: 2)
                        .allowsHitTesting(false)
                }
            }
            .animation(reduceMotion ? nil : .snappy(duration: 0.18), value: insertAbove)
            // Nested inside the column's own drop target on purpose, and this is
            // the hazard #47's review named: a card covers most of a populated
            // column, so if this swallowed drops the column could not receive
            // them and "drop anywhere in the column" — the app's whole gesture —
            // would break. It does not swallow them: a drop on a card is still a
            // drop into this column, because `reorder` performs the column move
            // itself when the card comes from elsewhere. What changes is only
            // *where in the column* it lands.
            .dropDestination(for: String.self) { items, _ in
                insertAbove = nil
                guard let id = items.first.flatMap(UUID.init(uuidString:)) else { return false }
                // A card dropped on itself. Refused at the gesture so the drag
                // snaps back rather than animating into a placement that
                // `CardReorder.placement` is about to decline anyway.
                guard id != card.id else { return false }

                // Done is drawn in `columnEnteredAt` order, so a placement
                // inside it cannot be honoured: `reorder` would write an
                // `orderIndex` the column does not read and the card would
                // redraw exactly where it was. Refused at the gesture, so the
                // drag snaps back — the same answer #47's review demanded for
                // every other move the board is about to decline. A drop from
                // *another* column still passes, because that is a column
                // change and `reorder` performs it.
                if card.column == .done, model.card(id: id)?.column == .done { return false }

                // Only a drop from *another* column can be refused; asking
                // `refuse` about a same-column drop would answer "same column"
                // and put a refusal note on a gesture that is allowed.
                if model.card(id: id)?.column != card.column,
                   model.refuse(cardID: id, to: card.column) {
                    return false
                }
                Task { await model.reorder(cardID: id, in: card.column, above: card) }
                return true
            } isTargeted: { targeted in
                // No insertion cue in Done: it would promise a position the
                // column cannot show. The column's own highlight still says the
                // drop is accepted, which for a card arriving from elsewhere it
                // is.
                guard card.column != .done else { return }
                insertAbove = targeted ? card.id : (insertAbove == card.id ? nil : insertAbove)
            }
            .onDrag {
                // An action closure, not a view builder: safe to record the
                // selection here, and it means starting a drag arms the console
                // for the card in hand.
                model.selectedCardID = card.id
                return NSItemProvider(object: card.id.uuidString as NSString)
            }
            // Moving a card is the app's only gesture, and it used to be a
            // teleport: the card vanished from one column and appeared in
            // another with no motion connecting the two.
            //
            // Gated by the `.animation(reduceMotion ? nil : …, value:
            // cards.map(\.id))` on the enclosing `LazyVStack`, which is the
            // animation that drives it: a card arriving or leaving *is* a
            // change to that value. Reduce motion turns it off there, once, for
            // every card in the column.
            .transition(
                .asymmetric(
                    insertion: .opacity.combined(with: .offset(x: -14)),
                    removal: .opacity.combined(with: .scale(scale: 0.97))
                ))
    }

    /// Everything this column draws, in the order it draws it.
    ///
    /// Computed per access, like the `groups` and `doneLog` it replaces and for
    /// the same reason: the rule is cheap, and caching it would need something
    /// to invalidate the cache — including at midnight, when Done's answer
    /// changes without any card moving.
    private var rows: ColumnRows {
        ColumnRows.of(column, model: model, foldedRepoIDs: collapsedRepos)
    }

    /// Fold a heading, and give up the selection it was holding.
    ///
    /// ⛔ Not optional politeness. `ColumnRows` draws a folded heading **open**
    /// while it holds the selection — that is what keeps "a selected card is a
    /// drawn card" true without mutating the fold set behind the reader's back —
    /// so without this the chevron would visibly do nothing on exactly the group
    /// the reader is looking at. Refusing the fold instead was the other
    /// candidate and is worse: a control that declines when pressed reads as
    /// broken, where losing the selection reads as the consequence of folding
    /// away what you were reading.
    ///
    /// One function for both headings, because there is one rule. A day and a
    /// repository fold differently and forget the selection identically.
    private func fold(away cards: [Card], _ act: () -> Void) {
        act()
        model.selectedCardID = ColumnRows.selection(
            model.selectedCardID, survivingFoldOf: cards)
    }

    /// A day's heading in Done, newest first.
    ///
    /// The rows under it are `draggable(_:)` exactly like every other column's,
    /// so a finished card can still be dragged back out — Done is a horizon on
    /// what is *drawn*, never a change to what a card is or what may be done to
    /// it.
    ///
    /// `folded` is what the reader **sees**, which is why the button says which
    /// way it means rather than flipping `collapsedDays`: the two disagree at
    /// the one heading that holds the selection.
    private func dayHeader(_ day: ShipDay, folded: Bool) -> some View {
        ShipDayHeader(label: day.label, count: day.cards.count, collapsed: folded) {
            if folded {
                model.setDay(day.start, folded: false)
            } else {
                fold(away: day.cards) { model.setDay(day.start, folded: true) }
            }
        }
    }

    /// Where the rest of the finished work went.
    ///
    /// Drawn only when the horizon actually hid something, so a board younger
    /// than the horizon never grows a control that would open an empty window.
    /// Nothing here is destructive and nothing is lost — the cards it counts
    /// are in the database exactly as they were, which is what lets this be a
    /// quiet line rather than a warning.
    private func olderFooter(_ count: Int) -> some View {
        Button {
            model.showConsoleFace(.archive)
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "archivebox")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                Fact(text: "\(count) older", tint: Palette.quiet, small: true)
                Spacer()
                ConsoleLabel(text: "Open Archive")
            }
            .contentShape(Rectangle())
            .padding(.top, 6)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(BoardAccessibility.olderFooter(count: count))
    }

    /// Deliberately carries no `dropDestination`.
    ///
    /// The drop target is the column and only the column. A drop onto a group
    /// header would have to mean "move this card to that repository", which is
    /// a write `BoardService` owns and a second path to a card's identity — the
    /// exact kind of silent second write path the app is built to avoid.
    ///
    /// `folded` is what the reader **sees**, not what `collapsedRepos` holds:
    /// a group folded by the reader is drawn open while it holds the selection,
    /// so reading the set here would fold on a press meant to unfold and the
    /// chevron would run backwards. See `fold(away:_:)`.
    private func groupHeader(_ group: CardGroup, folded: Bool) -> some View {
        Button {
            if folded {
                collapsedRepos.remove(group.repoID)
            } else {
                fold(away: group.cards) { collapsedRepos.insert(group.repoID) }
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: folded ? "chevron.right" : "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.tertiary)
                ConsoleLabel(text: group.repoName, tint: .secondary)
                Fact(text: "\(group.cards.count)", tint: Palette.quiet, small: true)
                Spacer()
            }
            .contentShape(Rectangle())
            .padding(.top, 4)
        }
        .buttonStyle(.plain)
        // Singular written out, by the same function the column caption above
        // uses. It was written out here and *not* there, which is how the two
        // labels on one column came to disagree about "1 cards".
        .accessibilityLabel(
            BoardAccessibility.groupCaption(
                repoName: group.repoName, count: group.cards.count, column: column.displayName
            )
        )
    }

    /// An empty column used to be blank, which reads as broken rather than
    /// available.
    private var dropHint: some View {
        RoundedRectangle(cornerRadius: Metric.cardRadius)
            .strokeBorder(
                style: StrokeStyle(lineWidth: 1, dash: [4, 4])
            )
            .foregroundStyle(.quaternary)
            .frame(height: 56)
            .overlay {
                Text(hintText)
                    .font(Type.prose)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 6)
            }
    }

    /// An empty column should not invite a drop it will refuse. The tint stays
    /// quiet: the header above already carries the refusal in `Palette.refused`,
    /// and a second coloured refusal in one column is the dilution the palette
    /// guards against.
    private var hintText: String {
        if isRefused { return "Not this card" }
        if column == .backlog { return "No stories yet — ⌘N writes one" }
        return "Drop a card here"
    }

    private var cards: [Card] { model.cards(in: column) }

    /// What dropping the card in hand would do, or `nil` when nothing is
    /// selected.
    private var consequence: Consequence? {
        guard let card = model.selectedCard, card.column != column else { return nil }
        return Consequence.of(model.preview(card, to: column))
    }

    private var isRefused: Bool { consequence?.isRefused ?? false }

    private var captionTint: Color {
        guard let consequence else { return .secondary }
        return consequence.isRefused ? Palette.refused : consequence.tint
    }

    /// `consequence` is `nil` for the card's *own* column, so both of these
    /// fell through to `Palette.armed` — dragging a card over the column it is
    /// already in painted that column in the app's most loaded colour, and then
    /// the drop was refused with "Already here." `Palette.inert` is the
    /// documented "nothing happens on arrival" tone and the standing rail tint
    /// of Backlog and In Review, so no accent is added here.
    private var background: some ShapeStyle {
        if isTargeted { return AnyShapeStyle(Surface.wash(consequence?.tint ?? Palette.inert)) }
        if isRefused { return AnyShapeStyle(Surface.recessFaint) }
        return AnyShapeStyle(Surface.recess)
    }

    private var borderTint: Color {
        if isTargeted { return consequence?.tint ?? Palette.inert }
        guard let consequence, !consequence.isRefused else { return .clear }
        return Surface.washBorder(consequence.tint)
    }
}

// MARK: - What a screen reader hears of the board

/// The sentences the board says aloud, as pure functions.
///
/// Same reason `LogRowAccessibility` exists one file over: a label written
/// inline in a `body` is a claim nothing can hold. `swift test` cannot see the
/// screen, but these it can see — and #79 asks for the five column captions to
/// still be there *after* a panel was inserted between them, which is a claim
/// worth being able to make.
///
/// Singular is written out in both captions here. "1 cards" is the kind of thing
/// that makes a careful product look careless, and these strings are read aloud.
/// The group header had already been fixed for exactly that and the column
/// caption above it had not — which is the argument for one function rather than
/// two spellings.
enum BoardAccessibility {

    /// A column's caption: its name, how many cards are in it, and either the
    /// consequence of dropping the card in hand or the column's standing rule.
    ///
    /// The caller decides which of those two `rule` is — that choice is
    /// `Consequence.of(model.preview(…))`, the same call the visible caption
    /// makes, and duplicating it here would be a second answer to it.
    static func columnCaption(name: String, count: Int, rule: String) -> String {
        "\(name), \(count) \(cards(count)). \(rule)"
    }

    /// A repository group inside a column, when the picker says "All
    /// repositories".
    static func groupCaption(repoName: String, count: Int, column: String) -> String {
        "\(repoName), \(count) \(cards(count)) in \(column)"
    }

    /// One day's heading in the Done column, or in the archive.
    ///
    /// Here rather than spelled out in `ShipDayHeader` for the reason recorded
    /// on `groupCaption`: the singular has to be written out by the one
    /// function that knows how, or a third label on this column joins the two
    /// that once disagreed about "1 cards".
    ///
    /// `partial` is the archive's case and defaults to the board's: a day the
    /// page boundary may have cut is spoken as a floor, because the visible
    /// capsule reads "23+" and VoiceOver cannot render a glyph. Saying "23
    /// cards" to the one reader who cannot see the "+" would hand them the
    /// precise claim this header stopped making.
    static func shipDayCaption(day: String, count: Int, partial: Bool = false) -> String {
        "\(day), \(partial ? "at least " : "")\(count) \(cards(count))"
    }

    /// Done's footer: how many finished cards the horizon is not drawing, and
    /// where the rest of them are.
    ///
    /// Empty at zero rather than "0 older cards", because at zero the footer is
    /// **not drawn at all** — a label announcing a control that is not on
    /// screen is worse than no label. The visible row is terser than this
    /// ("37 older · Open Archive"); a sentence is what VoiceOver needs.
    static func olderFooter(count: Int) -> String {
        guard count > 0 else { return "" }
        return "\(count) older \(cards(count)). Open Archive."
    }

    /// One row of a card's move history, read as a sentence.
    ///
    /// The visible row is a tabular line — two columns, an age, an origin — and
    /// read out field by field it would be four disconnected fragments. This is
    /// the same information as a sentence, which is what
    /// `.accessibilityElement(children: .combine)` needs to be given instead.
    ///
    /// `run` is optional and the clause is omitted entirely when it is `nil`:
    /// VoiceOver must not say "started" about a move that started nothing.
    static func historyRowLabel(
        from: String, to: String, age: String, origin: String, run: String?
    ) -> String {
        let base = "\(from) to \(to), \(age), \(origin)"
        guard let run else { return base }
        return "\(base). Started \(run)"
    }

    /// What the detail panel announces itself as.
    ///
    /// It names the column as well as the card, and that is the whole point of
    /// the sentence. A sighted reader learns which column the panel belongs to
    /// from the caret, the tether and the rail across its top — all three of
    /// which are `.accessibilityHidden(true)`, because they are decoration for a
    /// relationship that has to be *stated* rather than drawn. This is the
    /// statement. Drop the column from it and a listener has no way left to
    /// learn it.
    ///
    /// Applied in `DetailPanelView`, not here, and that is not arbitrary: the
    /// label VoiceOver uses is the one nearest the view, so a second one
    /// attached out here would be silently inert. It lives in this file only
    /// because it is a sentence a test can hold, next to the other two.
    static func panelLabel(title: String, column: ElliotModel.Column) -> String {
        "Details for \(title), in \(column.displayName)"
    }

    /// What the analysis panel announces itself as.
    ///
    /// The detail panel's label above carries a column because a caret and a
    /// tether draw that relationship and neither can be heard. This one carries
    /// a **repository** for the mirror-image reason: the analysis panel has no
    /// caret and no origin column, so nothing on it draws which repository it is
    /// about — it is in the toolbar picker, three controls away.
    ///
    /// Three sentences, one per state the panel can be in. A pure function for
    /// the reason the two captions above are: a label written inline in a `body`
    /// is a claim nothing can hold.
    static func analysisPanelLabel(repoName: String?, proposalCount: Int?) -> String {
        guard let repoName else { return "Analysis. Pick a single repository to analyse." }
        guard let proposalCount else { return "Analysis of \(repoName). Not started." }
        let noun = proposalCount == 1 ? "proposal" : "proposals"
        return "Analysis of \(repoName), \(proposalCount) \(noun) to decide."
    }

    private static func cards(_ count: Int) -> String {
        count == 1 ? "card" : "cards"
    }
}
