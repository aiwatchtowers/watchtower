// swift-tools-version: 5.10

import PackageDescription

let package = Package(
    name: "WatchtowerDesktop",
    platforms: [
        .macOS(.v14),
    ],
    dependencies: [
        // GRDB linked against SQLCipher.swift (#603): our fork, pinned exactly.
        // The Kit, the Desktop and WatchtowerMobile/project.yml carry the same
        // URL and tag (SPM allows one GRDB in the graph), and the SQLCipher
        // version moves in lockstep with internal/sqlcipher/VERSION.
        .package(url: "https://github.com/aiwatchtowers/GRDB.swift", exact: "7.11.1-sqlcipher.2"),
        // Markdown AST for the shared chat renderer (tables, task lists, fences).
        .package(url: "https://github.com/swiftlang/swift-markdown.git", from: "0.5.0"),
        // Embedded terminal for the Workbench tab (Claude Code in the project
        // folder). MIT. App target only — WatchtowerCore stays AppKit-free.
        .package(url: "https://github.com/migueldeicaza/SwiftTerm", from: "1.20.0"),
        .package(url: "https://github.com/jpsim/Yams", from: "5.0.0"),
        .package(url: "https://github.com/nalexn/ViewInspector", from: "0.10.0"),
        // The shared mobile Kit (mobile POC). Only the app target takes its
        // model-free WatchtowerSync product and DesignKit its token module
        // WatchtowerDesign; WatchtowerCore stays Kit-free (pinned by
        // PublicAPISurfaceTests).
        .package(path: "../WatchtowerKit"),
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
        // The Desktop design kit (button styles, rows, panels; the tokens come
        // from the Kit's WatchtowerDesign, re-exported): SwiftUI only, so the
        // gallery window can build without the app.
        .target(
            name: "DesignKit",
            dependencies: [
                .product(name: "WatchtowerDesign", package: "WatchtowerKit"),
            ],
            path: "Sources/DesignKit"
        ),
        // The gallery's views over the kit; never linked into the app.
        .target(
            name: "DesignKitCatalog",
            dependencies: ["DesignKit"],
            path: "Sources/DesignKitCatalog"
        ),
        // The gallery window (`make design-gallery`): a thin @main over the
        // catalog, never built into the app.
        .executableTarget(
            name: "DesignGallery",
            dependencies: ["DesignKit", "DesignKitCatalog"],
            path: "Sources/DesignGallery"
        ),
        // The CloudKit bridge (Go hub phase 3, spec §6.2): the signed helper
        // WatchtowerCloudBridge.app serves the Go hub's CloudKit transport on
        // <hub dir>/bridge.sock. The library takes the Kit's model-free
        // WatchtowerSync only (and its GRDB, for bridge.db): it holds no hub
        // key and opens no envelope (pinned by CloudBridgeTests'
        // testBridgeNeverOpensEnvelopes). The app links it for the share code
        // the Swift hub's CloudKitShareService wraps until that hub goes.
        .target(
            name: "CloudBridgeCore",
            dependencies: [
                .product(name: "WatchtowerSync", package: "WatchtowerKit"),
                .product(name: "GRDB", package: "GRDB.swift"),
            ],
            path: "Sources/CloudBridgeCore"
        ),
        // The helper's executable: main.swift only.
        .executableTarget(
            name: "WatchtowerCloudBridge",
            dependencies: ["CloudBridgeCore"],
            path: "Sources/WatchtowerCloudBridge"
        ),
        .executableTarget(
            name: "WatchtowerDesktop",
            dependencies: [
                "WatchtowerCore",
                "DesignKit",
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "Yams", package: "Yams"),
                .product(name: "WhisperKit", package: "WhisperKit"),
                .product(name: "FluidAudio", package: "FluidAudio"),
                .product(name: "Qwen3ASR", package: "speech-swift"),
                .product(name: "SwiftTerm", package: "SwiftTerm"),
                .product(name: "WatchtowerSync", package: "WatchtowerKit"),
                "CloudBridgeCore",
            ],
            path: "Sources",
            exclude: [
                "WatchtowerCore", "OCRKit", "OCRHelper", "DesignKit", "DesignKitCatalog", "DesignGallery",
                "CloudBridgeCore", "WatchtowerCloudBridge",
            ],
            resources: [
                .process("Resources"),
                // POC (code viewer): Monaco host page + build (scripts/fetch-monaco.sh).
                .copy("CodeEditorWeb"),
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
            path: "Tests/Core",
            exclude: ["Fixtures"]
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
                "DesignKit",
                "DesignKitCatalog",
                "WatchtowerTestSupport",
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "ViewInspector", package: "ViewInspector"),
                // The hub tests drive it on the Kit's InMemoryCloudTransport.
                .product(name: "WatchtowerSync", package: "WatchtowerKit"),
                // F25: the test hub and phone (fixed pairing) that seal and open what the hub publishes.
                .product(name: "WatchtowerE2ETesting", package: "WatchtowerKit"),
            ],
            path: "Tests",
            exclude: ["Core", "Support", "OCRHelperTests", "CloudBridge"]
        ),
        // The bridge's own tests: CloudBridgeCore only — no app, no ML stack,
        // so the linked-symbols check sees the bridge's code alone.
        .testTarget(
            name: "CloudBridgeTests",
            dependencies: ["CloudBridgeCore"],
            path: "Tests/CloudBridge"
        ),
    ]
)
