// swift-tools-version: 6.3.1
//
// MEASURED, not assumed (#116). This line said 6.1 until 2026-08-07, and nothing had ever built the
// package on a 6.1 toolchain — the first CI run this repository ever had failed on one in under two
// minutes. What follows is what a build said, on real toolchains, and the runs are cited so the next
// person can re-take the measurement rather than trust this comment.
//
// Twenty-one builds across eight Apple toolchains, on the `macos-15` and `macos-26` runner images
// (runs 31167517846, 31167931727, 31170356694):
//
//   toolchain            SDK          swift build   swift build --build-tests
//   6.1.2  (Xcode 16.4)  macosx15.5   RED           RED
//   6.2    (Xcode 26.0)  macosx26.0   green         RED
//   6.2.1  (Xcode 26.1)  macosx26.1   green         RED
//   6.2.3  (Xcode 26.2)  macosx26.2   green         RED
//   6.2.4  (Xcode 26.3)  macosx26.2   green         RED
//   6.3.1  (Xcode 26.4)  macosx26.4   green         green
//   6.3.2  (Xcode 26.5)  macosx26.5   green         green
//   6.3.3  (Xcode 26.6)  macosx26.5   green         green
//
// So this package has TWO floors and they are four releases apart:
//
//   • The **build** floor is 6.2. On 6.1.2 two sites in `ElliotAppKit` fail — a `switch` over a
//     `Bool?` that 6.2 accepts as exhaustive and 6.1 does not (`AnalysisPanelView.swift:698`), and
//     `await center.notificationSettings()` returning a non-`Sendable` `UNNotificationSettings` into
//     a `@MainActor` class (`NotificationDelivery.swift:124`).
//   • The **test** floor is 6.3.1. Every 6.2.x compiler gives up on one expression —
//     `ElliotProcessTests/StreamingProcessDrainTests.swift:138`, inside a `#expect` expansion:
//     "the compiler is unable to type-check this expression in reasonable time".
//
// This line declares **6.3.1, the test floor, deliberately over the lower build floor**, and the
// reason is this issue's own purpose rather than caution. A tools-version is enforced by SwiftPM at
// *manifest parse*, before a source file is read: its job here is to turn a mysterious failure into
// a named one. The failure a 6.2 contributor would actually hit is the test one — `swift test` is
// this repository's verification gate, CLAUDE.md tells them to run it, and since #21 `ci.yml` runs
// it on every pull request as well. Declaring 6.2 would let them build, then hand them a type-check
// timeout inside a macro expansion: exactly the mystery this floor exists to prevent, one target
// over.
//
// ⚠️ That CI exists now does **not** retire this argument — it moves where the mystery would be met,
// not whether it is one. A red check arrives minutes later, on a runner the contributor cannot
// inspect, carrying the same unreadable "unable to type-check this expression in reasonable time";
// the refusal here arrives before a source file is read and names the version. `ci.yml` answers
// whether the suite passes; this line answers why you cannot run it at all, and only the second one
// is any use to someone whose toolchain is four releases short. Until #186 this paragraph reasoned
// from CI's absence instead — the same rot as the 6.1 claim this header opens with: a premise that
// was true the day it was written, and that nothing ever re-checked.
//
// **The patch component is deliberate and load-bearing — do not round this to `6.3`.** It said `6.3`
// for one commit, and that was wrong twice over: SwiftPM resolves `6.3` as **6.3.0**, and the
// measured floor is 6.3.1. Verified rather than assumed, because the first version of this comment
// asserted the opposite ("a tools-version carries no patch component") and that is simply false: a
// scratch package declaring `6.3.1` reports `6.3.1` from `swift package tools-version`, and one
// declaring `6.3.9` is refused by a 6.3.3 toolchain with *"using Swift tools version 6.3.9 but the
// installed version is 6.3.3"*. Rounding down to `6.3` therefore admits a 6.3.0 toolchain — which
// swift.org's `swift-6.3-RELEASE` reports as exactly `6.3` — to parse, build, and then hit the
// `#expect` timeout below. That is the mystery-instead-of-a-refusal this whole line exists to
// prevent, reintroduced by three characters.
//
// That makes the declared floor *sufficient* rather than *minimal*, and the gap is one expression
// wide. Break that `#expect` into sub-expressions and the two floors collapse to 6.2 — filed as its
// own change rather than smuggled in here, because it alters what the floor may be and that should
// be visible. Until then, 6.2 is recorded above as measured-green-for-`swift build`, so lowering
// this line later needs no new argument, only the follow-up landing.
//
// ⚠️ One thing these numbers do NOT separate: every toolchain moved its SDK with it, so the two
// `ElliotAppKit` diagnostics at 6.1.2 are attributable to the 6.1→6.2 compiler step, the
// macosx15→macosx26 SDK step, or both. No image pairs an old compiler with a new SDK, so it was not
// measurable here. It does not change the floor — a toolchain arrives as an Xcode, and Xcode 16.4
// does not build this package — but do not restate it as "the 6.1 *compiler* cannot".
import PackageDescription

