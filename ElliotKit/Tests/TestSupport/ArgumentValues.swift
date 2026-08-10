import Foundation

/// The argv element following each occurrence of `flag`, in argv order.
///
/// **Total by construction, and that is the entire reason it exists.** The
/// obvious `arguments[index + 1]` traps when the flag is the last element, and a
/// trap is not a test failure: it kills the whole test binary before
/// swift-testing prints its `Test run with N tests` summary, so CI is left with
/// an exit code and no named test at all — the loudest possible defect reported
/// as the quietest possible signal. Here a trailing flag simply yields no value,
/// and the `#expect` comparing the result fails naming its own test.
///
/// Returning *every* occurrence rather than the first lets one comparison assert
/// which values were passed **and** how many times the flag appeared, which is
/// what the `--add-dir` assertions want: the pair, in order, and no third.
///
/// - Note: only whole elements match. `--flag=value` is a shape nothing in this
///   package emits — `ClaudeInvocation` writes the flag and its value as two
///   separate argv elements, because a path under `ELLIOT_HOME` carries spaces —
///   so it is deliberately not handled rather than half-handled.
public func argumentValues(after flag: String, in arguments: [String]) -> [String] {
    arguments.enumerated().compactMap { index, element in
        guard element == flag, index + 1 < arguments.count else { return nil }
        return arguments[index + 1]
    }
}
