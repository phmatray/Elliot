import SwiftUI

/// A panel's outer edge, as something you can grab.
///
/// One view rather than one per panel. Before this the board had a single
/// resizable panel and the strip lived inside it; #151 added a second, and the
/// four things in here are each a fix with a reason —
///
/// - the **paired hover guard**: SwiftUI can deliver a repeated `true` while the
///   pointer moves inside the strip, and an unpaired push leaves the resize
///   cursor stuck over the whole board;
/// - the **`onDisappear` pop**: Escape can close a panel while the pointer is on
///   its handle, in which case the exit hover never arrives;
/// - the **2pt minimum distance**, so a click that never moves cannot resize
///   behind the reader's back;
/// - the **adjustable action**, because a drag gesture alone is a control only a
///   mouse can reach.
///
/// Copied into a second panel those become four bugs' worth of learning sitting
/// in a place that can drift from this one — which is the shape this repository
/// has already paid for twice, in `ProcessRunner`/`StreamingProcess` (#146) and
/// in the three hand-written outcome switches (#135).
///
/// ⚠️ The snap itself lives in `PanelLayout.snappedSpans`, not here. This file
/// has no assertions in it; the arithmetic of "given a drag and a column width,
/// which span wins" is the half a test can hold, and it is held in
/// `PanelResizeTests`.
struct PanelResizeHandle: View {
    @Binding var spans: Int

    /// The board's column width, which is what a span is measured in.
    let columnWidth: CGFloat

    /// Whether the panel opens to its origin's **left** — which puts the handle
    /// on the leading edge and reverses which way "wider" is.
    ///
    /// Always `false` for the analysis panel, which is pinned at the row's
    /// leading edge and therefore always grabbed by its trailing one.
    let opensLeft: Bool

    /// The tooltip, and the VoiceOver label. Both name the panel, because a
    /// board with two of them has two of these and "Panel width" would be the
    /// same sentence twice.
    let help: String
    let label: String

    @State private var isOver = false

    var body: some View {
        Rectangle()
            .fill(.clear)
            .frame(width: Metric.resizeStripWidth)
            .overlay {
                Capsule()
                    .fill(isOver ? Surface.chipFillHover : Surface.hairline)
                    .frame(width: Metric.resizeGrip.width, height: Metric.resizeGrip.height)
            }
            // The strip is transparent, so without this only the 2pt grip would
            // take a hit and the cursor would flicker along the edge.
            .contentShape(Rectangle())
            .onHover { hovering in
                guard hovering != isOver else { return }
                isOver = hovering
                if hovering {
                    NSCursor.resizeLeftRight.push()
                } else {
                    NSCursor.pop()
                }
            }
            .onDisappear {
                guard isOver else { return }
                isOver = false
                NSCursor.pop()
            }
            .gesture(
                // Snapped on release, not tracked live: the two settings are two
                // *layouts*, and rebuilding the body at every intermediate width
                // would flip a panel's contents in and out under the reader's
                // hand.
                DragGesture(minimumDistance: 2)
                    .onEnded { drag in
                        spans = PanelLayout.snappedSpans(
                            from: spans,
                            translation: drag.translation.width,
                            columnWidth: columnWidth,
                            opensLeft: opensLeft
                        )
                    }
            )
            .help(help)
            .accessibilityLabel(label)
            .accessibilityValue("\(spans) columns")
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: spans = PanelLayout.spanChoices.wide
                case .decrement: spans = PanelLayout.spanChoices.narrow
                @unknown default: break
                }
            }
    }
}
