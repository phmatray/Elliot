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
and buries the two changes that actually matter, listed below.

## What was removed, and why

See `docs/superpowers/specs/2026-08-12-elliot-acp-design.md` §3.3. In short: the library contained
three separate places that spawn a process, and `ChildProcess` is the only thing in this repository
allowed to do that.

| Removed | Replaced by |
|---|---|
| `ACP/Internal/ProcessManager.swift`, `ProcessRegistry.swift` | `ElliotProcess/ACPTransport.swift` |
| `ACP/Transport/StdioTransport.swift` | same |
| `ACP/Utilities/ShellEnvironment.swift` | `ElliotProcess/LoginShellEnvironment.swift` |
| `ACP/Agent/*` | nothing — we are a client |
| `ACP/FileSystemDelegate.swift`, `TerminalDelegate.swift` | nothing — we declare `fs: false`, `terminal: false` |
| `ACPHTTP`, `ACPRegistry` (never copied) | nothing |

## What was changed in place

- `Client.swift`: generic parameters constrained to `Sendable` (20 sites); `ACPProcessManager`
  replaced by the `Transport` protocol the file already declared but never used.
- `Utilities/Logger.swift`: mutable statics made immutable; subsystem repointed to
  `dev.phmatray.elliot`.
