import CoreGraphics
import ElliotModel
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum IconError: Error, CustomStringConvertible {
    case contextFailed(Int)
    case encodeFailed(URL)
    case decodeFailed(URL)
    case mismatch(URL)

    var description: String {
        switch self {
        case .contextFailed(let pixels): "Could not create a \(pixels)×\(pixels) bitmap context"
        case .encodeFailed(let url): "Could not write \(url.path)"
        case .decodeFailed(let url): "Could not read \(url.path) as an image"
        case .mismatch(let url): "\(url.path) is out of date — re-render it with `elliot-icon png`"
        }
    }
}

enum IconRenderer {
    private static var sRGB: CGColorSpace { CGColorSpace(name: CGColorSpace.sRGB)! }

    private static func colour(_ value: UInt32, alpha: Double = 1) -> CGColor {
        CGColor(
            srgbRed: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255,
            alpha: alpha
        )
    }

    /// The mark on its plate, at `pixels` square.
    ///
    /// macOS icons carry their own shape and margin — nothing masks them — so
    /// the plate is the canvas inset by 10 % with the icon grid's continuous
    /// corner proportion, and the canvas outside it stays transparent.
    static func image(pixels: Int) throws -> CGImage {
        let side = Double(pixels)
        guard
            let context = CGContext(
                data: nil, width: pixels, height: pixels, bitsPerComponent: 8,
                bytesPerRow: 0, space: sRGB,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        else { throw IconError.contextFailed(pixels) }

        let inset = side * 0.10
        let plate = CGRect(x: inset, y: inset, width: side - 2 * inset, height: side - 2 * inset)

        context.saveGState()
        context.addPath(
            CGPath(
                roundedRect: plate,
                cornerWidth: plate.width * 0.2237,
                cornerHeight: plate.width * 0.2237,
                transform: nil
            )
        )
        context.clip()
        // Not a decorative sweep: armed → irreversible is the board's own
        // consequence axis, laid along the direction the cards travel.
        let gradient = CGGradient(
            colorsSpace: sRGB,
            colors: [colour(BrandColor.armed.light), colour(BrandColor.irreversible.light)] as CFArray,
            locations: [0, 1]
        )!
        context.drawLinearGradient(
            gradient,
            start: CGPoint(x: plate.minX, y: plate.maxY),
            end: CGPoint(x: plate.maxX, y: plate.minY),
            options: []
        )
        context.restoreGState()

        let count = ElliotMark.cardCount(forPixelSize: pixels)
        let opacities: [Double] = count == 1 ? [1] : [0.45, 0.72, 1]
        for index in 0..<count {
            context.saveGState()
            context.addPath(path(ElliotMark.card(index, of: count), in: plate))
            context.setFillColor(colour(BrandColor.paper.light, alpha: opacities[index]))
            context.fillPath()
            context.restoreGState()
        }

        guard let image = context.makeImage() else { throw IconError.contextFailed(pixels) }
        return image
    }

    /// Unit space has `y` growing downward; CoreGraphics has it growing up.
    private static func path(_ segments: [MarkSegment], in rect: CGRect) -> CGPath {
        let path = CGMutablePath()
        func point(_ mark: MarkPoint) -> CGPoint {
            CGPoint(x: rect.minX + mark.x * rect.width, y: rect.maxY - mark.y * rect.height)
        }
        for segment in segments {
            switch segment {
            case .move(let p): path.move(to: point(p))
            case .line(let p): path.addLine(to: point(p))
            case .curve(let to, let control): path.addQuadCurve(to: point(to), control: point(control))
            case .close: path.closeSubpath()
            }
        }
        return path
    }

    static func write(_ image: CGImage, to url: URL) throws {
        guard
            let destination = CGImageDestinationCreateWithURL(
                url as CFURL, UTType.png.identifier as CFString, 1, nil
            )
        else { throw IconError.encodeFailed(url) }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw IconError.encodeFailed(url) }
    }

    static func writeIconSet(to directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // Two entries share a pixel size at 32, 256 and 512; render each size
        // once and write it under both names.
        var rendered: [Int: CGImage] = [:]
        for entry in IconSet.entries {
            let image = try rendered[entry.pixels] ?? image(pixels: entry.pixels)
            rendered[entry.pixels] = image
            try write(image, to: directory.appending(path: entry.fileName))
        }
    }

    /// Raw RGBA bytes, so two images are compared by what they look like rather
    /// than by how ImageIO happened to encode them. PNG encoding is not
    /// guaranteed stable across macOS versions, and a guard that cries wolf
    /// after an OS update is worse than no guard.
    static func pixels(of image: CGImage) throws -> [UInt8] {
        let width = image.width, height = image.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        try bytes.withUnsafeMutableBytes { buffer in
            guard
                let context = CGContext(
                    data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                    bytesPerRow: width * 4, space: sRGB,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                )
            else { throw IconError.contextFailed(width) }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        return bytes
    }

    static func check(_ url: URL, pixels wanted: Int) throws {
        guard
            let source = CGImageSourceCreateWithURL(url as CFURL, nil),
            let existing = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { throw IconError.decodeFailed(url) }
        guard existing.width == wanted else { throw IconError.mismatch(url) }
        guard try pixels(of: existing) == pixels(of: image(pixels: wanted)) else {
            throw IconError.mismatch(url)
        }
    }
}
