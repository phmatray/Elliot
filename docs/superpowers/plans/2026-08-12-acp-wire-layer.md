# ACP Wire Layer (Stage 0) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Put a vendored, Swift-6-clean ACP client into ElliotKit, speaking to a real
`claude-agent-acp` over Elliot's own `ChildProcess` — without changing one line of `ElliotModel`,
`ElliotEngine`, `ElliotStore`, `ElliotIPC`, `ElliotMCPKit` or `ElliotAppKit`.

**Architecture:** `wiedymi/swift-acp` is vendored under `ElliotKit/Vendor/swift-acp/` as two targets
(`ACPModel`, `ACP`) keeping their upstream module names so the tree stays diffable against upstream.
Everything in it that spawns a process is deleted and replaced by `ACPTransport`, a `Transport`
conformance living in `ElliotProcess` and sitting on `ChildProcess` — because `ChildProcess` is the
only thing in this repository allowed to start a child. `Client` is re-pointed from its hardcoded
`ACPProcessManager` onto the `Transport` protocol it already declares but never used.

**Tech Stack:** Swift 6.3.1, `swiftLanguageModes: [.v6]`, macOS 15, swift-testing, GRDB (untouched
here), Python 3 for the test double, Node ≥ 22 + `npx` for the live adapter.

## Global Constraints

- Tools version is **`6.3.1`**, patch included — never a bare `6.3`. SwiftPM resolves `6.3` as
  `6.3.0` and readmits a toolchain that hits a `#expect` type-check timeout.
- `swiftLanguageModes: [.v6]`, `platforms: [.macOS(.v15)]`. Every type crossing an isolation
  boundary is `Sendable`.
- **4 spaces, 110 columns — everywhere, `Vendor/` included.** Arbitrated 2026-08-12: one rule, no
  exception. `.swift-format` already pins exactly those two values.
  - ⛔ **`Sources/` and `Tests/` are formatted BY HAND.** Do not run `swift format` over them —
    measured on a clean checkout, it reindents 140 files and `lint --strict` reports 22 463
    violations, and the disagreement is the printer's layout rather than its width.
  - ✅ **`Vendor/` is the exception, and it is not the forbidden run.** Nobody hand-wrote it and
    nobody will hand-maintain its layout, so `swift format --in-place --recursive ElliotKit/Vendor`
    — **scoped to that directory, never the package** — is the right tool and the only practical one
    for 10 648 lines. Task 1 Step 2 does it once, before any of our own edits, so the 33 concurrency
    fixes land as a readable diff rather than inside a reformat.
  - ⚠️ **Consequence, recorded rather than discovered later:** upstream comparison stops being a
    plain `git diff`. Use `-w`/`-b` (whitespace-insensitive) when checking this tree against
    `wiedymi/swift-acp`. `VENDORED.md` says so.
- ⛔ **`ChildProcess` is the only thing that starts a child**, drains its pipes and publishes its
  exit. Task 2 installs a test that fails by name if a second spawner appears.
- ⛔ **Nothing waits on `Process.waitUntilExit()`.** Both existing spawners publish the exit from
  `terminationHandler` under one lock.
- Every async wait in a test is bounded, through `withTimeout` in the `TestSupport` target. No test
  sleeps a fixed interval or asserts an absolute duration.
- Conventional Commits with the layer as scope: `feat(process): …`, `chore(vendor): …`.
- Branch: `feat/<issue>-<slug>`, number first, followed by `-`.
- `swift test --filter` matches the **type** name, not the `@Suite` display name. A filter matching
  nothing prints `warning: No matching test cases were run` and **exits 0**.
- ⚠️ A stale `.build` fails in ways that look like real breakage. If a reported failure could not
  have happened, `rm -rf ElliotKit/.build` before believing it. Adding an associated value to an
  enum triggers this with no checkout at all.

## Corrections to the spec, measured after it was written

The design document (`docs/superpowers/specs/2026-08-12-elliot-acp-design.md`, commit `11637dc`)
§3.4 lists `ACP/Utilities/Logger.swift` as a cut. **That is wrong and this plan does not follow it.**
`Logger` is referenced by `Client.swift` and `FileSystemDelegate.swift`; cutting it breaks the one
file we most need. It is kept, its 12 mutable statics are made immutable, and its subsystem is
repointed to Elliot's — which satisfies the stated intent (not a second logging story) at no cost.
Task 9 writes this correction back into the spec.

`ShellEnvironment` is confirmed cuttable: its only callers are `TerminalDelegate`, `StdioTransport`
and `ProcessManager`, all three of which this plan deletes.

---

## File Structure

| File | Responsibility |
|---|---|
| `ElliotKit/Vendor/swift-acp/ACPModel/**` | Vendored wire types. Upstream module name kept so the tree diffs against upstream. |
| `ElliotKit/Vendor/swift-acp/ACP/**` | Vendored protocol layer: `Client`, message routing, requests/responses/updates. No process, no shell, no transport. |
| `ElliotKit/Vendor/swift-acp/VENDORED.md` | Origin, commit, licence, and the exact list of what was deleted and why. |
| `ElliotKit/Sources/ElliotProcess/ChildProcess.swift` | Gains an opt-in writable stdin. Everything else unchanged. |
| `ElliotKit/Sources/ElliotProcess/ACPTransport.swift` | `Transport` conformance over `ChildProcess`. The only new spawn-adjacent file. |
| `ElliotKit/Sources/ElliotProcess/ACPAgentProcess.swift` | Launch descriptor: which binary, which arguments, which environment. |
| `Scripts/fake-acp.py` | The test double. Answers ACP over stdio from a fixture. |
| `Fixtures/acp/*.json` | Real recordings of the live adapter (already committed in `11637dc`). |
| `ElliotKit/Tests/ElliotProcessTests/ACPTransportTests.swift` | Transport against `/bin/cat` and against the double. |
| `ElliotKit/Tests/ElliotProcessTests/OneSpawnerTests.swift` | Source-reading guard: exactly one `Process()` in the package. |
| `ElliotKit/Tests/ElliotProcessTests/ACPSessionTests.swift` | End-to-end through the double. |

---

### Task 1: Vendor the library whole, and make it build under `.v6`

Vendor first, cut second. Two gates: a reviewer can accept "the library is in the tree and compiles
under our floor" separately from "the right parts were removed", and the second is much easier to
judge once the first is green.

**Files:**
- Create: `ElliotKit/Vendor/swift-acp/**` (45 files, from the clone)
- Create: `ElliotKit/Vendor/swift-acp/VENDORED.md`
- Modify: `ElliotKit/Package.swift` (targets list, around line 144)
- Test: `ElliotKit/Tests/ElliotProcessTests/ACPModelDecodingTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces: modules `ACPModel` and `ACP`, importable from `ElliotProcess`. Types used later:
  `Client` (actor), `Transport` (protocol), `SessionUpdateNotification`, `RequestPermissionRequest`,
  `SessionId`, `JSONRPCNotification`.

- [ ] **Step 1: Clone the pinned commit and copy the sources**

```bash
cd /tmp && rm -rf swift-acp-vendor
git clone https://github.com/wiedymi/swift-acp swift-acp-vendor
cd swift-acp-vendor && git checkout 9498537769d1309b6519fbb87d0c22fcf9317f3e
git log -1 --format='%H %ad %s' --date=iso   # expect: 9498537… 2026-07-22 … Fix ACP subprocess message handling
```

Then, from the Elliot worktree root:

```bash
mkdir -p ElliotKit/Vendor/swift-acp
cp -R /tmp/swift-acp-vendor/Sources/ACPModel ElliotKit/Vendor/swift-acp/ACPModel
cp -R /tmp/swift-acp-vendor/Sources/ACP      ElliotKit/Vendor/swift-acp/ACP
cp /tmp/swift-acp-vendor/LICENSE             ElliotKit/Vendor/swift-acp/LICENSE
```

⚠️ `ACPHTTP` and `ACPRegistry` are **not** copied at all — WebSocket transport and agent discovery
are out of scope, and not copying them is cheaper than deleting them later.

- [ ] **Step 2: Reformat the vendored tree to the project's rule, once, before touching anything**

Upstream runs to 137 columns; this project pins 110 in `.swift-format`. Do it now, so the 33
concurrency fixes in Steps 6–7 land as a readable diff instead of inside a reformat.

```bash
swift format --in-place --recursive ElliotKit/Vendor
git -C . diff --stat -- ElliotKit/Vendor | tail -1
python3 -c "
import pathlib
worst = max(
    ((len(l.rstrip()), p, i + 1)
     for p in pathlib.Path('ElliotKit/Vendor').rglob('*.swift')
     for i, l in enumerate(p.read_text().splitlines())),
    default=(0, None, 0))
print('longest line now:', worst)
"
```

⛔ **Scoped to `ElliotKit/Vendor`, never the package.** Running it over `Sources/` or `Tests/`
rewrites 140 hand-formatted files, which is the ⛔ in `CLAUDE.md`.

⚠️ A few lines may still exceed 110 — the printer cannot break a long string literal or a very long
identifier. That is expected; do not hand-wrap them.

- [ ] **Step 3: Write `VENDORED.md`**

Create `ElliotKit/Vendor/swift-acp/VENDORED.md`:

```markdown
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
```

- [ ] **Step 4: Add the two targets to `Package.swift`**

In `ElliotKit/Package.swift`, in the `targets:` array, immediately **before** the existing
`.target(name: "ElliotProcess", …)` line:

```swift
        // Vendored: wiedymi/swift-acp @ 9498537, MIT. See Vendor/swift-acp/VENDORED.md for the
        // origin, the licence, and the list of what was deleted — chiefly three process spawners,
        // because ChildProcess is the only thing here allowed to start a child.
        //
        // Upstream module names are kept so this tree stays diffable against upstream.
        .target(name: "ACPModel", path: "Vendor/swift-acp/ACPModel"),
        .target(name: "ACP", dependencies: ["ACPModel"], path: "Vendor/swift-acp/ACP"),