let package = Package(
    name: "ElliotKit",
    // ⚠️ UNVERIFIED, and deliberately recorded as such (#116, criterion 5). This is a *deployment*
    // claim — the oldest macOS the built binary may run on — and it is a different question from the
    // `swift-tools-version` above, which is a *build toolchain* claim. Run 31118743562 disproved the
    // toolchain one; it says nothing whatever about this one, and conflating the two is how a claim
    // gets convicted or acquitted without evidence.
    //
    // What is measured, on 2026-08-07:
    //   • Elliot's own sources compile at `-target arm64-apple-macosx15.0` (read out of
    //     `swift build --verbose`), and both executables record `minos 15.0` in LC_BUILD_VERSION.
    //   • So Swift's availability checking has already proven every API these sources *call* exists
    //     on macOS 15 — that is what compiling green at this triple means.
    //   • And nothing bypasses that proof: `git grep -nE '(if|guard) #available|#unavailable|@available\('`
    //     over `ElliotKit/Sources` returns **nothing at all**. There is no availability guard, no
    //     `NSClassFromString`, no `responds(to:)` — no escape hatch for the checker to miss.
    //
    // What is NOT measured: whether `Elliot.app` actually *runs* there. Nobody has launched it on
    // macOS 15. Existence of an API is not its behaviour, the binaries are built against the macOS
    // 26.5 SDK, and `Scripts/build-app.sh` stamps `LSMinimumSystemVersion 15.0` on that untested
    // basis. Settling it needs a macOS 15 machine or VM, which this repository has never had.
    //
    // Left at .v15 rather than raised: raising it would be the same sin in the other direction —
    // convicting a claim no one has tested. Tracked as **issue #142** rather than left as a comment
    // nobody queries; settle it there and replace this block with what was seen.
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "elliot-mcp", targets: ["elliot-mcp"]),
        .executable(name: "ElliotApp", targets: ["ElliotApp"]),
        .executable(name: "elliot-icon", targets: ["elliot-icon"]),
        .library(name: "ElliotModel", targets: ["ElliotModel"]),
        .library(name: "ElliotStore", targets: ["ElliotStore"]),
        .library(name: "ElliotProcess", targets: ["ElliotProcess"]),
        .library(name: "ElliotEngine", targets: ["ElliotEngine"]),
        .library(name: "ElliotIPC", targets: ["ElliotIPC"]),
        .library(name: "ElliotMCPKit", targets: ["ElliotMCPKit"]),
        .library(name: "ElliotAppKit", targets: ["ElliotAppKit"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.11.1"),
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", from: "0.12.1"),
    ],
    targets: [
        .executableTarget(name: "elliot-mcp", dependencies: ["ElliotMCPKit"]),
        // Holds `@main` and the `Scene` graph, and nothing else. An
        // `executableTarget` cannot be imported, so anything left in here is
        // unreachable from `swift test` — which is how `.inspector()` shipped
        // three times without anyone seeing it work (#47 adopted it unverified,
        // #50 was the crash, #52 the layout, #53 the revert), and why
        // `MCPRequestHandler` had to be evacuated to ElliotEngine in #55.
        .executableTarget(name: "ElliotApp", dependencies: ["ElliotAppKit"]),
        // Every view and `AppModel`. A library rather than part of the
        // executable so a test target can import it: the point of the split is
        // that the app's own logic stops being unprovable.
        .target(
            name: "ElliotAppKit",
            dependencies: ["ElliotEngine", "ElliotIPC", "ElliotStore", "ElliotProcess"]
        ),
        // Renders the mark to PNGs so `Scripts/build-app.sh` can hand them to
        // `iconutil`. It draws from ElliotMark rather than owning an outline,
        // so the Dock icon and the badge in the app cannot drift apart.
        .executableTarget(name: "elliot-icon", dependencies: ["ElliotModel"]),
        .target(name: "ElliotModel"),
        .target(
            name: "ElliotStore",
            dependencies: ["ElliotModel", .product(name: "GRDB", package: "GRDB.swift")]
        ),
        .target(name: "ElliotProcess", dependencies: ["ElliotModel"]),
        // ElliotIPC for `MCPRequestHandler`, which answers the wire on the app's
        // behalf. It lives here rather than in ElliotApp because ElliotApp is an
        // executableTarget with no test target: in there, the live half of the
        // protocol was unreachable from `swift test` while the helper's offline
        // fallback was covered. The edge points down the documented order —
        // ElliotIPC depends on ElliotModel alone — so it adds no cycle.
        .target(
            name: "ElliotEngine",
            dependencies: ["ElliotModel", "ElliotStore", "ElliotProcess", "ElliotIPC"]
        ),
        .target(name: "ElliotIPC", dependencies: ["ElliotModel"]),
        // Deliberately depends on neither ElliotEngine nor ElliotProcess: the
        // helper never spawns claude and never writes the database. It cannot
        // diverge from the board because it holds no copy of the rules.
        .target(
            name: "ElliotMCPKit",
            dependencies: ["ElliotModel", "ElliotIPC", "ElliotStore", .product(name: "MCP", package: "swift-sdk")]
        ),
        // Test-only, and depends on nothing: the suites' bounded waits live
        // here so a wedged child fails its test in seconds instead of hanging
        // `swift test` — and with it the SwiftPM build lock — indefinitely.
        .target(name: "TestSupport", path: "Tests/TestSupport"),
        .testTarget(name: "TestSupportTests", dependencies: ["TestSupport"]),
        .testTarget(name: "ElliotModelTests", dependencies: ["ElliotModel"]),
        // GRDB is named rather than reached through ElliotStore: the migration
        // tests build a database at the schema an older Elliot left behind, and
        // that is raw SQL by necessity — the current record types cannot be
        // written into a table that predates one of their columns.
        .testTarget(
            name: "ElliotStoreTests",
            dependencies: [
                "ElliotStore", "TestSupport", .product(name: "GRDB", package: "GRDB.swift"),
            ]
        ),
        // Fixtures and the fake `claude` live at the repository root, not in a
        // resource bundle: the same files are used by hand from a terminal when
        // reproducing a run.
        .testTarget(name: "ElliotProcessTests", dependencies: ["ElliotProcess", "TestSupport"]),
        // `ElliotMCPKit` here is a **test**-target edge and nothing more: this is
        // the only target that can see both halves of the wire's read path, so
        // it is the only place `OfflineParityTests` can drive one seeded board
        // through `MCPRequestHandler.handle` and `OfflineResponder.respond` and
        // compare the bytes. The source-target invariant is untouched —
        // `ElliotMCPKit` still depends on neither `ElliotEngine` nor
        // `ElliotProcess`, so the helper still holds no copy of the rules.
        .testTarget(
            name: "ElliotEngineTests",
            dependencies: ["ElliotEngine", "ElliotMCPKit", "TestSupport"]
        ),
        // Reaches past the wire into the helper that speaks it: the analysis
        // cases are asserted round-trip, so the encoder and the tool that emits
        // it are proven against each other rather than separately.
        .testTarget(
            name: "ElliotIPCTests",
            dependencies: ["ElliotIPC", "ElliotMCPKit", .product(name: "MCP", package: "swift-sdk")]
        ),
        // Drives the tools through `BridgeProviding`, so the offline branches —
        // the ones that never run on a machine where Elliot is up — are reached
        // without a socket and without an app.
        // TestSupport for `TestHome`, not for its waits: these tests resolve
        // `StoreLocation` paths, and touching the shared home first is what
        // stops the process-global `ELLIOT_HOME` moving between a write and
        // the read that follows it.
        .testTarget(name: "ElliotMCPKitTests", dependencies: ["ElliotMCPKit", "TestSupport"]),
        // Covers `AppModel` where it decides rather than where it renders. It
        // held 800 lines and no tests until the split above made it reachable.
        .testTarget(name: "ElliotAppKitTests", dependencies: ["ElliotAppKit", "TestSupport"]),
    ],
    swiftLanguageModes: [.v6]
)
