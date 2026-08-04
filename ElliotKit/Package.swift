// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "ElliotKit",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "ElliotModel", targets: ["ElliotModel"]),
        .library(name: "ElliotStore", targets: ["ElliotStore"]),
        .library(name: "ElliotProcess", targets: ["ElliotProcess"]),
        .library(name: "ElliotEngine", targets: ["ElliotEngine"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
    ],
    targets: [
        .target(name: "ElliotModel"),
        .target(
            name: "ElliotStore",
            dependencies: ["ElliotModel", .product(name: "GRDB", package: "GRDB.swift")]
        ),
        .target(name: "ElliotProcess", dependencies: ["ElliotModel"]),
        .target(name: "ElliotEngine", dependencies: ["ElliotModel", "ElliotStore", "ElliotProcess"]),
        .testTarget(name: "ElliotModelTests", dependencies: ["ElliotModel"]),
        .testTarget(name: "ElliotStoreTests", dependencies: ["ElliotStore"]),
        // Fixtures and the fake `claude` live at the repository root, not in a
        // resource bundle: the same files are used by hand from a terminal when
        // reproducing a run.
        .testTarget(name: "ElliotProcessTests", dependencies: ["ElliotProcess"]),
        .testTarget(name: "ElliotEngineTests", dependencies: ["ElliotEngine"]),
    ],
    swiftLanguageModes: [.v6]
)
