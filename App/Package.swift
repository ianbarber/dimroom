// swift-tools-version: 5.10

import PackageDescription

let package = Package(
    name: "Dimroom",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(path: "../Packages/Harness"),
        .package(path: "../Packages/Catalog"),
        .package(path: "../Packages/EditEngine"),
        .package(path: "../Packages/ImportKit"),
        .package(path: "../Packages/Previews"),
        .package(path: "../Packages/UI"),
        .package(path: "../Packages/DriveClient"),
    ],
    targets: [
        .executableTarget(
            name: "Dimroom",
            dependencies: [
                .product(name: "Harness", package: "Harness"),
                .product(name: "Catalog", package: "Catalog"),
                .product(name: "EditEngine", package: "EditEngine"),
                .product(name: "ImportKit", package: "ImportKit"),
                .product(name: "Previews", package: "Previews"),
                .product(name: "UI", package: "UI"),
                .product(name: "DriveClient", package: "DriveClient"),
            ],
            path: "Sources"
        ),
        .testTarget(
            name: "DimroomTests",
            dependencies: [
                "Dimroom",
                .product(name: "Catalog", package: "Catalog"),
                .product(name: "DriveClient", package: "DriveClient"),
            ],
            path: "Tests"
        ),
    ]
)
