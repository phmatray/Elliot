import SwiftUI

// MARK: - What the caret is drawn from

/// The three rectangles the caret needs, each reported by the view that owns it:
/// the selected card, the viewport of the list it sits in, and the panel.
///
/// One value and one key rather than three, because the caret is a statement
/// about all three at once — "*this* panel points at *that* card, which is
/// *inside* its column's viewport". Three separate keys would arrive in three
/// separate updates and could disagree for a frame about which column is the
/// origin, which is exactly long enough to draw an arrow at a card that is not
/// there.
struct CaretAnchors {
    /// The selected card. `nil` when nothing is selected, and — the case that
    /// matters — when the card is scrolled far enough that the `LazyVStack`
    /// never built it. `PanelLayout.isDetached` reads that absence as out of
    /// band, which is what it means.
    var card: Anchor<CGRect>?
    /// The origin column's scrollable viewport, not its content: what the
    /// reader can currently see of that list.
    var list: Anchor<CGRect>?
    /// The panel itself. `nil` while the panel is shut, and that is the whole
    /// "draw nothing" condition — no second copy of "is the panel showing".
    var panel: Anchor<CGRect>?
}

/// Carries `CaretAnchors` up the board.
///
/// ⚠️ **`reduce` merges; it does not replace.** The three contributions come
/// from three different subtrees, so the obvious `value = nextValue()` would
/// leave whichever one SwiftUI visits last and silently drop the other two —
/// and the symptom of that is a caret that never appears, with a green build
/// and a green test run behind it.
///
/// ⚠️ **And `reduce` only ever sees siblings.** It is the *whole* defence for
/// three subtrees, and no defence at all one level up: `.anchorPreference`
/// applied to a view that is an **ancestor** of another writer replaces that
/// writer's value outright rather than merging with it, so `reduce` is never
/// called for the pair. That is #159 — `ColumnView.list` wrote `list` on the
/// `ScrollView` containing the cards, and the selected card's rect was
/// discarded one level below the overlay while this comment said the design was
/// safe. Every writer for this key must therefore be a sibling of the others;
/// the column reports through a `.background` for exactly that reason. Anything
/// new that wants to contribute here reports from its own subtree, never from
/// above someone else's.
///
/// Anchors are used rather than a coordinate space plus stored state on
/// purpose. An anchor is resolved by the `GeometryProxy` that reads it, so the
/// card, the list and the panel are all measured in **one** space by
/// construction, with nothing to keep in sync — and, unlike a measurement
/// written back into `@State`, the value the caret draws from comes out of the
/// layout pass that is happening now rather than the one before it. That is the
/// same trap `frame(boardWidth:)` documents one file over.
enum CaretAnchorKey: PreferenceKey {
    static var defaultValue: CaretAnchors { CaretAnchors() }

    static func reduce(value: inout CaretAnchors, nextValue: () -> CaretAnchors) {
        let next = nextValue()
        value.card = next.card ?? value.card
        value.list = next.list ?? value.list
        value.panel = next.panel ?? value.panel
    }
}

/// Report one of the caret's three rectangles, from a subtree of one's own.
///
/// **The only supported way to write `CaretAnchorKey`**, and the reason is
/// #159. A bare `.anchorPreference` is correct on a leaf and quietly wrong on a
/// container: applied to a view that is an *ancestor* of another writer it
/// **replaces** that writer's value rather than merging with it, and `reduce`
/// — which is the whole defence for this key — is never called for the pair.
/// `ColumnView.list` was that container, and the selected card's rectangle was
/// discarded one level below the overlay for two releases while every
/// arithmetic test stayed green.
///
/// Reporting from a `.background` makes the two siblings instead, which is the
/// case that always worked. The rect is unchanged: background content is sized
/// by the view it backs, so this measures exactly what the modifier applied
/// directly would have measured, and `Color.clear` claims no space.
///
/// Written as one helper rather than three call sites because the safe form and
/// the broken form look equally reasonable in a diff — the point is that the
/// broken one is no longer expressible where the caret is concerned.
/// `CaretAnchorTests` holds that: it reads this target and fails if the key is
/// written anywhere but here.
///
/// ⚠️ `allowsHitTesting(false)` is not tidiness. A background lies under its
/// view, and the columns deselect on a tap that reaches their empty space — a
/// `Color.clear` that took hits would sit between the reader and that gesture,
/// which is the class of defect #158 is about. It reports geometry and takes
/// nothing.
extension View {
    func reportsCaretAnchor(
        _ transform: @escaping (Anchor<CGRect>) -> CaretAnchors
    ) -> some View {
        background {
            Color.clear
                .anchorPreference(key: CaretAnchorKey.self, value: .bounds, transform: transform)
                .allowsHitTesting(false)
        }
    }
}

