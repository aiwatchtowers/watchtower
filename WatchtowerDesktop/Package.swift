// swift-tools-version: 5.10

import PackageDescription

let package = Package(
    name: "WatchtowerDesktop",
    platforms: [
        .macOS(.v14),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift", from: "7.0.0"),
        // Markdown AST for the shared chat renderer (tables, task lists, fences).
        .package(url: "https://github.com/swiftlang/swift-markdown.git", from: "0.5.0"),
        .package(url: "https://github.com/jpsim/Yams", from: "5.0.0"),
        .package(url: "https://github.com/nalexn/ViewInspector", from: "0.10.0"),
        // Pinned to 0.18.x: WhisperKitEngine uses 0.18.0-specific API surface
        // (including the misspelled `detectLangauge(audioArray:)`).
        .package(url: "https://github.com/argmaxinc/WhisperKit.git", .upToNextMinor(from: "0.18.0")),
        // Pinned to 0.15.x: ParakeetProvider uses AsrManager/AsrModels API verified
        // against the v0.15.5 tag, and FluidAudioDiarizer uses the diarizer API
        // surface (DiarizerModels.downloadIfNeeded, performCompleteDiarization).
        // Known cosmetic build warning from the dependency itself ("found 1
        // file(s) which are unhandled": their ASR/Parakeet/Unified/benchmark.md
        // is not excluded in FluidAudio's own manifest, unfixed upstream as of
        // v0.15.5/main) — harmless, cannot be silenced from this manifest.
        .package(url: "https://github.com/FluidInference/FluidAudio.git", .upToNextMinor(from: "0.15.5")),
        // Pinned to the exact 0.0.7 tag: the only speech-swift releases that keep the
        // macOS(.v14) platform floor (0.0.1-0.0.7) — 0.0.8+ requires macOS 15 (MLXState),
        // and 0.0.20+ additionally pulls in `WhisperKit >=1.0.0`, which conflicts with our
        // WhisperKitProvider pin to the 0.18.x API surface. See task-7-report.md.
        .package(url: "https://github.com/soniqo/speech-swift.git", exact: "0.0.7"),
    ],
    targets: [
        .target(
            name: "WatchtowerCore",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "Yams", package: "Yams"),
                .product(name: "Markdown", package: "swift-markdown"),
            ],
            path: "Sources/WatchtowerCore"
        ),
        // The OCR recognizer behind the `watchtower-ocr` helper the Go CLI
        // runs on scanned attachment pages. Vision + CoreGraphics + ImageIO
        // only: no GRDB, no ML stack, so the helper stays small and touches
        // nothing but the file it is handed.
        .target(
            name: "OCRKit",
            path: "Sources/OCRKit"
        ),
        .executableTarget(
            name: "watchtower-ocr",
            dependencies: ["OCRKit"],
            path: "Sources/OCRHelper"
        ),
        .executableTarget(
            name: "WatchtowerDesktop",
            dependencies: [
                "WatchtowerCore",
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "Yams", package: "Yams"),
                .product(name: "WhisperKit", package: "WhisperKit"),
                .product(name: "FluidAudio", package: "FluidAudio"),
                .product(name: "Qwen3ASR", package: "speech-swift"),
            ],
            path: "Sources",
            exclude: ["WatchtowerCore", "OCRKit", "OCRHelper"],
            resources: [
                .process("Resources"),
            ]
        ),
        .target(
            name: "WatchtowerTestSupport",
            dependencies: [
                "WatchtowerCore",
                .product(name: "GRDB", package: "GRDB.swift"),
            ],
            path: "Tests/Support"
        ),
        .testTarget(
            name: "WatchtowerCoreTests",
            dependencies: [
                "WatchtowerCore",
                "WatchtowerTestSupport",
                .product(name: "GRDB", package: "GRDB.swift"),
            ],
            path: "Tests/Core"
        ),
        .testTarget(
            name: "OCRKitTests",
            dependencies: ["OCRKit"],
            path: "Tests/OCRHelperTests"
        ),
        .testTarget(
            name: "WatchtowerDesktopTests",
            dependencies: [
                "WatchtowerDesktop",
                "WatchtowerCore",
                "WatchtowerTestSupport",
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "ViewInspector", package: "ViewInspector"),
            ],
            path: "Tests",
            exclude: ["Core", "Support", "OCRHelperTests"]
        ),
    ]
)
