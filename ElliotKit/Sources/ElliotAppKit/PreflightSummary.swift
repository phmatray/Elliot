import ElliotEngine
import SwiftUI

/// The verdict strip at the top of Preflight: its mark, its tint and its two
/// sentences, decided once from what was actually read.
///
/// A value rather than four expressions in the view, for the reason
/// `RepositoriesView.countSentence` is a `nonisolated static`: what a screen
/// *says* is assertable and where it sits is not. The strip had a symbol chosen
/// by one ternary and a headline chosen by a second, which is two places to
/// remember that a green seal is a claim.
///
/// ⛔ **The rule it carries is `countSentence`'s, one screen over: a repository
/// nobody read is not a repository that passed.** With any repository unswept,
/// *"Everything Elliot needs is here"* is a claim about a whole nobody measured
/// — the same false green as `RepoIssue.notChecked` being folded into "nothing
/// needs attention", which that page went to some trouble to stop doing.
struct PreflightSummary: Hashable {
    var failing: Int
    var warning: Int
    /// Repositories with no reading at all — never a count of checks, because
    /// the checks of an unread repository do not exist to be counted.
    var unread: Int
    var checks: Int
    var repositories: Int

    /// Built from one reading per repository, in `model.repos` order, with `nil`
    /// for the ones nobody has swept.
    ///
    /// Taking `[PreflightReading?]` rather than the model's dictionary keeps the
    /// arithmetic honest about its own input: a dictionary lookup that missed
    /// would silently shrink the denominator, which is the shape of every bug
    /// this type is about.
    static func of(machine: [CheckResult], repositories: [PreflightReading?]) -> PreflightSummary {
        let all = machine + repositories.compactMap { $0 }.flatMap(\.results)
        return PreflightSummary(
            failing: all.count { $0.status == .fail },
            warning: all.count { $0.status == .warn },
            // Through `PreflightReading.verdict(of:)` rather than by counting
            // the nils: "nobody looked" is that type's word, and this screen
            // asking the question its own way is how the two come to disagree
            // about a repository whose reading arrives empty.
            unread: repositories.count { PreflightReading.verdict(of: $0) == .notChecked },
            checks: all.count,
            repositories: repositories.count
        )
    }

    /// The one line a reader takes the whole screen's verdict from.
    ///
    /// Failures first — they are what stops a run — then warnings, then the
    /// repositories nobody has read. The all-clear is reachable only when all
    /// three are zero.
    var headline: String {
        if failing > 0 {
            return "\(failing) check\(failing == 1 ? "" : "s") failing — runs will not work"
        }
        if warning > 0 { return "\(warning) warning\(warning == 1 ? "" : "s")" }
        if unread > 0 {
            return "\(unread) repositor\(unread == 1 ? "y" : "ies") not checked yet"
        }
        return "Everything Elliot needs is here"
    }

    /// What was counted, and what was not.
    ///
    /// It names the denominator rather than hiding it: "3 of 5 repositories" is
    /// the same discipline as `countSentence` refusing to total a portfolio with
    /// an owner it could not list.
    var countLine: String {
        let noun = "repositor\(repositories == 1 ? "y" : "ies")"
        guard unread > 0 else {
            return "\(checks) checks across this machine and \(repositories) \(noun)."
        }
        return "\(checks) checks across this machine and \(repositories - unread) of "
            + "\(repositories) \(noun) — \(unread) not read yet."
    }

    /// The mark beside the headline, and its tint.
    ///
    /// The pair is derived from the same three counts as the headline, in one
    /// place, so a screen cannot show a green seal over a sentence saying
    /// something is unread. `questionmark.circle.dashed` and `Palette.attention`
    /// are `RepositoriesView`'s own vocabulary for `.notChecked` — the two
    /// screens already agreed on three symbols, and this is the fourth.
    var symbol: String {
        if failing > 0 { return "xmark.seal.fill" }
        if warning > 0 { return "exclamationmark.triangle.fill" }
        if unread > 0 { return "questionmark.circle.dashed" }
        return "checkmark.seal.fill"
    }

    var tint: Color {
        if failing > 0 { return Palette.refused }
        if warning > 0 || unread > 0 { return Palette.attention }
        return Palette.verified
    }

    /// What a repository section says instead of a check list when nothing has
    /// been read about it.
    ///
    /// ⚠️ Two sentences and not one: a sweep that is *running* and a sweep that
    /// has not been asked for are different facts, and the second one is the
    /// only one a reader can act on. Collapsing them would put "not checked yet"
    /// under a repository whose checks are being read at that moment, which
    /// reads as a refusal rather than as progress.
    static func unreadLine(isChecking: Bool) -> String {
        isChecking
            ? "Checking…"
            : "Not checked yet — nothing here is a pass or a failure."
    }
}
