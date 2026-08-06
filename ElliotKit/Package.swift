// swift-tools-version: 6.1
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
        .testTarget(name: "ElliotEngineTests", dependencies: ["ElliotEngine", "TestSupport"]),
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
