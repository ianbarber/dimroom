// swift-tools-version: 5.10

import PackageDescription

let package = Package(
    name: "EditEngine",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "EditEngine", targets: ["EditEngine"]),
    ],
    targets: [
        .target(name: "EditEngine"),
        .testTarget(name: "EditEngineTests", dependencies: ["EditEngine"]),
    ]
)
