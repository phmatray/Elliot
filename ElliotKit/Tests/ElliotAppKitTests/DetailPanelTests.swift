import ElliotModel
import Foundation
import Testing

@testable import ElliotAppKit

/// What a test can hold of the detail panel's own shape.
///
/// Not the pixels. `swift test` cannot see where anything sits on screen, and
/// this project has paid for pretending otherwise four times (#47, #50, #52,
/// #53). What it *can* see is which blocks the panel builds, and that is where
/// the one thing that must not go wrong lives.
///
/// ### The thing that must not go wrong
///
/// #85 moved the merge confirmation onto this panel deliberately above
/// everything else on it, because it is the only thing there waiting on the
/// reader and the one act in the product that cannot be undone.
/// `AppModel.armPendingMerge` selects the card, opens the panel *and* arms the
/// merge together — the panel is opened in order to show the confirmation.
///
/// At two spans the panel shows one pane behind a switch. A confirmation drawn
/// inside the Issue pane while the reader sits on Runs would be an armed merge
/// with nowhere to confirm it: the fail-closed case #85 exists to prevent. So it
/// is drawn in the **header**, outside the switch, and this suite pins that at
/// every span and on every pane.
///
/// Half of that guarantee is not asserted here because it cannot be violated:
/// `headerRegions` returns `[PanelHeaderRegion]` and `panes` returns
/// `[PanelPane]`, two types with no case in common, so `.mergeConfirmation` is
/// **unrepresentable** inside a pane. The signature of `headerRegions` carries
/// the other half — it takes no selected pane, so no header block can vary with
/// which pane is showing.
@Suite("Detail panel")
struct DetailPanelTests {

    /// Every span the panel is meant to be read at, plus one either side. 1 and
    /// 4 are not settings the menu offers; they are here because a preference is
    /// an integer and nothing stops a future one being out of range.
    private let spans = [1, 2, 3, 4]

    // MARK: - 1. The confirmation cannot be hidden

