import ElliotEngine
import Foundation

/// What a Preflight row should draw for a finding's fixes.
///
/// A plain function over values rather than logic inside the view, for the
/// reason this codebase gives everywhere else: `swift test` can assert a
/// function and cannot assert a `body`. The view calls this and renders what it
/// gets; it decides nothing.
enum PreflightFixes {
    struct Button: Identifiable, Hashable {
        var id: String { fix.id }
        var title: String
        var fix: CheckFix
    }

    /// One button per fix, in the order the check offered them.
    ///
    /// The order is the check's on purpose. `labelsCheck` puts the deterministic
    /// fix first — the one that resolves the finding outright — ahead of the one
    /// that files work for later, so a reader scanning the row meets the cheap
    /// answer before the expensive one.
    static func buttons(for result: CheckResult) -> [Button] {
        result.fixes.map { Button(title: $0.label, fix: $0) }
    }
}
