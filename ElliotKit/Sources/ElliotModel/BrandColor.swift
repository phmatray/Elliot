/// The brand's raw colour values, and the one place they are written.
///
/// `Palette` in `ElliotApp` turns these into SwiftUI colours and carries the
/// comments explaining what each one *means*; the icon renderer reads the same
/// numbers to draw the plate. Neither holds a copy, so changing a hex here
/// changes the board and the Dock icon together — which is the only way those
/// two can be relied on to agree.
public struct BrandColor: Sendable, Hashable, Codable {
    /// 24-bit sRGB, `0xRRGGBB`.
    public let light: UInt32
    public let dark: UInt32

    public init(light: UInt32, dark: UInt32) {
        self.light = light
        self.dark = dark
    }
}

extension BrandColor {
    /// A gesture here starts an autonomous run.
    public static let armed = BrandColor(light: 0x5B_3DF5, dark: 0xA9_96FF)
    /// The one move that cannot be taken back: merging the pull request.
    public static let irreversible = BrandColor(light: 0xC0_246A, dark: 0xFF_7BB0)
    /// `gh` confirmed it.
    public static let verified = BrandColor(light: 0x0B_7A5E, dark: 0x4B_D6A8)
    /// A move was refused, or a run failed.
    public static let refused = BrandColor(light: 0xA9_3226, dark: 0xFF_8A75)
    /// Still alive, but wants a decision.
    public static let attention = BrandColor(light: 0x8A_5A00, dark: 0xF0_B429)
    /// The cards in the mark. The same in both appearances: a macOS 15 app
    /// icon does not follow the system appearance, so a dark variant would be
    /// unreachable.
    public static let paper = BrandColor(light: 0xFA_F9FC, dark: 0xFA_F9FC)
}
