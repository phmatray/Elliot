import ElliotModel
import SwiftUI

/// The labels a card asks its issue to carry, drawn as chips.
///
/// One view for both places a card's labels appear — removable in the editor,
/// read-only in the detail panel — because they are the same list saying the
/// same thing, and a second copy would be a second answer to "what does a
/// label the repository lacks look like".
///
/// `onRemove` being `nil` is what makes it read-only, rather than a `Kind` or a
/// boolean: the read-only site has nothing to pass, so it cannot forget to.
struct LabelChips: View {
    let names: [String]
    /// Whether the repository is **known not to have** this label. Supplied
    /// rather than computed, so the one rule lives in `RepositoryLabels` where
    /// `swift test` holds it — and so a caller that has established nothing
    /// accuses nothing.
    let isMissing: (String) -> Bool
    var onRemove: ((String) -> Void)?

    var body: some View {
        // Wraps rather than scrolling: a card can carry more labels than a
        // two-span panel is wide, and a horizontal scroller would hide the
        // overflow behind a gesture nobody knows to make.
        FlowRow(spacing: 6) {
            ForEach(names, id: \.self) { name in
                chip(name)
            }
        }
    }

    private func chip(_ name: String) -> some View {
        let missing = isMissing(name)
        return HStack(spacing: 4) {
            if missing {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 8))
                    .foregroundStyle(Palette.attention)
            }
            Text(name)
                .font(Type.fact)
                // Struck through, not hidden and not dropped: the card records
                // what someone asked for, and a label the repository no longer
                // has is a fact about the repository rather than a reason to
                // forget the request.
                .strikethrough(missing, color: Palette.attention)
            if onRemove != nil {
                Image(systemName: "xmark")
                    .font(.system(size: 7, weight: .bold))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(Surface.chipFill)
        .clipShape(Capsule())
        .overlay {
            if missing { Capsule().strokeBorder(Palette.attention.opacity(0.5)) }
        }
        .contentShape(Capsule())
        .modifier(RemoveChip(name: name, onRemove: onRemove))
        .accessibilityLabel(accessibilityLabel(name, missing: missing))
    }

    /// Said in words, because the mark that carries it on screen is a colour
    /// and a strike-through — neither of which a screen reader announces.
    private func accessibilityLabel(_ name: String, missing: Bool) -> String {
        let base = missing ? "\(name) — this repository does not have this label" : name
        return onRemove == nil ? base : "\(base). Remove"
    }
}

/// Makes a chip tappable only when there is something to do, so a read-only
/// chip is not a button that does nothing.
private struct RemoveChip: ViewModifier {
    let name: String
    let onRemove: ((String) -> Void)?

    func body(content: Content) -> some View {
        if let onRemove {
            Button { onRemove(name) } label: { content }
                .buttonStyle(.plain)
                .help("Remove \(name)")
        } else {
            content
        }
    }
}

/// A row that wraps onto the next line instead of overflowing.
///
/// Hand-written rather than `LazyVGrid`: a grid wants columns of a known width
/// and these are chips of whatever width their text is. This is the whole of
/// what `Layout` was added for, and it is 20 lines.
struct FlowRow: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = layout(subviews: subviews, width: proposal.width ?? .infinity)
        let height = rows.last.map { $0.y + $0.height } ?? 0
        let width = rows.map { $0.width }.max() ?? 0
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(
        in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
    ) {
        for row in layout(subviews: subviews, width: bounds.width) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(
                    at: CGPoint(x: x, y: bounds.minY + row.y),
                    proposal: ProposedViewSize(size)
                )
                x += size.width + spacing
            }
        }
    }

    private struct Row {
        var indices: [Int] = []
        var y: CGFloat = 0
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func layout(subviews: Subviews, width: CGFloat) -> [Row] {
        var rows: [Row] = []
        var current = Row()
        var x: CGFloat = 0

        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            // `!current.indices.isEmpty` so a chip wider than the whole row
            // still gets a row of its own rather than looping for ever.
            if x + size.width > width, !current.indices.isEmpty {
                rows.append(current)
                current = Row(y: current.y + current.height + spacing)
                x = 0
            }
            current.indices.append(index)
            current.width = x + size.width
            current.height = max(current.height, size.height)
            x += size.width + spacing
        }
        if !current.indices.isEmpty { rows.append(current) }
        return rows
    }
}
