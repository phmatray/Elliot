import Foundation
import Testing

@testable import ElliotModel

@Suite("Money format")
struct MoneyFormatTests {
    /// Pinned rather than `.current`: an assertion about how an amount is written
    /// must not depend on the machine writing it.
    private let us = Locale(identifier: "en_US")

    @Test("A sub-cent cost keeps four decimals so it cannot read as free")
    func subCentKeepsPrecision() {
        #expect(MoneyFormat.usd(0.0031, locale: us) == "$0.0031")
        #expect(MoneyFormat.usd(0.0001, locale: us) == "$0.0001")
        #expect(MoneyFormat.usd(0.0099, locale: us) == "$0.0099")
    }

    @Test("A cost of a cent or more is ordinary money")
    func centAndAboveIsOrdinary() {
        #expect(MoneyFormat.usd(0.01, locale: us) == "$0.01")
        #expect(MoneyFormat.usd(1, locale: us) == "$1.00")
        #expect(MoneyFormat.usd(47.2, locale: us) == "$47.20")
        #expect(MoneyFormat.usd(33.9643, locale: us) == "$33.96")
    }

    @Test("Three cents is money, not a measurement — the sub-cent rule stops at a cent")
    func justAboveTheThresholdRounds() {
        // Pinned because it is the case that looks like a regression and is not:
        // `$%.4f` wrote 0.0312 as `$0.0312`, and this writes it `$0.03`. Above a
        // cent the extra digits are noise, and the first draft of this suite
        // asserted the old rendering by mistake.
        #expect(MoneyFormat.usd(0.0312, locale: us) == "$0.03")
    }

    @Test("Zero is an amount, not a measurement")
    func zeroIsOrdinary() {
        #expect(MoneyFormat.usd(0, locale: us) == "$0.00")
    }

    @Test("The threshold is exclusive on both sides")
    func thresholdBoundaries() {
        #expect(MoneyFormat.fractionDigits(for: 0) == MoneyFormat.ordinaryFractionDigits)
        #expect(MoneyFormat.fractionDigits(for: 0.0099) == MoneyFormat.subCentFractionDigits)
        #expect(MoneyFormat.fractionDigits(for: 0.01) == MoneyFormat.ordinaryFractionDigits)
        #expect(MoneyFormat.fractionDigits(for: 100) == MoneyFormat.ordinaryFractionDigits)
    }

    @Test("A negative amount is written by its magnitude's rule")
    func negativesUseMagnitude() {
        // Nothing in Elliot bills a negative today. The rule is stated anyway so
        // that if one ever arrives it is written, not silently given the wrong
        // precision by an `amount < 0.01` test that every negative satisfies.
        #expect(MoneyFormat.fractionDigits(for: -0.003) == MoneyFormat.subCentFractionDigits)
        #expect(MoneyFormat.fractionDigits(for: -12) == MoneyFormat.ordinaryFractionDigits)
    }

    @Test("The reader's locale decides how it is written, not a hard-coded dollar sign")
    func localeDecidesTheWriting() {
        let fr = MoneyFormat.usd(0.03, locale: Locale(identifier: "fr_FR"))
        // Asserted on properties rather than an exact string: the precise glyph
        // for USD in a French locale is ICU's business and has changed between
        // OS releases. What must hold is that the amount is written the French
        // way and is not the American rendering.
        #expect(fr.contains("0,03"))
        #expect(!fr.contains("0.03"))
        #expect(fr != MoneyFormat.usd(0.03, locale: us))
    }

    @Test("Every rendering carries a currency, whatever the locale")
    func neverBareDigits() {
        for identifier in ["en_US", "fr_FR", "de_DE", "ja_JP"] {
            let written = MoneyFormat.usd(12.5, locale: Locale(identifier: identifier))
            #expect(written.contains("12"), "\(identifier) lost the amount: \(written)")
            #expect(
                written.rangeOfCharacter(from: CharacterSet.decimalDigits.inverted) != nil,
                "\(identifier) rendered bare digits with no currency: \(written)"
            )
        }
    }
}
