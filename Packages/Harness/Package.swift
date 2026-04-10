// swift-tools-version: 5.10

import PackageDescription

let package = Package(
    name: "Harness",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "Harness", targets: ["Harness"]),
        .executable(name: "dimroom-cli", targets: ["DimroomCLI"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.3.0"),
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
        .testTarget(name: "HarnessTests", dependencies: ["Harness"]),
    ]
)
