// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "ElliotKit",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "ElliotModel", targets: ["ElliotModel"]),
    ],
    targets: [
        .target(name: "ElliotModel"),
        .testTarget(name: "ElliotModelTests", dependencies: ["ElliotModel"]),
    ],
    swiftLanguageModes: [.v6]
)