```

and change the `ElliotProcess` target line to depend on them:

```swift
        .target(name: "ElliotProcess", dependencies: ["ElliotModel", "ACP", "ACPModel"]),
```

- [ ] **Step 5: Build and capture the failures**

```bash
cd ElliotKit && rm -rf .build && swift build > /tmp/acp-vendor-build.log 2>&1; echo "EXIT=$?"
grep -c 'error:' /tmp/acp-vendor-build.log
grep 'error:' /tmp/acp-vendor-build.log | sed 's/.*error: //' | sed "s/'[^']*'/'X'/g" | sort | uniq -c | sort -rn
```

⚠️ Redirect as `> log 2>&1`, never `2>&1 > log` — the latter sends stderr to the old stdout and the
log comes back empty of diagnostics.

Expected: **33 errors**, in exactly three files, in two shapes —
`20 × type 'X' does not conform to the 'Sendable' protocol` and
`12 × static property 'X' is not concurrency-safe because it is nonisolated global shared mutable state`,
plus one `emit-module command failed`.

If the count differs, stop and report it rather than adapting: the number is a measurement from
2026-08-12 and a different one means the commit is not the pinned one.

- [ ] **Step 6: Constrain the generics in `Client.swift`**

Every failing generic is an unconstrained `T` passed through a task group or a continuation. The fix
is one word per signature. For example, `withRequestTimeout`:

```swift
    private func withRequestTimeout<T: Sendable>(
```

Apply `: Sendable` to the generic parameter of every signature the compiler named. Do **not** silence
these with `@unchecked Sendable` or by removing the constraint from the caller — the diagnostic is
correct, and this hole was found independently before the compiler named it.

- [ ] **Step 7: Fix the mutable statics**

In `Vendor/swift-acp/ACP/Utilities/Logger.swift`, make each flagged `static var` a `static let`, and
repoint the subsystem so this package has one logging story rather than two:

```swift
extension Logger {
    /// Repointed from upstream's `com.acp` when vendored: a second subsystem is a second place to
    /// look when a run goes quiet, and `log show` is already hard enough to get output from here.
    private static let acpSubsystem = "dev.phmatray.elliot"
```

Apply the same `var` → `let` change to the other flagged statics. Where a static genuinely must
stay mutable, `nonisolated(unsafe) let` is **not** an acceptable substitute — convert it or hoist it
into the actor that uses it.

`ShellEnvironment.swift`'s statics are also flagged; leave that file alone, Task 2 deletes it.

- [ ] **Step 8: Build until green**

```bash
cd ElliotKit && swift build > /tmp/acp-vendor-build.log 2>&1; echo "EXIT=$?"
grep -c 'error:' /tmp/acp-vendor-build.log; grep -c 'warning:' /tmp/acp-vendor-build.log
tail -3 /tmp/acp-vendor-build.log
```

Expected: `EXIT=0`, `0` errors, `0` warnings, `Build complete!`.

- [ ] **Step 9: Write the failing decoding test**

This asserts the one property the whole "Claude via ACP" decision rests on: that `_meta` survives.

Create `ElliotKit/Tests/ElliotProcessTests/ACPModelDecodingTests.swift`:

```swift
import ACP
import ACPModel
import Foundation
import Testing

/// `_meta.claudeCode.toolName` is how a card keeps rendering `Read` / `Edit` / `Bash` after the
/// wire changes. A decoder that drops unknown `_meta` would make the vendored library unusable
/// here regardless of how cleanly it compiles, so this is pinned rather than assumed.
@Suite("ACP model decoding")
struct ACPModelDecodingTests {
    @Test("a tool call keeps its Claude-specific _meta, nested values included")
    func toolCallMetaSurvives() throws {
        let json = """
        {"sessionId":"sess-1",
         "update":{"sessionUpdate":"tool_call","toolCallId":"tc-1","title":"Read File",
                   "kind":"read","status":"pending","content":[],
                   "_meta":{"claudeCode":{"toolName":"Read","nested":{"deep":true}}}}}
        """
        let note = try JSONDecoder().decode(
            SessionUpdateNotification.self, from: Data(json.utf8)
        )
        guard case .toolCall(let call) = note.update else {
            Issue.record("expected a tool_call update")
            return
        }
        let claudeCode = call._meta?["claudeCode"]?.value as? [String: any Sendable]
        #expect(claudeCode?["toolName"] as? String == "Read")
        #expect((claudeCode?["nested"] as? [String: any Sendable])?["deep"] as? Bool == true)
    }

    @Test("_meta survives an encode/decode round trip")
    func metaSurvivesRoundTrip() throws {
        let json = """
        {"sessionId":"sess-1",
         "update":{"sessionUpdate":"tool_call","toolCallId":"tc-1","title":"Read File",
                   "kind":"read","status":"pending","content":[],
                   "_meta":{"claudeCode":{"toolName":"Read"}}}}
        """
        let once = try JSONDecoder().decode(
            SessionUpdateNotification.self, from: Data(json.utf8)
        )
        let twice = try JSONDecoder().decode(
            SessionUpdateNotification.self, from: JSONEncoder().encode(once)
        )
        guard case .toolCall(let call) = twice.update else {
            Issue.record("expected a tool_call update")
            return
        }
        let claudeCode = call._meta?["claudeCode"]?.value as? [String: any Sendable]
        #expect(claudeCode?["toolName"] as? String == "Read")
    }
}
```

- [ ] **Step 10: Run the tests**

```bash
cd ElliotKit && swift test --filter ACPModelDecodingTests
```

Expected: 2 tests pass. ⚠️ If it prints `warning: No matching test cases were run` and exits 0, the
filter matched nothing — check the **type** name, not the suite's display name.

- [ ] **Step 11: Commit**

```bash
git rev-parse --abbrev-ref HEAD   # confirm the branch before committing; worktrees share this .git
git add ElliotKit/Vendor ElliotKit/Package.swift ElliotKit/Tests/ElliotProcessTests/ACPModelDecodingTests.swift
git commit -m "chore(vendor): swift-acp at 9498537, compiling under our own language mode

Vendored rather than depended on because a 5.9 package consumed from a .v6
one is never itself strict-concurrency checked: measured, it builds clean as
a dependency and raises 33 errors when its sources compile under .v6.

Twenty of those were unconstrained generics crossing a task group, which is a
real hole rather than a compiler formality. The other twelve were mutable
statics, and the logger's subsystem is repointed to ours on the way past."
```

---

### Task 2: Cut what `Client` does not hold, and arm the guard against the rest

**Files:**
- Delete: `ElliotKit/Vendor/swift-acp/ACP/Internal/ProcessManager.swift`, `ProcessRegistry.swift`,
  `Transport/StdioTransport.swift`, `Utilities/ShellEnvironment.swift`,
  `FileSystemDelegate.swift`, `TerminalDelegate.swift`, `Agent/Agent.swift`,
  `Agent/StdinTransport.swift`
- Modify: `ElliotKit/Vendor/swift-acp/ACP/Client.swift` (the 12 `processManager` sites) — Task 5
  completes this; here it only needs to compile.
- Test: `ElliotKit/Tests/ElliotProcessTests/OneSpawnerTests.swift`

**Interfaces:**
- Consumes: `ACPModel`, `ACP` from Task 1.
- Produces: an `ACP` module containing no process handling. `Transport` (protocol) is the only
  remaining seam to a child.

- [ ] **Step 1: Write the failing guard test**

A rule that is not a test is a rule nobody re-runs. This one reads the sources the way
`DrainDuplicationTests` already does, and fails **naming the file**.

Create `ElliotKit/Tests/ElliotProcessTests/OneSpawnerTests.swift`:

```swift
import Foundation
import Testing

/// `ChildProcess` is the only thing in this package that starts a child, drains its pipes and
/// publishes its exit. That was true until a vendored ACP library arrived carrying three more
/// spawners — one of which called `waitUntilExit()`, which this repository's production rule
/// forbids outright.
///
/// #146 is why this is a test and not a comment: the mechanism was written twice before, eight
/// comment lines were byte-identical across the two copies, and three defects were each fixed in
/// one file only. A vendor boundary is a worse place for that to happen, not a better one.
@Suite("One spawner")
struct OneSpawnerTests {
    /// Walks up from this file to the package root, so the test does not depend on the working
    /// directory `swift test` happened to be run from.
    static var packageRoot: URL {
        URL(fileURLWithPath: #filePath)          // …/Tests/ElliotProcessTests/OneSpawnerTests.swift
            .deletingLastPathComponent()          // …/Tests/ElliotProcessTests
            .deletingLastPathComponent()          // …/Tests
            .deletingLastPathComponent()          // …/ElliotKit
    }

    static func swiftFiles(under directory: String) -> [URL] {
        let root = packageRoot.appendingPathComponent(directory)
        guard let walker = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: nil
        ) else { return [] }
        return walker.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
    }

    /// The two files Task 5 removes, once `Client` no longer references them.
    ///
    /// Listed by name so the guard is **armed now** and this set emptying is Task 5's acceptance
    /// criterion — which is not the same thing as a guard switched off and forgotten.
    static let knownRemaining: Set<String> = ["ProcessManager.swift", "ProcessRegistry.swift"]

    @Test("only ChildProcess.swift constructs a Process")
    func onlyOneSpawner() throws {
        var offenders: [String] = []
        for file in Self.swiftFiles(under: "Sources") + Self.swiftFiles(under: "Vendor") {
            let name = file.lastPathComponent
            guard name != "ChildProcess.swift", !Self.knownRemaining.contains(name) else { continue }
            let text = try String(contentsOf: file, encoding: .utf8)
            if text.contains("Process()") { offenders.append(name) }
        }
        #expect(
            offenders.isEmpty,
            "a second spawner appeared in \(offenders.joined(separator: ", ")) — ChildProcess is the "
                + "only thing allowed to start a child (see #146)"
        )
    }

    @Test("nothing waits on waitUntilExit")
    func nothingBlocksOnWaitUntilExit() throws {
        var offenders: [String] = []
        for file in Self.swiftFiles(under: "Sources") + Self.swiftFiles(under: "Vendor") {
            let name = file.lastPathComponent
            guard !Self.knownRemaining.contains(name) else { continue }
            let text = try String(contentsOf: file, encoding: .utf8)
            // `ChildProcess`'s own doc comment explains at length why it does NOT call this, so
            // the match must be a call rather than a mention.
            if text.contains(".waitUntilExit()") { offenders.append(name) }
        }
        #expect(
            offenders.isEmpty,
            "\(offenders.joined(separator: ", ")) waits on waitUntilExit(), which spins a run loop "
                + "on a cooperative thread the runtime may park and reuse (3b1c226/#18)"
        )
    }
}
```

- [ ] **Step 2: Run it and watch it fail**

```bash
cd ElliotKit && swift test --filter OneSpawnerTests
```

Expected: **both tests FAIL**. `onlyOneSpawner` names `StdioTransport.swift` (and `Agent.swift` /
`StdinTransport.swift` if either constructs one); `nothingBlocksOnWaitUntilExit` names
`ShellEnvironment.swift`.

⚠️ `ProcessManager.swift` and `ProcessRegistry.swift` are **not** in either list — `knownRemaining`
excuses them until Task 5. If they do appear, the excuse set was mistyped.

⚠️ If both tests pass, the vendoring of Task 1 did not land — check `ElliotKit/Vendor/` exists and
that `swiftFiles(under: "Vendor")` is finding files (a wrong `packageRoot` returns an empty list,
and an empty list passes every guard silently).

- [ ] **Step 3: Delete only what `Client.swift` does not reference**

`ProcessManager` and `ProcessRegistry` stay for now — `Client` holds them at fourteen sites, and
removing those is Task 5's whole subject. Deleting them here would end this task on a red build, and
a task must end green.

```bash
cd ElliotKit/Vendor/swift-acp/ACP
rm Transport/StdioTransport.swift
rm Utilities/ShellEnvironment.swift
rm FileSystemDelegate.swift TerminalDelegate.swift
rm -rf Agent
```

`FileSystemDelegate` and `TerminalDelegate` go because this client declares
`fs: {readTextFile: false, writeTextFile: false}` and `terminal: false`, so a conforming agent never
issues those calls. ⚠️ Their *types* live in `ACPModel` and stay — only the implementations go.

- [ ] **Step 4: Give the deleted delegates a default refusal**

Deleting the implementations leaves `ClientDelegate`'s requirements unsatisfiable by any conformer.
Move them into the existing `public extension ClientDelegate` block, beside the optional
requirements that already default there:

```swift
    func handleFileReadRequest(
        _ path: String, sessionId: String, line: Int?, limit: Int?
    ) async throws -> ReadTextFileResponse {
        // Elliot declares `fs: {readTextFile: false, writeTextFile: false}` at `initialize`, so a
        // conforming agent never sends this. Refusing is the honest answer if one does anyway.
        throw ClientError.invalidResponse
    }

    func handleFileWriteRequest(
        _ path: String, content: String, sessionId: String
    ) async throws -> WriteTextFileResponse {
        // Same capability, same reason. ⛔ Never make this a silent success: an agent that believes
        // it wrote a file it did not is worse than one told no.
        throw ClientError.invalidResponse
    }
