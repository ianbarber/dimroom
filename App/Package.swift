// swift-tools-version: 5.10

import PackageDescription

let package = Package(
    name: "Dimroom",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(path: "../Packages/Harness"),
    ],
    targets: [
        .executableTarget(
            name: "Dimroom",
            dependencies: [
                .product(name: "Harness", package: "Harness"),
            ],
            path: "Sources"
        ),
    ]
)
