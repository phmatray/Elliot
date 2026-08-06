import Foundation

/// How an amount of money is written, decided once.
///
/// Both cost displays used `String(format: "$%.4f", cost)`. Four decimals is the
/// right precision for one run that cost a third of a cent and the wrong one for
/// anything a portfolio adds up to: it was the only format the product had, so
/// Elliot could write `$0.0031` and had no way to write `$47.20`. The `$` was
/// hard-coded too, in an app whose user is in Europe.
///
/// Here rather than in a view because `ElliotApp` has no test target — a rule
/// written in a SwiftUI body is a rule `swift test` cannot reach.
public enum MoneyFormat {
    /// Below a cent, two decimals would round a real cost to `$0.00` and make a
    /// run that spent something read as free.
    static let subCentFractionDigits = 4
    static let ordinaryFractionDigits = 2

    /// The threshold is exclusive: an amount *at* one cent is ordinary money and
    /// wants two decimals.
    static let subCentThreshold = 0.01

    /// Writes a US dollar amount for `locale`.
    ///
    /// The currency is always USD — that is what the Claude Code API bills and
    /// what `total_cost_usd` carries — but the way it is *written* belongs to the
    /// reader: `$0.03` in `en_US` and `0,03 $US` in `fr_FR` are the same amount.
    ///
    /// `locale` is a parameter rather than read from the environment so tests are
    /// deterministic on any machine.
    public static func usd(_ amount: Double, locale: Locale = .current) -> String {
        amount.formatted(
            .currency(code: "USD")
                .locale(locale)
                .precision(.fractionLength(fractionDigits(for: amount)))
        )
    }

    /// Zero is deliberately ordinary. The sub-cent rule exists so a small cost is
    /// not rounded away into looking free; nothing is being rounded away when the
    /// cost really is nothing, and `$0.0000` reads as a measurement where `$0.00`
    /// reads as an amount.
    static func fractionDigits(for amount: Double) -> Int {
        guard amount != 0, abs(amount) < subCentThreshold else { return ordinaryFractionDigits }
        return subCentFractionDigits
    }
}
