import AppKit
import SwiftUI
import Testing

@testable import ElliotAppKit

/// What a test can hold of the visual vocabulary.
///
/// `swift test` cannot see where anything sits on screen — that gap cost this
/// project #47, #50, #52 and #53 — so nothing here asserts a position. What it
/// asserts is the part of `DesignSystem.swift` that is arithmetic and not
/// appearance: the ladders are ordered, the demoted variants really are
/// demoted, the faces are distinct from the faces they are meant to contrast
/// with, and the one token whose whole justification is a *relationship* to a
/// system colour actually holds that relationship.
@Suite("Design system")
struct DesignSystemTests {

    // MARK: - The radius ladder

    /// A rounded thing inside another rounded thing reads wrong at the same
    /// radius, so the four values are a ladder, not four independent numbers.
    /// Asserted as a chain rather than four literals: the point is the order,
    /// and any of them may be retuned as long as the order survives.
    @Test("The radius ladder holds: nested < card < panel < column")
    func radiusLadderIsOrdered() {
        #expect(
            Metric.nestedRadius < Metric.cardRadius,
            "A nested chip drawn at the card's own radius reads as a second card."
        )
        #expect(Metric.cardRadius < Metric.panelRadius)
        #expect(
            Metric.panelRadius < Metric.columnRadius,
            "The panel sits between columns; at the column radius it becomes a sixth one."
        )

        // And the chain end to end, so a future value inserted in the middle
        // cannot satisfy its neighbours while breaking the span.
        #expect(Metric.nestedRadius < Metric.columnRadius)
    }

    // MARK: - The panel's elevation

    /// The panel gets the app's first and only shadow — it is the one thing
    /// distinguishing "panel" from "a sixth column". These assertions are the
    /// shape of a shadow rather than a taste in one: a zero radius is not a
    /// shadow, an opacity outside 0…1 is not a colour, and a shadow that
    /// travels upward reads as the panel being lit from below.
    @Test("The panel's elevation is a shadow and not a border")
    func panelElevationIsAShadow() {
        #expect(Metric.panelElevation.radius > 0)
        #expect(Metric.panelElevation.y > 0)
        #expect(Metric.panelElevation.opacity > 0)
        #expect(
            Metric.panelElevation.opacity < 1,
            "A fully opaque shadow is a black rectangle behind the panel, not depth."
        )
        // Softer than it is displaced, which is what separates a cast shadow
        // from a hard offset duplicate of the panel.
        #expect(Metric.panelElevation.radius >= Metric.panelElevation.y)
    }

    // MARK: - The washes

    /// `washFaint` replaced a hand-written `wash(tint).opacity(0.6)` at one call
    /// site so the strength stops being decided per call site. The assertion
    /// that matters is the ordering — faint really is fainter than wash, and
    /// both stay below the border strength — not the three literals.
    @Test("The wash ladder holds: faint < wash < border, for any tint")
    func washLadderIsOrdered() {
        for tint in [Color.red, .green, Palette.armed, Palette.irreversible] {
            let faint = alpha(of: Surface.washFaint(tint))
            let wash = alpha(of: Surface.wash(tint))
            let border = alpha(of: Surface.washBorder(tint))

            #expect(faint < wash)
            #expect(wash < border)
            #expect(faint > 0)
        }
    }

    /// The one number worth pinning, because it is the one that changed: the
    /// old call site produced 0.12 × 0.6 = 0.072, and below roughly 0.08 a
    /// tinted wash stops being distinguishable from the untinted `recess`
    /// behind it. If someone lowers this, it should be on purpose.
    @Test("The faint wash stays above the recess it is drawn on")
    func faintWashOutrunsTheRecess() {
        #expect(alpha(of: Surface.washFaint(.red)) > alpha(of: Surface.recess))
        #expect(alpha(of: Surface.washFaint(.red)) > alpha(of: Surface.recessFaint))
    }

    // MARK: - The faces

    /// `hearsay` is the type-level form of "`gh` is the fact, the agent's prose
    /// is a hint". If it ever resolves to the same face as `fact`, the panel
    /// renders a claim and a receipt identically — the exact conflation the
    /// verdict block exists to prevent — and it would do so silently.
    @Test("Hearsay is neither the fact face nor plain prose")
    func hearsayIsItsOwnFace() {
        #expect(
            Type.hearsay != Type.fact,
            "A claim set in the machine face asserts a machine established it."
        )
        #expect(
            Type.hearsay != Type.bodyProse,
            "Hearsay is bodyProse italicised; equal here means the italic was lost."
        )
        #expect(Type.hearsay == Font.system(size: 12).italic())
    }

    /// The label tier exists so a caption inside a panel can announce its row
    /// rather than compete with it. Equal to `label` means the tier collapsed.
    @Test("The small label is a tier below the console label")
    func labelSmallIsATierOfItsOwn() {
        #expect(Type.labelSmall != Type.label)
        #expect(Type.labelSmall == Font.system(size: 10, weight: .semibold).width(.standard))
    }

    // MARK: - The well

    /// The whole justification for `Surface.well` existing rather than reusing
    /// `NSColor.textBackgroundColor` is a *relationship*: a well must read as
    /// set into the panel, which in a dark appearance means darker than the
    /// window behind it. So the relationship is what is asserted, and the
    /// system colour that fails it is asserted alongside — otherwise the day
    /// AppKit changes its mind, this token looks like an unexplained
    /// duplication of a system value.
    @MainActor
    @Test("The well is darker than the window in dark appearance, where the system colour is not")
    func wellIsSetIntoTheDarkWindow() throws {
        let dark = try #require(NSAppearance(named: .darkAqua))

        let well = try #require(luminance(of: NSColor(Surface.well), in: dark))
        let window = try #require(luminance(of: .windowBackgroundColor, in: dark))
        let systemText = try #require(luminance(of: .textBackgroundColor, in: dark))

        #expect(
            well < window,
            "A well no darker than the window is not a well — it is invisible."
        )
        #expect(
            !(systemText < window),
            """
            `.textBackgroundColor` has become darker than the window in dark \
            appearance. That was the entire reason `Surface.well` is hard-coded \
            rather than reusing it; if it now holds, the token can go.
            """
        )
    }

    /// In light appearance the relationship inverts — paper is lighter than the
    /// window's chrome — so the well must not simply be "dark".
    @MainActor
    @Test("The well is not darker than the window in light appearance")
    func wellDoesNotInvertInLightAppearance() throws {
        let light = try #require(NSAppearance(named: .aqua))

        let well = try #require(luminance(of: NSColor(Surface.well), in: light))
        let window = try #require(luminance(of: .windowBackgroundColor, in: light))

        #expect(well <= window)
        #expect(well > 0.5, "The light well is paper, not ink.")
    }

    // MARK: - Helpers

    /// The alpha a `Color` actually resolves to. Opacity is the only property
    /// of these fills a test can read back: the hue is a system colour whose
    /// resolution depends on the appearance, the strength is the decision.
    private func alpha(of color: Color) -> CGFloat {
        NSColor(color).alphaComponent
    }

    /// Perceived brightness of an `NSColor` resolved against one appearance, or
    /// `nil` if it will not convert to sRGB. Dynamic colours resolve against
    /// the *current drawing* appearance, so it has to be made current first —
    /// reading one outside such a block gives whatever the process last drew
    /// in, which in a test process is arbitrary.
    @MainActor
    private func luminance(of color: NSColor, in appearance: NSAppearance) -> CGFloat? {
        var result: CGFloat?
        appearance.performAsCurrentDrawingAppearance {
            guard let srgb = color.usingColorSpace(.sRGB) else { return }
            result = 0.2126 * srgb.redComponent
                + 0.7152 * srgb.greenComponent
                + 0.0722 * srgb.blueComponent
        }
        return result
    }
}