// MARK: - The caret's own shape

/// The numbers the caret and the tether are placed from, with no view attached.
///
/// The board's arithmetic lives in `PanelLayout` — widths, order, `caretY`,
/// `isDetached`, `tetherReach`. This is the smaller question of where the two
/// decorations sit against the panel's **edge**, which is the caret's own shape
/// rather than the board's layout, and it is here so the mirrored case can be
/// pinned by a test: a caret drawn on the wrong side is invisible in exactly one
/// column and nowhere else.
///
/// Read off the approved mockup (`docs/mockups/inline-detail-panel.html`,
/// `.caret` / `.tether`). The CSS offsets are relative to the panel's *padding*
/// box, so both shapes sit 1pt inside the panel's border line: the caret's mouth
/// covers the border it is notched out of instead of being a triangle glued to
/// the outside of it.
enum CaretMetric {
    /// How far the caret's point reaches past the panel's edge.
    static let depth: CGFloat = 8
    /// Half the caret's mouth, so the triangle stands `2 × halfHeight` tall.
    static let halfHeight: CGFloat = 9
    /// The panel's border, which the caret's base overlaps by exactly this much
    /// — the same 1pt `DetailPanelView` strokes its outline with.
    static let border: CGFloat = 1

    /// Where the caret's centre falls, given the panel edge it hangs off.
    ///
    /// `flipped` mirrors it about that edge: after the origin column the caret
    /// is on the panel's leading edge pointing back at the card, and before Done
    /// it is on the trailing edge pointing the other way.
    static func caretCenterX(panelEdgeX: CGFloat, flipped: Bool) -> CGFloat {
        let outward = (depth - border) / 2
        return flipped ? panelEdgeX + outward : panelEdgeX - outward
    }

    /// Where the tether's centre falls. It runs from the panel's edge outward by
    /// `PanelLayout.tetherReach`, which is the gutter plus the column's own list
    /// padding — the distance that makes it touch the card rather than stop
    /// short of it.
    static func tetherCenterX(panelEdgeX: CGFloat, flipped: Bool) -> CGFloat {
        let half = PanelLayout.tetherReach / 2
        return flipped ? panelEdgeX + half : panelEdgeX - half
    }

    /// The caret has lost its card: the tether cannot point at anything, and the
    /// caret says so rather than lying at a third of its weight.
    static let detachedTether: Double = 0
    static let detachedCaret: Double = 0.35
}

// MARK: - The view

/// The 2pt rail from the selected card to the panel, and the caret notched out
/// of the panel's edge where it lands.
///
/// Two decisions come straight from the mockup and neither is decoration:
///
/// 1. **The tether is a rail, not a new element.** Same `Metric.railHeight` the
///    columns wear for what arriving costs, same `Palette.armed` the selected
///    card already wears as its border — this is that border continuing across
///    the gutter. It reaches `PanelLayout.tetherReach`, the gutter *plus* the
///    column's list padding, because a line that stops 8pt short of the card
///    reads as a dash near it rather than a line leaving it.
/// 2. **The caret belongs to the panel.** It is drawn in the panel's border
///    colour and filled with the panel's own background, so it reads as a notch
///    in the panel meeting a line from the card — two objects — rather than as
///    an arrow the card is holding.
///
/// It is drawn as an overlay over the whole board row rather than inside the
/// panel, for one reason: the caret and the tether live *outside* the panel's
/// bounds, and in the flipped case they hang over Done. Up here nothing can clip
/// them and nothing can paint over them.
///
/// ⚠️ `allowsHitTesting(false)` is load-bearing rather than tidy — this overlay
/// covers the entire board, so without it no card could be clicked or dragged
/// anywhere. `accessibilityHidden(true)` for the other half of the same thought:
/// it is decoration for a relationship the accessibility tree already states in
/// words.
struct CaretRail: View {
    let anchors: CaretAnchors
    /// Whether the panel opened to its column's left — `PanelLayout.opensLeft`,
    /// decided once by the board and passed in, never re-derived here.
    let flipped: Bool