```

and one each for `handleTerminalCreate`, `handleTerminalOutput`, `handleTerminalWaitForExit`,
`handleTerminalKill` and `handleTerminalRelease`, each carrying a one-line comment naming
`terminal: false` as the capability that makes it unreachable. Copy the exact signatures from
`ClientDelegate.swift`'s protocol body — do not retype them from memory.

- [ ] **Step 5: Build and test**

```bash
cd ElliotKit && swift build > /tmp/acp-cut-build.log 2>&1; echo "EXIT=$?"
swift test --filter OneSpawnerTests
```

Expected: build `EXIT=0`; both guard tests **pass**, with `ProcessManager.swift` and
`ProcessRegistry.swift` excused by name.

- [ ] **Step 6: Sample the whole suite**

One green run does not clear a suite. The clean build costs ~21–45 s and execution ~1.5–2.9 s, so
five samples after one build cost about eight seconds.

```bash
cd ElliotKit && swift build --build-tests > /dev/null 2>&1
for i in 1 2 3 4 5; do swift test 2>&1 | tail -1; done
```

Expected: five identical passing lines, `1418 tests in 158 suites` plus the new ones.

- [ ] **Step 7: Commit**

```bash
git rev-parse --abbrev-ref HEAD
git add -A ElliotKit/Vendor ElliotKit/Tests/ElliotProcessTests/OneSpawnerTests.swift
git commit -m "chore(vendor): cut two of the vendored spawners, and arm the guard against the rest

The library carried three places that construct a Process and one that
captures the login shell by calling waitUntilExit() — the one thing this
package's production rule forbids, and a duplicate of LoginShellEnvironment,
which is hard-won.

OneSpawnerTests reads the sources the way DrainDuplicationTests does and
fails naming the file. ProcessManager and ProcessRegistry are excused by
name for now; that list emptying is the next task's acceptance criterion,
which is not the same thing as a disabled guard."
```

---

### Task 3: Give `ChildProcess` an opt-in writable stdin

ACP is spoken *to*. `ChildProcess` sets `process.standardInput = FileHandle.nullDevice` on purpose —
*"Never let a child inherit the app's stdin and block waiting on it"* — so `Transport.send` has
nowhere to write. The default must not change; this adds a case.

**Files:**
- Modify: `ElliotKit/Sources/ElliotProcess/ChildProcess.swift:71-95` (init), and add `writeStdin`
- Modify: `ElliotKit/Sources/ElliotProcess/ProcessRunner.swift:14-26` (a new `ProcessError` case)
- Test: `ElliotKit/Tests/ElliotProcessTests/ChildProcessStdinTests.swift`

**Interfaces:**
- Consumes: `ChildProcess<Sink>`, `ChildOutputSink`, `Locked`, `ProcessError` — all existing.
- Produces:
  - `ChildProcess.StandardInput` — `enum { case null, case pipe }`, `Sendable`
  - `ChildProcess.init(executable:arguments:cwd:environment:stdin:sink:)` where
    `stdin: StandardInput = .null`
  - `func writeStdin(_ data: Data) throws` — throws `ProcessError.stdinNotPiped` when `.null`
  - `func closeStdin()`
  - `ProcessError.stdinNotPiped`

- [ ] **Step 1: Write the failing test**

Create `ElliotKit/Tests/ElliotProcessTests/ChildProcessStdinTests.swift`:

```swift
import Foundation
import Testing
import TestSupport

@testable import ElliotProcess

/// `cat` is the whole harness: it echoes stdin to stdout and exits when stdin closes, so one
/// spawn exercises writing, reading back, and the close that ends the child.
@Suite("Child process stdin")
struct ChildProcessStdinTests {
    /// Collects stdout under the drain lock, exactly as every other sink does.
    private struct Collector: ChildOutputSink {
        let continuation: AsyncStream<Data>.Continuation
        mutating func receiveStdout(_ chunk: Data) { continuation.yield(chunk) }
        mutating func receiveStderr(_ chunk: Data) {}
        mutating func finish() { continuation.finish() }
    }

    @Test("a piped child receives what is written to its stdin")
    func writesReachTheChild() async throws {
        var continuation: AsyncStream<Data>.Continuation!
        let chunks = AsyncStream<Data> { continuation = $0 }

        let child = try ChildProcess(
            executable: "/bin/cat",
            arguments: [],
            cwd: nil,
            environment: [:],
            stdin: .pipe,
            sink: Collector(continuation: continuation!)
        )

        try child.writeStdin(Data("hello\n".utf8))

        let first = try await withTimeout(.seconds(5)) {
            var iterator = chunks.makeAsyncIterator()
            return await iterator.next()
        }
        #expect(String(decoding: first ?? Data(), as: UTF8.self) == "hello\n")

        child.closeStdin()
        let termination = await withTimeout(.seconds(5)) { await child.wait() }
        #expect(termination.code == 0)
    }

