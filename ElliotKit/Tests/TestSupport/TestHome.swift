import Foundation

/// One `ELLIOT_HOME` for the whole test process, set once and never removed.
///
/// `StoreLocation` reads the variable on every access and it is process-global,
/// so a per-test home that gets deleted at the end of one test pulls the ground
/// out from under any suite still writing run logs. Both end-to-end suites are
/// nested under one `.serialized` parent for the same reason.
///
/// **The only thing in the test process permitted to touch `ELLIOT_HOME`.**
/// Swift Testing runs independent suites in parallel, so two lazy statics each
/// racing to `setenv` their own idea of the home is exactly the hazard this
/// type exists to remove: whichever wins, a suite already under way sees its
/// path prefix change from underneath it. The next suite that needs a home
/// reaches for `TestHome.scratch(_:)` rather than rolling its own `setenv`.
///
/// It lives in `TestSupport`, and not in the suite that first needed it,
/// because SwiftPM links every test target into **one** bundle and therefore
/// one process. While it was private to `ElliotEngineTests` its "only setter"
/// guarantee covered only that target, and a suite in another one —
/// `RunLogResourceTests`, which writes a file and then reads it back — could
/// resolve its path before this `setenv` and resolve it again afterwards. The
/// two answers differed and the file was reported missing. Any test that
/// resolves a `StoreLocation` path must touch `root` first, which is
/// idempotent, so that the home is already final when the path is computed.
///
/// This also fixes something that was already true: without it, the existing
/// end-to-end suite writes its run logs into the real
/// `~/Library/Application Support/Elliot/runs`.
public enum TestHome {
    /// Swift runs a `static let`'s initialiser at most once, even if two
    /// suites reach for `root` at the same instant, which is what lets this
    /// safely `setenv` before either test body can observe `ELLIOT_HOME`.
    public static let root: URL = {
        // An operator's own `ELLIOT_HOME`, already exported before `swift
        // test` ran, is adopted rather than clobbered — `StoreLocation`
        // documents that override as absolute, and honouring it here is what
        // keeps this the *only* setter: a second lazy static elsewhere that
        // still finds it unset would otherwise race this one. The trade is
        // that a pre-set value without a space in it leaves the space-parsing
        // assertions below exercising less than they would under our own
        // default — an operator's explicit choice, not a silent gap.
        if let existing = ProcessInfo.processInfo.environment["ELLIOT_HOME"], !existing.isEmpty {
            let url = URL(fileURLWithPath: existing, isDirectory: true)
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            return url
        }

        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("elliot-tests-\(ProcessInfo.processInfo.processIdentifier)",
                                    isDirectory: true)
            // Two spaces, deliberately, and not for decoration: this is the
            // shape of Elliot's real default home
            // (`~/Library/Application Support/Elliot`), and it is exactly what
            // a `sed` that stops at the first whitespace character truncates.
            // A home without a space in it would let that bug pass this suite
            // and ship anyway — see commit 06993ad and Scripts/fake-claude.sh.
            .appendingPathComponent("Application  Support", isDirectory: true)
            .appendingPathComponent("Elliot", isDirectory: true)
        setenv("ELLIOT_HOME", url.path, 1)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    /// A directory of one test's own, inside the shared home. Safe to delete:
    /// nothing else writes here.
    public static func scratch(_ label: String) -> URL {
        _ = root
        return root.appendingPathComponent("\(label)-\(UUID().uuidString)", isDirectory: true)
    }
}
