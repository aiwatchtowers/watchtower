// swift-tools-version: 5.10

import PackageDescription

let package = Package(
    name: "WatchtowerDesktop",
    platforms: [
        .macOS(.v14),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift", from: "7.0.0"),
        // swift-markdown removed: MarkdownText uses Foundation's AttributedString(markdown:)
        .package(url: "https://github.com/jpsim/Yams", from: "5.0.0"),
        .package(url: "https://github.com/nalexn/ViewInspector", from: "0.10.0"),
        // Pinned to 0.18.x: WhisperKitEngine uses 0.18.0-specific API surface
        // (including the misspelled `detectLangauge(audioArray:)`).
        .package(url: "https://github.com/argmaxinc/WhisperKit.git", .upToNextMinor(from: "0.18.0")),
        // Speaker diarization (pyannote/VBx on CoreML) for transcript roles.
        .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.12.0"),
    ],
    targets: [
        .executableTarget(
            name: "WatchtowerDesktop",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "Yams", package: "Yams"),
                .product(name: "WhisperKit", package: "WhisperKit"),
                .product(name: "FluidAudio", package: "FluidAudio"),
            ],
            path: "Sources",
            resources: [
                .process("Resources"),
            ]
        ),
        .testTarget(
            name: "WatchtowerDesktopTests",
            dependencies: [
                "WatchtowerDesktop",
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "ViewInspector", package: "ViewInspector"),
            ],
            path: "Tests"
        ),
    ]
)
