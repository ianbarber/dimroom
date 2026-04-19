// swift-tools-version: 5.10

import PackageDescription

let package = Package(
    name: "UI",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "UI", targets: ["UI"]),
    ],
    dependencies: [
        .package(path: "../Catalog"),
        .package(path: "../DriveClient"),
        .package(path: "../EditEngine"),
        .package(path: "../ImportKit"),
        .package(path: "../Previews"),
        .package(path: "../TestSupport"),
    ],
    targets: [
        .target(
            name: "UI",
            dependencies: [
                .product(name: "Catalog", package: "Catalog"),
                .product(name: "DriveClient", package: "DriveClient"),
                .product(name: "EditEngine", package: "EditEngine"),
                .product(name: "ImportKit", package: "ImportKit"),
                .product(name: "Previews", package: "Previews"),
            ]
        ),
        .testTarget(
            name: "UITests",
            dependencies: [
                "UI",
                .product(name: "Catalog", package: "Catalog"),
                .product(name: "DriveClient", package: "DriveClient"),
                .product(name: "EditEngine", package: "EditEngine"),
                .product(name: "ImportKit", package: "ImportKit"),
                .product(name: "Previews", package: "Previews"),
                .product(name: "TestSupport", package: "TestSupport"),
            ],
            exclude: ["__Snapshots__"],
            resources: [
                .copy("Fixtures"),
            ]
        ),
    ]
)
