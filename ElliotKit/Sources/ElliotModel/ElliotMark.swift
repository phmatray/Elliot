import Foundation

/// A point in the mark's unit square. `x` and `y` both run `0…1`, with `y`
/// increasing **downward**; adapters map it into their own space, and the
/// CoreGraphics one flips `y`.
public struct MarkPoint: Sendable, Hashable, Codable {
    public let x: Double
    public let y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

/// One step of the mark's outline. Deliberately not a `CGPath`: `ElliotModel`
/// stays free of frameworks, and both adapters — a SwiftUI `Shape` and a
/// CoreGraphics context — can walk these cases in a dozen lines each.
public enum MarkSegment: Sendable, Hashable {
    case move(MarkPoint)
    case line(MarkPoint)
    case curve(to: MarkPoint, control: MarkPoint)
    case close
}

/// Elliot's mark: a chevron card, pointed on the right and notched on the left,
/// so consecutive cards interlock. It is a card and an arrow at once, which is
/// what the app claims — moving a card is the act of execution.
public enum ElliotMark {
    /// How deep the chevron cuts, as a fraction of the unit square.
    static let depth = 0.14
    /// The band the cards occupy vertically.
    static let top = 0.18
    static let bottom = 0.82
    /// Left and right margin inside the unit square.
    static let margin = 0.07
    /// Corner rounding, clamped per corner by `roundedPolygon`.
    static let cornerRadius = 0.035

    /// How many cards the artwork shows at a given rendered pixel size.
    ///
    /// Three interlocking cards read as a procession at 64 px and up; below
    /// that they are three grey smears, so the small sizes carry one. The
    /// envelope is identical either way, so it stays the same logo.
    public static func cardCount(forPixelSize pixels: Int) -> Int {
        pixels >= 64 ? 3 : 1
    }

    /// The six vertices of card `index`, walked clockwise from the top-left.
    ///
    /// Index 2 is the point and index 5 is the notch tip; card `i`'s point is
    /// exactly card `i+1`'s notch, which is what makes the procession
    /// interlock rather than overlap.
    public static func vertices(_ index: Int, of count: Int) -> [MarkPoint] {
        precondition(count > 0 && index >= 0 && index < count, "card \(index) of \(count)")
        let width = (1 - 2 * margin - depth) / Double(count)
        let x0 = margin + Double(index) * width
        let x1 = x0 + width
        let mid = (top + bottom) / 2
        return [
            MarkPoint(x: x0, y: top),
            MarkPoint(x: x1, y: top),
            MarkPoint(x: x1 + depth, y: mid),
            MarkPoint(x: x1, y: bottom),
            MarkPoint(x: x0, y: bottom),
            MarkPoint(x: x0 + depth, y: mid),
        ]
    }

    /// Card `index` of `count`, as a closed, corner-rounded outline.
    public static func card(_ index: Int, of count: Int) -> [MarkSegment] {
        roundedPolygon(vertices(index, of: count), radius: cornerRadius)
    }

    /// Round a closed polygon's corners with quadratic curves.
    ///
    /// The radius is clamped **per corner** to half the shorter adjacent edge.
    /// Without that, the chevron tip — whose two edges are the shortest in the
    /// shape — turns inside out.
    public static func roundedPolygon(_ points: [MarkPoint], radius: Double) -> [MarkSegment] {
        precondition(points.count >= 3, "a polygon needs at least three points")

        func lerp(_ a: MarkPoint, _ b: MarkPoint, _ t: Double) -> MarkPoint {
            MarkPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
        }
        func length(_ a: MarkPoint, _ b: MarkPoint) -> Double {
            ((b.x - a.x) * (b.x - a.x) + (b.y - a.y) * (b.y - a.y)).squareRoot()
        }

        var segments: [MarkSegment] = []
        for index in points.indices {
            let previous = points[(index + points.count - 1) % points.count]
            let corner = points[index]
            let next = points[(index + 1) % points.count]

            let incoming = length(previous, corner)
            let outgoing = length(corner, next)
            let clamped = min(radius, incoming / 2, outgoing / 2)

            let start = lerp(corner, previous, incoming == 0 ? 0 : clamped / incoming)
            let end = lerp(corner, next, outgoing == 0 ? 0 : clamped / outgoing)

            if index == 0 {
                segments.append(.move(start))
            } else {
                segments.append(.line(start))
            }
            segments.append(.curve(to: end, control: corner))
        }
        segments.append(.close)
        return segments
    }
}

/// One file `iconutil` expects to find in an `.iconset` directory.
public struct IconSetEntry: Sendable, Hashable, Codable {
    public let fileName: String
    public let pixels: Int

    public init(fileName: String, pixels: Int) {
        self.fileName = fileName
        self.pixels = pixels
    }
}

/// The exact set `iconutil -c icns` requires. Kept here rather than in the
/// renderer so it is reachable by `swift test`.
public enum IconSet {
    public static let entries: [IconSetEntry] = [
        IconSetEntry(fileName: "icon_16x16.png", pixels: 16),
        IconSetEntry(fileName: "icon_16x16@2x.png", pixels: 32),
        IconSetEntry(fileName: "icon_32x32.png", pixels: 32),
        IconSetEntry(fileName: "icon_32x32@2x.png", pixels: 64),
        IconSetEntry(fileName: "icon_128x128.png", pixels: 128),
        IconSetEntry(fileName: "icon_128x128@2x.png", pixels: 256),
        IconSetEntry(fileName: "icon_256x256.png", pixels: 256),
        IconSetEntry(fileName: "icon_256x256@2x.png", pixels: 512),
        IconSetEntry(fileName: "icon_512x512.png", pixels: 512),
        IconSetEntry(fileName: "icon_512x512@2x.png", pixels: 1024),
    ]
}
