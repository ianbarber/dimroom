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
        .package(path: "../Packages/SyncEngine"),
        .package(path: "../Packages/AppIcon"),
        .package(path: "../Packages/TestSupport"),
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
                .product(name: "SyncEngine", package: "SyncEngine"),
                .product(name: "AppIcon", package: "AppIcon"),
            ],
            path: "Sources",
            resources: [
                .copy("Resources/AppIcon.icns"),
            ]
        ),
        .testTarget(
            name: "DimroomTests",
            dependencies: [
                "Dimroom",
                .product(name: "Catalog", package: "Catalog"),
                .product(name: "DriveClient", package: "DriveClient"),
                .product(name: "Harness", package: "Harness"),
                .product(name: "Previews", package: "Previews"),
                .product(name: "SyncEngine", package: "SyncEngine"),
                .product(name: "UI", package: "UI"),
                .product(name: "TestSupport", package: "TestSupport"),
            ],
            path: "Tests",
            exclude: ["__Snapshots__"]
        ),
    ]
)
