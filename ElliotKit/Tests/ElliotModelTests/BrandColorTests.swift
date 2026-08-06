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

    /// The mechanical half of "colour is reserved for consequence" — the rule
    /// that, with "monospace means a machine established it", carries the whole
    /// visual system.
    ///
    /// Five is not a round number. It is the complete list of things this app
    /// is allowed to say in colour: a gesture starts an autonomous run
    /// (`armed`), a gesture cannot be taken back (`irreversible`), `gh`
    /// confirmed it (`verified`), it was refused or it failed (`refused`), it
    /// is alive and wants a decision (`attention`). Everything else on screen
    /// is greyscale, and that scarcity is the *only* reason any of the five is
    /// legible at a glance.
    ///
    /// So a sixth entry does not add a meaning — it takes a little from each of
    /// the five that already have one, and nothing on screen reports that. This
    /// test is where it gets reported.
    @Test("Exactly five colours are consequences, and they are those five")
    func consequencesAreTheFiveAccents() {
        #expect(
            BrandColor.consequences.count == 5,
            """
            `BrandColor.consequences` is the app's entire colour budget: armed, \
            irreversible, verified, refused, attention. Colour here means "a \
            consequence follows", and it reads only because nothing else on the \
            board is coloured at all. Adding a sixth accent does not extend the \
            vocabulary, it dilutes the five that carry it — and nothing on \
            screen would show that happening, which is why it has to fail here. \
            If a new meaning genuinely needs colour, retire one of the five in \
            the same change and say which.
            """
        )

        // Named pairwise rather than by `==` on the array, so a failure says
        // *which* slot drifted instead of "two arrays differ". `zip` truncates,
        // so this cannot trap on a short list — the count above is the guard.
        let named: [(name: String, colour: BrandColor)] = [
            ("armed", .armed),
            ("irreversible", .irreversible),
            ("verified", .verified),
            ("refused", .refused),
            ("attention", .attention),
        ]
        #expect(named.count == 5)

        for (listed, expected) in zip(BrandColor.consequences, named) {
            #expect(
                listed.light == expected.colour.light,
                "The consequence listed here should be `\(expected.name)`'s light value."
            )
            #expect(
                listed.dark == expected.colour.dark,
                "The consequence listed here should be `\(expected.name)`'s dark value."
            )
        }

        // A duplicate would keep the count at five while dropping an accent —
        // the failure mode the count alone cannot see.
        #expect(Set(BrandColor.consequences).count == 5)
    }

    /// `paper` is the mark's own paper, and the file says so: a fill, not a
    /// consequence. It is also the one colour deliberately identical in both
    /// appearances, so listing it as an accent would put a value that cannot
    /// respond to the appearance into the set that always must.
    @Test("Paper is a fill and is not one of the consequences")
    func paperIsNotAnAccent() {
        #expect(
            !BrandColor.consequences.contains(BrandColor.paper),
            """
            `paper` draws the cards in the app mark. Nothing follows from \
            seeing it, so it spends none of the budget `consequences` bounds.
            """
        )
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
