// swift-tools-version: 5.10

import PackageDescription

let package = Package(
    name: "Previews",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "Previews", targets: ["Previews"]),
    ],
    targets: [
        .target(name: "Previews"),
        .testTarget(name: "PreviewsTests", dependencies: ["Previews"]),
    ]
)
