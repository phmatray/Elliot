import Foundation

/// The five axes' actual rules. Stubbed here — task 9 replaces `evaluate`'s
/// body with the real predicates; every axis reports violating in the
/// meantime, which is what makes `StandardsEngineOrderTests`'s
/// `expiredExemptionDoesNotSilence` meaningful: an expired exemption must fall
/// through to whatever the measurement says, and a stub answering `.compliant`
/// would pass that test for the wrong reason.
public enum StandardPredicates {

    public static func evaluate(
        _ standard: Standard,
        repo: GHRepoSummary,
        measurement: RepoMeasurement,
        now: Date,
        freshness: FreshnessPolicy
    ) -> StandardVerdict {
        .violating(Violation(summary: "not yet implemented", expected: "", actual: "", fixHint: nil))
    }
}
