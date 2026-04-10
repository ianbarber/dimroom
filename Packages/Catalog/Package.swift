// swift-tools-version: 5.10

import PackageDescription

let package = Package(
    name: "Catalog",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "Catalog", targets: ["Catalog"]),
    ],
    targets: [
        .target(name: "Catalog"),
        .testTarget(name: "CatalogTests", dependencies: ["Catalog"]),
    ]
)
