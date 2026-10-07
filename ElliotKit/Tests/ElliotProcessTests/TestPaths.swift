import Foundation

/// The repository root, from this file's own location, so the tests use the
/// same `Scripts/` and `Fixtures/` a human would from a terminal.
///
/// ⚠️ **This lived in `ClaudeRunnerTests.swift` until Stage 1 of #379 deleted that file**, where it
/// was the only `internal` declaration in a suite file and so was visible to the whole target.
/// Two suites had come to depend on it — `GHMergeStatusTests` and `GHPayloadDecodingTests`, neither
/// of which has anything to do with the CLI runner — so deleting the runner's tests broke the
/// **build** of tests that were never about the runner. A shared helper homed inside one suite's
/// file is a dependency nobody can see from either end; it gets its own file here so the next
/// deletion of a suite is a deletion of that suite.
///
/// `ElliotEngineTests` solves the same problem the other way, with a `private enum TestPaths` per
/// file. That is deliberate there and not copied here: those four are end-to-end suites that each
/// need a *different* set of doubles, so the per-file copies do not describe one thing twice.
/// Here two suites want the identical value, and writing it twice is the shape
/// `DrainDuplicationTests` exists to object to.
enum TestPaths {
    static let repoRoot: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // ElliotProcessTests
        .deletingLastPathComponent()   // Tests
        .deletingLastPathComponent()   // ElliotKit
        .deletingLastPathComponent()   // repo root
}
