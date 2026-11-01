// swift-tools-version: 5.10

import PackageDescription

// Products (mobile POC spec §2.1; the hosted relay client, #1239):
// - WatchtowerSync: the model-free sync core (Sync, CloudKitTransport, the
//   Relay payloads and coder, ReplicaStore, ReplicaHydrator). The Desktop
//   executable target takes this one of the Kit's sync products only.
// - WatchtowerKit: the phone-only decode mirrors and UI-facing helpers,
//   layered on WatchtowerSync.
// - WatchtowerDesign: the design tokens (spacing, radii, fills, strokes,
//   tones, motion) shared by the Desktop's DesignKit and the phone's
//   DesignSystem. SwiftUI only: no GRDB, no Kit types.
// - WatchtowerE2ETesting: a test hub and a test phone sharing one pairing
//   (F25). Linked ONLY by test targets (the Kit's, the Desktop's and the
//   phone's); no app or extension target links it.
// - WatchtowerHostedRelay: the hosted relay client, on the generated wire
//   types of its WatchtowerRelayProto target (relay.proto pinned in
//   Sources/WatchtowerRelayProto/VERSION, `make relay-proto`).
// - WatchtowerHostedRelayTesting: the fake relay the client's tests and the
//   phone's tests run on.
//   These hosted relay products are linked by the phone only (R3): the
//   Desktop never links them, and WatchtowerSync/WatchtowerKit never import
//   SwiftProtobuf, the proto or DeviceCheck (SeamBoundaryTests).
let package = Package(
    name: "WatchtowerKit",
    platforms: [
        .macOS(.v14),
        .iOS(.v17),
    ],
    products: [
        .library(name: "WatchtowerSync", targets: ["WatchtowerSync"]),
        .library(name: "WatchtowerKit", targets: ["WatchtowerKit"]),
        .library(name: "WatchtowerDesign", targets: ["WatchtowerDesign"]),
        .library(name: "WatchtowerE2ETesting", targets: ["WatchtowerE2ETesting"]),
        .library(name: "WatchtowerHostedRelay", targets: ["WatchtowerHostedRelay"]),
        .library(name: "WatchtowerHostedRelayTesting", targets: ["WatchtowerHostedRelayTesting"]),
    ],
    dependencies: [
        // GRDB linked against SQLCipher.swift (#603): our fork, pinned exactly.
        // The Kit, the Desktop and WatchtowerMobile/project.yml carry the same
        // URL and tag (SPM allows one GRDB in the graph), and the SQLCipher
        // version moves in lockstep with internal/sqlcipher/VERSION.
        .package(url: "https://github.com/aiwatchtowers/GRDB.swift", exact: "7.11.1-sqlcipher.2"),
        // The hosted relay's wire types (#1239). Its protoc-gen-swift
        // generated Sources/WatchtowerRelayProto/relay.pb.swift: moving this
        // pin means `make relay-proto` again (VERSION line 2 must match).
        .package(url: "https://github.com/apple/swift-protobuf", exact: "1.39.0"),
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
        .target(name: "WatchtowerDesign"),
        .target(
            name: "WatchtowerE2ETesting",
            dependencies: ["WatchtowerSync"]
        ),
        .target(
            name: "WatchtowerRelayProto",
            dependencies: [
                .product(name: "SwiftProtobuf", package: "swift-protobuf"),
            ],
            exclude: ["relay.proto", "VERSION"]
        ),
        .target(
            name: "WatchtowerHostedRelay",
            dependencies: [
                "WatchtowerSync",
                "WatchtowerRelayProto",
                .product(name: "SwiftProtobuf", package: "swift-protobuf"),
            ]
        ),
        .target(
            name: "WatchtowerHostedRelayTesting",
            dependencies: [
                "WatchtowerHostedRelay",
                "WatchtowerRelayProto",
                .product(name: "SwiftProtobuf", package: "swift-protobuf"),
            ]
        ),
        .testTarget(
            name: "WatchtowerHostedRelayTests",
            dependencies: [
                "WatchtowerHostedRelay",
                "WatchtowerHostedRelayTesting",
                "WatchtowerRelayProto",
                "WatchtowerSync",
                .product(name: "SwiftProtobuf", package: "swift-protobuf"),
                .product(name: "GRDB", package: "GRDB.swift"),
            ]
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
            name: "WatchtowerDesignTests",
            dependencies: ["WatchtowerDesign"]
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
