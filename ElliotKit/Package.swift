// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "ElliotKit",
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
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.11.1"),
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", from: "0.12.1"),
    ],
    targets: [
        .executableTarget(name: "elliot-mcp", dependencies: ["ElliotMCPKit"]),
        .executableTarget(
            name: "ElliotApp",
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
            dependencies: ["ElliotStore", .product(name: "GRDB", package: "GRDB.swift")]
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
    ],
    swiftLanguageModes: [.v6]
)
