// swift-tools-version: 5.10

import PackageDescription

let package = Package(
    name: "SyncEngine",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "SyncEngine", targets: ["SyncEngine"]),
    ],
    dependencies: [
        .package(path: "../Catalog"),
        .package(path: "../DriveClient"),
    ],
    targets: [
        .target(
            name: "SyncEngine",
            dependencies: [
                .product(name: "Catalog", package: "Catalog"),
                .product(name: "DriveClient", package: "DriveClient"),
            ]
        ),
        .testTarget(
            name: "SyncEngineTests",
            dependencies: [
                "SyncEngine",
                .product(name: "DriveTestSupport", package: "DriveClient"),
            ]
        ),
    ]
)
