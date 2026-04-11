// swift-tools-version: 5.10

import PackageDescription

let package = Package(
    name: "Dimroom",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(path: "../Packages/Harness"),
        .package(path: "../Packages/Catalog"),
        .package(path: "../Packages/ImportKit"),
        .package(path: "../Packages/Previews"),
        .package(path: "../Packages/UI"),
    ],
    targets: [
        .executableTarget(
            name: "Dimroom",
            dependencies: [
                .product(name: "Harness", package: "Harness"),
                .product(name: "Catalog", package: "Catalog"),
                .product(name: "ImportKit", package: "ImportKit"),
                .product(name: "Previews", package: "Previews"),
                .product(name: "UI", package: "UI"),
            ],
            path: "Sources"
        ),
    ]
)
