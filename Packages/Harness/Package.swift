// swift-tools-version: 5.10

import PackageDescription

let package = Package(
    name: "Harness",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "Harness", targets: ["Harness"]),
    ],
    targets: [
        .target(name: "Harness"),
        .testTarget(name: "HarnessTests", dependencies: ["Harness"]),
    ]
)