    @Test("a child spawned with the default stdin refuses a write")
    func defaultStdinRefusesWrites() throws {
        var continuation: AsyncStream<Data>.Continuation!
        _ = AsyncStream<Data> { continuation = $0 }

        let child = try ChildProcess(
            executable: "/bin/cat",
            arguments: [],
            cwd: nil,
            environment: [:],
            sink: Collector(continuation: continuation!)
        )
        defer { child.terminate() }

        #expect(throws: ProcessError.self) {
            try child.writeStdin(Data("hello\n".utf8))
        }
    }
}
```

- [ ] **Step 2: Run it and watch it fail**

```bash
cd ElliotKit && swift test --filter ChildProcessStdinTests
```

Expected: FAIL to **compile** — `extra argument 'stdin' in call`, and `writeStdin`/`closeStdin`
undefined. A compile failure is the correct red here.

- [ ] **Step 3: Add the error case**

In `ElliotKit/Sources/ElliotProcess/ProcessRunner.swift`, add to `ProcessError`:

```swift
    case stdinNotPiped
```

and to `errorDescription`:

```swift
        case .stdinNotPiped:
            "This child was spawned with stdin closed. Pass `stdin: .pipe` to write to it."
```

- [ ] **Step 4: Add the stdin option to `ChildProcess`**

In `ChildProcess.swift`, add above the class's `init`:

```swift
    /// What the child's stdin is connected to.
    ///
    /// `.null` is the default and stays the default: a child that inherits the app's stdin blocks
    /// waiting on it, which is what the single line here always prevented.
    ///
    /// `.pipe` exists for one kind of caller — an agent spoken to over JSON-RPC, which is written
    /// to rather than only read from. ⛔ Its writer never closes the handle: a helper whose stdin
    /// closes exits having written nothing, which reads exactly like a helper that failed to start.
    /// Only `closeStdin()` closes it, and only at teardown.
    enum StandardInput: Sendable {
        case null
        case pipe
    }
```

Add a stored property beside the existing ones:

```swift
    /// `nil` when spawned `.null`. Boxed because the write can come from any isolation.
    private let stdinHandle: Locked<FileHandle?>
