// swift-tools-version: 5.10

import PackageDescription

let package = Package(
    name: "AppIcon",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "AppIcon", targets: ["AppIcon"]),
        .executable(name: "dimroom-icongen", targets: ["IconGen"]),
    ],
    dependencies: [
        .package(path: "../TestSupport"),
    ],
    targets: [
        .target(
            name: "AppIcon"
        ),
        .executableTarget(
            name: "IconGen",
            dependencies: ["AppIcon"]
        ),
        .testTarget(
            name: "AppIconTests",
            dependencies: [
                "AppIcon",
                .product(name: "TestSupport", package: "TestSupport"),
            ],
            exclude: ["__Snapshots__"]
        ),
    ]
)
