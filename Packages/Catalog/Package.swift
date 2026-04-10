// swift-tools-version: 5.10

import PackageDescription

let package = Package(
    name: "Catalog",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "Catalog", targets: ["Catalog"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "6.0.0"),
    ],
    targets: [
        .target(
            name: "Catalog",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
            ]
        ),
        .testTarget(
            name: "CatalogTests",
            dependencies: ["Catalog"]
        ),
    ]
)
