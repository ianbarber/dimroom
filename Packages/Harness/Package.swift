// swift-tools-version: 5.10

import PackageDescription

let package = Package(
    name: "Harness",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "Harness", targets: ["Harness"]),
        .executable(name: "dimroom-cli", targets: ["DimroomCLI"]),
        .executable(name: "dimroom-fixture", targets: ["DimroomFixture"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.3.0"),
        .package(path: "../Catalog"),
        .package(path: "../Previews"),
    ],
    targets: [
        .target(name: "Harness"),
        .executableTarget(
            name: "DimroomCLI",
            dependencies: [
                "Harness",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .executableTarget(
            name: "DimroomFixture",
            dependencies: [
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "Catalog", package: "Catalog"),
                .product(name: "Previews", package: "Previews"),
            ]
        ),
        .testTarget(
            name: "HarnessTests",
            dependencies: [
                "Harness",
                .product(name: "Catalog", package: "Catalog"),
            ]
        ),
    ]
)