    var body: some View {
        // No panel, no caret. The panel's anchor exists only while the panel is
        // built, so this is the same condition the board draws the panel on
        // rather than a second copy of it.
        if let panelAnchor = anchors.panel {
            GeometryReader { proxy in
                // Every rectangle below is resolved by this one proxy, so the
                // card, the list and the panel are in one space by
                // construction. A GeometryReader is safe *here* — overlay
                // content is sized by the view it covers, so it cannot claim
                // space or move anything, which is not true of one wrapped
                // around a card.
                let panel = proxy[panelAnchor]
                let card = anchors.card.map { proxy[$0] }
                let list = anchors.list.map { proxy[$0] }

                let midY = card?.midY
                let detached = PanelLayout.isDetached(
                    cardMidY: midY,
                    listTop: list?.minY ?? .infinity,
                    listBottom: list?.maxY ?? -.infinity
                )
                // Clamped inside the panel so the caret never points at a
                // rounded corner. Falling back to the panel's own middle is the
                // only honest answer when there is no card rect: it is drawn
                // detached in that case, so it points at nothing and says so.
                let y = panel.minY + PanelLayout.caretY(
                    cardMidY: midY ?? panel.midY,
                    panelMinY: panel.minY,
                    panelHeight: panel.height
                )
                let edgeX = flipped ? panel.maxX : panel.minX

                // Both children are placed by `position`, which fills whatever
                // it is given — so this stack is a paint order and nothing else.
                ZStack {
                    tether
                        .opacity(detached ? CaretMetric.detachedTether : 1)
                        .position(
                            x: CaretMetric.tetherCenterX(panelEdgeX: edgeX, flipped: flipped),
                            y: y
                        )
                    // Drawn after the tether, and that order is the design: the
                    // caret's window-coloured fill covers the last few points of
                    // the rail, so the line appears to leave the caret's point
                    // instead of running under it to the panel wall.
                    caret
                        .opacity(detached ? CaretMetric.detachedCaret : 1)
                        .position(
                            x: CaretMetric.caretCenterX(panelEdgeX: edgeX, flipped: flipped),
                            y: y
                        )
                }
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }

    /// The rail across the gutter, in the selected card's own border colour.
    private var tether: some View {
        Rectangle()
            .fill(Palette.armed)
            .frame(width: PanelLayout.tetherReach, height: Metric.railHeight)
    }

    /// The panel's border, brought to a point.
    ///
    /// Two triangles: the outline in the panel's border colour, and the panel's
    /// own background inset by exactly the border width on all three sides —
    /// which is what leaves a 1pt line along the two diagonals and nothing
    /// across the mouth.
    private var caret: some View {
        ZStack(alignment: flipped ? .leading : .trailing) {
            CaretShape(pointsLeft: !flipped)
                .fill(Color(nsColor: .separatorColor))
                .frame(
                    width: CaretMetric.depth + CaretMetric.border,
                    height: CaretMetric.halfHeight * 2
                )
            CaretShape(pointsLeft: !flipped)
                .fill(Color(nsColor: .windowBackgroundColor))
                .frame(
                    width: CaretMetric.depth,
                    height: CaretMetric.halfHeight * 2 - CaretMetric.border * 2
                )
        }
    }
}

/// A triangle with its flat side against the panel and its point at the card.
private struct CaretShape: Shape {
    /// Which way the point faces. The flat side is always the one that meets the
    /// panel, so this flips with the panel.
    var pointsLeft: Bool

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let base = pointsLeft ? rect.maxX : rect.minX
        let tip = pointsLeft ? rect.minX : rect.maxX
        path.move(to: CGPoint(x: base, y: rect.minY))
        path.addLine(to: CGPoint(x: tip, y: rect.midY))
        path.addLine(to: CGPoint(x: base, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}
