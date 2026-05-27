// swift-tools-version: 5.10

import PackageDescription

let package = Package(
    name: "EditEngine",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "EditEngine", targets: ["EditEngine"]),
    ],
    dependencies: [
        .package(path: "../Catalog"),
        .package(path: "../TestSupport"),
    ],
    targets: [
        .target(
            name: "EditEngine",
            dependencies: ["Catalog"],
            resources: [.process("Resources")]
        ),
        .testTarget(
            name: "EditEngineTests",
            dependencies: [
                "EditEngine",
                "TestSupport",
            ],
            exclude: ["__Snapshots__"]
        ),
    ]
)
