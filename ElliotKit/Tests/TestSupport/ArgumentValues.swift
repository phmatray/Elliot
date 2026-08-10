import Foundation

/// The argv element following each occurrence of `flag`, in argv order — one
/// entry per occurrence, always.
///
/// **Total by construction, and that is the entire reason it exists.** The
/// obvious `arguments[index + 1]` traps when the flag is the last element, and a
/// trap is not a test failure: it kills the whole test binary before
/// swift-testing prints its `Test run with N tests` summary, so CI is left with
/// an exit code and no named test at all — the loudest possible defect reported
/// as the quietest possible signal.
///
/// ⛔ **A trailing flag yields `missingValueMarker(for:)`, never nothing.**
/// Dropping it would be the wrong repair: the trap would become a *silent
/// substitution*, which is the same family one rung quieter — argv ending
/// `--add-dir <dir> --add-dir` would compare equal to argv carrying one
/// `--add-dir`, and the assertion would pass over a spawn that really did
/// carry a value-less flag. Emitting a marker keeps the count honest, so a
/// comparison against the expected list pins **how many times the flag
/// appeared** as well as its values, and a missing value fails by name.
///
/// - Note: only whole elements match. `--flag=value` is a shape nothing in this
///   package emits — `ClaudeInvocation` writes the flag and its value as two
///   separate argv elements, because a path under `ELLIOT_HOME` carries spaces —
///   so it is deliberately not handled rather than half-handled.
public func argumentValues(after flag: String, in arguments: [String]) -> [String] {
    arguments.enumerated().compactMap { index, element in
        guard element == flag else { return nil }
        guard index + 1 < arguments.count else { return missingValueMarker(for: flag) }
        return arguments[index + 1]
    }
}

/// What `argumentValues(after:in:)` returns for a flag with nothing after it.
///
/// A sentinel rather than an omission, and one no real argv can collide with —
/// it is a sentence, and the values these assertions compare are paths and
/// enumeration tokens.
public func missingValueMarker(for flag: String) -> String {
    "<no value followed \(flag)>"
}
