// swift-tools-version: 5.10

import PackageDescription

// Two products (mobile POC spec §2.1):
// - WatchtowerSync: the model-free sync core (Sync, CloudKitTransport, the
//   Relay payloads and coder, ReplicaStore, ReplicaHydrator). The Desktop
//   executable target depends on this product only.
// - WatchtowerKit: the phone-only decode mirrors and UI-facing helpers,
//   layered on WatchtowerSync.
// - WatchtowerE2ETesting: a test hub and a test phone sharing one pairing
//   (F25). Linked ONLY by test targets (the Kit's, the Desktop's and the
//   phone's); no app or extension target links it.
let package = Package(
    name: "WatchtowerKit",
    platforms: [
        .macOS(.v14),
        .iOS(.v17),
    ],
    products: [
        .library(name: "WatchtowerSync", targets: ["WatchtowerSync"]),
        .library(name: "WatchtowerKit", targets: ["WatchtowerKit"]),
        .library(name: "WatchtowerE2ETesting", targets: ["WatchtowerE2ETesting"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift", from: "7.0.0"),
    ],
    targets: [
        .target(
            name: "WatchtowerSync",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
            ]
        ),
        .target(
            name: "WatchtowerKit",
            dependencies: [
                "WatchtowerSync",
                .product(name: "GRDB", package: "GRDB.swift"),
            ]
        ),
        .target(
            name: "WatchtowerE2ETesting",
            dependencies: ["WatchtowerSync"]
        ),
        .testTarget(
            name: "WatchtowerSyncTests",
            dependencies: [
                "WatchtowerSync",
                "WatchtowerE2ETesting",
                .product(name: "GRDB", package: "GRDB.swift"),
            ]
        ),
        .testTarget(
            name: "WatchtowerKitTests",
            dependencies: [
                "WatchtowerKit",
                "WatchtowerSync",
                "WatchtowerE2ETesting",
                .product(name: "GRDB", package: "GRDB.swift"),
            ]
        ),
    ]
)
