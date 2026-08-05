import Testing

@testable import ElliotModel

@Suite("The mark")
struct ElliotMarkTests {
    private func points(_ segments: [MarkSegment]) -> [MarkPoint] {
        segments.flatMap { segment -> [MarkPoint] in
            switch segment {
            case .move(let p), .line(let p): [p]
            case .curve(let to, let control): [to, control]
            case .close: []
            }
        }
    }

    @Test("A card is a closed path that starts with exactly one move", arguments: [1, 3])
    func pathIsClosed(count: Int) {
        for index in 0..<count {
            let segments = ElliotMark.card(index, of: count)
            let moves = segments.filter { if case .move = $0 { true } else { false } }
            #expect(moves.count == 1)
            if case .move = segments.first {} else { Issue.record("a path must open with a move") }
            #expect(segments.last == .close)
        }
    }

    @Test("Every card stays inside the unit square", arguments: [1, 3])
    func staysInUnitSquare(count: Int) {
        for index in 0..<count {
            for point in points(ElliotMark.card(index, of: count)) {
                #expect(point.x >= 0 && point.x <= 1)
                #expect(point.y >= 0 && point.y <= 1)
            }
        }
    }

    /// The reason this shape was chosen: a card's point is exactly the next
    /// card's notch, so the procession interlocks instead of overlapping.
    @Test("Cards tessellate: each point lands on the next card's notch")
    func cardsInterlock() {
        for index in 0..<2 {
            let mine = ElliotMark.vertices(index, of: 3)
            let next = ElliotMark.vertices(index + 1, of: 3)
            // Vertex 2 is the point; vertex 5 is the notch tip.
            #expect(abs(mine[2].x - next[5].x) < 1e-9)
            #expect(abs(mine[2].y - next[5].y) < 1e-9)
        }
    }

    /// The small sizes must be the same logo, not a different one.
    @Test("One card occupies the same envelope as three")
    func envelopeIsConstant() {
        let one = points(ElliotMark.card(0, of: 1))
        let three = (0..<3).flatMap { points(ElliotMark.card($0, of: 3)) }
        #expect(abs(one.map(\.x).min()! - three.map(\.x).min()!) < 1e-9)
        #expect(abs(one.map(\.x).max()! - three.map(\.x).max()!) < 1e-9)
    }

    @Test("Three cards above 64 px, one below")
    func sizeRule() {
        #expect(ElliotMark.cardCount(forPixelSize: 16) == 1)
        #expect(ElliotMark.cardCount(forPixelSize: 32) == 1)
        #expect(ElliotMark.cardCount(forPixelSize: 63) == 1)
        #expect(ElliotMark.cardCount(forPixelSize: 64) == 3)
        #expect(ElliotMark.cardCount(forPixelSize: 1024) == 3)
    }

    /// Every vertex contributes exactly two segments — an approach (a `move`
    /// for the first vertex, a `line` thereafter) and the curve that rounds it
    /// — and the path ends with a `close`. There is no explicit line back to
    /// the start: `close` draws that edge, in CoreGraphics and in SwiftUI
    /// alike, so emitting one would be a segment that renders nothing.
    @Test("Rounding a polygon yields two segments per vertex, then a close")
    func roundedPolygonShape() {
        let square = [
            MarkPoint(x: 0, y: 0), MarkPoint(x: 1, y: 0),
            MarkPoint(x: 1, y: 1), MarkPoint(x: 0, y: 1),
        ]
        let segments = ElliotMark.roundedPolygon(square, radius: 0.1)
        #expect(segments.count == 2 * square.count + 1)
        #expect(segments.last == .close)
        // The approach segments alternate with the curves, so a vertex's curve
        // is always at an odd index — the structure the adapters walk.
        for index in 0..<square.count {
            if case .curve = segments[2 * index + 1] {} else {
                Issue.record("vertex \(index) should be rounded by a curve")
            }
        }
    }

    /// An unclamped radius turns the chevron tip inside out, because its two
    /// edges are the shortest in the shape.
    @Test("A radius larger than an edge is clamped, not honoured")
    func radiusIsClamped() {
        let square = [
            MarkPoint(x: 0, y: 0), MarkPoint(x: 1, y: 0),
            MarkPoint(x: 1, y: 1), MarkPoint(x: 0, y: 1),
        ]
        for point in points(ElliotMark.roundedPolygon(square, radius: 10)) {
            #expect(point.x >= -1e-9 && point.x <= 1 + 1e-9)
            #expect(point.y >= -1e-9 && point.y <= 1 + 1e-9)
        }
    }

    @Test("The iconset table is exactly what iconutil requires")
    func iconSetTable() {
        #expect(IconSet.entries.count == 10)
        #expect(Set(IconSet.entries.map(\.fileName)).count == 10)
        #expect(IconSet.entries.allSatisfy { $0.fileName.hasSuffix(".png") })
        #expect(IconSet.entries.map(\.pixels).max() == 1024)
        #expect(IconSet.entries.map(\.pixels).min() == 16)
    }
}
