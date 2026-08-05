import Testing

@testable import ElliotModel

@Suite("Brand colours")
struct BrandColorTests {
    /// Pinned deliberately. These are the numbers the board has always used;
    /// the icon is built from two of them, so a silent edit here would change
    /// the Dock icon and the board together, which is the point — but it must
    /// never happen by accident.
    @Test("The six brand colours keep the values the board shipped with")
    func valuesArePinned() {
        #expect(BrandColor.armed.light == 0x5B_3DF5)
        #expect(BrandColor.armed.dark == 0xA9_96FF)
        #expect(BrandColor.irreversible.light == 0xC0_246A)
        #expect(BrandColor.irreversible.dark == 0xFF_7BB0)
        #expect(BrandColor.verified.light == 0x0B_7A5E)
        #expect(BrandColor.verified.dark == 0x4B_D6A8)
        #expect(BrandColor.refused.light == 0xA9_3226)
        #expect(BrandColor.refused.dark == 0xFF_8A75)
        #expect(BrandColor.attention.light == 0x8A_5A00)
        #expect(BrandColor.attention.dark == 0xF0_B429)
    }

    /// The icon does not follow the system appearance on macOS 15, so a
    /// separate dark paper would be a code path nothing can reach.
    @Test("Paper is the same in both appearances")
    func paperDoesNotAdapt() {
        #expect(BrandColor.paper.light == BrandColor.paper.dark)
    }

    @Test("Every channel fits in 24 bits")
    func valuesAreRGB() {
        let all = [
            BrandColor.armed, BrandColor.irreversible, BrandColor.verified,
            BrandColor.refused, BrandColor.attention, BrandColor.paper,
        ]
        for colour in all {
            #expect(colour.light <= 0xFF_FFFF)
            #expect(colour.dark <= 0xFF_FFFF)
        }
    }
}
