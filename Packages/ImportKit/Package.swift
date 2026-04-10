// swift-tools-version: 5.10

import PackageDescription

let package = Package(
    name: "ImportKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "ImportKit", targets: ["ImportKit"]),
    ],
    targets: [
        .target(name: "ImportKit"),
        .testTarget(name: "ImportKitTests", dependencies: ["ImportKit"]),
    ]
)
