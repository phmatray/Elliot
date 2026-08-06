import ElliotModel
import SwiftUI

/// One card of the mark, drawn from the very geometry the icon renderer
/// rasterises. The app and the Dock cannot show different logos, because there
/// is only one.
///
/// A card at a time, rather than the whole procession in one path, because the
/// cards *tessellate*: card `i`'s point is exactly card `i+1`'s notch, so a
/// single path filled in a single tone merges all three into one silhouette
/// and the procession disappears.
struct MarkShape: Shape {
    var index = 0
    var of = 3

    func path(in rect: CGRect) -> Path {
        var path = Path()
        for segment in ElliotMark.card(index, of: of) {
            switch segment {
            case .move(let p): path.move(to: point(p, in: rect))
            case .line(let p): path.addLine(to: point(p, in: rect))
            case .curve(let to, let control):
                path.addQuadCurve(to: point(to, in: rect), control: point(control, in: rect))
            case .close: path.closeSubpath()
            }
        }
        return path
    }

    /// SwiftUI's `y` grows downward, which is the mark's own convention — no
    /// flip here, unlike the CoreGraphics renderer.
    private func point(_ mark: MarkPoint, in rect: CGRect) -> CGPoint {
        CGPoint(x: rect.minX + mark.x * rect.width, y: rect.minY + mark.y * rect.height)
    }
}

/// The mark on its plate: the app icon, at whatever size a view needs it.
///
/// The same three opacities the icon renderer uses, and for the same reason —
/// a single tone across all three cards renders as one blob, because they
/// interlock. Three `Shape`s in a `ZStack` is what it costs to show the mark
/// the Dock shows, which is the whole point of defining it once.
struct MarkBadge: View {
    var size: CGFloat = 32

    /// Left to right, the procession lightens into the irreversible end.
    private static let opacities: [Double] = [0.45, 0.72, 1]

    var body: some View {
        ZStack {
            ForEach(Array(Self.opacities.enumerated()), id: \.offset) { index, opacity in
                MarkShape(index: index, of: Self.opacities.count)
                    .fill(Palette.paper.opacity(opacity))
            }
        }
        .frame(width: size, height: size)
        .background(
            LinearGradient(
                colors: [Palette.armed, Palette.irreversible],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
        .clipShape(RoundedRectangle(cornerRadius: size * 0.2237, style: .continuous))
        .accessibilityHidden(true)
    }
}
