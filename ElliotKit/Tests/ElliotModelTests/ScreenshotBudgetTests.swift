import Foundation
import Testing

@testable import ElliotModel

@Suite("Screenshot budget")
struct ScreenshotBudgetTests {
    @Test("An image already inside the budget is not touched")
    func alreadyFitsIsUnscaled() {
        // Exactly 1.0, not "about 1.0": a scale of 0.999 would resample a picture
        // that had nothing wrong with it, and resampling is the one step that can
        // turn readable text into a grey smear.
        #expect(ScreenshotBudget.scale(toFit: 1000, budget: 4000) == 1.0)
        #expect(ScreenshotBudget.scale(toFit: 4000, budget: 4000) == 1.0)
    }

    @Test("Bytes follow area, so the linear scale is the square root of the ratio")
    func scaleFollowsArea() {
        // Halving the byte count means halving the *pixels*, and pixels are a
        // product of two dimensions. Scaling each side by the ratio itself would
        // overshoot to a quarter — an image four times smaller than asked for,
        // which reads as a bad capture rather than a budget doing its job.
        let scale = ScreenshotBudget.scale(toFit: 8000, budget: 4000)
        #expect(abs(scale - 0.5.squareRoot()) < 0.0001)

        // The property that matters, stated as the property: applying the scale
        // lands on the budget.
        let projected = Double(8000) * scale * scale
        #expect(abs(projected - 4000) < 1)
    }

    @Test("A budget of nothing is a budget nobody set")
    func nonPositiveBudgetDoesNotScale() {
        // Guards a division by zero, but the reason to answer 1.0 rather than
        // refuse is that a caller passing 0 means "you decide" — the same reading
        // `ElliotPaging.clamp` already gives a non-positive limit.
        #expect(ScreenshotBudget.scale(toFit: 9000, budget: 0) == 1.0)
        #expect(ScreenshotBudget.scale(toFit: 9000, budget: -1) == 1.0)
    }

    @Test("Nothing to shrink is not something to shrink")
    func nonPositiveByteCountDoesNotScale() {
        #expect(ScreenshotBudget.scale(toFit: 0, budget: 4000) == 1.0)
        #expect(ScreenshotBudget.scale(toFit: -10, budget: 4000) == 1.0)
    }

    @Test("However far over budget, the scale never reaches zero")
    func neverCollapsesToNothing() {
        // A 0.0 scale gives a 0×0 bitmap, which encodes fine and arrives as a
        // valid, empty picture — the failure this whole issue is about, produced
        // by the guard meant to prevent it.
        for byteCount in [10_000_000, 1_000_000_000, Int.max / 2] {
            let scale = ScreenshotBudget.scale(toFit: byteCount, budget: 1024)
            #expect(scale > 0, "\(byteCount) collapsed to \(scale)")
            #expect(scale >= ScreenshotBudget.minimumScale)
            #expect(scale <= 1.0)
        }
    }

    @Test("The budget is spent in base64, which is a third bigger than the bytes")
    func base64SizeIsTheEncodedSize() {
        // The trap this closes: a PNG measured on disk and compared against a
        // budget expressed in base64 ships ~33 % over it, every time, with
        // nothing anywhere reporting an overrun.
        #expect(ScreenshotBudget.base64Size(ofRawBytes: 0) == 0)
        #expect(ScreenshotBudget.base64Size(ofRawBytes: 1) == 4)
        #expect(ScreenshotBudget.base64Size(ofRawBytes: 3) == 4)
        #expect(ScreenshotBudget.base64Size(ofRawBytes: 4) == 8)
        #expect(ScreenshotBudget.base64Size(ofRawBytes: 3000) == 4000)
    }

    @Test("The encoded size matches what Foundation actually produces")
    func base64SizeAgreesWithFoundation() {
        // Asserted against the real encoder rather than against the formula a
        // second time: an arithmetic identity tested by restating it proves only
        // that it was typed twice.
        for count in [0, 1, 2, 3, 4, 5, 100, 1023, 4096] {
            let data = Data(repeating: 0xAB, count: count)
            #expect(
                ScreenshotBudget.base64Size(ofRawBytes: count)
                    == data.base64EncodedString().utf8.count,
                "disagreed at \(count) bytes"
            )
        }
    }

    @Test("The default budget is a real number of bytes, not a placeholder")
    func defaultBudgetIsSane() {
        #expect(ScreenshotBudget.defaultInlineBytes == 768 * 1024)
    }
}
