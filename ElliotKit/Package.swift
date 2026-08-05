// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "ElliotKit",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "elliot-mcp", targets: ["elliot-mcp"]),
        .executable(name: "ElliotApp", targets: ["ElliotApp"]),
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
        .target(name: "ElliotModel"),
        .target(
            name: "ElliotStore",
            dependencies: ["ElliotModel", .product(name: "GRDB", package: "GRDB.swift")]
        ),
        .target(name: "ElliotProcess", dependencies: ["ElliotModel"]),
        .target(name: "ElliotEngine", dependencies: ["ElliotModel", "ElliotStore", "ElliotProcess"]),
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
        .testTarget(name: "ElliotStoreTests", dependencies: ["ElliotStore"]),
        // Fixtures and the fake `claude` live at the repository root, not in a
        // resource bundle: the same files are used by hand from a terminal when
        // reproducing a run.
        .testTarget(name: "ElliotProcessTests", dependencies: ["ElliotProcess", "TestSupport"]),
        .testTarget(name: "ElliotEngineTests", dependencies: ["ElliotEngine", "TestSupport"]),
        .testTarget(name: "ElliotIPCTests", dependencies: ["ElliotIPC"]),
    ],
    swiftLanguageModes: [.v6]
)
