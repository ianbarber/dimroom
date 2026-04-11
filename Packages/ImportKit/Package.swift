// swift-tools-version: 5.10

import PackageDescription

let package = Package(
    name: "ImportKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "ImportKit", targets: ["ImportKit"]),
    ],
    dependencies: [
        .package(path: "../Catalog"),
    ],
    targets: [
        .target(
            name: "ImportKit",
            dependencies: [
                .product(name: "Catalog", package: "Catalog"),
            ],
            linkerSettings: [
                .linkedFramework("ImageIO"),
                .linkedFramework("CoreGraphics"),
            ]
        ),
        .testTarget(
            name: "ImportKitTests",
            dependencies: ["ImportKit"]
        ),
    ]
)
