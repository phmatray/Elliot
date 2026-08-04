// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "ElliotKit",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "ElliotModel", targets: ["ElliotModel"]),
        .library(name: "ElliotStore", targets: ["ElliotStore"]),
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
        .testTarget(name: "ElliotModelTests", dependencies: ["ElliotModel"]),
        .testTarget(name: "ElliotStoreTests", dependencies: ["ElliotStore"]),
    ],
    swiftLanguageModes: [.v6]
)