    @Test("The merge confirmation is in the header at every span and on every pane")
    func mergeConfirmationSurvivesTheSwitch() {
        for span in spans {
            for hasNextStep in [true, false] {
                let header = PanelLayout.headerRegions(
                    spans: span,
                    isEditing: false,
                    isMergePending: true,
                    hasNextStep: hasNextStep
                )

                #expect(header.contains(.mergeConfirmation))
                // Above everything else on the panel, which is the position #85
                // put it in and the reason it is legible at all.
                #expect(header.first == .mergeConfirmation)

                // And on every pane a reader could be sitting on. `headerRegions`
                // takes no pane, so this asserts the consequence of that: the
                // header is the same list whichever pane is showing, and the
                // pane that *is* showing never carries it.
                for pane in PanelPane.allCases {
                    let visible = PanelLayout.panes(spans: span, selected: pane)
                    #expect(visible.contains(pane))
                    #expect(
                        PanelLayout.headerRegions(
                            spans: span,
                            isEditing: false,
                            isMergePending: true,
                            hasNextStep: hasNextStep
                        ) == header
                    )
                }
            }
        }
    }

    @Test("An armed merge outlives edit mode, where nothing else in the header does")
    func mergeConfirmationSurvivesTheEditor() {
        for span in spans {
            let editing = PanelLayout.headerRegions(
                spans: span, isEditing: true, isMergePending: true, hasNextStep: true
            )
            // The editor replaces the body, so there is no pane to switch and no
            // next step to take — but an answer is still being waited on.
            #expect(editing == [.mergeConfirmation])
        }
    }

    @Test("No confirmation, no block — the header does not reserve a slot for it")
    func nothingIsDrawnWithoutAPendingMerge() {
        for span in spans {
            let header = PanelLayout.headerRegions(
                spans: span, isEditing: false, isMergePending: false, hasNextStep: true
            )
            #expect(!header.contains(.mergeConfirmation))
            #expect(header.first == .nextStep)
        }
    }

    // MARK: - 2. The hidden pane is absent, not invisible

    @Test("At three spans both panes are built; below it only the selected one")
    func onlyTheSelectedPaneIsBuiltWhenOneFits() {
        #expect(PanelLayout.panes(spans: 3, selected: .issue) == [.issue, .runs])
        #expect(PanelLayout.panes(spans: 3, selected: .runs) == [.issue, .runs])
        #expect(PanelLayout.panes(spans: 4, selected: .runs) == [.issue, .runs])

        // One entry, and it is the chosen one — **not** two with one hidden.
        // Criterion 5: a hidden-but-present pane is still reachable by
        // VoiceOver, so a reader on Runs would be read the issue body.
        #expect(PanelLayout.panes(spans: 2, selected: .issue) == [.issue])
        #expect(PanelLayout.panes(spans: 2, selected: .runs) == [.runs])
        #expect(PanelLayout.panes(spans: 1, selected: .runs) == [.runs])

        for span in spans {
            for pane in PanelPane.allCases {
                let visible = PanelLayout.panes(spans: span, selected: pane)
                #expect(!visible.isEmpty)
                #expect(visible.contains(pane))
                #expect(visible.count <= PanelPane.allCases.count)
            }
        }
    }

    @Test("The switch appears exactly when a pane is hidden")
    func theSwitchAndTheBodyCannotDisagree() {
        for span in spans {
            for pane in PanelPane.allCases {
                let visible = PanelLayout.panes(spans: span, selected: pane)
                let hasSwitch = PanelLayout.headerRegions(
                    spans: span, isEditing: false, isMergePending: false, hasNextStep: true
                )
                .contains(.paneSwitch)

                // A switch offering a choice between two panes already on screen
                // is furniture; a hidden pane with no switch is unreachable.
                #expect(hasSwitch == (visible.count < PanelPane.allCases.count))
                #expect(hasSwitch == !PanelLayout.showsBothPanes(spans: span))
            }
        }
    }

    // MARK: - 3. The next step block

    @Test("The next step block is admitted only when there is a next step")
    func noEmptyNextStepBlock() {
        // Done has nowhere to go, so the block is absent rather than present and
        // empty — the same rule `IssuePane.sections` follows.
        for span in spans {
            let none = PanelLayout.headerRegions(
                spans: span, isEditing: false, isMergePending: false, hasNextStep: false
            )
            #expect(!none.contains(.nextStep))
        }

        // And it is a real column that has none: the layout's `hasNextStep` is
        // fed from `naturalNext`, so this pins the one column that answers nil.
        let terminal = ElliotModel.Column.allCases.filter { $0.naturalNext == nil }
        #expect(terminal == [.done])
    }

    // MARK: - 4. Reading order

    @Test("Header order is fixed: confirmation, next step, switch")
    func headerReadsInOneOrder() {
        let full = PanelLayout.headerRegions(
            spans: 2, isEditing: false, isMergePending: true, hasNextStep: true
        )
        #expect(full == [.mergeConfirmation, .nextStep, .paneSwitch])

        let wide = PanelLayout.headerRegions(
            spans: 3, isEditing: false, isMergePending: true, hasNextStep: true
        )
        #expect(wide == [.mergeConfirmation, .nextStep])
    }

    // MARK: - 5. The width the panel asks for

    @Test("The panel is as wide as its spans say, at the default and at both settings")
    func panelWidthFollowsTheReaderPreference() {
        // 316pt columns — the 1640pt default window. Tied to the same formula
        // the columns are laid out with rather than to a constant.
        let column = PanelLayout.columnWidth(boardWidth: 1_640)
        #expect(PanelLayout.panelWidth(columnWidth: column, spans: 3) == 968)
        #expect(PanelLayout.panelWidth(columnWidth: column, spans: 2) == 642)

        // Wider than the strip it replaces at both settings — `Metric
        // .inspectorWidth` was 344pt however large the window was.
        for span in [2, 3] {
            #expect(PanelLayout.panelWidth(columnWidth: column, spans: span) > 344)
        }
    }

    @MainActor
    @Test("The panel opens at three spans — the two-pane body — by default")
    func defaultSpansShowBothPanes() {
        let model = AppModel()
        #expect(model.panelSpans == 3)
        #expect(PanelLayout.showsBothPanes(spans: model.panelSpans))
        #expect(PanelLayout.panes(spans: model.panelSpans, selected: .issue) == [.issue, .runs])
    }

    // MARK: - 6. The panes themselves

    @Test("Two panes, each with a word the switch can fit")
    func panesAreNamed() {
        #expect(PanelPane.allCases == [.issue, .runs])
        #expect(PanelPane.issue.displayName == "Issue")
        #expect(PanelPane.runs.displayName == "Runs")
        for pane in PanelPane.allCases {
            #expect(!pane.displayName.isEmpty)
            #expect(pane.id == pane.rawValue)
        }
    }
}