```

Change the `init` signature to insert `stdin` before `sink`:

```swift
    init(
        executable: String,
        arguments: [String],
        cwd: String?,
        environment: [String: String],
        stdin: StandardInput = .null,
        sink: Sink
    ) throws {
```

and replace the single `process.standardInput = FileHandle.nullDevice` line with:

```swift
        switch stdin {
        case .null:
            // Never let a child inherit the app's stdin and block waiting on it.
            process.standardInput = FileHandle.nullDevice
            stdinHandle = Locked(nil)
        case .pipe:
            let inPipe = Pipe()
            process.standardInput = inPipe
            stdinHandle = Locked(inPipe.fileHandleForWriting)
        }
```

⚠️ This assignment must sit **before** `try process.run()`, where the existing line already is.

- [ ] **Step 5: Add the writer and the closer**

Add beside `withSink`:

```swift
    /// Writes to the child's stdin.
    ///
    /// Synchronous and under a lock, so two callers cannot interleave halves of a JSON-RPC line.
    /// A write blocks if the child is not reading; the messages this carries are single lines, and
    /// an agent that has stopped reading is one `terminate()` is about to reach anyway.
    func writeStdin(_ data: Data) throws {
        try stdinHandle.withLock { handle in
            guard let handle else { throw ProcessError.stdinNotPiped }
            try handle.write(contentsOf: data)
        }
    }

    /// Closes the child's stdin, which is how a well-behaved agent learns to exit.
    ///
    /// Separate from `terminate()` on purpose: closing is a request the child may take its time
    /// over, and `terminate()` is the escalation. Safe to call twice.
    func closeStdin() {
        stdinHandle.withLock { handle in
            try? handle?.close()
            handle = nil
        }
    }
```

- [ ] **Step 6: Run the test**

```bash
cd ElliotKit && swift test --filter ChildProcessStdinTests
```

Expected: 2 tests PASS.

- [ ] **Step 7: Verify every existing caller is untouched**

`stdin` has a default, so `StreamingProcess` and `ProcessRunner` should not have changed. Prove it:

```bash
git diff --stat ElliotKit/Sources/ElliotProcess/StreamingProcess.swift ElliotKit/Sources/ElliotProcess/ProcessRunner.swift
```

Expected: `StreamingProcess.swift` unchanged; `ProcessRunner.swift` changed only by the two lines of
the new error case.

- [ ] **Step 8: Sample the whole suite five times**

```bash
cd ElliotKit && swift build --build-tests > /dev/null 2>&1
for i in 1 2 3 4 5; do swift test 2>&1 | tail -1; done
```

Expected: five identical passing lines.

- [ ] **Step 9: Commit**

```bash
git rev-parse --abbrev-ref HEAD
git add ElliotKit/Sources/ElliotProcess/ChildProcess.swift ElliotKit/Sources/ElliotProcess/ProcessRunner.swift ElliotKit/Tests/ElliotProcessTests/ChildProcessStdinTests.swift
git commit -m "feat(process): an opt-in writable stdin, because ACP is spoken to

The null stdin was deliberate and stays the default — a child that inherits
the app's stdin blocks waiting on it. But a JSON-RPC agent is written to, so
.pipe is added as a case rather than the line being relaxed.

The writer never closes the handle. A helper whose stdin closes exits having
written nothing, which reads exactly like one that failed to start."
```

---

### Task 4: `ACPTransport` — the `Transport` conformance over `ChildProcess`

**Files:**
- Create: `ElliotKit/Sources/ElliotProcess/ACPAgentProcess.swift`
- Create: `ElliotKit/Sources/ElliotProcess/ACPTransport.swift`
- Test: `ElliotKit/Tests/ElliotProcessTests/ACPTransportTests.swift`

**Interfaces:**
- Consumes: `ChildProcess`, `ChildOutputSink`, `LineBuffer`, `Locked`, `ProcessError` from
  `ElliotProcess`; `Transport` from `ACP`.
- Produces:
  - `public struct ACPAgentProcess: Sendable` with `executable: String`, `arguments: [String]`,
    `cwd: String`, `environment: [String: String]`, and
    `init(executable:arguments:cwd:environment:)`
  - `public final class ACPTransport: Transport, Sendable` with
    `init(_ agent: ACPAgentProcess) throws`,
    `func send(_ data: Data) async throws`, `var messages: AsyncStream<Data> { get }`,
    `func close() async`, `var isConnected: Bool { get async }`,
    plus `var processIdentifier: Int32 { get }`, `func terminate(hardKillAfter:)` and
    `func waitForExit() async -> Int32` for Elliot's own use.

- [ ] **Step 1: Write the failing test**

Create `ElliotKit/Tests/ElliotProcessTests/ACPTransportTests.swift`:

```swift
import ACP
import Foundation
import Testing
import TestSupport

@testable import ElliotProcess

/// `/bin/cat` is a perfect ACP echo for transport purposes: newline-delimited JSON in, the same
/// bytes out. It tests the framing and the plumbing without involving an agent at all.
@Suite("ACP transport")
struct ACPTransportTests {
    @Test("a line written is a message received")
    func roundTripsOneMessage() async throws {
        let transport = try ACPTransport(
            ACPAgentProcess(
                executable: "/bin/cat", arguments: [], cwd: "/tmp", environment: [:]
            )
        )
        defer { transport.terminate() }

        try await transport.send(Data(#"{"jsonrpc":"2.0","id":1,"method":"ping"}"#.utf8))

        let received = try await withTimeout(.seconds(5)) {
            var iterator = transport.messages.makeAsyncIterator()
            return await iterator.next()
        }
        let decoded = try #require(received)
        let object = try JSONSerialization.jsonObject(with: decoded) as? [String: Any]
        #expect(object?["method"] as? String == "ping")
    }

    @Test("a message split across writes still arrives whole")
    func reassemblesASplitMessage() async throws {
        let transport = try ACPTransport(
            ACPAgentProcess(
                executable: "/bin/cat", arguments: [], cwd: "/tmp", environment: [:]
            )
        )
        defer { transport.terminate() }

        // `send` appends the newline, so these are two halves of one line only because the first
        // has none of its own — which is exactly what a chunked pipe read looks like.
        try await transport.sendRaw(Data(#"{"jsonrpc":"2.0","id":"#.utf8))
        try await transport.sendRaw(Data("1}\n".utf8))

        let received = try await withTimeout(.seconds(5)) {
            var iterator = transport.messages.makeAsyncIterator()
            return await iterator.next()
        }
        let decoded = try #require(received)
        let object = try JSONSerialization.jsonObject(with: decoded) as? [String: Any]
        #expect(object?["id"] as? Int == 1)
    }

    @Test("closing ends the message stream")
    func closingEndsTheStream() async throws {
        let transport = try ACPTransport(
            ACPAgentProcess(
                executable: "/bin/cat", arguments: [], cwd: "/tmp", environment: [:]
            )
        )
        await transport.close()

        let exit = await withTimeout(.seconds(5)) { await transport.waitForExit() }
        #expect(exit == 0)

        let isConnected = await transport.isConnected
        #expect(isConnected == false)
    }
}
```

- [ ] **Step 2: Run it and watch it fail**

```bash
cd ElliotKit && swift test --filter ACPTransportTests
```

Expected: FAIL to compile — `cannot find 'ACPTransport' in scope`.

- [ ] **Step 3: Write the launch descriptor**

Create `ElliotKit/Sources/ElliotProcess/ACPAgentProcess.swift`:

```swift
import Foundation

/// Everything needed to spawn one ACP agent.
///
/// A plain descriptor rather than a builder: the agent is reached by `npx`, which means the
/// executable is Node's launcher and the package is an argument, and nothing about that is worth
/// hiding behind a type that pretends otherwise.
///
/// ⚠️ The adapter resolves the Claude CLI vendored inside `@anthropic-ai/claude-agent-sdk`, not the
/// `claude` on PATH. `CLAUDE_CODE_EXECUTABLE` in `environment` is the documented escape hatch, and
/// whether pointing it at a locally installed CLI works is UNMEASURED as of 2026-08-12.
public struct ACPAgentProcess: Sendable {
    public var executable: String
    public var arguments: [String]
    public var cwd: String
    public var environment: [String: String]

    public init(
        executable: String,
        arguments: [String],
        cwd: String,
        environment: [String: String]
    ) {
        self.executable = executable
        self.arguments = arguments
        self.cwd = cwd
        self.environment = environment
    }
}
```

- [ ] **Step 4: Write the transport**

Create `ElliotKit/Sources/ElliotProcess/ACPTransport.swift`:

```swift
import ACP
import Foundation

/// ACP over a child's stdio, on top of `ChildProcess`.
///
/// The vendored library shipped its own `StdioTransport` and `ProcessManager`, both of which
/// constructed a `Process`. Deleting them and writing this is the whole point: `ChildProcess` owns
/// the spawn, the two-pipe drain, the exit publication and the SIGTERM→SIGKILL escalation, and
/// there is exactly one of it. What remains here is this transport's own idea — that stdout is a
/// sequence of newline-delimited JSON messages, and that stdin is writable.
///
/// Modelled on `StreamingProcess`, which is the same shape one protocol lower.
public final class ACPTransport: Transport, Sendable {
    private let child: ChildProcess<MessageSink>

    /// Splits chunks into messages. Called under `ChildProcess`'s lock — which is what stops a
    /// handler caught mid-flight by the child's exit yielding into a stream the final drain has
    /// already finished.
    private struct MessageSink: ChildOutputSink {
        var buffer = LineBuffer()
        var stderr = Data()
        let continuation: AsyncStream<Data>.Continuation

        mutating func receiveStdout(_ chunk: Data) {
            for line in buffer.append(chunk) where !line.isEmpty {
                continuation.yield(line)
            }
        }

        mutating func receiveStderr(_ chunk: Data) { stderr.append(chunk) }

        mutating func finish() {
            if let tail = buffer.flush(), !tail.isEmpty { continuation.yield(tail) }
            continuation.finish()
        }
    }

    /// Complete JSON-RPC messages, in order. Finishes when the agent exits.
    ///
    /// Unbounded, like `StreamingProcess.lines` and unlike the UI's run stream: dropping a
    /// JSON-RPC response is not a degraded picture, it is a request that never returns.
    public let messages: AsyncStream<Data>

    public init(_ agent: ACPAgentProcess) throws {
        var continuation: AsyncStream<Data>.Continuation!
        messages = AsyncStream(bufferingPolicy: .unbounded) { continuation = $0 }

        child = try ChildProcess(
            executable: agent.executable,
            arguments: agent.arguments,
            cwd: agent.cwd,
            environment: agent.environment,
            stdin: .pipe,
            sink: MessageSink(continuation: continuation!)
        )
    }

    /// Sends one JSON-RPC message, framed with the newline the protocol delimits on.
    public func send(_ data: Data) async throws {
        var framed = data
        framed.append(0x0A)
        try child.writeStdin(framed)
    }

    /// Sends bytes verbatim, framing included. For tests that need to write half a line.
    func sendRaw(_ data: Data) async throws {
        try child.writeStdin(data)
    }

    /// Closes stdin and lets the agent exit on its own terms.
    ///
    /// ⛔ Not `terminate()`. A well-behaved agent exits when its stdin closes, having flushed
    /// whatever it still owed; signalling it first would race that flush.
    public func close() async {
        child.closeStdin()
    }

    public var isConnected: Bool {
        get async { child.isRunning }
    }

    public var processIdentifier: Int32 { child.processIdentifier }

    /// Asks the agent to stop, escalating only if it ignores the request. The backstop for an
    /// agent that does not exit when its stdin closes.
    public func terminate(hardKillAfter grace: Duration = ProcessTermination.hardKillGrace) {
        child.terminate(hardKillAfter: grace)
    }

    public func waitForExit() async -> Int32 {
        await child.wait().code
    }
}
```

- [ ] **Step 5: Run the tests**

```bash
cd ElliotKit && swift test --filter ACPTransportTests
```

Expected: 3 tests PASS.

- [ ] **Step 6: Break it, to prove the tests bite**

A test that would say nothing if the code changed is not a guard. Temporarily delete the
`framed.append(0x0A)` line in `send`, run again:

```bash
cd ElliotKit && swift test --filter ACPTransportTests
```

Expected: `roundTripsOneMessage` **times out and fails** — `cat` echoes the bytes but no newline
ever arrives, so `LineBuffer` yields nothing.

⚠️ Commit before break-testing, or restore with `git checkout --` and lose nothing else: the tree
must be clean apart from the deliberate break. Then restore the line and re-run to green.

- [ ] **Step 7: Sample the whole suite five times, then commit**

```bash
cd ElliotKit && swift build --build-tests > /dev/null 2>&1
for i in 1 2 3 4 5; do swift test 2>&1 | tail -1; done
git rev-parse --abbrev-ref HEAD
git add ElliotKit/Sources/ElliotProcess/ACPTransport.swift ElliotKit/Sources/ElliotProcess/ACPAgentProcess.swift ElliotKit/Tests/ElliotProcessTests/ACPTransportTests.swift
git commit -m "feat(process): ACP over ChildProcess, so there is still one spawner

The vendored library shipped a StdioTransport and a ProcessManager that each
constructed a Process. This is what replaces both: ChildProcess owns the
spawn, the two-pipe drain, the exit and the SIGKILL escalation, and the only
idea left here is that stdout is newline-delimited JSON.

close() shuts stdin rather than signalling: a well-behaved agent exits when
its stdin closes, having flushed what it still owed."
```

---

### Task 5: Re-point `Client` from its process manager onto `Transport`

`Client` declares nothing about `Transport` today — it holds an `ACPProcessManager` at 12 sites,
while the `Transport` protocol sits in the same module unused. This is the change that lets the
last two spawners go.

**Files:**
- Modify: `ElliotKit/Vendor/swift-acp/ACP/Client.swift` (lines 35, 70, 75, 78, 111, 116, 121, 137,
  868, 930, 951, 968, 984, 1136 — re-verify with the grep in Step 1)
- Delete: `ElliotKit/Vendor/swift-acp/ACP/Internal/ProcessManager.swift`, `ProcessRegistry.swift`
- Modify: `ElliotKit/Tests/ElliotProcessTests/OneSpawnerTests.swift` (empty `knownRemaining`)
- Test: `ElliotKit/Tests/ElliotProcessTests/ACPClientTransportTests.swift`

**Interfaces:**
- Consumes: `ACPTransport` (Task 4), `Transport` (vendored).
- Produces: `Client.init(transport: any Transport)`; `Client.launch(...)` removed;
  `Client.processIdentifier()` / `processGroupIdentifier()` / `stderrLines()` removed — the caller
  owns the child and already knows those.

- [ ] **Step 1: Re-verify the call sites before editing**

```bash
grep -n 'processManager' ElliotKit/Vendor/swift-acp/ACP/Client.swift
```

Expected: 14 lines. If the set differs from the plan's list, trust the grep — the line numbers here
were read on 2026-08-12.

- [ ] **Step 2: Write the failing test**

Create `ElliotKit/Tests/ElliotProcessTests/ACPClientTransportTests.swift`:

```swift
import ACP
import ACPModel
import Foundation
import Testing
import TestSupport

@testable import ElliotProcess

/// An in-memory transport, so the client's request/response correlation is testable without a
/// child process at all. `/bin/cat` proves the pipe; this proves the protocol.
private final class LoopbackTransport: Transport, @unchecked Sendable {
    let messages: AsyncStream<Data>
    private let continuation: AsyncStream<Data>.Continuation
    private let lock = NSLock()
    private var closed = false

    /// Answers each request with a canned result keyed by method.
    private let answer: @Sendable (String, Int) -> Data?

    init(answer: @escaping @Sendable (String, Int) -> Data?) {
        var continuation: AsyncStream<Data>.Continuation!
        messages = AsyncStream(bufferingPolicy: .unbounded) { continuation = $0 }
        self.continuation = continuation!
        self.answer = answer
    }

    func send(_ data: Data) async throws {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let method = object["method"] as? String,
              let id = object["id"] as? Int
        else { return }
        if let reply = answer(method, id) { continuation.yield(reply) }
    }

    func close() async {
        lock.lock(); closed = true; lock.unlock()
        continuation.finish()
    }

    var isConnected: Bool {
        get async { lock.lock(); defer { lock.unlock() }; return !closed }
    }
}

@Suite("ACP client over a transport")
struct ACPClientTransportTests {
    @Test("initialize negotiates over whatever transport it was given")
    func initializeOverLoopback() async throws {
        let transport = LoopbackTransport { method, id in
            guard method == "initialize" else { return nil }
            return Data("""
            {"jsonrpc":"2.0","id":\(id),"result":{"protocolVersion":1,
             "agentCapabilities":{},"agentInfo":{"name":"loopback","version":"0.0.1"},
             "authMethods":[]}}
            """.utf8)
        }
        let client = Client(transport: transport)
        let response = try await withTimeout(.seconds(5)) {
            try await client.initialize(protocolVersion: 1)
        }
        #expect(response.protocolVersion == 1)
        #expect(response.agentInfo?.name == "loopback")
    }
}
```

⚠️ `client.initialize`'s exact parameter list is upstream's — read it at `Client.swift:145` and match
it. If it takes `clientCapabilities` and `clientInfo`, pass the values from the design: `fs` both
false, `terminal` false, `clientInfo` named `elliot`.

- [ ] **Step 3: Run it and watch it fail**

```bash
cd ElliotKit && swift test --filter ACPClientTransportTests
```

Expected: FAIL to compile — `Client` has no `init(transport:)`.

- [ ] **Step 4: Replace the stored property and the initialiser**

In `Client.swift`, replace the `private let processManager: ACPProcessManager` declaration with:

```swift
    /// The connection to the agent. Vendored change: upstream held an `ACPProcessManager` here and
    /// spawned its own child. Elliot supplies a `Transport` over `ChildProcess` instead, because
    /// this package has exactly one thing that starts a child.
    private let transport: any Transport
```

and replace `public init()` with:

```swift
    public init(transport: any Transport) {
        self.transport = transport
        // …keep upstream's remaining initialiser body, minus the processManager construction and
        // its two callback registrations, which Step 5 replaces.
    }
```

- [ ] **Step 5: Replace the callbacks with a read loop**

Upstream's initialiser ends with this — read verbatim from `Client.swift:74-83`:

```swift
        Task {
            await processManager.setDataReceivedCallback { [weak self] data in
                await self?.handleMessage(data: data)
            }
            await processManager.setTerminationCallback { [weak self] exitCode in
                await self?.handleTermination(exitCode: exitCode)
            }
        }
```

Both callbacks already delegate to methods that stay — `handleMessage(data:)` and
`handleTermination(exitCode:)`. Replace the whole block with a task draining the transport, reusing
those two methods rather than writing a second decoder:

```swift
        // Upstream pushed bytes in through a callback the process manager owned. A transport
        // publishes a stream, so the client pulls. Retained so `close()` can cancel it.
        readLoop = Task { [weak self] in
            for await message in transport.messages {
                await self?.handleMessage(data: message)
            }
            // The stream finishing is the agent going away. `handleTermination` is what fails every
            // in-flight request, so a caller is never left awaiting a reply that cannot come.
            // ⚠️ The exit code is not knowable from here — the transport owns the child. Zero is a
            // placeholder the caller must not read as "exited cleanly"; whoever built the
            // `ACPTransport` has `waitForExit()` and the real number.
            await self?.handleTermination(exitCode: 0)
        }
```

with a stored `private var readLoop: Task<Void, Never>?` beside the other properties.

- [ ] **Step 6: Replace the remaining ten sites**

| Upstream | Becomes |
|---|---|
| `await processManager.isRunning()` (4 sites) | `await transport.isConnected` |
| `await processManager.terminate()` | `await transport.close()` |
| `try await processManager.writeMessage(message)` | `try await transport.send(encoder.encode(message))` |
| `public func launch(...)` | **delete the whole method** — the caller constructs the transport |
| `processIdentifier()`, `processGroupIdentifier()`, `stderrLines()` | **delete** — the owner of the `ACPTransport` already has these |

⚠️ `writeMessage` took a model object and encoded it inside the process manager. `transport.send`
takes `Data`, so the encode moves to the call site. Use the `encoder` the client already holds.

- [ ] **Step 7: Delete the last two spawners and disarm the excuse list**

```bash
rm ElliotKit/Vendor/swift-acp/ACP/Internal/ProcessManager.swift
rm ElliotKit/Vendor/swift-acp/ACP/Internal/ProcessRegistry.swift
```

In `OneSpawnerTests.swift`, empty the excuse list — this is the task's acceptance criterion:

```swift
    /// Empty, and it must stay empty. Task 5 removed the last two.
    static let knownRemaining: Set<String> = []
```

- [ ] **Step 8: Build and test**

```bash
cd ElliotKit && rm -rf .build && swift build > /tmp/acp-client-build.log 2>&1; echo "EXIT=$?"
grep -c 'error:' /tmp/acp-client-build.log; grep -c 'warning:' /tmp/acp-client-build.log
swift test --filter ACPClientTransportTests
swift test --filter OneSpawnerTests
```

Expected: build `EXIT=0`, 0 errors, 0 warnings; `ACPClientTransportTests` 1 test passes;
`OneSpawnerTests` 2 tests pass with an empty excuse list.

- [ ] **Step 9: Sample and commit**

```bash
cd ElliotKit && swift build --build-tests > /dev/null 2>&1
for i in 1 2 3 4 5; do swift test 2>&1 | tail -1; done
git rev-parse --abbrev-ref HEAD
git add -A ElliotKit/Vendor ElliotKit/Tests/ElliotProcessTests
git commit -m "refactor(vendor): the client speaks through the Transport it already declared

Upstream declared a Transport protocol and then never used it: Client held an
ACPProcessManager at fourteen sites and spawned its own child. Re-pointing it
is what lets the last two spawners go, and OneSpawnerTests' excuse list is now
empty — which was this change's acceptance criterion.

launch(), processIdentifier() and stderrLines() are deleted rather than
forwarded. Whoever built the transport owns the child and already knows them."
```

---

### Task 6: `Scripts/fake-acp.py` — a double that answers

`Scripts/fake-claude.sh` prints and exits. An ACP double must respond, which makes it a program.
Python, under `Scripts/`, matching the existing harness: a stable path, runnable by hand from a
terminal — which is why `Fixtures/` sits at the repository root in the first place.

**Files:**
- Create: `Scripts/fake-acp.py`
- Create: `Fixtures/acp/fake-simple-turn.json`
- Test: exercised by Task 7; this task's own gate is running it by hand.

**Interfaces:**
- Consumes: nothing.
- Produces: an executable at `Scripts/fake-acp.py` honouring
  `FAKE_ACP_FIXTURE` (path to a JSON array of `session/update` params to replay),
  `FAKE_ACP_MODE` (`ok` | `hang` | `crash` | `permission`),
  `FAKE_ACP_READY` (path touched once the responder is trap-protected),
  `FAKE_ACP_ARGV_OUT` (path to write the received argv to),
  `FAKE_ACP_STOP_REASON` (default `end_turn`).

- [ ] **Step 1: Write the fixture**

Create `Fixtures/acp/fake-simple-turn.json` — a JSON array of `update` objects, replayed in order:

```json
[
  {"sessionUpdate": "current_mode_update", "currentModeId": "bypassPermissions"},
  {"sessionUpdate": "agent_message_chunk",
   "content": {"type": "text", "text": "Reading the file."},
   "messageId": "msg_fake_1"},
  {"sessionUpdate": "tool_call", "toolCallId": "tc-1", "title": "Edit",
   "kind": "edit", "status": "pending", "content": [],
   "_meta": {"claudeCode": {"toolName": "Edit"}}},
  {"sessionUpdate": "tool_call_update", "toolCallId": "tc-1",
   "title": "Edit /tmp/notes.txt", "kind": "edit",
   "locations": [{"path": "/tmp/notes.txt", "line": 3}]},
  {"sessionUpdate": "tool_call_update", "toolCallId": "tc-1",
   "content": [{"type": "diff", "path": "/tmp/notes.txt",
                "oldText": "line three", "newText": "line three\nline four"}]},
  {"sessionUpdate": "tool_call_update", "toolCallId": "tc-1", "status": "completed"},
  {"sessionUpdate": "usage_update", "used": 37355, "size": 1000000,
   "cost": {"amount": 0.2855775, "currency": "USD"}}
]
```

⚠️ Frames 3–6 reproduce the partial-patch shape measured from the real adapter: `status`, `kind` and
`title` are each absent from at least one later frame. A double that repeated every field on every
frame would let a replacing fold pass, which is the exact bug the design calls out.

- [ ] **Step 2: Write the responder**

Create `Scripts/fake-acp.py`:

```python
#!/usr/bin/env python3
"""An ACP agent that answers, for tests.

`fake-claude.sh` prints and exits; ACP is a conversation, so this reads JSON-RPC on stdin and
replies. It replays a fixture of `session/update` frames on `session/prompt`, then answers the
prompt request with a stop reason.

Env:
  FAKE_ACP_FIXTURE      JSON array of `update` objects to replay. Required for a useful turn.
  FAKE_ACP_MODE         ok | hang | crash | permission          (default: ok)
  FAKE_ACP_READY        path touched once trap-protected
  FAKE_ACP_ARGV_OUT     path to write argv to, one element per line
  FAKE_ACP_STOP_REASON  default: end_turn
"""
import json
import os
import signal
import sys

MODE = os.environ.get("FAKE_ACP_MODE", "ok")
STOP_REASON = os.environ.get("FAKE_ACP_STOP_REASON", "end_turn")
SESSION_ID = "sess-fake-0001"

# Trap first, before anything else can fail: a child that outlives its parent holding the
# runner's stdout pipe open is how a test suite stops terminating.
signal.signal(signal.SIGTERM, lambda *_: sys.exit(143))
signal.signal(signal.SIGINT, lambda *_: sys.exit(130))

if path := os.environ.get("FAKE_ACP_ARGV_OUT"):
    with open(path, "w") as fh:
        fh.write("\n".join(sys.argv[1:]))

if path := os.environ.get("FAKE_ACP_READY"):
    open(path, "w").close()


def write(message):
    sys.stdout.write(json.dumps(message) + "\n")
    sys.stdout.flush()


def reply(request_id, result):
    write({"jsonrpc": "2.0", "id": request_id, "result": result})


def notify(update):
    write({"jsonrpc": "2.0", "method": "session/update",
           "params": {"sessionId": SESSION_ID, "update": update}})


def fixture():
    path = os.environ.get("FAKE_ACP_FIXTURE")
    if not path:
        return []
    with open(path) as fh:
        return json.load(fh)


def handle(message):
    method, request_id = message.get("method"), message.get("id")

    if method == "initialize":
        reply(request_id, {
            "protocolVersion": 1,
            "agentCapabilities": {"sessionCapabilities": {}},
            "agentInfo": {"name": "fake-acp", "version": "0.0.1"},
            "authMethods": [],
        })
    elif method == "session/new":
        reply(request_id, {
            "sessionId": SESSION_ID,
            "modes": {"currentModeId": "default", "availableModes": [
                {"id": "default", "name": "Manual"},
                {"id": "bypassPermissions", "name": "Bypass Permissions"},
            ]},
        })
    elif method == "session/set_config_option":
        notify({"sessionUpdate": "current_mode_update",
                "currentModeId": message["params"].get("value")})
        reply(request_id, {"configOptions": []})
    elif method == "session/prompt":
        if MODE == "hang":
            return                      # never answer; the caller's timeout is the test
        if MODE == "crash":
            sys.exit(9)
        if MODE == "permission":
            # The client MUST answer this. A double that asks is how the answering path is tested.
            write({"jsonrpc": "2.0", "id": 9001, "method": "session/request_permission",
                   "params": {"sessionId": SESSION_ID,
                              "toolCall": {"toolCallId": "tc-1"},
                              "options": [
                                  {"optionId": "allow", "name": "Allow", "kind": "allow_once"},
                                  {"optionId": "deny", "name": "Deny", "kind": "reject_once"},
                              ]}})
        for update in fixture():
            notify(update)
        reply(request_id, {"stopReason": STOP_REASON})
    elif method == "session/cancel":
        pass                            # a notification; nothing to answer
    elif request_id is not None:
        write({"jsonrpc": "2.0", "id": request_id,
               "error": {"code": -32601, "message": f"fake-acp does not implement {method}"}})


for line in sys.stdin:                  # ends when the client closes stdin — that is the exit
    line = line.strip()
    if not line:
        continue
    try:
        handle(json.loads(line))
    except json.JSONDecodeError:
        write({"jsonrpc": "2.0", "id": None,
               "error": {"code": -32700, "message": "parse error"}})
```

- [ ] **Step 3: Make it executable and drive it by hand**

```bash
chmod +x Scripts/fake-acp.py
printf '%s\n%s\n' \
  '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":1}}' \
  '{"jsonrpc":"2.0","id":2,"method":"session/new","params":{"cwd":"/tmp","mcpServers":[]}}' \
  | python3 Scripts/fake-acp.py
```

Expected: two JSON lines on stdout, the first with `"protocolVersion": 1` and
`"name": "fake-acp"`, the second with `"sessionId": "sess-fake-0001"`. The process then exits
because stdin closed.

- [ ] **Step 4: Drive a full turn by hand**

```bash
printf '%s\n%s\n%s\n' \
  '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":1}}' \
  '{"jsonrpc":"2.0","id":2,"method":"session/new","params":{"cwd":"/tmp","mcpServers":[]}}' \
  '{"jsonrpc":"2.0","id":3,"method":"session/prompt","params":{"sessionId":"sess-fake-0001","prompt":[{"type":"text","text":"go"}]}}' \
  | FAKE_ACP_FIXTURE=Fixtures/acp/fake-simple-turn.json python3 Scripts/fake-acp.py \
  | python3 -c "import sys,json; [print(json.loads(l).get('method') or 'response') for l in sys.stdin]"
```

Expected: `response`, `response`, then seven `session/update` lines, then `response`.

- [ ] **Step 5: Commit**

```bash
git rev-parse --abbrev-ref HEAD
git add Scripts/fake-acp.py Fixtures/acp/fake-simple-turn.json
git commit -m "test(process): an ACP double that answers, because ACP is a conversation

fake-claude.sh prints and exits, which is enough for a one-shot CLI and not
enough for a protocol. This reads JSON-RPC on stdin and replies, replaying a
fixture of session/update frames on session/prompt.

The fixture reproduces the partial-patch shape measured from the real
adapter: status, kind and title are each absent from at least one later
frame, so a fold that replaces rather than merges cannot pass."
```

---

### Task 7: End to end through the double

**Files:**
- Create: `ElliotKit/Tests/ElliotProcessTests/ACPSessionTests.swift`

**Interfaces:**
- Consumes: `ACPTransport`, `ACPAgentProcess` (Task 4); `Client` (Task 5); `Scripts/fake-acp.py`
  and `Fixtures/acp/fake-simple-turn.json` (Task 6).
- Produces: nothing further — this is the stage's acceptance test.

- [ ] **Step 1: Write the failing test**

```swift
import ACP
import ACPModel
import Foundation
import Testing
import TestSupport

@testable import ElliotProcess

/// The whole of Stage 0, end to end: a real child process, real JSON-RPC framing, a real
/// request/response correlation, and a real notification stream — with a double standing in for
/// the agent so the suite stays deterministic and needs no network, no tokens and no GitHub.
@Suite("ACP session")
struct ACPSessionTests {
    static var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // ElliotProcessTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // ElliotKit
            .deletingLastPathComponent()   // repository root
    }

    static func agent(mode: String = "ok") -> ACPAgentProcess {
        ACPAgentProcess(
            executable: "/usr/bin/python3",
            arguments: [repositoryRoot.appendingPathComponent("Scripts/fake-acp.py").path],
            cwd: "/tmp",
            environment: [
                "FAKE_ACP_MODE": mode,
                "FAKE_ACP_FIXTURE": repositoryRoot
                    .appendingPathComponent("Fixtures/acp/fake-simple-turn.json").path,
            ]
        )
    }

    @Test("a full turn: initialize, new session, set the mode, prompt, collect updates")
    func fullTurn() async throws {
        let transport = try ACPTransport(Self.agent())
        let client = Client(transport: transport)
        defer { transport.terminate() }

        let updates = Task {
            var collected: [SessionUpdateNotification] = []
            for await notification in await client.notifications {
                guard notification.method == "session/update" else { continue }
                collected.append(try! JSONDecoder().decode(
                    SessionUpdateNotification.self,
                    from: JSONEncoder().encode(notification.params)
                ))
                if collected.count == 8 { break }   // 1 mode + 7 fixture frames
            }
            return collected
        }

        let initialize = try await withTimeout(.seconds(10)) {
            try await client.initialize(protocolVersion: 1)
        }
        #expect(initialize.agentInfo?.name == "fake-acp")

        let session = try await withTimeout(.seconds(10)) {
            try await client.newSession(cwd: "/tmp", mcpServers: [])
        }
        #expect(session.sessionId.value == "sess-fake-0001")

        _ = try await withTimeout(.seconds(10)) {
            try await client.setConfigOption(
                sessionId: session.sessionId, configId: "mode", value: "bypassPermissions"
            )
        }

        let prompt = try await withTimeout(.seconds(20)) {
            try await client.sendPrompt(
                sessionId: session.sessionId, prompt: [.text("go")]
            )
        }
        #expect(prompt.stopReason == .endTurn)

        let collected = try await withTimeout(.seconds(10)) { await updates.value }
        #expect(collected.count == 8)
    }

    /// The shape the design's §5.1 calls out, pinned against the double rather than described.
    ///
    /// Four frames for one tool call, three of which omit a field an earlier one carried. A fold
    /// that *replaces* the row instead of merging it would finish with no title and no kind — and
    /// this is the test that would not let that ship.
    @Test("one tool call arrives as four frames, each carrying only what changed")
    func toolCallPatchesArrivePartial() async throws {
        let transport = try ACPTransport(Self.agent())
        let client = Client(transport: transport)
        defer { transport.terminate() }

        let frames = Task { () -> [ToolCallUpdate] in
            var collected: [ToolCallUpdate] = []
            for await notification in await client.notifications {
                guard notification.method == "session/update" else { continue }
                let note = try! JSONDecoder().decode(
                    SessionUpdateNotification.self,
                    from: JSONEncoder().encode(notification.params)
                )
                switch note.update {
                case .toolCall(let call) where call.toolCallId == "tc-1":
                    collected.append(call)
                case .toolCallUpdate(let call) where call.toolCallId == "tc-1":
                    collected.append(call)
                default:
                    continue
                }
                if collected.count == 4 { break }
            }
            return collected
        }

        _ = try await withTimeout(.seconds(10)) { try await client.initialize(protocolVersion: 1) }
        let session = try await withTimeout(.seconds(10)) {
            try await client.newSession(cwd: "/tmp", mcpServers: [])
        }
        _ = try await withTimeout(.seconds(20)) {
            try await client.sendPrompt(sessionId: session.sessionId, prompt: [.text("go")])
        }

        let collected = try await withTimeout(.seconds(10)) { await frames.value }
        #expect(collected.count == 4)

        // Frame 1 creates it: a generic title, a kind, a status.
        #expect(collected[0].title == "Edit")
        #expect(collected[0].kind == .edit)
        #expect(collected[0].status == .pending)

        // Frame 2 refines the title and adds a location — and carries NO status.
        #expect(collected[1].title == "Edit /tmp/notes.txt")
        #expect(collected[1].locations?.first?.path == "/tmp/notes.txt")
        #expect(collected[1].status == nil)

        // Frame 3 is content only. Every other field is absent, which is the trap.
        #expect(collected[2].title == nil)
        #expect(collected[2].kind == nil)
        #expect(collected[2].status == nil)
        #expect(collected[2].content?.isEmpty == false)

        // Frame 4 completes it, and carries nothing else at all.
        #expect(collected[3].status == .completed)
        #expect(collected[3].title == nil)
        #expect(collected[3].kind == nil)
    }
}
```

⚠️ `ToolCallUpdate`, the `.toolCall` / `.toolCallUpdate` case names, `ToolKind.edit` and
`ToolStatus.pending` are upstream's — read them in `ACPModel` and match. If upstream models creation
and update as one type, collapse the `switch` accordingly; the assertions are what matter.

⚠️ `client.notifications`, `newSession`, `setConfigOption`, `sendPrompt` and `ContentBlock.text`
signatures are upstream's — read them at `Client.swift:86, 176, 329, 201` and match exactly. Adjust
the calls above rather than adapting the library.

- [ ] **Step 2: Run and watch it fail**

```bash
cd ElliotKit && swift test --filter ACPSessionTests
```

Expected: compile failures naming any signature that does not match upstream. Fix the **test**, not
the library.

- [ ] **Step 3: Iterate to green**

```bash
cd ElliotKit && swift test --filter ACPSessionTests
```

Expected: 2 tests PASS.

- [ ] **Step 4: Prove the double can hang, and that the timeout catches it**

Temporarily change `Self.agent()` to `Self.agent(mode: "hang")` in the first test and run:

```bash
cd ElliotKit && swift test --filter ACPSessionTests
```

Expected: `fullTurn` fails on the `sendPrompt` timeout after 20 s — **not** an indefinite hang. That
is the point of `withTimeout` and this is where it is proved. Restore `mode: "ok"`.

- [ ] **Step 5: Sample five times under load**

A single sample cannot detect an intermittent regression; a defect failing 53 % of the time once
reached `main` past 21 single-sample merges. One flake here was 1-in-13 idle and 6-in-10 under load.

```bash
cd ElliotKit && swift build --build-tests > /dev/null 2>&1
for i in 1 2 3 4 5; do swift test 2>&1 | tail -1; done
```

Expected: five identical passing lines.

- [ ] **Step 6: Commit**

```bash
git rev-parse --abbrev-ref HEAD
git add ElliotKit/Tests/ElliotProcessTests/ACPSessionTests.swift
git commit -m "test(process): Stage 0 end to end, against a double rather than a token

A real child, real newline framing, real request/response correlation and a
real notification stream — with fake-acp.py standing in for the agent, so the
suite stays deterministic and needs no network, no tokens and no GitHub.

The second test pins the partial-patch shape: four frames for one tool call,
three of which omit fields an earlier one carried."
```

---

### Task 8: Take the two measurements the design left open

Not a code task. These are the two `UNMEASURED` items the spec names, and Stage 0 is where they get
answered — before anything is built on top of them.

**Files:**
- Modify: `docs/superpowers/specs/2026-08-12-elliot-acp-design.md` (§2.2 and §5.4)
- Create: `Fixtures/acp/turn-skill-invocation.json`, `Fixtures/acp/turn-refusal.json`

**Interfaces:**
- Consumes: `Scripts/probe/acp_turn.py` (committed in `11637dc`).
- Produces: two recorded transcripts and two spec sections that no longer say UNMEASURED.

- [ ] **Step 1: Measure whether a plugin skill actually invokes**

⛔ **Not against a real repository** — `create-issue` files a real GitHub issue. Use a throwaway
checkout with no `origin`, and a skill whose failure is harmless. `get-repo-profile` is the right
one: it reads the repository and writes `.claude/skills/repo-profile.md`, and in a scratch checkout
that costs nothing.

```bash
rm -rf /tmp/elliot-acp-skill && mkdir -p /tmp/elliot-acp-skill
cd /tmp/elliot-acp-skill && git init -q && echo '# scratch' > README.md
git add -A && git -c user.email=probe@local -c user.name=probe commit -qm init
```

Then from the Elliot worktree:

```bash
export ACP_CWD=/tmp/elliot-acp-skill
export ACP_MODE=bypassPermissions
export ACP_PROMPT='/ai-migration-kit:get-repo-profile'
export ACP_DUMP=/tmp/acp-skill.json
export ACP_TURN_WAIT=900
python3 Scripts/probe/acp_turn.py
```

Record: whether any `tool_call` carries `_meta.claudeCode.toolName == "Skill"`, whether
`.claude/skills/repo-profile.md` exists afterwards, and the `stopReason`.

```bash
test -f /tmp/elliot-acp-skill/.claude/skills/repo-profile.md && echo "SKILL RAN" || echo "SKILL DID NOT RUN"
```

- [ ] **Step 2: Measure what a refusal looks like under `bypassPermissions`**

The design keeps `RunState.completedWithDenials` pending this. Provoke a real refusal with a
`PreToolUse` hook that denies, in the scratch checkout:

```bash
mkdir -p /tmp/elliot-acp-skill/.claude
cat > /tmp/elliot-acp-skill/.claude/settings.json <<'JSON'
{
  "hooks": {
    "PreToolUse": [
      {"matcher": "Bash",
       "hooks": [{"type": "command",
                  "command": "echo '{\"decision\":\"block\",\"reason\":\"probe: denied on purpose\"}'"}]}
    ]
  }
}
JSON
```

```bash
export ACP_CWD=/tmp/elliot-acp-skill
export ACP_MODE=bypassPermissions
export ACP_PROMPT='Run `echo hello` with the Bash tool and tell me what it printed.'
export ACP_DUMP=/tmp/acp-refusal.json
python3 Scripts/probe/acp_turn.py
```

Record: whether a `session/request_permission` arrived (the probe counts them), what
`tool_call_update.status` the Bash call ended on, and the `stopReason`.

- [ ] **Step 3: Commit the transcripts and rewrite the two spec sections**

```bash
cp /tmp/acp-skill.json Fixtures/acp/turn-skill-invocation.json
cp /tmp/acp-refusal.json Fixtures/acp/turn-refusal.json
```

In the spec, replace §2.2's *"Advertised is not invoked … is **UNMEASURED**"* paragraph and §5.4's
*"Decision: probe before freezing"* paragraph with what the two runs actually showed — including
`[M]` tags and the date. ⛔ If a probe fails to establish something, say so and keep the word
UNMEASURED. Do not convert an inference into a measurement.

- [ ] **Step 4: Commit**

```bash
git rev-parse --abbrev-ref HEAD
git add Fixtures/acp docs/superpowers/specs/2026-08-12-elliot-acp-design.md
git commit -m "docs: close the two measurements Stage 0 existed to take

Skill invocation end to end and what a refusal looks like under
bypassPermissions were the two UNMEASURED items the design named as
load-bearing. Both transcripts are committed beside the earlier ones."
```

---

### Task 9: Write the `Logger` correction back into the spec

The spec's §3.4 lists `ACP/Utilities/Logger.swift` as a cut. Measured afterwards: `Client.swift`
depends on it, so cutting it breaks the file this whole stage is about. A plan that silently
contradicts its spec leaves the next reader with two documents and no way to tell which is current.

**Files:**
- Modify: `docs/superpowers/specs/2026-08-12-elliot-acp-design.md` §3.4

- [ ] **Step 1: Amend the cut table**

Replace the `ACP/Utilities/Logger` row of §3.4's table with:

```markdown
| `ACP/Utilities/Logger` | ✅ **keep, repointed** | Measured after this document was first written: `Client.swift` and `FileSystemDelegate.swift` reference it, so cutting it breaks the one file this stage is about. Its 12 mutable statics are made immutable and its subsystem moves from `com.acp` to `dev.phmatray.elliot`, which serves the stated intent — one logging story — at no cost. |
```

- [ ] **Step 2: Commit**

```bash
git rev-parse --abbrev-ref HEAD
git add docs/superpowers/specs/2026-08-12-elliot-acp-design.md
git commit -m "docs: keep the vendored logger, which Client depends on

§3.4 listed it as a cut. Client.swift and FileSystemDelegate.swift reference
it, so the cut would have broken the file the stage exists to reach. Kept,
statics made immutable, subsystem repointed to ours."
```

---

## What Stage 0 deliberately does not do

Named so a reviewer does not look for them, and so the next plan knows what it inherits:

- **No `RunEvent`.** `StreamEvent` is untouched and still the only event model. Translating ACP
  frames into a neutral model is the next plan's first task.
- **No card changes.** Nothing in `ElliotAppKit` moves; no diff renders anywhere yet.
- **No `RunScheduler` change.** `ClaudeRunner` is untouched and still spawns every run.
- **No migrations, no `elliotProtocolVersion` bump.** No persisted shape changes here.
- **No Preflight rows.** Node and `npx` discovery arrive with the runner that needs them.
- **The permission responder is not written**, only measured (Task 8). At `bypassPermissions` it was
  measured never to be called; the policy that stands behind that belongs to the next plan.
