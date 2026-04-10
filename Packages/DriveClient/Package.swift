// swift-tools-version: 5.10

import PackageDescription

let package = Package(
    name: "DriveClient",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "DriveClient", targets: ["DriveClient"]),
    ],
    targets: [
        .target(name: "DriveClient"),
        .testTarget(name: "DriveClientTests", dependencies: ["DriveClient"]),
    ]
)
