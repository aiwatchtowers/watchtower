// swift-tools-version: 5.10

import PackageDescription

let package = Package(
    name: "WatchtowerKit",
    platforms: [
        .macOS(.v14),
        .iOS(.v17),
    ],
    products: [
        .library(name: "WatchtowerKit", targets: ["WatchtowerKit"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift", from: "7.0.0"),
    ],
    targets: [
        .target(
            name: "WatchtowerKit",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
            ]
        ),
        .testTarget(
            name: "WatchtowerKitTests",
            dependencies: ["WatchtowerKit"]
        ),
    ]
)
