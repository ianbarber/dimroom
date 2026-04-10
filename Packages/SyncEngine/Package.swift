// swift-tools-version: 5.10

import PackageDescription

let package = Package(
    name: "SyncEngine",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "SyncEngine", targets: ["SyncEngine"]),
    ],
    targets: [
        .target(name: "SyncEngine"),
        .testTarget(name: "SyncEngineTests", dependencies: ["SyncEngine"]),
    ]
)
