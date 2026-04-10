// swift-tools-version: 5.10

import PackageDescription

let package = Package(
    name: "TestSupport",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "TestSupport", targets: ["TestSupport"]),
    ],
    dependencies: [
        .package(url: "https://github.com/pointfreeco/swift-snapshot-testing", from: "1.17.0"),
    ],
    targets: [
        .target(
            name: "TestSupport",
            dependencies: [
                .product(name: "SnapshotTesting", package: "swift-snapshot-testing"),
            ]
        ),
        .testTarget(
            name: "TestSupportTests",
            dependencies: [
                "TestSupport",
            ]
        ),
    ]
)
