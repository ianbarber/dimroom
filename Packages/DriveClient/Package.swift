// swift-tools-version: 5.10

import PackageDescription

let package = Package(
    name: "DriveClient",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "DriveClient", targets: ["DriveClient"]),
        .library(name: "DriveTestSupport", targets: ["DriveTestSupport"]),
    ],
    targets: [
        .target(name: "DriveClient"),
        .target(name: "DriveTestSupport", dependencies: ["DriveClient"]),
        .testTarget(
            name: "DriveClientTests",
            dependencies: [
                "DriveClient",
                "DriveTestSupport",
            ]
        ),
    ]
)
