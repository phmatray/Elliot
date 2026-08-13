# Vendored: wiedymi/swift-acp

**Origin:** https://github.com/wiedymi/swift-acp
**Commit:** `9498537769d1309b6519fbb87d0c22fcf9317f3e` (2026-07-22, "Fix ACP subprocess message handling")
**Licence:** MIT © 2025 wiedymi — see `LICENSE` beside this file.

## Why vendored rather than depended on

Its only tag is `v0.1.0` while its README instructs `from: "1.0.0"` — a requirement that cannot
resolve against its own published tags. More importantly, it is `swift-tools-version: 5.9`, so as a
package dependency its own sources are never checked under Swift 6 strict concurrency: measured, it
builds clean as a 5.9 dependency consumed from a `.v6` package, and raises 33 errors when its
sources are compiled under `.v6`. Vendoring is what makes it actually checked.

## Module names are upstream's, deliberately

`ACPModel` and `ACP` keep their upstream names so this tree can be compared against upstream to pick
up fixes. Do not rename them.

## ⚠️ This tree has been reformatted — diff it whitespace-insensitively

Arbitrated 2026-08-12: the project's format rule (4 spaces, 110 columns, pinned in `.swift-format`)
applies here too, with no exception. Upstream runs to 137 columns, so a one-off
`swift format --in-place --recursive` was applied to this directory **before** any of our own edits.

That is not the tree-wide formatter run `CLAUDE.md` forbids: that ⛔ protects `Sources/` and
`Tests/`, which are hand-formatted and which the pretty-printer would rewrite wholesale. Nothing
here is hand-formatted.

**So comparing against upstream needs `git diff -w` or `diff -b`.** A plain diff shows the reformat
and buries the changes that actually matter, listed below.

## What was removed, and why

See `docs/superpowers/specs/2026-08-12-elliot-acp-design.md` §3.3. In short: the library contained
five separate places that spawn a process, and `ChildProcess` is the only thing in this repository
allowed to do that.

**As of Task 5, this table is the tree's actual contents, not just its policy.** `Client` →
`ACPProcessManager` → `ShellEnvironment` was one call chain, cut together: `Client` now holds a
`private let transport: any Transport` instead of an `ACPProcessManager`, and
`ACP/Internal/ProcessManager.swift`, `ProcessRegistry.swift` and `ACP/Utilities/ShellEnvironment.swift`
are deleted, not merely unreferenced. `OneSpawnerTests.knownRemaining` — the excuse list this file's
own guard read against those three names — is empty.

| Removed | Replaced by |
|---|---|
| `ACP/Internal/ProcessManager.swift`, `ProcessRegistry.swift` | `ElliotProcess/ACPTransport.swift` |
| `ACP/Transport/StdioTransport.swift` | same |
| `ACP/Utilities/ShellEnvironment.swift` | `ElliotProcess/LoginShellEnvironment.swift` |
| `ACP/Agent/*` | nothing — we are a client |
| `ACP/FileSystemDelegate.swift`, `TerminalDelegate.swift` | nothing — we declare `fs: false`, `terminal: false` |
| `ACPHTTP`, `ACPRegistry` (never copied) | nothing |

## What was changed in place

Four files, corrected 2026-08-12 (the "20 sites" this line previously claimed was Step 5's
*diagnostic* count — 5 source sites × 4 reporting passes — not a count of edits; there is one):

- `Client.swift:909`: the one generic parameter the build named at Step 6 —
  `withRequestTimeout<T>` → `withRequestTimeout<T: Sendable>`.
- `Client.swift:912`: `withRequestTimeout`'s `operation` parameter —
  `@escaping () async throws -> T` → `@escaping @Sendable () async throws -> T`. Not a generic
  parameter, so the line above doesn't cover it: this is a `SendingClosureRisksDataRace`
  diagnostic that only appeared once `:909`'s fix let the file clear an earlier type error and
  reach that later, SIL-level check.
- `Client.swift:1142`: `writeMessageWithDebug<T: Encodable>` → `<T: Encodable & Sendable>`, the
  other half of that same cascade (a `SendingRisksDataRace` at its call into
  `processManager.writeMessage`).
- `Internal/ProcessManager.swift:250`: `ACPProcessManager.writeMessage<T: Encodable>` →
  `<T: Encodable & Sendable>` — the callee side of the edit directly above.
- `Utilities/Logger.swift:12-14`: `acpSubsystem` made `let`, repointed to `dev.phmatray.elliot`;
  `configureACPLogging` deleted (its body assigned to what is now a `let`, and it had zero call
  sites anywhere in this repository).
- `Utilities/ShellEnvironment.swift:19-20`: `cachedEnvironment`/`isLoading` made
  `nonisolated(unsafe) static var` — arbitrated 2026-08-12; see the comment at the site for
  exactly what synchronisation this does and does not rely on.

**Task 5 (`refactor(vendor): the client speaks through the Transport it already declared`) made the
replacement above true.** `Client.swift` no longer names `ACPProcessManager` anywhere except in a
doc comment recording why the property changed; the fourteen call sites (`isRunning()` ×4,
`terminate()`, `writeMessage()`, plus `processIdentifier()`/`processGroupIdentifier()`/`stderrLines()`/
`launch()`, which are deleted rather than forwarded) are gone. `launch()`'s deletion means `Client`
no longer starts anything — the caller constructs the `Transport` and hands it to `init(transport:)`.
