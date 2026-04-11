// swift-tools-version: 5.10

import PackageDescription

let package = Package(
    name: "Previews",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "Previews", targets: ["Previews"]),
    ],
    dependencies: [
        .package(path: "../Catalog"),
    ],
    targets: [
        .target(
            name: "Previews",
            dependencies: [
                .product(name: "Catalog", package: "Catalog"),
            ],
            linkerSettings: [
                .linkedFramework("CoreImage"),
                .linkedFramework("ImageIO"),
                .linkedFramework("CoreGraphics"),
            ]
        ),
        .testTarget(
            name: "PreviewsTests",
            dependencies: ["Previews"]
        ),
    ]
)
